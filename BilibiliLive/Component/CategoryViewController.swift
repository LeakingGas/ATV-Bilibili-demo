//
//  CategoryViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2023/2/26.
//
//  左侧分类 + 右侧内容（排行 / 直播 / 收藏等共用）。
//  焦点移到哪个分类，右侧立即显示它的内容（各分类后台预加载），按右键进入内容。
//  分类栏与主菜单侧边栏同一风格：毛玻璃圆角面板、白底黑字焦点、淡白当前项。
//

import Foundation
import SnapKit
import UIKit

class CategoryViewController: UIViewController, BLTabBarContentVCProtocol {
    struct CategoryDisplayModel {
        let title: String
        let contentVC: UIViewController
        var autoSelect: Bool? = true
    }

    var typeCollectionView: UICollectionView!
    var categories = [CategoryDisplayModel]()
    let contentView = UIView()
    weak var currentViewController: UIViewController?
    private var selectedIndex = 0
    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))

    override func viewDidLoad() {
        super.viewDidLoad()
        if categories.isEmpty {
        } else {
            initTypeCollectionView()
        }
    }

    func initTypeCollectionView() {
        if typeCollectionView != nil {
            return
        }
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(58))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 6
        section.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 14, bottom: 18, trailing: 14)
        typeCollectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        typeCollectionView.backgroundColor = .clear
        typeCollectionView.clipsToBounds = false
        typeCollectionView.remembersLastFocusedIndexPath = true
        typeCollectionView.register(BLCategoryRowCell.self, forCellWithReuseIdentifier: "cell")

        panel.layer.cornerRadius = 32
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        view.addSubview(panel)
        panel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(56)
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(8)
            make.bottom.equalToSuperview().inset(48)
            make.width.equalTo(330)
        }
        panel.contentView.addSubview(typeCollectionView)
        typeCollectionView.snp.makeConstraints { $0.edges.equalToSuperview() }
        typeCollectionView.dataSource = self
        typeCollectionView.delegate = self

        view.addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.bottom.right.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.left.equalTo(panel.snp.right).offset(24)
        }
        show(index: 0)
        preloadCategories()
    }

    /// 后台依次加载各分类页面和数据，焦点切过去时内容已就绪。
    private func preloadCategories() {
        for (offset, model) in categories.enumerated() where offset != selectedIndex {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(offset) * 0.12) { [weak self, weak vc = model.contentVC] in
                guard let self, let vc, !vc.isViewLoaded else { return }
                vc.loadViewIfNeeded()
                vc.view.frame = self.contentView.bounds.isEmpty ? self.view.bounds : self.contentView.bounds
                vc.view.layoutIfNeeded()
            }
        }
    }

    private func show(index: Int) {
        guard categories.indices.contains(index) else { return }
        selectedIndex = index
        let vc = categories[index].contentVC
        if currentViewController !== vc { setViewController(vc: vc) }
        for cell in typeCollectionView.visibleCells {
            if let row = cell as? BLCategoryRowCell, let path = typeCollectionView.indexPath(for: cell) {
                row.isCurrent = path.item == selectedIndex
            }
        }
    }

    func setViewController(vc: UIViewController) {
        currentViewController?.willMove(toParent: nil)
        currentViewController?.view.removeFromSuperview()
        currentViewController?.removeFromParent()
        currentViewController = vc
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.view.makeConstraintsToBindToSuperview()
        vc.didMove(toParent: self)
    }

    func reloadData() {
        (currentViewController as? BLTabBarContentVCProtocol)?.reloadData()
    }

    // MARK: - 返回键：焦点在右侧内容时先回到左侧当前分类

    private var forcedCategory: IndexPath?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let forcedCategory, let cell = typeCollectionView?.cellForItem(at: forcedCategory) { return [cell] }
        return super.preferredFocusEnvironments
    }
}

extension CategoryViewController: BLMenuPressHandling {
    func handleMenuPress() -> Bool {
        guard typeCollectionView != nil, let focused = UIScreen.main.focusedView, focused.isDescendant(of: contentView) else { return false }
        let path = IndexPath(item: selectedIndex, section: 0)
        typeCollectionView.scrollToItem(at: path, at: .centeredVertically, animated: true)
        typeCollectionView.layoutIfNeeded()
        forcedCategory = path
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        forcedCategory = nil
        return true
    }
}

extension CategoryViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return categories.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! BLCategoryRowCell
        cell.titleLabel.text = categories[indexPath.item].title
        cell.isCurrent = indexPath.item == selectedIndex
        return cell
    }
}

extension CategoryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        show(index: indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        guard let next = context.nextFocusedIndexPath, categories.indices.contains(next.item),
              categories[next.item].autoSelect != false else { return }
        show(index: next.item)
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        IndexPath(item: selectedIndex, section: 0)
    }
}

/// 与主菜单侧边栏一致的分类行：焦点白底黑字，当前项淡白底。
final class BLCategoryRowCell: UICollectionViewCell {
    let titleLabel = UILabel()
    private let background = UIView()

    var isCurrent = false {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 24
        background.layer.cornerCurve = .continuous
        contentView.addSubview(background)
        background.snp.makeConstraints { $0.edges.equalToSuperview() }
        titleLabel.font = .systemFont(ofSize: 25, weight: .medium)
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        background.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(24)
            make.centerY.equalToSuperview()
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.updateAppearance() }
    }

    private func updateAppearance() {
        background.backgroundColor = isFocused ? .white : isCurrent ? UIColor.white.withAlphaComponent(0.16) : .clear
        titleLabel.textColor = isFocused ? .black : isCurrent ? .white : UIColor.white.withAlphaComponent(0.72)
        transform = isFocused ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = isFocused ? 0.25 : 0
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)
    }
}
