//
//  PlayerEngine.swift
//  BilibiliLive
//
//  统一底层：插件只和这两个接口打交道，不直接碰 AVPlayer / AVPlayerViewController。
//  - PlayerEngine：播放内核（系统 AVPlayer 或 VLC），负责时间、播放 / 暂停、跳转、时间观察。
//  - PlayerHost：播放界面（系统 AVPlayerViewController 或我们仿照它做的 VLC 界面），
//    负责控制栏按钮、右下角按钮、下滑面板、倍速显示。
//  同一套插件（弹幕、倍速、SponsorBlock、画质、选集、点赞投币……）因此能同时驱动两个播放器。
//

import AVKit
import UIKit

/// 播放器上登记的时间观察；cancel()（或释放）时从登记它的那个播放器上摘掉。
final class PlayerTimeObservation {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let work = onCancel
        onCancel = nil
        work?()
    }

    deinit {
        onCancel?()
    }
}

protocol PlayerEngine: AnyObject {
    /// 当前播放位置（秒）。
    var currentTime: TimeInterval { get }
    /// 总时长（秒），未知时为 0。
    var duration: TimeInterval { get }
    /// 正在播放或正在等数据准备播放（不是被用户暂停）。
    var isPlaying: Bool { get }
    var isMuted: Bool { get set }
    func play()
    func pause()
    func seek(to seconds: TimeInterval, completion: ((Bool) -> Void)?)
    /// 播放中每隔 interval 秒回调一次当前位置。
    func addPeriodicObserver(interval: TimeInterval, queue: DispatchQueue, _ block: @escaping (TimeInterval) -> Void) -> PlayerTimeObservation
    /// 正常播放经过这些时间点时在主线程回调（跳转越过不回调）。
    func addBoundaryObserver(times: [TimeInterval], _ block: @escaping () -> Void) -> PlayerTimeObservation
    /// 系统播放器内核时为对应的 AVPlayer；VLC 为 nil。
    var avPlayer: AVPlayer? { get }
    /// Debug 浮层显示的内核状态。
    var debugText: String { get }
}

extension PlayerEngine {
    func seek(to seconds: TimeInterval) {
        seek(to: seconds, completion: nil)
    }
}

@MainActor
protocol PlayerHost: AnyObject {
    /// 用来弹窗、挂手势、显示提示动画的视图控制器。
    var hostViewController: UIViewController { get }
    /// 画面右下角的按钮（跳过广告等）。
    var contextualActions: [UIAction] { get set }
    /// 下滑面板 / 控制栏上的附加操作（下一条）。
    var infoViewActions: [UIAction] { get set }
    /// 下滑面板的内容页（推荐和评论）。
    var customInfoViewControllers: [UIViewController] { get set }
    /// 底部控制栏的按钮和菜单（点赞、画质、播放设置、弹幕……）。
    var transportBarCustomMenuItems: [UIMenuElement] { get set }
    /// 系统播放器时为 AVPlayerViewController（播放插件把 AVPlayer 装在这里）；VLC 为 nil。
    var avPlayerViewController: AVPlayerViewController? { get }
    /// 应用播放速度（含界面上的倍速显示）。
    func applyPlaybackSpeed(_ speed: PlaySpeed)
    /// 控制栏上的标题、副标题。系统播放器从播放项的元数据里读，这里不用。
    func setDisplayInfo(title: String?, subtitle: String?)
}

extension AVPlayerViewController: PlayerHost {
    var hostViewController: UIViewController { self }
    var avPlayerViewController: AVPlayerViewController? { self }

    func applyPlaybackSpeed(_ speed: PlaySpeed) {
        player?.currentItem?.audioTimePitchAlgorithm = .timeDomain
        selectSpeed(AVPlaybackSpeed(rate: speed.value, localizedName: speed.name))
    }

    func setDisplayInfo(title: String?, subtitle: String?) {}
}

/// 系统播放器内核。
final class AVPlayerEngine: PlayerEngine {
    let player: AVPlayer

    init(player: AVPlayer) {
        self.player = player
    }

    var avPlayer: AVPlayer? { player }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: TimeInterval {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    var isPlaying: Bool {
        player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: TimeInterval, completion: ((Bool) -> Void)?) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            completion?(finished)
        }
    }

    func addPeriodicObserver(interval: TimeInterval, queue: DispatchQueue, _ block: @escaping (TimeInterval) -> Void) -> PlayerTimeObservation {
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: queue) { time in
            block(time.seconds)
        }
        // 观察者只能从添加它的那个播放器上移除，否则 AVFoundation 直接抛异常闪退。
        return PlayerTimeObservation { [weak player] in player?.removeTimeObserver(token) }
    }

    func addBoundaryObserver(times: [TimeInterval], _ block: @escaping () -> Void) -> PlayerTimeObservation {
        let values = times.filter { $0.isFinite && $0 >= 0 }.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        guard !values.isEmpty else { return PlayerTimeObservation {} }
        let token = player.addBoundaryTimeObserver(forTimes: values, queue: .main, using: block)
        return PlayerTimeObservation { [weak player] in player?.removeTimeObserver(token) }
    }

    var debugText: String {
        "time control status: \(player.timeControlStatus.rawValue) \(player.reasonForWaitingToPlay?.rawValue ?? "")\nplayer status:\(player.status.rawValue)"
    }
}

/// 设置里的「播放器」：系统 / VLC / 自动（有杜比视界用系统，否则 VLC）。
enum PlayerEngineChoice: String, Codable, CaseIterable {
    case system
    case vlc
    case auto

    var title: String {
        switch self {
        case .system: return "系统播放器"
        case .vlc: return "VLC"
        case .auto: return "自动（杜比视界用系统，其余 VLC）"
        }
    }
}

/// 实际使用的播放内核。
enum PlayerEngineKind {
    case system
    case vlc
}
