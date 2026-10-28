//
//  VLCPlayerSurface.swift
//  BilibiliLive
//
//  VLC 内核的播放界面，外观和操作照着系统播放器做：
//  - 画面上轻点触控板：显示控制栏；按下触控板 / 播放键：暂停或继续；左右按：后退 / 前进 10 秒。
//  - 在触控板上左右滑动：拖动进度（带预览图），按下确认跳转，按返回取消。
//  - 控制栏：标题、进度条、时间，下面一排按钮（点赞、画质、播放设置、弹幕……），再往下是「推荐和评论」。
//  - 返回键：先关菜单 / 面板 / 取消拖动 / 收起控制栏，都没有时退出播放。
//  插件看到的是 PlayerHost 接口，和系统播放器一样设置按钮、右下角操作、下滑面板。
//

import AVKit
import SnapKit
import TVVLCKit
import UIKit

@MainActor
protocol VLCPlayerSurfaceDelegate: AnyObject {
    func vlcSurfaceRequestsExit(_ surface: VLCPlayerSurface)
    func vlcSurface(_ surface: VLCPlayerSurface, didReplaceEngine old: VLCPlayerEngine?, with new: VLCPlayerEngine?)
    func vlcSurfaceEngineDidBecomeReady(_ surface: VLCPlayerSurface)
    func vlcSurfaceEngineDidStart(_ surface: VLCPlayerSurface)
    func vlcSurfaceEngineDidPause(_ surface: VLCPlayerSurface)
    func vlcSurfaceEngineDidEnd(_ surface: VLCPlayerSurface)
    func vlcSurfaceEngineDidFail(_ surface: VLCPlayerSurface)
}

final class VLCPlayerSurface: UIViewController, PlayerHost {
    weak var surfaceDelegate: VLCPlayerSurfaceDelegate?
    private(set) var engine: VLCPlayerEngine?

    /// 插件的叠加层（弹幕、Debug、倍速提示）。
    let contentOverlayView = UIView()

    private let videoView = UIView()
    private let controls = UIView()
    private let gradientView = UIView()
    private let gradient = CAGradientLayer()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progress = VLCProgressBar()
    private let scrubber = VLCScrubberView()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let buttonsRow = UIStackView()
    private let buttonTip = UILabel()
    private let pill = VLCCapsuleButton(title: "推荐和评论")
    private let contextualStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let preview = UIView()
    private let previewImage = UIImageView()
    private let previewTime = UILabel()
    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let panelTitle = UILabel()

    private var barButtons = [VLCBarButton]()
    private var contextualButtons = [VLCCapsuleButton]()
    private var popover: VLCMenuPopover?
    private weak var popoverAnchor: VLCBarButton?
    private weak var panelChild: UIViewController?

    private(set) var controlsVisible = false
    private var panelOpen = false
    private var scrubTarget: Double?
    private var scrubWasPlaying = false
    private var hideWork: DispatchWorkItem?
    private var progressTimer: Timer?
    private var thumbnails: VLCThumbnailProvider?
    private var playbackRate: Float = 1
    private var isBuffering = true

    /// 拖动预览图用的视频地址（本地代理上码率最低的流）。
    var thumbnailURL: URL? {
        didSet {
            thumbnails?.cancel()
            thumbnails = thumbnailURL.map { VLCThumbnailProvider(url: $0) }
        }
    }

    private let sideInset: CGFloat = 90
    private let panelHeight: CGFloat = 760

    deinit {
        progressTimer?.invalidate()
        thumbnails?.cancel()
    }

    // MARK: - PlayerHost

    var hostViewController: UIViewController { self }
    var avPlayerViewController: AVPlayerViewController? { nil }

    var contextualActions: [UIAction] = [] {
        didSet { rebuildContextualButtons() }
    }

    var infoViewActions: [UIAction] = [] {
        didSet { rebuildButtons() }
    }

    var customInfoViewControllers: [UIViewController] = [] {
        didSet { updatePanelContent() }
    }

    var transportBarCustomMenuItems: [UIMenuElement] = [] {
        didSet { rebuildButtons() }
    }

