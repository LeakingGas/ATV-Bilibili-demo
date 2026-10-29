//
//  SpeedChangerPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVKit

class SpeedChangerPlugin: NSObject, CommonPlayerPlugin {
    private var notifyView: UILabel?
    private weak var containerView: UIView?
    private weak var engine: PlayerEngine?
    private weak var host: PlayerHost?
    private var hasShownSpeedNotification = false

    @Published private(set) var currentPlaySpeed: PlaySpeed = .default

    func addViewToPlayerOverlay(container: UIView) {
        containerView = container
    }

    private func fadeOutNotifyView() {
        UIView.animate(withDuration: 1.0, animations: {
            self.notifyView?.alpha = 0.0 // Fade out to invisible
        }) { _ in
            self.notifyView?.removeFromSuperview() // Optionally remove from superview after fading out
        }
    }

    func playerDidLoad(host: PlayerHost) {
        self.host = host

        currentPlaySpeed = Settings.mediaPlayerSpeed
        installBoostGesture(on: host.hostViewController.view)
        pressObserver = NotificationCenter.default.addObserver(forName: BLWindow.remotePressBegan, object: nil, queue: .main) { [weak self] _ in
            self?.notePress()
        }
    }

    // 连续点按触控板（点按快进快退）时手指一直搭在触控板上，会被误认成「长按 2 倍速」：
    // 最近 0.8 秒内有过点按就不进入 2 倍速；2 倍速中一有点按就退出。
    private var pressObserver: NSObjectProtocol?
    private var lastPressAt = Date.distantPast

    private func notePress() {
        lastPressAt = Date()
        if isBoosting { endBoost() }
    }

    func playerWillCleanUp(host: PlayerHost) {
        endBoost()
        if let boostGesture { boostGesture.view?.removeGestureRecognizer(boostGesture) }
        boostGesture = nil
        if let pressObserver { NotificationCenter.default.removeObserver(pressObserver) }
        pressObserver = nil
    }

    // MARK: - 长按触控板 2 倍速（松手恢复）

    private var boostGesture: UILongPressGestureRecognizer?
    private var isBoosting = false
    private var boostLabel: UILabel?

    private func installBoostGesture(on view: UIView) {
        guard boostGesture == nil else { return }
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleBoost(_:)))
        // Resting a finger on the touch surface (no click); a click keeps AVKit's own behaviour.
        gesture.allowedPressTypes = []
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        gesture.minimumPressDuration = 0.6
        gesture.allowableMovement = 60
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        view.addGestureRecognizer(gesture)
        boostGesture = gesture
    }

    @objc private func handleBoost(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard Date().timeIntervalSince(lastPressAt) > 0.8 else { return }
            guard let engine, engine.isPlaying else { return }
            if let player = engine.avPlayer, player.timeControlStatus != .playing { return }
            isBoosting = true
            host?.applyPlaybackSpeed(PlaySpeed(name: "2X", value: 2))
            (host?.hostViewController.parent as? CommonPlayerViewController)?.beginBoostUI()
            showBoostLabel()
        case .ended, .cancelled, .failed:
            endBoost()
        default:
            break
        }
    }

    private func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        host?.applyPlaybackSpeed(currentPlaySpeed)
        (host?.hostViewController.parent as? CommonPlayerViewController)?.endBoostUI()
        UIView.animate(withDuration: 0.2) { self.boostLabel?.alpha = 0 }
    }

    private func showBoostLabel() {
        if boostLabel == nil, let containerView {
            let label = UILabel()
            label.text = "▶▶ 2X 倍速播放中"
            label.font = .systemFont(ofSize: 30, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            label.layer.cornerRadius = 14
            label.layer.masksToBounds = true
            containerView.addSubview(label)
            label.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.top.equalToSuperview().offset(80)
                make.width.equalTo(340)
                make.height.equalTo(64)
            }
            boostLabel = label
        }
        boostLabel?.superview?.bringSubviewToFront(boostLabel!)
        UIView.animate(withDuration: 0.2) { self.boostLabel?.alpha = 1 }
    }

    func playerDidChange(engine: PlayerEngine) {
        self.engine = engine
    }

    func playerWillStart(engine: PlayerEngine) {
        host?.applyPlaybackSpeed(currentPlaySpeed)
    }

    func playerDidStart(engine: PlayerEngine) {
        guard !hasShownSpeedNotification else { return }
        hasShownSpeedNotification = true

        // 只有在速度不为默认值1时才显示提示
        guard currentPlaySpeed != .default else { return }

        if notifyView == nil {
            notifyView = UILabel()
            notifyView?.backgroundColor = UIColor.black.withAlphaComponent(0.3)
            notifyView?.textColor = UIColor.white
            containerView?.addSubview(notifyView!)
            notifyView?.numberOfLines = 0
            notifyView?.layer.cornerRadius = 10 // Set the corner radius
            notifyView?.layer.masksToBounds = true // Enable masks to bounds
            notifyView?.font = UIFont.systemFont(ofSize: 26)
            notifyView?.textAlignment = NSTextAlignment.center
            notifyView?.snp.makeConstraints { make in
                // make.bottom.equalToSuperview().inset(20) // 20 points from the bottom
                make.center.equalToSuperview() // Center horizontally
                make.width.equalTo(300) // Set a width (optional)
                make.height.equalTo(60) // Set a height (optional)
            }
        }
        notifyView?.isHidden = false
        notifyView?.text = "播放速度设置为 \(currentPlaySpeed.name)"

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.fadeOutNotifyView()
        }
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let gearImage = UIImage(systemName: "gearshape")

        let speedActions = PlaySpeed.blDefaults.map { playSpeed in
            UIAction(title: playSpeed.name, state: currentPlaySpeed == playSpeed ? .on : .off) {
                [weak self] _ in
                guard let self else { return }
                host?.applyPlaybackSpeed(playSpeed)
                currentPlaySpeed = playSpeed
            }
        }
        let playSpeedMenu = UIMenu(title: "播放速度", options: [.displayInline, .singleSelection], children: speedActions)
        let menu = UIMenu(title: "播放设置", image: gearImage, identifier: UIMenu.Identifier(rawValue: "setting"), children: [playSpeedMenu])
        return [menu]
    }
}

struct PlaySpeed: Codable {
    var name: String
    var value: Float
}

extension PlaySpeed: Equatable {
    static let `default` = PlaySpeed(name: "1X", value: 1)

    static let blDefaults = [
        PlaySpeed(name: "0.5X", value: 0.5),
        PlaySpeed(name: "0.75X", value: 0.75),
        PlaySpeed(name: "1X", value: 1),
        PlaySpeed(name: "1.25X", value: 1.25),
        PlaySpeed(name: "1.5X", value: 1.5),
        PlaySpeed(name: "1.75X", value: 1.75),
        PlaySpeed(name: "2X", value: 2),
    ]
}

extension SpeedChangerPlugin: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool
    {
        true
    }
}
