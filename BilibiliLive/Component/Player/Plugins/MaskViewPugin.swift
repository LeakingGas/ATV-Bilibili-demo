//
//  MaskViewPugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVKit
import UIKit

class MaskViewPugin: NSObject, CommonPlayerPlugin {
    weak var maskView: UIView?
    var maskProvider: MaskProvider
    private var observer: Any?
    private var videoOutput: AVPlayerItemVideoOutput?

    init(maskView: UIView, maskProvider: MaskProvider) {
        self.maskView = maskView
        self.maskProvider = maskProvider
    }

    func playerDidChange(player: AVPlayer) {
        if maskProvider.needVideoOutput() {
            setUpOutput(player: player)
        }

        if let observer, let owner = observedPlayer { owner.removeTimeObserver(observer) }
        observedPlayer = player
        let timePerFrame = CMTime(value: 1, timescale: CMTimeScale(maskProvider.preferFPS()))
        observer = player.addPeriodicTimeObserver(forInterval: timePerFrame, queue: .main) {
            [weak self] time in
            guard let self, let maskView, !maskView.isHidden else { return }
            maskProvider.getMask(for: time, frame: maskView.frame) {
                [weak maskView] maskLayer in
                maskView?.layer.mask = maskLayer
            }
        }
    }

    private weak var observedPlayer: AVPlayer?

    func playerDidCleanUp(player: AVPlayer) {
        if let observer, let owner = observedPlayer {
            owner.removeTimeObserver(observer)
        }
        observer = nil
        observedPlayer = nil
    }

    private func setUpOutput(player: AVPlayer) {
        guard videoOutput == nil, let videoItem = player.currentItem else { return }
        let pixelBuffAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBuffAttributes)
        videoItem.add(videoOutput)
        self.videoOutput = videoOutput
        maskProvider.setVideoOutout(ouput: videoOutput)
    }
}
