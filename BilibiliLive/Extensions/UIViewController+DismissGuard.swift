//
//  UIViewController+DismissGuard.swift
//  BilibiliLive
//
//  诊断日志实测（tvOS 27）：在播放控制栏上选过按钮 / 打开过菜单、焦点回到画面后，
//  再按返回时 AVKit 偶尔既不收起控制栏、也不调用 playerViewControllerShouldDismiss，
//  而是自己直接 dismiss 播放器（我们在响应链上拦下返回键、设了 isModalInPresentation 都拦不住）。
//  这里在 dismiss 入口兜底：刚按过「应当收起控制栏」的返回键后 1.5 秒内，
//  非我们自己发起的关闭播放器请求一律改成收起控制栏。
//

import ObjectiveC
import UIKit

extension UIViewController {
    static let installDismissGuard: Void = {
        let cls = UIViewController.self
        guard let original = class_getInstanceMethod(cls, #selector(UIViewController.dismiss(animated:completion:))),
              let guarded = class_getInstanceMethod(cls, #selector(UIViewController.bl_guardedDismiss(animated:completion:)))
        else { return }
        method_exchangeImplementations(original, guarded)
    }()

    @objc func bl_guardedDismiss(animated flag: Bool, completion: (() -> Void)?) {
        if let player = CommonPlayerViewController.playerAffected(byDismissOn: self), player.shouldBlockUnexpectedDismiss() {
            Diag.mark("PLAYER \(Diag.id(player)) blocked dismiss from \(type(of: self))")
            player.handleBlockedDismiss()
            return
        }
        // 方法已交换：这里调用的是系统原来的 dismiss。
        bl_guardedDismiss(animated: flag, completion: completion)
    }
}

extension CommonPlayerViewController {
    /// 对 `controller` 调用 dismiss 会关掉哪个播放器（不会关播放器则为 nil）。
    static func playerAffected(byDismissOn controller: UIViewController) -> CommonPlayerViewController? {
        if let presented = controller.presentedViewController {
            // 关闭的是 controller 弹出的整条链。
            var node: UIViewController? = presented
            while let current = node {
                if let player = current as? CommonPlayerViewController { return player }
                node = current.presentedViewController
            }
            return nil
        }
        // controller 自己（或它所在的父控制器）被关闭。
        var node: UIViewController? = controller
        while let current = node {
            if let player = current as? CommonPlayerViewController { return player }
            node = current.parent
        }
        return nil
    }
}
