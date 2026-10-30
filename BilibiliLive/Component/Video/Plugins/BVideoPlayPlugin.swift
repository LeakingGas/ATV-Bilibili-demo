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
    private var playData: PlayerDetailData
    private let reportWatchHistory: Bool
    private let minimizeStalling: Bool
    /// 「不等缓冲，数据到了就播」：打开视频时读取一次。
    private let playWithoutWaiting = Settings.playWithoutWaiting
    /// 不等缓冲模式下，播放因数据不足停住（不是用户暂停），数据一到就自动继续。
    private var stalledAwaitingData = false
    /// 快速起播进行中：每个新播放器从这里开始，画面开始播放后结束，之后快进、卡顿都按正常模式处理。
    private var fastStartActive = false
    private var lastImmediateKick = -Double.infinity
    private let isMuted: Bool
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    /// VLC 模式：本插件只播一路静音的低码率「影子」视频（这条流在 dash.video 里的位置），
    /// 给系统播放器界面提供时间轴和拖动预览，画面和声音由 VLCRendererPlugin 输出。
    private let shadowStreamIndex: Int?
    private let shadowGate: MediaDeliveryGate?
    private var isShadow: Bool { shadowStreamIndex != nil }
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
         mediaWarmupManager: PlayerMediaWarmupManager? = nil,
         shadowStreamIndex: Int? = nil,
         shadowGate: MediaDeliveryGate? = nil)
    {
        self.shadowStreamIndex = shadowStreamIndex
        self.shadowGate = shadowGate
        self.playInfo = playInfo
        playData = detailData
        self.reportWatchHistory = reportWatchHistory
        self.minimizeStalling = minimizeStalling
        self.isMuted = isMuted
        self.mediaWarmupManager = mediaWarmupManager
        currentQualityId = playData.videoPlayURLInfo.quality
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

    // MARK: - 回到 App 后续播

    // 回到主屏幕后系统会挂起 App，本地 BTR 代理的监听连接随之失效；回来时播放器还连着
    // 失效的代理，一直转圈。回到前台时用新的代理在原位置重新加载（与切画质同一流程）。
    private var lifecycleObservers = [NSObjectProtocol]()
    private var backgroundedAt: Date?
    private var wasPlayingWhenBackgrounded = false
    /// 进后台时已经把播放项卸掉，回来必须重建（不论离开多久）。
    private var backgroundPosition: Double?

    private func handleEnterBackground() {
        Diag.mark("BPLAY \(Diag.id(self)) enterBackground avplayer=\(Diag.id(playerVC?.player)) item=\(Diag.id(playerVC?.player?.currentItem)) mode=\(transportMode) pip=\(CommonPlayerViewController.PipRecorder.shared.playingPipViewController.count)")
        guard let player = playerVC?.player else { return }
        if isShadow {
            // 黑画面影子不联网，不用拆；只记观看进度。
            let position = player.currentTime().seconds
            if reportWatchHistory, position.isFinite, position > 0 {
                WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(position), epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
            }
            return
        }
        backgroundedAt = Date()
        wasPlayingWhenBackgrounded = player.rate > 0 || player.timeControlStatus != .paused
        // 画中画还在播时不能动它。
        if transportMode == .accelerated,
           CommonPlayerViewController.PipRecorder.shared.playingPipViewController.isEmpty,
           player.currentItem != nil
        {
            let position = player.currentTime().seconds
            if position.isFinite {
                // 挂起前主动断开播放器到本地代理的连接，回来后用新地址、新代理整体重建。
                // 否则 App 恢复时播放器、代理线程和失效的连接同时收拾残局，偶尔会闪退。
                backgroundPosition = position
                if reportWatchHistory, position > 0 {
                    WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(position), epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
                }
                loadTask?.cancel()
                loadGeneration += 1
                stopBTRMonitoring()
                player.pause()
                player.replaceCurrentItem(with: nil)
                playerDelegate?.btrPlayback.invalidate()
                Diag.mark("BPLAY \(Diag.id(self)) background teardown done pos=\(Int(position))")
            }
        }
        // 预热好的下一集也绑着失效的代理，一并丢弃。
        Task { [mediaWarmupManager] in await mediaWarmupManager?.cancelAll() }
    }

    private func handleEnterForeground() {
        guard !isShadow else { return }
        Diag.mark("BPLAY \(Diag.id(self)) enterForeground saved=\(backgroundPosition.map { String(Int($0)) } ?? "nil") avplayer=\(Diag.id(playerVC?.player)) vc=\(Diag.id(playerVC))")
        guard let since = backgroundedAt, transportMode == .accelerated, let player = playerVC?.player else { return }
        backgroundedAt = nil
        let saved = backgroundPosition
        backgroundPosition = nil
        guard saved != nil || Date().timeIntervalSince(since) > 2 else { return }
        let position = saved ?? player.currentTime().seconds
        guard position.isFinite else { return }
        let resume = wasPlayingWhenBackgrounded
        BTRTrace.shared.event("foreground_reload",["position":position,"resume":resume])
        Task { @MainActor [weak self] in
            await self?.reloadInPlace(at: position, resume: resume)
        }
    }

    /// B 站视频地址带签名和过期时间，离开较久后旧地址会被 CDN 拒绝（之前回来一直黑屏的偶发原因之一），
    /// 所以重载前先重新请求播放地址；刚从后台回来网络可能还没就绪，失败时稍等重试。
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
                Diag.mark("BPLAY \(Diag.id(self)) refreshPlayURL ok attempt=\(attempt)")
                BTRTrace.shared.event("foreground_playurl",["attempt":attempt,"ok":true])
                return
            } catch {
                Diag.mark("BPLAY \(Diag.id(self)) refreshPlayURL failed attempt=\(attempt) \((error as NSError).domain)#\((error as NSError).code)")
                BTRTrace.shared.event("foreground_playurl",["attempt":attempt,"ok":false])
            }
        }
    }

    @MainActor
    private func reloadInPlace(at position: Double, resume: Bool) async {
        await refreshPlayURL()
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            if await reloadOnce(at: position, resume: resume) { return }
        }
        onLoadFailure?("回到 App 后重新加载失败，请返回后重新打开视频")
    }

    // 必须在主线程：seek 的 await 之后会继续操作播放器，AVKit 随之刷新界面。
    // 之前这里没标主线程，seek 回来在后台线程调 play/pause，AVKit 在后台改布局 → 闪退（诊断日志实锤）。
    @MainActor
    private func reloadOnce(at position: Double, resume: Bool) async -> Bool {
        do {
            let generation = beginLoadGeneration()
            Diag.mark("BPLAY \(Diag.id(self)) reload begin gen=\(generation) pos=\(Int(position)) vc=\(Diag.id(playerVC))")
            try await playmedia(urlInfo: playData.videoPlayURLInfo,
                                playerInfo: playData.playerInfo,
                                generation: generation,
                                maxQuality: lastMaxQuality,
                                streamIndex: lastStreamIndex,
                                isQualitySwitch: true)
            guard loadGeneration == generation, !Task.isCancelled, let newPlayer = playerVC?.player else { return true }
            _ = await newPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard loadGeneration == generation, playerVC?.player === newPlayer else { return true }
            if resume { newPlayer.play() } else { newPlayer.pause() }
            Diag.mark("BPLAY \(Diag.id(self)) reload done gen=\(generation) avplayer=\(Diag.id(newPlayer))")
            return true
        } catch is CancellationError {
            return true
        } catch {
            Logger.warn("[player] foreground reload failed: \(error)")
            Diag.mark("BPLAY \(Diag.id(self)) reload failed \((error as NSError).domain)#\((error as NSError).code)")
            BTRTrace.shared.event("foreground_reload_failed",BTRTrace.errorFields(error))
            return false
        }
    }

    deinit {
        Diag.mark("BPLAY \(Diag.id(self)) deinit")
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        btrTimer?.invalidate()
        if let btrJumpObserver { NotificationCenter.default.removeObserver(btrJumpObserver) }
        playerDelegate?.btrPlayback.invalidate()
        networkLogTimer?.invalidate()
    }

    /// 当前实际播放的视频流（供画质菜单标记当前项）。
    var currentMedia: VideoPlayURLInfo.DashInfo.DashMediaInfo? { playerDelegate?.primaryMedia }

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
        if let media = playerDelegate?.primaryVideoDescription, !media.isEmpty { lines.append("stream: " + media) }
        if !startupMarks.isEmpty { lines.append("\(startupKind): " + startupMarks.joined(separator: " → ")) }
        if let accel = playerDelegate?.accelerationDebugInfo, !accel.isEmpty {
            lines.append("last completed track: " + accel)
        }
        if !btrFailureSnapshot.isEmpty { lines.append(btrFailureSnapshot) }
        if !cdnProbeReport.isEmpty {
            lines.append(cdnProbeReport)
        }
        return lines.joined(separator: "\n")
    }

    func playerDidFail(engine: PlayerEngine) {
        // Strict BTR: report failure without switching transport.
        guard transportMode == .accelerated, let player = engine.avPlayer, playerVC?.player === player else { return }
        Task { @MainActor [weak self] in
            await self?.reportBTRFailure(reason: "player-failed")
        }
    }

    func playerDidLoad(host: PlayerHost) {
        guard let playerVC = host.avPlayerViewController else { return }
        Diag.startupStep("player_engine", ["kind": "system"])
        Diag.mark("BPLAY \(Diag.id(self)) playerDidLoad aid=\(playData.aid) cid=\(playData.cid) start=\(playData.playerStartPos ?? -1)")
        self.playerVC = playerVC
        playerVC.player = nil
        if isShadow {
            startBlankShadow()
            return
        }
        startLoad(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo, streamIndex: shadowStreamIndex)
    }

    /// VLC 模式的影子：播本地生成的视频（时长和视频一样），不联网、不缓冲、不会卡，
    /// 只用来驱动系统播放界面（进度条、控制栏、下滑面板）。
    /// 内容是 B 站的预览截图做成的幻灯片（拖动进度条的缩略图、长按快进快退的画面都靠它）；
    /// 2 秒内做不出来就先用黑画面（后台继续做完缓存，下次打开同一视频就有了）。
    private func startBlankShadow() {
        let info = playData.videoPlayURLInfo
        let duration = info.timelength > 0 ? Double(info.timelength) / 1000 : Double(info.dash.duration)
        let generation = beginLoadGeneration()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let started = Date()
                let aid = self.playData.aid, cid = self.playData.cid
                let previewTask = Task { try await PreviewShadowAsset.clipURL(aid: aid, cid: cid, duration: duration) }
                let previewURL = await withTaskGroup(of: URL?.self) { group -> URL? in
                    group.addTask { try? await previewTask.value }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                let item: AVPlayerItem
                if let previewURL {
                    item = AVPlayerItem(asset: AVURLAsset(url: previewURL))
                } else {
                    item = try await BlankShadowAsset.makeItem(duration: duration)
                }
                Diag.startupStep("shadow_content", ["kind": previewURL == nil ? "blank" : "preview"])
                guard self.loadGeneration == generation, !Task.isCancelled, let playerVC = self.playerVC else { return }
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                Diag.startupStep("blank_shadow_ready", ["duration": duration, "ms": Date().timeIntervalSince(started) * 1000])
                playerVC.player = nil
                guard self.loadGeneration == generation, !Task.isCancelled else { return }
                Diag.mark("BPLAY \(Diag.id(self)) install blank shadow avplayer=\(Diag.id(player)) duration=\(Int(duration))")
                playerVC.player = player
            } catch {
                guard self.loadGeneration == generation, !Task.isCancelled else { return }
                Diag.startupStep("blank_shadow_failed", ["error": String(describing: error).prefix(160)])
                self.onLoadFailure?("影子播放器创建失败：\(error)")
            }
        }
    }

    func playerWillStart(engine: PlayerEngine) {
        guard let player = engine.avPlayer else { return }
        if playerVC?.player === player { markStartup("ready") }
        guard playerVC?.player === player,
              let target = resumeState.initialTarget(history: playData.playerStartPos.map { Double($0) }) else { return }
        BTRTrace.shared.event("seek_requested",["source":"initial-history","target":target,"generation":loadGeneration])
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playerDidStart(engine _: PlayerEngine) {
        startNetworkLogging()
    }

    func playerDidCleanUp(engine: PlayerEngine) {
        guard let player = engine.avPlayer else { return }
        Diag.mark("BPLAY \(Diag.id(self)) cleanUp avplayer=\(Diag.id(player)) owner=\(btrOwner === player)")
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
        var actions: [UIMenuElement] = [action]
        if playerDelegate?.isHDR == true {
            let diag = UIAction(title: isRunningHDRDiag ? "HDR 诊断中…" : "HDR 诊断", image: UIImage(systemName: "stethoscope")) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.runHDRDiagnostics() }
            }
            actions.append(diag)
        }
        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") }),
            let index = current.firstIndex(of: setting)
        {
            current[index] = setting.replacingChildren(setting.children + actions)
            return []
        }
        return []
    }

    // MARK: - HDR10：先把电视切到 HDR10，再交给系统播放器

    private var didSetDisplayCriteria = false
    private weak var displayManager: AVDisplayManager?

    /// 和 Infuse 一样：电视还在 SDR 模式时系统播放器会直接拒绝 HDR10 流，所以先请求切换显示模式，
    /// 等切换完成再加载。只在 Apple TV 和本 App 都开着「匹配动态范围」时做。
    @MainActor
    private func switchDisplayForHDRIfNeeded(asset: AVURLAsset) async {
        guard !isShadow, let delegate = playerDelegate, delegate.isHDR else { return }
        let (need, reason) = await delegate.displayNeed()
        guard let need else {
            BTRTrace.shared.event("hdr_display_switch", ["result": "not_needed", "reason": reason])
            return
        }
        var fields: [String: Any] = ["kind": need.kind.rawValue, "frameRate": need.frameRate, "size": "\(need.width)x\(need.height)"]
        guard let manager = playerVC?.view.window?.avDisplayManager ?? UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first?.avDisplayManager
        else {
            fields["result"] = "no_display_manager"
            BTRTrace.shared.event("hdr_display_switch", fields)
            return
        }
        guard manager.isDisplayCriteriaMatchingEnabled, Settings.contentMatch else {
            fields["result"] = "matching_off"
            fields["system"] = manager.isDisplayCriteriaMatchingEnabled
            fields["app"] = Settings.contentMatch
            BTRTrace.shared.event("hdr_display_switch", fields)
            return
        }
        guard let criteria = await Self.displayCriteria(need: need, asset: asset) else {
            fields["result"] = "no_criteria"
            BTRTrace.shared.event("hdr_display_switch", fields)
            return
        }
        // 以系统的「切换开始 / 结束」通知为准（设备日志：只查「正在切换」状态时两次都一直等到 9 秒上限，
        // 另一次 2.9 秒就好，分不清是电视真慢还是状态没及时变回来）。状态查询保留作对照，9 秒上限兜底。
        let started = Date()
        func ms() -> Double { Date().timeIntervalSince(started) * 1000 }
        final class NoteTimes: @unchecked Sendable {
            private let lock = NSLock()
            private var startValue: Double?
            private var endValue: Double?
            var start: Double? { lock.lock(); defer { lock.unlock() }; return startValue }
            var end: Double? { lock.lock(); defer { lock.unlock() }; return endValue }
            func markStart(_ v: Double) { lock.lock(); if startValue == nil { startValue = v }; lock.unlock() }
            func markEnd(_ v: Double) { lock.lock(); if endValue == nil { endValue = v }; lock.unlock() }
        }
        let notes = NoteTimes()
        let startedAt = started
        var flagOnMs: Double?, flagOffMs: Double?
        let center = NotificationCenter.default
        let startObserver = center.addObserver(forName: .AVDisplayManagerModeSwitchStart, object: manager, queue: .main) { _ in
            notes.markStart(Date().timeIntervalSince(startedAt) * 1000)
        }
        let endObserver = center.addObserver(forName: .AVDisplayManagerModeSwitchEnd, object: manager, queue: .main) { _ in
            notes.markEnd(Date().timeIntervalSince(startedAt) * 1000)
        }
        defer {
            center.removeObserver(startObserver)
            center.removeObserver(endObserver)
        }
        manager.preferredDisplayCriteria = criteria
        didSetDisplayCriteria = true
        displayManager = manager
        // 先等切换开始（通知或状态，最多 1 秒），再等结束（结束通知，或状态变回来，最多 9 秒）。
        while ms() < 1000, notes.start == nil, flagOnMs == nil {
            if manager.isDisplayModeSwitchInProgress { flagOnMs = ms() }
            else { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        let began = notes.start != nil || flagOnMs != nil
        var endedBy = "-"
        while began, ms() < 9000 {
            let inProgress = manager.isDisplayModeSwitchInProgress
            if inProgress, flagOnMs == nil { flagOnMs = ms() }
            if !inProgress, flagOnMs != nil, flagOffMs == nil { flagOffMs = ms() }
            if notes.end != nil { endedBy = "end_notification"; break }
            if flagOffMs != nil, notes.start == nil { endedBy = "flag"; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if began, endedBy == "-" { endedBy = "timeout" }
        fields["result"] = began ? "switched" : "no_switch_needed"
        fields["endedBy"] = endedBy
        fields["waitMs"] = ms()
        fields["startNoteMs"] = notes.start ?? -1
        fields["endNoteMs"] = notes.end ?? -1
        fields["flagOnMs"] = flagOnMs ?? -1
        fields["flagOffMs"] = flagOffMs ?? -1
        fields["flagNow"] = manager.isDisplayModeSwitchInProgress
        BTRTrace.shared.event("hdr_display_switch", fields)
    }

    private static func displayCriteria(need: BilibiliVideoResourceLoaderDelegate.DisplayNeed, asset: AVURLAsset) async -> AVDisplayCriteria? {
        if #available(tvOS 17.0, *) {
            var description: CMFormatDescription?
            var extensions: [CFString: Any] = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
            var codec = kCMVideoCodecType_HEVC
            if need.kind == .dolbyVision, let box = need.dolbyBox {
                // 杜比视界：编码类型 dvh1，带上视频自己的 dvcC / dvvC 配置盒，系统据此决定切成杜比视界模式。
                codec = 0x6476_6831 // 'dvh1'
                extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [box.type: box.payload] as CFDictionary
            }
            CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                           width: Int32(need.width), height: Int32(need.height),
                                           extensions: extensions as CFDictionary, formatDescriptionOut: &description)
            guard let description else { return nil }
            return AVDisplayCriteria(refreshRate: need.frameRate, formatDescription: description)
        }
        return asset.preferredDisplayCriteria
    }

    // MARK: - HDR 诊断（临时）

    private var pendingHDRDiagMode: BilibiliVideoResourceLoaderDelegate.HDRDiagnosticMode = .none
    private var isRunningHDRDiag = false

    /// 依次用几种主播放列表写法重新加载当前视频，每种最多等 6 秒，记下系统播放器肯不肯开始加载，最后恢复原样。
    @MainActor
    private func runHDRDiagnostics() async {
        guard !isRunningHDRDiag, !isShadow else { return }
        isRunningHDRDiag = true
        defer {
            isRunningHDRDiag = false
            pendingHDRDiagMode = .none
        }
        let position = playerVC?.player?.currentTime().seconds ?? 0
        BTRTrace.shared.event("hdr_diag_begin", ["eligibleForHDR": AVPlayer.eligibleForHDRPlayback,
                                                 "hdrModes": AVPlayer.availableHDRModes.rawValue,
                                                 "position": position])
        Diag.eventWindow("HDR 诊断")
        for mode in [BilibiliVideoResourceLoaderDelegate.HDRDiagnosticMode.original, .noIFrame, .appleCodec, .noRange] {
            pendingHDRDiagMode = mode
            let generation = beginLoadGeneration()
            let started = Date()
            do {
                try await playmedia(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo, generation: generation,
                                    maxQuality: lastMaxQuality, streamIndex: lastStreamIndex, isQualitySwitch: true)
            } catch {
                BTRTrace.shared.event("hdr_diag", ["mode": mode.rawValue, "result": "load_error", "error": String(describing: error).prefix(120)])
                continue
            }
            var result = "timeout"
            while Date().timeIntervalSince(started) < 6 {
                guard loadGeneration == generation else { return }
                if let item = playerVC?.player?.currentItem {
                    if item.status == .readyToPlay { result = "ready"; break }
                    if item.status == .failed { result = "failed"; break }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let item = playerVC?.player?.currentItem
            let error = (item?.error as NSError?).map { "\($0.domain)#\($0.code)" } ?? "-"
            let errorLog = item?.errorLog()?.events.last.map { "\($0.errorDomain)#\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? "-"
            BTRTrace.shared.event("hdr_diag", ["mode": mode.rawValue, "result": result,
                                               "waitMs": Date().timeIntervalSince(started) * 1000,
                                               "size": item.map { "\(Int($0.presentationSize.width))x\(Int($0.presentationSize.height))" } ?? "-",
                                               "error": error, "errorLog": errorLog])
        }
        // 恢复原样（正常写法），回到诊断前的位置。
        pendingHDRDiagMode = .none
        let generation = beginLoadGeneration()
        try? await playmedia(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo, generation: generation,
                             maxQuality: lastMaxQuality, streamIndex: lastStreamIndex, isQualitySwitch: true)
        if loadGeneration == generation, let player = playerVC?.player, position > 0 {
            _ = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        BTRTrace.shared.event("hdr_diag_end")
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

    /// 起播记录：系统播放器的状态变化、等待原因、缓冲、访问日志（只记录，不影响播放）。
    private var avStateObservations = [NSKeyValueObservation]()
    private var avStateObservers = [NSObjectProtocol]()

    private func observeAVState(player: AVPlayer, item: AVPlayerItem) {
        avStateObservations.removeAll()
        avStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        avStateObservers.removeAll()
        let id = Diag.id(player)
        var lastStatus = player.timeControlStatus
        avStateObservations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            let status = ["paused", "waiting", "playing"][min(player.timeControlStatus.rawValue, 2)]
            if lastStatus == .playing, player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                Diag.eventWindow(String(format: "stall at %.1fs", player.currentTime().seconds))
            }
            lastStatus = player.timeControlStatus
            Diag.startupStep("av_time_control", ["player": id, "status": status, "reason": player.reasonForWaitingToPlay?.rawValue ?? "-"])
        })
        avStateObservations.append(player.observe(\.reasonForWaitingToPlay, options: [.new]) { player, _ in
            Diag.startupStep("av_waiting_reason", ["player": id, "reason": player.reasonForWaitingToPlay?.rawValue ?? "-"])
        })
        avStateObservations.append(item.observe(\.status, options: [.initial, .new]) { item, _ in
            Diag.startupStep("av_item_status", ["player": id, "status": item.status.rawValue, "error": (item.error as NSError?)?.code ?? 0])
        })
        avStateObservations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { item, _ in
            Diag.startupStep("av_likely_keep_up", ["player": id, "value": item.isPlaybackLikelyToKeepUp])
        })
        avStateObservations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { item, _ in
            Diag.startupStep("av_buffer_empty", ["player": id, "value": item.isPlaybackBufferEmpty])
        })
        avStateObservations.append(item.observe(\.loadedTimeRanges, options: [.new]) { item, _ in
            let ranges = item.loadedTimeRanges.map { $0.timeRangeValue }
                .map { String(format: "%.1f-%.1f", $0.start.seconds, ($0.start + $0.duration).seconds) }
                .joined(separator: ",")
            Diag.startupStep("av_loaded", ["player": id, "ranges": ranges])
        })
        avStateObservations.append(item.observe(\.presentationSize, options: [.new]) { item, _ in
            Diag.startupStep("av_presentation_size", ["player": id, "size": "\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))"])
        })
        let center = NotificationCenter.default
        avStateObservers.append(center.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: nil) { _ in
            guard let event = item.accessLog()?.events.last else { return }
            Diag.startupStep("av_access_log", ["player": id, "startupTime": event.startupTime, "transferDuration": event.transferDuration,
                                                "bytes": event.numberOfBytesTransferred, "observedBitrate": event.observedBitrate,
                                                "indicatedBitrate": event.indicatedBitrate, "segments": event.numberOfMediaRequests,
                                                "stalls": event.numberOfStalls])
        })
        avStateObservers.append(center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: nil) { _ in
            guard let event = item.errorLog()?.events.last else { return }
            Diag.startupStep("av_error_log", ["player": id, "status": event.errorStatusCode, "domain": event.errorDomain,
                                               "comment": String((event.errorComment ?? "").replacingOccurrences(of: "https?://\\S+", with: "<url>", options: .regularExpression).prefix(120))])
        })
        avStateObservers.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil) { _ in
            Diag.startupStep("av_stalled", ["player": id])
        })
    }

    private func stopBTRMonitoring() {
        avStateObservations.removeAll()
        avStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        avStateObservers.removeAll()
        btrTimer?.invalidate(); btrTimer = nil
        if let btrJumpObserver { NotificationCenter.default.removeObserver(btrJumpObserver) }
        btrJumpObserver = nil
    }
    private func startBTRMonitoring(player: AVPlayer) {
        stopBTRMonitoring()
        guard transportMode == .accelerated, let item = player.currentItem else { return }
        observeAVState(player: player, item: item)
        if playWithoutWaiting {
            avStateObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                // 只在起播阶段接管；开始播放后交还系统播放器自己等缓冲。
                guard let self, self.fastStartActive else { return }
                self.stalledAwaitingData = true
                BTRTrace.shared.event("playback_stalled",["position":player.currentTime().seconds])
                // 不等缓冲模式下系统卡住时会直接变成「暂停」（画面上出现暂停符号）。
                // 改为等待状态（显示加载圈），数据一到由 playIfDataArrived 立刻继续。
                player.automaticallyWaitsToMinimizeStalling = true
                player.play()
            })
        }
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
                if self.startupMarks.contains(where: { $0.hasPrefix("playing") }) {
                    Diag.eventWindow(String(format: "seek to %.1fs", player.currentTime().seconds))
                }
                self.sampleBTR(player: player, jumped: true)
            }
    }
    private var lastTraceSample = -Double.infinity
    // diag13: startup timeline shown in the debug overlay.
    private var startupBegan: Double?
    private var startupKind = "起播"
    private var startupMarks = [String]()
    private func markStartup(_ name: String) {
        guard let began = startupBegan, !startupMarks.contains(where: { $0.hasPrefix(name) }) else { return }
        let elapsed = (BTRTrace.now - began) / 1000
        startupMarks.append(String(format: "%@ %.1fs", name, elapsed))
        BTRTrace.shared.event("startup_mark",["mark":name,"kind":startupKind,"elapsedMs":BTRTrace.now - began])
        if name == "playing" { startupBegan = nil }
    }
    // diag10 ended with 13.9 s buffered while AVPlayer kept waiting "to minimize stalls" until the
    // 60 s watchdog fired: its keep-up estimate lags behind the burst-y BTR delivery. With several
    // seconds contiguous at the playhead, resume playback instead of freezing.
    private var bufferedWaitingSince: Double?
    private var lastKickStart = -Double.infinity
    private func kickStartIfBuffered(player: AVPlayer, ahead: Double) {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              player.reasonForWaitingToPlay == .toMinimizeStalls,
              !isUserPaused, ahead >= 6 else { bufferedWaitingSince = nil; return }
        let now = BTRTrace.now
        guard let since = bufferedWaitingSince else { bufferedWaitingSince = now; return }
        guard now - since >= 1500, now - lastKickStart >= 5000 else { return }
        lastKickStart = now; bufferedWaitingSince = nil
        BTRTrace.shared.event("player_kickstart",["ahead":ahead,"waitedMs":now - since,"position":player.currentTime().seconds])
        player.playImmediately(atRate: Float(btrLastRate))
    }
    /// 不等缓冲模式：只要播放头前面有一点数据就立刻播，不等系统评估网速。
    private func playIfDataArrived(player: AVPlayer, item: AVPlayerItem, ahead: Double) {
        if player.timeControlStatus == .playing {
            // 画面开始播放：快速起播结束，恢复正常缓冲（之后快进、卡顿由系统播放器自己等数据）。
            stalledAwaitingData = false
            fastStartActive = false
            player.automaticallyWaitsToMinimizeStalling = minimizeStalling
            if !isShadow, item.preferredForwardBufferDuration < 15 { item.preferredForwardBufferDuration = 15 }
            BTRTrace.shared.event("fast_start_off", ["position": player.currentTime().seconds, "ahead": ahead,
                                                     "waitsToMinimizeStalling": player.automaticallyWaitsToMinimizeStalling,
                                                     "forwardBuffer": item.preferredForwardBufferDuration])
            return
        }
        guard item.status == .readyToPlay else { return }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        guard waiting || stalledAwaitingData else { return } // .paused 且未卡顿 = 用户暂停
        let now = BTRTrace.now
        guard ahead >= (stalledAwaitingData ? 1.0 : 0.3), now - lastImmediateKick >= 500 else { return }
        lastImmediateKick = now
        stalledAwaitingData = false
        BTRTrace.shared.event("play_immediately",["ahead":ahead,"reason":player.reasonForWaitingToPlay?.rawValue ?? "stalled",
                                                  "position":player.currentTime().seconds])
        player.playImmediately(atRate: Float(btrLastRate))
    }

    private func sampleBTR(player: AVPlayer, jumped: Bool = false) {
        guard let item = player.currentItem, let session = playerDelegate?.btrPlayback else { return }
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        // VLC 模式下影子播放器会被临时调到极低速率等 VLC，那不是用户的倍速。
        if player.rate > 0.1 { btrLastRate = Double(player.rate) }
        // loadedTimeRanges may contain disconnected seek islands. Only merge ranges
        // contiguous with the playhead, never count a distant prefetched island.
        let ranges = item.loadedTimeRanges.map { $0.timeRangeValue }.sorted { $0.start.seconds < $1.start.seconds }
        var end = position
        for range in ranges {
            let start = range.start.seconds, finish = CMTimeRangeGetEnd(range).seconds
            if start.isFinite && finish.isFinite && start <= end + 0.05 && finish > end { end = finish }
        }
        kickStartIfBuffered(player: player, ahead: max(0, end - position))
        if fastStartActive { playIfDataArrived(player: player, item: item, ahead: max(0, end - position)) }
        if player.timeControlStatus == .playing { markStartup("playing") }
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

    func playerDidDismiss(host: PlayerHost) {
        guard reportWatchHistory else { return }
        guard let currentTime = host.avPlayerViewController?.player?.currentTime().seconds, currentTime > 0 else { return }
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

    func playerWillCleanUp(host: PlayerHost) {
        Diag.mark("BPLAY \(Diag.id(self)) willCleanUp")
        if didSetDisplayCriteria {
            didSetDisplayCriteria = false
            displayManager?.preferredDisplayCriteria = nil
        }
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
        startupBegan = BTRTrace.now
        startupKind = isQualitySwitch ? "切画质" : "起播"
        startupMarks = []
        Diag.startupStep("bplay_load_begin", ["qualitySwitch": isQualitySwitch])
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
                Diag.mark("BPLAY \(Diag.id(self)) prepare failed \((error as NSError).domain)#\((error as NSError).code)")
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
        delegate.deliveryGate = shadowGate
        delegate.hdrDiagnosticMode = pendingHDRDiagMode
        markStartup("prepared")
        // diag13: start the first segment before AVPlayer asks for it, from the history position
        // when there is one (EXT-X-START makes AVPlayer request that segment directly).
        if !isQualitySwitch {
            let history = playData.playerStartPos.map { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
            delegate.startOffset = history
            Task { await delegate.prewarmStart(at: history ?? 0) }
        }
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
        await switchDisplayForHDRIfNeeded(asset: asset)
        guard loadGeneration == generation, !Task.isCancelled else { return }
        let playerItem = AVPlayerItem(asset: asset)

        // 设置 preferredPeakBitRate 为一个很高的值，让 AVPlayer 优先选择高码率流
        // 0 表示无限制，让 AVPlayer 根据网络条件自动选择最高可用码率
        playerItem.preferredPeakBitRate = 0

        // 之前设成 60s 是为了扛 CDN 吞吐抖动，但 BANDWIDTH 声明错误的根因已修复，
        // 实测 CDN 吞吐充裕，不再需要这么激进的预缓冲。60s 在连续快进时的副作用是：
        // 每次 seek 都会立刻为新位置起一大批 60s 的 range 请求，下一个 seek 一来又整体取消重来，
        // 密集 seek 下网络连接层疲于开连接/取消，表现为长时间无响应。降到 15s 大幅减少这种抖动。
        playerItem.preferredForwardBufferDuration = 15
        if playWithoutWaiting {
            // 开播前只要求很少的缓冲，开播后再恢复到 15 秒（见 sampleBTR）。
            playerItem.preferredForwardBufferDuration = 4
        }

        if isShadow {
            // 影子只提前缓冲 2 秒：VLC 卡住时，影子最多再走两秒就停下等（见 VLCRendererPlugin）。
            playerItem.preferredForwardBufferDuration = 2
        }
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = playWithoutWaiting ? false : minimizeStalling
        fastStartActive = playWithoutWaiting
        stalledAwaitingData = false
        Diag.startupStep("av_player_created", ["waitsToMinimizeStalling": player.automaticallyWaitsToMinimizeStalling,
                                               "forwardBuffer": playerItem.preferredForwardBufferDuration])
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
        Diag.mark("BPLAY \(Diag.id(self)) install avplayer=\(Diag.id(player)) gen=\(generation) delegate=\(Diag.id(playerDelegate))")
        playerVC.player = player
        startBTRMonitoring(player: player)
    }
}

/// VLC 模式影子用的黑画面：1 秒的 64×36 黑色 H.264 片段（首次生成后缓存），拉伸成视频的时长。
enum BlankShadowAsset {
    private static let clipName = "blank-shadow-v1.mp4"

    static func makeItem(duration: Double) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: try await clipURL())
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw "黑画面没有视频轨" }
        let clipDuration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw "无法创建影子轨道"
        }
        let clipRange = CMTimeRange(start: .zero, duration: clipDuration)
        try compositionTrack.insertTimeRange(clipRange, of: track, at: .zero)
        compositionTrack.scaleTimeRange(clipRange, toDuration: CMTime(seconds: max(duration, 1), preferredTimescale: 600))
        return AVPlayerItem(asset: composition)
    }

    private static func clipURL() async throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent(clipName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let temp = directory.appendingPathComponent("blank-\(UUID().uuidString).mp4")
        let width = 64, height = 36
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: width,
                                                                           AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? "无法生成黑画面" }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw "无法创建画面缓冲" }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for second in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 2))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? "黑画面写入失败" }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }
}

