//
//  TitleSupplementaryView.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/10/21.
//

import SnapKit
import UIKit

class TitleSupplementaryView: UICollectionReusableView {
    let label = UILabel()
    static let reuseIdentifier = "title-supplementary-reuse-identifier"

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }
}

extension TitleSupplementaryView {
    func configure() {
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        label.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.equalToSuperview().offset(20)
            make.trailing.equalToSuperview()
            make.bottom.equalToSuperview()
        }
        // 分区标题：大号粗体、略带透明，Apple TV 风格。
        label.font = UIFont.systemFont(ofSize: 40, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
    }
}
