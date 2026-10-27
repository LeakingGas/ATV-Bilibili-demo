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
    var attemptTrace: String = ""
    var downgradedToDirect: Bool
    var candidateCount = 0
    var bannedCount = 0
    var readAheadSlots = 0
    var readAheadBytes: Int64 = 0

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

    let traceID = UUID().uuidString
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
        let traceStarted = BTRTrace.now
        BTRTrace.shared.event("pipe_backpressure_begin", ["request":traceID])
        defer { BTRTrace.shared.event("pipe_backpressure_end", ["request":traceID,"waitMs":BTRTrace.now-traceStarted]) }
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
    nonisolated let traceID = UUID().uuidString
    private let candidates: [String]
    private let referer: String
    private let userAgent: String
    private let mode: MediaTransportMode
    private let playback: BTRPlaybackSession
    private let isAudio: Bool
    private let traceLabel: String
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
    private var recentAttempts = [String]()
    private var downgraded = false
    private let memoryCap: Int64 = 16 * 1024 * 1024
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    init(candidates: [String], referer: String, userAgent: String = Keys.userAgent, mode: MediaTransportMode = .accelerated, playback: BTRPlaybackSession = BTRPlaybackSession(), isAudio: Bool = false, traceLabel: String = "") {
        var seen = Set<String>()
        self.candidates = candidates.filter { URL(string: $0)?.host != nil && seen.insert($0).inserted }
        self.referer = referer; self.userAgent = userAgent; self.mode = mode
        self.playback = playback; self.isAudio = isAudio; self.traceLabel = traceLabel
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
            deliveredBytes: delivered, extraBytes: max(0, wireBytes - delivered), attemptTrace: recentAttempts.joined(separator: " | "), downgradedToDirect: downgraded,
            candidateCount: candidates.count, bannedCount: candidates.filter { health[$0]?.until == .infinity }.count,
            readAheadSlots: slots.count, readAheadBytes: slots.reduce(0) { $0 + Int64($1.data?.count ?? 0) })
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
        let usable = candidates.filter { health[$0]?.until != .infinity }
        let base = usable.isEmpty ? candidates : usable
        let open = base.filter { (health[$0]?.until ?? 0) <= Self.now }
        let urls = open.isEmpty ? base : open
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
        await BTRTrace.$requestID.withValue(pipe.traceID) {
            await streamRecorded(range: range, to: pipe, readAhead: mode == .accelerated)
        }
    }

    // MARK: - diag12 pipelined read-ahead
    //
    // Device traces (diag9/diag10) showed cold overseas edges answering after 0.5-2.5 s while a
    // started body arrived at >200 Mbps. The diag5-11 port waited for a whole 2 MiB window before
    // starting the next one, so every window paid that latency: ~2 MiB per ~3 s = 5 Mbps, below a
    // 20-25 Mbps 4K track. Upstream BTR splits the whole player range at once. Here a bounded
    // sliding pipeline keeps `depth` pieces in flight, delivers strictly in order, refills as soon
    // as any piece settles and continues past the player's range into the next HLS segment
    // (which AVPlayer requests next), bounded by `aheadBytes` of memory per track.
    private final class Slot {
        let range: MediaByteRange
        var task: Task<Data, Error>?
        var data: Data?
        var finished = false
        /// diag14: live download state; the reader streams its verified prefix before the piece completes.
        let piece = Piece()
        /// diag14: the player is waiting for this piece (inside its requested / prewarmed range).
        var critical = false
        let created = BTRPlaybackSession.now
        init(_ range: MediaByteRange) { self.range = range }
    }
    private final class Reader {
        var cursor: Int64
        /// Where this reader started (the beginning of the player's request / prewarm).
        let origin: Int64
        let requestEnd: Int64
        let readAhead: Bool
        let generation: Int
        let rescue: RescueBudget
        init(cursor: Int64, requestEnd: Int64, readAhead: Bool, generation: Int, rescue: RescueBudget) {
            self.cursor = cursor; origin = cursor; self.requestEnd = requestEnd; self.readAhead = readAhead
            self.generation = generation; self.rescue = rescue
        }
    }
    private var slots = [Slot]()
    private var readers = [UUID: Reader]()
    private var pieceBytes: Int64 { mode == .proxy ? 512 * 1024 : isAudio ? 256 * 1024 : 1024 * 1024 }
    private var aheadBytes: Int64 { isAudio ? 4 * 1024 * 1024 : 24 * 1024 * 1024 }
    private var depth: Int {
        let limit = playback.limit
        let reserve = max(1, Int(ceil(Double(limit) / 8)))
        return mode == .proxy ? 1 : isAudio ? max(2, reserve) : max(2, limit - reserve)
    }
    private func slotAt(_ position: Int64) -> Slot? {
        slots.first { $0.range.start <= position && position <= $0.range.end }
    }
    private func remove(_ slot: Slot) { slots.removeAll { $0 === slot } }
    private func wanted(_ slot: Slot) -> Bool {
        readers.values.contains { slot.range.end >= $0.cursor && slot.range.start <= $0.cursor + aheadBytes }
    }
    private func evict() {
        let now = BTRPlaybackSession.now
        for slot in slots where !wanted(slot) || (slot.finished && now - slot.created > 60000) {
            slot.task?.cancel(); remove(slot)
            BTRTrace.shared.event("readahead_evicted",["start":slot.range.start,"end":slot.range.end,"finished":slot.finished])
        }
    }
    // diag13: start the segment AVPlayer will ask for first, before it asks.
    private var prewarmID: UUID?
    func prewarm(range: MediaByteRange) {
        guard mode == .accelerated, prewarmID == nil, slotAt(range.start) == nil else { return }
        let id = UUID()
        prewarmID = id
        readers[id] = Reader(cursor: range.start, requestEnd: range.end, readAhead: false,
                             generation: playback.generation, rescue: RescueBudget(playback.limit))
        BTRTrace.shared.event("prewarm_begin",["track":traceID,"start":range.start,"end":range.end])
        if let reader = readers[id] { schedule(reader) }
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self.endPrewarm(id)
        }
    }
    private func endPrewarm(_ id: UUID) {
        guard prewarmID == id else { return }
        readers[id] = nil; prewarmID = nil
        evict()
    }
    /// Verify every node concurrently instead of one node per first lane.
    func verifyAllHosts() {
        let deadline = BTRDeadline(session: playback, generation: playback.generation, presentation: nil)
        for url in candidates where !verified.contains(url) {
            Task { try? await self.verify(url, deadline: deadline) }
        }
    }

    /// Cancels and drains read-ahead that no active reader needs (tests, item teardown).
    func cancelReadAhead() async {
        let idle = slots.filter { !wanted($0) }
        for slot in idle { slot.task?.cancel(); remove(slot) }
        for slot in idle { _ = try? await slot.task?.value }
    }
    private func refill() {
        for reader in readers.values { schedule(reader) }
    }
    private func schedule(_ reader: Reader) {
        guard playback.isCurrent(reader.generation) else { return }
        var position = reader.cursor
        while let existing = slotAt(position) { position = existing.range.end + 1 }
        // Memory bound: never schedule more than aheadBytes past the delivery cursor.
        let windowEnd = reader.cursor + aheadBytes - 1
        let end: Int64
        if reader.readAhead, let total { end = min(total - 1, windowEnd) }
        else { end = min(reader.requestEnd, windowEnd) }
        var pending = slots.filter { !$0.finished }.count
        var planned = [MediaByteRange]()
        // diag14: startup trace showed one slow connection on the first 1 MiB piece holding every later
        // (already finished) piece for 7.6 s. Before playback the first MiB goes out in 256 KiB pieces:
        // first bytes reach the player sooner and a slow connection only holds a small piece.
        let notPlaying = playback.deadline(presentation: 0, generation: reader.generation).isInfinite
        let smallHead = notPlaying && mode == .accelerated && !isAudio
        // The piece at the reader's cursor is always admitted, even when read-ahead filled `depth`.
        while position <= end, pending < depth || (planned.isEmpty && position == reader.cursor) {
            let size = smallHead && position - reader.origin < 1024 * 1024 ? 256 * 1024 : pieceBytes
            var pieceEnd = min(end, position + size - 1)
            if position <= reader.requestEnd { pieceEnd = min(pieceEnd, reader.requestEnd) }
            if let next = slots.filter({ $0.range.start > position }).min(by: { $0.range.start < $1.range.start }) {
                pieceEnd = min(pieceEnd, next.range.start - 1)
            }
            guard let piece = try? MediaByteRange(start: position, end: pieceEnd) else { break }
            planned.append(piece)
            slots.append(Slot(piece))
            pending += 1
            position = pieceEnd + 1
            while let existing = slotAt(position) { position = existing.range.end + 1 }
        }
        guard !planned.isEmpty else { return }
        slots.sort { $0.range.start < $1.range.start }
        let urls = pool()
        let measured = Dictionary(uniqueKeysWithValues: urls.map { ($0, speed($0)) })
        let primaries = policy.assign(urls, count: planned.count) { measured[$0] ?? 0 }
        let delay = policy.hedgeDelay
        for (index, piece) in planned.enumerated() {
            guard let slot = slots.first(where: { $0.range == piece }) else { continue }
            let primary = primaries[index]
            let preferred = [primary] + urls.filter { $0 != primary }
            let presentation = timings.first { $0.range.end >= piece.start && $0.range.start <= piece.end }?.start
            let deadline = BTRDeadline(session: playback, generation: reader.generation, presentation: presentation)
            let distance = slots.filter { $0.range.start >= reader.cursor && $0.range.start < piece.start }.count
            let priority = presentation == nil ? 220 : 50 - min(20, distance)
            let ahead = piece.start > reader.requestEnd
            slot.critical = !ahead
            BTRTrace.shared.event("piece_scheduled",["start":piece.start,"end":piece.end,"host":URL(string:primary)?.host ?? "","readAhead":ahead,"depth":depth])
            let rescue = reader.rescue
            let state = slot.piece
            slot.task = Task {
                do {
                    let bytes = try await self.downloadPiece(piece, state: state, slot: slot, preferred: preferred, priority: priority, delay: delay, deadline: deadline, rescue: rescue)
                    slot.data = bytes; slot.finished = true
                    self.refill()
                    return bytes
                } catch {
                    // No refill here: the reader waiting on this slot is about to fail (or was
                    // cancelled); re-creating its piece would leak a request. Gaps are filled by
                    // the next schedule() of a live reader.
                    slot.finished = true
                    self.remove(slot)
                    throw error
                }
            }
        }
    }
    private func value(of slot: Slot) async throws -> Data {
        if let data = slot.data { return data }
        guard let task = slot.task else { throw MediaRangeError.truncated }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func streamRecorded(range: MediaByteRange, to pipe: MediaBytePipe, readAhead: Bool) async {
        BTRTrace.shared.event("stream_begin", ["track":traceID,"session":playback.id.uuidString,
            "audio":isAudio,"start":range.start,"end":range.end,"media":traceLabel,"hosts":candidates.compactMap { URL(string:$0)?.host }])

        let generation = playback.generation
        let presentation = timings.first { $0.range.end >= range.start && $0.range.start <= range.end }?.start
        let deadline = BTRDeadline(session: playback, generation: generation, presentation: presentation)
        let due = deadline.value
        BTRTrace.shared.event("stream_deadline",["presentation":presentation ?? -1,"remainingMs":due.isFinite ? due-BTRPlaybackSession.now : -1])
        let rescue = RescueBudget(playback.limit)
        var admitted = false
        let readerID = UUID()
        // diag14: the piece this reader is currently streaming. Progressive delivery polls instead of
        // awaiting the piece task, so a cancelled request must cancel (and wait for) it explicitly,
        // as the old await-with-cancellation-handler did.
        var headSlot: Slot?
        defer {
            if admitted { streams -= 1 }
            readers[readerID] = nil
        }
        do {
            guard !candidates.isEmpty else { throw MediaRangeError.unsatisfiable(total: total) }
            // tvOS adaptation: two bounded streams per track. The byte pipe also backpressures.
            let admissionStarted = BTRTrace.now
            while streams >= 2 {
                guard deadline.valid else { throw CancellationError() }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard deadline.valid else { throw CancellationError() }
            try Task.checkCancellation()
            streams += 1; admitted = true
            var cursor = range.start
            let reused = slotAt(cursor) != nil
            BTRTrace.shared.event("stream_admitted",["waitMs":BTRTrace.now-admissionStarted,"readAheadHit":reused])
            // diag13: no serial 64 KiB startup probe. AVPlayer plays an HLS segment only once the
            // whole segment has arrived, so the probe only added one cold round trip before the
            // parallel pieces started.
            if let id = prewarmID, let warm = readers[id], cursor >= warm.cursor, cursor <= warm.requestEnd {
                // The player now asks for the prewarmed segment: this reader takes over.
                readers[id] = nil; prewarmID = nil
                BTRTrace.shared.event("prewarm_handoff",["start":cursor,"readyBytes":slots.filter { $0.finished }.reduce(0) { $0 + $1.range.length }])
            }
            let reader = Reader(cursor: cursor, requestEnd: range.end, readAhead: readAhead, generation: generation, rescue: rescue)
            readers[readerID] = reader
            // diag14: read-ahead pieces already in flight become critical once the player asks for them
            // (device trace: the 2nd segment's read-ahead pieces stalled 2-8 s without being hedged).
            for slot in slots where slot.range.end >= cursor && slot.range.start <= range.end { slot.critical = true }
            evict()
            while cursor <= range.end {
                guard deadline.valid else { throw CancellationError() }
                reader.cursor = cursor
                schedule(reader)
                guard let slot = self.slotAt(cursor) else { throw MediaRangeError.truncated }
                headSlot = slot
                let waitStarted = BTRTrace.now
                let upto = min(slot.range.end, range.end)
                let from = Int(cursor - slot.range.start), to = Int(upto - slot.range.start) + 1
                // diag14: hand over the piece's verified prefix as it arrives (in order) instead of
                // waiting for the whole piece. The player gets its first bytes with the first packet
                // and no longer times out ("No response for media file in 5 s") on a slow connection.
                var sent = from
                var firstByteMs = -1.0
                while sent < to {
                    guard deadline.valid else { throw CancellationError() }
                    if let data = slot.data {
                        guard Int64(data.count) == slot.range.length else { throw MediaRangeError.truncated }
                        let chunk = sent == 0 && to == data.count ? data : data.subdata(in: (data.startIndex + sent)..<(data.startIndex + to))
                        try await pipe.write(chunk, isCurrent: { deadline.valid })
                        if firstByteMs < 0 { firstByteMs = BTRTrace.now - waitStarted }
                        delivered += Int64(chunk.count)
                        playback.ordered(chunk.count, generation: generation)
                        sent = to
                        break
                    }
                    if slot.finished {
                        _ = try await value(of: slot) // failed piece: rethrow its error
                        throw MediaRangeError.truncated
                    }
                    let prefix = slot.piece.best()
                    let available = min(prefix.count, to)
                    if available - sent >= 64 * 1024 || (available == to && available > sent) {
                        let chunk = prefix.subdata(in: (prefix.startIndex + sent)..<(prefix.startIndex + available))
                        try await pipe.write(chunk, isCurrent: { deadline.valid })
                        if firstByteMs < 0 { firstByteMs = BTRTrace.now - waitStarted }
                        delivered += Int64(chunk.count)
                        playback.ordered(chunk.count, generation: generation)
                        sent = available
                        continue
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                BTRTrace.shared.event("ordered_delivery",["start":cursor,"end":upto,"bytes":to - from,"waitMs":BTRTrace.now-waitStarted,
                    "firstByteMs":firstByteMs,"inFlight":slots.filter { !$0.finished }.count,"held":slots.filter { $0.finished }.count])
                if upto == slot.range.end { remove(slot) }
                cursor = upto + 1
            }
            reader.cursor = cursor
            if readAhead { refill() }
            BTRTrace.shared.event("stream_complete")
            pipe.close()
        } catch {
            if Task.isCancelled || error is CancellationError, let slot = headSlot, !slot.finished {
                readers[readerID] = nil
                if !wanted(slot) {
                    slot.task?.cancel()
                    remove(slot)
                    _ = try? await slot.task?.value
                }
            }
            playback.recordError(error, isAudio: isAudio, generation: generation)
            BTRTrace.shared.event("stream_failed",BTRTrace.errorFields(error))
            pipe.fail(error)
        }
    }
    func fetch(range: MediaByteRange) async throws -> Data {
        guard range.length <= memoryCap else { throw MediaRangeError.unsatisfiable(total: total) }
        let pipe = MediaBytePipe(capacityBytes: Int(max(64 * 1024, range.length)))
        // The whole capped result fits: no blocking reader on a cooperative executor.
        await BTRTrace.$requestID.withValue(pipe.traceID) {
            await streamRecorded(range: range, to: pipe, readAhead: false)
        }
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
    private func downloadPiece(_ range: MediaByteRange, state: Piece, slot: Slot, preferred: [String], priority: Int, delay: Double, deadline: BTRDeadline, rescue: RescueBudget) async throws -> Data {
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
            BTRTrace.shared.event("piece_round",["start":range.start,"end":range.end,"round":round,"prefixBytes":state.best().count])
            let offset = round % preferred.count
            let rotated = Array(preferred[offset...]) + Array(preferred[..<offset])
            let first = rotated[0]
            let rest = rotated.dropFirst().sorted { speed($0) > speed($1) }
            let all = [first] + rest
            let usable = all.filter { health[$0]?.until != .infinity }
            let urls = Array((usable.isEmpty ? all : usable).prefix(8))
            let open = urls.filter { (health[$0]?.until ?? 0) <= Self.now }
            let ordered = open + urls.filter { !open.contains($0) }
            let width = mode == .proxy ? 1 : 2
            for start in stride(from: 0, to: ordered.count, by: width) {
                if start > 0 { retries += 1 }
                let pair = Array(ordered[start..<min(start + width, ordered.count)])
                do { return try await race(range, state: state, slot: slot, pair: pair, priority: priority, delay: delay, deadline: deadline, rescue: rescue) }
                catch {
                    try Task.checkCancellation()
                    if !deadline.valid { throw CancellationError() }
                    last = error
                }
            }
        }
        throw last
    }
    private func race(_ range: MediaByteRange, state: Piece, slot: Slot, pair: [String], priority: Int, delay: Double, deadline: BTRDeadline, rescue: RescueBudget) async throws -> Data {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            defer { group.cancelAll() }
            group.addTask { await self.lane(range, state: state, url: pair[0], priority: priority, deadline: deadline) }
            if pair.count > 1 {
                group.addTask {
                    try await self.waitForHedge(range, state: state, slot: slot, delay: delay, deadline: deadline, copy: pair[1], rescue: rescue)
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
                        BTRTrace.shared.event("hedge_start",["start":range.start,"end":range.end,"host":URL(string:pair[1])?.host ?? "","afterFailures":failed])
                        group.addTask { await self.lane(range, state: state, url: pair[1], priority: priority + 20, deadline: deadline) }
                    }
                case .timer:
                    if !secondary {
                        secondary = true; retries += 1; playback.rescued()
                        BTRTrace.shared.event("hedge_start",["start":range.start,"end":range.end,"host":URL(string:pair[1])?.host ?? "","afterFailures":failed])
                        group.addTask { await self.lane(range, state: state, url: pair[1], priority: priority + 20, deadline: deadline) }
                    }
                }
            }
            throw last
        }
    }
    private func waitForHedge(_ range: MediaByteRange, state: Piece, slot: Slot, delay: Double,
                              deadline: BTRDeadline, copy: String, rescue: RescueBudget) async throws {
        // With no mapped playback deadline retain BTR compatibility-mode timing — except for pieces the
        // player waits for: device trace showed prewarm pieces (scheduled before the playlist timings
        // exist) all hedged blindly at 0.9 s, doubling every request. Those use the startup rule below.
        if deadline.presentation == nil && !slot.critical {
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9)); return
        }
        var observation = BTRHedgeObservation(seenAt: BTRPlaybackSession.now)
        var startup = BTRStartupHedge()
        while true {
            try Task.checkCancellation()
            guard deadline.valid else { throw CancellationError() }
            if deadline.value.isFinite, let first = state.contexts.first {
                let got = first.progress.snapshot().count
                if observation.due(now: BTRPlaybackSession.now, started: first.started,
                    bytes: got, length: Int(range.length) - first.base.count, delay: delay * 1000,
                    deadline: deadline.value, copyBps: speed(copy), connectionBps: policy.connectionBps,
                    rescue: &rescue.value) { return }
            } else if slot.critical, let first = state.contexts.first {
                // diag14: before playback starts there is no playback deadline, so the rule above never
                // fired and a slow connection on a piece the player waits for ran unchallenged
                // (device trace: 1 MiB at ~150 KB/s for 7.6 s while other pieces took ~1 s).
                let now = BTRPlaybackSession.now
                let got = first.progress.snapshot().count
                if startup.due(now: now, started: first.started, bytes: got,
                               length: Int(range.length) - first.base.count, copyBps: speed(copy)),
                   rescue.value.claimProgress() {
                    BTRTrace.shared.event("startup_hedge",["start":range.start,"end":range.end,"bytes":got,
                        "elapsedMs":now - first.started,"copyBps":speed(copy)])
                    return
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func lane(_ range: MediaByteRange, state: Piece, url: String, priority: Int, deadline: BTRDeadline) async -> Outcome {
        do {
            try Task.checkCancellation()
            guard deadline.valid else { throw CancellationError() }
            let verifyStarted = BTRTrace.now
            BTRTrace.shared.event("verify_begin",["host":URL(string:url)?.host ?? "","start":range.start,"end":range.end])
            try await verify(url, deadline: deadline)
            BTRTrace.shared.event("verify_end",["host":URL(string:url)?.host ?? "","elapsedMs":BTRTrace.now-verifyStarted])
            let host = URL(string: url)!.host!.lowercased()
            let queuedAt = BTRTrace.now
            BTRTrace.shared.event("queue_begin",["host":host,"start":range.start,"end":range.end])
            let permit = try await MediaDownloadBudget.shared.acquire(host: host, priority: priority, session: playback, deadline: deadline, queueClass: priority >= 200 ? 0 : priority >= 100 ? 1 : 2)
            BTRTrace.shared.event("queue_end",["host":host,"start":range.start,"end":range.end,"waitMs":BTRTrace.now-queuedAt])
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
            BTRTrace.shared.event("lane_failed",BTRTrace.errorFields(error).merging(["start":range.start,"end":range.end,"host":URL(string:url)?.host ?? ""]) { _,new in new })
            return .failure(error)
        }
    }
    private func raw(_ range: MediaByteRange, url: String, progress: BTRProgress,
                     permit: BudgetPermit, deadline: BTRDeadline? = nil) async throws -> Int64? {
        let requestDeadline = deadline ?? BTRDeadline(session: playback, generation: playback.generation, presentation: nil)
        let host = permit.host
        active[host, default: 0] += 1
        playback.transferStarted(host: host)
        let started = Self.now
        var outcome = "ok"
        defer {
            let bytes = progress.snapshot().count
            recentAttempts.append("range=\(range.start)-\(range.end) got=\(bytes) result=\(outcome)")
            if recentAttempts.count > 12 { recentAttempts.removeFirst(recentAttempts.count - 12) }
            wireBytes += Int64(bytes)
            playback.transferEnded(host: host)
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
            if Task.isCancelled || !requestDeadline.valid {
                outcome = "cancelled"
                throw CancellationError()
            }
            if let network = error as? URLError { outcome = "network:\(network.code.rawValue)" }
            else if let media = error as? MediaRangeError { outcome = String(describing: media) }
            else { outcome = "transport-error" }
            let status: Int?
            if let mediaError = error as? MediaRangeError, case let .upstream(value) = mediaError { status = value } else { status = nil }
            playback.failure(status: status, noBytes: (error as? URLError)?.code == .timedOut && progress.snapshot().isEmpty, generation: requestDeadline.generation)
            failures += 1
            let count = (health[url]?.failures ?? 0) + 1
            // A node that refuses this signed address (synthetic BTR node) will keep refusing it.
            let permanent = status.map { [403, 404, 410].contains($0) } ?? false
            health[url] = (count, permanent ? .infinity : Self.now + min(60, 3 * pow(2, Double(min(count, 4)))))
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
    private func banMismatch(_ url: String) {
        health[url] = (99, .infinity)
        BTRTrace.shared.event("host_banned",["host":URL(string:url)?.host ?? "","reason":"content-mismatch"])
    }
    private var verifying = [String: Task<Void, Error>]()
    private func verify(_ url: String, deadline: BTRDeadline) async throws {
        guard candidates.count > 1, !verified.contains(url) else { return }
        if let running = verifying[url] { return try await running.value }
        let task = Task { try await self.verifyNow(url, deadline: deadline) }
        verifying[url] = task
        defer { verifying[url] = nil }
        try await task.value
    }
    private func verifyNow(_ url: String, deadline: BTRDeadline) async throws {
        guard !verified.contains(url) else { return }
        if let (range, bytes) = anchor {
            guard try await sampleBytes(range, url: url, deadline: deadline) == bytes else { banMismatch(url); throw MediaRangeError.mismatch }
        } else {
            let length = min(total ?? (32 * 1024), 32 * 1024)
            let range = try MediaByteRange(start: 0, end: length - 1)
            if referenceSample == nil {
                referenceSample = try await sampleBytes(range, url: candidates[0], deadline: deadline)
                verified.insert(candidates[0])
            }
            guard try await sampleBytes(range, url: url, deadline: deadline) == referenceSample else { banMismatch(url); throw MediaRangeError.mismatch }
        }
        verified.insert(url)
    }
}
