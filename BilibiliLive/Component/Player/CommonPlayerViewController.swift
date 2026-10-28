//
//  CommonPlayerViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//
//  播放器容器：管理插件，把内核事件分发给插件（统一底层，见 PlayerEngine.swift）。
//  界面始终是系统播放器 AVPlayerViewController（返回键等系统问题的兜底逻辑都在这里）。
//  VLC 模式下系统播放器播一路静音的低码率影子视频提供界面和时间轴，VLC 画面叠在上面（VLCRendererPlugin）。
//

import AVKit
import Kingfisher
import UIKit

class CommonPlayerViewController: UIViewController {
    private let playerVC = AVPlayerViewController()
    private var activePlugins = [CommonPlayerPlugin]()
    private var observations = Set<NSKeyValueObservation>()
    private var rateObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var playToEndObserver: Any?
    private var playbackStalledObserver: Any?
    private var isEnd = false
    private var isRestoringFromPip = false
    /// 底部控制栏（标题、胶囊按钮、进度条）当前是否显示（系统播放器）。
    private var transportBarVisible = false
    /// 新 AVPlayerItem ready 后是否自动 play。换 CDN host 等场景可临时关掉，由调用方按用户暂停状态决定是否续播。
    var autoPlayWhenReady = true
    /// 已请求退出（播放器上面还盖着弹窗时，本控制器的 isBeingDismissed 可能不为真）。
    private(set) var exitRequested = false

    /// 进入时就装上的界面。
    var initialEngineKind: PlayerEngineKind? = .system
    /// 当前装着的界面（只有系统播放器界面）。
    private(set) var installedEngineKind: PlayerEngineKind?
    /// 当前内核（包着 playerVC.player）。
    private(set) var currentEngine: PlayerEngine?

    /// 插件看到的界面。
    var playerHost: PlayerHost { playerVC }

    func exitPlayer(animated: Bool = true) {
        guard !exitRequested else { return }
        Diag.mark("PLAYER \(Diag.id(self)) exitPlayer presented=\(presentedViewController.map { String(describing: type(of: $0)) } ?? "none")")
        exitRequested = true
        // 上面还盖着弹窗时，直接对自己 dismiss 只会关掉弹窗；从呈现者关闭整条链。
        if presentedViewController != nil, let presenter = presentingViewController {
            presenter.dismiss(animated: animated)
        } else {
            dismiss(animated: animated)
        }
    }

    var showsPlaybackControls = true
    var allowsPictureInPicturePlayback = true

