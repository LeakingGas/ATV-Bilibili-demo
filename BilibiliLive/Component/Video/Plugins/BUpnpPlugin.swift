//
//  BUpnpPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVFoundation
import Foundation

class BUpnpPlugin: NSObject, CommonPlayerPlugin {
    let duration: Int?
    weak var engine: PlayerEngine?
    private var observar: PlayerTimeObservation?

    init(duration: Int?) {
        self.duration = duration
    }

    func pause() {
        engine?.pause()
    }

    func resume() {
        engine?.play()
    }

    func seek(to time: TimeInterval) {
        engine?.seek(to: time)
    }

    func playerWillStart(engine: PlayerEngine) {
        BiliBiliUpnpDMR.shared.currentPlugin = self
        observar?.cancel()
        observar = nil
        self.engine = engine
        guard let duration else { return }
        observar = engine.addPeriodicObserver(interval: 5, queue: .global()) { seconds in
            DispatchQueue.main.async {
                BiliBiliUpnpDMR.shared.sendProgress(duration: duration, current: Int(seconds))
            }
        }
    }

    func playerDidStart(engine: PlayerEngine) {
        DispatchQueue.main.async {
            BiliBiliUpnpDMR.shared.sendStatus(status: .playing)
        }
    }

    func playerDidPause(engine: PlayerEngine) {
        DispatchQueue.main.async {
            BiliBiliUpnpDMR.shared.sendStatus(status: .paused)
        }
    }

    func playerDidEnd(engine: PlayerEngine) {
        DispatchQueue.main.async {
            BiliBiliUpnpDMR.shared.sendStatus(status: .end)
        }
    }

    func playerDidFail(engine: PlayerEngine) {
        DispatchQueue.main.async {
            BiliBiliUpnpDMR.shared.sendStatus(status: .stop)
        }
    }

    func playerDidCleanUp(engine: PlayerEngine) {
        observar?.cancel()
        observar = nil
        DispatchQueue.main.async {
            BiliBiliUpnpDMR.shared.sendStatus(status: .stop)
        }
    }
}
