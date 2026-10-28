//
//  VideoPlayListPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/26.
//

import AVKit

class VideoPlayListPlugin: NSObject, CommonPlayerPlugin {
    private let nextActionIdentifierPrefix = "play.next"
    private weak var host: PlayerHost?
    var onPlayEnd: (() -> Void)?
    var onPlayNextWithInfo: ((PlayInfo) -> Void)?

    let sequenceProvider: VideoSequenceProvider?

    init(sequenceProvider: VideoSequenceProvider?) {
        self.sequenceProvider = sequenceProvider
    }

    func playerDidLoad(host: PlayerHost) {
        self.host = host
    }

    func playerWillStart(engine: PlayerEngine) {
        guard let playerVC = host, let sequenceProvider else { return }
        let menuState = MainActor.assumeIsolated { () -> (PlayInfo?, PlayInfo?) in
            guard sequenceProvider.count > 0 else { return (nil, nil) }
            return (sequenceProvider.peekPrevious(), sequenceProvider.peekNext())
        }
        let next = menuState.1
        var actions = playerVC.infoActions.filter {
            !$0.identifier.rawValue.hasPrefix(nextActionIdentifierPrefix)
        }

        if let next {
            let nextAction = UIAction(title: "下一条",
                                      image: UIImage(systemName: "forward.end.fill"),
                                      identifier: .init(rawValue: "\(nextActionIdentifierPrefix).\(next.sequenceKey)"))
            { [weak self] _ in
                Task { [weak self] in
                    _ = await self?.playNext()
                }
            }
            actions.append(nextAction)
        }

        playerVC.infoActions = actions
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let loopImage = UIImage(systemName: "infinity")
        let loopAction = UIAction(title: "循环播放", image: loopImage, state: Settings.loopPlay ? .on : .off) {
            action in
            action.state = (action.state == .off) ? .on : .off
            Settings.loopPlay = action.state == .on
        }
        let actions = [UIMenuElement](arrayLiteral: loopAction)

        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") })
        {
            var child = setting.children
            child.append(contentsOf: actions)
            if let index = current.firstIndex(of: setting) {
                current[index] = setting.replacingChildren(child)
            }
            return []
        }
        return actions
    }

    func playerDidEnd(engine: PlayerEngine) {
        Task { [weak self] in
            guard let self else { return }
            if !(await playNext()) {
                if Settings.loopPlay {
                    await MainActor.run {
                        self.sequenceProvider?.reset()
                    }
                    if !(await playNext()) {
                        await MainActor.run {
                            engine.seek(to: 0)
                            engine.play()
                        }
                    }
                    return
                }
                await MainActor.run { [weak self] in
                    self?.onPlayEnd?()
                }
            }
        }
    }

    @discardableResult
    private func playNext() async -> Bool {
        if let next = await sequenceProvider?.moveNext() {
            await MainActor.run { [weak self] in
                self?.onPlayNextWithInfo?(next)
            }
            return true
        }
        return false
    }
}
