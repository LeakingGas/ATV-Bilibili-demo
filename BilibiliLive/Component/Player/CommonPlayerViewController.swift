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
    /// 新 AVPlayerItem ready 后是否自动 play。换 CDN host 等场景可临时关掉，由调用方按用户暂停状态决定是否续播。
    var autoPlayWhenReady = true
    /// 已请求退出（播放器上面还盖着弹窗时，本控制器的 isBeingDismissed 可能不为真）。
    private(set) var exitRequested = false

    func exitPlayer(animated: Bool = true) {
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

extension CommonPlayerViewController: AVPlayerViewControllerDelegate {
    @objc func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        Diag.mark("PLAYER \(Diag.id(self)) shouldDismiss (back)")
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
