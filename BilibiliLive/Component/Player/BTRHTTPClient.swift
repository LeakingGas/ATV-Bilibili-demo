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
        let traceID = UUID().uuidString
        let parent = BTRTrace.requestID
        let started = BTRTrace.now
        var lastProgress = -Double.infinity
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
    /// App-wide client: one connection pool for every track and video (see MediaRangeDownloader).
    static let shared = BTRHTTPClient()
    private var lastPreconnect = [String: Double]()
    /// BTR preconnectCdnNodes: open connections to the nodes before any media is asked for, so the
    /// first pieces skip the TCP+TLS handshake (~0.6 s to the mainland). Two per host for HTTP/1.1.
    func preconnect(hosts: [String]) {
        let now = BTRTrace.now
        lock.lock()
        let due = hosts.filter { now - (lastPreconnect[$0] ?? -.infinity) > 15000 }
        for host in due { lastPreconnect[host] = now }
        lock.unlock()
        guard !due.isEmpty else { return }
        BTRTrace.shared.event("preconnect",["hosts":due.count])
        for host in due {
            guard let url = URL(string: "https://\(host)/") else { continue }
            for _ in 0..<2 {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.timeoutInterval = 5
                request.setValue(Keys.userAgent, forHTTPHeaderField: "User-Agent")
                session.dataTask(with: request).resume()
            }
        }
    }
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
    private func trace(_ state: Transfer, _ event: String, _ fields: [String: Any] = [:]) {
        BTRTrace.shared.event(event, fields.merging(["attempt":state.traceID,"request":state.parent,
            "start":state.range.start,"end":state.range.end]) { _,new in new })
    }
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
                self.trace(state,"http_timeout",["timer":generation == nil ? "total" : "idle-or-headers","bytes":state.progress.snapshot().count,"elapsedMs":BTRTrace.now-state.started])
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
                trace(state,"http_begin",["host":request.url?.host ?? ""])
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
            // A preconnect HEAD has no body: letting it finish keeps its connection in the pool.
            completionHandler(dataTask.originalRequest?.httpMethod == "HEAD" ? .allow : .cancel); return
        }
        trace(state,"http_headers",["status":http.statusCode,"elapsedMs":BTRTrace.now-state.started])
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
        if state.error != nil { trace(state,"http_rejected"); completionHandler(.cancel); return }
        trace(state,"http_validated",["total":state.total ?? -1])
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
        let first = state.progress.snapshot().isEmpty
        state.progress.append(data)
        if first || BTRTrace.now-state.lastProgress >= 1000 {
            state.lastProgress = BTRTrace.now
            trace(state,first ? "http_first_byte" : "http_progress",["bytes":state.progress.snapshot().count,"elapsedMs":BTRTrace.now-state.started])
        }
        state.onProgress()
        state.idleTimer = timer(4, task: dataTask, generation: state.idleGeneration)
    }
    // Which protocol carried a request and whether it reused an open connection (no secrets logged).
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        var fields: [String: Any] = ["host":task.originalRequest?.url?.host ?? "","proto":last.networkProtocolName ?? "?",
            "reused":last.isReusedConnection,"method":task.originalRequest?.httpMethod ?? ""]
        if let start = last.connectStartDate, let end = last.secureConnectionEndDate ?? last.connectEndDate {
            fields["connectMs"] = end.timeIntervalSince(start) * 1000
        }
        if let start = last.fetchStartDate, let first = last.responseStartDate {
            fields["firstByteMs"] = first.timeIntervalSince(start) * 1000
        }
        BTRTrace.shared.event("http_metrics", fields)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let state = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let state else { return }
        state.idleTimer?.cancel(); state.totalTimer?.cancel(); state.epochTimer?.cancel()
        var result: [String:Any] = ["bytes":state.progress.snapshot().count,"elapsedMs":BTRTrace.now-state.started]
        if let failure = state.error ?? error { result.merge(BTRTrace.errorFields(failure)) { _,new in new } }
        result["completeBody"] = state.validated && Int64(state.progress.snapshot().count) == state.range.length
        trace(state,"http_end",result)
        if let failure = state.error ?? error { state.completion?.resume(throwing: failure) }
        else if !state.validated || Int64(state.progress.snapshot().count) != state.range.length {
            state.completion?.resume(throwing: MediaRangeError.truncated)
        } else { state.completion?.resume(returning: state.total) }
        state.completion = nil
    }
}
