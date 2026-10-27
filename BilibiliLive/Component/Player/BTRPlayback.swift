// Swift port of BTR createAutoConcurrency, commit 49bdfe88 (MIT).
// Copyright (c) 2026 Bilibili-thread-ripper contributors. See ThirdParty/BTR/LICENSE.
import Foundation

struct BTRAutoConcurrency {
    var maximumThreads = 64
    static let ladder = [8, 12, 16, 24, 32, 48, 64]
    struct Trial { var from: Int; var level: Int; var at: Double; var baseline: Double; var stalled = false }
    struct Rest { var until: Double; var hard: Bool }
    private(set) var level = 0
    private(set) var changedAt = 0.0
    private(set) var steps = 0
    private(set) var reason = "start"
    private(set) var trial: Trial?
    private var resting = [Int: Rest]()
    private var buckets = [(at: Double, bytes: Int)]()
    private var lastActivity = -Double.infinity
    private var saturated = false
    private var saturatedSince = 0.0
    private var spans = [(from: Double, to: Double)]()
    private var aheadSamples = [(at: Double, ahead: Double)]()
    private var pressureSince = 0.0
    private var startup: (base: Int, until: Double)?
    var threads: Int { Self.ladder[level] }
    mutating func throughput(_ at: Double) -> Double {
        buckets.removeAll { at - $0.at > 5000 }
        guard let first = buckets.first, let last = buckets.last else { return 0 }
        return Double(buckets.reduce(0) { $0 + $1.bytes }) * 1000 / max(1000, last.at - first.at + 250)
    }
    mutating func saturation(_ at: Double) -> Double {
        let from = at - 5000
        spans.removeAll { $0.to <= from }
        var busy = spans.reduce(0.0) { $0 + max(0, $1.to - max($1.from, from)) }
        if saturated { busy += max(0, at - max(saturatedSince, from)) }
        return min(1, busy / 5000)
    }
    private mutating func rest(_ level: Int, _ at: Double) -> Rest? {
        guard let value = resting[level] else { return nil }
        if value.until <= at { resting[level] = nil; return nil }
        return value
    }
    private mutating func setLevel(_ level: Int, _ at: Double, _ reason: String, trial: Trial? = nil) {
        self.level = level; changedAt = at; self.reason = reason; steps += 1
        self.trial = trial; pressureSince = 0
    }
    @discardableResult private mutating func stepUp(_ at: Double, strong: Bool, reason: String) -> Bool {
        guard at - changedAt >= 2500, rest(level, at)?.hard != true else { return false }
        var next = level + 1
        while next < Self.ladder.count {
            guard let value = rest(next, at) else { break }
            if value.hard || !strong { return false }
            next += 1
        }
        guard next < Self.ladder.count, Self.ladder[next] <= maximumThreads else { return false }
        let trial = Trial(from: level, level: next, at: at, baseline: throughput(at))
        setLevel(next, at, reason, trial: trial); startup = nil
        return true
    }
    private mutating func stepDown(_ target: Int, restLevel: Int, at: Double, duration: Double, hard: Bool, reason: String) {
        resting[restLevel] = Rest(until: at + duration, hard: hard)
        if target < level { setLevel(target, at, reason) }
    }
    mutating func delivered(_ bytes: Int, at: Double) {
        if let last = buckets.last, at - last.at < 250 { buckets[buckets.count - 1].bytes += bytes }
        else { buckets.append((at, bytes)) }
        buckets.removeAll { at - $0.at > 5000 }
        guard let test = trial, at - test.at >= 10000 else { return }
        trial = nil
        guard !test.stalled, saturation(at) >= 0.6, test.baseline > 0 else { return }
        if throughput(at) < test.baseline {
            stepDown(test.from, restLevel: test.level, at: at, duration: 90000, hard: false, reason: "trial rollback")
        }
    }
    mutating func activity(at: Double) { lastActivity = at }
    mutating func demand(active: Int, limit: Int, queued: Int, at: Double) {
        let value = active >= limit && queued > 0
        guard value != saturated else { return }
        if saturated { spans.append((saturatedSince, at)) }
        saturated = value; saturatedSince = at
        _ = saturation(at)
    }
    mutating func stall(at: Double) {
        if trial != nil { trial?.stalled = true }
        stepUp(at, strong: true, reason: "stall")
    }
    mutating func buffer(ahead: Double, playing: Bool, at: Double) {
        aheadSamples.append((at, ahead))
        aheadSamples.removeAll { at - $0.at > 1250 }
        if let start = startup {
            if at >= start.until { startup = nil }
            else if ahead >= 15, at - changedAt >= 2500 {
                if level > start.base { setLevel(level - 1, at, "startup comfortable") }
                if level <= start.base { startup = nil }
            }
        }
        let earlier = aheadSamples.first { at - $0.at >= 1000 }
        let pressed = playing && at - lastActivity < 1500 && ahead < 6
            && earlier.map { ahead <= $0.ahead + 0.05 } == true
        guard pressed else { pressureSince = 0; return }
        if pressureSince == 0 { pressureSince = at; return }
        guard at - pressureSince >= 1000 else { return }
        pressureSince = 0
        stepUp(at, strong: false, reason: "buffer pressure")
    }
    mutating func slow(at: Double) {
        if saturation(at) >= 0.6 { stepUp(at, strong: false, reason: "first byte slow") }
    }
    mutating func pushback(at: Double) {
        stepDown(max(0, level - 1), restLevel: level, at: at, duration: 180000, hard: true, reason: "server pushback")
    }
    mutating func newSession(at: Double) {
        aheadSamples.removeAll(); pressureSince = 0; trial = nil; buckets.removeAll(); spans.removeAll()
        if saturated { saturatedSince = at }
        let base = startup?.base ?? level
        var target = level
        if rest(level, at)?.hard != true {
            while target < 2, Self.ladder[target + 1] <= maximumThreads, rest(target + 1, at)?.hard != true { target += 1 }
        }
        if target > level { setLevel(target, at, "startup") }
        startup = level > base ? (base, at + 30000) : nil
    }
}

