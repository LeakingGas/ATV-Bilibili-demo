//
//  BiliBiliUpnpDMR.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/11/25.
//

import CocoaAsyncSocket
import CoreMedia
import Foundation
import Swifter
import SwiftyJSON
import UIKit

class BiliBiliUpnpDMR: NSObject {
    static let shared = BiliBiliUpnpDMR()

    private let ssdpHost = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900
    private let httpPort: in_port_t = 9958
    private let mockServerName = "Linux/3.0.0, UPnP/1.0, Platinum/1.0.5.13"

    private let udpQueue = DispatchQueue(label: "com.bilibili.upnp.udp")

    weak var currentPlugin: BUpnpPlugin?

    private var udp: GCDAsyncUdpSocket?
    private var httpServer = HttpServer()
    private var connectedSockets = [GCDAsyncSocket]()
    @MainActor private var sessions = Set<NVASession>()
    private var started = false
    private var ip: String?
    private var boardcastTimer: Timer?

    private lazy var serverInfo: String = {
        let file = Bundle.main.url(forResource: "DLNAInfo", withExtension: "xml")!
        return try! String(contentsOf: file).replacingOccurrences(of: "{{UUID}}", with: bUuid)
    }()

    private lazy var nirvanaControl: String = {
        let file = Bundle.main.url(forResource: "NirvanaControl", withExtension: "xml")!
        return try! String(contentsOf: file)
    }()

    private lazy var avTransportScpd: String = {
        let file = Bundle.main.url(forResource: "AvTransportScpd", withExtension: "xml")!
        return try! String(contentsOf: file)
    }()

    private lazy var bUuid: String = {
        if Settings.uuid.count > 0 {
            return Settings.uuid
        }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var randomString = ""
        for _ in 0..<35 {
            let rand = arc4random_uniform(36)
            let nextChar = letters[letters.index(letters.startIndex, offsetBy: Int(rand))]
            randomString.append(nextChar)
        }
        Settings.uuid = randomString
        return randomString
    }()

    override private init() { super.init() }
    func start() {
        if !handlersInstalled {
            handlersInstalled = true
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
            installHTTPHandlers()
        }
        startIfNeed(reason: "start")
    }

    private var handlersInstalled = false

    private func installHTTPHandlers() {
        httpServer["/description.xml"] = { [weak self] req in
            Logger.debug("handel serverInfo")
            let agent = req.headers["user-agent"] ?? "-"
            Diag.dlna("description fetched by \(req.address ?? "?") ua=\(agent)")
            DispatchQueue.main.async { self?.lastDescriptionFetchAt = Date() }
            return HttpResponse.ok(.text(self?.serverInfo ?? ""))
        }

        httpServer["/projection"] = nvasocket(uuid: bUuid, didConnect: { [weak self] session in
            Logger.info("session connected \(session)")
            Diag.dlna("cast session connected")
            DispatchQueue.main.async {
                self?.sessions.insert(session)
            }
        }, didDisconnect: { [weak self] session in
            Logger.info("session disconnect \(session)")
            Diag.dlna("cast session disconnected")
            DispatchQueue.main.async {
                self?.sessions.remove(session)
            }
        }, processor: { [weak self] session, frame in
            DispatchQueue.main.async {
                self?.handleEvent(frame: frame, session: session)
            }
        })

        httpServer["/dlna/NirvanaControl.xml"] = {
            [weak self] req in
            Logger.debug("handle NirvanaControl")
            let txt = self?.nirvanaControl ?? ""
            return HttpResponse.ok(.text(txt))
        }

        httpServer.get["/dlna/AVTransport.xml"] = {
            [weak self] req in
            Logger.debug("handle AVTransport.xml")
            let txt = self?.avTransportScpd ?? ""
            return HttpResponse.ok(.text(txt))
        }

        httpServer.post["/AVTransport/action"] = {
            req in
            let str = String(data: Data(req.body), encoding: .utf8) ?? ""
            Logger.debug("handle AVTransport.xml \(str)")
            return HttpResponse.ok(.text(str))
        }

        httpServer["/AVTransport/event"] = {
            req in
            return HttpResponse.internalServerError(nil)
        }

        httpServer["/debug/log"] = {
            req in
            if let path = Logger.latestLogPath(),
               let str = try? String(contentsOf: URL(fileURLWithPath: path))
            {
                return HttpResponse.ok(.text(str))
            }
            return HttpResponse.internalServerError(nil)
        }
    }

    // MARK: - 状态（设置里显示）

