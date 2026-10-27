//
//  VLCPlayerSurfaceViews.swift
//  BilibiliLive
//
//  VLC 播放界面的各个零件，外观照着系统播放器（AVPlayerViewController）做：
//  进度条、圆形毛玻璃按钮、按钮弹出的菜单、「推荐和评论」胶囊、拖动预览图。
//

import AVFoundation
import SnapKit
import UIKit

// MARK: - 时间格式

enum VLCTimeFormat {
    static func string(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - 执行 UIAction

enum VLCActionRunner {
    /// UIAction 的处理闭包不能直接调用；挂到一个按钮上再触发，和系统菜单点选的效果一样。
    static func perform(_ action: UIAction) {
        let trigger = UIButton(type: .custom)
        trigger.addAction(action, for: .primaryActionTriggered)
        trigger.sendActions(for: .primaryActionTriggered)
    }
}

// MARK: - 进度条（可聚焦：拖动、点按、左右键都落在这里）

final class VLCScrubberView: UIView {
    /// 由界面控制器处理的按键（返回键除外，返回键由界面控制器统一处理）。
    var onPress: ((UIPress.PressType) -> Void)?

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled: Set<UIPress.PressType> = [.select, .playPause, .leftArrow, .rightArrow]
        if presses.contains(where: { handled.contains($0.type) }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled: Set<UIPress.PressType> = [.select, .playPause, .leftArrow, .rightArrow]
        if let press = presses.first(where: { handled.contains($0.type) }) {
            onPress?(press.type)
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled: Set<UIPress.PressType> = [.select, .playPause, .leftArrow, .rightArrow]
        if presses.contains(where: { handled.contains($0.type) }) { return }
        super.pressesCancelled(presses, with: event)
    }
}

final class VLCProgressBar: UIView {
    private let track = UIView()
    private let fill = UIView()
    private let marker = UIView()
    private var fraction: CGFloat = 0
    var emphasized = false {
        didSet { setNeedsLayout() }
    }

    var showsMarker = false {
        didSet { marker.isHidden = !showsMarker }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        track.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        fill.backgroundColor = .white
        marker.backgroundColor = .white
        marker.layer.cornerRadius = 3
        marker.layer.shadowColor = UIColor.black.cgColor
        marker.layer.shadowOpacity = 0.5
        marker.layer.shadowRadius = 6
        marker.layer.shadowOffset = .zero
        marker.isHidden = true
        addSubview(track)
        track.addSubview(fill)
        addSubview(marker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(fraction: Double) {
        self.fraction = CGFloat(max(0, min(1, fraction.isFinite ? fraction : 0)))
        setNeedsLayout()
    }

    /// 播放头在本视图里的横坐标。
    var markerX: CGFloat { bounds.width * fraction }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height: CGFloat = emphasized ? 12 : 8
        track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        track.layer.cornerRadius = height / 2
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * fraction, height: height)
        fill.layer.cornerRadius = height / 2
        marker.frame = CGRect(x: markerX - 3, y: bounds.height / 2 - 18, width: 6, height: 36)
    }
}

// MARK: - 控制栏上的圆形毛玻璃按钮

final class VLCBarButton: UIButton {
    let element: UIMenuElement
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let icon = UIImageView()
    private let textLabel = UILabel()

    var titleText: String {
        (element as? UIAction)?.title ?? (element as? UIMenu)?.title ?? ""
    }

    init(element: UIMenuElement) {
        self.element = element
        super.init(frame: .zero)
        blur.isUserInteractionEnabled = false
        blur.clipsToBounds = true
        addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .white
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        icon.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(34)
        }
        textLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        textLabel.textColor = .white
        textLabel.textAlignment = .center
        textLabel.isUserInteractionEnabled = false
        addSubview(textLabel)
        textLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(22)
        }
        accessibilityLabel = titleText
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var image: UIImage? {
        (element as? UIAction)?.image ?? (element as? UIMenu)?.image
    }

    /// 有图标的是圆形按钮；没有图标的（例如「下一条」以外的纯文字操作）是胶囊按钮。
    var isCircle: Bool { image != nil }

    func refresh() {
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        icon.image = image?.withConfiguration(config)
        icon.isHidden = image == nil
        textLabel.text = image == nil ? titleText : nil
        accessibilityLabel = titleText
        applyFocusStyle(focused: isFocused)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        blur.layer.cornerRadius = bounds.height / 2
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.applyFocusStyle(focused: self.isFocused)
        }
    }

    private func applyFocusStyle(focused: Bool) {
        transform = focused ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
        backgroundColor = focused ? .white : .clear
        blur.alpha = focused ? 0 : 1
        icon.tintColor = focused ? .black : .white
        textLabel.textColor = focused ? .black : .white
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = focused ? 0.35 : 0
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 8)
    }
}

// MARK: - 胶囊（推荐和评论 / 右下角操作）

final class VLCCapsuleButton: UIButton {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let label = UILabel()
    var onFocus: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        blur.isUserInteractionEnabled = false
        blur.clipsToBounds = true
        addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        label.text = title
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        label.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(30)
        }
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var title: String {
        get { label.text ?? "" }
        set { label.text = newValue; accessibilityLabel = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        blur.layer.cornerRadius = bounds.height / 2
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.backgroundColor = focused ? .white : .clear
            self.blur.alpha = focused ? 0 : 1
            self.label.textColor = focused ? .black : .white
        }
        if focused { onFocus?() }
    }
}

// MARK: - 按钮弹出的菜单（照系统菜单：平铺选项、内嵌分组、子菜单）

