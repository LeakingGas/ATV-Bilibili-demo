//
//  VideoComponents.swift
//  BilibiliLive
//
//  Created by yicheng on 2021/4/17.
//

import AVKit
import Combine
import Foundation
import UIKit

import Alamofire
import Kingfisher
import MarqueeLabel
import SnapKit
import TVUIKit


class BLCardView: TVCardView {
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        subviews.first?.subviews.first?.subviews.last?.subviews.first?.subviews.first?.layer.cornerRadius = 12
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cardBackgroundColor = UIColor(named: "bgColor")
    }
}

class RelatedVideoCell: BLMotionCollectionViewCell {
    let titleLabel = MarqueeLabel()
    let imageView = UIImageView()
    override func setup() {
        super.setup()
        contentView.addSubview(imageView)
        contentView.addSubview(titleLabel)
        imageView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.width.equalTo(imageView.snp.height).multipliedBy(14.0 / 9)
        }
        imageView.layer.cornerRadius = 20
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        titleLabel.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview()
            make.top.equalTo(imageView.snp.bottom).offset(6)
        }
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.font = UIFont.systemFont(ofSize: 28)
        titleLabel.fadeLength = 60
        stopScroll()
    }

    func update(data: any DisplayData) {
        titleLabel.text = data.title
        imageView.kf.setImage(with: data.pic, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 360, height: 202))), .cacheOriginalImage])
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if isFocused {
            startScroll()
        } else {
            stopScroll()
        }
    }

    private func startScroll() {
        titleLabel.restartLabel()
        titleLabel.holdScrolling = false
    }

    private func stopScroll() {
        titleLabel.shutdownLabel()
        titleLabel.holdScrolling = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopScroll()
    }
}

class DetailLabel: UILabel {
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            if self.isFocused {
                self.backgroundColor = .white
            } else {
                self.backgroundColor = .clear
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isUserInteractionEnabled = true
    }

    override var canBecomeFocused: Bool {
        return true
    }

    override func drawText(in rect: CGRect) {
        let insets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
        super.drawText(in: rect.inset(by: insets))
    }
}

class NoteDetailView: UIControl {
    let label = UILabel()
    var onPrimaryAction: ((NoteDetailView) -> Void)?
    private let backgroundView = UIView()
    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setup() {
        addSubview(backgroundView)
        backgroundView.backgroundColor = UIColor(named: "bgColor")
        backgroundView.layer.shadowOffset = CGSizeMake(0, 10)
        backgroundView.layer.shadowOpacity = 0.15
        backgroundView.layer.shadowRadius = 16.0
        backgroundView.layer.cornerRadius = 20
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.isHidden = !isFocused
        backgroundView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.left.equalToSuperview().offset(-20)
            make.right.equalToSuperview().offset(20)
        }

        addSubview(label)
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 29)
        label.textColor = UIColor(named: "titleColor")
        label.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(14)
            make.bottom.lessThanOrEqualToSuperview().offset(-14)
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        backgroundView.isHidden = !isFocused
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.first?.type == .select {
            sendActions(for: .primaryActionTriggered)
            onPrimaryAction?(self)
        }
    }
}

class ContentDetailViewController: UIViewController {
    private let titleLabel = UILabel()
    private let contentTextView = UITextView()

    static func createDesp(content: String) -> ContentDetailViewController {
        let vc = ContentDetailViewController()
        vc.titleLabel.text = "简介"
        vc.contentTextView.text = content
        return vc
    }

    static func createReply(content: String) -> ContentDetailViewController {
        let vc = ContentDetailViewController()
        vc.titleLabel.text = "评论"
        vc.contentTextView.text = content
        return vc
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [contentTextView]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(titleLabel)
        view.addSubview(contentTextView)
        titleLabel.font = UIFont.systemFont(ofSize: 60, weight: .semibold)
        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(80)
            make.centerX.equalToSuperview()
        }
        contentTextView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        contentTextView.isScrollEnabled = true
        contentTextView.isUserInteractionEnabled = true
        contentTextView.isSelectable = true
        contentTextView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom)
            make.centerX.equalToSuperview()
            make.leading.equalToSuperview().offset(60)
            make.trailing.equalToSuperview().inset(60)
            make.bottom.equalToSuperview().inset(80)
        }
    }
}
