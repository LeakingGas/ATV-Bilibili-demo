//
//  BVideoPlayPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/24.
//

import AVKit
import UIKit

class BVideoPlayPlugin: NSObject, CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?

    private weak var playerVC: AVPlayerViewController?
    private var playerDelegate: BilibiliVideoResourceLoaderDelegate?
    private let playInfo: PlayInfo
    private let playData: PlayerDetailData
    private let reportWatchHistory: Bool
    private let minimizeStalling: Bool
    private let isMuted: Bool
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private var currentQualityId: Int?
    private var resumeState = PlaybackResumeState()
    // 记录最近一次实际用于加载的 maxQuality/streamIndex，host 切换时原样复用，
    // 不去动用户当前的画质模式（自动多档 fallback 还是手动锁定某一档）
    private var lastMaxQuality: Int?
    private var lastStreamIndex: Int?

    // Cleanup callbacks refer to an outgoing player, while playerDelegate may
    // already hold the incoming load. Keep ownership independent of that pointer.
    private weak var btrOwner: AVPlayer?
    private var btrOwnedSession: BTRPlaybackSession?
    private var btrFailureSnapshot = ""
    private var btrTimer: Timer?
    private var btrJumpObserver: NSObjectProtocol?
    private var btrLastRate = 1.0
    private var networkLogTimer: Timer?
    private var lastStalls = 0
    private var lastDroppedFrames = 0
    private var cdnProbeReport = ""
    private var isProbingCDN = false
    /// 当前会话实际传输模式（创建播放资源时快照；设置只影响新建会话）。
    private var transportMode: MediaTransportMode = .accelerated
    /// 加速不可恢复时的播放器级直连恢复次数（有界，避免无限重试）。
    /// 单调时钟记录的连续等待起点（systemUptime 秒）。nil 表示当前不在等待。
    /// 日志周期 5s 且需两次不健康采样才计数一次，周期计数实际对应约 120s；
    /// 以单调时长为准，60s 到即回退，不依赖双层计数。
    private var acceleratedWaitingSince: TimeInterval?

    /// 加速等待看门狗：isWaiting 为真且非用户暂停时累计单调时长，
    /// 满 60s 触发一次有界直连恢复；任何进展（或用户暂停）即清零。
    /// 由 checkStallHealth 与无 access log 的起播阶段共同驱动。
    private func noteAcceleratedWaiting(isWaiting: Bool) {
        guard transportMode == .accelerated else {
            acceleratedWaitingSince = nil
            return
        }
        guard isWaiting, !isUserPaused else {
            acceleratedWaitingSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = acceleratedWaitingSince {
            if now - since >= 60 {
                acceleratedWaitingSince = nil
                Logger.info("[BTR] 持续等待超60s，保留BTR并记录诊断；直连已禁用")
                Task { @MainActor [weak self] in
                    await self?.reportBTRFailure(reason: "waiting-60s")
                }
            }
        } else {
            acceleratedWaitingSince = now
        }
    }

    // 运行时 CDN 健康检测：只在真实卡顿时换 host，不用 observed/indicated 比特率比
    // （indicated 常是峰值 BANDWIDTH，播放流畅时 observed 低于它完全正常）
    private var stallUnhealthyStreak = 0
    private var isEvaluatingHostSwitch = false
    private var lastHostSwitchAt: Date?
    /// 连续几次处于卡顿/等待缓冲才触发，避免单次抖动
    private let stallTriggerCount = 2
    /// 换完 host 后的冷静期，避免连续误触发
    private let hostSwitchCooldown: TimeInterval = 30
    private let networkLogInterval: TimeInterval = 5
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(playInfo: PlayInfo,
         detailData: PlayerDetailData,
         reportWatchHistory: Bool = true,
         minimizeStalling: Bool = true,
         isMuted: Bool = false,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil)
    {
        self.playInfo = playInfo
        playData = detailData
        self.reportWatchHistory = reportWatchHistory
        self.minimizeStalling = minimizeStalling
        self.isMuted = isMuted
        self.mediaWarmupManager = mediaWarmupManager
        currentQualityId = playData.videoPlayURLInfo.quality
    }

    deinit {
        btrTimer?.invalidate()
        if let btrJumpObserver { NotificationCenter.default.removeObserver(btrJumpObserver) }
        playerDelegate?.btrPlayback.invalidate()
        networkLogTimer?.invalidate()
    }

    /// 供 DebugPlugin 浮层显示的网络诊断信息
    var networkDebugInfo: String {
        var lines = [String]()
        if let mode = playerDelegate?.effectiveTransportMode {
            lines.append("transport: \(mode == .accelerated ? "accel" : mode == .proxy ? "proxy" : "direct")")
        }
        if transportMode == .accelerated, let session = playerDelegate?.btrPlayback { lines.append("BTR ONLY / direct disabled\n" + session.debug) }
        if let host = playerDelegate?.currentSegmentHost {
            lines.append("segment host: \(host)")
        }
        if let accel = playerDelegate?.accelerationDebugInfo, !accel.isEmpty {
            lines.append("last completed track: " + accel)
        }
        if !btrFailureSnapshot.isEmpty { lines.append(btrFailureSnapshot) }
        if !cdnProbeReport.isEmpty {
            lines.append(cdnProbeReport)
        }
        return lines.joined(separator: "\n")
    }

    func playerDidFail(player: AVPlayer) {
        // Strict BTR: report failure without switching transport.
        guard transportMode == .accelerated, playerVC?.player === player else { return }
        Task { @MainActor [weak self] in
            await self?.reportBTRFailure(reason: "player-failed")
        }
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        playerVC.player = nil
        startLoad(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo)
    }

    func playerWillStart(player: AVPlayer) {
        guard playerVC?.player === player,
              let target = resumeState.initialTarget(history: playData.playerStartPos.map { Double($0) }) else { return }
        BTRTrace.shared.event("seek_requested",["source":"initial-history","target":target,"generation":loadGeneration])
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playerDidStart(player _: AVPlayer) {
        startNetworkLogging()
    }

    func playerDidCleanUp(player: AVPlayer) {
        if btrOwner === player {
            stopBTRMonitoring()
            btrOwnedSession?.invalidate()
            btrOwnedSession = nil
            btrOwner = nil
            stopNetworkLogging()
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        // 挂进「播放设置」，与 Debug 并列（依赖 SpeedChangerPlugin 先创建 setting 菜单）
        let action = UIAction(title: isProbingCDN ? "CDN 测速中…" : "CDN 测速",
                              image: UIImage(systemName: "speedometer"))
        { [weak self] _ in
            self?.probeCDN()
        }
        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") }),
            let index = current.firstIndex(of: setting)
        {
            current[index] = setting.replacingChildren(setting.children + [action])
            return []
        }
        return []
    }

    private func probeCDN() {
        guard !isProbingCDN else { return }
        let candidates = playerDelegate?.cdnCandidates ?? []
        guard !candidates.isEmpty else {
            cdnProbeReport = "无候选 CDN"
            return
        }
        let currentHost = playerDelegate?.currentSegmentHost
        isProbingCDN = true
        cdnProbeReport = "CDN 测速中…"
        Task { @MainActor [weak self] in
            let report = await CDNDiagnostics.run(urls: candidates, currentHost: currentHost)
            self?.cdnProbeReport = report
            self?.isProbingCDN = false
        }
    }

    private func stopBTRMonitoring() {
        btrTimer?.invalidate(); btrTimer = nil
        if let btrJumpObserver { NotificationCenter.default.removeObserver(btrJumpObserver) }
        btrJumpObserver = nil
    }
    private func startBTRMonitoring(player: AVPlayer) {
        stopBTRMonitoring()
        guard transportMode == .accelerated, let item = player.currentItem else { return }
        btrLastRate = Double(Settings.mediaPlayerSpeed.value)
        sampleBTR(player: player)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self, weak player] _ in
            guard let self, let player, self.playerVC?.player === player else { return }
            self.sampleBTR(player: player)
        }
        btrTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        btrJumpObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped,
            object: item, queue: .main) { [weak self, weak player] _ in
                guard let self, let player, self.playerVC?.player === player else { return }
                self.sampleBTR(player: player, jumped: true)
            }
    }
    private var lastTraceSample = -Double.infinity
    private func sampleBTR(player: AVPlayer, jumped: Bool = false) {
        guard let item = player.currentItem, let session = playerDelegate?.btrPlayback else { return }
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        if player.rate > 0 { btrLastRate = Double(player.rate) }
        // loadedTimeRanges may contain disconnected seek islands. Only merge ranges
        // contiguous with the playhead, never count a distant prefetched island.
        let ranges = item.loadedTimeRanges.map { $0.timeRangeValue }.sorted { $0.start.seconds < $1.start.seconds }
        var end = position
        for range in ranges {
            let start = range.start.seconds, finish = CMTimeRangeGetEnd(range).seconds
            if start.isFinite && finish.isFinite && start <= end + 0.05 && finish > end { end = finish }
        }
        session.update(position: position, rate: btrLastRate,
            advancing: player.timeControlStatus == .playing,
            intended: player.timeControlStatus != .paused,
            waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            ahead: max(0, end - position), jumped: jumped)
        if jumped || BTRTrace.now-lastTraceSample >= 1000 {
            lastTraceSample = BTRTrace.now
            let access = item.accessLog()?.events.last
            var fields: [String:Any] = ["session":session.id.uuidString,"position":position,
                "ahead":max(0,end-position),"tcs":player.timeControlStatus.rawValue,
                "itemStatus":item.status.rawValue,"jumped":jumped,"rate":player.rate,
                "empty":item.isPlaybackBufferEmpty,"keepUp":item.isPlaybackLikelyToKeepUp,
                "quality":currentQualityId ?? -1,"threads":session.limit,
                "waitingReason":player.reasonForWaitingToPlay?.rawValue ?? ""]
            if let access {
                fields["observedBps"] = access.observedBitrate.isFinite ? access.observedBitrate : -1
                fields["indicatedBps"] = access.indicatedBitrate.isFinite ? access.indicatedBitrate : -1
                fields["stalls"] = access.numberOfStalls
            }
            if let error = item.error { fields.merge(BTRTrace.errorFields(error)) { _,new in new } }
            if let error = item.errorLog()?.events.last {
                fields["avErrorCode"] = error.errorStatusCode
            }
            BTRTrace.shared.event("player_sample",fields)
        }
    }

    private func startNetworkLogging() {
        guard networkLogTimer == nil else { return }
        networkLogTimer = Timer.scheduledTimer(withTimeInterval: networkLogInterval, repeats: true) { [weak self] _ in
            self?.logNetworkStatus()
        }
    }

    private func stopNetworkLogging() {
        networkLogTimer?.invalidate()
        networkLogTimer = nil
    }

    private func logNetworkStatus() {
        guard let player = playerVC?.player,
              let item = player.currentItem,
              let event = item.accessLog()?.events.last
        else {
            // 起播尚无 access log 时 checkStallHealth 不会执行，这里的等待看门狗
            // 同样需要覆盖，否则首帧卡死时 60s 回退永远不触发。
            noteAcceleratedWaiting(isWaiting: playerVC?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            return
        }
        // event.uri 是内部 variant playlist 的地址（我们用的是自定义 atv://dash/N scheme），
        // 解析出来的 host 恒为 "dash"，跟实际连的 CDN 无关；真实 host 记录在 playerDelegate 里。
        let host = playerDelegate?.currentSegmentHost ?? "-"
        let observedBps = event.observedBitrate
        let indicatedBps = event.indicatedBitrate
        let effectiveIndicated = effectiveIndicatedBitrate(from: indicatedBps)
        let observed = String(format: "%.1f", observedBps / 1_000_000)
        let indicated = String(format: "%.1f", indicatedBps / 1_000_000)
        let effective = String(format: "%.1f", effectiveIndicated / 1_000_000)
        let stalls = event.numberOfStalls
        let dropped = event.numberOfDroppedVideoFrames
        let tcs = player.timeControlStatus
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        let keepUp = item.isPlaybackLikelyToKeepUp
        let buffered = bufferedSeconds(of: item)
        let stallDelta = stalls - lastStalls
        Logger.info("playback host \(host) observed \(observed)Mbps indicated \(indicated)Mbps effective \(effective)Mbps stalls \(stalls)(+\(stallDelta)) dropped \(dropped)(+\(dropped - lastDroppedFrames)) serverChanges \(event.numberOfServerAddressChanges) tcs \(tcs.rawValue) wait \(waiting) keepUp \(keepUp) buffered \(String(format: "%.1f", buffered))s")
        lastStalls = stalls
        lastDroppedFrames = dropped

        checkStallHealth(stallDelta: stallDelta, buffered: buffered, currentHost: host)
    }

    /// 用户明确暂停（.paused）。卡缓冲/断网时是 .waitingToPlayAtSpecifiedRate，仍应做健康检测。
    private var isUserPaused: Bool {
        playerVC?.player?.timeControlStatus == .paused
    }

    private var isWaitingToPlay: Bool {
        playerVC?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// access log 的 indicated 在起播/loading 时常为 0 或负值；日志里的 effective 用流声明平均带宽兜底。
    private func effectiveIndicatedBitrate(from accessLogIndicated: Double) -> Double {
        if accessLogIndicated > 0 { return accessLogIndicated }
        guard let declared = playerDelegate?.primaryVideoBandwidth, declared > 0 else { return 0 }
        return Double(declared)
    }

    private func bufferedSeconds(of item: AVPlayerItem) -> Double {
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        let end = range.start.seconds + range.duration.seconds
        let current = item.currentTime().seconds
        guard end.isFinite, current.isFinite else { return 0 }
        return max(0, end - current)
    }

    /// 只根据真实卡顿触发换源：正在 waiting，或本周期新增了 stall。
    /// 播放流畅时仅 observed < indicated 不触发——indicated 常是峰值，低一些完全正常。
    private func checkStallHealth(stallDelta: Int, buffered: Double, currentHost: String) {
        guard !isUserPaused, !isEvaluatingHostSwitch else {
            stallUnhealthyStreak = 0
            return
        }
        if let lastSwitch = lastHostSwitchAt, Date().timeIntervalSince(lastSwitch) < hostSwitchCooldown {
            return
        }

        let unhealthy = isWaitingToPlay || stallDelta > 0
        if unhealthy {
            stallUnhealthyStreak += 1
        } else {
            stallUnhealthyStreak = 0
            return
        }
        guard stallUnhealthyStreak >= stallTriggerCount else { return }
        stallUnhealthyStreak = 0

        // 加速模式已在下载器内做 CDN 调度、竞速和隔离，不再重复起播测速/换 host；
        // Strict BTR: no player-level CDN switching or direct fallback.
        // 因此普通 waiting/stall 一律交由下载器：长时无进展由单调时钟看门狗兜底。
        if transportMode == .accelerated {
            noteAcceleratedWaiting(isWaiting: isWaitingToPlay)
            return
        }
    }

    func playerDidDismiss(playerVC: AVPlayerViewController) {
        guard reportWatchHistory else { return }
        guard let currentTime = playerVC.player?.currentTime().seconds, currentTime > 0 else { return }
        WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(currentTime), epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
    }

    /// 与资源加载器选主视频流的逻辑对齐，取出该流各 CDN host 的代表 URL，供起播轻量测速。
    private func primaryCDNCandidates(from info: VideoPlayURLInfo, maxQuality: Int?, streamIndex: Int?) -> [String] {
        var videos = info.dash.video
        if Settings.preferAvc {
            let videosMap = Dictionary(grouping: videos, by: { $0.id })
            for (key, values) in videosMap {
                if values.contains(where: { !$0.isHevc }) {
                    videos.removeAll(where: { $0.id == key && $0.isHevc })
                }
            }
        }
        if let streamIndex, streamIndex < info.dash.video.count {
            videos = [info.dash.video[streamIndex]]
        } else if let maxQuality {
            let matching = videos.filter { $0.id == maxQuality }
            if let best = matching.max(by: { $0.bandwidth < $1.bandwidth }) {
                videos = [best]
            } else {
                videos = matching
            }
        } else {
            let qualityLimit = Settings.mediaQuality.qn
            videos = videos.filter { $0.id <= qualityLimit }
            if let highest = videos.map(\.id).max() {
                videos = videos.filter { $0.id == highest }
            }
        }
        videos.sort { $0.bandwidth > $1.bandwidth }
        guard let primary = videos.first else { return [] }
        var seenHosts = Set<String>()
        return primary.playableURLs.filter { url in
            guard let host = URLComponents(string: url)?.host else { return false }
            return seenHosts.insert(host).inserted
        }
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        invalidatePendingLoad(tearingDown: true)
    }

    private func startLoad(urlInfo: VideoPlayURLInfo,
                           playerInfo: PlayerInfo?,
                           maxQuality: Int? = nil,
                           streamIndex: Int? = nil,
                           isQualitySwitch: Bool = false)
    {
        acceleratedWaitingSince = nil
        transportMode = .accelerated
        let generation = beginLoadGeneration()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.playmedia(urlInfo: urlInfo,
                                         playerInfo: playerInfo,
                                         generation: generation,
                                         maxQuality: maxQuality,
                                         streamIndex: streamIndex,
                                         isQualitySwitch: isQualitySwitch)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.loadGeneration == generation,
                      self.playerVC != nil
                else { return }
                Logger.warn("[player] Failed to prepare media: \(error)")
                self.onLoadFailure?(error.localizedDescription)
            }
        }
    }

    private func beginLoadGeneration() -> Int {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        return loadGeneration
    }

    private func invalidatePendingLoad(tearingDown: Bool) {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        stopBTRMonitoring()
        playerDelegate?.btrPlayback.invalidate()
        playerDelegate = nil
        if tearingDown {
            playerVC = nil
        }
    }

    private func ensureActiveLoad(_ generation: Int) throws -> AVPlayerViewController {
        guard !Task.isCancelled,
              loadGeneration == generation,
              let playerVC
        else {
            throw CancellationError()
        }
        return playerVC
    }

    @MainActor
    private func playmedia(urlInfo: VideoPlayURLInfo,
                           playerInfo: PlayerInfo?,
                           generation: Int,
                           maxQuality: Int? = nil,
                           streamIndex: Int? = nil,
                           preferredHost: String? = nil,
                           isQualitySwitch: Bool = false) async throws
    {
        _ = try ensureActiveLoad(generation)
        let prepared = try await preparedMedia(urlInfo: urlInfo,
                                               playerInfo: playerInfo,
                                               maxQuality: maxQuality,
                                               streamIndex: streamIndex,
                                               preferredHost: preferredHost,
                                               isQualitySwitch: isQualitySwitch)
        // The await above may finish after a newer load generation. Validate
        // before retaining its resource-loader delegate or touching the player.
        let playerVC = try ensureActiveLoad(generation)
        let delegate = prepared.delegate
        let asset = prepared.asset
        if playerDelegate !== delegate { playerDelegate?.btrPlayback.invalidate() }
        playerDelegate = delegate
        // Mandatory BTR; proxy startup failure is a resource-loading error.
        transportMode = delegate.effectiveTransportMode

        // AVKit 不允许在同一场全屏播放里反复切换该属性，因此只在首次装配资源时计算一次。
        if !isQualitySwitch {
            playerVC.appliesPreferredDisplayCriteriaAutomatically = shouldApplyContentMatch(delegate: delegate)
        }

        await prepare(toPlay: asset, generation: generation)
    }

    private func preparedMedia(urlInfo: VideoPlayURLInfo,
                               playerInfo: PlayerInfo?,
                               maxQuality: Int?,
                               streamIndex: Int?,
                               preferredHost: String?,
                               isQualitySwitch: Bool) async throws -> PreparedPlayerMedia
    {
        // 传输模式快照：设置只影响新建播放资源，已开始的不重建
        let mode: MediaTransportMode = .accelerated
        if !isQualitySwitch,
           maxQuality == nil,
           streamIndex == nil,
           preferredHost == nil,
           let mediaWarmupManager
        {
            let prepared = try await mediaWarmupManager.preparedMedia(for: playInfo)
            return prepared
        }
        lastStalls = 0
        lastDroppedFrames = 0
        lastMaxQuality = maxQuality
        lastStreamIndex = streamIndex

        var resolvedHost = preferredHost
        // 加速模式使用下载器内的 CDN 动态调度，不再重复执行旧版起播测速
        if resolvedHost == nil, mode != .accelerated {
            let candidates = primaryCDNCandidates(from: urlInfo, maxQuality: maxQuality, streamIndex: streamIndex)
            if let best = await CDNDiagnostics.pickFastestHost(urls: candidates) {
                resolvedHost = best
                Logger.info("[cdn] 起播选用 host: \(best)")
            }
        } else if mode == .accelerated {
            Logger.info("[cdn] 加速模式：跳过起播测速，由下载器动态调度")
        }

        return try await PlayerMediaFactory.prepare(aid: playData.aid,
                                                    urlInfo: urlInfo,
                                                    playerInfo: playerInfo,
                                                    maxQuality: maxQuality,
                                                    streamIndex: streamIndex,
                                                    preferredHost: resolvedHost,
                                                    transportMode: mode)
    }

    /// Strict BTR: preserve diagnostics, never replace the item with a direct URL.
    @MainActor
    private func reportBTRFailure(reason: String) async {
        guard let player = playerVC?.player else { return }
        let error = (player.currentItem?.error ?? player.error) as NSError?
        let code = error.map { String($0.code) } ?? "none"
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingCode = underlying.map { String($0.code) } ?? "none"
        BTRTrace.shared.event("player_failure",["reason":reason,"code":code,"underlyingCode":underlyingCode])
        btrFailureSnapshot = "BTR ONLY: \(reason); direct disabled\nplayer:\(code) underlying:\(underlyingCode)"
        // Waiting downloads may still recover; keep the current BTR item alive.
    }

    @MainActor
    func switchQuality(to qualityId: Int, streamIndex: Int?) async {
        guard let player = playerVC?.player else { return }

        // Snapshot per switch: later overlapping switches cannot overwrite this target.
        guard let target = resumeState.qualityTarget(current: player.currentTime().seconds) else { return }
        BTRTrace.shared.event("quality_switch",["from":currentQualityId ?? -1,"to":qualityId,"streamIndex":streamIndex ?? -1,"target":target])
        currentQualityId = qualityId

        // 重新加载视频，使用新的画质
        do {
            let generation = beginLoadGeneration()
            try await playmedia(urlInfo: playData.videoPlayURLInfo,
                                playerInfo: playData.playerInfo,
                                generation: generation,
                                maxQuality: qualityId,
                                streamIndex: streamIndex,
                                isQualitySwitch: true)

            // 恢复播放位置并继续播放
            guard loadGeneration == generation,
                  !Task.isCancelled,
                  playerVC != nil,
                  let newPlayer = playerVC?.player
            else { return }
            BTRTrace.shared.event("seek_requested",["source":"quality-switch","target":target,"generation":generation])
            let completed = await newPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            BTRTrace.shared.event("seek_completed",["source":"quality-switch","target":target,"generation":generation,"completed":completed])
            guard loadGeneration == generation, !Task.isCancelled, playerVC?.player === newPlayer else { return }
            newPlayer.play()
        } catch is CancellationError {
            return
        } catch {
            Logger.warn("[quality] Failed to switch quality: \(error)")
        }
    }

    private func shouldApplyContentMatch(delegate: BilibiliVideoResourceLoaderDelegate) -> Bool {
        guard Settings.contentMatch else { return false }
        guard Settings.contentMatchOnlyInHDR else { return true }
        return delegate.isHDR == true
    }

    @MainActor
    func prepare(toPlay asset: AVURLAsset, generation: Int) async {
        guard loadGeneration == generation,
              !Task.isCancelled,
              let playerVC
        else { return }
        let playerItem = AVPlayerItem(asset: asset)

        // 设置 preferredPeakBitRate 为一个很高的值，让 AVPlayer 优先选择高码率流
        // 0 表示无限制，让 AVPlayer 根据网络条件自动选择最高可用码率
        playerItem.preferredPeakBitRate = 0

        // 之前设成 60s 是为了扛 CDN 吞吐抖动，但 BANDWIDTH 声明错误的根因已修复，
        // 实测 CDN 吞吐充裕，不再需要这么激进的预缓冲。60s 在连续快进时的副作用是：
        // 每次 seek 都会立刻为新位置起一大批 60s 的 range 请求，下一个 seek 一来又整体取消重来，
        // 密集 seek 下网络连接层疲于开连接/取消，表现为长时间无响应。降到 15s 大幅减少这种抖动。
        playerItem.preferredForwardBufferDuration = 15

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = minimizeStalling
        player.isMuted = isMuted
        guard loadGeneration == generation, !Task.isCancelled else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        playerVC.player = nil
        guard loadGeneration == generation, !Task.isCancelled else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        // The nil assignment above synchronously cleans up the old player.
        // Bind the incoming session only after that callback, before publishing it.
        btrOwner = player
        btrOwnedSession = playerDelegate?.btrPlayback
        playerVC.player = player
        startBTRMonitoring(player: player)
    }
}
