//
//  VideoPlayerViewModel.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//

import Combine
import UIKit

struct PlayerDetailData {
    let aid: Int
    let cid: Int
    let epid: Int? // 港澳台解锁需要
    let seasonId: Int? // 番剧 season_id
    let subType: Int? // 0: 普通视频 1：番剧 2：电影 3：纪录片 4：国创 5：电视剧 7：综艺

    var playerStartPos: Int?
    var detail: VideoDetail?
    var clips: [VideoPlayURLInfo.ClipInfo]?
    var playerInfo: PlayerInfo?
    var videoPlayURLInfo: VideoPlayURLInfo

    var isBangumi: Bool {
        return epid ?? 0 > 0 || seasonId ?? 0 > 0
    }
}

/// 进入视频时「继续播放 / 从头播放」询问所需的信息。
struct ResumePrompt {
    let title: String
    let cover: URL?
    let position: Int
    let duration: Int
}

enum ResumeChoice {
    case resume
    case restart
    case cancel
}

@MainActor
class VideoPlayerViewModel {
    let loadResult = PassthroughSubject<Result<[CommonPlayerPlugin], String>, Never>()
    var onExit: (() -> Void)?
    var onPlayInfoChanged: ((PlayInfo) -> Void)?
    var sequenceProvider: VideoSequenceProvider?
    /// 有观看记录时询问继续还是从头；返回 nil 表示不询问（直接续播）。
    var resumeChooser: ((ResumePrompt) async -> ResumeChoice)?
    private var hasHandledResumeChoice = false
    /// 这次加载用哪个播放器（设置「播放器」+ 是否会选中杜比视界）。
    private(set) var engineKind: PlayerEngineKind = .system
    private var hasBuiltSequence = false

    private var playInfo: PlayInfo
    private let playMode: VideoPlayerMode
    private let playContextCache: PlayContextCache?
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private let previewMuted: Bool
    private let startTimeOverride: Int?
    private let startTimeOverrideContentIdentity: String
    private var videoDetail: VideoDetail?
    private var cancellable = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(playInfo: PlayInfo,
         playMode: VideoPlayerMode = .regular,
         playContextCache: PlayContextCache? = nil,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil,
         previewMuted: Bool = true,
         startTimeOverride: Int? = nil)
    {
        self.playInfo = playInfo
        self.playMode = playMode
        self.playContextCache = playContextCache
        self.mediaWarmupManager = mediaWarmupManager
        self.previewMuted = previewMuted
        self.startTimeOverride = startTimeOverride
        startTimeOverrideContentIdentity = playInfo.contentIdentity
    }

    var currentPlayInfo: PlayInfo {
        playInfo
    }

    func load() {
        startLoad(for: playInfo)
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
    }