    /// 1900 端口是否抢到（抢到才能听见手机的搜索）。
    private(set) var ssdpBound = false
    private var bindError: String?
    private(set) var lastSearchAt: Date?
    private var lastDescriptionFetchAt: Date?
    private var searchesSinceHeartbeat = 0
    private var notifyFailures = 0
    private var heartbeatAt = Date()
    private var rebindAt = Date.distantPast
    /// 同一来源同一类型的搜索 30 秒内只记一行，其余计数。
    private var searchLogAt = [String: (at: Date, suppressed: Int)]()

    /// 设置「投屏」一行右侧的文字。
    var statusText: String {
        guard Settings.enableDLNA else { return "关" }
        guard started else { return "启动失败" }
        guard ssdpBound else { return "1900 端口被占用" }
        guard let lastSearchAt else { return "正常 · 还没收到搜索" }
        let seconds = Int(Date().timeIntervalSince(lastSearchAt))
        let ago = seconds < 60 ? "刚刚" : seconds < 3600 ? "\(seconds / 60) 分钟前" : "\(seconds / 3600) 小时前"
        return "正常 · \(ago)收到搜索"
    }

    func stop() {
        stop(reason: "stop")
    }

    private func stop(reason: String) {
        if started || udp != nil { Diag.dlna("stop (\(reason))") }
        boardcastTimer?.invalidate()
        boardcastTimer = nil
        udp?.close()
        udp = nil
        ssdpBound = false
        httpServer.stop()
        started = false
        Logger.info("dmr stopped")
    }

    @objc func didEnterBackground() {
        stop(reason: "background")
    }