// One lock-protected state shared by video/audio/quality renditions of a playback item.
// AVPlayer stays on the main thread; network code only sees plain values.
final class BTRPlaybackSession: @unchecked Sendable {
    static var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }
    let id = UUID()
    private let lock = NSLock()
    private var auto = BTRAutoConcurrency()
    private var epoch = 0
    private var closed = false
    private var position = 0.0
    private var rate = 1.0
    private var sampledAt = -Double.infinity
    private var advancing = false
    private var intended = false
    private var waiting = false
    private var initialized = false
    private var bufferAhead = 0.0
    private var activeRequests = 0
    private var queuedRequests = 0
    private var errors = [String: (message: String, at: Double)]()
    private var rescues = 0
    private var liveHosts = [String: Int]()
    private var orderedSamples = [(at: Double, bytes: Int)]()
    private var lastNetworkProgress = -Double.infinity
    private var lastOrderedProgress = -Double.infinity
    func transferStarted(host: String) { locked { liveHosts[host, default: 0] += 1 } }
    func transferEnded(host: String) { locked {
        if let count = liveHosts[host], count > 1 { liveHosts[host] = count - 1 }
        else { liveHosts.removeValue(forKey: host) }
    } }
    func ordered(_ bytes: Int, generation: Int) { locked {
        guard !closed, epoch == generation else { return }
        let now = Self.now
        orderedSamples.removeAll { now - $0.at > 5000 }
        orderedSamples.append((now, bytes))
        lastOrderedProgress = now
    } }
    private var hosts = Set<String>()
    func registerHosts(_ values: [String]) {
        locked { hosts.formUnion(values); auto.maximumThreads = max(8, min(64, hosts.count * 8)) }
    }
    private func locked<T>(_ operation: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation() }
    var generation: Int { locked { epoch } }
    var limit: Int { locked { auto.threads } }
    var debug: String { locked {
        let fresh = Self.now - sampledAt <= 1500
        let state = closed ? "closed" : !fresh ? "stale" : !intended ? "paused" : waiting ? "waiting" : "playing"
        let deadlineState = !closed && fresh && intended ? "mapped" : "off"
        var lines = ["BTR diag:13 trace auto:\(auto.threads) reason:\(auto.reason) gen:\(epoch)",
                     "slots:\(activeRequests)/\(auto.threads) queue:\(queuedRequests) rescue:\(rescues)",
                     String(format: "play:%@ ahead:%.1fs rate:%.2fx deadline:%@", state, bufferAhead, rate, deadlineState)]
        let now = Self.now
        orderedSamples.removeAll { now - $0.at > 5000 }
        let orderedMbps = Double(orderedSamples.reduce(0) { $0 + $1.bytes }) * 8 / 5_000_000
        let networkAge = lastNetworkProgress.isFinite ? String(format: "%.1fs", max(0, now - lastNetworkProgress) / 1000) : "none"
        let orderedAge = lastOrderedProgress.isFinite ? String(format: "%.1fs", max(0, now - lastOrderedProgress) / 1000) : "none"
        lines.append(String(format: "live hosts:%d http:%d ordered5s:%.2fMbps", liveHosts.count, liveHosts.values.reduce(0,+), orderedMbps))
        lines.append("last network:\(networkAge) ordered:\(orderedAge)")
        for track in ["video", "audio"] {
            if let error = errors[track] {
                lines.append(String(format: "%@ last:%@ (%.0fs ago)", track, error.message, max(0, Self.now - error.at) / 1000))
            }
        }
        return lines.joined(separator: "\n")
    } }
    func rescued() { locked { rescues += 1 } }
    // Only controlled labels/codes, never signed URLs or localizedDescription.
    func recordError(_ error: Error, isAudio: Bool, generation: Int) {
        locked {
            guard !closed, epoch == generation, !(error is CancellationError) else { return }
            let label: String
            if let value = error as? MediaRangeError {
                switch value {
                case .upstream(let status): label = "HTTP \(status)"
                case .truncated: label = "truncated"
                case .mismatch: label = "range/content mismatch"
                case .budgetExhausted: label = "budget exhausted"
                case .cancelled: return
                default: label = "range error"
                }
            } else if let value = error as? URLError {
                if value.code == .cancelled { return }
                label = "network \(value.code.rawValue)"
            } else { label = "transport error" }
            errors[isAudio ? "audio" : "video"] = (label, Self.now)
        }
    }
    func isCurrent(_ value: Int) -> Bool { locked { !closed && value == epoch } }
    func invalidate() { locked { closed = true; epoch += 1 } }
    func update(position: Double, rate: Double, advancing: Bool, intended: Bool, waiting: Bool,
                ahead: Double, jumped: Bool = false, now: Double = BTRPlaybackSession.now) {
        guard position.isFinite, rate.isFinite, ahead.isFinite else { return }
        locked {
            guard !closed else { return }
            let projected = self.position + (self.advancing ? max(0, now - sampledAt) / 1000 * self.rate : 0)
            // AVPlayer may issue target-range requests BEFORE its time-jump notification.
            // Those immutable byte requests remain valid; only item teardown invalidates them.
            let fresh = now - sampledAt <= 1500
            let discontinuity = initialized && fresh && abs(position - projected) > 1.5
            if !initialized || discontinuity {
                // Keep error history across seeks for post-failure diagnosis.
                auto.newSession(at: now)
            }
            if waiting && !self.waiting && intended && initialized && !discontinuity { auto.stall(at: now) }
            initialized = true
            self.position = position; self.rate = max(0.1, rate); self.advancing = advancing
            self.intended = intended; self.waiting = waiting; sampledAt = now
            bufferAhead = max(0, ahead)
            auto.buffer(ahead: max(0, ahead), playing: intended, at: now)
        }
    }
    func deadline(presentation: Double?, generation: Int, now: Double = BTRPlaybackSession.now) -> Double {
        locked {
            guard !closed, generation == epoch, intended, now - sampledAt <= 1500,
                  let presentation, presentation.isFinite else { return .infinity }
            let playhead = position + (advancing ? max(0, now - sampledAt) / 1000 * rate : 0)
            return now + max(0, presentation - playhead) / rate * 1000
        }
    }
    func activity(generation: Int) { locked { if !closed && generation == epoch { lastNetworkProgress = Self.now; auto.activity(at: Self.now) } } }
    func delivered(_ bytes: Int, generation: Int) { locked { if !closed && generation == epoch { auto.delivered(bytes, at: Self.now) } } }
    func demand(active: Int, queued: Int) { locked { activeRequests = active; queuedRequests = queued; auto.demand(active: active, limit: auto.threads, queued: queued, at: Self.now) } }
    func failure(status: Int?, noBytes: Bool, generation: Int) {
        locked {
            guard !closed, generation == epoch else { return }
            if status == 412 || status == 429 { auto.pushback(at: Self.now) }
            else if noBytes { auto.slow(at: Self.now) }
        }
    }
}

