//
//  ClickpadRotationTracker.swift
//  BilibiliLive
//
//  Siri Remote（第二代起）触控板外圈转圈：顺时针 = 下一项，逆时针 = 上一项。
//  通过 GameController 读取触控板绝对坐标识别转圈；只观察触摸，不拦截任何事件。
//  目前只用于最外层侧边栏菜单。
//

import GameController
import UIKit
import UIKit.UIGestureRecognizerSubclass

protocol ClickpadRotationHandling: AnyObject {
    /// step: +1 顺时针（向下），-1 逆时针（向上）。返回 true 表示已处理。
    func handleRotationStep(_ step: Int) -> Bool
}

final class ClickpadRotationTracker {
    static let shared = ClickpadRotationTracker()

    private(set) var isRotating = false
    private var lastSampleAt = 0.0

    /// 是否应屏蔽系统自身的焦点移动：只在手指确实正沿外圈转动、且坐标在持续更新时为真。
    /// 带新鲜度检查——之前状态偶尔卡在「转圈中」，导致左右键失灵，要按好几下才恢复。
    var suppressesFocusEngine: Bool {
        guard touching, startedOnRing, ProcessInfo.processInfo.systemUptime - lastSampleAt < 0.3 else { return false }
        return isRotating || abs(accumulated) > 0.15
    }

    private let handlers = NSHashTable<AnyObject>.weakObjects()
    private var lastAngle: Double?
    private var accumulated = 0.0
    private var touching = false
    private var decided = false
    private var startedOnRing = false
    private weak var observedWindow: UIWindow?
    private let ringRadius = 0.55
    private let startThreshold = 0.45
    private let stepAngle = 1.1

    private init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachControllers()
        }
        attachControllers()
    }

    func register(_ handler: ClickpadRotationHandling) {
        handlers.add(handler)
    }

    func installTouchObserver(on window: UIWindow?) {
        guard let window, observedWindow !== window else { return }
        observedWindow = window
        let observer = TouchPresenceGestureRecognizer()
        observer.onBegan = { [weak self] in self?.touchBegan() }
        observer.onEnded = { [weak self] in self?.touchEnded() }
        window.addGestureRecognizer(observer)
    }

    private func attachControllers() {
        for controller in GCController.controllers() {
            guard let pad = controller.microGamepad else { continue }
            pad.reportsAbsoluteDpadValues = true
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                DispatchQueue.main.async { self?.update(x: Double(x), y: Double(y)) }
            }
        }
    }

    private func reset() {
        decided = false; startedOnRing = false; isRotating = false
        lastAngle = nil; accumulated = 0
    }

    private func touchBegan() {
        touching = true
        reset()
    }

    private func touchEnded() {
        touching = false
        reset()
    }

    private func update(x: Double, y: Double) {
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        let radius = hypot(x, y)
        if radius < 0.001 { reset(); return }
        // 没有触摸观察者时（极少见）退化为：有坐标即视为按住。
        if observedWindow == nil { touching = true }
        guard touching else { return }
        if !decided {
            decided = true
            startedOnRing = radius >= ringRadius
        }
        guard startedOnRing, radius >= ringRadius * 0.8 else {
            // 划过中间：这次触摸按普通滑动处理
            startedOnRing = false; isRotating = false; lastAngle = nil; accumulated = 0
            return
        }
        let angle = atan2(y, x)
        defer { lastAngle = angle }
        guard let last = lastAngle else { return }
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        accumulated += delta
        if !isRotating, abs(accumulated) > startThreshold { isRotating = true }
        guard isRotating else { return }
        // y 轴向上为正：顺时针时角度减小。
        while accumulated <= -stepAngle { accumulated += stepAngle; step(+1) }
        while accumulated >= stepAngle { accumulated -= stepAngle; step(-1) }
    }

    private func step(_ value: Int) {
        for handler in handlers.allObjects.compactMap({ $0 as? ClickpadRotationHandling }) where handler.handleRotationStep(value) { return }
    }
}

/// 只观察触控板触摸的开始 / 结束，从不识别、不拦截任何事件。
final class TouchPresenceGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onBegan?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onEnded?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onEnded?()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

