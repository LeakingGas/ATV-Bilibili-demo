//
//  RowPrefetcher.swift
//  BilibiliLive
//
//  列表里焦点所在的那一行：同时预载每个视频的播放地址和第一段，点开时直接用上。
//  同时保留两行：当前行和时间上的上一行（最近一次停留过的那行，不是空间上的上一行），
//  手快划走再划回来不用重下。焦点进入第三行时才丢掉更早的那行。遇到 B 站限流就停 10 分钟。
//

import Foundation

/// 状态用锁保护（不绑定主线程：播放器启动入口也会在非主线程上下文里取它的缓存）。
final class RowPrefetcher: @unchecked Sendable {
    static let shared = RowPrefetcher()
    private let lock = NSLock()

    /// 预载和点开播放共用这两个缓存（点开时能直接拿到预载的播放地址和已经在下的第一段）。
    let contextCache = PlayContextCache()
    /// 两行各最多 4 个，再留一个余量。预载时不取视频详情（少一个接口请求）。
    let warmup: PlayerMediaWarmupManager

    private init() {
        warmup = PlayerMediaWarmupManager(playContextCache: contextCache, maxPreparedEntries: 9, fillDetail: false)
    }

    /// 按 aid 记录的预载任务。
    private var tasks = [Int: Task<Void, Never>]()
    private var pendingRow: Task<Void, Never>?
    private var brakeUntil = Date.distantPast
    /// 当前行和时间上的上一行（aid 集合）。
    private var currentRow = Set<Int>()
    private var previousRow = Set<Int>()
    /// 列表里没有 cid 的视频（例如关注动态）查到的 cid，点开播放时也用它。
    private var resolvedCids = [Int: Int]()

    /// 预载时查到的 cid（没查过返回 nil）。
    func cachedCid(aid: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return resolvedCids[aid]
    }

    /// 焦点进入（或停在）某一行。停 0.3 秒才开始，划过的行不预载、也不算「上一行」。
    func focusRow(_ row: [PlayInfo], focused: PlayInfo?) {
        lock.lock(); defer { lock.unlock() }
        pendingRow?.cancel()
        guard Settings.prefetchRow else { return }
        guard Date() >= brakeUntil else {
            Diag.mark("PREFETCH skipped (rate-limit brake \(Int(brakeUntil.timeIntervalSinceNow))s left)")
            return
        }
        // 番剧走另一套播放地址，不预载；没有 cid 的普通视频预载时先查 cid。
        let infos = row.filter { $0.aid > 0 && !$0.isBangumi }.map { info -> PlayInfo in
            var info = info
            if !info.isCidVaild, let cid = resolvedCids[info.aid] { info.cid = cid }
            return info
        }
        pendingRow = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.start(infos, focused: focused)
        }
    }

    private func start(_ infos: [PlayInfo], focused: PlayInfo?) {
        lock.lock(); defer { lock.unlock() }
        let row = Set(infos.map(\.aid))
        var droppedRow = Set<Int>()
        if row == currentRow {
            // 同一行（例如在行内左右移动），保持不变。
        } else if row == previousRow {
            swap(&currentRow, &previousRow)
        } else {
            droppedRow = previousRow.subtracting(row)
            previousRow = currentRow
            currentRow = row
        }
        let keep = currentRow.union(previousRow)
        for (aid, task) in tasks where !keep.contains(aid) {
            task.cancel()
            tasks[aid] = nil
        }
        let warmup = warmup
        Task {
            let dropped = await warmup.retain(aids: keep)
            if dropped > 0 { Diag.mark("PREFETCH dropped \(dropped) from older row") }
        }
        // 焦点所在的视频先发起；上一行没下完的继续下完，不再追加。
        let focusedAid = focused?.aid ?? 0
        let ordered = infos.sorted { a, _ in a.aid == focusedAid }
        var started = 0
        for info in ordered where tasks[info.aid] == nil {
            started += 1
            tasks[info.aid] = Task { [weak self] in await self?.prefetch(info) }
        }
        Diag.mark("PREFETCH row n=\(infos.count) new=\(started) focused=\(focusedAid) keptPrevious=\(previousRow.count) droppedRow=\(droppedRow.count)")
    }

    private func prefetch(_ info: PlayInfo) async {
        let started = Date()
        var info = info
        do {
            if !info.isCidVaild {
                let cidStarted = Date()
                do {
                    info = try await PlayInfoResolver.resolve(info)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Diag.mark("PREFETCH cid_failed aid=\(info.aid) ms=\(Int(Date().timeIntervalSince(cidStarted) * 1000)): \(String(describing: error).prefix(120))")
                    throw error
                }
                guard info.isCidVaild else {
                    Diag.mark("PREFETCH cid_failed aid=\(info.aid) ms=\(Int(Date().timeIntervalSince(cidStarted) * 1000)): pagelist returned no cid")
                    throw "pagelist returned no cid"
                }
                lock.lock(); resolvedCids[info.aid] = info.cid; lock.unlock()
                Diag.mark("PREFETCH cid_resolved aid=\(info.aid) cid=\(info.cid ?? 0) ms=\(Int(Date().timeIntervalSince(cidStarted) * 1000))")
            }
            try Task.checkCancellation()
            let media = try await warmup.preparedMedia(for: info)
            try Task.checkCancellation()
            BTRTrace.shared.event("prefetch_ready", ["aid": info.aid, "ms": Int(Date().timeIntervalSince(started) * 1000)])
            Diag.mark("PREFETCH ready aid=\(info.aid) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            // 第一段（视频和音频）开始下载；播放器点开后接着用。
            await media.delegate.prewarmStart(at: 0)
        } catch is CancellationError {
            // 自己被取消时，任务表里的记录已由取消方移除；
            // 若是缓存被别处清空（例如 App 进后台）导致的取消，下面清掉记录，回到这行时会重新预载。
        } catch {
            if Self.isRateLimit(error) {
                lock.lock()
                brakeUntil = Date().addingTimeInterval(600)
                tasks.values.forEach { $0.cancel() }
                tasks.removeAll()
                currentRow = []
                previousRow = []
                lock.unlock()
                let warmup = warmup
                Task { await warmup.retain(aids: []) }
                Diag.mark("PREFETCH brake 10min after rate limit: \(error)")
            } else {
                Diag.mark("PREFETCH failed aid=\(info.aid): \(String(describing: error).prefix(120))")
            }
        }
        guard !Task.isCancelled else { return }
        lock.lock(); tasks[info.aid] = nil; lock.unlock()
    }

    /// 播放器关闭：只丢掉它用过的那几个视频（代理已随播放器关闭），两行里其他视频保留。
    func playerDidExit(playedAids: Set<Int>) {
        lock.lock()
        for aid in playedAids {
            tasks[aid]?.cancel()
            tasks[aid] = nil
        }
        lock.unlock()
        let warmup = warmup
        Task {
            let dropped = await warmup.evict(aids: playedAids)
            Diag.mark("PREFETCH player exit, evicted played=\(playedAids.sorted()) entries=\(dropped), rest kept")
        }
    }

    /// B 站风控 / 限流相关的错误码。
    private static func isRateLimit(_ error: Error) -> Bool {
        guard let requestError = error as? RequestError, case let .statusFail(code, _) = requestError else { return false }
        return [-412, 412, -352, -351, -509, -799].contains(code)
    }
}