    deinit {
        Diag.mark("PLAYER \(Diag.id(self)) deinit")
        cleanUpPlayerOnExit(force: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Diag.mark("PLAYER \(Diag.id(self)) viewDidLoad \(type(of: self))")
        view.backgroundColor = .black
        if let initialEngineKind { installSurface(initialEngineKind) }
    }

    // MARK: - 界面

    /// 装上系统播放器界面（VLC 模式也用它，见 VLCRendererPlugin）。
    func installSurface(_ kind: PlayerEngineKind) {
        guard installedEngineKind == nil else { return }
        installedEngineKind = .system
        installAVKitSurface()
        setNeedsFocusUpdate()
    }

    /// VLC 模式：画中画里只会是低码率的影子视频，关掉。
    func setPictureInPictureAllowed(_ allowed: Bool) {
        allowsPictureInPicturePlayback = allowed
        playerVC.allowsPictureInPicturePlayback = allowed
    }

    private var avkitObserved = false

    // MARK: - 加载背景（封面毛玻璃，代替黑屏）

    private let loadingBackdrop = PlayerLoadingBackdropView()
    private var readyForDisplayObservation: NSKeyValueObservation?
    /// VLC 模式：第一帧由 VLCRendererPlugin 通知，不看系统播放器（系统那路是影子）。
    var loadingBackdropWaitsForExternalFrame = false

    /// 开始加载一个视频时调用；封面可以之后拿到再调一次补上。
    func showLoadingBackdrop(cover: URL?) {
        hideEndOverlay()
        loadingBackdrop.show(cover: cover)
    }

    /// 画面出来了，淡出加载背景。
    func loadingBackdropFrameReady() {
        loadingBackdrop.hide()
    }

    // MARK: - 播完：最后一帧毛玻璃 + 中间的重播按钮

    /// 毛玻璃放在画面层（控制栏、下滑面板之下）；按钮放在播放器上面（能拿到焦点）。
    private let endBlur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private lazy var replayOverlay = PlayerReplayOverlayView()
    private(set) var endOverlayShown = false
    /// 按钮是否显示并拿着焦点（按下方向键后让给系统播放器，好去推荐和评论）。
    private var replayButtonActive = false

    func showEndOverlay() {
        guard !endOverlayShown else { return }
        endOverlayShown = true
        Diag.mark("PLAYER \(Diag.id(self)) end overlay shown")
        restoreControls()
        if endBlur.superview == nil, let overlay = playerVC.contentOverlayView {
            endBlur.isUserInteractionEnabled = false
            overlay.addSubview(endBlur)
            endBlur.snp.makeConstraints { $0.edges.equalToSuperview() }
        }
        endBlur.superview?.bringSubviewToFront(endBlur)
        endBlur.isHidden = false
        endBlur.alpha = 0
        UIView.animate(withDuration: 0.3) { self.endBlur.alpha = 0.5 }
        if replayOverlay.superview == nil {
            replayOverlay.onReplay = { [weak self] in self?.replayFromStart() }
            replayOverlay.onLeave = { [weak self] in self?.deactivateReplayButton() }
            replayOverlay.onMenu = { [weak self] in self?.exitPlayer() }
            view.addSubview(replayOverlay)
            replayOverlay.snp.makeConstraints { $0.edges.equalToSuperview() }
        }
        activateReplayButton()
    }

    func hideEndOverlay() {
        guard endOverlayShown else { return }
        endOverlayShown = false
        replayButtonActive = false
        Diag.mark("PLAYER \(Diag.id(self)) end overlay hidden")
        UIView.animate(withDuration: 0.2, animations: { self.endBlur.alpha = 0 }) { _ in
            if !self.endOverlayShown { self.endBlur.isHidden = true }
        }
        replayOverlay.isHidden = true
        setNeedsFocusUpdate()
    }

    private func activateReplayButton() {
        guard endOverlayShown else { return }
        replayButtonActive = true
        view.bringSubviewToFront(replayOverlay)
        replayOverlay.isHidden = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// 在按钮上按下 / 下滑：按钮让开，焦点交给系统播放器（再按下就是推荐和评论）。
    private func deactivateReplayButton() {
        replayButtonActive = false
        replayOverlay.isHidden = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func replayFromStart() {
        guard let engine = currentEngine else { return }
        Diag.mark("PLAYER \(Diag.id(self)) replay")
        hideEndOverlay()
        isEnd = false
        engine.seek(to: 0) { _ in
            DispatchQueue.main.async { engine.play() }
        }
    }

    /// 结束画面下又开始播了（在系统播放器上按了播放、拖回去播）：收起结束画面；还停在结尾就从头播。
    private func handleStartWhileEnded(engine: PlayerEngine) {
        guard endOverlayShown else { return }
        let duration = engine.duration
        if duration > 0, engine.currentTime >= duration - 1 {
            replayFromStart()
        } else {
            isEnd = false
            hideEndOverlay()
        }
    }

    private func installAVKitSurface() {
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        playerVC.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        playerVC.showsPlaybackControls = showsPlaybackControls
        playerVC.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        playerVC.delegate = self
        if loadingBackdrop.superview == nil, let overlay = playerVC.contentOverlayView {
            // 先于插件加进去：VLC 画面插在它下面，弹幕等插件视图在它上面。
            overlay.addSubview(loadingBackdrop)
            loadingBackdrop.snp.makeConstraints { $0.edges.equalToSuperview() }
        }

        guard !avkitObserved else { return }
        avkitObserved = true
        readyForDisplayObservation = playerVC.observe(\.isReadyForDisplay, options: [.new]) { [weak self] vc, _ in
            DispatchQueue.main.async {
                guard let self, vc.isReadyForDisplay, !self.loadingBackdropWaitsForExternalFrame else { return }
                self.loadingBackdrop.hide()
            }
        }
        let playerObservation = playerVC.observe(\.player, options: [.old, .new]) { [weak self] vc, obs in
            Logger.debug("player changed: \(String(describing: obs.oldValue)) -> \(String(describing: obs.newValue))")
            Diag.mark("PLAYER \(Diag.id(self)) avplayer \(Diag.id(obs.oldValue ?? nil)) -> \(Diag.id(obs.newValue ?? nil)) plugins=\(self?.activePlugins.count ?? -1)")
            guard let self, self.installedEngineKind == .system else { return }
            if let oldPlayer = obs.oldValue, let oldPlayer {
                let oldEngine = (self.currentEngine as? AVPlayerEngine).flatMap { $0.player === oldPlayer ? $0 : nil } ?? AVPlayerEngine(player: oldPlayer)
                self.activePlugins.forEach { $0.playerDidCleanUp(engine: oldEngine) }
            }
            self.playerDidChange(player: vc.player)
        }
        observations.insert(playerObservation)
    }


    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 不允许系统用返回键直接关掉播放器（诊断日志实测：AVKit 状态错乱时，返回键会绕过
        // shouldDismiss，被 UIKit 当作「关闭弹出页面」直接关掉）。关闭一律走 exitPlayer。
        isModalInPresentation = true
        presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Diag.mark("PLAYER \(Diag.id(self)) viewDidAppear")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Diag.mark("PLAYER \(Diag.id(self)) viewDidDisappear dismissing=\(isBeingDismissed) exit=\(exitRequested)")
        if installedEngineKind != nil {
            activePlugins.forEach { $0.playerDidDismiss(host: playerHost) }
        }
        cleanUpPlayerOnExit()
    }

    // MARK: 返回键（系统播放器）
    //
    // 诊断日志实测：在控制栏上选过胶囊按钮 / 打开过菜单后，焦点被送回画面时，系统控制栏仍显示，
    // 但下一次返回 AVKit 不再处理（既不收起控制栏，也不调用 shouldDismiss），
    // 返回键一路传到 UIKit，被当作「关闭当前弹出的页面」直接把播放器关了。
    // 这里在按下返回的那一刻记录：控制栏是否显示、焦点是否在画面上（不在按钮或菜单里）。
    // 两者都成立时拦下这次返回，让控制栏收起（AVKit 自己收了就什么都不做），不关闭播放器。
    private var interceptMenuPress = false
    /// 最近一次「控制栏显示、焦点在画面上」时按下返回的时间。
    private var guardedMenuPressAt: TimeInterval?

    func shouldBlockUnexpectedDismiss() -> Bool {
        guard !exitRequested, let at = guardedMenuPressAt else { return false }
        return ProcessInfo.processInfo.systemUptime - at < 1.5
    }

    func handleBlockedDismiss() {
        guardedMenuPressAt = nil
        if transportBarVisible { hideTransportBar() }
    }

    private var focusIsOnVideoSurface: Bool {
        guard let focused = view.window?.windowScene?.focusSystem?.focusedItem as? UIView else { return true }
        var current: UIView? = focused
        while let item = current, item !== playerVC.view {
            if item is UICollectionViewCell || item is UITableViewCell || NSStringFromClass(type(of: item)).contains("Menu") { return false }
            current = item.superview
        }
        return true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if installedEngineKind == .system, presses.contains(where: { $0.type == .menu }) {
            interceptMenuPress = transportBarVisible && focusIsOnVideoSurface && presentedViewController == nil
            Diag.mark("PLAYER \(Diag.id(self)) menu down bar=\(transportBarVisible) intercept=\(interceptMenuPress)")
            if interceptMenuPress {
                guardedMenuPressAt = ProcessInfo.processInfo.systemUptime
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), interceptMenuPress {
            interceptMenuPress = false
            // AVKit 正常情况下已经在这一下收起了控制栏；没收起就由我们收起。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.transportBarVisible, !self.exitRequested else { return }
                Diag.mark("PLAYER \(Diag.id(self)) AVKit ignored back; hiding transport bar ourselves")
                self.hideTransportBar()
            }
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), interceptMenuPress {
            interceptMenuPress = false
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    /// 控制栏被我们强制收起后，系统控件处于关闭状态，直到用户下一次操作才恢复。
    /// （收起后马上恢复会让 AVKit 把控制栏又显示出来：实测「消失一下又出现」。）
    private(set) var controlsSuppressed = false

    private func hideTransportBar() {
        transportBarVisible = false
        controlsSuppressed = true
        playerVC.showsPlaybackControls = false
        Diag.mark("PLAYER \(Diag.id(self)) controls suppressed")
        // 不能在后台自动恢复：诊断日志实测，系统控件一打开 AVKit 就立刻把控制栏显示出来
        // （恢复后 20ms 内 transportBar -> visible），表现为控制栏自己蹦出来。
        // 只在用户下一次操作时恢复；代价是那一次「字幕」按钮会晚零点几秒出现。
    }

    private func restoreControls() {
        guard controlsSuppressed else { return }
        controlsSuppressed = false
        playerVC.showsPlaybackControls = showsPlaybackControls
        Diag.mark("PLAYER \(Diag.id(self)) controls restored")
    }

    /// 由窗口在分发前调用：控件被收起期间，遥控器按键由这里处理（此时 AVKit 不接按键，
    /// 焦点可能无处可落，不能交给系统默认处理，否则返回键会直接退到桌面）。
    func consumePressWhileSuppressed(_ event: UIPressesEvent) -> Bool {
        guard controlsSuppressed, !exitRequested, presentedViewController == nil else { return false }
        for press in event.allPresses {
            switch press.type {
            case .menu:
                // 控制栏已收起：返回 = 退出播放。
                if press.phase == .ended { exitPlayer() }
            case .select, .playPause:
                if press.phase == .ended {
                    restoreControls()
                    if let player = playerVC.player {
                        if player.rate > 0 { player.pause() } else { player.play() }
                    }
                }
            default:
                if press.phase == .began { restoreControls() }
            }
        }
        return true
    }

    /// 触控板滑动：恢复系统控件（事件照常分发）。
    func noteTouchWhileSuppressed() {
        restoreControls()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if endOverlayShown, replayButtonActive { return [replayOverlay.button] }
        return installedEngineKind == .system ? [playerVC.view] : []
    }

    // MARK: - 插件

    func addPlugin(plugin: CommonPlayerPlugin) {
        if activePlugins.contains(where: { $0 == plugin }) {
            return
        }
        if let overlay = playerVC.contentOverlayView { plugin.addViewToPlayerOverlay(container: overlay) }
        activePlugins.append(plugin)
        plugin.playerDidLoad(host: playerHost)
        if !playerHost.transportBarCustomMenuItems.isEmpty {
            updateMenus()
        }
    }

    func removePlugin(plugin: CommonPlayerPlugin) {
        let removingPlugins = activePlugins.filter { $0 == plugin }
        removingPlugins.forEach { $0.playerWillCleanUp(host: playerHost) }
        if let currentEngine {
            removingPlugins.forEach { $0.playerDidCleanUp(engine: currentEngine) }
        }
        activePlugins.removeAll { $0 == plugin }
    }

    func removeAllPlugins() {
        guard !activePlugins.isEmpty else { return }
        Diag.mark("PLAYER \(Diag.id(self)) removeAllPlugins n=\(activePlugins.count) avplayer=\(Diag.id(playerVC.player))")
        let host = playerHost
        activePlugins.forEach { $0.playerWillCleanUp(host: host) }
        if let engine = currentEngine {
            activePlugins.forEach { $0.playerDidCleanUp(engine: engine) }
        }
        activePlugins.removeAll()
    }

    // 子类钩子
    func playerWillStart(engine: PlayerEngine) {}
    func playerDidStart(engine: PlayerEngine) {}
    func playerDidEnd(engine: PlayerEngine) {}
    func playerDidStall(engine: PlayerEngine) {}
    func playerDidFail(engine: PlayerEngine) {}

    func showErrorAlertAndExit(title: String = "播放失败", message: String = "未知错误") {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let actionOk = UIAlertAction(title: "OK", style: .default) {
            [weak self] _ in
            self?.exitPlayer()
        }
        alertController.addAction(actionOk)
        present(alertController, animated: true, completion: nil)
    }

    func updateMenus() {
        var menus = [UIMenuElement]()
        for activePlugin in activePlugins {
            let newMenus = activePlugin.addMenuItems(current: &menus)
            menus.append(contentsOf: newMenus)
        }
        // 底部控制栏最左侧固定顺序：点赞、画质、设置、弹幕，其余保持原顺序。
        menus = menus.enumerated().sorted { lhs, rhs in
            let a = Self.menuRank(lhs.element), b = Self.menuRank(rhs.element)
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
        playerHost.transportBarCustomMenuItems = menus
    }

    private static func menuRank(_ element: UIMenuElement) -> Int {
        if let action = element as? UIAction {
            if action.identifier.rawValue == "btr.interaction.like" { return 0 }
            if action.title == "Show Danmu" { return 3 }
        }
        if let menu = element as? UIMenu {
            switch menu.identifier.rawValue {
            case "quality": return 1
            case "setting": return 2
            default: break
            }
            if menu.title == "弹幕设置" { return 4 }
        }
        return 10
    }

    func stopPlayback() {
        cleanUpPlayerOnExit(force: true)
    }

    func currentPlaybackTimeInSeconds() -> Int? {
        guard let seconds = currentEngine?.currentTime, seconds.isFinite, seconds > 0 else { return nil }
        return Int(seconds.rounded(.down))
    }

    private func cleanUpPlayerOnExit(force: Bool = false) {
        let isPictureInPictureRunning = PipRecorder.shared.playingPipViewController.contains { $0.playerVC == playerVC }
        let shouldCleanUp = force || ((isBeingDismissed || exitRequested || isMovingFromParent || navigationController?.isBeingDismissed == true) && !isPictureInPictureRunning)
        guard shouldCleanUp else { return }
        Diag.mark("PLAYER \(Diag.id(self)) cleanUpOnExit force=\(force) pip=\(isPictureInPictureRunning)")

        cleanUpObserver()

        let player = playerVC.player
        player?.pause()
        // Plugins may still be preparing the first player. Always run their
        // cleanup hook even when the engine has not been installed yet.
        removeAllPlugins()
        player?.replaceCurrentItem(with: nil)
        playerVC.player = nil
        currentEngine = nil
    }

    private func cleanUpObserver() {
        rateObserver = nil
        statusObserver = nil
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = nil
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = nil
    }
}

// MARK: - 系统播放器内核事件

extension CommonPlayerViewController {
    private func playerDidChange(player: AVPlayer?) {
        if let player {
            let engine = AVPlayerEngine(player: player)
            currentEngine = engine
            activePlugins.forEach { $0.playerDidChange(engine: engine) }
            rateObserver = player.observe(\.rate, options: [.old, .new]) {
                [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.playerRateDidChange(engine: engine)
                }
            }
            if let playItem = player.currentItem {
                observePlayerItem(playItem, engine: engine)
            }
            updateMenus()
        } else {
            currentEngine = nil
            cleanUpObserver()
        }
    }

    private func playerRateDidChange(engine: AVPlayerEngine) {
        guard currentEngine === engine else { return }
        if engine.player.rate > 0 {
            handleStartWhileEnded(engine: engine)
            activePlugins.forEach { $0.playerDidStart(engine: engine) }
            playerDidStart(engine: engine)
        } else if engine.player.rate == 0 {
            if !isEnd {
                activePlugins.forEach { $0.playerDidPause(engine: engine) }
            }
        }
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem, engine: AVPlayerEngine) {
        statusObserver = playerItem.observe(\.status, options: [.new, .old]) {
            [weak self] item, _ in
            guard let self, self.currentEngine === engine else { return }
            let player = engine.player
            Diag.mark("PLAYER \(Diag.id(self)) item \(Diag.id(item)) status=\(item.status.rawValue) avplayer=\(Diag.id(player)) owner=\(Diag.id(item.asset))")
            switch item.status {
            case .readyToPlay:
                isEnd = false
                activePlugins.forEach { $0.playerWillStart(engine: engine) }
                playerWillStart(engine: engine)
                if autoPlayWhenReady {
                    player.play()
                }
            case .failed:
                activePlugins.forEach { $0.playerDidFail(engine: engine) }
                playerDidFail(engine: engine)
            default:
                break
            }
        }
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            guard let self, self.currentEngine === engine else { return }
            isEnd = true
            activePlugins.forEach { $0.playerDidEnd(engine: engine) }
            playerDidEnd(engine: engine)
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main) { [weak self] _ in
            guard let self, self.currentEngine === engine else { return }
            activePlugins.forEach { $0.playerDidStall(engine: engine) }
            playerDidStall(engine: engine)
        }
    }
}

extension CommonPlayerViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        false
    }

    /// 系统想用返回键关掉播放器时：控制栏还显示着就先收起，否则正常退出。
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        Diag.mark("PLAYER \(Diag.id(self)) system tried to dismiss bar=\(transportBarVisible)")
        if transportBarVisible {
            hideTransportBar()
        } else {
            exitPlayer()
        }
    }
}

extension CommonPlayerViewController: AVPlayerViewControllerDelegate {
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willTransitionToVisibilityOfTransportBar visible: Bool,
                              with coordinator: AVPlayerViewControllerAnimationCoordinator)
    {
        transportBarVisible = visible
        Diag.mark("PLAYER \(Diag.id(self)) transportBar -> \(visible ? "visible" : "hidden")")
        // 结束画面下，系统控制栏收起、焦点回到画面（不在下滑面板里）时，把重播按钮放回来。
        if !visible, endOverlayShown, !replayButtonActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.endOverlayShown, !self.replayButtonActive, !self.transportBarVisible,
                      self.focusIsOnVideoSurface, self.presentedViewController == nil else { return }
                self.activateReplayButton()
            }
        }
    }

    @objc func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        Diag.mark("PLAYER \(Diag.id(self)) shouldDismiss (back) transportBar=\(transportBarVisible)")
        // 系统的问题：在控制栏上点过胶囊按钮（或打开过菜单）后，返回键把焦点送回进度条，
        // 下一次返回就直接要求关闭播放器，跳过了「先收起控制栏」这一步。
        // 控制栏还显示着时，这次返回只收起控制栏，回到全屏画面。
        if transportBarVisible, playerViewController.showsPlaybackControls {
            hideTransportBar()
            return false
        }
        if let presentedViewController = UIViewController.topMostViewController() as? CommonPlayerViewController,
           presentedViewController.playerVC == playerViewController
        {
            exitPlayer()
            return false
        }
        return false
    }

    @objc func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_: AVPlayerViewController) -> Bool {
        return true
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Diag.mark("PLAYER \(Diag.id(self)) PiP will start")
        isRestoringFromPip = false
        PipRecorder.shared.playingPipViewController.append(self)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Diag.mark("PLAYER \(Diag.id(self)) PiP did stop restoring=\(isRestoringFromPip)")
        PipRecorder.shared.playingPipViewController.removeAll { $0.playerVC == playerViewController }
        if !isRestoringFromPip {
            // 用户点 ✕ 关闭 PiP，清理资源
            cleanUpPlayerOnExit(force: true)
        }
        isRestoringFromPip = false
    }

    @objc func playerViewController(_ playerViewController: AVPlayerViewController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void)
    {
        isRestoringFromPip = true
        let presentedViewController = UIViewController.topMostViewController()
        Diag.mark("PLAYER \(Diag.id(self)) PiP restore top=\(type(of: presentedViewController))")
        guard let containerPlayer = PipRecorder.shared.playingPipViewController.first(where: { $0.playerVC == playerViewController }) else {
            completionHandler(false)
            return
        }
        if presentedViewController is CommonPlayerViewController {
            let parent = presentedViewController.presentingViewController
            presentedViewController.dismiss(animated: false) {
                parent?.present(containerPlayer, animated: false)
                completionHandler(true)
            }
        } else {
            presentedViewController.present(containerPlayer, animated: false) {
                completionHandler(true)
            }
        }
    }

    class PipRecorder {
        static let shared = PipRecorder()
        var playingPipViewController = [CommonPlayerViewController]()
    }
}

