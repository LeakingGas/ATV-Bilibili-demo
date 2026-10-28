//
//  VLCRendererPlugin.swift
//  BilibiliLive
//
//  VLC 模式：界面和操作完全是系统播放器的。系统播放器播一路静音的低码率「影子」视频
//  （BVideoPlayPlugin 的 shadowStreamIndex），只提供时间轴、控制栏和拖动预览；
//  真正的画面和声音由这里的 VLC 输出，画面叠在系统播放器的画面层上、控制栏下面。
//
//  同步原则：以 VLC 为准，只调整看不见的影子，绝不为了同步去改 VLC 的速度、暂停或跳转。
//  VLC 只跟着用户的操作走（暂停 / 继续、拖动 / 快进快退、选的倍速）。
//  - VLC 还没出画面（刚进视频、拖动之后）：关闭影子的数据闸门，系统播放器停在自己的加载圈上等。
//  - 影子和 VLC 差得多：把影子挪到 VLC 的位置（影子在下层看不见，只有进度条时间小跳一下）。
//  - 影子的时间跳了、又不是我们挪的：是用户在系统界面上拖动 / 快进，VLC 跳到同一位置。
//

import AVKit
import TVVLCKit
import UIKit

final class VLCRendererPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

    /// 影子播放器的数据闸门（交给 BVideoPlayPlugin，由本地代理在交数据前检查）。
    let gate = MediaDeliveryGate()

    private let vlc = VLCMediaPlayer()
    private let videoView = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private weak var master: AVPlayer?
    private weak var container: CommonPlayerViewController?
    private weak var hostView: UIView?
    /// 系统播放器自己的加载圈（影子在等数据时转）。VLC 正常出画面时把它藏起来。
    private var systemSpinners = [WeakView]()
    private var systemSpinnerScanAt = Date.distantPast
    private var systemSpinnerHidden = false
    private var loggedSpinnerScan = false
    private var rateObservation: NSKeyValueObservation?
    private var jumpObserver: NSObjectProtocol?

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
    private var mediaLoaded = false
    /// 用户暂停了（影子速率为 0 且不是在等数据）。
    private var userPaused = false
    private var masterEverPlayed = false
    /// 影子开始正常播放的时间：起播阶段（影子跳到观看记录、刚开播）的时间跳变不算用户拖动。
    private var masterPlayingSince: Date?
    /// 上一次同步时影子的时间：时间跳变是相对它判断的（不是和 VLC 比：起播时两边本来就有差）。
    private var prevMasterTime: Double = 0
    /// 用户在系统界面上长按左右快退 / 快进（影子速率为负或大于 2.5）：VLC 放不了倒放，先停下，
    /// 并让下面的影子露出来（系统播放器自己的快退快进画面），松手后 VLC 跳到影子的位置。
    private var scanning = false
    private var lastVLCTimeMs: Int32 = -1
    private var lastVLCAdvanceAt = Date.distantPast
    private var stalledSince: Date?
    /// 用户拖动后 VLC 跳去的位置；VLC 在那里出画面前，影子等着。
    private var vlcSeekPending: (target: Double, at: Date)?
    /// 我们自己挪影子的时间：这段时间内影子的时间跳变不算用户操作。
    private var ownMasterSeekAt = Date.distantPast
    private var lastCorrectionAt = Date.distantPast
    private var markedPlaying = false
    private var syncLogAt = Date.distantPast

    init(detailData: PlayerDetailData) {
        playData = detailData
        super.init()
        vlc.delegate = self
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        gate.isOpen = false
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
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        syncTimer?.invalidate()
        delegate?.btrPlayback.invalidate()
        gate.isOpen = true
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
        lines.append("VLC state: \(names[vlc.state] ?? "\(vlc.state.rawValue)") time:\(String(format: "%.1f", vlcTime)) shadow:\(String(format: "%.1f", masterTime)) gate:\(gate.isOpen ? "open" : "closed")")
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
        vlc.drawable = videoView
    }

    func playerDidLoad(host: PlayerHost) {
        Diag.startupStep("player_engine", ["kind": "VLC"])
        container = host.hostViewController.parent as? CommonPlayerViewController
        container?.setPictureInPictureAllowed(false)
        hostView = host.hostViewController.view
        vlc.rate = Settings.mediaPlayerSpeed.value
        let start = playData.playerStartPos.map { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
        startLoad(at: start, maxQuality: nil, streamIndex: nil)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.sync() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    func playerDidChange(engine: PlayerEngine) {
        guard let player = engine.avPlayer else { return }
        master = player
        masterEverPlayed = false
        masterPlayingSince = nil
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            DispatchQueue.main.async { self?.masterRateChanged(rate) }
        }
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: player.currentItem, queue: .main) { [weak self] _ in
            self?.masterJumped()
        }
    }

    func playerDidCleanUp(engine: PlayerEngine) {
        guard let player = engine.avPlayer, player === master else { return }
        rateObservation = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        master = nil
    }

    func playerWillCleanUp(host: PlayerHost) {
        systemSpinners.forEach { $0.view?.alpha = 1 }
        systemSpinners = []
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        syncTimer?.invalidate()
        syncTimer = nil
        rateObservation = nil
        gate.isOpen = true
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
                self.gate.isOpen = true
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

        // 影子已经在播时（切画质、回到 App）从影子的位置开始。
        let start = master.map { $0.currentTime().seconds }.flatMap { $0.isFinite && $0 > 0.5 ? $0 : nil } ?? position
        let media = VLCMedia(url: videoURL)
        var options: [String: Any] = ["network-caching": 600, "http-reconnect": true]
        if let audioURL { options["input-slave"] = audioURL.absoluteString }
        if let start, start > 0 { options["start-time"] = start }
        media.addOptions(options)
        lastVLCTimeMs = -1
        lastVLCAdvanceAt = .distantPast
        vlcSeekPending = nil
        markedPlaying = false
        vlc.media = media
        if !userPaused { vlc.play() }
        mediaLoaded = true
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
        BTRTrace.shared.event("quality_switch", ["to": qualityId, "streamIndex": streamIndex ?? -1, "target": vlcTime, "engine": "VLC"])
        startLoad(at: vlcTime, maxQuality: qualityId, streamIndex: streamIndex)
    }

    // MARK: - 用户操作（都来自系统界面上的影子播放器）

    private var masterTime: Double {
        let seconds = master?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private var vlcTime: Double {
        Double(vlc.time.intValue) / 1000
    }

    /// 最近 0.6 秒内 VLC 的时间在走 = 画面在动。
    /// 找到系统界面里的加载圈（排除我们自己的），VLC 出画面时用透明度藏起来。
    /// 不用 isHidden：系统 startAnimating 会把 isHidden 改回去，透明度它不动。
    private func updateSystemSpinner(hide: Bool) {
        guard let hostView else { return }
        if Date().timeIntervalSince(systemSpinnerScanAt) > 1 {
            systemSpinnerScanAt = Date()
            var found = [WeakView]()
            func walk(_ view: UIView) {
                if view === videoView { return }
                if view is UIActivityIndicatorView || String(describing: type(of: view)).contains("ActivityIndicator") {
                    found.append(WeakView(view))
                    return
                }
                view.subviews.forEach(walk)
            }
            walk(hostView)
            if !found.isEmpty, !loggedSpinnerScan {
                loggedSpinnerScan = true
                Diag.startupStep("system_spinner_found", ["count": found.count,
                                                          "types": found.compactMap { $0.view.map { String(describing: type(of: $0)) } }.joined(separator: ",")])
            }
            // 新找到的先按当前状态处理，之前藏过、已经不在的不管。
            systemSpinners = found
            systemSpinnerHidden = !hide
        }
        guard hide != systemSpinnerHidden else {
            // 系统可能自己把透明度改回去，藏着的时候每次都再压一下。
            if hide { systemSpinners.forEach { if let v = $0.view, v.alpha != 0 { v.alpha = 0 } } }
            return
        }
        systemSpinnerHidden = hide
        systemSpinners.forEach { $0.view?.alpha = hide ? 0 : 1 }
    }

    private var vlcAdvancing: Bool {
        Date().timeIntervalSince(lastVLCAdvanceAt) < 0.6
    }

    private func masterRateChanged(_ rate: Float) {
        guard let master else { return }
        if rate < 0 || rate > 2.5 {
            if !scanning {
                scanning = true
                BTRTrace.shared.event("vlc_scan_begin", ["rate": rate, "shadow": masterTime])
                vlc.pause()
                videoView.isHidden = true
                gate.isOpen = true
            }
            return
        }
        if scanning {
            scanning = false
            let target = masterTime
            BTRTrace.shared.event("vlc_scan_end", ["rate": rate, "shadow": target])
            if rate == 0 { userPaused = true }
            startUserSeek(to: target)
        }
        if rate >= 0.1 {
            // 用户选的倍速 / 继续播放。
            masterEverPlayed = true
            if masterPlayingSince == nil { masterPlayingSince = Date() }
            if abs(vlc.rate - rate) > 0.01 { vlc.rate = rate }
            if userPaused {
                userPaused = false
                if mediaLoaded, !vlc.isPlaying { vlc.play() }
            }
        } else if rate == 0, masterEverPlayed, master.timeControlStatus == .paused {
            // 用户暂停（影子在等数据时是 waiting，不是 paused）。
            userPaused = true
            if vlc.isPlaying { vlc.pause() }
        }
    }

    /// 影子的时间跳了：不是我们挪的，就是用户在系统界面上拖动 / 快进快退。
    private func masterJumped() {
        // 起播阶段的跳变（影子开始播放、跳到观看记录位置）不算：VLC 已经从那里开始了。
        // 影子开始正常播放 1.5 秒以后、又不是我们自己挪的，才是用户拖动 / 快进快退。
        guard mediaLoaded, !scanning, Date().timeIntervalSince(ownMasterSeekAt) > 1.0,
              let since = masterPlayingSince, Date().timeIntervalSince(since) > 1.5 else { return }
        let target = masterTime
        // 和影子自己上一刻的位置比（不和 VLC 比）。
        guard abs(target - prevMasterTime) > 1.0 else { return }
        prevMasterTime = target
        guard abs(target - vlcTime) > 0.5 else { return }
        startUserSeek(to: target)
    }

    private func startUserSeek(to target: Double) {
        vlcSeekPending = (target, Date())
        lastCorrectionAt = Date()
        BTRTrace.shared.event("vlc_user_seek", ["target": target, "vlc": vlcTime])
        Diag.eventWindow(String(format: "VLC seek to %.1fs", target))
        vlc.time = VLCTime(int: Int32(target * 1000))
        if !userPaused, !vlc.isPlaying { vlc.play() }
        gate.isOpen = userPaused
    }

    // MARK: - 同步（只动影子）

    private func sync() {
        updateSystemSpinner(hide: mediaLoaded && vlcAdvancing)
        guard mediaLoaded else { return }
        let state = vlc.state
        if state == .ended || state == .error {
            gate.isOpen = true
            spinner.stopAnimating()
            return
        }

        if scanning { return }
        // 快退快进松手后，VLC 在新位置出画面了才盖回去（之前露出的是系统播放器自己的画面）。
        if videoView.isHidden, vlcSeekPending == nil, vlcAdvancing {
            videoView.isHidden = false
        }
        defer { prevMasterTime = masterTime }

        // 用户拖动后：VLC 在新位置出画面前，影子等着。
        if let pending = vlcSeekPending {
            let arrived = abs(vlcTime - pending.target) < 0.8 && lastVLCAdvanceAt > pending.at && vlcAdvancing
            if arrived || Date().timeIntervalSince(pending.at) > 10 {
                vlcSeekPending = nil
            }
        }

        // VLC 没在出画面（又不是用户暂停）= 影子不该往前走，关闸门。
        let vlcStalled = !userPaused && (!vlcAdvancing || vlcSeekPending != nil)
        if vlcStalled {
            if stalledSince == nil { stalledSince = Date() }
        } else {
            stalledSince = nil
        }
        gate.isOpen = !vlcStalled
        // 影子在系统加载圈里等时由系统显示加载圈；影子还在走而 VLC 卡住时显示我们的。
        let showSpinner = vlcStalled && markedPlaying && master?.timeControlStatus == .playing
            && Date().timeIntervalSince(stalledSince ?? Date()) > 0.3
        if showSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }

        guard let master, master.timeControlStatus == .playing, !vlcStalled else { return }

        // 影子和 VLC 差得多：把影子挪到 VLC 的位置（只动影子，画面和声音不受影响）。
        let drift = masterTime - vlcTime
        if abs(drift) > 1.0, Date().timeIntervalSince(lastCorrectionAt) > 3 {
            lastCorrectionAt = Date()
            ownMasterSeekAt = Date()
            let target = vlcTime + 0.1
            BTRTrace.shared.event("shadow_correct", ["shadow": masterTime, "vlc": vlcTime, "drift": drift])
            master.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        if Date().timeIntervalSince(syncLogAt) > 5 {
            syncLogAt = Date()
            BTRTrace.shared.event("vlc_sync", ["shadow": masterTime, "vlc": vlcTime, "drift": drift])
        }
    }

    // MARK: - 回到 App

    private func handleEnterBackground() {
        guard mediaLoaded else { return }
        backgroundPosition = vlcTime
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
        gate.isOpen = false
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
        guard state != .buffering else { return } // buffering 一秒能报几十次，不记
        Diag.startupStep("vlc_state", ["state": names[state] ?? "\(state.rawValue)", "time": vlcTime])
        if state == .error {
            BTRTrace.shared.event("vlc_error", ["shadow": masterTime])
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
            container?.loadingBackdropFrameReady()
        }
    }
}

/// 弱引用一个视图（系统界面里的视图我们不持有）。
private struct WeakView {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}
