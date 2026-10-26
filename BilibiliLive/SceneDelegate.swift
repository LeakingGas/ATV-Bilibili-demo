//
//  SceneDelegate.swift
//  BilibiliLive
//

import UIKit

/// 刚启动、还没有任何元素获得焦点时，返回键直接落到窗口上（系统默认退出 App）。
/// 这里先交给主界面：能弹出侧边栏就弹出，不能才按系统默认处理。
final class BLWindow: UIWindow {
    private var menuHandled = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
