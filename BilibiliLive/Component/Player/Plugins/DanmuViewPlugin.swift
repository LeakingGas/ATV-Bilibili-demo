//
//  DanmuViewPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
import Combine
import UIKit

protocol DanmuProviderProtocol {
    var observerPlayerTime: Bool { get }
    var onSendTextModel: PassthroughSubject<DanmakuTextCellModel, Never> { get }
    func playerTimeChange(time: TimeInterval)
}

class DanmuViewPlugin: NSObject {
    let danMuView = DanmakuView()

    init(provider: DanmuProviderProtocol) {
        danmuProvider = provider
        super.init()
        provider.onSendTextModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.shoot($0)
            }.store(in: &cancellable)

        Defaults.shared.$showDanmu
            .receive(on: DispatchQueue.main)
            .sink {
                [weak self] in
                self?.danMuView.isHidden = !$0
            }.store(in: &cancellable)
    }

    private let danmuProvider: DanmuProviderProtocol
    private var timeObserver: PlayerTimeObservation?
    private var cancellable = Set<AnyCancellable>()

    private func shoot(_ model: DanmakuCellModel) {
        // 当显示区域小于1时,将底部弹幕转为浮动弹幕
        if danMuView.displayArea < 1, model.type == .bottom {
            if let shootModel = model as? DanmakuTextCellModel {
                shootModel.type = .floating
                danMuView.shoot(danmaku: shootModel)
                return
            }
        }

        danMuView.shoot(danmaku: model)
    }
}

extension DanmuViewPlugin: CommonPlayerPlugin {
    func playerDidChange(engine: PlayerEngine) {
        // 观察者登记在旧内核上，由 PlayerTimeObservation 从它自己的内核上摘掉。
        timeObserver?.cancel()
        timeObserver = nil
        // 清空当前显示的弹幕，准备重新同步
        danMuView.clean()
    }

    func playerWillStart(engine: PlayerEngine) {
        guard danmuProvider.observerPlayerTime else {
            return
        }
        timeObserver?.cancel()
        timeObserver = engine.addPeriodicObserver(interval: 1, queue: DispatchQueue.global()) { [weak self] seconds in
            guard let self else { return }
            if !Defaults.shared.showDanmu { return }
            danmuProvider.playerTimeChange(time: seconds)
        }
    }

    func playerDidCleanUp(engine: PlayerEngine) {
        timeObserver?.cancel()
        timeObserver = nil
    }

    func addViewToPlayerOverlay(container: UIView) {
        container.addSubview(danMuView)
        danMuView.makeConstraintsToBindToSuperview()
        danMuView.setNeedsLayout()
        danMuView.layoutIfNeeded()
        danMuView.paddingTop = 5
        danMuView.trackHeight = 50
        danMuView.displayArea = Settings.danmuArea.percent
        danMuView.recaculateTracks()
    }

    func playerDidStart(engine: PlayerEngine) {
        danMuView.play()
    }

    /// 显示区域立刻生效：按新范围重排轨道，正在飘的清掉重新出。
    private func applyDisplayArea() {
        danMuView.displayArea = Settings.danmuArea.percent
        danMuView.clean()
        danMuView.recaculateTracks()
    }

    func playerDidPause(engine: PlayerEngine) {
        danMuView.pause()
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let danmuImage = UIImage(systemName: "list.bullet.rectangle.fill")
        let danmuImageDisable = UIImage(systemName: "list.bullet.rectangle")
        let danmuAction = UIAction(title: "Show Danmu", image: danMuView.isHidden ? danmuImageDisable : danmuImage) {
            action in
            Defaults.shared.showDanmu.toggle()
            action.image = Defaults.shared.showDanmu ? danmuImage : danmuImageDisable
        }
        let danmuDurationMenu = UIMenu(title: "弹幕展示时长", options: [.displayInline, .singleSelection], children: [4, 6, 8].map { dur in
            UIAction(title: "\(dur) 秒", state: dur == Settings.danmuDuration ? .on : .off) { _ in Settings.danmuDuration = dur }
        })
        let danmuAILevelMenu = UIMenu(title: "弹幕屏蔽等级", options: [.displayInline, .singleSelection], children: [Int32](1...10).map { level in
            UIAction(title: "\(level)", state: level == Settings.danmuAILevel ? .on : .off) { _ in Settings.danmuAILevel = level }
        })
        let danmuAlphaMenu = UIMenu(title: "透明度", options: [.displayInline, .singleSelection], children: DanmuAlpha.allCases.map { alpha in
            UIAction(title: alpha.title, state: alpha == Settings.danmuAlpha ? .on : .off) { _ in Settings.danmuAlpha = alpha }
        })
        // 和设置页「弹幕 → 显示区域」是同一个值；从屏幕顶部算起。
        let danmuAreaMenu = UIMenu(title: "显示区域", options: [.displayInline, .singleSelection], children: [DanmuArea.style_0, .style_75, .style_50, .style_25].map { area in
            UIAction(title: area.title, state: area == Settings.danmuArea ? .on : .off) { [weak self] _ in
                Settings.danmuArea = area
                self?.applyDisplayArea()
            }
        })
        let danmuSettingMenu = UIMenu(title: "弹幕设置", image: UIImage(systemName: "keyboard.badge.ellipsis"),
                                      children: [danmuDurationMenu, danmuAILevelMenu, danmuAlphaMenu, danmuAreaMenu])

        return [danmuAction, danmuSettingMenu]
    }
}
