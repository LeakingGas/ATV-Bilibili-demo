//
//  VLCVideoPlayerViewController.swift
//  BilibiliLive
//
//  试验：用 VLC 引擎播放（设置 › 播放引擎）。
//  下载仍走 BTR：VLC 直接读本地代理上的视频文件 + 音频文件（http://127.0.0.1:端口/media/…），
//  来多少数据播多少，不像系统播放器那样要整段到齐、还要等下一段、评估网速。
//
//  原型范围：播放 / 暂停、进度条（触控板左右滑动快速拖动）、左右键 ±10 秒、返回、弹幕、继续 / 从头询问、观看进度上报。
//  不支持：杜比视界 / HDR 输出、画中画、画质切换、下滑面板（需要时切回系统播放器）。
//

import SnapKit
import TVVLCKit
import UIKit

final class VLCVideoPlayerViewController: UIViewController {
    private var playInfo: PlayInfo
    private let askResume: Bool

    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let overlay = UIView()
    private let focusSink = VLCFocusSinkView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let controls = VLCControlsView()

    private var resourceDelegate: BilibiliVideoResourceLoaderDelegate?
    private var danmuProvider: VideoDanmuProvider?
    private var danmuPlugin: DanmuViewPlugin?
    private var danmuTimer: Timer?
    private var progressTimer: Timer?
    private var hideControlsWork: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?

    private var resolvedCid = 0
    private var durationSeconds: Double = 0
    private var startSeconds: Double = 0
    private var didStartPlaying = false
    private var isExiting = false
    private var userPaused = false

    // 拖动进度
    private var scrubTarget: Double?
    private var scrubCommitWork: DispatchWorkItem?

