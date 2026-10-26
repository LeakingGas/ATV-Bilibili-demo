//
//  FeedCollectionViewCell.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/10/20.
//

import Kingfisher
import TVUIKit
import UIKit

class FeedCollectionViewCell: BLMotionCollectionViewCell {
    var onLongPress: (() -> Void)?
    var styleOverride: FeedDisplayStyle? { didSet { if oldValue != styleOverride { updateStyle() } }}

    // 参考 Apple TV 应用：大圆角封面在上，下方左侧大号序号，右侧标题 / UP主·日期 / 数据。
    private let imageView = UIImageView()
    private let badgeLabel = PaddingLabel()
    private let indexLabel = UILabel()
    private let titleLabel = UILabel()
    private let upLabel = UILabel()
    private let statsLabel = UILabel()
    private var currentData: (any DisplayData)?

    override func setup() {
        super.setup()
        scaleFactor = 1.06
        let longpress = UILongPressGestureRecognizer(target: self, action: #selector(actionLongPress(sender:)))
        addGestureRecognizer(longpress)

        contentView.addSubview(imageView)
        imageView.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.height.equalTo(imageView.snp.width).multipliedBy(9.0 / 16)
        }
        imageView.layer.cornerRadius = 24
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.06)

        badgeLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.layer.cornerRadius = 10
        badgeLabel.layer.cornerCurve = .continuous
        badgeLabel.clipsToBounds = true
        badgeLabel.isHidden = true
        contentView.addSubview(badgeLabel)
        badgeLabel.snp.makeConstraints { make in
            make.top.equalTo(imageView).offset(12)
            make.trailing.equalTo(imageView).inset(12)
        }

        indexLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        indexLabel.setContentHuggingPriority(.required, for: .horizontal)
        indexLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.numberOfLines = 2
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.95)
        upLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        statsLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        [titleLabel, upLabel, statsLabel].forEach {
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let textStack = UIStackView(arrangedSubviews: [titleLabel, upLabel, statsLabel])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.setCustomSpacing(10, after: titleLabel)

        let row = UIStackView(arrangedSubviews: [indexLabel, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 14
        contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.top.equalTo(imageView.snp.bottom).offset(16)
            make.leading.equalToSuperview().offset(4)
            make.trailing.equalToSuperview()
            make.bottom.equalToSuperview().priority(.high)
        }
        updateStyle()
    }

    func setup(data: any DisplayData) {
        setup(data: data, index: nil)
    }

    func setup(data: any DisplayData, index: Int?) {
        currentData = data
        titleLabel.text = data.title
        upLabel.text = [data.ownerName, data.date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        upLabel.isHidden = upLabel.text?.isEmpty ?? true
        if let index {
            indexLabel.text = "\(index)"
            indexLabel.isHidden = false
        } else {
            indexLabel.isHidden = true
        }
        if let badge = data.overlay?.badge {
            badgeLabel.text = badge.text
            badgeLabel.backgroundColor = badge.color ?? .systemPink
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
        if var pic = data.pic {
            if pic.scheme == nil {
                pic = URL(string: "http:\(pic.absoluteString)")!
            }
            imageView.kf.setImage(with: pic, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 640, height: 360))), .cacheOriginalImage, .transition(.fade(0.2))])
        }
        updateStyle()
    }

    /// 播放量 / 弹幕 / 时长等，用 SF Symbols 小图标 + 文字排成一行。
    private func makeStats(_ overlay: DisplayOverlay?, font: UIFont) -> NSAttributedString? {
        guard let overlay else { return nil }
        let items = overlay.leftItems + overlay.rightItems
        guard !items.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        let color = UIColor.white.withAlphaComponent(0.55)
        for (offset, item) in items.enumerated() {
            if offset > 0 { result.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            var suffix = ""
            if let icon = item.icon, let image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(font: font))?.withTintColor(color, renderingMode: .alwaysOriginal) {
                let attachment = NSTextAttachment(image: image)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
                if icon.hasPrefix("play") { suffix = "观看" }
                if icon.hasPrefix("list.bullet") { suffix = "弹幕" }
            }
            result.append(NSAttributedString(string: item.text + suffix, attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }

    private func updateStyle() {
        let style = styleOverride ?? Settings.displayStyle
        titleLabel.font = style.titleFont
        upLabel.font = style.upFont
        indexLabel.font = style.indexFont
        statsLabel.attributedText = makeStats(currentData?.overlay, font: style.upFont)
        statsLabel.isHidden = statsLabel.attributedText == nil
    }

    @objc private func actionLongPress(sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }
        onLongPress?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onLongPress = nil
        imageView.kf.cancelDownloadTask()
        imageView.image = nil
    }
}

/// 带内边距的标签（角标用）。
final class PaddingLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

extension FeedDisplayStyle {
    var fractionalWidth: CGFloat {
        switch self {
        case .large, .sideBar:
            return 0.33
        case .normal:
            return 0.25
        }
    }

    var fractionalHeight: CGFloat {
        switch self {
        case .large:
            return fractionalWidth / 1.5
        case .normal:
            return fractionalWidth / 1.5
        case .sideBar:
            return fractionalWidth / 1.15
        }
    }

    var heightEstimated: CGFloat {
        switch self {
        case .large:
            return 516
        case .normal, .sideBar:
            return 380
        }
    }

    var titleFont: UIFont {
        switch self {
        case .large:
            return UIFont.systemFont(ofSize: 25, weight: .semibold)
        case .normal:
            return UIFont.systemFont(ofSize: 23, weight: .semibold)
        case .sideBar:
            return UIFont.systemFont(ofSize: 21, weight: .semibold)
        }
    }

    var upFont: UIFont {
        switch self {
        case .large:
            return UIFont.systemFont(ofSize: 20, weight: .regular)
        case .normal:
            return UIFont.systemFont(ofSize: 18, weight: .regular)
        case .sideBar:
            return UIFont.systemFont(ofSize: 17, weight: .regular)
        }
    }

    /// 序号：圆体粗字。
    var indexFont: UIFont {
        let size: CGFloat = self == .large ? 58 : self == .normal ? 50 : 44
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
