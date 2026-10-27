//
//  VLCVideoPlayPlugin.swift
//  BilibiliLive
//
//  VLC 内核的播放插件（系统播放器对应的是 BVideoPlayPlugin）：
//  下载走 BTR 本地代理，VLC 直接读代理上的视频文件 + 音频文件，来多少数据播多少。
//  负责起播（含继续播放位置）、切画质、回到 App 后重载、上报观看进度、拖动预览图地址。
//

import TVVLCKit
import UIKit

final class VLCVideoPlayPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

    private weak var surface: VLCPlayerSurface?
    private var engine: VLCPlayerEngine?
    private var delegate: BilibiliVideoResourceLoaderDelegate?
    /// 换画质 / 重载后，旧代理再留几秒，让 VLC 读完手上的请求再关。
    private var retiredDelegates = [BilibiliVideoResourceLoaderDelegate]()
    private let playInfo: PlayInfo
    private var playData: PlayerDetailData
    private let reportWatchHistory: Bool
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var lastMaxQuality: Int?
    private var lastStreamIndex: Int?
    private var cdnProbeReport = ""
    private var isProbingCDN = false
    private var lifecycleObservers = [NSObjectProtocol]()
    private var backgroundPosition: Double?
    private var wasPlayingWhenBackgrounded = false

    init(playInfo: PlayInfo, detailData: PlayerDetailData, reportWatchHistory: Bool = true) {
        self.playInfo = playInfo
        playData = detailData
        self.reportWatchHistory = reportWatchHistory
        super.init()
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleEnterBackground()
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleEnterForeground()
            },
        ]
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        delegate?.btrPlayback.invalidate()
        Diag.mark("VLCPLAY deinit")
    }

    /// 当前实际播放的视频流（画质菜单勾选当前项）。
    var currentMedia: VideoPlayURLInfo.DashInfo.DashMediaInfo? { delegate?.primaryMedia }

    /// Debug 浮层的网络信息。
    var networkDebugInfo: String {
        var lines = ["engine: VLC"]
        if let session = delegate?.btrPlayback { lines.append("BTR\n" + session.debug) }
        if let media = delegate?.primaryVideoDescription, !media.isEmpty { lines.append("stream: " + media) }
        if !cdnProbeReport.isEmpty { lines.append(cdnProbeReport) }
        return lines.joined(separator: "\n")
    }

    // MARK: - 插件回调

    func playerDidLoad(host: PlayerHost) {
        guard let surface = host as? VLCPlayerSurface else { return }
        self.surface = surface
        Diag.startupStep("player_engine", ["kind": "VLC"])
        let start = playData.playerStartPos.map { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
        startLoad(at: start, autoplay: true, maxQuality: nil, streamIndex: nil)
    }

    func playerDidDismiss(host: PlayerHost) {
        reportHistory()
    }

    func playerWillCleanUp(host: PlayerHost) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        delegate?.btrPlayback.invalidate()
        surface?.shutdownEngine()
        engine = nil
        surface = nil
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let action = UIAction(title: isProbingCDN ? "CDN 测速中…" : "CDN 测速", image: UIImage(systemName: "speedometer")) { [weak self] _ in
            self?.probeCDN()
        }
        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") }),
            let index = current.firstIndex(of: setting)
        {
            current[index] = setting.replacingChildren(setting.children + [action])
        }
        return []
    }

    // MARK: - 加载

    private func startLoad(at position: Double?, autoplay: Bool, maxQuality: Int?, streamIndex: Int?) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        lastMaxQuality = maxQuality
        lastStreamIndex = streamIndex
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.load(generation: generation, position: position, autoplay: autoplay, maxQuality: maxQuality, streamIndex: streamIndex)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                Diag.startupStep("vlc_load_failed", ["error": String(describing: error).prefix(160)])
                self.onLoadFailure?(String(describing: error))
            }
        }
    }

    @MainActor
    private func load(generation: Int, position: Double?, autoplay: Bool, maxQuality: Int?, streamIndex: Int?) async throws {
        guard let surface else { throw CancellationError() }
        let info = playData.videoPlayURLInfo
        let newDelegate = BilibiliVideoResourceLoaderDelegate()
        newDelegate.setBilibili(info: info, subtitles: [], aid: playData.aid, maxQuality: maxQuality, streamIndex: streamIndex)
        guard let video = newDelegate.primaryMedia else { throw "没有可播放的视频流" }
        async let videoURLReq = newDelegate.prepareDirectURL(for: video)
        async let audioURLReq = Self.directURL(newDelegate, newDelegate.primaryAudio)
        let videoURL = await videoURLReq
        let audioURL = await audioURLReq
        guard loadGeneration == generation, !Task.isCancelled else {
            newDelegate.btrPlayback.invalidate()
            throw CancellationError()
        }
        guard let videoURL else { throw "BTR 代理不可用" }
        Diag.startupStep("vlc_proxy_ready", ["video": newDelegate.primaryVideoDescription, "audio": audioURL != nil])

        if let old = delegate {
            old.btrPlayback.invalidate()
            retiredDelegates.append(old)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.retiredDelegates.removeAll { $0 === old }
            }
        }
        delegate = newDelegate

        let media = VLCMedia(url: videoURL)
        var options: [String: Any] = ["network-caching": 600, "http-reconnect": true]
        if let audioURL { options["input-slave"] = audioURL.absoluteString }
        if let position, position > 0 { options["start-time"] = position }
        media.addOptions(options)

        let engine = self.engine ?? VLCPlayerEngine()
        engine.knownDuration = Double(info.dash.duration)
        if self.engine == nil {
            self.engine = engine
            surface.install(engine: engine)
        }
        Diag.startupStep("vlc_play")
        engine.load(media: media, autoplay: autoplay)
        if !autoplay { engine.pause() }

        // 拖动预览图：码率最低的那条视频流（不和正片抢带宽，不做起播加速）。
        if let thumb = newDelegate.thumbnailMedia, thumb != video {
            Task { @MainActor [weak self, weak newDelegate] in
                guard let newDelegate, let url = await newDelegate.prepareDirectURL(for: thumb, fastStart: false) else { return }
                guard let self, self.delegate === newDelegate else { return }
                self.surface?.thumbnailURL = url
            }
        }
    }

    private static func directURL(_ delegate: BilibiliVideoResourceLoaderDelegate,
                                  _ media: VideoPlayURLInfo.DashInfo.DashMediaInfo?) async -> URL?
    {
        guard let media else { return nil }
        return await delegate.prepareDirectURL(for: media)
    }

    // MARK: - 切画质

    @MainActor
    func switchQuality(to qualityId: Int, streamIndex: Int?) async {
        guard let engine else { return }
        let position = engine.currentTime
        let playing = engine.isPlaying
        BTRTrace.shared.event("quality_switch", ["to": qualityId, "streamIndex": streamIndex ?? -1, "target": position, "engine": "VLC"])
        startLoad(at: position, autoplay: playing, maxQuality: qualityId, streamIndex: streamIndex)
    }

    // MARK: - 回到 App

    private func handleEnterBackground() {
        guard let engine else { return }
        let position = engine.currentTime
        wasPlayingWhenBackgrounded = engine.isPlaying
        backgroundPosition = position
        reportHistory()
        // 挂起后本地代理失效：先停掉，回来用新的播放地址和新代理在原位置重建。
        loadTask?.cancel()
        loadGeneration += 1
        engine.pause()
        engine.player.stop()
        delegate?.btrPlayback.invalidate()
        Diag.mark("VLCPLAY background teardown pos=\(Int(position))")
    }

    private func handleEnterForeground() {
        guard let position = backgroundPosition, engine != nil else { return }
        backgroundPosition = nil
        let resume = wasPlayingWhenBackgrounded
        BTRTrace.shared.event("foreground_reload", ["position": position, "resume": resume, "engine": "VLC"])
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPlayURL()
            self.startLoad(at: position, autoplay: resume, maxQuality: self.lastMaxQuality, streamIndex: self.lastStreamIndex)
        }
    }

    /// B 站视频地址带签名和过期时间，离开较久后旧地址会被拒绝，重载前先换新地址。
    @MainActor
    private func refreshPlayURL() async {
        let aid = playData.aid, cid = playData.cid
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            do {
                let fresh = playData.isBangumi
                    ? try await WebRequest.requestPcgPlayUrl(aid: aid, cid: cid)
                    : try await WebRequest.requestPlayUrl(aid: aid, cid: cid)
                playData.videoPlayURLInfo = fresh
                return
            } catch {
                Diag.mark("VLCPLAY refreshPlayURL failed attempt=\(attempt)")
            }
        }
    }

    // MARK: - 其他

    private func reportHistory() {
        guard reportWatchHistory, let position = engine?.currentTime, position > 0 else { return }
        WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(position),
                                      epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
    }

    private func probeCDN() {
        guard !isProbingCDN else { return }
        let candidates = delegate?.cdnCandidates ?? []
        guard !candidates.isEmpty else {
            cdnProbeReport = "无候选 CDN"
            return
        }
        isProbingCDN = true
        cdnProbeReport = "CDN 测速中…"
        Task { @MainActor [weak self] in
            let report = await CDNDiagnostics.run(urls: candidates, currentHost: nil)
            self?.cdnProbeReport = report
            self?.isProbingCDN = false
        }
    }
}
