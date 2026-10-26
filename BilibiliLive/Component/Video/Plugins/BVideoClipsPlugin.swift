//
//  BVideoClipsPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVKit

class BVideoClipsPlugin: NSObject, CommonPlayerPlugin {
    let clipInfos: [VideoPlayURLInfo.ClipInfo]

    private var observers = [Any]()
    private weak var playerVC: AVPlayerViewController?

    init(clipInfos: [VideoPlayURLInfo.ClipInfo]) {
        self.clipInfos = clipInfos
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
    }

    private weak var observedPlayer: AVPlayer?

    private func removeObservers() {
        if let owner = observedPlayer {
            observers.forEach { owner.removeTimeObserver($0) }
        }
        observers.removeAll()
        observedPlayer = nil
    }

    func playerWillStart(player: AVPlayer) {
        removeObservers()
        observedPlayer = player
        for clip in clipInfos {
            let start = CMTime(seconds: clip.start, preferredTimescale: 1)
            let end = CMTime(seconds: clip.end, preferredTimescale: 1)
            let startObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: start)], queue: .main) {
                [weak player, weak self] in
                let action = {
                    clip.skipped = true
                    player?.seek(to: CMTime(seconds: Double(clip.end), preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if clip.skipped != true, Settings.autoSkip {
                    action()
                } else {
                    let action = UIAction(title: clip.customText) { _ in action() }
                    self?.playerVC?.contextualActions = [action]
                }
            }
            observers.append(startObserver)

            let endObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) {
                [weak self] in
                self?.playerVC?.contextualActions = []
            }
            observers.append(endObserver)
        }
    }

    func playerDidCleanUp(player: AVPlayer) {
        removeObservers()
    }
}
