//
//  Diag.swift
//  BilibiliLive
//
//  闪退诊断：常驻、落盘、崩溃也不丢的记录。
//
//  - crash.log：致命信号（野指针、Swift 运行时 trap、abort）和未捕获 ObjC 异常的调用栈。
//    信号处理里只用异步信号安全的调用，写完后交还系统默认处理（系统崩溃报告照常生成）。
//  - stderr.log：stderr 重定向到文件，Swift 的 "Fatal error: …" 原因会写在这里。
//  - events.log：关键事件流水（前后台切换、播放器装配/重载、内存占用、主线程卡顿），
//    每条直接 write(2) 落盘，进程被杀也能留下最后一条。
//
//  下次启动时把上一轮的三个文件整理成报告；若上一轮是异常结束，弹窗提示导出。
//  不记录账号、Cookie、带签名的链接。
//

import Darwin
import Foundation
import MachO
import os
import UIKit

// MARK: - 信号处理用的全局状态（信号处理函数里不能分配内存、不能加锁）

private var diagCrashFD: Int32 = -1
private var diagHandlingSignal: Int32 = 0
private let diagFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 256)
private let diagDigits = UnsafeMutablePointer<UInt8>.allocate(capacity: 40)

private func diagWrite(_ text: StaticString) {
    guard diagCrashFD >= 0 else { return }
    _ = Darwin.write(diagCrashFD, text.utf8Start, text.utf8CodeUnitCount)
}

private func diagWriteHex(_ value: UInt) {
    guard diagCrashFD >= 0 else { return }
    var n = value
    var i = 39
    repeat {
        let d = UInt8(n & 0xF)
        diagDigits[i] = d < 10 ? 48 + d : 87 + d
        n >>= 4
        i -= 1
    } while n > 0 && i > 2
    diagDigits[i] = 120 // x
    diagDigits[i - 1] = 48 // 0
    _ = Darwin.write(diagCrashFD, diagDigits + (i - 1), 40 - (i - 1))
}

private func diagWriteInt(_ value: Int32) {
    guard diagCrashFD >= 0 else { return }
    var n = value < 0 ? -Int(value) : Int(value)
    var i = 39
    repeat {
        diagDigits[i] = UInt8(48 + n % 10)
        n /= 10
        i -= 1
    } while n > 0 && i > 1
    _ = Darwin.write(diagCrashFD, diagDigits + (i + 1), 39 - i)
}

private let diagSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { sig, info, context in
    if diagHandlingSignal != 0 {
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }
    diagHandlingSignal = 1
    diagWrite("\n=== FATAL SIGNAL ")
    diagWriteInt(sig)
    switch sig {
    case SIGSEGV: diagWrite(" SIGSEGV")
    case SIGBUS: diagWrite(" SIGBUS")
    case SIGABRT: diagWrite(" SIGABRT")
    case SIGILL: diagWrite(" SIGILL")
    case SIGTRAP: diagWrite(" SIGTRAP (Swift runtime trap / EXC_BREAKPOINT)")
    case SIGFPE: diagWrite(" SIGFPE")
    case SIGSYS: diagWrite(" SIGSYS")
    default: break
    }
    if let info {
        diagWrite(" code=")
        diagWriteInt(info.pointee.si_code)
        diagWrite(" addr=")
        diagWriteHex(UInt(bitPattern: info.pointee.si_addr))
    }
    #if arch(arm64)
        if let context {
            let uc = context.assumingMemoryBound(to: ucontext_t.self)
            if let mc = uc.pointee.uc_mcontext {
                diagWrite(" pc=")
                diagWriteHex(UInt(mc.pointee.__ss.__pc))
                diagWrite(" lr=")
                diagWriteHex(UInt(mc.pointee.__ss.__lr))
            }
        }
    #endif
    if pthread_main_np() != 0 { diagWrite("\nthread: main\n") } else { diagWrite("\nthread: background\n") }
    let count = backtrace(diagFrames, 256)
    if diagCrashFD >= 0 { backtrace_symbols_fd(diagFrames, count, diagCrashFD) }
    diagWrite("=== END\n")
    // 交还系统默认处理，系统崩溃报告照常生成。
    signal(sig, SIG_DFL)
    raise(sig)
}

