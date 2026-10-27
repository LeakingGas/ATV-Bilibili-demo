//
//  BVideoClipsPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVKit

class BVideoClipsPlugin: NSObject, CommonPlayerPlugin {
    let clipInfos: [VideoPlayURLInfo.ClipInfo]

    private var observers = [PlayerTimeObservation]()
    private weak var host: PlayerHost?

    init(clipInfos: [VideoPlayURLInfo.ClipInfo]) {
        self.clipInfos = clipInfos
    }

    func playerDidLoad(host: PlayerHost) {
        self.host = host
    }

    private func removeObservers() {
        observers.forEach { $0.cancel() }
        observers.removeAll()
    }

    func playerWillStart(engine: PlayerEngine) {
        removeObservers()
        for clip in clipInfos {
            let start = Double(clip.start).rounded(.down)
            let end = Double(clip.end).rounded(.down)
            let startObserver = engine.addBoundaryObserver(times: [start]) {
                [weak engine, weak self] in
                let action = {
                    clip.skipped = true
                    engine?.seek(to: Double(clip.end).rounded(.down))
                }
                if clip.skipped != true, Settings.autoSkip {
                    action()
                } else {
                    let action = UIAction(title: clip.customText) { _ in action() }
                    self?.host?.contextualActions = [action]
                }
            }
            observers.append(startObserver)

            let endObserver = engine.addBoundaryObserver(times: [end]) {
                [weak self] in
                self?.host?.contextualActions = []
            }
            observers.append(endObserver)
        }
    }

    func playerDidCleanUp(engine: PlayerEngine) {
        removeObservers()
    }
}
