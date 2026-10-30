//
//  VideoLauncher.swift
//  BilibiliLive
//
//  所有列表进入视频的统一入口：直接打开播放器（不再经过详情页）。
//  有观看记录时由播放器询问继续播放还是从头播放。
//

import UIKit

enum VideoLauncher {
    /// - cover: 列表卡片上的封面，加载时立刻用作毛玻璃背景（不必等视频详情）。
    static func play(aid: Int, cid: Int? = nil, epid: Int? = nil, cover: URL? = nil, from presenter: UIViewController? = nil) {
        let epid = (epid ?? 0) > 0 ? epid : nil
        var info = PlayInfo(aid: aid, cid: cid ?? 0, epid: epid ?? 0)
        info.coverURL = cover
        play(info, from: presenter)
    }

    static func play(seasonId: Int, from presenter: UIViewController? = nil) {
        play(PlayInfo(aid: 0, cid: 0, epid: 0, seasonId: seasonId), from: presenter)
    }

    static func play(epid: Int, from presenter: UIViewController? = nil) {
        play(PlayInfo(aid: 0, cid: 0, epid: epid), from: presenter)
    }

    static func play(_ info: PlayInfo, askResume: Bool = true, from presenter: UIViewController? = nil) {
        var info = info
        let presenter = presenter ?? UIViewController.topMostViewController()
        // Open the CDN connections while the play URL is still being requested.
        BTRHTTPClient.shared.preconnect(hosts: BTRCDN.preconnectHosts(region: Settings.btrNodeRegion))
        // 普通视频：和列表预载共用缓存，预载好的播放地址和第一段直接用上。
        let shared = RowPrefetcher.shared
        // 列表里没有 cid 的视频（例如关注动态）：用预载时查到的 cid，省掉播放器里再查一次。
        if !info.isBangumi, !info.isCidVaild, info.aid > 0, let cid = shared.cachedCid(aid: info.aid) {
            info.cid = cid
            Diag.mark("PREFETCH cid_reused aid=\(info.aid) cid=\(cid)")
        }
        let usePrefetch = Settings.prefetchRow && !info.isBangumi && (info.cid ?? 0) > 0
        let player = usePrefetch
            ? VideoPlayerViewController(playInfo: info, playContextCache: shared.contextCache, mediaWarmupManager: shared.warmup)
            : VideoPlayerViewController(playInfo: info)
        player.askResume = askResume
        // 列表页本身可能还盖着别的弹窗（例如搜索），从最上层弹出。
        presenter.topMostViewController().present(player, animated: true)
    }
}
