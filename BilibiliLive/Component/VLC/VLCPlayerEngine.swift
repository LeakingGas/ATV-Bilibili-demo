//
//  VLCPlayerEngine.swift
//  BilibiliLive
//
//  VLC 内核：把 VLCMediaPlayer 包成统一的 PlayerEngine，并把它的状态变化翻译成
//  和系统播放器一样的几个事件（准备好、开始播放、暂停、结束、出错）。
//

import AVFoundation
import TVVLCKit
import UIKit

protocol VLCPlayerEngineDelegate: AnyObject {
    /// 第一次能播（相当于 AVPlayerItem.readyToPlay）。
    func vlcEngineDidBecomeReady(_ engine: VLCPlayerEngine)
    func vlcEngineDidStart(_ engine: VLCPlayerEngine)
    func vlcEngineDidPause(_ engine: VLCPlayerEngine)
    func vlcEngineDidEnd(_ engine: VLCPlayerEngine)
    func vlcEngineDidFail(_ engine: VLCPlayerEngine)
    /// 缓冲状态变化（显示 / 隐藏加载圈）。
    func vlcEngine(_ engine: VLCPlayerEngine, isBuffering: Bool)
}

final class VLCPlayerEngine: NSObject, PlayerEngine {
    let player = VLCMediaPlayer()
    weak var delegate: VLCPlayerEngineDelegate?

    /// 已知的总时长（秒）；VLC 拿到之前用播放地址里的时长。
    var knownDuration: TimeInterval = 0
    private(set) var isReady = false
    private var isEnded = false
    private var wantsPlay = false
    private var markedPlaying = false
    private var lastTimeMs: Int32 = 0
    private var lastTimeChangeAt = Date.distantPast
    private var observers = [UUID: Observer]()
    private var pollTimer: Timer?
    /// 跳转后 VLC 的时间要过一会儿才更新，这段时间里按目标位置报告，进度条不会跳回去。
    private var pendingSeek: (target: TimeInterval, at: Date)?

    private final class Observer {
        let interval: TimeInterval
        let queue: DispatchQueue
        let periodic: ((TimeInterval) -> Void)?
        let times: [TimeInterval]
        let boundary: (() -> Void)?
        var lastFired: Date = .distantPast
        var lastTime: TimeInterval = -1
        init(interval: TimeInterval, queue: DispatchQueue, periodic: ((TimeInterval) -> Void)?, times: [TimeInterval], boundary: (() -> Void)?) {
            self.interval = interval; self.queue = queue; self.periodic = periodic; self.times = times; self.boundary = boundary
        }
    }

    override init() {
        super.init()
        player.delegate = self
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// 停止并释放内核（退出播放器 / 换内核时调用）。
    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        observers.removeAll()
        player.delegate = nil
        player.stop()
        player.media = nil
    }

    /// 装上新的媒体（起播、切画质、回前台重载都走这里）。
    func load(media: VLCMedia, autoplay: Bool) {
        isReady = false
        isEnded = false
        wantsPlay = autoplay
        pendingSeek = nil
        lastTimeMs = 0
        markedPlaying = false
        player.media = media
        player.play()
    }

    // MARK: PlayerEngine

    var avPlayer: AVPlayer? { nil }

    var currentTime: TimeInterval {
        if let pendingSeek, Date().timeIntervalSince(pendingSeek.at) < 1.5 { return pendingSeek.target }
        return max(0, Double(player.time.intValue) / 1000)
    }

    var duration: TimeInterval {
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        return length > 0 ? length : knownDuration
    }

    var isPlaying: Bool {
        wantsPlay && !isEnded
    }

    var isMuted: Bool = false {
        didSet {
            if let audio = player.audio as VLCAudio? { audio.isMuted = isMuted }
        }
    }