/// 播放器加载时的背景：视频封面铺满，叠一层比主界面薄的毛玻璃。
final class PlayerLoadingBackdropView: UIView {
    private let imageView = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let dim = UIView()
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview().inset(-40) }
        addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        // 主界面背景毛玻璃 0.55 + 暗渐变；这里稍薄一点。
        blur.alpha = 0.45
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.15)
        addSubview(dim)
        dim.snp.makeConstraints { $0.edges.equalToSuperview() }
        alpha = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(cover: URL?) {
        layer.removeAllAnimations()
        isHidden = false
        alpha = 1
        superview?.bringSubviewToFront(self)
        if let cover {
            guard cover != currentURL else { return }
            currentURL = cover
            imageView.kf.setImage(with: cover, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 960, height: 540))),
                                                         .scaleFactor(UIScreen.main.scale), .transition(.fade(0.2))])
        } else if currentURL != nil {
            currentURL = nil
            imageView.kf.cancelDownloadTask()
            imageView.image = nil
        }
    }

    func hide() {
        guard !isHidden, alpha > 0 else { return }
        UIView.animate(withDuration: 0.3, animations: { self.alpha = 0 }) { finished in
            if finished, self.alpha == 0 { self.isHidden = true }
        }
    }
}

/// 播完后屏幕中间的「重播」按钮。只有按钮能拿焦点，其余区域不挡操作。
final class PlayerReplayOverlayView: UIView {
    let button: UIButton
    var onReplay: (() -> Void)?
    /// 按下方向键 / 下滑：离开按钮。
    var onLeave: (() -> Void)?
    var onMenu: (() -> Void)?

    override init(frame: CGRect) {
        var config = UIButton.Configuration.filled()
        config.title = "重播"
        config.image = UIImage(systemName: "arrow.counterclockwise")
        config.imagePadding = 14
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 22, leading: 48, bottom: 22, trailing: 48)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 34, weight: .semibold)
            return attributes
        }
        button = UIButton(configuration: config)
        super.init(frame: frame)
        addSubview(button)
        button.snp.makeConstraints { $0.center.equalToSuperview() }
        button.addAction(UIAction { [weak self] _ in self?.onReplay?() }, for: .primaryActionTriggered)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        swipe.direction = .down
        addGestureRecognizer(swipe)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    @objc private func swipedDown() {
        onLeave?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .downArrow || $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onMenu?()
            return
        }
        if presses.contains(where: { $0.type == .downArrow }) {
            onLeave?()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .downArrow || $0.type == .menu }) { return }
        super.pressesCancelled(presses, with: event)
    }
}