struct BTRSegmentTiming: Sendable {
    let range: MediaByteRange
    let start: Double
}
struct BTRDeadline: Sendable {
    let session: BTRPlaybackSession
    let generation: Int
    let presentation: Double?
    var value: Double { session.deadline(presentation: presentation, generation: generation) }
    var valid: Bool { session.isCurrent(generation) }
}

// BTR hedgeDue + bounded progress/stale rescue budget. Used on the downloader actor.
struct BTRRescue {
    var progressRemaining: Int
    var staleRemaining: Int
    init(_ limit: Int) { progressRemaining = max(0, limit); staleRemaining = max(1, limit) }
    mutating func claimProgress() -> Bool {
        guard progressRemaining > 0 else { return false }; progressRemaining -= 1; return true
    }
    mutating func claimStale() -> Bool {
        guard staleRemaining > 0 else { return false }; staleRemaining -= 1; return true
    }
}
struct BTRHedgeObservation {
    var seenBytes = 0
    var seenAt: Double
    var deficits = 0
    mutating func due(now: Double, started: Double, bytes: Int, length: Int, delay: Double,
                      deadline: Double, copyBps: Double, connectionBps: Double, rescue: inout BTRRescue) -> Bool {
        let ran = now - started
        let progressed = bytes != seenBytes
        if progressed { seenBytes = bytes; seenAt = now }
        let rate = Double(bytes) * 1000 / max(1, ran)
        let eta = Double(max(0, length - bytes)) * 1000 / max(1, rate)
        if deadline.isFinite && bytes > 0 && progressed {
            deficits = eta - (deadline - now) >= 250 ? deficits + 1 : 0
            let slowPeer = connectionBps > 0 && rate < connectionBps * 0.5 && eta >= 500
            if ran >= 250, ((eta >= max(0, deadline - now) && slowPeer) || deficits >= 2), rescue.claimProgress() { return true }
        }
        guard ran >= delay else { return false }
        if bytes == 0 || now - seenAt >= delay { return true }
        if now + eta <= deadline - 1500 { return false }
        if copyBps > rate * 1.5 { return true }
        if connectionBps <= 0 || rate < connectionBps * 0.6 { return true }
        if copyBps <= 0 { return true }
        return now + eta > deadline && rescue.claimStale()
    }
}


