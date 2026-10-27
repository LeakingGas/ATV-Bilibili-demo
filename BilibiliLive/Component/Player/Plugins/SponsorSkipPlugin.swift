//
//  SponsorSkipPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2/11/2024.
//

import AVKit

class SponsorSkipPlugin: NSObject, CommonPlayerPlugin {
    private var clipInfos: [SponsorBlockRequest.SkipSegment] = []
    private let bvid: String
    private let duration: Double
    private var observers = [PlayerTimeObservation]()
    private weak var host: PlayerHost?
    private weak var engine: PlayerEngine?

    private var set = false

    init(bvid: String, duration: Int) {
        self.bvid = bvid
        self.duration = Double(duration)
    }

    func loadClips() async {
        do {
            clipInfos = try await SponsorBlockRequest.getSkipSegments(bvid: bvid)
            clipInfos = clipInfos.filter {
                abs(duration - $0.videoDuration) < 4
            }

            Logger.debug("[SponsorBlockRequest] get segs: \(clipInfos.map { "\($0.start)-\($0.end)" }.joined(separator: ","))")
            await MainActor.run {
                if !self.set, let engine = self.engine {
                    self.set = true
                    self.sendClipToPlayer(engine: engine)
                }
            }
        } catch {
            print(error)
        }
    }

    func sendClipToPlayer(engine: PlayerEngine) {
        // 只挂在一个播放器上：换播放器（切画质、回前台重载）时先从原来的播放器上摘掉。
        removeObservers()
        for clip in clipInfos {
            let start: Double
            let end: Double

            let buttonText: String
            let autoSkip = Settings.enableSponsorBlock == .jump
            if autoSkip {
                start = (clip.start - 5).rounded(.down)
                end = clip.start.rounded(.down)
                buttonText = "取消跳过广告"
            } else {
                start = clip.start.rounded(.down)
                end = (clip.end - 1).rounded(.down)
                buttonText = "跳过广告"
            }

            let skipAction = { [weak engine, weak self] in
                engine?.seek(to: Double(clip.end).rounded(.down))
                self?.host?.contextualActions = []
            }

            let startObserver = engine.addBoundaryObserver(times: [start]) {
                [weak self] in
                guard let self = self else { return }
                let action: UIAction
                let identifier = UIAction.Identifier(clip.UUID)
                if autoSkip {
                    action = UIAction(title: buttonText, identifier: identifier) { [weak self] _ in
                        self?.host?.contextualActions = []
                    }
                } else {
                    action = UIAction(title: buttonText, identifier: identifier) { _ in skipAction() }
                }
                host?.contextualActions = [action]
            }
            observers.append(startObserver)

            let endObserver = engine.addBoundaryObserver(times: [end]) {
                [weak self] in
                guard let self = self else { return }
                if let action = host?.contextualActions.first,
                   action.identifier.rawValue == clip.UUID, autoSkip
                {
                    skipAction()
                }
                host?.contextualActions = []
            }
            observers.append(endObserver)
        }
    }

    func playerDidLoad(host: PlayerHost) {
        self.host = host
        Task {
            await loadClips()
        }
    }

    func playerDidChange(engine: PlayerEngine) {
        self.engine = engine
    }

    func playerWillStart(engine: PlayerEngine) {
        self.engine = engine
        if !clipInfos.isEmpty {
            set = true
            sendClipToPlayer(engine: engine)
        }
    }

    func playerDidCleanUp(engine: PlayerEngine) {
        removeObservers()
    }

    private func removeObservers() {
        observers.forEach { $0.cancel() }
        observers.removeAll()
    }
}
