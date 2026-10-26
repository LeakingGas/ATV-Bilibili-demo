//
//  ResumePromptViewController.swift
//  BilibiliLive
//
//  进入视频时有观看记录：询问「继续播放」还是「从头播放」。
//  风格与侧边栏一致：模糊的视频封面铺底 + 深色毛玻璃，左侧文字和按钮，右侧封面卡片。
//

import Kingfisher
import SnapKit
import UIKit

final class ResumePromptViewController: UIViewController {
    private let prompt: ResumePrompt
    private var completion: ((ResumeChoice) -> Void)?

    private let backdrop = UIImageView()
    private let cover = UIImageView()
    private let coverCard = UIView()
    private lazy var resumeButton = ResumeChoiceButton(symbol: "play.fill", title: "继续播放")
    private lazy var restartButton = ResumeChoiceButton(symbol: "arrow.counterclockwise", title: "从头播放")

    init(prompt: ResumePrompt, completion: @escaping (ResumeChoice) -> Void) {
        self.prompt = prompt
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // 被其它流程关掉时也要把结果交回去，否则加载会一直等。
        completion?(.cancel)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [resumeButton]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        view.addSubview(backdrop)
        backdrop.snp.makeConstraints { $0.edges.equalToSuperview() }

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        view.addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }

        let shade = ResumeGradientView(colors: [UIColor.black.withAlphaComponent(0.15), UIColor.black.withAlphaComponent(0.55)])
        view.addSubview(shade)
        shade.snp.makeConstraints { $0.edges.equalToSuperview() }

        // 右侧封面卡片
        coverCard.layer.shadowColor = UIColor.black.cgColor
        coverCard.layer.shadowOpacity = 0.45
        coverCard.layer.shadowRadius = 40
        coverCard.layer.shadowOffset = CGSize(width: 0, height: 24)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 28
        cover.layer.cornerCurve = .continuous
        cover.layer.borderWidth = 1
        cover.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        cover.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        coverCard.addSubview(cover)
        cover.snp.makeConstraints { $0.edges.equalToSuperview() }
        view.addSubview(coverCard)
        coverCard.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(140)
            make.centerY.equalToSuperview()
            make.width.equalTo(720)
            make.height.equalTo(coverCard.snp.width).multipliedBy(9.0 / 16.0)
        }

        // 左侧文字
        let caption = UILabel()
        caption.text = "继续观看"
        caption.font = .systemFont(ofSize: 26, weight: .semibold)
        caption.textColor = UIColor.white.withAlphaComponent(0.55)

        let titleLabel = UILabel()
        titleLabel.text = prompt.title.isEmpty ? "上次看到这里" : prompt.title
        titleLabel.font = .systemFont(ofSize: 50, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail

        let progress = ResumeProgressBar()
        progress.fraction = prompt.duration > 0 ? CGFloat(prompt.position) / CGFloat(prompt.duration) : 0
        progress.snp.makeConstraints { make in
            make.width.equalTo(460)
            make.height.equalTo(8)
        }

        let timeLabel = UILabel()
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        let watched = Self.format(prompt.position)
        if prompt.duration > 0 {
            let left = max(0, prompt.duration - prompt.position)
            timeLabel.text = "看到 \(watched) · 剩余 \(Self.format(left))"
        } else {
            timeLabel.text = "看到 \(watched)"
        }

        let progressRow = UIStackView(arrangedSubviews: [progress, timeLabel])
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.spacing = 24

        resumeButton.subtitle = watched
        resumeButton.addTarget(self, action: #selector(resumeTapped), for: .primaryActionTriggered)
        restartButton.addTarget(self, action: #selector(restartTapped), for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [resumeButton, restartButton])
        buttons.axis = .horizontal
        buttons.spacing = 28

        let column = UIStackView(arrangedSubviews: [caption, titleLabel, progressRow, buttons])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.setCustomSpacing(10, after: caption)
        column.setCustomSpacing(30, after: titleLabel)
        column.setCustomSpacing(56, after: progressRow)
        view.addSubview(column)
        column.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(140)
            make.trailing.lessThanOrEqualTo(coverCard.snp.leading).offset(-80)
            make.centerY.equalToSuperview()
        }

        if let url = prompt.cover {
            cover.kf.setImage(with: url, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 1440, height: 810))), .transition(.fade(0.25))])
            backdrop.kf.setImage(with: url, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 480, height: 270))), .transition(.fade(0.25))])
        }
    }

    // MARK: Actions

    @objc private func resumeTapped() {
        finish(.resume)
    }

    @objc private func restartTapped() {
        finish(.restart)
    }

    private func finish(_ choice: ResumeChoice) {
        guard let completion else { return }
        self.completion = nil
        if choice == .cancel {
            // 返回：连同播放器一起退出，弹窗不单独做动画。
            dismiss(animated: false) { completion(.cancel) }
        } else {
            // 先开始加载，再淡出弹窗，起播更快。
            completion(choice)
            dismiss(animated: true)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            finish(.cancel)
            return
        }
        super.pressesEnded(presses, with: event)
    }

    private static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - 按钮：未聚焦是毛玻璃胶囊，聚焦变白底黑字并放大（tvOS 系统按钮的观感）

final class ResumeChoiceButton: UIControl {
    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        }
    }

    private let glass = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let fill = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: 14)

        for layerView in [glass, fill] {
            layerView.isUserInteractionEnabled = false
            layerView.layer.cornerRadius = 40
            layerView.layer.cornerCurve = .continuous
            layerView.clipsToBounds = true
            addSubview(layerView)
            layerView.snp.makeConstraints { $0.edges.equalToSuperview() }
        }
        glass.layer.borderWidth = 1
        glass.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        fill.backgroundColor = .white
        fill.alpha = 0

        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold))
        icon.contentMode = .scaleAspectFit
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        subtitleLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, subtitleLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(12, after: titleLabel)
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(44)
            make.trailing.equalToSuperview().inset(48)
            make.centerY.equalToSuperview()
        }
        snp.makeConstraints { make in
            make.height.equalTo(80)
            make.width.greaterThanOrEqualTo(260)
        }
        applyColors(focused: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    private func applyColors(focused: Bool) {
        let tint: UIColor = focused ? UIColor(white: 0.08, alpha: 1) : .white
        icon.tintColor = tint
        titleLabel.textColor = tint
        subtitleLabel.textColor = focused ? UIColor(white: 0.08, alpha: 0.55) : UIColor.white.withAlphaComponent(0.6)
        fill.alpha = focused ? 1 : 0
        layer.shadowOpacity = focused ? 0.35 : 0
        transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations {
            self.applyColors(focused: focused)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else {
            super.pressesBegan(presses, with: event)
            return
        }
        UIView.animate(withDuration: 0.12) { self.transform = CGAffineTransform(scaleX: 1.02, y: 1.02) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else {
            super.pressesCancelled(presses, with: event)
            return
        }
        UIView.animate(withDuration: 0.12) { self.applyColors(focused: self.isFocused) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .select }) else {
            super.pressesEnded(presses, with: event)
            return
        }
        UIView.animate(withDuration: 0.12) { self.applyColors(focused: self.isFocused) }
        sendActions(for: .primaryActionTriggered)
    }
}

// MARK: - 小部件

private final class ResumeProgressBar: UIView {
    var fraction: CGFloat = 0 { didSet { setNeedsLayout() } }
    private let bar = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.22)
        layer.cornerRadius = 4
        clipsToBounds = true
        bar.backgroundColor = .white
        bar.layer.cornerRadius = 4
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let clamped = min(1, max(0.02, fraction))
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
    }
}

private final class ResumeGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(colors: [UIColor]) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