final class VLCMenuPopover: UIView {
    var onDismiss: (() -> Void)?
    var onPerformed: (() -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let titleLabel = UILabel()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var levels = [UIMenu]()
    private(set) var firstRow: UIView?

    init(menu: UIMenu) {
        super.init(frame: .zero)
        layer.cornerRadius = 28
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 30
        blur.layer.cornerRadius = 28
        blur.clipsToBounds = true
        addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(24)
            make.leading.trailing.equalToSuperview().inset(30)
        }
        scroll.clipsToBounds = false
        addSubview(scroll)
        scroll.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalToSuperview().inset(18)
            make.height.equalTo(100)
        }
        stack.axis = .vertical
        stack.spacing = 6
        scroll.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 4, left: 18, bottom: 4, right: 18))
            make.width.equalTo(scroll).offset(-36)
        }
        push(menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var canGoBack: Bool { levels.count > 1 }

    func goBack() {
        guard levels.count > 1 else { return }
        levels.removeLast()
        rebuild()
    }

    private func push(_ menu: UIMenu) {
        levels.append(menu)
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let menu = levels.last else { return }
        titleLabel.text = menu.title
        firstRow = nil
        append(children: menu.children, depth: 0)
        let rows = CGFloat(stack.arrangedSubviews.count)
        let height = min(640, rows * 76 + 12)
        scroll.snp.updateConstraints { $0.height.equalTo(height) }
        scroll.contentOffset = .zero
        setNeedsFocusUpdate()
    }

    private func append(children: [UIMenuElement], depth: Int) {
        for child in children {
            if let action = child as? UIAction {
                let row = VLCMenuRow(title: action.title, image: action.image, checked: action.state == .on, disclosure: false)
                row.addAction(UIAction { [weak self] _ in
                    VLCActionRunner.perform(action)
                    self?.onPerformed?()
                }, for: .primaryActionTriggered)
                stack.addArrangedSubview(row)
                if firstRow == nil { firstRow = row }
            } else if let menu = child as? UIMenu {
                if menu.options.contains(.displayInline) {
                    if !menu.title.isEmpty {
                        let header = UILabel()
                        header.text = menu.title
                        header.font = .systemFont(ofSize: 22, weight: .semibold)
                        header.textColor = UIColor.white.withAlphaComponent(0.5)
                        let wrapper = UIView()
                        wrapper.addSubview(header)
                        header.snp.makeConstraints { make in
                            make.leading.trailing.equalToSuperview().inset(14)
                            make.top.equalToSuperview().inset(14)
                            make.bottom.equalToSuperview().inset(2)
                        }
                        stack.addArrangedSubview(wrapper)
                    }
                    append(children: menu.children, depth: depth + 1)
                } else {
                    let row = VLCMenuRow(title: menu.title, image: menu.image, checked: false, disclosure: true)
                    row.addAction(UIAction { [weak self] _ in self?.push(menu) }, for: .primaryActionTriggered)
                    stack.addArrangedSubview(row)
                    if firstRow == nil { firstRow = row }
                }
            }
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let checked = stack.arrangedSubviews.first(where: { ($0 as? VLCMenuRow)?.checked == true }) { return [checked] }
        return firstRow.map { [$0] } ?? []
    }
}

final class VLCMenuRow: UIButton {
    let checked: Bool
    private let check = UIImageView(image: UIImage(systemName: "checkmark"))
    private let icon = UIImageView()
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    init(title: String, image: UIImage?, checked: Bool, disclosure: Bool) {
        self.checked = checked
        super.init(frame: .zero)
        layer.cornerRadius = 16
        snp.makeConstraints { $0.height.equalTo(70) }
        check.tintColor = .white
        check.contentMode = .scaleAspectFit
        check.isHidden = !checked
        icon.image = image
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.isHidden = image == nil
        label.text = title
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.textColor = .white
        chevron.tintColor = UIColor.white.withAlphaComponent(0.6)
        chevron.contentMode = .scaleAspectFit
        chevron.isHidden = !disclosure
        for view in [check, icon, label, chevron] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        check.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(18)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(26)
        }
        icon.snp.makeConstraints { make in
            make.leading.equalTo(check.snp.trailing).offset(14)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(image == nil ? 0 : 32)
        }
        label.snp.makeConstraints { make in
            make.leading.equalTo(icon.snp.trailing).offset(image == nil ? 0 : 14)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(chevron.snp.leading).offset(-12)
        }
        chevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(18)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(24)
        }
        accessibilityLabel = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isFocused
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.backgroundColor = focused ? .white : .clear
            let color: UIColor = focused ? .black : .white
            self.label.textColor = color
            self.check.tintColor = color
            self.icon.tintColor = color
            self.chevron.tintColor = focused ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.6)
            self.transform = focused ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
        }
    }
}

// MARK: - 拖动预览图

/// 用码率最低的那条视频流（经本地 BTR 代理）取预览图，和系统播放器的 i-frame 预览一样不占正片带宽。
final class VLCThumbnailProvider {
    private let generator: AVAssetImageGenerator
    private var cache = [Int: UIImage]()
    private var pending: Int?
    private let bucket: Double = 5

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
        pending = nil
    }

    /// 回调在主线程；同一时间只取一张，新的请求取消旧的。
    func image(at seconds: Double, completion: @escaping (UIImage?) -> Void) {
        let key = Int(max(0, seconds) / bucket)
        if let cached = cache[key] { completion(cached); return }
        guard pending != key else { return }
        generator.cancelAllCGImageGeneration()
        pending = key
        let time = CMTime(seconds: Double(key) * bucket + bucket / 2, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, cgImage, _, result, _ in
            let image = (result == .succeeded ? cgImage : nil).map { UIImage(cgImage: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.pending == key { self.pending = nil }
                if let image {
                    self.cache[key] = image
                    if self.cache.count > 200 { self.cache.removeAll() }
                }
                completion(image)
            }
        }
    }
}
