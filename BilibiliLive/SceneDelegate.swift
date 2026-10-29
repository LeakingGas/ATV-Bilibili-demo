//
//  SceneDelegate.swift
//  BilibiliLive
//

import UIKit

/// 刚启动、还没有任何元素获得焦点时，返回键直接落到窗口上（系统默认退出 App）。
/// 这里先交给主界面：能弹出侧边栏就弹出，不能才按系统默认处理。
final class BLWindow: UIWindow {
    /// 遥控器有按键按下（分发前发出；2 倍速手势据此区分「点按」和「长按」）。
    static let remotePressBegan = Notification.Name("BLWindow.remotePressBegan")
    private var menuHandled = false
    /// 「按下」被播放器代接（没交给系统）的按键：它后面的「松开 / 取消」也必须代接。
    /// 系统收到没见过「按下」的「松开」会直接抛异常闪退（Found untracked presses that are not in the began phase）。
    private var takenPresses = Set<ObjectIdentifier>()
    private weak var takingPlayer: CommonPlayerViewController?

    /// 诊断：记录每一次遥控器按键（在分发给任何界面之前）。
    override func sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent {
            if presses.allPresses.contains(where: { $0.phase == .began }) {
                NotificationCenter.default.post(name: Self.remotePressBegan, object: nil)
            }
            for press in presses.allPresses where press.phase == .began || press.phase == .ended {
                Diag.mark("PRESS \(Diag.pressName(press.type)) \(press.phase == .began ? "down" : "up") focus=\(Diag.describeFocus())")
            }
            // 按下时代接了的键：后续阶段一律代接，不交给系统。
            let taken = presses.allPresses.filter { takenPresses.contains(ObjectIdentifier($0)) }
            if !taken.isEmpty {
                _ = takingPlayer?.consumePressWhileSuppressed(presses)
                for press in taken where press.phase == .ended || press.phase == .cancelled {
                    takenPresses.remove(ObjectIdentifier(press))
                }
                return
            }
            let player = rootViewController?.topMostViewController() as? CommonPlayerViewController
            // 只在「按下」时决定要不要代接；按下交给了系统的键，后续阶段也交给系统。
            if let player, presses.allPresses.contains(where: { $0.phase == .began }),
               player.controlsSuppressed, player.consumePressWhileSuppressed(presses)
            {
                if takenPresses.count > 16 { takenPresses.removeAll() }
                for press in presses.allPresses where press.phase == .began {
                    takenPresses.insert(ObjectIdentifier(press))
                }
                takingPlayer = player
                return
            }
            if let player, presses.allPresses.contains(where: { $0.phase == .began }) {
                player.restoreTransportBar(reason: "press")
            }
        } else if event.type == .touches,
                  let player = rootViewController?.topMostViewController() as? CommonPlayerViewController,
                  player.controlsSuppressed || player.transportBarExcluded
        {
            player.noteTouchWhileSuppressed()
        }
        super.sendEvent(event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            Diag.mark("WINDOW got unhandled menu press")
        }
        if presses.contains(where: { $0.type == .menu }),
           let tabBar = rootViewController as? BLTabBarViewController, tabBar.showSidebarFromWindowMenuPress()
        {
            menuHandled = true
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuHandled {
            menuHandled = false
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuHandled {
            menuHandled = false
            return
        }
        super.pressesCancelled(presses, with: event)
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = BLWindow(windowScene: windowScene)
        self.window = window

        if ApiRequest.isLogin() {
            if let expireDate = ApiRequest.getToken()?.expireDate {
                let now = Date()
                if expireDate.timeIntervalSince(now) < 60 * 60 * 30 {
                    ApiRequest.refreshToken()
                }
            } else {
                ApiRequest.refreshToken()
            }
            window.rootViewController = BLTabBarViewController()
        } else {
            window.rootViewController = LoginViewController.create()
        }
        window.makeKeyAndVisible()
    }

    func showLogin() {
        replaceRootViewController(with: LoginViewController.create(), animated: false)
    }

    func showTabBar() {
        replaceRootViewController(with: BLTabBarViewController(), animated: false)
    }

    func resetTabBar() {
        replaceRootViewController(with: BLTabBarViewController(), animated: true)
    }

    private func replaceRootViewController(with viewController: UIViewController, animated: Bool) {
        guard let window else { return }
        if animated, let snapshot = window.snapshotView(afterScreenUpdates: false) {
            window.rootViewController = viewController
            window.makeKeyAndVisible()
            viewController.view.addSubview(snapshot)
            UIView.animate(withDuration: 0.25, animations: {
                snapshot.alpha = 0
            }, completion: { _ in
                snapshot.removeFromSuperview()
            })
        } else {
            window.rootViewController = viewController
            window.makeKeyAndVisible()
        }
    }
}
