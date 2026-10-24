// Native port of Bilibili-thread-ripper (MIT), commit 49bdfe88e90c78cfa51f7c25de92fffd6cf0924d.
// Copyright (c) 2026 Bilibili-thread-ripper contributors.
// See ThirdParty/BTR/LICENSE and docs/BTR-PORT.md.
import Foundation

struct BTRPolicy {
    var connectionBps = 0.0
    var pieceMs = 0.0
    private var assignTurn = 0
    private var trialWaited = 0
    private var trialCursor = 0

    // idm-downloader.js: recordMeter / adaptiveMinChunk / hedgeDelayMs
    mutating func record(bytes: Int, elapsed: Double) {
        guard bytes >= 48 * 1024, elapsed > 0 else { return }
        let bps = Double(bytes) / elapsed
        connectionBps = connectionBps > 0 ? connectionBps * 0.7 + bps * 0.3 : bps
        pieceMs = pieceMs > 0 ? pieceMs * 0.7 + elapsed * 1000 * 0.3 : elapsed * 1000
    }
    var hedgeDelay: Double { pieceMs > 0 ? max(250, min(900, (pieceMs * 1.5).rounded())) / 1000 : 0.9 }
    func minimumChunk(length: Int64, limit: Int, hosts: Int) -> Int64 {
        guard connectionBps > 0 else { return 64 * 1024 }
        let target = Int64(floor(connectionBps * 0.6 / 65536)) * 65536
        let divisor = Int64(max(1, min(max(4, hosts), limit)))
        let spread = (length + divisor - 1) / divisor
        return max(64 * 1024, min(1024 * 1024, target, spread))
    }
    // range-core.js: splitRange
    static func split(_ range: MediaByteRange, limit: Int, minimum: Int64) -> [MediaByteRange] {
        let minimum = max(32 * 1024, minimum)
        let count = max(1, min(Int64(max(1, min(512, limit))), (range.length + minimum - 1) / minimum))
        let base = range.length / count, remainder = range.length % count
        var cursor = range.start
        return (0..<count).map { index in
            let size = base + (index < remainder ? 1 : 0)
            let result = try! MediaByteRange(start: cursor, end: cursor + size - 1)
            cursor += size
            return result
        }
    }
    // idm-downloader.js: assignPrimaries (smooth weighted round robin + tail trials).
    mutating func assign(_ input: [String], count requested: Int, speed: (String) -> Double) -> [String] {
        guard !input.isEmpty, requested > 0 else { return [] }
        if input.count == 1 { return Array(repeating: input[0], count: requested) }
        let turn = assignTurn
        assignTurn = (assignTurn + 1) % 4096
        var urls = input
        var known = urls.map(speed)
        guard let top = known.filter({ $0 > 0 }).max() else {
            return (0..<requested).map { urls[($0 + turn) % urls.count] }
        }
        urls = urls.enumerated().filter { known[$0.offset] == 0 || known[$0.offset] >= top / 12 }.map(\.element)
        known = urls.map(speed)
        let unknown = urls.enumerated().filter { known[$0.offset] == 0 }.map(\.element)
        var trials = min(unknown.count * 2, requested / 4)
        if trials == 0, !unknown.isEmpty, requested >= 2 {
            trialWaited += 1
            if trialWaited >= 4 { trials = 1 }
        }
        if trials > 0 { trialWaited = 0 }
        if !unknown.isEmpty { urls = urls.enumerated().filter { known[$0.offset] > 0 }.map(\.element) }
        let weights = urls.map { max(speed($0), top * 0.05) }
        let total = weights.reduce(0, +)
        var credit = weights.map { _ in 0.0 }
        let order = urls.indices.map { ($0 + turn) % urls.count }
        var result = [String]()
        for _ in 0..<(requested - trials) {
            var best = order[0]
            for index in order {
                credit[index] += weights[index]
                if credit[index] > credit[best] { best = index }
            }
            credit[best] -= total
            result.append(urls[best])
        }
        for index in 0..<trials { result.append(unknown[(index + trialCursor) % unknown.count]) }
        trialCursor = (trialCursor + trials) % 4096
        return result
    }
}
