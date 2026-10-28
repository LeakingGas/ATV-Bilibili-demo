//
//  VLCRendererPlugin.swift
//  BilibiliLive
//
//  VLC 模式：界面和操作完全是系统播放器的。系统播放器播一路本地生成的静音「影子」
//  （BVideoPlayPlugin 的黑画面 / 预览图幻灯片，不联网、不缓冲、不会卡），只提供时间轴、控制栏和拖动预览；
//  真正的画面和声音由这里的 VLC 输出，画面叠在系统播放器的画面层上、控制栏下面。
//
//  同步原则：VLC 说了算，影子只跟随。绝不为了同步去改 VLC 的速度、暂停或跳转。
//  - 用户的操作都来自系统界面：跳转（系统的「用户跳转」通知 + 影子的时间跳变）、暂停 / 继续、倍速，
//    由这里转给 VLC。影子自己不会卡、不会停，所以它的状态变化只可能来自用户或我们。
//  - VLC 实际播到哪，影子就挪到哪；VLC 在缓冲 / 跳转中，影子钉在 VLC 该在的位置上。
//

import AVKit
import TVVLCKit
import UIKit

final class VLCRendererPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

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
    /// 用户暂停了。
    private var userPaused = false
    private var masterEverPlayed = false
    /// 用户在系统界面上长按左右快退 / 快进（影子速率为负或大于 2.5）：VLC 放不了倒放，先停下，
    /// 让下面的影子露出来（系统播放器自己的快退快进画面），松手后 VLC 跳到影子的位置。
    private var scanning = false
    /// 这次打开 VLC 时的起点（VLC 出第一帧前，影子钉在这里）。
    private var loadStartPosition: Double = 0
    /// VLC 播完时的位置（它的结尾可能比影子短一两秒）。
    private var vlcEndTime: Double?
    private var lastVLCTimeMs: Int32 = -1
    private var lastVLCAdvanceAt = Date.distantPast
    private var stalledSince: Date?
    /// 用户跳转后 VLC 要去的位置；VLC 在那里出画面前，影子钉在这里。
    private var vlcSeekPending: (target: Double, at: Date)?
    /// 我们最近一次挪影子：影子因此产生的时间跳变不算用户操作。
    private var lastOwnSeek: (target: Double, at: Date)?
    private var lastPinAt = Date.distantPast
    private var markedPlaying = false
    private var syncLogAt = Date.distantPast
    /// 音频诊断：VLC 实际播出 / 丢掉的音频段数（判断「没声音」是不是 VLC 丢了声音）。
    private var audioStatsAt = Date.distantPast
    private var lastPlayedAudio = -1
    private var lastLostAudio = -1
    private var silentSince: Date?

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
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
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
        lines.append("VLC state: \(names[vlc.state] ?? "\(vlc.state.rawValue)") time:\(String(format: "%.1f", vlcTime)) shadow:\(String(format: "%.1f", masterTime))")
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
        vlcEndTime = nil
        loadStartPosition = start ?? 0
        markedPlaying = false
        lastPlayedAudio = -1
        lastLostAudio = -1
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
            if abs(vlc.rate - rate) > 0.01 { vlc.rate = rate }
            if userPaused {
                userPaused = false
                BTRTrace.shared.event("vlc_resume", ["vlc": vlcTime, "shadow": masterTime])
                if vlcFinished {
                    startUserSeek(to: masterTime)
                } else if mediaLoaded, !vlc.isPlaying {
                    vlc.play()
                }
            }
        } else if rate == 0, masterEverPlayed {
            // 影子播到结尾自己停下，不是用户暂停（「播完了」由 VLC 决定，见 handleVLCEnded）。
            let duration = master.currentItem?.duration.seconds ?? 0
            if duration.isFinite, duration > 0, masterTime >= duration - 0.5 { return }
            userPaused = true
            BTRTrace.shared.event("vlc_pause", ["vlc": vlcTime, "shadow": masterTime])
            if vlc.isPlaying { vlc.pause() }
        }
    }

    /// 系统的「用户跳转」通知（点按快进快退、滑动进度条后确认）：VLC 直接跳过去。
    func playerUserNavigated(to seconds: Double) {
        guard mediaLoaded || vlcFinished, seconds.isFinite else { return }
        startUserSeek(to: max(0, seconds))
    }

    /// 影子的时间跳了。影子不联网、不会自己跳，所以除了我们自己挪的，就是别人挪的：
    /// 用户（上面的通知没覆盖到的情况）、重播、跳过广告、投屏控制……VLC 都要跟过去。
    private func masterJumped() {
        // 影子还没开始播（刚装上、跳到观看记录位置）的跳变不算：VLC 自己从起点开始，影子随后会被挪过去。
        guard mediaLoaded || vlcFinished, !scanning, masterEverPlayed else { return }
        let current = masterTime
        if let own = lastOwnSeek, Date().timeIntervalSince(own.at) < 2, abs(current - own.target) < 0.5 { return }
        guard abs(current - expectedVLCTime) > 1.0 else { return }
        BTRTrace.shared.event("shadow_jump", ["to": current, "vlc": vlcTime, "expected": expectedVLCTime])
        startUserSeek(to: current)
    }

    /// VLC 此刻「应该」在的位置：跳转中是目标位置，还没出第一帧是起点，其余是 VLC 的实际时间。
    private var expectedVLCTime: Double {
        if let pending = vlcSeekPending { return pending.target }
        if !markedPlaying { return loadStartPosition }
        return vlcTime
    }

    /// VLC 播完后媒体已经结束，跳转 / 播放都不会生效，要从目标位置重新打开。
    private var vlcFinished: Bool {
        mediaLoaded && vlcEndTime != nil
    }

    private func startUserSeek(to target: Double) {
        if vlcFinished {
            // 跳到 VLC 结尾 1 秒以内：保持播完状态，不重新打开（会超出 VLC 的结尾，从 0 开始放）。
            if let end = vlcEndTime, target >= end - 1.0 {
                BTRTrace.shared.event("vlc_seek_ignored_at_end", ["target": target, "vlcEnd": end])
                return
            }
            BTRTrace.shared.event("vlc_reopen_after_end", ["target": target])
            vlcEndTime = nil
            container?.externalPlaybackResumed()
            startLoad(at: target, maxQuality: lastMaxQuality, streamIndex: lastStreamIndex)
            return
        }
        // 同一个目标（通知和时间跳变都报了同一次跳转）只跳一次。
        if let pending = vlcSeekPending, abs(pending.target - target) < 0.3, Date().timeIntervalSince(pending.at) < 2 { return }
        vlcSeekPending = (target, Date())
        BTRTrace.shared.event("vlc_user_seek", ["target": target, "vlc": vlcTime])
        Diag.eventWindow(String(format: "VLC seek to %.1fs", target))
        vlc.time = VLCTime(int: Int32(target * 1000))
        if !userPaused, !vlc.isPlaying { vlc.play() }
    }

    /// 挪影子（我们自己的跳转，不算用户操作）。
    private func seekShadow(to target: Double) {
        guard let master else { return }
        lastOwnSeek = (target, Date())
        lastPinAt = Date()
        master.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 同步（只动影子）

    private func sync() {
        updateSystemSpinner(hide: mediaLoaded && vlcAdvancing)
        guard mediaLoaded else { return }
        let state = vlc.state
        if state == .ended, vlcEndTime == nil { handleVLCEnded() }
        if vlcEndTime != nil || state == .error {
            spinner.stopAnimating()
            return
        }

        if scanning { return }
        // 快退快进松手后，VLC 在新位置出画面了才盖回去（之前露出的是影子）。
        if videoView.isHidden, vlcSeekPending == nil, vlcAdvancing {
            videoView.isHidden = false
        }

        // 跳转后 VLC 在目标附近重新走起来 = 到了。
        if let pending = vlcSeekPending {
            let arrived = abs(vlcTime - pending.target) < 1.5 && lastVLCAdvanceAt > pending.at && vlcAdvancing
            if arrived || Date().timeIntervalSince(pending.at) > 15 {
                vlcSeekPending = nil
            }
        }
        logAudioStats()

        // VLC 没在出画面（又不是用户暂停）：显示加载圈，影子钉在 VLC 该在的位置上。
        let vlcStalled = !userPaused && (!vlcAdvancing || vlcSeekPending != nil)
        if vlcStalled {
            if stalledSince == nil { stalledSince = Date() }
        } else {
            stalledSince = nil
        }
        let showSpinner = vlcStalled && markedPlaying && Date().timeIntervalSince(stalledSince ?? Date()) > 0.3
        if showSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }

        guard master != nil else { return }
        let expected = expectedVLCTime
        let drift = masterTime - expected
        if vlcStalled {
            if abs(drift) > 0.3, Date().timeIntervalSince(lastPinAt) > 0.25 {
                seekShadow(to: expected)
            }
            return
        }
        if abs(drift) > 0.5, Date().timeIntervalSince(lastPinAt) > 1.0 {
            BTRTrace.shared.event("shadow_correct", ["shadow": masterTime, "vlc": vlcTime, "drift": drift])
            seekShadow(to: vlcTime + 0.05)
            return
        }
        if Date().timeIntervalSince(syncLogAt) > 5 {
            syncLogAt = Date()
            BTRTrace.shared.event("vlc_sync", ["shadow": masterTime, "vlc": vlcTime, "drift": drift])
        }
    }

    /// 每秒看一次 VLC 播出 / 丢掉的音频段数；VLC 画面在走而声音一段都没播出，记下来。
    private func logAudioStats() {
        guard Date().timeIntervalSince(audioStatsAt) >= 1, let media = vlc.media else { return }
        audioStatsAt = Date()
        let played = Int(media.numberOfPlayedAudioBuffers)
        let lost = Int(media.numberOfLostAudioBuffers)
        defer {
            lastPlayedAudio = played
            lastLostAudio = lost
        }
        guard lastPlayedAudio >= 0 else { return }
        let playedDelta = played - lastPlayedAudio
        let lostDelta = lost - lastLostAudio
        let advancing = vlcAdvancing && !userPaused
        if advancing, playedDelta <= 0 {
            if silentSince == nil {
                silentSince = Date()
                BTRTrace.shared.event("vlc_audio_silent", ["vlc": vlcTime, "lost": lostDelta,
                                                           "tracks": Int(vlc.numberOfAudioTracks), "track": Int(vlc.currentAudioTrackIndex)])
            }
        } else if let since = silentSince, playedDelta > 0 {
            silentSince = nil
            BTRTrace.shared.event("vlc_audio_back", ["vlc": vlcTime, "silentMs": Date().timeIntervalSince(since) * 1000])
        }
        if lostDelta > 0 {
            BTRTrace.shared.event("vlc_audio_lost", ["vlc": vlcTime, "lost": lostDelta, "played": playedDelta])
        }
    }

    /// VLC 播完：通知结束画面；影子还没到结尾就直接挪到结尾（触发系统的「播完」：结束画面或下一集）。
    private func handleVLCEnded() {
        guard vlcEndTime == nil else { return }
        vlcEndTime = vlcTime
        BTRTrace.shared.event("vlc_ended", ["vlc": vlcTime, "shadow": masterTime])
        // VLC 播完可能黑屏：露出影子的最后一帧（上面会盖结束画面的毛玻璃）。
        videoView.isHidden = true
        container?.externalPlaybackEnded()
        guard let master else { return }
        let duration = master.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 0, masterTime < duration - 0.1 else { return }
        lastOwnSeek = (duration - 0.05, Date())
        master.seek(to: CMTime(seconds: duration - 0.05, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async { master.play() }
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
        if state == .ended, mediaLoaded, vlcEndTime == nil { handleVLCEnded() }
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
