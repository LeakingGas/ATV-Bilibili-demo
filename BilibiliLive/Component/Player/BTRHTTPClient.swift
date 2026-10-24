// Native URLSession adapter for BTR attempt/readBody. See ThirdParty/BTR/LICENSE.
import Foundation

final class BTRProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

// Each attempt has one terminal continuation and an independently cancellable task.
// Delegate chunks avoid per-byte actor hops and make validated partial data resumable.
final class BTRHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer: @unchecked Sendable {
        let range: MediaByteRange
        let progress: BTRProgress
        let knownTotal: Int64?
        var total: Int64?
        var validated = false
        var error: Error?
        var completion: CheckedContinuation<Int64?, Error>?
        var epochTimer: DispatchSourceTimer?
        var isCurrent: @Sendable () -> Bool = { true }
        var onProgress: @Sendable () -> Void = {}
        var idleGeneration = 0
        var idleTimer: DispatchWorkItem?
        var totalTimer: DispatchWorkItem?
        init(_ range: MediaByteRange, _ progress: BTRProgress, _ knownTotal: Int64?) {
            self.range = range; self.progress = progress; self.knownTotal = knownTotal
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func install(_ task: URLSessionTask) {
            lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
            if stop { task.cancel() }
        }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    }
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var transfers = [Int: Transfer]()
    private var session: URLSession!
    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 8
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }
    func invalidate() { session.invalidateAndCancel() }
    private func lookup(_ task: URLSessionTask) -> Transfer? {
        lock.lock(); defer { lock.unlock() }; return transfers[task.taskIdentifier]
    }
    private func register(_ transfer: Transfer, task: URLSessionTask) {
        lock.lock(); transfers[task.taskIdentifier] = transfer; lock.unlock()
    }
    // Timer work is serialized with data/completion callbacks on the delegate queue.
    private func timer(_ seconds: Double, task: URLSessionTask, generation: Int? = nil) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self, weak task] in
            guard let self, let task else { return }
            self.queue.addOperation {
                guard let state = self.lookup(task) else { return }
                if let generation, state.idleGeneration != generation { return }
                state.error = URLError(.timedOut)
                task.cancel()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
    func fetch(_ request: URLRequest, range: MediaByteRange, progress: BTRProgress, knownTotal: Int64?, isCurrent: @escaping @Sendable () -> Bool = { true }, onProgress: @escaping @Sendable () -> Void = {}) async throws -> Int64? {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let state = Transfer(range, progress, knownTotal)
                state.completion = continuation
                state.isCurrent = isCurrent; state.onProgress = onProgress
                let task = session.dataTask(with: request)
                register(state, task: task)
                queue.addOperation {
                    state.idleTimer = self.timer(5.5, task: task, generation: state.idleGeneration)
                    state.totalTimer = self.timer(15, task: task)
                    let watcher = DispatchSource.makeTimerSource(queue: .global())
                    watcher.schedule(deadline: .now(), repeating: .milliseconds(50))
                    watcher.setEventHandler { [weak self, weak task] in
                        guard let self, let task else { return }
                        self.queue.addOperation {
                            guard let transfer = self.lookup(task), !transfer.isCurrent() else { return }
                            transfer.error = CancellationError(); task.cancel()
                        }
                    }
                    state.epochTimer = watcher; watcher.resume()
                    task.resume()
                    cancellation.install(task)
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = lookup(dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        state.idleTimer?.cancel()
        state.idleGeneration += 1
        if http.statusCode != 206 { state.error = MediaRangeError.upstream(status: http.statusCode) }
        else if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" { state.error = MediaRangeError.mismatch }
        else if let value = http.value(forHTTPHeaderField: "Content-Range"),
                let parsed = MediaRangeParsing.parseContentRange(value), parsed.range == state.range,
                parsed.total.map({ $0 > state.range.end }) ?? true,
                state.knownTotal == nil || parsed.total == state.knownTotal {
            state.total = parsed.total
            state.validated = true
        } else { state.error = MediaRangeError.mismatch }
        if state.error != nil { completionHandler(.cancel); return }
        state.idleTimer = timer(4, task: dataTask, generation: state.idleGeneration)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = lookup(dataTask), state.validated, state.error == nil else { return }
        state.idleTimer?.cancel()
        state.idleGeneration += 1
        if Int64(state.progress.snapshot().count + data.count) > state.range.length {
            state.error = MediaRangeError.mismatch; dataTask.cancel(); return
        }
        state.progress.append(data)
        state.onProgress()
        state.idleTimer = timer(4, task: dataTask, generation: state.idleGeneration)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let state = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let state else { return }
        state.idleTimer?.cancel(); state.totalTimer?.cancel(); state.epochTimer?.cancel()
        if let failure = state.error ?? error { state.completion?.resume(throwing: failure) }
        else if !state.validated || Int64(state.progress.snapshot().count) != state.range.length {
            state.completion?.resume(throwing: MediaRangeError.truncated)
        } else { state.completion?.resume(returning: state.total) }
        state.completion = nil
    }
}