    func applyPlaybackSpeed(_ speed: PlaySpeed) {
        playbackRate = speed.value
        engine?.playbackRate = speed.value
    }

    func setDisplayInfo(title: String?, subtitle: String?) {
        loadViewIfNeeded()
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    // MARK: - 内核

    /// 装上（或换掉）VLC 内核。
    func install(engine newEngine: VLCPlayerEngine) {
        loadViewIfNeeded()
        let old = engine
        guard old !== newEngine else { return }
        engine = newEngine
        newEngine.delegate = self
        newEngine.player.drawable = videoView
        isBuffering = true
        spinner.startAnimating()
        surfaceDelegate?.vlcSurface(self, didReplaceEngine: old, with: newEngine)
        if let old, old !== newEngine { old.shutdown() }
    }

    /// 退出 / 换界面时停掉内核。
    func shutdownEngine() {
        guard let old = engine else { return }
        engine = nil
        surfaceDelegate?.vlcSurface(self, didReplaceEngine: old, with: nil)
        old.shutdown()
        progressTimer?.invalidate()
        progressTimer = nil
        thumbnails?.cancel()
    }

    // MARK: - 视图

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        for sub in [videoView, contentOverlayView] {
            sub.isUserInteractionEnabled = false
            view.addSubview(sub)
            sub.snp.makeConstraints { $0.edges.equalToSuperview() }
        }

        view.addSubview(controls)
        controls.snp.makeConstraints { $0.edges.equalToSuperview() }
        controls.alpha = 0

        gradientView.isUserInteractionEnabled = false
        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.35).cgColor, UIColor.black.withAlphaComponent(0.8).cgColor]
        gradient.locations = [0.35, 0.6, 1]
        gradientView.layer.addSublayer(gradient)
        controls.addSubview(gradientView)
        gradientView.snp.makeConstraints { $0.edges.equalToSuperview() }

        setUpBottomArea()
        setUpPreview()
        setUpPanel()

        contextualStack.axis = .horizontal
        contextualStack.spacing = 24
        view.addSubview(contextualStack)
        contextualStack.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(sideInset)
            make.bottom.equalToSuperview().inset(330)
        }

        spinner.color = .white
        view.addSubview(spinner)
        spinner.snp.makeConstraints { $0.center.equalToSuperview() }
        spinner.startAnimating()

        scrubber.onPress = { [weak self] type in self?.handleScrubberPress(type) }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        scrubber.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        tap.allowedPressTypes = []
        scrubber.addGestureRecognizer(tap)

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer

        rebuildButtons()
        rebuildContextualButtons()
        updatePanelContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = gradientView.bounds
    }

    private func setUpBottomArea() {
        pill.onFocus = { [weak self] in DispatchQueue.main.async { self?.openPanel() } }
        controls.addSubview(pill)
        pill.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().inset(36)
            make.height.equalTo(58)
        }

        buttonsRow.axis = .horizontal
        buttonsRow.spacing = 28
        buttonsRow.alignment = .center
        controls.addSubview(buttonsRow)
        buttonsRow.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(sideInset)
            make.trailing.lessThanOrEqualToSuperview().inset(sideInset)
            make.bottom.equalTo(pill.snp.top).offset(-34)
            make.height.equalTo(84)
        }

        buttonTip.font = .systemFont(ofSize: 22, weight: .semibold)
        buttonTip.textColor = .white
        buttonTip.textAlignment = .center
        buttonTip.alpha = 0
        controls.addSubview(buttonTip)

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
            label.textColor = UIColor.white.withAlphaComponent(0.85)
            controls.addSubview(label)
        }
        elapsedLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(sideInset)
            make.bottom.equalTo(buttonsRow.snp.top).offset(-22)
        }
        remainingLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(sideInset)
            make.bottom.equalTo(elapsedLabel)
        }

        controls.addSubview(progress)
        progress.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(sideInset)
            make.bottom.equalTo(elapsedLabel.snp.top).offset(-12)
            make.height.equalTo(40)
        }
        // 可聚焦的进度条区域放在 controls 外面：控制栏收起时它仍然接收按键和滑动。
        view.addSubview(scrubber)
        scrubber.snp.makeConstraints { make in
            make.edges.equalTo(progress)
        }

        subtitleLabel.font = .systemFont(ofSize: 26, weight: .medium)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        controls.addSubview(subtitleLabel)
        subtitleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(sideInset)
            make.trailing.lessThanOrEqualToSuperview().inset(sideInset)
            make.bottom.equalTo(progress.snp.top).offset(-8)
        }
        titleLabel.font = .systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = .white
        controls.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(sideInset)
            make.trailing.lessThanOrEqualToSuperview().inset(sideInset)
            make.bottom.equalTo(subtitleLabel.snp.top).offset(-6)
        }
    }

    private func setUpPreview() {
        preview.isHidden = true
        preview.isUserInteractionEnabled = false
        controls.addSubview(preview)
        previewImage.contentMode = .scaleAspectFill
        previewImage.clipsToBounds = true
        previewImage.layer.cornerRadius = 14
        previewImage.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        preview.addSubview(previewImage)
        previewImage.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.width.equalTo(400)
            make.height.equalTo(225)
        }
        previewTime.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        previewTime.textColor = .white
        previewTime.textAlignment = .center
        preview.addSubview(previewTime)
        previewTime.snp.makeConstraints { make in
            make.top.equalTo(previewImage.snp.bottom).offset(10)
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview()
        }
    }

    private func setUpPanel() {
        panel.isHidden = true
        panel.layer.cornerRadius = 40
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        view.addSubview(panel)
        panel.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(panelHeight)
        }
        panelTitle.font = .systemFont(ofSize: 28, weight: .bold)
        panelTitle.textColor = UIColor.white.withAlphaComponent(0.7)
        panel.contentView.addSubview(panelTitle)
        panelTitle.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(26)
            make.centerX.equalToSuperview()
        }
    }

    // MARK: - 进度刷新

    private func tick() {
        guard let engine else { return }
        if scrubTarget == nil {
            let duration = engine.duration
            let position = engine.currentTime
            progress.set(fraction: duration > 0 ? position / duration : 0)
            elapsedLabel.text = VLCTimeFormat.string(position)
            remainingLabel.text = "-" + VLCTimeFormat.string(max(0, duration - position))
        }
        let waiting = isBuffering && engine.isPlaying && scrubTarget == nil
        if waiting != spinner.isAnimating {
            if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }

    // MARK: - 控制栏显示 / 收起

    func showControls(autoHide: Bool = true) {
        hideWork?.cancel()
        if !controlsVisible {
            controlsVisible = true
            UIView.animate(withDuration: 0.25) { self.controls.alpha = 1 }
        }
        tick()
        if autoHide { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.engine?.isPlaying == true, self.scrubTarget == nil, self.popover == nil,
                  !self.panelOpen, self.scrubber.isFocused else { return }
            self.hideControls()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func hideControls() {
        hideWork?.cancel()
        guard controlsVisible else { return }
        controlsVisible = false
        UIView.animate(withDuration: 0.35) {
            self.controls.alpha = 0
            self.buttonTip.alpha = 0
        }
        if !scrubber.isFocused {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    // MARK: - 按键与手势

    private func handleScrubberPress(_ type: UIPress.PressType) {
        guard let engine else { return }
        switch type {
        case .select:
            if scrubTarget != nil {
                commitScrub()
            } else {
                togglePlayPause()
            }
        case .playPause:
            if scrubTarget != nil { commitScrub() } else { togglePlayPause() }
        case .leftArrow, .rightArrow:
            let delta: Double = type == .leftArrow ? -10 : 10
            if let target = scrubTarget {
                updateScrub(to: target + delta)
            } else {
                let target = max(0, min(engine.currentTime + delta, max(0, engine.duration - 1)))
                Diag.eventWindow(String(format: "VLC skip to %.1fs", target))
                engine.seek(to: target)
                showControls()
                tick()
            }
        default:
            break
        }
    }

    private func togglePlayPause() {
        guard let engine else { return }
        if engine.isPlaying {
            engine.pause()
            showControls(autoHide: false)
        } else {
            engine.play()
            showControls()
        }
    }

    @objc private func handleTap() {
        guard scrubTarget == nil else { return }
        if controlsVisible { scheduleAutoHide() } else { showControls() }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let engine, engine.duration > 0, popover == nil, !panelOpen else { return }
        switch gesture.state {
        case .began:
            let velocity = gesture.velocity(in: scrubber)
            guard abs(velocity.x) > abs(velocity.y) || scrubTarget != nil else { return }
            if scrubTarget == nil {
                scrubWasPlaying = engine.isPlaying
                if scrubWasPlaying { engine.pause() }
                scrubTarget = engine.currentTime
                progress.emphasized = true
                progress.showsMarker = true
                showControls(autoHide: false)
            }
        case .changed:
            guard let target = scrubTarget else { return }
            let dx = gesture.translation(in: scrubber).x
            gesture.setTranslation(.zero, in: scrubber)
            let speed = abs(gesture.velocity(in: scrubber).x)
            // 一次完整滑动约等于视频时长的 8%（至少 60 秒）；快速甩动最多再放大 4 倍。
            let perPoint = max(60, engine.duration * 0.08) / 1000
            let accel = min(4, 1 + speed / 1500)
            updateScrub(to: target + Double(dx) * perPoint * accel)
        default:
            break
        }
    }

    private func updateScrub(to seconds: Double) {
        guard let engine else { return }
        let duration = engine.duration
        let target = max(0, min(seconds, max(0, duration - 1)))
        scrubTarget = target
        progress.set(fraction: duration > 0 ? target / duration : 0)
        elapsedLabel.text = VLCTimeFormat.string(target)
        remainingLabel.text = "-" + VLCTimeFormat.string(max(0, duration - target))
        showPreview(at: target)
    }

    private func showPreview(at seconds: Double) {
        preview.isHidden = false
        previewTime.text = VLCTimeFormat.string(seconds)
        view.layoutIfNeeded()
        let x = progress.frame.minX + progress.markerX
        let half: CGFloat = 200
        let centerX = min(max(x, sideInset + half), view.bounds.width - sideInset - half)
        preview.snp.remakeConstraints { make in
            make.centerX.equalTo(controls.snp.leading).offset(centerX)
            make.bottom.equalTo(progress.snp.top).offset(-28)
        }
        thumbnails?.image(at: seconds) { [weak self] image in
            guard let self, self.scrubTarget != nil else { return }
            if let image { self.previewImage.image = image }
        }
    }

    private func endScrubUI() {
        scrubTarget = nil
        progress.emphasized = false
        progress.showsMarker = false
        preview.isHidden = true
        previewImage.image = nil
        thumbnails?.cancel()
    }

    private func commitScrub() {
        guard let engine, let target = scrubTarget else { return }
        endScrubUI()
        Diag.eventWindow(String(format: "VLC seek to %.1fs", target))
        engine.seek(to: target)
        if scrubWasPlaying { engine.play() }
        showControls(autoHide: scrubWasPlaying)
        tick()
    }

    private func cancelScrub() {
        guard let engine, scrubTarget != nil else { return }
        endScrubUI()
        if scrubWasPlaying { engine.play() }
        showControls(autoHide: scrubWasPlaying)
        tick()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            handleMenuPress()
            return
        }
        if presses.contains(where: { $0.type == .playPause }), !scrubber.isFocused, popover == nil {
            // 焦点在按钮或面板上时，播放键照样暂停 / 继续。
            togglePlayPause()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesCancelled(presses, with: event)
    }

    private func handleMenuPress() {
        if let popover {
            if popover.canGoBack { popover.goBack() } else { closePopover() }
        } else if panelOpen {
            closePanel()
        } else if scrubTarget != nil {
            cancelScrub()
        } else if controlsVisible {
            hideControls()
        } else {
            surfaceDelegate?.vlcSurfaceRequestsExit(self)
        }
    }

    // MARK: - 焦点

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusOverride { return [focusOverride] }
        if let popover { return [popover] }
        if panelOpen, let panelChild { return [panelChild] }
        if !controlsVisible, let first = contextualButtons.first { return [first] }
        return [scrubber]
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard let next = context.nextFocusedView else { return true }
        if let popover { return next.isDescendant(of: popover) }
        if scrubTarget != nil { return false }
        if panelOpen {
            if next.isDescendant(of: panel) { return true }
            if context.focusHeading == .up { DispatchQueue.main.async { self.closePanel() } }
            return false
        }
        if !controlsVisible {
            if next.isDescendant(of: contextualStack) || next === scrubber { return true }
            // 控制栏收起时往下滑：先把控制栏叫出来，焦点不动。
            if context.focusHeading == .down || context.focusHeading == .up {
                DispatchQueue.main.async { self.showControls() }
            }
            return false
        }
        // 在进度条上左右滑是拖动进度，不是移动焦点。
        if context.previouslyFocusedView === scrubber, context.focusHeading == .left || context.focusHeading == .right {
            return false
        }
        return true
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let button = context.nextFocusedView as? VLCBarButton {
            hideWork?.cancel()
            buttonTip.text = button.titleText
            buttonTip.sizeToFit()
            view.layoutIfNeeded()
            let frame = button.convert(button.bounds, to: controls)
            buttonTip.center = CGPoint(x: frame.midX, y: frame.minY - 30)
            coordinator.addCoordinatedAnimations { self.buttonTip.alpha = button.titleText.isEmpty ? 0 : 1 }
        } else {
            coordinator.addCoordinatedAnimations { self.buttonTip.alpha = 0 }
            if context.nextFocusedView === scrubber, controlsVisible { scheduleAutoHide() }
        }
    }

    // MARK: - 按钮

    private func rebuildButtons() {
        guard isViewLoaded else { return }
        let focusedIndex = barButtons.firstIndex { $0.isFocused }
        barButtons.forEach { $0.removeFromSuperview() }
        barButtons = (transportBarCustomMenuItems + infoViewActions.map { $0 as UIMenuElement }).map { element in
            let button = VLCBarButton(element: element)
            if let action = element as? UIAction {
                button.addAction(UIAction { [weak self, weak button] _ in
                    VLCActionRunner.perform(action)
                    button?.refresh()
                    self?.scheduleAutoHideIfNeeded()
                }, for: .primaryActionTriggered)
            } else if let menu = element as? UIMenu {
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let self, let button else { return }
                    self.presentMenu(menu, from: button)
                }, for: .primaryActionTriggered)
            }
            buttonsRow.addArrangedSubview(button)
            button.snp.makeConstraints { make in
                make.height.equalTo(72)
                if button.isCircle { make.width.equalTo(72) }
            }
            return button
        }
        if let focusedIndex, barButtons.indices.contains(focusedIndex) {
            restoreFocus(to: barButtons[focusedIndex])
        }
    }

    private func scheduleAutoHideIfNeeded() {
        if scrubber.isFocused { scheduleAutoHide() }
    }

    private var pendingFocus: UIView?

    private func restoreFocus(to view: UIView) {
        pendingFocus = view
        DispatchQueue.main.async { [weak self] in
            guard let self, let target = self.pendingFocus else { return }
            self.pendingFocus = nil
            guard self.controlsVisible, self.popover == nil, !self.panelOpen, target.window != nil else { return }
            self.focusOverride = target
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            self.focusOverride = nil
        }
    }

    private var focusOverride: UIView?

    private func presentMenu(_ menu: UIMenu, from button: VLCBarButton) {
        closePopover()
        hideWork?.cancel()
        let popover = VLCMenuPopover(menu: menu)
        popover.onPerformed = { [weak self] in
            self?.closePopover()
        }
        view.addSubview(popover)
        view.layoutIfNeeded()
        let frame = button.convert(button.bounds, to: view)
        let width: CGFloat = 600
        let left = min(max(sideInset, frame.midX - 60), view.bounds.width - sideInset - width)
        popover.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(left)
            make.width.equalTo(width)
            make.bottom.equalToSuperview().offset(frame.minY - 24 - view.bounds.height)
        }
        popover.alpha = 0
        self.popover = popover
        popoverAnchor = button
        UIView.animate(withDuration: 0.2) { popover.alpha = 1 }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func closePopover() {
        guard let popover else { return }
        self.popover = nil
        UIView.animate(withDuration: 0.15, animations: { popover.alpha = 0 }) { _ in popover.removeFromSuperview() }
        barButtons.forEach { $0.refresh() }
        if let anchor = popoverAnchor, anchor.superview != nil {
            restoreFocus(to: anchor)
        } else {
            setNeedsFocusUpdate()
        }
    }

    private func rebuildContextualButtons() {
        guard isViewLoaded else { return }
        let hadFocus = contextualButtons.contains { $0.isFocused }
        contextualButtons.forEach { $0.removeFromSuperview() }
        contextualButtons = contextualActions.map { action in
            let button = VLCCapsuleButton(title: action.title)
            button.addAction(UIAction { _ in VLCActionRunner.perform(action) }, for: .primaryActionTriggered)
            contextualStack.addArrangedSubview(button)
            button.snp.makeConstraints { $0.height.equalTo(66) }
            return button
        }
        if !contextualButtons.isEmpty, !controlsVisible, popover == nil, !panelOpen {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        } else if hadFocus {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    // MARK: - 推荐和评论面板

    private func updatePanelContent() {
        guard isViewLoaded else { return }
        let content = customInfoViewControllers.first
        pill.isHidden = content == nil
        pill.title = content?.title ?? "推荐和评论"
        panelTitle.text = content?.title
        if let panelChild, panelChild !== content {
            panelChild.willMove(toParent: nil)
            panelChild.view.removeFromSuperview()
            panelChild.removeFromParent()
            self.panelChild = nil
        }
        buttonsRow.snp.updateConstraints { make in
            make.bottom.equalTo(pill.snp.top).offset(content == nil ? 58 : -34)
        }
    }

    private func openPanel() {
        guard !panelOpen, let content = customInfoViewControllers.first else { return }
        panelOpen = true
        hideWork?.cancel()
        if panelChild !== content {
            addChild(content)
            panel.contentView.addSubview(content.view)
            content.view.snp.makeConstraints { make in
                make.top.equalTo(panelTitle.snp.bottom).offset(10)
                make.leading.trailing.bottom.equalToSuperview()
            }
            content.didMove(toParent: self)
            panelChild = content
        }
        panel.isHidden = false
        panel.transform = CGAffineTransform(translationX: 0, y: panelHeight)
        UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseOut) {
            self.panel.transform = .identity
            self.controls.alpha = 0
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func closePanel() {
        guard panelOpen else { return }
        panelOpen = false
        UIView.animate(withDuration: 0.3, animations: {
            self.panel.transform = CGAffineTransform(translationX: 0, y: self.panelHeight)
            self.controls.alpha = self.controlsVisible ? 1 : 0
        }) { _ in
            if !self.panelOpen { self.panel.isHidden = true }
        }
        if let last = barButtons.last {
            restoreFocus(to: last)
        } else {
            setNeedsFocusUpdate()
        }
    }
}

// MARK: - 内核事件

extension VLCPlayerSurface: VLCPlayerEngineDelegate {
    func vlcEngineDidBecomeReady(_ engine: VLCPlayerEngine) {
        guard engine === self.engine else { return }
        engine.playbackRate = playbackRate
        surfaceDelegate?.vlcSurfaceEngineDidBecomeReady(self)
    }

    func vlcEngineDidStart(_ engine: VLCPlayerEngine) {
        guard engine === self.engine else { return }
        surfaceDelegate?.vlcSurfaceEngineDidStart(self)
    }

    func vlcEngineDidPause(_ engine: VLCPlayerEngine) {
        guard engine === self.engine else { return }
        surfaceDelegate?.vlcSurfaceEngineDidPause(self)
    }

    func vlcEngineDidEnd(_ engine: VLCPlayerEngine) {
        guard engine === self.engine else { return }
        surfaceDelegate?.vlcSurfaceEngineDidEnd(self)
    }

    func vlcEngineDidFail(_ engine: VLCPlayerEngine) {
        guard engine === self.engine else { return }
        surfaceDelegate?.vlcSurfaceEngineDidFail(self)
    }

    func vlcEngine(_ engine: VLCPlayerEngine, isBuffering: Bool) {
        guard engine === self.engine else { return }
        self.isBuffering = isBuffering
        tick()
    }
}
