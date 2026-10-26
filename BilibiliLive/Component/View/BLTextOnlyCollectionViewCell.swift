//
//  BLTextOnlyCollectionViewCell.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/10/24.
//

import Foundation
import UIKit

class BLTextOnlyCollectionViewCell: BLMotionCollectionViewCell {
    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let selectedWhiteView = UIView()
    let titleLabel = UILabel()

    override func setup() {
        super.setup()
        scaleFactor = 1.15
        contentView.addSubview(effectView)
        effectView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        effectView.contentView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.centerX.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(20)
            make.top.bottom.lessThanOrEqualToSuperview().inset(8)
        }
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.font = UIFont.systemFont(ofSize: 26, weight: .medium)
        effectView.layer.cornerRadius = 20
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
        // 焦点态：白底黑字（系统按钮风格）。
        selectedWhiteView.backgroundColor = .white
        selectedWhiteView.isHidden = true
        effectView.contentView.insertSubview(selectedWhiteView, at: 0)
        selectedWhiteView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        selectedWhiteView.isHidden = !isFocused
        titleLabel.textColor = isFocused ? .black : .white
    }
}
