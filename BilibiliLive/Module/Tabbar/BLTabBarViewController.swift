//
//  BLTabBarViewController.swift
//  BilibiliLive
//
//  Created by Etan Chen on 2021/4/5.
//

import UIKit

protocol BLTabBarContentVCProtocol {
    func reloadData()
}

class BLTabBarViewController: UITabBarController, UITabBarControllerDelegate {
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        Settings.bootstrapTabBarPlacementModelIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabBarPagesDidChange), name: .tabBarPagesDidChange, object: nil)
        reloadTabs(animated: false)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        guard let buttonPress = presses.first?.type else { return }
        if buttonPress == .playPause {
            if let reloadVC = topMostViewController() as? BLTabBarContentVCProtocol {
                print("send reload to \(reloadVC)")
                reloadVC.reloadData()
            }
        }
    }

    @objc private func handleTabBarPagesDidChange() {
        reloadTabs(animated: false)
    }

    private func reloadTabs(animated: Bool) {
        let pages = Settings.tabBarPages
        if #available(tvOS 18.0, *) {
            // tvOS 18+：系统悬浮侧边栏。平时隐藏、内容全屏；按返回从左侧弹出，
            // 再按返回回到 Apple TV 主屏幕，按右方向键收起侧边栏继续浏览。
            let previousTab = selectedTab?.identifier
            mode = .tabSidebar
            let newTabs = pages.map { page in
                UITab(title: page.title, image: UIImage(systemName: page.symbolName), identifier: page.rawValue) { [weak self] _ in
                    self?.controller(for: page) ?? UIViewController()
                }
            }
            tabs = newTabs
            if let previousTab, let tab = newTabs.first(where: { $0.identifier == previousTab }) {
                selectedTab = tab
            }
            return
        }
        let previousPage = selectedViewController?.tabBarItem.accessibilityIdentifier
        let controllers = pages.map { controller(for: $0) }

        setViewControllers(controllers, animated: animated)

        if let previousPage, let index = controllers.firstIndex(where: { $0.tabBarItem.accessibilityIdentifier == previousPage }) {
            selectedIndex = index
        }
    }

    private func controller(for page: TabBarPage) -> UIViewController {
        return TabBarPageVCFactory.createVC(for: page)
    }
}
