import Foundation
// Only the app's default User-Agent is stubbed. Production sources are compiled directly.
enum Keys { static let userAgent = "BTR-native-tests" }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
}
func expected(_ start: Int, _ count: Int) -> Data { Data((start..<(start+count)).map { UInt8($0 % 256) }) }
@main struct Tests {
    static func main() async throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        for test in json["tests"] as! [[String: Any]] {
            var policy = BTRPolicy()
            let urls = test["urls"] as! [String], speeds = test["speeds"] as! [Double]
            for wanted in test["rounds"] as! [[String]] {
                let got = policy.assign(urls, count: test["count"] as! Int) { speeds[urls.firstIndex(of: $0)!] }
                try require(got == wanted, "BTR assignPrimaries parity")
            }
        }
        for test in json["splits"] as! [[String: Any]] {
            let range = try MediaByteRange(start: 17, end: 16 + Int64(test["length"] as! Int))
            let got = BTRPolicy.split(range, limit: test["limit"] as! Int, minimum: 65536)
            let wanted = test["pieces"] as! [[String: Int]]
            try require(got.count == wanted.count, "split count")
            for (a,b) in zip(got,wanted) { try require(a.start == Int64(b["start"]!) && a.end == Int64(b["end"]!), "split bytes") }
        }
        var policy = BTRPolicy()
        for item in json["meters"] as! [[String: Any]] {
            policy.record(bytes: item["bytes"] as! Int, elapsed: item["seconds"] as! Double)
            try require(abs(policy.hedgeDelay - (item["delay"] as! Double)) < 0.0001, "hedge delay parity")
            try require(policy.minimumChunk(length: 2097152, limit: 7, hosts: 2) == Int64(item["minimum"] as! Int), "adaptive chunk parity")
        }
        print("PASS: 59 original BTR policy vectors")
        for events in json["autos"] as! [[[String: Any]]] {
            var auto = BTRAutoConcurrency()
            for event in events {
                let now = event["at"] as! Double
                switch event["op"] as! String {
                case "newSession": auto.newSession(at: now)
                case "activity": auto.activity(at: now)
                case "stall": auto.stall(at: now)
                case "slow": auto.slow(at: now)
                case "pushback": auto.pushback(at: now)
                case "buffer": auto.buffer(ahead: event["ahead"] as! Double, playing: event["playing"] as! Bool, at: now)
                case "delivered": auto.delivered(event["bytes"] as! Int, at: now)
                case "demand": auto.demand(active: event["active"] as! Int, limit: event["limit"] as! Int, queued: event["queued"] as! Int, at: now)
                default: fatalError("unknown oracle event")
                }
                try require(auto.threads == event["threads"] as! Int && auto.steps == event["steps"] as! Int, "auto level/step parity")
                try require((auto.trial.map { BTRAutoConcurrency.ladder[$0.from] } ?? -1) == event["trialFrom"] as! Int, "trial parity")
                try require(abs(auto.throughput(now).rounded() - (event["throughput"] as! Double)) < 0.1, "throughput parity")
                try require(abs((auto.saturation(now)*100).rounded()/100 - (event["saturation"] as! Double)) < 0.001, "saturation parity")
            }
        }
        for event in json["hedges"] as! [[String: Any]] {
            var budget = BTRRescue(0)
            var observation = BTRHedgeObservation(seenBytes:event["bytes"] as! Int,seenAt:event["seenAt"] as! Double)
            let due = observation.due(now:event["now"] as! Double,started:0,bytes:event["bytes"] as! Int,
                length:event["length"] as! Int,delay:900,deadline:event["deadline"] as! Double,
                copyBps:event["copy"] as! Double,connectionBps:100000,rescue:&budget)
            try require(due == event["due"] as! Bool && budget.staleRemaining == event["remaining"] as! Int, "BTR hedgeDue parity")
        }
        // Primary data progress, not timer ticks, may spend one early rescue per range.
        var earlyBudget = BTRRescue(1)
        var early = BTRHedgeObservation(seenAt:0)
        _ = early.due(now:100,started:0,bytes:1000,length:100000,delay:900,deadline:200,copyBps:1000,connectionBps:1000,rescue:&earlyBudget)
        let rescued = early.due(now:300,started:0,bytes:2000,length:100000,delay:900,deadline:400,copyBps:1000,connectionBps:1000,rescue:&earlyBudget)
        try require(rescued && earlyBudget.progressRemaining == 0, "bounded early deficit rescue")
        // Deadline extrapolation, speed, paused/stale snapshots and seek generations.
        let session = BTRPlaybackSession()
        session.update(position:10,rate:2,advancing:true,intended:true,waiting:false,ahead:5,now:1000)
        let epoch = session.generation
        try require(abs(session.deadline(presentation:20,generation:epoch,now:1250)-6000) < 0.001, "2x deadline")
        session.update(position:10.5,rate:2,advancing:false,intended:false,waiting:false,ahead:5,now:1250)
        try require(session.deadline(presentation:20,generation:epoch,now:1300).isInfinite, "paused no deadline")
        session.update(position:100,rate:1,advancing:false,intended:true,waiting:true,ahead:0,jumped:true,now:1500)
        try require(!session.isCurrent(epoch), "seek invalidates old epoch")
        try require(session.deadline(presentation:100,generation:session.generation,now:1600)==1600, "overdue head is immediate")
        try require(session.deadline(presentation:101,generation:session.generation,now:4000).isInfinite, "stale snapshot has no deadline")
        session.invalidate()
        try require(!session.isCurrent(session.generation), "closed playback")
        // No rescue before a primary has actually started; on-pace transfers keep bandwidth.
        var rescue = BTRRescue(1)
        var observation = BTRHedgeObservation(seenAt:0)
        try require(!observation.due(now:100,started:0,bytes:10000,length:20000,delay:900,deadline:10000,copyBps:100000,connectionBps:100000,rescue:&rescue), "no premature hedge")
        try require(!observation.due(now:1000,started:0,bytes:100000,length:150000,delay:900,deadline:10000,copyBps:100000,connectionBps:100000,rescue:&rescue), "deadline met, no hedge")
        try require(observation.due(now:2000,started:0,bytes:100000,length:150000,delay:900,deadline:2100,copyBps:200000,connectionBps:100000,rescue:&rescue), "stopped transfer rescued")
        print("PASS: auto-concurrency source parity, playback deadline and rescue policy")
        let base = "http://127.0.0.1:\(CommandLine.arguments[2])"
        let range = try MediaByteRange(start: 0, end: 524287)
        let resume = MediaRangeDownloader(candidates: [base+"/resume"], referer: base, mode: .proxy)
        let resumed = try await resume.fetch(range: range)
        try require(resumed == expected(0,524288), "truncated prefix resume bytes")
        let (logData,_) = try await URLSession.shared.data(from: URL(string: base+"/stats")!)
        let log = try JSONSerialization.jsonObject(with: logData) as! [[String: Any]]
        try require(log.contains { ($0["path"] as? String) == "/resume" && ($0["start"] as? Int) == 65536 }, "retry must request missing tail")
        print("PASS: interrupted 206 resumes at 65536")
        let engine = MediaRangeDownloader(candidates: [base+"/slow",base+"/reorder"], referer: base)
        let anchor = try MediaByteRange(start: 0,end: 1023)
        await engine.setTrustAnchor(range: anchor, bytes: expected(0,1024))
        let large = try MediaByteRange(start: 0,end: 3*1024*1024-1)
        let bytes = try await engine.fetch(range: large)
        try require(bytes == expected(0,3*1024*1024), "ordered delivery across windows")
        let diagnostic = await engine.diagnostics()
        try require(diagnostic.activeSubrequests == 0 && diagnostic.activeHosts == 0, "no leaked winner/loser requests")
        print("PASS: hedging, ordered delivery, bounded windows, connection cleanup")
        for path in ["/full", "/wrong", "/refused"] {
            let bad = MediaRangeDownloader(candidates:[base+path],referer:base,mode:.proxy)
            var rejected = false
            do { _ = try await bad.fetch(range: range) } catch { rejected = true }
            try require(rejected, "invalid response accepted: \(path)")
        }
        // Direct HTTP mismatches tested above; trust-anchor rejection through one broken candidate
        // plus a valid candidate must recover without splicing the corrupt source.
        let recovery = MediaRangeDownloader(candidates:[base+"/corrupt",base+"/good"],referer:base)
        await recovery.setTrustAnchor(range:anchor,bytes:expected(0,1024))
        let recovered = try await recovery.fetch(range:range)
        try require(recovered == expected(0,524288), "anchor mismatch recovery")
        print("PASS: status/Content-Range validation and anchor mismatch recovery")
        let waiting = MediaRangeDownloader(candidates:[base+"/wait"],referer:base,mode:.proxy)
        let task = Task { try await waiting.fetch(range: range) }
        try await Task.sleep(nanoseconds:100_000_000)
        let started = ProcessInfo.processInfo.systemUptime
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch { cancelled = true }
        try require(cancelled && ProcessInfo.processInfo.systemUptime-started < 2, "cancel must unblock headers")
        let after = await waiting.diagnostics()
        try require(after.activeSubrequests == 0, "cancel leaked permit")
        let moving = BTRPlaybackSession()
        moving.update(position:0,rate:1,advancing:false,intended:true,waiting:true,ahead:0)
        let obsolete = MediaRangeDownloader(candidates:[base+"/wait"],referer:base,mode:.proxy,playback:moving)
        let old = Task { try await obsolete.fetch(range:range) }
        try await Task.sleep(nanoseconds:100_000_000)
        let seekAt = ProcessInfo.processInfo.systemUptime
        moving.update(position:100,rate:1,advancing:false,intended:true,waiting:true,ahead:0,jumped:true)
        var oldRejected=false
        do { _ = try await old.value } catch { oldRejected=true }
        try require(oldRejected && ProcessInfo.processInfo.systemUptime-seekAt < 2, "seek aborts actual URLSession request")
        // A consumer slower than the producer must not deadlock a 64KiB pipe.
        let pipe = MediaBytePipe(capacityBytes:65536)
        let producer = Task { try await pipe.write(expected(0,524288)); pipe.close() }
        let read = try await Task.detached { () throws -> Data in
            var result=Data()
            while let chunk=try pipe.readSync(maxLength:8192,timeout:2) { result.append(chunk) }
            return result
        }.value
        try await producer.value
        try require(read == expected(0,524288), "pipe backpressure")
        print("PASS: cancellation and small-pipe backpressure")
    }
}