    @objc func willEnterForeground() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startIfNeed(reason: "foreground")
        }
    }

    private func startIfNeed(reason: String) {
        stop(reason: "restart")
        guard Settings.enableDLNA else {
            Diag.dlna("disabled in settings (\(reason))")
            return
        }
        ip = getIPAddress()
        Diag.dlna("start (\(reason)) ip=\(ip ?? "nil") interfaces=\(interfaceSummary()) uuid=\(bUuid.prefix(6))")
        do {
            try httpServer.start(httpPort)
        } catch {
            started = false
            Logger.warn("dmr start fail: \(error.localizedDescription).")
            Diag.dlna("http server on \(httpPort) FAILED: \(error)")
            return
        }
        started = true
        openSSDPSocket()
        Logger.info("dmr started, http: \(httpPort), ssdp: \(ssdpPort) bound=\(ssdpBound)")
        heartbeatAt = Date()
        searchesSinceHeartbeat = 0
        boardcastTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            self?.tick()
        }
    }

    /// 开 1900 端口；每一步失败都记下来（以前失败了也不知道）。
    private func openSSDPSocket() {
        udp?.close()
        let socket = GCDAsyncUdpSocket(delegate: self, delegateQueue: udpQueue)
        udp = socket
        var steps = [String]()
        do { try socket.enableBroadcast(true) } catch { steps.append("broadcast: \(error)") }
        do { try socket.enableReusePort(true) } catch { steps.append("reusePort: \(error)") }
        var bound = true
        do { try socket.bind(toPort: ssdpPort) } catch {
            bound = false
            steps.append("bind 1900: \(error)")
        }
        if bound {
            do { try socket.joinMulticastGroup(ssdpHost) } catch { steps.append("joinMulticast: \(error)") }
            do { try socket.beginReceiving() } catch {
                bound = false
                steps.append("beginReceiving: \(error)")
            }
        }
        ssdpBound = bound
        bindError = steps.isEmpty ? nil : steps.joined(separator: "; ")
        Diag.dlna("ssdp socket " + (bound ? "OK" : "NOT LISTENING") + (steps.isEmpty ? "" : " — " + steps.joined(separator: "; ")))
    }

    private func tick() {
        guard started else { return }
        // IP 可能变（重新获取地址、换网）：每秒重新取，变了记一笔。
        let current = getIPAddress()
        if current != ip {
            Diag.dlna("ip changed \(ip ?? "nil") -> \(current ?? "nil")")
            ip = current
        }
        // 没抢到 1900：每 10 秒再试一次（占着端口的 App 可能已经退了）。
        if !ssdpBound, Date().timeIntervalSince(rebindAt) > 10 {
            rebindAt = Date()
            openSSDPSocket()
        }
        if Date().timeIntervalSince(heartbeatAt) > 300 {
            Diag.dlna("alive ip=\(ip ?? "nil") listening=\(ssdpBound) searches(5min)=\(searchesSinceHeartbeat) notifyFailures=\(notifyFailures)")
            heartbeatAt = Date()
            searchesSinceHeartbeat = 0
            notifyFailures = 0
        }
        guard let notify = getSSDPNotify(), let data = notify.data(using: .utf8) else { return }
        udp?.send(data, toHost: ssdpHost, port: ssdpPort, withTimeout: 1, tag: 0)
    }

    private func interfaceSummary() -> String {
        var result = [String]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "?" }
        var ptr = ifaddr
        while let interface = ptr?.pointee {
            defer { ptr = interface.ifa_next }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            result.append(String(cString: interface.ifa_name) + "=" + String(cString: hostname))
        }
        freeifaddrs(ifaddr)
        return result.joined(separator: ",")
    }

    private func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { return "" }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name == "en2" || name == "en3" || name == "en4" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        if name == "en0" {
                            break
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func getSSDPResp() -> String {
        guard let ip = ip ?? getIPAddress() else {
            Logger.debug("no ip")
            return ""
        }

        return """
        HTTP/1.1 200 OK
        LOCATION: http://\(ip):\(httpPort)/description.xml
        CACHE-CONTROL: max-age=30
        SERVER: \(mockServerName)
        EXT:
        BOOTID.UPNP.ORG: 1669443520
        CONFIGID.UPNP.ORG: 10177363
        USN: uuid:atvbilibili&\(bUuid)::upnp:rootdevice
        ST: upnp:rootdevice
        DATE: \(ssdpDateString())

        """
    }

    private func getSSDPNotify() -> String? {
        guard let ip = ip ?? getIPAddress() else {
            Logger.debug("no ip")
            return nil
        }
        let text = """
        NOTIFY * HTTP/1.1
        Host: \(ssdpHost):\(ssdpPort)
        Location: http://\(ip):9958/description.xml
        Cache-Control: max-age=30
        Server: \(mockServerName)
        NTS: ssdp:alive
        USN: uuid:\(bUuid)::urn:schemas-upnp-org:device:MediaRenderer:1
        NT: urn:schemas-upnp-org:device:MediaRenderer:1

        """
        return text
    }

    private func ssdpDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    func handleEvent(frame: NVASession.NVAFrame, session: NVASession) {
        let topMost = UIViewController.topMostViewController()
        if frame.action != "GetVolume" { Diag.dlna("cast action \(frame.action)") }
        switch frame.action {
        case "GetVolume":
            session.sendReply(content: ["volume": 30])
        case "Play":
            handlePlay(json: JSON(parseJSON: frame.body))
            session.sendEmpty()
        case "Pause":
            currentPlugin?.pause()
            session.sendEmpty()
        case "Resume":
            currentPlugin?.resume()
            session.sendEmpty()
        case "SwitchDanmaku":
            let json = JSON(parseJSON: frame.body)
            Defaults.shared.showDanmu = json["open"].boolValue
            session.sendEmpty()
        case "Seek":
            let json = JSON(parseJSON: frame.body)
            currentPlugin?.seek(to: json["seekTs"].doubleValue)
            session.sendEmpty()
        case "Stop":
            (topMost as? CommonPlayerViewController)?.dismiss(animated: true)
            session.sendEmpty()
        case "PlayUrl":
            let json = JSON(parseJSON: frame.body)
            session.sendEmpty()
            guard let url = json["url"].url,
                  let extStr = URLComponents(string: url.absoluteString)?.queryItems?
                  .first(where: { $0.name == "nva_ext" })?.value
            else {
                Logger.warn("get play url: \(frame.body)")
                return
            }
            let ext = JSON(parseJSON: extStr)
            handlePlay(json: ext["content"])
        default:
            Logger.debug("action: \(frame.action)")
            session.sendEmpty()
        }
    }

    func handlePlay(json: JSON) {
        let roomId = json["roomId"].stringValue
        if roomId.count > 0, let room = Int(roomId), room > 0 {
            playLive(roomID: room)
        } else {
            playVideo(json: json)
        }
    }

    enum PlayStatus: Int {
        case loading = 3
        case playing = 4
        case paused = 5
        case end = 6
        case stop = 7
    }

    @MainActor func sendStatus(status: PlayStatus) {
        Logger.debug("send status: \(status)")
        Array(sessions).forEach { $0.sendCommand(action: "OnPlayState", content: ["playState": status.rawValue]) }
    }

    @MainActor func sendProgress(duration: Int, current: Int) {
        Array(sessions).forEach { $0.sendCommand(action: "OnProgress", content: ["duration": duration, "position": current]) }
    }

    func sendVideoSwitch(aid: Int, cid: Int) {
        /* this might cause client disconnect for unkown reason
         let playItem = ["aid": aid, "cid": cid, "contentType": 0, "epId": 0, "seasonId": 0, "roomId": 0] as [String: Any]
         let mockQnDesc = ["curQn": 0,
                           "supportQnList": [
                               [
                                   "description": "",
                                   "displayDesc": "",
                                   "needLogin": false,
                                   "needVip": false,
                                   "quality": 0,
                                   "superscript": "",
                               ],
                           ],
                           "userDesireQn": 0] as [String: Any]
         let data = ["playItem": playItem, "qnDesc": mockQnDesc, "title": "null"] as [String: Any]
         Array(sessions).forEach { $0.sendCommand(action: "OnEpisodeSwitch", content: data) }
          */
    }
}