    private func startLoad(for requestedPlayInfo: PlayInfo) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await performLoad(for: requestedPlayInfo, generation: generation)
        }
        loadTask = task
    }

    private func performLoad(for requestedPlayInfo: PlayInfo, generation: Int) async {
        defer {
            if loadGeneration == generation {
                loadTask = nil
            }
        }
        do {
            Diag.startupStep("vm_load_begin")
            let (resolvedPlayInfo, loadedData, bangumi) = try await loadVideoInfo(for: requestedPlayInfo)
            var data = loadedData
            Diag.startupStep("vm_info_ready", ["quality": data.videoPlayURLInfo.quality, "startPos": data.playerStartPos ?? -1])
            guard !Task.isCancelled, loadGeneration == generation else { return }

            if playMode == .regular, !hasBuiltSequence {
                hasBuiltSequence = true
                if sequenceProvider == nil {
                    sequenceProvider = Self.makeSequence(playInfo: resolvedPlayInfo, detail: data.detail, bangumi: bangumi)
                }
            }

            if playMode == .regular, !hasHandledResumeChoice {
                hasHandledResumeChoice = true
                if startTimeOverride == nil, Settings.resumePrompt,
                   let position = data.playerStartPos, position >= 10,
                   let resumeChooser
                {
                    let prompt = ResumePrompt(title: data.detail?.title ?? resolvedPlayInfo.title ?? "",
                                              cover: data.detail?.pic ?? resolvedPlayInfo.coverURL,
                                              position: position,
                                              duration: data.videoPlayURLInfo.dash.duration)
                    Diag.startupStep("resume_prompt_shown")
                    let choice = await resumeChooser(prompt)
                    Diag.startupStep("resume_prompt_answered", ["choice": "\(choice)"])
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    switch choice {
                    case .resume: break
                    case .restart: data.playerStartPos = nil
                    case .cancel:
                        onExit?()
                        return
                    }
                }
            }

            let danmuProvider = VideoDanmuProvider(enableDanmuFilter: Settings.enableDanmuFilter,
                                                   enableDanmuRemoveDup: Settings.enableDanmuRemoveDup)
            // Danmaku load in the background (as the VLC player does): device log showed this await
            // holding the player back 0.2-1.8 s before any video request was made.
            Diag.startupStep("vm_danmu_begin")
            let danmuStart = data.playerStartPos ?? 0
            Task {
                await danmuProvider.initVideo(cid: data.cid, startPos: danmuStart)
                Diag.startupStep("vm_danmu_done")
            }
            guard !Task.isCancelled, loadGeneration == generation else { return }

            playInfo = resolvedPlayInfo
            videoDetail = data.detail
            engineKind = resolveEngineKind(data)
            BiliBiliUpnpDMR.shared.sendVideoSwitch(aid: resolvedPlayInfo.aid, cid: data.cid)
            cancellable.removeAll()
            let plugins = generatePlayerPlugin(data,
                                               playInfo: resolvedPlayInfo,
                                               danmuProvider: danmuProvider)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            Diag.startupStep("vm_plugins_ready")
            loadResult.send(.success(plugins))
        } catch is CancellationError {
            return
        } catch let err {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            loadResult.send(.failure(err.localizedDescription))
        }
    }

    private func loadVideoInfo(for playInfo: PlayInfo) async throws -> (PlayInfo, PlayerDetailData, BangumiInfo?) {
        let (resolvedPlayInfo, bangumi) = try await PlayInfoResolver.resolveWithBangumi(playInfo)
        Diag.startupStep("vm_resolved", ["bangumi": resolvedPlayInfo.isBangumi])
        try Task.checkCancellation()
        do {
            let data = try await fetchVideoData(for: resolvedPlayInfo)
            try Task.checkCancellation()
            return (resolvedPlayInfo, data, bangumi)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 部分番剧/影视只给了 aid（例如搜索、评论里的链接），普通接口拿不到地址时按番剧重新解析。
            guard !resolvedPlayInfo.isBangumi,
                  let detail = try? await WebRequest.requestDetailVideo(aid: resolvedPlayInfo.aid),
                  let redirect = detail.View.redirect_url?.lastPathComponent, redirect.hasPrefix("ep"),
                  let epid = Int(redirect.dropFirst(2)), epid > 0
            else { throw error }
            try Task.checkCancellation()
            var bangumiInfo = resolvedPlayInfo
            bangumiInfo.epid = epid
            let (resolved, info) = try await PlayInfoResolver.resolveWithBangumi(bangumiInfo)
            try Task.checkCancellation()
            let data = try await fetchVideoData(for: resolved)
            try Task.checkCancellation()
            return (resolved, data, info)
        }
    }

    /// 分P、合集、番剧剧集组成的播放列表（原来由详情页提供）。
    private static func makeSequence(playInfo: PlayInfo, detail: VideoDetail?, bangumi: BangumiInfo?) -> VideoSequenceProvider? {
        var seq = [PlayInfo]()
        if let bangumi {
            let episodes = bangumi.episodes.isEmpty ? (bangumi.section?.first?.episodes ?? []) : bangumi.episodes
            seq = episodes.map { episode in
                let title = [episode.title, episode.long_title].filter { !$0.isEmpty }.joined(separator: " ")
                return PlayInfo(aid: episode.aid, cid: episode.cid, epid: episode.id, seasonId: bangumi.season_id,
                                subType: bangumi.type, title: title, coverURL: episode.cover)
            }
        } else if let detail {
            let pages = detail.View.pages ?? []
            if pages.count > 1 {
                seq = pages.map { PlayInfo(aid: detail.View.aid, cid: $0.cid, title: $0.part, coverURL: detail.pic) }
            } else if let season = detail.View.ugc_season {
                let section = season.sections.first { $0.episodes.contains { $0.aid == detail.View.aid } } ?? season.sections.first
                let episodes = (section?.episodes ?? []).sorted { $0.arc.ctime < $1.arc.ctime }
                seq = episodes.map { PlayInfo(aid: $0.aid, cid: $0.cid, title: $0.title, coverURL: $0.arc.pic) }
            }
        }
        guard seq.count > 1 else { return nil }
        let index = seq.firstIndex { $0.cid == playInfo.cid }
            ?? seq.firstIndex { $0.aid == playInfo.aid && !playInfo.isBangumi }
            ?? seq.firstIndex { ($0.epid ?? 0) > 0 && $0.epid == playInfo.epid }
        guard let index else { return nil }
        return VideoSequenceProvider(seq: seq, currentIndex: index)
    }

    /// 在下滑面板的「选集」里选了某一集。
    func playSequenceItem(_ info: PlayInfo) {
        guard let sequenceProvider,
              let index = sequenceProvider.playSeq.firstIndex(where: { $0.sequenceKey == info.sequenceKey }),
              info.sequenceKey != currentPlayInfo.sequenceKey
        else { return }
        sequenceProvider.setCurrentIndex(index)
        updatePlayInfo(sequenceProvider.playSeq[index])
    }

    private func fetchVideoDetail(aid: Int, existing: VideoDetail?) async -> VideoDetail? {
        if let existing { return existing }
        return try? await WebRequest.requestDetailVideo(aid: aid)
    }

    private func fetchVideoData(for playInfo: PlayInfo) async throws -> PlayerDetailData {
        assert(playInfo.isCidVaild)
        let existingVideoDetail = videoDetail?.View.aid == playInfo.aid ? videoDetail : nil
        if !playInfo.isBangumi, let playContextCache {
            let cached = try await playContextCache.context(for: playInfo, mode: playContextMode)
            let resolvedDetail = cached.detail ?? existingVideoDetail

            var detail = PlayerDetailData(aid: playInfo.aid,
                                          cid: cached.cid,
                                          epid: playInfo.epid,
                                          seasonId: playInfo.seasonId,
                                          subType: playInfo.subType,
                                          detail: resolvedDetail,
                                          clips: nil,
                                          playerInfo: cached.playerInfo,
                                          videoPlayURLInfo: cached.videoPlayURLInfo)

            let lastPlayCid = playInfo.lastPlayCid ?? cached.playerInfo?.last_play_cid ?? 0
            let playTimeInSecond = playInfo.playTimeInSecond ?? cached.playerInfo?.playTimeInSecond ?? 0
            detail.playerStartPos = resolvedPlayerStartPos(cid: cached.cid,
                                                           duration: cached.videoPlayURLInfo.dash.duration,
                                                           lastPlayCid: lastPlayCid,
                                                           playTimeInSecond: playTimeInSecond,
                                                           playInfo: playInfo)
            return detail
        }

        let aid = playInfo.aid
        let cid = playInfo.cid!
        async let infoReq = try? WebRequest.requestPlayerInfo(aid: aid, cid: cid)
        async let detailReq = fetchVideoDetail(aid: aid, existing: existingVideoDetail)
        do {
            let playData: VideoPlayURLInfo
            var clipInfos: [VideoPlayURLInfo.ClipInfo]?

            Diag.startupStep("vm_playurl_begin")
            if playInfo.isBangumi {
                do {
                    playData = try await WebRequest.requestPcgPlayUrl(aid: aid, cid: cid, options: playContextMode.requestOptions)
                } catch let err as RequestError {
                    if case let .statusFail(code, _) = err,
                       code == -404 || code == -10403,
                       let data = try await fetchAreaLimitPcgVideoData(for: playInfo)
                    {
                        playData = data
                    } else {
                        throw err
                    }
                }

                clipInfos = playData.clip_info_list
            } else {
                playData = try await WebRequest.requestPlayUrl(aid: aid, cid: cid, options: playContextMode.requestOptions)
            }

            Diag.startupStep("vm_playurl_done")
            let info = await infoReq
            Diag.startupStep("vm_playerinfo_done")
            let resolvedDetail = await detailReq
            Diag.startupStep("vm_detail_done")

            var detail = PlayerDetailData(aid: playInfo.aid, cid: playInfo.cid!, epid: playInfo.epid, seasonId: playInfo.seasonId, subType: playInfo.subType, detail: resolvedDetail, clips: clipInfos, playerInfo: info, videoPlayURLInfo: playData)

            let last_play_cid = playInfo.lastPlayCid ?? info?.last_play_cid ?? 0
            let playTimeInSecond = playInfo.playTimeInSecond ?? info?.playTimeInSecond ?? 0
            detail.playerStartPos = resolvedPlayerStartPos(cid: cid,
                                                           duration: playData.dash.duration,
                                                           lastPlayCid: last_play_cid,
                                                           playTimeInSecond: playTimeInSecond,
                                                           playInfo: playInfo)

            return detail

        } catch let err {
            if case let .statusFail(code, message) = err as? RequestError {
                throw "\(code) \(message)，可能需要大会员"
            } else if await infoReq?.is_upower_exclusive == true {
                throw "该视频为充电专属视频 \(err)"
            } else {
                throw err
            }
        }
    }

    private func updatePlayInfo(_ newPlayInfo: PlayInfo) {
        playInfo = newPlayInfo
        onPlayInfoChanged?(newPlayInfo)
        startLoad(for: newPlayInfo)
    }

    private func resolvedPlayerStartPos(cid: Int,
                                        duration: Int,
                                        lastPlayCid: Int,
                                        playTimeInSecond: Int,
                                        playInfo: PlayInfo) -> Int?
    {
        if let startTimeOverride,
           startTimeOverrideContentIdentity == playInfo.contentIdentity,
           duration - startTimeOverride > 5
        {
            return startTimeOverride
        }
        if lastPlayCid == cid,
           duration - playTimeInSecond > 5,
           Settings.continuePlay
        {
            return playTimeInSecond
        }
        return nil
    }

    func retryCurrent() {
        load()
    }

    func playNextFromSequence() async -> Bool {
        guard let next = await sequenceProvider?.moveNext() else { return false }
        updatePlayInfo(next)
        return true
    }

    func playPreviousFromSequence() async -> Bool {
        guard let previous = sequenceProvider?.movePrevious() else { return false }
        updatePlayInfo(previous)
        return true
    }

    func playTemporaryOverride(_ temporaryPlayInfo: PlayInfo) {
        guard temporaryPlayInfo.sequenceKey != currentPlayInfo.sequenceKey else { return }
        sequenceProvider.map { provider in
            MainActor.assumeIsolated {
                provider.pushTemporary(temporaryPlayInfo)
            }
        }
        updatePlayInfo(temporaryPlayInfo)
    }

    func preloadNeighborsIfNeeded() async {
        guard playMode == .feedFlow, let playContextCache, let sequenceProvider else { return }
        let current = sequenceProvider.current() ?? currentPlayInfo
        let priority = [current,
                        sequenceProvider.peekNext(),
                        sequenceProvider.peekPrevious()].compactMap { $0 }.uniqued()
        for info in priority {
            guard !Task.isCancelled else { return }
            await playContextCache.preload(playInfo: info, mode: .regular)
        }
        guard !Task.isCancelled else { return }
        await playContextCache.trim(keeping: priority)
        for info in priority {
            guard !Task.isCancelled else { return }
            await mediaWarmupManager?.preload(playInfo: info)
        }
    }

    /// 系统 / VLC / 自动（会选中杜比视界时用系统播放器，其余用 VLC）。预览和刷视频流只用系统播放器。
    private func resolveEngineKind(_ data: PlayerDetailData) -> PlayerEngineKind {
        guard playMode == .regular else { return .system }
        switch Settings.playerEngine {
        case .system: return .system
        case .vlc: return .vlc
        case .auto: return BilibiliVideoResourceLoaderDelegate.selectsDolbyVision(data.videoPlayURLInfo) ? .system : .vlc
        }
    }

    private func generatePlayerPlugin(_ data: PlayerDetailData,
                                      playInfo: PlayInfo,
                                      danmuProvider: VideoDanmuProvider) -> [CommonPlayerPlugin]
    {
        let playplugin: CommonPlayerPlugin
        let networkDebugInfo: () -> String
        let switchQuality: (Int, Int?) async -> Void
        let currentMedia: () -> VideoPlayURLInfo.DashInfo.DashMediaInfo?
        var extraPlugins = [CommonPlayerPlugin]()
        if engineKind == .vlc {
            // 系统播放器只播最低码率的影子视频（静音），提供界面和时间轴；VLC 输出画面和声音。
            let videos = data.videoPlayURLInfo.dash.video
            let shadowIndex = videos.indices.filter { (videos[$0].width ?? 0) > 0 }.min { videos[$0].bandwidth < videos[$1].bandwidth }
            let renderer = VLCRendererPlugin(detailData: data)
            let shadow = BVideoPlayPlugin(playInfo: playInfo,
                                          detailData: data,
                                          reportWatchHistory: playMode != .preview,
                                          minimizeStalling: true,
                                          isMuted: true,
                                          mediaWarmupManager: nil,
                                          shadowStreamIndex: shadowIndex,
                                          shadowGate: renderer.gate)
            shadow.onLoadFailure = { [weak self] message in
                self?.loadResult.send(.failure(message))
            }
            renderer.onLoadFailure = { [weak self] message in
                self?.loadResult.send(.failure(message))
            }
            playplugin = shadow
            extraPlugins.append(renderer)
            networkDebugInfo = { [weak renderer, weak shadow] in
                (renderer?.networkDebugInfo ?? "") + "\n--- shadow clock ---\n" + (shadow?.networkDebugInfo ?? "")
            }
            switchQuality = { [weak renderer] quality, index in await renderer?.switchQuality(to: quality, streamIndex: index) }
            currentMedia = { [weak renderer] in renderer?.currentMedia }
        } else {
            let system = BVideoPlayPlugin(playInfo: playInfo,
                                          detailData: data,
                                          reportWatchHistory: playMode != .preview,
                                          minimizeStalling: true,
                                          isMuted: playMode == .preview && previewMuted,
                                          mediaWarmupManager: playMode == .feedFlow ? mediaWarmupManager : nil)
            system.onLoadFailure = { [weak self] message in
                self?.loadResult.send(.failure(message))
            }
            playplugin = system
            networkDebugInfo = { [weak system] in system?.networkDebugInfo ?? "" }
            switchQuality = { [weak system] quality, index in await system?.switchQuality(to: quality, streamIndex: index) }
            currentMedia = { [weak system] in system?.currentMedia }
        }

        if playMode == .preview {
            return [playplugin]
        }

        let danmu = DanmuViewPlugin(provider: danmuProvider)
        let upnp = BUpnpPlugin(duration: data.detail?.View.duration)
        let debug = DebugPlugin()
        debug.additionDebugInfo = networkDebugInfo
        let playSpeed = SpeedChangerPlugin()
        playSpeed.$currentPlaySpeed.sink { [weak danmu] speed in
            danmu?.danMuView.playingSpeed = speed.value
        }.store(in: &cancellable)

        let playlist = VideoPlayListPlugin(sequenceProvider: sequenceProvider)
        playlist.onPlayEnd = { [weak self] in
            guard self?.playMode == .regular else { return }
            self?.onExit?()
        }
        playlist.onPlayNextWithInfo = {
            [weak self] info in
            guard let self else { return }
            updatePlayInfo(info)
        }

        // SpeedChangerPlugin creates the shared settings menu that later plugins extend.
        var plugins: [CommonPlayerPlugin] = [playSpeed, playplugin] + extraPlugins + [danmu, upnp, debug, playlist]

        if let detail = data.detail {
            let infoTabs = VideoPlayerInfoTabsPlugin(detail: detail,
                                                     currentPlayInfo: playInfo,
                                                     sequenceProvider: sequenceProvider)
            infoTabs.onSelectDiscovery = { [weak self] info in
                self?.playTemporaryOverride(info)
            }
            infoTabs.onSelectEpisode = { [weak self] info in
                self?.playSequenceItem(info)
            }
            plugins.append(infoTabs)
        }

        // 添加画质选择器插件
        let qualitySelector = BVideoQualityPlugin(detailData: data) { qualityId, streamIndex in
            Task { @MainActor in
                await switchQuality(qualityId, streamIndex)
            }
        }

        qualitySelector.currentMediaProvider = currentMedia
        plugins.append(qualitySelector)

        if let clips = data.clips {
            let clip = BVideoClipsPlugin(clipInfos: clips)
            plugins.append(clip)
        }

        if Settings.enableSponsorBlock != .none, let bvid = data.detail?.View.bvid, let duration = data.detail?.View.duration {
            let sponsor = SponsorSkipPlugin(bvid: bvid, duration: duration)
            plugins.append(sponsor)
        }

        if Settings.danmuMask {
            if let mask = data.playerInfo?.dm_mask,
               let video = data.videoPlayURLInfo.dash.video.first,
               mask.fps > 0
            {
                let maskProvider = BMaskProvider(info: mask, videoSize: CGSize(width: video.width ?? 0, height: video.height ?? 0))
                plugins.append(MaskViewPugin(maskView: danmu.danMuView, maskProvider: maskProvider))
            } else if Settings.vnMask {
                let maskProvider = VMaskProvider()
                plugins.append(MaskViewPugin(maskView: danmu.danMuView, maskProvider: maskProvider))
            }
        }

        // 默认视频标题作主标题 up主用户名作副标题
        if let detail = data.detail {
            var title = detail.title
            var subTitle = detail.ownerName
            // 分页播放时则以分页标题作主标题 up主用户名+视频标题作副标题
            let pages = detail.View.pages ?? []
            if pages.count > 1, let index = pages.firstIndex(where: { $0.cid == playInfo.cid }) {
                let page = pages[index]
                title = page.part
                subTitle += "·\(detail.title)"
            }
            let infoPlugin = BVideoInfoPlugin(title: title, subTitle: subTitle, desp: detail.View.desc, pic: detail.pic, viewPoints: data.playerInfo?.view_points)
            plugins.append(infoPlugin)
            Logger.debug("updateInfoPlugin: title: \(title) subTitle: \(subTitle)")
        }

        return plugins
    }

    private var playContextMode: PlayContextMode {
        switch playMode {
        case .preview:
            return .preview
        case .regular, .feedFlow:
            return .regular
        }
    }
}