/// VLC 模式影子用的预览幻灯片：B 站「视频快照」接口给的预览截图（雪碧图），按时间点切开，
/// 写成一段很小的本地视频（每张截图一个关键帧）。按 cid 缓存。
enum PreviewShadowAsset {
    private static let version = "v1"

    static func clipURL(aid: Int, cid: Int, duration: Double) async throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shadow-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(cid)-\(version).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        cleanUp(directory)

        var components = URLComponents(string: "https://api.bilibili.com/x/player/videoshot")!
        components.queryItems = [URLQueryItem(name: "aid", value: String(aid)),
                                 URLQueryItem(name: "cid", value: String(cid)),
                                 URLQueryItem(name: "index", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["data"] as? [String: Any],
              let images = info["image"] as? [String], !images.isEmpty,
              let xLen = (info["img_x_len"] as? NSNumber)?.intValue, xLen > 0,
              let yLen = (info["img_y_len"] as? NSNumber)?.intValue, yLen > 0,
              let width = (info["img_x_size"] as? NSNumber)?.intValue, width > 0,
              let height = (info["img_y_size"] as? NSNumber)?.intValue, height > 0
        else { throw "没有预览截图" }
        var times = ((info["index"] as? [NSNumber]) ?? []).map(\.doubleValue)
        let perSprite = xLen * yLen

        // 雪碧图并行下载，按顺序放好。
        let sprites: [CGImage] = try await withThrowingTaskGroup(of: (Int, CGImage?).self) { group in
            for (offset, path) in images.enumerated() {
                group.addTask {
                    let link = path.hasPrefix("//") ? "https:" + path : path
                    guard let spriteURL = URL(string: link) else { return (offset, nil) }
                    let (bytes, _) = try await URLSession.shared.data(from: spriteURL)
                    return (offset, UIImage(data: bytes)?.cgImage)
                }
            }
            var result = [CGImage?](repeating: nil, count: images.count)
            for try await (offset, image) in group { result[offset] = image }
            return result.compactMap { $0 }
        }
        guard sprites.count == images.count else { throw "预览截图下载不全" }
        let totalThumbs = sprites.count * perSprite
        if times.count == totalThumbs + 1 { times.removeFirst() }
        let count = min(times.count, totalThumbs)
        guard count > 1 else { throw "预览截图太少" }

        let temp = directory.appendingPathComponent("tmp-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? "无法生成预览视频" }
        writer.startSession(atSourceTime: .zero)
        var lastTime = -1.0
        for index in 0..<count {
            try Task.checkCancellation()
            // 第一张放在 0 秒（开头没有截图时也有画面）；时间必须递增且在视频长度内。
            let time = index == 0 ? 0 : times[index]
            guard time > lastTime, time < duration else { continue }
            let sprite = sprites[index / perSprite]
            let cell = index % perSprite
            let rect = CGRect(x: (cell % xLen) * width, y: (cell / xLen) * height, width: width, height: height)
            guard let thumb = sprite.cropping(to: rect), let buffer = makeBuffer(thumb, width: width, height: height) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
            lastTime = time
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw writer.error ?? "预览视频写入失败"
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }

    private static func makeBuffer(_ image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// 缓存超过 300 个时删掉最旧的一半。
    private static func cleanUp(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > 300 else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a < b
        }
        sorted.prefix(files.count / 2).forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