extension BiliBiliUpnpDMR {
    func playLive(roomID: Int) {
        let player = LivePlayerViewController()
        player.room = LiveRoom(title: "", room_id: roomID, uname: "", area_v2_name: "", keyframe: nil, face: nil, cover_from_user: nil)
        UIViewController.topMostViewController().present(player, animated: true)
    }

    func playVideo(json: JSON) {
        let aid = json["aid"].intValue
        let cid = json["cid"].intValue
        let epid = json["epid"].intValue

        // 投屏直接开播，不弹「继续 / 从头」询问（进度由手机端控制）。
        let info = epid > 0 ? PlayInfo(aid: 0, cid: 0, epid: epid) : PlayInfo(aid: aid, cid: cid)
        if let _ = AppDelegate.shared.window!.rootViewController?.presentedViewController {
            AppDelegate.shared.window!.rootViewController?.dismiss(animated: false) {
                VideoLauncher.play(info, askResume: false)
            }
        } else {
            VideoLauncher.play(info, askResume: false)
        }
    }
}

extension BiliBiliUpnpDMR: GCDAsyncUdpSocketDelegate {
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        address.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            let sockaddrPtr = pointer.bindMemory(to: sockaddr.self)
            guard let unsafePtr = sockaddrPtr.baseAddress else { return }
            guard getnameinfo(unsafePtr, socklen_t(address.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else {
                return
            }
        }
        var ipAddress = String(cString: hostname)
        ipAddress = ipAddress.replacingOccurrences(of: "::ffff:", with: "")
        let str = String(data: data, encoding: .utf8)
        if str?.contains("ssdp:discover") == true {
            Logger.debug("handle ssdp discover from: \(ipAddress)")
            let headers = Self.headers(str ?? "")
            logSearch(from: ipAddress, st: headers["st"] ?? "-", mx: headers["mx"] ?? "-", agent: headers["user-agent"] ?? "-")
            let response = getSSDPResp()
            guard !response.isEmpty, let data = response.data(using: .utf8) else {
                Diag.dlna("  no reply: no ip address")
                return
            }
            sock.send(data, toAddress: address, withTimeout: -1, tag: 1)
        }
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didNotSendDataWithTag tag: Int, dueToError error: Error?) {
        if tag == 1 {
            Diag.dlna("  reply send FAILED: \(String(describing: error))")
            return
        }
        DispatchQueue.main.async {
            self.notifyFailures += 1
            if self.notifyFailures == 1 { Diag.dlna("notify send FAILED: \(String(describing: error))") }
        }
    }

    func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        guard let error else { return }
        Diag.dlna("ssdp socket closed with error: \(error)")
    }

    private func logSearch(from ip: String, st: String, mx: String, agent: String) {
        DispatchQueue.main.async {
            self.lastSearchAt = Date()
            self.searchesSinceHeartbeat += 1
            let key = ip + "|" + st
            if let previous = self.searchLogAt[key], Date().timeIntervalSince(previous.at) < 30 {
                self.searchLogAt[key] = (previous.at, previous.suppressed + 1)
                return
            }
            let suppressed = self.searchLogAt[key]?.suppressed ?? 0
            self.searchLogAt[key] = (Date(), 0)
            Diag.dlna("search from \(ip) st=\(st) mx=\(mx) ua=\(agent)" + (suppressed > 0 ? " (+\(suppressed) earlier)" : "") + " -> replied")
        }
    }

    private static func headers(_ text: String) -> [String: String] {
        var result = [String: String]()
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}