private let diagExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    guard diagCrashFD >= 0 else { return }
    var text = "\n=== UNCAUGHT EXCEPTION \(exception.name.rawValue)\n"
    text += "reason: \(exception.reason ?? "")\n"
    text += "thread: \(Thread.isMainThread ? "main" : "background")\n"
    text += exception.callStackSymbols.joined(separator: "\n")
    text += "\n=== END\n"
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBufferPointer { Darwin.write(diagCrashFD, $0.baseAddress, $0.count) }
}

// MARK: - Swift 符号还原（调用栈里的 $s… 名字）

@_silgen_name("swift_demangle")
private func diagSwiftDemangle(_ mangledName: UnsafePointer<CChar>?,
                               _ mangledNameLength: UInt,
                               _ outputBuffer: UnsafeMutablePointer<CChar>?,
                               _ outputBufferSize: UnsafeMutablePointer<UInt>?,
                               _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

enum Diag {
    private static let lock = NSLock()
    private static var eventsFD: Int32 = -1
    private static var eventsBytes = 0
    private static let launchUptime = ProcessInfo.processInfo.systemUptime
    private static var observers = [NSObjectProtocol]()
    private static var watchdog: DispatchSourceTimer?
    private static var lastMainPong = ProcessInfo.processInfo.systemUptime
    private static var stallReported = false

    /// 上一轮异常结束的判断（nil = 正常）。
    private(set) static var previousVerdict: String?

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("diag", isDirectory: true)
    }

    private static func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static var buildDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let sha = (info["BTRGitSHA"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(10)) } ?? "local"
        return "\(version) (\(sha))"
    }

    // MARK: 启动

    /// 尽量在启动最早处调用。
    static func setup() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        collectPreviousSession()

        // 本轮文件
        diagCrashFD = open(file("crash.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        let header = "build \(buildDescription)\nlaunched \(ISO8601DateFormatter().string(from: Date()))\n\(imageInfo())\n"
        writeAll(diagCrashFD, header)

        let errFD = open(file("stderr.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if errFD >= 0 {
            setvbuf(stderr, nil, _IONBF, 0)
            dup2(errFD, STDERR_FILENO)
            close(errFD)
        }

        eventsFD = open(file("events.log").path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)

        installCrashHandlers()
        BTRTrace.persistentSink = { mark($0) }
        observeLifecycle()
        startMainThreadWatchdog()
        mark("LAUNCH build=\(buildDescription) tvOS=\(UIDevice.current.systemVersion)")
    }

    private static func installCrashHandlers() {
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE, SIGSYS] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = diagSignalHandler
            action.sa_flags = SA_SIGINFO
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
        NSSetUncaughtExceptionHandler(diagExceptionHandler)
    }

    // MARK: 事件流水

    static func mark(_ text: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - launchUptime
        let line = String(format: "%9.3f %@ mem=%dM avail=%dM | ", elapsed, Thread.isMainThread ? "main" : "bg  ", footprintMB(), availableMB()) + text + "\n"
        lock.lock()
        defer { lock.unlock() }
        guard eventsFD >= 0 else { return }
        if eventsBytes > 6 * 1024 * 1024 {
            // 只保留最近的：文件过大时清空重来。
            ftruncate(eventsFD, 0)
            eventsBytes = 0
            writeAll(eventsFD, "(earlier events dropped)\n")
        }
        eventsBytes += writeAll(eventsFD, line)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ text: String) -> Int {
        guard fd >= 0 else { return 0 }
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    static func availableMB() -> Int {
        Int(os_proc_available_memory() / 1_048_576)
    }

    private static func observeLifecycle() {
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "LIFECYCLE resign-active"),
            (UIApplication.didEnterBackgroundNotification, "LIFECYCLE background"),
            (UIApplication.willEnterForegroundNotification, "LIFECYCLE foreground"),
            (UIApplication.didBecomeActiveNotification, "LIFECYCLE active"),
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING"),
            (UIApplication.willTerminateNotification, "LIFECYCLE terminate"),
        ]
        for (name, text) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                mark(text)
                if name == UIApplication.willEnterForegroundNotification {
                    lastMainPong = ProcessInfo.processInfo.systemUptime
                }
            })
        }
    }

    /// 主线程卡住超过 2 秒时记一笔（系统看门狗会杀掉卡死的 App，这类结束不会有崩溃栈）。
    private static func startMainThreadWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        var lastTick = ProcessInfo.processInfo.systemUptime
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            defer { lastTick = now }
            if now - lastTick > 1.5 {
                // 计时器自己也停过：进程刚从挂起中恢复，不算主线程卡顿。
                lock.lock(); lastMainPong = now; lock.unlock()
                return
            }
            lock.lock()
            let blocked = now - lastMainPong
            let shouldReport = blocked > 2 && !stallReported
            if shouldReport { stallReported = true }
            lock.unlock()
            if shouldReport { mark(String(format: "MAIN THREAD BLOCKED %.1fs", blocked)) }
            DispatchQueue.main.async {
                let pong = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let wasStalled = stallReported
                let duration = pong - lastMainPong
                lastMainPong = pong
                stallReported = false
                lock.unlock()
                if wasStalled { mark(String(format: "main thread recovered after %.1fs", duration)) }
            }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: 上一轮

    private static func read(_ name: String) -> String {
        guard let data = try? Data(contentsOf: file(name)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func tail(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }

    private static func collectPreviousSession() {
        let crash = read("crash.log")
        let errors = read("stderr.log")
        let events = read("events.log")
        guard !events.isEmpty || !crash.isEmpty else { return }

        let verdict = judge(crash: crash, stderr: errors, events: events)
        var report = "#### 上一轮运行：\(verdict ?? "正常结束")\n\n"
        report += "---- crash.log ----\n" + demangle(crash) + "\n"
        let fatal = errors.split(separator: "\n").filter { $0.contains("Fatal error") || $0.contains("fatal error") || $0.contains("Terminating app") || $0.contains("precondition") }
        report += "---- stderr 关键行 ----\n" + fatal.joined(separator: "\n") + "\n"
        report += "---- stderr 末尾 ----\n" + tail(errors, lines: 80) + "\n"
        report += "---- events.log 末尾 ----\n" + tail(events, lines: 600) + "\n"

        try? report.write(to: file("previous.txt"), atomically: true, encoding: .utf8)
        if verdict != nil {
            previousVerdict = verdict
            try? report.write(to: file("last-abnormal.txt"), atomically: true, encoding: .utf8)
        }
    }

    private static func judge(crash: String, stderr: String, events: String) -> String? {
        if crash.contains("=== UNCAUGHT EXCEPTION") { return "闪退（未捕获异常）" }
        if crash.contains("=== FATAL SIGNAL") {
            return stderr.contains("Fatal error") ? "闪退（Swift 运行时错误）" : "闪退（致命信号）"
        }
        if stderr.contains("Fatal error") { return "闪退（Swift 运行时错误）" }
        let lifecycle = events.split(separator: "\n").last { $0.contains("LIFECYCLE") }
        if let lifecycle {
            if lifecycle.contains("LIFECYCLE terminate") { return nil }
            if lifecycle.contains("LIFECYCLE background") || lifecycle.contains("resign-active") {
                return "在后台被系统结束（无崩溃栈：多为内存占用过高被回收，也可能是手动划掉）"
            }
        }
        let lastStall = events.range(of: "MAIN THREAD BLOCKED", options: .backwards)
        let lastRecover = events.range(of: "main thread recovered", options: .backwards)
        if let lastStall, lastRecover.map({ $0.lowerBound < lastStall.lowerBound }) ?? true {
            return "前台被系统结束（无崩溃栈：主线程卡死被看门狗杀掉的可能性大）"
        }
        return "前台被系统结束（无崩溃栈：可能是内存超限或看门狗）"
    }

    // MARK: 导出

    static func exportText() -> String {
        var text = "BilibiliLive 诊断报告\n生成于 \(ISO8601DateFormatter().string(from: Date()))\n当前 build \(buildDescription)\n\(imageInfo())\n\n"
        let abnormal = read("last-abnormal.txt")
        if !abnormal.isEmpty {
            text += "======== 最近一次异常结束 ========\n" + abnormal + "\n\n"
        }
        let previous = read("previous.txt")
        if !previous.isEmpty, previous != abnormal {
            text += "======== 上一轮运行 ========\n" + previous + "\n\n"
        }
        text += "======== 本轮运行 ========\n"
        text += "---- crash.log ----\n" + demangle(read("crash.log")) + "\n"
        text += "---- events.log 末尾 ----\n" + tail(read("events.log"), lines: 400) + "\n\n"
        text += "======== 应用日志末尾 ========\n"
        for path in Logger.logFilePaths.prefix(2).reversed() {
            if let data = FileManager.default.contents(atPath: path) {
                text += "---- \((path as NSString).lastPathComponent) ----\n" + tail(String(decoding: data, as: UTF8.self), lines: 300) + "\n"
            }
        }
        return text
    }

    /// 导出后不再重复提示同一次异常。
    static func clearAbnormalNotice() {
        previousVerdict = nil
    }

    private static func demangle(_ text: String) -> String {
        guard text.contains("$s") || text.contains("_T0") else { return text }
        var result = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var parts = [String]()
            for token in line.split(separator: " ", omittingEmptySubsequences: false) {
                let raw = String(token)
                let candidate = raw.hasPrefix("_$s") ? String(raw.dropFirst()) : raw
                if candidate.hasPrefix("$s"), let readable = demangleSymbol(candidate) {
                    parts.append(readable)
                } else {
                    parts.append(raw)
                }
            }
            result += parts.joined(separator: " ") + "\n"
        }
        return result
    }

    private static func demangleSymbol(_ name: String) -> String? {
        name.withCString { pointer -> String? in
            guard let output = diagSwiftDemangle(pointer, UInt(strlen(pointer)), nil, nil, 0) else { return nil }
            defer { free(output) }
            return String(cString: output)
        }
    }

    /// 主程序的加载地址和 UUID，没有符号时可以用 dSYM 手动还原地址。
    private static func imageInfo() -> String {
        guard let header = _dyld_get_image_header(0) else { return "image: ?" }
        let slide = _dyld_get_image_vmaddr_slide(0)
        var uuid = "?"
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == LC_UUID {
                uuid = UUID(uuid: cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
                break
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        let name = (String(cString: _dyld_get_image_name(0)) as NSString).lastPathComponent
        return String(format: "image: %@ uuid=%@ base=0x%lx slide=0x%lx", name, uuid, UInt(bitPattern: header), slide)
    }
}

// MARK: - 导出界面

extension Diag {
    /// 启动后若上一轮是异常结束，提示一次并可直接导出。
    static func presentAbnormalNoticeIfNeeded() {
        guard let verdict = previousVerdict,
              let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }).first?.rootViewController
        else { return }
        clearAbnormalNotice()
        let top = root.topMostViewController()
        let alert = UIAlertController(title: "上次 App 异常退出",
                                      message: "\(verdict)\n\n已自动保存诊断记录，可以现在导出发给开发者，也可以稍后在 设置 › 闪退诊断日志 里导出。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "导出诊断日志", style: .default) { _ in
            presentExport(from: top)
        })
        alert.addAction(UIAlertAction(title: "稍后", style: .cancel))
        top.present(alert, animated: true)
    }

    static func presentExport(from presenter: UIViewController) {
        let message: String
        do {
            let address = try BTRTraceExport.shared.startDiagnostics()
            message = address + "\n\n用同一网络下的电脑或手机浏览器打开这个地址，保存 bili-diag.txt 后发到聊天。下载完成前请让本 App 保持在前台。"
        } catch {
            message = "本地下载服务启动失败（错误码 \((error as NSError).code)）。"
        }
        let alert = UIAlertController(title: "导出诊断日志", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        presenter.present(alert, animated: true)
    }
}

extension Diag {
    /// 简短的对象标识，用来在流水里区分新旧播放器 / 代理。
    static func id(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFFF, radix: 16)
    }
}
