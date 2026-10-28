//
//  CommonPlayerPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//
//  插件通过 PlayerHost（界面）和 PlayerEngine（内核）工作，同一个插件可以跑在系统播放器和 VLC 上。
//

import UIKit

protocol CommonPlayerPlugin: NSObject {
    func addViewToPlayerOverlay(container: UIView)
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement]

    func playerDidLoad(host: PlayerHost)
    func playerDidDismiss(host: PlayerHost)
    func playerWillCleanUp(host: PlayerHost)
    func playerDidChange(engine: PlayerEngine)

    func playerWillStart(engine: PlayerEngine)
    func playerDidStart(engine: PlayerEngine)
    func playerDidPause(engine: PlayerEngine)
    func playerDidEnd(engine: PlayerEngine)
    func playerDidStall(engine: PlayerEngine)
    func playerDidFail(engine: PlayerEngine)
    func playerDidCleanUp(engine: PlayerEngine)
    /// 用户在系统界面上跳转（点按快进快退、滑动进度条后确认），参数是目标时间。
    func playerUserNavigated(to seconds: Double)
}

extension CommonPlayerPlugin {
    func addViewToPlayerOverlay(container: UIView) {}
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] { return [] }

    func playerDidLoad(host: PlayerHost) {}
    func playerDidDismiss(host: PlayerHost) {}
    func playerWillCleanUp(host: PlayerHost) {}
    func playerDidChange(engine: PlayerEngine) {}

    func playerWillStart(engine: PlayerEngine) {}
    func playerDidStart(engine: PlayerEngine) {}
    func playerDidPause(engine: PlayerEngine) {}
    func playerDidEnd(engine: PlayerEngine) {}
    func playerDidStall(engine: PlayerEngine) {}
    func playerDidFail(engine: PlayerEngine) {}
    func playerDidCleanUp(engine: PlayerEngine) {}
    func playerUserNavigated(to seconds: Double) {}
}
