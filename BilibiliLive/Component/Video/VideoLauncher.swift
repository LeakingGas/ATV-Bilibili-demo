//
//  VideoLauncher.swift
//  BilibiliLive
//
//  所有列表进入视频的统一入口：直接打开播放器（不再经过详情页）。
//  有观看记录时由播放器询问继续播放还是从头播放。
//

import UIKit

@MainActor
enum VideoLauncher {
    static func play(aid: Int, cid: Int? = nil, epid: Int? = nil, from presenter: UIViewController? = nil) {
        let epid = (epid ?? 0) > 0 ? epid : nil
        play(PlayInfo(aid: aid, cid: cid ?? 0, epid: epid ?? 0), from: presenter)
    }

    static func play(seasonId: Int, from presenter: UIViewController? = nil) {
        play(PlayInfo(aid: 0, cid: 0, epid: 0, seasonId: seasonId), from: presenter)
    }

    static func play(epid: Int, from presenter: UIViewController? = nil) {
        play(PlayInfo(aid: 0, cid: 0, epid: epid), from: presenter)
    }

    static func play(_ info: PlayInfo, askResume: Bool = true, from presenter: UIViewController? = nil) {
        let player = VideoPlayerViewController(playInfo: info)
        player.askResume = askResume
        let presenter = presenter ?? UIViewController.topMostViewController()
        // 列表页本身可能还盖着别的弹窗（例如搜索），从最上层弹出。
        presenter.topMostViewController().present(player, animated: true)
    }
}
