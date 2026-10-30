//
//  RowPrefetcher.swift
//  BilibiliLive
//
//  列表里焦点所在的那一行：同时预载每个视频的播放地址和第一段，点开时直接用上。
//  焦点换到别的行，上一行没下完的停掉、丢弃。遇到 B 站限流就停 10 分钟。
//

import Foundation

/// 状态用锁保护（不绑定主线程：播放器启动入口也会在非主线程上下文里取它的缓存）。
final class RowPrefetcher: @unchecked Sendable {
    static let shared = RowPrefetcher()
    private let lock = NSLock()

    /// 预载和点开播放共用这两个缓存（点开时能直接拿到预载的播放地址和已经在下的第一段）。
    let contextCache = PlayContextCache()
    /// 一行最多 4 个，再留一个给刚离开的焦点视频。预载时不取视频详情（少一个接口请求）。
    let warmup: PlayerMediaWarmupManager

    private init() {
        warmup = PlayerMediaWarmupManager(playContextCache: contextCache, maxPreparedEntries: 5, fillDetail: false)
    }

    private var tasks = [String: Task<Void, Never>]()
    private var pendingRow: Task<Void, Never>?
    private var brakeUntil = Date.distantPast


    /// 焦点进入（或停在）某一行。停 0.3 秒才开始，划过的行不预载。
    func focusRow(_ row: [PlayInfo], focused: PlayInfo?) {
        lock.lock(); defer { lock.unlock() }
        pendingRow?.cancel()
        guard Settings.prefetchRow else { return }
        guard Date() >= brakeUntil else {
            Diag.mark("PREFETCH skipped (rate-limit brake \(Int(brakeUntil.timeIntervalSinceNow))s left)")
            return
        }
        let infos = row.filter { $0.aid > 0 && ($0.cid ?? 0) > 0 && !$0.isBangumi }
        pendingRow = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.start(infos, focused: focused)
        }
    }

    private func start(_ infos: [PlayInfo], focused: PlayInfo?) {
        lock.lock(); defer { lock.unlock() }
        let keys = Set(infos.map(\.sequenceKey))
        for (key, task) in tasks where !keys.contains(key) {
            task.cancel()
            tasks[key] = nil
        }
        let warmup = warmup
        Task { await warmup.retain(sequenceKeys: keys) }
        // 焦点所在的视频先发起。
        let ordered = infos.sorted { a, _ in a.sequenceKey == focused?.sequenceKey }
        var started = 0
        for info in ordered where tasks[info.sequenceKey] == nil {
            started += 1
            tasks[info.sequenceKey] = Task { [weak self] in await self?.prefetch(info) }
        }
        Diag.mark("PREFETCH row n=\(infos.count) new=\(started) focused=\(focused?.aid ?? 0)")
    }

    private func prefetch(_ info: PlayInfo) async {
        let started = Date()
        do {
            let media = try await warmup.preparedMedia(for: info)
            guard !Task.isCancelled else { return }
            BTRTrace.shared.event("prefetch_ready", ["aid": info.aid, "ms": Int(Date().timeIntervalSince(started) * 1000)])
            Diag.mark("PREFETCH ready aid=\(info.aid) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            // 第一段（视频和音频）开始下载；播放器点开后接着用。
            await media.delegate.prewarmStart(at: 0)
        } catch is CancellationError {
            return
        } catch {
            if Self.isRateLimit(error) {
                lock.lock()
                brakeUntil = Date().addingTimeInterval(600)
                tasks.values.forEach { $0.cancel() }
                tasks.removeAll()
                lock.unlock()
                let warmup = warmup
                Task { await warmup.retain(sequenceKeys: []) }
                Diag.mark("PREFETCH brake 10min after rate limit: \(error)")
            } else {
                Diag.mark("PREFETCH failed aid=\(info.aid): \(String(describing: error).prefix(120))")
            }
        }
        lock.lock(); tasks[info.sequenceKey] = nil; lock.unlock()
    }

    /// B 站风控 / 限流相关的错误码。
    private static func isRateLimit(_ error: Error) -> Bool {
        guard let requestError = error as? RequestError, case let .statusFail(code, _) = requestError else { return false }
        return [-412, 412, -352, -351, -509, -799].contains(code)
    }
}
