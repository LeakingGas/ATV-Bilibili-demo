//
//  PlayInfoResolver.swift
//  BilibiliLive
//
//  Created by OpenAI on 2026/4/6.
//

import Foundation

enum PlayInfoResolver {
    static func resolve(_ playInfo: PlayInfo) async throws -> PlayInfo {
        try await resolveWithBangumi(playInfo).0
    }

    /// 同 resolve，番剧时一并返回剧集信息（用于选集列表）。
    static func resolveWithBangumi(_ playInfo: PlayInfo) async throws -> (PlayInfo, BangumiInfo?) {
        if playInfo.isBangumi {
            return try await resolveBangumi(playInfo)
        }
        return (try await resolveVideo(playInfo), nil)
    }

    private static func resolveVideo(_ playInfo: PlayInfo) async throws -> PlayInfo {
        guard !playInfo.isCidVaild else { return playInfo }
        guard playInfo.aid > 0 else {
            throw ValidationError.argumentInvalid(message: "缺少视频 aid，无法解析播放信息")
        }
        var resolved = playInfo
        resolved.cid = try await WebRequest.requestCid(aid: playInfo.aid)
        return resolved
    }

    private static func resolveBangumi(_ playInfo: PlayInfo) async throws -> (PlayInfo, BangumiInfo?) {
        var resolved = playInfo
        let info: BangumiInfo
        if let epid = playInfo.epid, epid > 0 {
            info = try await WebRequest.requestBangumiInfo(epid: epid)
        } else if let seasonId = playInfo.seasonId, seasonId > 0 {
            info = try await WebRequest.requestBangumiInfo(seasonID: seasonId)
        } else if playInfo.aid > 0 {
            if !playInfo.isCidVaild {
                resolved.cid = try await WebRequest.requestCid(aid: playInfo.aid)
            }
            return (resolved, nil)
        } else {
            throw ValidationError.argumentInvalid(message: "缺少番剧标识，无法解析播放信息")
        }

        resolved.seasonId = info.season_id
        resolved.subType = resolved.subType ?? info.type

        // 没指定集数时从上次看到的那一集开始（原详情页的行为）。
        let progress = info.user_status?.progress
        let matchedEpisode: BangumiInfo.Episode?
        if let epid = resolved.epid, epid > 0 {
            matchedEpisode = info.findEpisodeById(epid) ?? info.episodes.first
        } else {
            matchedEpisode = progress.flatMap { info.findEpisodeById($0.last_ep_id) }
                ?? info.episodes.first ?? info.section?.first?.episodes.first
        }

        if let episode = matchedEpisode {
            resolved.epid = episode.id
            resolved.aid = episode.aid
            resolved.cid = episode.cid
            if let progress, progress.last_ep_id == episode.id, progress.last_time > 0, resolved.playTimeInSecond == nil {
                resolved.lastPlayCid = episode.cid
                resolved.playTimeInSecond = progress.last_time
            }
            if resolved.coverURL == nil {
                resolved.coverURL = episode.cover
            }
            if resolved.title?.isEmpty != false {
                let combinedTitle = [episode.title, episode.long_title]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                resolved.title = combinedTitle.isEmpty ? resolved.title : combinedTitle
            }
        }

        return (resolved, info)
    }
}