// 港澳台解锁
extension VideoPlayerViewModel {
    private func fetchAreaLimitPcgVideoData(for playInfo: PlayInfo) async throws -> VideoPlayURLInfo? {
        guard Settings.areaLimitUnlock else { return nil }
        guard let epid = playInfo.epid, epid > 0 else { return nil }

        let season = try await WebRequest.requestBangumiSeasonView(epid: epid)
        let checkTitle = season.title.contains("僅") ? season.title : season.series_title
        let checkAreaList = parseAreaByTitle(title: checkTitle)
        guard !checkAreaList.isEmpty else { return nil }

        let playData = try await requestAreaLimitPcgPlayUrl(epid: epid, cid: playInfo.cid!, areaList: checkAreaList)
        return playData
    }

    private func requestAreaLimitPcgPlayUrl(epid: Int, cid: Int, areaList: [String]) async throws -> VideoPlayURLInfo? {
        for area in areaList {
            do {
                return try await WebRequest.requestAreaLimitPcgPlayUrl(epid: epid,
                                                                       cid: cid,
                                                                       area: area,
                                                                       options: playContextMode.requestOptions)
            } catch let err {
                if area == areaList.last {
                    throw err
                } else {
                    print(err)
                }
            }
        }
        return nil
    }

    private func parseAreaByTitle(title: String) -> [String] {
        if title.isMatch(pattern: "[仅|僅].*[东南亚|其他]") {
            // TODO: 未支持
            return []
        }

        var areas: [String] = []
        if title.isMatch(pattern: "僅.*台") {
            areas.append("tw")
        }
        if title.isMatch(pattern: "僅.*港") {
            areas.append("hk")
        }

        if areas.isEmpty {
            // 标题没有地区限制信息，返回尝试检测的区域
            return ["tw", "hk"]
        } else {
            return areas
        }
    }
}
