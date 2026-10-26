//
//  AVPlayerMetaUtils.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/6/6.
//

import AVKit
import Kingfisher
import MediaPlayer

enum AVPlayerMetaUtils {
    static func setPlayerInfo(title: String?, subTitle: String?, desp: String?, pic: URL?, player: AVPlayer) async {
        // 只给播放器标题和副标题（控制栏上方显示）。不再提供简介和封面：
        // 系统会因为它们多出一个「简介」页，内容和我们的「详情」页重复。
        _ = desp
        let mapping: [AVMetadataIdentifier: Any?] = [
            .commonIdentifierTitle: title,
            .iTunesMetadataTrackSubTitle: subTitle,
        ]
        let metas = mapping.compactMap { createMetadataItem(for: $0, value: $1) }

        MainActor.callSafely {
            player.currentItem?.externalMetadata = metas
        }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? "",
            MPMediaItemPropertyArtist: subTitle ?? "",
        ]

        if let pic = pic,
           let resource = try? await KingfisherManager.shared.retrieveImage(
               with: Kingfisher.KF.ImageResource(downloadURL: pic),
               options: [
                   .onlyLoadFirstFrame,
                   .processor(DownsamplingImageProcessor(size: CGSize(width: 640, height: 360))),
               ]
           ),
           resource.image.size.width > 0
        {
            // 封面只用于系统「正在播放」信息，不放进播放器元数据。
            let artwork = MPMediaItemArtwork(boundsSize: resource.image.size) { _ in resource.image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    static func createMetadataItem(for identifier: AVMetadataIdentifier, value: Any?) -> AVMetadataItem? {
        if value == nil { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as? NSCopying & NSObjectProtocol
        // Specify "und" to indicate an undefined language.
        item.extendedLanguageTag = "und"
        return item.copy() as? AVMetadataItem
    }
}