// Opt-in, bounded flight recorder. Callers supply only numeric metadata, generated IDs,
// and CDN hostnames. Never pass URL strings, headers, media bytes or error descriptions.
final class BTRTrace: @unchecked Sendable {
    static let shared = BTRTrace()
    @TaskLocal static var requestID: String = ""
    private let lock = NSLock()
    private let capacity = 12000
    private var rows = [String]()
    private var cursor = 0
    private var sequence = 0
    private var active = false
    private var started = 0.0
    private var wallStart = ""
    static var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }
    func start() {
        lock.lock(); defer { lock.unlock() }
        rows.removeAll(keepingCapacity: true); cursor = 0; sequence = 0
        started = Self.now; wallStart = ISO8601DateFormatter().string(from: Date()); active = true
    }
    func freeze() { lock.lock(); active = false; lock.unlock() }
    /// 这些事件同时写进常驻的闪退诊断流水（不依赖 BTR 记录是否开启）。
    private static let persistent: Set<String> = ["foreground_reload", "foreground_reload_failed", "foreground_playurl",
        "player_failure", "seek_requested", "quality_switch", "track_registered", "startup_mark", "stream_failed",
        "proxy_failed", "proxy_rejected", "host_banned", "prewarm_begin", "playlist_start_offset", "player_kickstart"]
    /// 由 App 的闪退诊断模块注入（测试里不存在）。
    static var persistentSink: ((String) -> Void)?
    /// 起播记录（App 注入）：每个事件都转给它，由它决定当前是否在记录起播过程。
    static var startupSink: ((String, [String: Any]) -> Void)?
    func event(_ name: String, _ fields: [String: Any] = [:]) {
        Self.startupSink?(name, fields)
        if Self.persistent.contains(name), let sink = Self.persistentSink {
            let compact = fields.filter { $0.key != "hosts" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            sink("BTR " + name + " " + compact)
        }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        if Self.now - started > 600000 { active = false; return }
        var row = fields
        row["event"] = name; row["ms"] = Int(Self.now - started); row["seq"] = sequence
        if row["request"] == nil, !Self.requestID.isEmpty { row["request"] = Self.requestID }
        guard JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              data.count <= 2048, let line = String(data: data, encoding: .utf8) else { return }
        sequence += 1
        if rows.count < capacity { rows.append(line) }
        else { rows[cursor] = line; cursor = (cursor + 1) % capacity }
    }
    func export() -> String {
        lock.lock(); defer { lock.unlock() }
        let header: [String: Any] = ["format":"btr-trace-1", "build":"diag14-startup",
            "startedUTC":wallStart, "recording":active, "events":rows.count,
            "overwritten":max(0, sequence - rows.count), "maxSeconds":600]
        let data = try! JSONSerialization.data(withJSONObject:header,options:[.sortedKeys])
        let ordered = Array(rows[cursor...]) + Array(rows[..<cursor])
        return String(data:data,encoding:.utf8)! + "\n" + ordered.joined(separator:"\n") + "\n"
    }
    static func errorFields(_ error: Error) -> [String: Any] {
        if error is CancellationError { return ["error":"cancelled"] }
        if let pipe = error as? MediaBytePipe.PipeError {
            switch pipe {
            case .failed(let underlying): return errorFields(underlying)
            case .readTimeout: return ["error":"pipe-read-timeout"]
            case .closed: return ["error":"pipe-closed"]
            }
        }
        let e = error as NSError
        // Do not include userInfo, which can contain signed URLs.
        return ["errorDomain":e.domain,"errorCode":e.code]
    }
}


// History applies only on first entry, never again when replacing the player for quality.
// Capturing a quality target also consumes history if initial readiness hasn't arrived yet.
struct PlaybackResumeState {
    private var historyConsumed = false
    mutating func initialTarget(history: Double?) -> Double? {
        guard !historyConsumed else { return nil }
        historyConsumed = true
        guard let history, history.isFinite, history > 0 else { return nil }
        return history
    }
    mutating func qualityTarget(current: Double) -> Double? {
        guard current.isFinite, current >= 0 else { return nil }
        historyConsumed = true
        return current
    }
}