    var playbackRate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    func play() {
        wantsPlay = true
        if isEnded {
            isEnded = false
            player.stop()
            player.play()
            return
        }
        player.play()
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func seek(to seconds: TimeInterval, completion: ((Bool) -> Void)?) {
        let total = duration
        let target = max(0, total > 1 ? min(seconds, total - 0.5) : seconds)
        pendingSeek = (target, Date())
        if isEnded {
            isEnded = false
            player.play()
        }
        player.time = VLCTime(int: Int32(target * 1000))
        for observer in observers.values { observer.lastTime = target }
        completion?(true)
    }

    func addPeriodicObserver(interval: TimeInterval, queue: DispatchQueue, _ block: @escaping (TimeInterval) -> Void) -> PlayerTimeObservation {
        addObserver(Observer(interval: interval, queue: queue, periodic: block, times: [], boundary: nil))
    }

    func addBoundaryObserver(times: [TimeInterval], _ block: @escaping () -> Void) -> PlayerTimeObservation {
        addObserver(Observer(interval: 0, queue: .main, periodic: nil, times: times.filter { $0.isFinite && $0 >= 0 }, boundary: block))
    }

    private func addObserver(_ observer: Observer) -> PlayerTimeObservation {
        let id = UUID()
        observer.lastTime = currentTime
        observers[id] = observer
        return PlayerTimeObservation { [weak self] in
            if Thread.isMainThread {
                self?.observers[id] = nil
            } else {
                DispatchQueue.main.async { self?.observers[id] = nil }
            }
        }
    }

    var debugText: String {
        let names: [VLCMediaPlayerState: String] = [.stopped: "stopped", .opening: "opening", .buffering: "buffering",
                                                    .ended: "ended", .error: "error", .playing: "playing", .paused: "paused"]
        return "VLC state: \(names[player.state] ?? "\(player.state.rawValue)") playing:\(player.isPlaying) rate:\(player.rate)\nvideo:\(Int(player.videoSize.width))x\(Int(player.videoSize.height))"
    }

    // MARK: 时间观察

    private func poll() {
        let now = Date()
        let time = currentTime
        let advancing = player.isPlaying
        if let pendingSeek, now.timeIntervalSince(pendingSeek.at) >= 1.5 { self.pendingSeek = nil }
        for observer in observers.values {
            if let periodic = observer.periodic {
                guard advancing || abs(time - observer.lastTime) > 0.5 else { continue }
                guard now.timeIntervalSince(observer.lastFired) >= observer.interval else { continue }
                observer.lastFired = now
                observer.lastTime = time
                observer.queue.async { periodic(time) }
            } else if let boundary = observer.boundary {
                let previous = observer.lastTime
                observer.lastTime = time
                // 只在正常播放经过时触发（跳转越过不算），和 AVPlayer 的边界观察一致。
                guard advancing, time > previous, time - previous < 1.0 else { continue }
                if observer.times.contains(where: { $0 > previous && $0 <= time }) {
                    boundary()
                }
            }
        }
    }
}

extension VLCPlayerEngine: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = player.state
        let names: [VLCMediaPlayerState: String] = [.stopped: "stopped", .opening: "opening", .buffering: "buffering",
                                                    .ended: "ended", .error: "error", .playing: "playing", .paused: "paused"]
        Diag.startupStep("vlc_state", ["state": names[state] ?? "\(state.rawValue)", "time": currentTime])
        switch state {
        case .playing:
            delegate?.vlcEngine(self, isBuffering: false)
            if !isReady {
                isReady = true
                delegate?.vlcEngineDidBecomeReady(self)
            }
            delegate?.vlcEngineDidStart(self)
        case .paused:
            delegate?.vlcEngineDidPause(self)
        case .buffering:
            if wantsPlay, !player.isPlaying { delegate?.vlcEngine(self, isBuffering: true) }
        case .ended:
            isEnded = true
            delegate?.vlcEngineDidEnd(self)
        case .error:
            delegate?.vlcEngineDidFail(self)
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let ms = player.time.intValue
        if ms != lastTimeMs {
            lastTimeMs = ms
            lastTimeChangeAt = Date()
            pendingSeek = nil
            delegate?.vlcEngine(self, isBuffering: false)
            if !markedPlaying, ms > 0 {
                markedPlaying = true
                Diag.startupStep("startup_mark", ["mark": "playing", "kind": "VLC"])
            }
        }
    }
}
