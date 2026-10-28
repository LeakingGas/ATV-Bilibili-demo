//
//  VLCRendererPlugin.swift
//  BilibiliLive
//
//  VLC 模式：界面和操作完全是系统播放器的。系统播放器播一路静音的低码率「影子」视频
//  （BVideoPlayPlugin 的 shadowStreamIndex），只提供时间轴、控制栏和拖动预览；
//  真正的画面和声音由这里的 VLC 输出，画面叠在系统播放器的画面层上、控制栏下面。
//
//  同步规则（影子播放器是「主时钟」，用户的所有操作都作用在它上面）：
//  - 主时钟播放 / 暂停 / 倍速 → VLC 跟着做。
//  - 主时钟被拖动、快进快退（和 VLC 差 3 秒以上）→ VLC 跳到同一位置。
//  - VLC 还没出画面、在缓冲或落后 → 把主时钟调到极低速率「等」VLC（界面上仍是播放中，不会出现暂停图标），
//    VLC 跟上后恢复。VLC 超前 → VLC 暂停一下等主时钟。
//

import AVKit
import TVVLCKit
import UIKit

final class VLCRendererPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

    private let vlc = VLCMediaPlayer()
    private let videoView = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private weak var playerVC: AVPlayerViewController?
    private weak var master: AVPlayer?
    private var rateObservation: NSKeyValueObservation?

    private var delegate: BilibiliVideoResourceLoaderDelegate?
    private var retiredDelegates = [BilibiliVideoResourceLoaderDelegate]()
    private var playData: PlayerDetailData
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var lastMaxQuality: Int?
    private var lastStreamIndex: Int?
    private var syncTimer: Timer?
    private var lifecycleObservers = [NSObjectProtocol]()
    private var backgroundPosition: Double?
    private var cdnProbeReport = ""
    private var isProbingCDN = false

    // 同步状态
    /// 用户选择的倍速（主时钟上不是我们设的、>= 0.1 的速率）。
    private var userRate: Float = 1
    /// 我们正在改主时钟的速率（KVO 里据此区分用户操作）。
    private var settingMasterRate = false
    private var holdingMaster = false
    private var vlcHeldAhead = false
    private var mediaLoaded = false
    private var lastVLCTimeMs: Int32 = -1
    private var lastVLCAdvanceAt = Date.distantPast
    private var vlcSeekPending: (target: Double, at: Date)?
    private var markedPlaying = false
    private var syncLogAt = Date.distantPast

    /// 主时钟等待 VLC 时的速率：时间几乎不走，但系统界面仍显示「播放中」。
    private static let holdRate: Float = 0.0001

    init(detailData: PlayerDetailData) {
        playData = detailData
        super.init()
        vlc.delegate = self
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleEnterBackground()
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleEnterForeground()
            },
        ]
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        syncTimer?.invalidate()
        delegate?.btrPlayback.invalidate()
        vlc.delegate = nil
        vlc.stop()
        Diag.mark("VLCR deinit")
    }

    /// 当前实际播放的视频流（画质菜单勾选当前项）。
    var currentMedia: VideoPlayURLInfo.DashInfo.DashMediaInfo? { delegate?.primaryMedia }

    var networkDebugInfo: String {
        var lines = ["engine: VLC (system UI + shadow clock)"]
        let names: [VLCMediaPlayerState: String] = [.stopped: "stopped", .opening: "opening", .buffering: "buffering",
                                                    .ended: "ended", .error: "error", .playing: "playing", .paused: "paused"]
        lines.append("VLC state: \(names[vlc.state] ?? "\(vlc.state.rawValue)") time:\(String(format: "%.1f", vlcTime)) master:\(String(format: "%.1f", masterTime)) hold:\(holdingMaster) ahead:\(vlcHeldAhead)")
        if let session = delegate?.btrPlayback { lines.append("BTR\n" + session.debug) }
        if let media = delegate?.primaryVideoDescription, !media.isEmpty { lines.append("stream: " + media) }
        if !cdnProbeReport.isEmpty { lines.append(cdnProbeReport) }
        return lines.joined(separator: "\n")
    }

    // MARK: - 插件回调

    func addViewToPlayerOverlay(container: UIView) {
        // 系统播放器画面层之上、弹幕和控制栏之下。
        container.insertSubview(videoView, at: 0)
        videoView.snp.makeConstraints { $0.edges.equalToSuperview() }
        spinner.color = .white
        spinner.hidesWhenStopped = true
        videoView.addSubview(spinner)
        spinner.snp.makeConstraints { $0.center.equalToSuperview() }
        spinner.startAnimating()
        vlc.drawable = videoView
    }

    func playerDidLoad(host: PlayerHost) {
        playerVC = host.avPlayerViewController
        Diag.startupStep("player_engine", ["kind": "VLC"])
        (host.hostViewController.parent as? CommonPlayerViewController)?.setPictureInPictureAllowed(false)
        userRate = Settings.mediaPlayerSpeed.value
        let start = playData.playerStartPos.map { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
        startLoad(at: start, maxQuality: nil, streamIndex: nil)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.sync() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    func playerDidChange(engine: PlayerEngine) {
        guard let player = engine.avPlayer else { return }
        master = player
        holdingMaster = false
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            // KVO 在设置速率的线程上同步回调：这里就判断是不是我们自己改的（不算用户操作）。
            guard let self, !self.settingMasterRate else { return }
            let rate = player.rate
            DispatchQueue.main.async { self.masterRateChanged(rate) }
        }
    }

    func playerDidCleanUp(engine: PlayerEngine) {
        guard let player = engine.avPlayer, player === master else { return }
        rateObservation = nil
        master = nil
    }

    func playerWillCleanUp(host: PlayerHost) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        syncTimer?.invalidate()
        syncTimer = nil
        rateObservation = nil
        vlc.stop()
        delegate?.btrPlayback.invalidate()
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let action = UIAction(title: isProbingCDN ? "CDN 测速中…" : "CDN 测速（VLC 画面）", image: UIImage(systemName: "speedometer")) { [weak self] _ in
            self?.probeCDN()
        }
        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") }),
            let index = current.firstIndex(of: setting)
        {
            current[index] = setting.replacingChildren(setting.children + [action])
        }
        return []
    }

    // MARK: - 加载 VLC

    private func startLoad(at position: Double?, maxQuality: Int?, streamIndex: Int?) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        lastMaxQuality = maxQuality
        lastStreamIndex = streamIndex
        mediaLoaded = false
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.load(generation: generation, position: position, maxQuality: maxQuality, streamIndex: streamIndex)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                Diag.startupStep("vlc_load_failed", ["error": String(describing: error).prefix(160)])
                self.onLoadFailure?(String(describing: error))
            }
        }
    }

    @MainActor
    private func load(generation: Int, position: Double?, maxQuality: Int?, streamIndex: Int?) async throws {
        let info = playData.videoPlayURLInfo
        let newDelegate = BilibiliVideoResourceLoaderDelegate()
        newDelegate.setBilibili(info: info, subtitles: [], aid: playData.aid, maxQuality: maxQuality, streamIndex: streamIndex)
        guard let video = newDelegate.primaryMedia else { throw "没有可播放的视频流" }
        async let videoURLReq = newDelegate.prepareDirectURL(for: video)
        async let audioURLReq = Self.directURL(newDelegate, newDelegate.primaryAudio)
        let videoURL = await videoURLReq
        let audioURL = await audioURLReq
        guard loadGeneration == generation, !Task.isCancelled else {
            newDelegate.btrPlayback.invalidate()
            throw CancellationError()
        }
        guard let videoURL else { throw "BTR 代理不可用" }
        Diag.startupStep("vlc_proxy_ready", ["video": newDelegate.primaryVideoDescription, "audio": audioURL != nil])

        if let old = delegate {
            old.btrPlayback.invalidate()
            retiredDelegates.append(old)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.retiredDelegates.removeAll { $0 === old }
            }
        }
        delegate = newDelegate

        // 起播位置以主时钟为准（主时钟已经在播时，例如切画质、回到 App）。
        let start = master.map { $0.currentTime().seconds }.flatMap { $0.isFinite && $0 > 0.5 ? $0 : nil } ?? position
        let media = VLCMedia(url: videoURL)
        var options: [String: Any] = ["network-caching": 600, "http-reconnect": true]
        if let audioURL { options["input-slave"] = audioURL.absoluteString }
        if let start, start > 0 { options["start-time"] = start }
        media.addOptions(options)
        lastVLCTimeMs = -1
        lastVLCAdvanceAt = .distantPast
        vlcSeekPending = nil
        vlcHeldAhead = false
        markedPlaying = false
        vlc.media = media
        vlc.play()
        mediaLoaded = true
        spinner.startAnimating()
        Diag.startupStep("vlc_play", ["start": start ?? 0])
    }

    private static func directURL(_ delegate: BilibiliVideoResourceLoaderDelegate,
                                  _ media: VideoPlayURLInfo.DashInfo.DashMediaInfo?) async -> URL?
    {
        guard let media else { return nil }
        return await delegate.prepareDirectURL(for: media)
    }

    /// 画质菜单：换 VLC 的流，影子不变。
    @MainActor
    func switchQuality(to qualityId: Int, streamIndex: Int?) async {
        BTRTrace.shared.event("quality_switch", ["to": qualityId, "streamIndex": streamIndex ?? -1, "target": masterTime, "engine": "VLC"])
        startLoad(at: masterTime, maxQuality: qualityId, streamIndex: streamIndex)
    }

    // MARK: - 同步

    private var masterTime: Double {
        let seconds = master?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private var vlcTime: Double {
        Double(vlc.time.intValue) / 1000
    }

    /// 最近 0.6 秒内 VLC 的时间在走 = 画面在动。
    private var vlcAdvancing: Bool {
        Date().timeIntervalSince(lastVLCAdvanceAt) < 0.6
    }

    private func masterRateChanged(_ rate: Float) {
        guard !settingMasterRate else { return }
        if rate >= 0.1 {
            // 用户（或系统界面）选的倍速。
            userRate = rate
            vlc.rate = rate
            holdingMaster = false
        } else if rate == 0 {
            // 用户暂停。
            holdingMaster = false
        }
        sync()
    }

    private func setMasterRate(_ rate: Float) {
        guard let master, master.rate != rate else { return }
        settingMasterRate = true
        master.rate = rate
        settingMasterRate = false
    }

    private func hold(_ reason: String) {
        guard let master, master.rate > 0 else { return }
        if !holdingMaster {
            holdingMaster = true
            BTRTrace.shared.event("vlc_sync_hold", ["reason": reason, "master": masterTime, "vlc": vlcTime])
        }
        setMasterRate(Self.holdRate)
        if master.rate == 0 {
            // 这条流不支持慢速：退而求其次，暂停主时钟等 VLC（holdingMaster 记着这不是用户暂停）。
            settingMasterRate = true
            master.pause()
            settingMasterRate = false
        }
    }

    private func release() {
        guard holdingMaster else { return }
        holdingMaster = false
        BTRTrace.shared.event("vlc_sync_release", ["master": masterTime, "vlc": vlcTime])
        setMasterRate(userRate)
    }

    private func sync() {
        guard mediaLoaded, let master, let item = master.currentItem, item.status == .readyToPlay else { return }
        let state = vlc.state
        if state == .ended || state == .error { release(); return }

        // 主时钟没在走、也不是我们让它停的 = 用户暂停。
        let userWantsPlay = master.rate > 0 || holdingMaster
        if !userWantsPlay {
            if vlc.isPlaying { vlc.pause() }
            vlcHeldAhead = false
            spinner.stopAnimating()
            return
        }

        let m = masterTime
        let v = vlcTime

        // 1. 用户拖动 / 快进快退：主时钟和 VLC 差得多，VLC 跳过去。
        if let pending = vlcSeekPending {
            if abs(v - pending.target) < 1.5, vlcAdvancing {
                vlcSeekPending = nil
            } else if Date().timeIntervalSince(pending.at) < 8 {
                hold("seek")
                ensureVLCPlaying()
                spinner.startAnimating()
                return
            } else {
                vlcSeekPending = nil
            }
        } else if markedPlaying, abs(v - m) > 3 {
            vlcSeekPending = (m, Date())
            BTRTrace.shared.event("vlc_sync_seek", ["master": m, "vlc": v])
            Diag.eventWindow(String(format: "VLC seek to %.1fs", m))
            vlc.time = VLCTime(int: Int32(m * 1000))
            hold("seek")
            ensureVLCPlaying()
            spinner.startAnimating()
            return
        }

        // 2. VLC 超前（主时钟刚才在等）：VLC 停一下等主时钟。
        if v - m > 0.4, vlcAdvancing || vlcHeldAhead {
            release()
            if !vlcHeldAhead {
                vlcHeldAhead = true
                vlc.pause()
            }
            spinner.stopAnimating()
            return
        }
        if vlcHeldAhead {
            if v - m > 0.05 { return }
            vlcHeldAhead = false
        }

        ensureVLCPlaying()

        // 3. VLC 没在出画面或落后：主时钟等它。
        if !vlcAdvancing || m - v > 0.25 {
            hold(vlcAdvancing ? "behind" : "buffering")
            if !vlcAdvancing { spinner.startAnimating() }
            return
        }

        // 4. 同步：恢复主时钟。
        spinner.stopAnimating()
        release()
        if abs(vlc.rate - userRate) > 0.01 { vlc.rate = userRate }
        if Date().timeIntervalSince(syncLogAt) > 5 {
            syncLogAt = Date()
            BTRTrace.shared.event("vlc_sync", ["master": m, "vlc": v, "drift": v - m])
        }
    }

    private func ensureVLCPlaying() {
        guard !vlcHeldAhead, !vlc.isPlaying else { return }
        let state = vlc.state
        if state == .paused || state == .stopped {
            vlc.play()
        }
    }

    // MARK: - 回到 App

    private func handleEnterBackground() {
        guard mediaLoaded else { return }
        backgroundPosition = masterTime
        loadTask?.cancel()
        loadGeneration += 1
        mediaLoaded = false
        vlc.stop()
        delegate?.btrPlayback.invalidate()
        Diag.mark("VLCR background teardown pos=\(Int(backgroundPosition ?? 0))")
    }

    private func handleEnterForeground() {
        guard let position = backgroundPosition else { return }
        backgroundPosition = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPlayURL()
            self.startLoad(at: position, maxQuality: self.lastMaxQuality, streamIndex: self.lastStreamIndex)
        }
    }

    @MainActor
    private func refreshPlayURL() async {
        let aid = playData.aid, cid = playData.cid
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            do {
                let fresh = playData.isBangumi
                    ? try await WebRequest.requestPcgPlayUrl(aid: aid, cid: cid)
                    : try await WebRequest.requestPlayUrl(aid: aid, cid: cid)
                playData.videoPlayURLInfo = fresh
                return
            } catch {
                Diag.mark("VLCR refreshPlayURL failed attempt=\(attempt)")
            }
        }
    }

    private func probeCDN() {
        guard !isProbingCDN else { return }
        let candidates = delegate?.cdnCandidates ?? []
        guard !candidates.isEmpty else {
            cdnProbeReport = "无候选 CDN"
            return
        }
        isProbingCDN = true
        cdnProbeReport = "CDN 测速中…"
        Task { @MainActor [weak self] in
            let report = await CDNDiagnostics.run(urls: candidates, currentHost: nil)
            self?.cdnProbeReport = report
            self?.isProbingCDN = false
        }
    }
}

extension VLCRendererPlugin: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let names: [VLCMediaPlayerState: String] = [.stopped: "stopped", .opening: "opening", .buffering: "buffering",
                                                    .ended: "ended", .error: "error", .playing: "playing", .paused: "paused"]
        let state = vlc.state
        Diag.startupStep("vlc_state", ["state": names[state] ?? "\(state.rawValue)", "time": vlcTime])
        if state == .error {
            BTRTrace.shared.event("vlc_error", ["master": masterTime])
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let ms = vlc.time.intValue
        guard ms != lastVLCTimeMs else { return }
        if lastVLCTimeMs >= 0 { lastVLCAdvanceAt = Date() }
        lastVLCTimeMs = ms
        if !markedPlaying, ms > 0, lastVLCAdvanceAt != .distantPast {
            markedPlaying = true
            Diag.startupStep("startup_mark", ["mark": "playing", "kind": "VLC"])
        }
    }
}