    init(playInfo: PlayInfo, askResume: Bool = true) {
        self.playInfo = playInfo
        self.askResume = askResume
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        Diag.mark("VLC deinit")
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [focusSink] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for sub in [videoView, overlay, focusSink] {
            view.addSubview(sub)
            sub.snp.makeConstraints { $0.edges.equalToSuperview() }
        }
        overlay.isUserInteractionEnabled = false
        view.addSubview(controls)
        controls.snp.makeConstraints { $0.edges.equalToSuperview() }
        controls.alpha = 0
        view.addSubview(spinner)
        spinner.color = .white
        spinner.snp.makeConstraints { $0.center.equalToSuperview() }
        spinner.startAnimating()

        player.drawable = videoView
        player.delegate = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        focusSink.addGestureRecognizer(pan)

        Diag.startupBegin("VLC aid=\(playInfo.aid) cid=\(playInfo.cid ?? 0) epid=\(playInfo.epid ?? 0) season=\(playInfo.seasonId ?? 0)")
        loadTask = Task { [weak self] in await self?.load() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || isExiting else { return }
        teardown()
    }

    // MARK: - 加载

    private func load() async {
        do {
            Diag.startupStep("vlc_load_begin")
            let resolved = try await PlayInfoResolver.resolve(playInfo)
            playInfo = resolved
            let aid = resolved.aid, cid = resolved.cid ?? 0
            resolvedCid = cid
            async let urlReq = resolved.isBangumi
                ? WebRequest.requestPcgPlayUrl(aid: aid, cid: cid)
                : WebRequest.requestPlayUrl(aid: aid, cid: cid)
            async let infoReq = try? WebRequest.requestPlayerInfo(aid: aid, cid: cid)
            let info = try await urlReq
            let playerInfo = await infoReq
            Diag.startupStep("vlc_playurl_done", ["quality": info.quality])
            durationSeconds = Double(info.dash.duration)

            // 观看记录与继续 / 从头询问（和系统播放器一致）
            let lastCid = resolved.lastPlayCid ?? playerInfo?.last_play_cid ?? 0
            let lastTime = resolved.playTimeInSecond ?? playerInfo?.playTimeInSecond ?? 0
            if Settings.continuePlay, lastCid == cid, lastTime >= 10, durationSeconds - Double(lastTime) > 5 {
                var resume = true
                if askResume, Settings.resumePrompt {
                    let detail = try? await WebRequest.requestDetailVideo(aid: aid)
                    let prompt = ResumePrompt(title: detail?.title ?? resolved.title ?? "", cover: detail?.pic ?? resolved.coverURL,
                                              position: lastTime, duration: info.dash.duration)
                    Diag.startupStep("resume_prompt_shown")
                    let choice = await presentResumePrompt(prompt)
                    Diag.startupStep("resume_prompt_answered", ["choice": "\(choice)"])
                    switch choice {
                    case .resume: break
                    case .restart: resume = false
                    case .cancel: exit(); return
                    }
                }
                if resume { startSeconds = Double(lastTime) }
            }

            // BTR 本地代理：沿用系统播放器路径的选流规则（画质上限、AVC 优先）。
            let delegate = BilibiliVideoResourceLoaderDelegate()
            delegate.setBilibili(info: info, subtitles: [], aid: aid)
            resourceDelegate = delegate
            guard let video = delegate.primaryMedia else { throw "没有可播放的视频流" }
            async let videoURLReq = delegate.prepareDirectURL(for: video)
            async let audioURLReq = Self.directURL(delegate, delegate.primaryAudio)
            guard let videoURL = await videoURLReq else { throw "BTR 代理不可用" }
            let audioURL = await audioURLReq
            Diag.startupStep("vlc_proxy_ready", ["video": delegate.primaryVideoDescription, "audio": audioURL != nil])

            // 弹幕
            let provider = VideoDanmuProvider(enableDanmuFilter: Settings.enableDanmuFilter,
                                              enableDanmuRemoveDup: Settings.enableDanmuRemoveDup)
            danmuProvider = provider
            Task { await provider.initVideo(cid: cid, startPos: Int(startSeconds)) }
            let danmu = DanmuViewPlugin(provider: provider)
            danmu.addViewToPlayerOverlay(container: overlay)
            danmuPlugin = danmu

            controls.title = resolved.title ?? ""
            Task { [weak self] in
                guard let self, self.controls.title.isEmpty, let detail = try? await WebRequest.requestDetailVideo(aid: aid) else { return }
                self.controls.title = detail.title
            }

            let media = VLCMedia(url: videoURL)
            var options: [String: Any] = ["network-caching": 600, "http-reconnect": true]
            if let audioURL { options["input-slave"] = audioURL.absoluteString }
            if startSeconds > 0 { options["start-time"] = startSeconds }
            media.addOptions(options)
            player.media = media
            Diag.startupStep("vlc_play")
            player.play()
            startTimers()
        } catch {
            guard !Task.isCancelled else { return }
            Diag.startupStep("vlc_load_failed", ["error": String(describing: error).prefix(160)])
            showError(String(describing: error))
        }
    }

    private static func directURL(_ delegate: BilibiliVideoResourceLoaderDelegate,
                                  _ media: VideoPlayURLInfo.DashInfo.DashMediaInfo?) async -> URL? {
        guard let media else { return nil }
        return await delegate.prepareDirectURL(for: media)
    }

    private func presentResumePrompt(_ prompt: ResumePrompt) async -> ResumeChoice {
        for _ in 0..<40 where view.window == nil || isBeingPresented {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await withCheckedContinuation { continuation in
            let promptVC = ResumePromptViewController(prompt: prompt) { continuation.resume(returning: $0) }
            present(promptVC, animated: true)
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        let alert = UIAlertController(title: "播放失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in self?.exit() })
        present(alert, animated: true)
    }

    // MARK: - 计时

    private func startTimers() {
        let progress = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(progress, forMode: .common)
        progressTimer = progress
        let danmu = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.player.isPlaying, Defaults.shared.showDanmu else { return }
            self.danmuProvider?.playerTimeChange(time: self.currentSeconds)
        }
        RunLoop.main.add(danmu, forMode: .common)
        danmuTimer = danmu
    }

    private var currentSeconds: Double {
        Double(player.time.intValue) / 1000
    }

    private func tick() {
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length > 0 { durationSeconds = length }
        if scrubTarget == nil {
            controls.update(position: currentSeconds, duration: durationSeconds, playing: player.isPlaying)
        }
    }

    private func teardown() {
        loadTask?.cancel()
        progressTimer?.invalidate(); progressTimer = nil
        danmuTimer?.invalidate(); danmuTimer = nil
        let position = Int(currentSeconds)
        if position > 0, resolvedCid > 0 {
            WebRequest.reportWatchHistory(aid: playInfo.aid, cid: resolvedCid, currentTime: position,
                                          epid: playInfo.epid, seasonId: playInfo.seasonId, subType: playInfo.subType)
        }
        player.stop()
        player.media = nil
        resourceDelegate = nil
    }

    private func exit() {
        guard !isExiting else { return }
        isExiting = true
        Diag.mark("VLC exit")
        if let presenter = presentingViewController {
            presenter.dismiss(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: - 控制栏

    private func showControls(autoHide: Bool = true) {
        hideControlsWork?.cancel()
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 1 }
        guard autoHide else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.player.isPlaying, self.scrubTarget == nil else { return }
            UIView.animate(withDuration: 0.4) { self.controls.alpha = 0 }
        }
        hideControlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hideControls() {
        hideControlsWork?.cancel()
        UIView.animate(withDuration: 0.3) { self.controls.alpha = 0 }
    }

    private var controlsVisible: Bool { controls.alpha > 0.5 }

    private func togglePause() {
        if player.isPlaying {
            userPaused = true
            player.pause()
            danmuPlugin?.danMuView.pause()
            showControls(autoHide: false)
        } else {
            userPaused = false
            player.play()
            danmuPlugin?.danMuView.play()
            showControls()
        }
        tick()
    }

    private func seek(to seconds: Double) {
        let target = max(0, min(seconds, max(0, durationSeconds - 1)))
        Diag.startupStep("vlc_seek", ["to": target])
        Diag.eventWindow(String(format: "VLC seek to %.1fs", target))
        player.time = VLCTime(int: Int32(target * 1000))
        danmuPlugin?.danMuView.clean()
        controls.update(position: target, duration: durationSeconds, playing: player.isPlaying)
    }

    // 触控板左右滑动：快速拖动进度条，松手约 0.5 秒后跳转。滑得越快走得越多。
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard durationSeconds > 0 else { return }
        switch gesture.state {
        case .began:
            scrubTarget = scrubTarget ?? currentSeconds
            scrubCommitWork?.cancel()
            showControls(autoHide: false)
        case .changed:
            let dx = gesture.translation(in: focusSink).x
            gesture.setTranslation(.zero, in: focusSink)
            let speed = abs(gesture.velocity(in: focusSink).x)
            // 一次完整滑动（约 1000 点）≈ 视频时长的 8%（至少 60 秒）；快速甩动最多再放大 4 倍。
            let perPoint = max(60, durationSeconds * 0.08) / 1000
            let accel = min(4, 1 + speed / 1500)
            let target = max(0, min(durationSeconds - 1, (scrubTarget ?? currentSeconds) + Double(dx) * perPoint * accel))
            scrubTarget = target
            controls.update(position: target, duration: durationSeconds, playing: player.isPlaying, scrubbing: true)
        case .ended, .cancelled, .failed:
            scheduleScrubCommit()
        default:
            break
        }
    }

    private func scheduleScrubCommit() {
        scrubCommitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let target = self.scrubTarget else { return }
            self.scrubTarget = nil
            self.seek(to: target)
            self.showControls()
        }
        scrubCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - 遥控器按键

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled: Set<UIPress.PressType> = [.menu, .select, .playPause, .leftArrow, .rightArrow, .upArrow, .downArrow]
        if presses.contains(where: { handled.contains($0.type) }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first else { return super.pressesEnded(presses, with: event) }
        switch press.type {
        case .menu:
            if let target = scrubTarget {
                // 拖动中按返回：放弃这次拖动
                scrubCommitWork?.cancel()
                scrubTarget = nil
                _ = target
                tick()
                showControls()
            } else if controlsVisible, player.isPlaying {
                hideControls()
            } else {
                exit()
            }
        case .select:
            if scrubTarget != nil {
                scrubCommitWork?.cancel()
                scrubCommitWork = nil
                if let target = scrubTarget { scrubTarget = nil; seek(to: target) }
                showControls()
            } else {
                togglePause()
            }
        case .playPause:
            togglePause()
        case .leftArrow:
            seek(to: (scrubTarget ?? currentSeconds) - 10)
            showControls()
        case .rightArrow:
            seek(to: (scrubTarget ?? currentSeconds) + 10)
            showControls()
        case .upArrow, .downArrow:
            showControls()
        default:
            super.pressesEnded(presses, with: event)
        }
    }
}

// MARK: - VLC 回调

extension VLCVideoPlayerViewController: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = player.state
        let names: [VLCMediaPlayerState: String] = [.stopped: "stopped", .opening: "opening", .buffering: "buffering",
                                                    .ended: "ended", .error: "error", .playing: "playing", .paused: "paused"]
        Diag.startupStep("vlc_state", ["state": names[state] ?? "\(state.rawValue)", "time": currentSeconds])
        switch state {
        case .playing:
            danmuPlugin?.danMuView.play()
        case .paused:
            danmuPlugin?.danMuView.pause()
        case .error:
            showError("VLC 无法播放这个视频")
        case .ended:
            exit()
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard !didStartPlaying, player.time.intValue > 0 else { return }
        didStartPlaying = true
        spinner.stopAnimating()
        Diag.startupStep("startup_mark", ["mark": "playing", "kind": "VLC"])
        showControls()
    }
}

// MARK: - 视图

/// 全屏可聚焦的空视图：让遥控器按键和触控板滑动都落到播放器上。
final class VLCFocusSinkView: UIView {
    override var canBecomeFocused: Bool { true }
}

/// 底部控制栏：标题、进度条、时间。
final class VLCControlsView: UIView {
    var title: String {
        get { titleLabel.text ?? "" }
        set { titleLabel.text = newValue }
    }

    private let gradient = CAGradientLayer()
    private let titleLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let thumb = UIView()
    private let timeLabel = UILabel()
    private let remainLabel = UILabel()
    private let stateIcon = UIImageView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
        gradient.locations = [0.55, 1]
        layer.addSublayer(gradient)

        titleLabel.font = .systemFont(ofSize: 38, weight: .semibold)
        titleLabel.textColor = .white
        addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(90)
            make.trailing.lessThanOrEqualToSuperview().inset(90)
            make.bottom.equalToSuperview().inset(150)
        }

        track.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        track.layer.cornerRadius = 5
        addSubview(track)
        track.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(90)
            make.bottom.equalToSuperview().inset(100)
            make.height.equalTo(10)
        }
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 5
        track.addSubview(fill)
        thumb.backgroundColor = .white
        thumb.layer.cornerRadius = 14
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.4
        thumb.layer.shadowRadius = 8
        thumb.isHidden = true
        addSubview(thumb)

        for label in [timeLabel, remainLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.8)
            addSubview(label)
        }
        timeLabel.snp.makeConstraints { make in
            make.leading.equalTo(track)
            make.top.equalTo(track.snp.bottom).offset(14)
        }
        remainLabel.snp.makeConstraints { make in
            make.trailing.equalTo(track)
            make.top.equalTo(track.snp.bottom).offset(14)
        }
        stateIcon.tintColor = .white
        stateIcon.contentMode = .scaleAspectFit
        addSubview(stateIcon)
        stateIcon.snp.makeConstraints { make in
            make.trailing.equalTo(track)
            make.centerY.equalTo(titleLabel)
            make.width.height.equalTo(40)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layoutProgress()
    }

    private func layoutProgress() {
        let width = track.bounds.width * fraction
        fill.frame = CGRect(x: 0, y: 0, width: width, height: track.bounds.height)
        let center = CGPoint(x: track.frame.minX + width, y: track.frame.midY)
        thumb.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        thumb.center = center
    }

    func update(position: Double, duration: Double, playing: Bool, scrubbing: Bool = false) {
        fraction = duration > 0 ? CGFloat(max(0, min(1, position / duration))) : 0
        timeLabel.text = Self.format(position)
        remainLabel.text = "-" + Self.format(max(0, duration - position))
        thumb.isHidden = !scrubbing
        stateIcon.image = UIImage(systemName: playing ? "play.fill" : "pause.fill")
        layoutProgress()
    }

    private static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
