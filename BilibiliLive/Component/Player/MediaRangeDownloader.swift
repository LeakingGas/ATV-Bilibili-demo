//
//  MediaRangeDownloader.swift
//  BilibiliLive
//
//  BTR native port: priority queue, weighted assignment, resumable hedging.
//  职责：有界并发、子块切分、CDN 健康模型、慢请求竞速、严格校验、有序流式交付。
//  状态限定在当前媒体流/播放会话内，不跨视频持久化，不持有全局 CDN 排名。
//

import Foundation

// MARK: - 全局并发预算（只管理资源数量，不持有 CDN 排名）

/// 所有活动媒体会话共享的总并发预算。
/// 只计数在途子请求数量，不记录任何 CDN 吞吐状态。
/// 许可与释放通过 BudgetPermit token 一一绑定：一次获取最多释放一次，
/// 未持许可的请求不得发送，避免绕过上限或重复释放破坏计数。
actor MediaDownloadBudget {
    static let shared = MediaDownloadBudget()

    /// 同时进行的全局请求上限（内部参数，实测调整）。
    private let globalMax = 64
    /// 同 host 上限（内部参数，实测调整）。
    private let perHostMax = 8

    /// 已发出的有效许可集合；释放时必须持有对应 token，否则忽略。
    private var outstanding = Set<BudgetPermit>()
    private var perHostActive = [String: Int]()
    private var owners = [BudgetPermit: BTRPlaybackSession]()

    private struct Waiter {
        let id: UUID
        let host: String
        let priority: Int
        let sequence: Int
        let queuedAt: Double
        let session: BTRPlaybackSession?
        let deadline: BTRDeadline?
        let queueClass: Int
        func rank(_ now: Double) -> Double {
            let due = deadline?.value ?? .infinity
            guard due.isFinite else { return Double(priority) }
            let left = due - now
            let urgency = left <= 0 ? 12.0 : left <= 750 ? 9.0 : left <= 2000 ? 6.0 : 0
            return Double(priority) + urgency + (queueClass == 2 ? (now - queuedAt) * 20 / 900 : 0)
        }
    }
    private var waiting = [Waiter]()
    private var sequence = 0
    private func activeCount(_ session: BTRPlaybackSession) -> Int { owners.values.filter { $0.id == session.id }.count }
    private func notifyDemand() {
        var sessions = [UUID: BTRPlaybackSession]()
        for value in owners.values { sessions[value.id] = value }
        for value in waiting.compactMap({ $0.session }) { sessions[value.id] = value }
        for value in sessions.values {
            value.demand(active: activeCount(value), queued: waiting.filter { $0.session?.id == value.id }.count)
        }
    }
    func acquire(host: String, priority: Int, session: BTRPlaybackSession? = nil,
                 deadline: BTRDeadline? = nil, queueClass: Int = 2) async throws -> BudgetPermit {
        let id = UUID()
        sequence += 1
        waiting.append(Waiter(id: id, host: host, priority: priority, sequence: sequence,
            queuedAt: BTRPlaybackSession.now, session: session, deadline: deadline, queueClass: queueClass))
        defer { waiting.removeAll { $0.id == id }; notifyDemand() }
        while true {
            try Task.checkCancellation()
            if let deadline, !deadline.valid { throw CancellationError() }
            notifyDemand()
            let now = BTRPlaybackSession.now
            let eligible = waiting.filter {
                (perHostActive[$0.host] ?? 0) < perHostMax
                    && ($0.session.map { activeCount($0) < $0.limit } ?? true)
                    && ($0.deadline?.valid ?? true)
            }.sorted {
                if $0.queueClass != $1.queueClass { return $0.queueClass < $1.queueClass }
                let a = $0.rank(now), b = $1.rank(now)
                return a == b ? $0.sequence < $1.sequence : a > b
            }
            if outstanding.count < globalMax, eligible.first?.id == id {
                let permit = BudgetPermit(host: host)
                outstanding.insert(permit)
                perHostActive[host, default: 0] += 1
                if let session { owners[permit] = session }
                return permit
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 释放许可。同一 token 只生效一次；未知 token 直接忽略。
    func release(_ permit: BudgetPermit) {
        guard outstanding.remove(permit) != nil else { return }
        let owner = owners.removeValue(forKey: permit)
        defer {
            notifyDemand()
            if let owner { owner.demand(active: activeCount(owner), queued: waiting.filter { $0.session?.id == owner.id }.count) }
        }
        let host = permit.host
        if let current = perHostActive[host] {
            if current <= 1 {
                perHostActive[host] = nil
            } else {
                perHostActive[host] = current - 1
            }
        }
    }
}

/// 并发预算许可 token。一次获取、最多释放一次，不可伪造（仅预算 actor 可创建）。
struct BudgetPermit: Hashable, Sendable {
    /// 内部记账用的 host（URL host 小写形式）。
    let host: String
    private let id: UUID
    /// 仅 MediaDownloadBudget 可创建。
    fileprivate init(host: String) {
        self.host = host
        id = UUID()
    }
}

// MARK: - 只读诊断快照

struct MediaRangeDiagnostics: Sendable {
    var transportMode: MediaTransportMode
    var activeHosts: Int
    /// 各 host 历史实测吞吐之和：多 host 并行时近似聚合上限，单 host 时即其实测值。
    /// 它是估计值，不是端到端实测的聚合吞吐，不得直接作为性能验收的吞吐结论。
    var estimatedAggregateMbps: Double
    var activeSubrequests: Int
    var failures: Int
    var retries: Int
    var deliveredBytes: Int64
    var extraBytes: Int64
    var downgradedToDirect: Bool

    var redundancyRatio: Double {
        guard deliveredBytes > 0 else { return 0 }
        return Double(extraBytes) / Double(deliveredBytes)
    }
}

// MARK: - 有界数据通道（异步生产者 → 同步 HTTP writer）

/// 私有桥接类型：只有下载器能写入已验证的有序字节，HTTP writer 在后台
/// socket 队列同步读取。容量按字节限制，满时生产者挂起（不阻塞线程）。
/// 禁止用无限缓存或丢弃旧数据实现背压；同一请求最多交付一次且严格递增。
final class MediaBytePipe: @unchecked Sendable {
    enum PipeError: Error {
        case closed
        case failed(Error)
        case readTimeout
    }

    private let condition = NSCondition()
    private var buffer = Data()
    private let capacityBytes: Int
    private var closed = false
    private var failure: Error?

    init(capacityBytes: Int = 2 * 1024 * 1024) {
        self.capacityBytes = max(64 * 1024, capacityBytes)
    }

    /// 异步写入。满时挂起直到消费者读取腾出空间；关闭/失败/取消时抛出。
    func write(_ data: Data, isCurrent: @Sendable () -> Bool = { true }) async throws {
        guard !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            guard isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
            let chunkEnd = min(data.count, offset + min(capacityBytes, 256 * 1024))
            let chunk = data[(data.startIndex + offset)..<(data.startIndex + chunkEnd)]
            try await writeChunk(Data(chunk), isCurrent: isCurrent)
            offset = chunkEnd
        }
    }

    private func writeChunk(_ chunk: Data, isCurrent: @Sendable () -> Bool) async throws {
        if try tryAppend(chunk) { return }
        // 慢路径：等待空间（挂起，不阻塞线程），用轮询+短等待避免复杂延续队列
        while true {
            guard isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
            if try tryAppend(chunk) { return }
            // 短暂让出，等待消费者读取
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    /// 同步尝试追加；返回 true 表示已写入，false 表示缓冲满需稍后重试。
    /// 失败/关闭时直接抛出。锁操作封装在同步函数内，避免在 async 上下文直接调用。
    private func tryAppend(_ chunk: Data) throws -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if let failure {
            throw PipeError.failed(failure)
        }
        if closed {
            throw PipeError.closed
        }
        if buffer.count + chunk.count <= capacityBytes {
            buffer.append(chunk)
            condition.signal()
            return true
        }
        return false
    }

    /// 同步读取（供 Swifter writer 在后台队列调用，可阻塞该队列线程）。
    /// 返回 nil 表示 EOF（生产者已 close 且缓冲排空）。
    func readSync(maxLength: Int, timeout: TimeInterval = 30) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty {
            if let failure {
                throw PipeError.failed(failure)
            }
            if closed {
                return nil
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw PipeError.readTimeout
            }
            condition.wait(until: deadline)
        }
        let take = min(maxLength, buffer.count)
        let chunk = buffer.prefix(take)
        buffer.removeFirst(take)
        condition.signal()
        return Data(chunk)
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if failure == nil {
            failure = error
            if error is CancellationError { buffer.removeAll() }
        }
        condition.broadcast()
        condition.unlock()
    }
}

// BTR native download engine. Ported from idm-downloader.js / cdn-resolver.js
// Copyright (c) 2026 Bilibili-thread-ripper contributors (MIT).
// The public name is retained as the ATV loopback adapter's source-compatible facade.
actor MediaRangeDownloader {
    private let candidates: [String]
    private let referer: String
    private let userAgent: String
    private let mode: MediaTransportMode
    private let playback: BTRPlaybackSession
    private let isAudio: Bool
    private var timings = [BTRSegmentTiming]()
    func setTimings(_ timings: [BTRSegmentTiming]) { self.timings = timings }
    private let client = BTRHTTPClient()
    private var policy = BTRPolicy()
    private var total: Int64?
    private var anchor: (MediaByteRange, Data)?
    private var verified = Set<String>()
    private var referenceSample: Data?
    private var speeds = [String: (bps: Double, at: Double)]()
    private var health = [String: (failures: Int, until: Double)]()
    private var active = [String: Int]()
    private var streams = 0
    private var delivered: Int64 = 0
    private var wireBytes: Int64 = 0
    private var failures = 0
    private var retries = 0
    private var downgraded = false
    private let memoryCap: Int64 = 16 * 1024 * 1024
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    init(candidates: [String], referer: String, userAgent: String = Keys.userAgent, mode: MediaTransportMode = .accelerated, playback: BTRPlaybackSession = BTRPlaybackSession(), isAudio: Bool = false) {
        var seen = Set<String>()
        self.candidates = candidates.filter { URL(string: $0)?.host != nil && seen.insert($0).inserted }
        self.referer = referer; self.userAgent = userAgent; self.mode = mode
        self.playback = playback; self.isAudio = isAudio
        playback.registerHosts(self.candidates.compactMap { URL(string: $0)?.host?.lowercased() })
    }
    deinit { client.invalidate() }
    func markDowngraded() { downgraded = true }
    func knownTotal() -> Int64? { total }
    func updateKnownTotal(_ value: Int64?) { if total == nil, let value, value > 0 { total = value } }
    func setTrustAnchor(range: MediaByteRange, bytes: Data) {
        if anchor == nil, Int64(bytes.count) == range.length { anchor = (range, bytes) }
    }
    func diagnostics() -> MediaRangeDiagnostics {
        MediaRangeDiagnostics(transportMode: mode, activeHosts: active.count,
            estimatedAggregateMbps: candidates.reduce(0) { $0 + speed($1) } * 8 / 1_000_000,
            activeSubrequests: active.values.reduce(0, +), failures: failures, retries: retries,
            deliveredBytes: delivered, extraBytes: max(0, wireBytes - delivered), downgradedToDirect: downgraded)
    }
    private func speed(_ url: String) -> Double {
        guard let sample = speeds[url], Self.now - sample.at < 90 else { return 0 }
        return sample.bps
    }
    private func sample(_ url: String, bytes: Int, elapsed: Double) {
        guard bytes >= 48 * 1024, elapsed > 0 else { return }
        let measured = Double(bytes) / elapsed
        let old = speeds[url]?.bps ?? 0
        speeds[url] = (old > 0 ? old * 0.65 + measured * 0.35 : measured, Self.now)
    }
    private func pool() -> [String] {
        let open = candidates.filter { (health[$0]?.until ?? 0) <= Self.now }
        let urls = open.isEmpty ? candidates : open
        return urls.enumerated().sorted {
            let a = speed($0.element), b = speed($1.element)
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
    func split(range: MediaByteRange) -> [MediaByteRange] {
        let slots = playback.limit
        let reserve = max(1, Int(ceil(Double(slots) / 8)))
        let limit = mode == .proxy ? 1 : isAudio ? reserve : max(1, slots - reserve)
        return BTRPolicy.split(range, limit: limit,
            minimum: policy.minimumChunk(length: range.length, limit: limit, hosts: candidates.count))
    }
    private final class RescueBudget {
        var value: BTRRescue
        init(_ slots: Int) { value = BTRRescue(max(1, Int(ceil(Double(slots) / 8)))) }
    }

    func stream(range: MediaByteRange, to pipe: MediaBytePipe) async {
        let generation = playback.generation
        let presentation = timings.first { $0.range.end >= range.start && $0.range.start <= range.end }?.start
        let deadline = BTRDeadline(session: playback, generation: generation, presentation: presentation)
        let rescue = RescueBudget(playback.limit)
        var admitted = false
        defer { if admitted { streams -= 1 } }
        do {
            guard !candidates.isEmpty, range.length <= memoryCap else { throw MediaRangeError.unsatisfiable(total: total) }
            // tvOS adaptation: two bounded streams per track. The byte pipe also backpressures.
            while streams >= 2 {
                guard deadline.valid else { throw CancellationError() }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard deadline.valid else { throw CancellationError() }
            try Task.checkCancellation()
            streams += 1; admitted = true
            var cursor = range.start
            // BTR startup media probe: promptly deliver a small verified head before the tail.
            if mode == .accelerated, speeds.isEmpty, range.length > 64 * 1024 {
                let head = try MediaByteRange(start: cursor, end: cursor + 64 * 1024 - 1)
                let bytes = try await downloadPiece(head, preferred: pool(), priority: 120, delay: 0, deadline: deadline, rescue: rescue)
                try await pipe.write(bytes, isCurrent: { deadline.valid }); delivered += Int64(bytes.count); cursor = head.end + 1
            }
            // BTR ordered chunks, bounded to 2 MiB windows rather than retaining a whole range.
            while cursor <= range.end {
                guard deadline.valid else { throw CancellationError() }
                let window = try MediaByteRange(start: cursor, end: min(range.end, cursor + 2 * 1024 * 1024 - 1))
                let pieces = split(range: window)
                let urls = pool()
                let measured = Dictionary(uniqueKeysWithValues: urls.map { ($0, speed($0)) })
                let primaries = policy.assign(urls, count: pieces.count) { measured[$0] ?? 0 }
                let delay = policy.hedgeDelay
                try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    defer { group.cancelAll() }
                    for (index, piece) in pieces.enumerated() {
                        let primary = primaries[index]
                        let preferred = [primary] + urls.filter { $0 != primary }
                        group.addTask {
                            let data = try await self.downloadPiece(piece, preferred: preferred,
                                priority: presentation == nil ? 220 : 50 - min(20, index), delay: delay, deadline: deadline, rescue: rescue)
                            return (index, data)
                        }
                    }
                    var ordered = [Int: Data]()
                    var next = 0
                    while let (index, bytes) = try await group.next() {
                        ordered[index] = bytes
                        while let chunk = ordered.removeValue(forKey: next) {
                            try await pipe.write(chunk, isCurrent: { deadline.valid })
                            delivered += Int64(chunk.count)
                            next += 1
                        }
                    }
                    guard next == pieces.count else { throw MediaRangeError.truncated }
                }
                cursor = window.end + 1
            }
            pipe.close()
        } catch { pipe.fail(error) }
    }
    func fetch(range: MediaByteRange) async throws -> Data {
        guard range.length <= memoryCap else { throw MediaRangeError.unsatisfiable(total: total) }
        let pipe = MediaBytePipe(capacityBytes: Int(max(64 * 1024, range.length)))
        // The whole capped result fits: no blocking reader on a cooperative executor.
        await stream(range: range, to: pipe)
        var result = Data()
        while let chunk = try pipe.readSync(maxLength: 256 * 1024) { result.append(chunk) }
        guard Int64(result.count) == range.length else { throw MediaRangeError.truncated }
        return result
    }

    // idm-downloader.js downloadPiece: shared longest prefix and live primary recorder.
    // Access to Piece/Context is confined to this actor; only BTRProgress crosses executors.
    private final class Context {
        let base: Data
        let progress = BTRProgress()
        let started = BTRPlaybackSession.now
        var resumable = true
        init(_ base: Data) { self.base = base }
        var bytes: Data { var data = base; data.append(progress.snapshot()); return data }
    }
    private final class Piece {
        var prefix = Data()
        var contexts = [Context]()
        func best() -> Data {
            contexts.reduce(prefix) { current, context in
                let live = context.resumable ? context.bytes : Data()
                return live.count > current.count ? live : current
            }
        }
    }
    private enum Outcome {
        case success(Data)
        case failure(Error)
        case timer
    }
    private func downloadPiece(_ range: MediaByteRange, preferred: [String], priority: Int, delay: Double, deadline: BTRDeadline, rescue: RescueBudget) async throws -> Data {
        let state = Piece()
        let started = Self.now
        var last: Error = MediaRangeError.truncated
        // BTR's three rounds, exponential pause, 25-second retry-admission window.
        for round in 0..<3 {
            try Task.checkCancellation()
            if round > 0 {
                retries += 1
                if Self.now - started > 25 { break }
                try await Task.sleep(nanoseconds: UInt64(min(2, 0.5 * pow(2, Double(round - 1))) * 1e9))
            }
            let offset = round % preferred.count
            let rotated = Array(preferred[offset...]) + Array(preferred[..<offset])
            let first = rotated[0]
            let rest = rotated.dropFirst().sorted { speed($0) > speed($1) }
            let urls = Array(([first] + rest).prefix(8))
            let open = urls.filter { (health[$0]?.until ?? 0) <= Self.now }
            let ordered = open + urls.filter { !open.contains($0) }
            let width = mode == .proxy ? 1 : 2
            for start in stride(from: 0, to: ordered.count, by: width) {
                if start > 0 { retries += 1 }
                let pair = Array(ordered[start..<min(start + width, ordered.count)])
                do { return try await race(range, state: state, pair: pair, priority: priority, delay: delay, deadline: deadline, rescue: rescue) }
                catch {
                    try Task.checkCancellation()
                    if !deadline.valid { throw CancellationError() }
                    last = error
                }
            }
        }
        throw last
    }
    private func race(_ range: MediaByteRange, state: Piece, pair: [String], priority: Int, delay: Double, deadline: BTRDeadline, rescue: RescueBudget) async throws -> Data {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            defer { group.cancelAll() }
            group.addTask { await self.lane(range, state: state, url: pair[0], priority: priority, deadline: deadline) }
            if pair.count > 1 {
                group.addTask {
                    try await self.waitForHedge(range, state: state, delay: delay, deadline: deadline, copy: pair[1], rescue: rescue)
                    return .timer
                }
            }
            var secondary = false
            var failed = 0
            var last: Error = MediaRangeError.truncated
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                switch outcome {
                case let .success(bytes):
                    playback.delivered(bytes.count, generation: deadline.generation)
                    return bytes // Promise.any: no 100ms loser grace period.
                case let .failure(error):
                    failed += 1; last = error
                    if failed == pair.count { throw last }
                    // BTR firstFailure: immediate rescue instead of waiting out the hedge timer.
                    if pair.count > 1, !secondary {
                        secondary = true; retries += 1; playback.rescued()
                        group.addTask { await self.lane(range, state: state, url: pair[1], priority: priority + 20, deadline: deadline) }
                    }
                case .timer:
                    if !secondary {
                        secondary = true; retries += 1; playback.rescued()
                        group.addTask { await self.lane(range, state: state, url: pair[1], priority: priority + 20, deadline: deadline) }
                    }
                }
            }
            throw last
        }
    }
    private func waitForHedge(_ range: MediaByteRange, state: Piece, delay: Double,
                              deadline: BTRDeadline, copy: String, rescue: RescueBudget) async throws {
        // With no mapped playback deadline retain BTR compatibility-mode timing.
        if deadline.presentation == nil {
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9)); return
        }
        var observation = BTRHedgeObservation(seenAt: BTRPlaybackSession.now)
        while true {
            try Task.checkCancellation()
            guard deadline.valid else { throw CancellationError() }
            if deadline.value.isFinite, let first = state.contexts.first {
                let got = first.progress.snapshot().count
                if observation.due(now: BTRPlaybackSession.now, started: first.started,
                    bytes: got, length: Int(range.length) - first.base.count, delay: delay * 1000,
                    deadline: deadline.value, copyBps: speed(copy), connectionBps: policy.connectionBps,
                    rescue: &rescue.value) { return }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func lane(_ range: MediaByteRange, state: Piece, url: String, priority: Int, deadline: BTRDeadline) async -> Outcome {
        do {
            try Task.checkCancellation()
            guard deadline.valid else { throw CancellationError() }
            try await verify(url, deadline: deadline)
            let host = URL(string: url)!.host!.lowercased()
            let permit = try await MediaDownloadBudget.shared.acquire(host: host, priority: priority, session: playback, deadline: deadline, queueClass: priority >= 200 ? 0 : priority >= 100 ? 1 : 2)
            do {
                try Task.checkCancellation()
                // BTR begin(): snapshot only after obtaining a slot, not at queue admission.
                var base = state.best()
                if base.count < 32 * 1024 || Int64(base.count) >= range.length { base = Data() }
                let context = Context(base)
                state.contexts.append(context)
                defer {
                    let bytes = context.bytes
                    if context.resumable, bytes.count > state.prefix.count, Int64(bytes.count) < range.length { state.prefix = bytes }
                    state.contexts.removeAll { $0 === context }
                }
                let tail = try MediaByteRange(start: range.start + Int64(base.count), end: range.end)
                do {
                    _ = try await raw(tail, url: url, progress: context.progress, permit: permit, deadline: deadline)
                    let result = context.bytes
                    guard Int64(result.count) == range.length else { throw MediaRangeError.truncated }
                    await MediaDownloadBudget.shared.release(permit)
                    return .success(result)
                } catch {
                    // Never resume malformed/overlong bodies; valid interrupted 206 prefixes survive.
                    if let e = error as? MediaRangeError, e == .mismatch { context.resumable = false; state.prefix = Data(); state.contexts.removeAll { $0 === context } }
                    throw error
                }
            } catch {
                await MediaDownloadBudget.shared.release(permit)
                throw error
            }
        } catch {
            playback.recordError(error, isAudio: isAudio, generation: deadline.generation)
            return .failure(error)
        }
    }
    private func raw(_ range: MediaByteRange, url: String, progress: BTRProgress,
                     permit: BudgetPermit, deadline: BTRDeadline? = nil) async throws -> Int64? {
        let requestDeadline = deadline ?? BTRDeadline(session: playback, generation: playback.generation, presentation: nil)
        let host = permit.host
        active[host, default: 0] += 1
        let started = Self.now
        defer {
            let bytes = progress.snapshot().count
            wireBytes += Int64(bytes)
            active[host] = (active[host] ?? 1) > 1 ? active[host]! - 1 : nil
            sample(url, bytes: bytes, elapsed: Self.now - started)
        }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let length = try await client.fetch(request, range: range, progress: progress, knownTotal: total,
                isCurrent: { requestDeadline.valid }, onProgress: { [playback] in playback.activity(generation: requestDeadline.generation) })
            try Task.checkCancellation()
            if let length {
                if let total, total != length { throw MediaRangeError.mismatch }
                total = length
            }
            health[url] = (0, 0)
            policy.record(bytes: progress.snapshot().count, elapsed: Self.now - started)
            return length
        } catch {
            if Task.isCancelled || !requestDeadline.valid { throw CancellationError() }
            let status: Int?
            if let mediaError = error as? MediaRangeError, case let .upstream(value) = mediaError { status = value } else { status = nil }
            playback.failure(status: status, noBytes: (error as? URLError)?.code == .timedOut && progress.snapshot().isEmpty, generation: requestDeadline.generation)
            failures += 1
            let count = (health[url]?.failures ?? 0) + 1
            health[url] = (count, Self.now + min(60, 3 * pow(2, Double(min(count, 4)))))
            throw error
        }
    }
    private func sampleBytes(_ range: MediaByteRange, url: String, deadline: BTRDeadline) async throws -> Data {
        let permit = try await MediaDownloadBudget.shared.acquire(host: URL(string: url)!.host!.lowercased(), priority: 220, session: playback, deadline: deadline, queueClass: 0)
        let progress = BTRProgress()
        do {
            _ = try await raw(range, url: url, progress: progress, permit: permit, deadline: deadline)
            await MediaDownloadBudget.shared.release(permit)
            return progress.snapshot()
        } catch { await MediaDownloadBudget.shared.release(permit); throw error }
    }
    // Native safety gate before BTR may splice a prefix from another URL. Unlike the old
    // implementation, inconclusive samples are not accepted. Signed URLs stay unmodified.
    private func verify(_ url: String, deadline: BTRDeadline) async throws {
        guard candidates.count > 1, !verified.contains(url) else { return }
        if let (range, bytes) = anchor {
            guard try await sampleBytes(range, url: url, deadline: deadline) == bytes else { throw MediaRangeError.mismatch }
        } else {
            let length = min(total ?? (32 * 1024), 32 * 1024)
            let range = try MediaByteRange(start: 0, end: length - 1)
            if referenceSample == nil {
                referenceSample = try await sampleBytes(range, url: candidates[0], deadline: deadline)
                verified.insert(candidates[0])
            }
            guard try await sampleBytes(range, url: url, deadline: deadline) == referenceSample else { throw MediaRangeError.mismatch }
        }
        verified.insert(url)
    }
}
