//
//  CommonPlayerViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
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
    /// 底部控制栏（标题、胶囊按钮、进度条）当前是否显示。
    private var transportBarVisible = false
    /// 新 AVPlayerItem ready 后是否自动 play。换 CDN host 等场景可临时关掉，由调用方按用户暂停状态决定是否续播。
    var autoPlayWhenReady = true
    /// 已请求退出（播放器上面还盖着弹窗时，本控制器的 isBeingDismissed 可能不为真）。
    private(set) var exitRequested = false

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
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        playerVC.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        playerVC.showsPlaybackControls = showsPlaybackControls
        playerVC.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        playerVC.delegate = self

        let playerObservation = playerVC.observe(\.player, options: [.old, .new]) { [weak self] vc, obs in
            Logger.debug("player changed: \(String(describing: obs.oldValue)) -> \(String(describing: obs.newValue))")
            Diag.mark("PLAYER \(Diag.id(self)) avplayer \(Diag.id(obs.oldValue ?? nil)) -> \(Diag.id(obs.newValue ?? nil)) plugins=\(self?.activePlugins.count ?? -1)")
            if let oldPlayer = obs.oldValue, let oldPlayer {
                self?.activePlugins.forEach { $0.playerDidCleanUp(player: oldPlayer) }
            }
            self?.playerDidChange(player: vc.player)
        }
        observations.insert(playerObservation)
        activePlugins.forEach { $0.playerDidLoad(playerVC: playerVC) }
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
        activePlugins.forEach { $0.playerDidDismiss(playerVC: playerVC) }
        cleanUpPlayerOnExit()
    }

    // MARK: 返回键
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
        if presses.contains(where: { $0.type == .menu }) {
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
        return [playerVC.view]
    }

    func addPlugin(plugin: CommonPlayerPlugin) {
        if activePlugins.contains(where: { $0 == plugin }) {
            return
        }
        plugin.addViewToPlayerOverlay(container: playerVC.contentOverlayView!)
        activePlugins.append(plugin)
        plugin.playerDidLoad(playerVC: playerVC)
        if playerVC.transportBarCustomMenuItems.isEmpty == false {
            updateMenus()
        }
    }

    func removePlugin(plugin: CommonPlayerPlugin) {
        let removingPlugins = activePlugins.filter { $0 == plugin }
        removingPlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            removingPlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll { $0 == plugin }
    }

    func removeAllPlugins() {
        guard !activePlugins.isEmpty else { return }
        Diag.mark("PLAYER \(Diag.id(self)) removeAllPlugins n=\(activePlugins.count) avplayer=\(Diag.id(playerVC.player))")
        activePlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            Logger.debug("removeAllPlugins: clean up player: \(player)")
            activePlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll()
    }

    func playerWillStart(player: AVPlayer) {}
    func playerDidStart(player: AVPlayer) {}
    func playerDidEnd(player: AVPlayer) {}
    func playerDidStall(player: AVPlayer) {}
    func playerDidFail(player: AVPlayer) {}

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
        playerVC.transportBarCustomMenuItems = menus
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
        guard let seconds = playerVC.player?.currentTime().seconds,
              seconds.isFinite,
              seconds > 0
        else {
            return nil
        }
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
        // Plugins may still be preparing the first AVPlayer. Always run their
        // cleanup hook even when playerVC.player has not been installed yet.
        removeAllPlugins()
        player?.replaceCurrentItem(with: nil)
        playerVC.player = nil
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

extension CommonPlayerViewController {
    private func playerDidChange(player: AVPlayer?) {
        if let player {
            activePlugins.forEach { $0.playerDidChange(player: player) }
            rateObserver = player.observe(\.rate, options: [.old, .new]) {
                [weak self] _player, obs in
                DispatchQueue.main.async { [weak self] in
                    self?.playerRateDidChange(player: player)
                }
            }
            if let playItem = player.currentItem {
                observePlayerItem(playItem)
            }
            updateMenus()
        } else {
            cleanUpObserver()
        }
    }

    private func playerRateDidChange(player: AVPlayer) {
        if player.rate > 0 {
            activePlugins.forEach { $0.playerDidStart(player: player) }
            playerDidStart(player: player)
        } else if player.rate == 0 {
            if !isEnd {
                activePlugins.forEach { $0.playerDidPause(player: player) }
            }
        }
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        statusObserver = playerItem.observe(\.status, options: [.new, .old]) {
            [weak self] item, _ in
            guard let self, let player = playerVC.player else { return }
            Diag.mark("PLAYER \(Diag.id(self)) item \(Diag.id(item)) status=\(item.status.rawValue) avplayer=\(Diag.id(player)) owner=\(Diag.id(item.asset))")
            switch item.status {
            case .readyToPlay:
                isEnd = false
                activePlugins.forEach { $0.playerWillStart(player: player) }
                playerWillStart(player: player)
                if autoPlayWhenReady {
                    player.play()
                }
            case .failed:
                activePlugins.forEach { $0.playerDidFail(player: player) }
                playerDidFail(player: player)
            default:
                break
            }
        }
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] note in
            guard let self, let player = playerVC.player else { return }
            isEnd = true
            activePlugins.forEach { $0.playerDidEnd(player: player) }
            playerDidEnd(player: player)
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main) { [weak self] _ in
            guard let self, let player = playerVC.player else { return }
            activePlugins.forEach { $0.playerDidStall(player: player) }
            playerDidStall(player: player)
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
