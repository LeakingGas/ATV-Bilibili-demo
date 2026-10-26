//
//  TabBarCustomizationViewController.swift
//  BilibiliLive
//
//  自定义菜单栏。
//  浏览：方向键正常移动焦点。
//  按确定（或播放键）「拿起」当前项目 → 方向键 / 滑动移动它（左右调顺序，上下换区域），
//  焦点始终跟着被拿起的项目；再按确定、播放或返回键「放下」。
//

import SnapKit
import UIKit

class TabBarCustomizationViewController: UIViewController {
    // MARK: - State

    private static let sectionOrder: [Settings.TabBarPageSection] = [.tabBar, .personal, .hidden]
    private var lists: [[Settings.TabBarPagePlacement]] = [[], [], []]
    private var originalPlacements = [Settings.TabBarPagePlacement]()

    /// 被拿起的项目所在位置；nil = 浏览模式。
    private var picked: IndexPath?
    private var focusedIndexPath: IndexPath?
    /// 下一次强制聚焦的位置（拿起移动后让焦点跟随）。
    private var forcedFocus: IndexPath?

    private var isEditingItem: Bool { picked != nil }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if let forcedFocus, let cell = collectionView.cellForItem(at: forcedFocus) { return [cell] }
        return [collectionView]
    }

    // MARK: - Views

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 26, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.8)
        label.numberOfLines = 2
        return label
    }()

    private let restoreDefaultButton: BLCustomTextButton = {
        let button = BLCustomTextButton()
        button.title = "恢复默认"
        button.titleFont = .systemFont(ofSize: 30, weight: .semibold)
        button.titleColor = UIColor.white
        return button
    }()

    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        cv.remembersLastFocusedIndexPath = false
        cv.dataSource = self
        cv.delegate = self
        cv.clipsToBounds = false
        cv.register(TabBarTileCell.self, forCellWithReuseIdentifier: TabBarTileCell.reuseID)
        cv.register(TabBarSectionHeaderView.self,
                    forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                    withReuseIdentifier: TabBarSectionHeaderView.reuseID)
        return cv
    }()

    private let menuTap = UITapGestureRecognizer()
    private var swipes = [UISwipeGestureRecognizer]()

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(200), heightDimension: .absolute(110))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .continuous
            section.interGroupSpacing = 26
            section.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 0, bottom: 34, trailing: 40)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(50)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自定义菜单栏"
        view.backgroundColor = .black
        setupUI()
        setupGestures()
        reloadPlacementsFromSettings()
        updateHintLabel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isEditingItem { drop() }
        commitIfNeeded()
    }

    // MARK: - Input

    private func setupGestures() {
        // 移动中按返回 = 放下，不退出本页。手势优先于导航控制器的返回。
        menuTap.addTarget(self, action: #selector(handleMenuTap))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuTap.delegate = self
        view.addGestureRecognizer(menuTap)
        // 触控板滑动（不产生方向键按压）在移动中也能移动项目。
        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = self
            swipe.isEnabled = false
            view.addGestureRecognizer(swipe)
            swipes.append(swipe)
        }
    }

    @objc private func handleMenuTap() {
        if isEditingItem { drop() }
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard isEditingItem else { return }
        switch gesture.direction {
        case .left: move(dx: -1, dy: 0)
        case .right: move(dx: 1, dy: 0)
        case .up: move(dx: 0, dy: -1)
        case .down: move(dx: 0, dy: 1)
        default: break
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isEditingItem, let type = presses.first?.type else {
            super.pressesBegan(presses, with: event)
            return
        }
        switch type {
        case .leftArrow: move(dx: -1, dy: 0)
        case .rightArrow: move(dx: 1, dy: 0)
        case .upArrow: move(dx: 0, dy: -1)
        case .downArrow: move(dx: 0, dy: 1)
        case .menu, .select, .playPause: break // handled on release
        default: super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let type = presses.first?.type else {
            super.pressesEnded(presses, with: event)
            return
        }
        switch type {
        case .select, .playPause:
            if isEditingItem { drop() } else { pick() }
        case .menu where isEditingItem:
            drop()
        default:
            let arrows: [UIPress.PressType] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
            if isEditingItem, arrows.contains(type) { return }
            super.pressesEnded(presses, with: event)
        }
    }

    // MARK: - Pick / move / drop

    private func pick() {
        guard let indexPath = focusedIndexPath, placement(at: indexPath) != nil else { return }
        picked = indexPath
        swipes.forEach { $0.isEnabled = true }
        updateHintLabel()
        collectionView.reconfigureItems(at: [indexPath])
    }

    private func drop() {
        let last = picked
        picked = nil
        swipes.forEach { $0.isEnabled = false }
        updateHintLabel()
        commitIfNeeded()
        if let last, collectionView.numberOfSections > last.section, collectionView.numberOfItems(inSection: last.section) > last.item {
            collectionView.reconfigureItems(at: [last])
        }
    }

    private func showAlert(_ title: String) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
        present(alert, animated: true)
    }

    /// dx：同区域内左右挪一格；dy：移到上 / 下一个区域（保持大致相同的横向位置）。
    private func move(dx: Int, dy: Int) {
        guard let from = picked, var item = placement(at: from) else { return }
        var to = from
        if dx != 0 {
            let target = from.item + dx
            guard lists[from.section].indices.contains(target) else { return }
            lists[from.section].swapAt(from.item, target)
            to = IndexPath(item: target, section: from.section)
        } else {
            let targetSection = from.section + dy
            guard Self.sectionOrder.indices.contains(targetSection) else { return }
            if from.section == 0 {
                if item.page.isFixedInTabBar { showAlert("「\(item.page.title)」只能放在菜单栏"); return }
                if lists[0].count <= 3 { showAlert("菜单栏至少保留 3 个页面"); return }
            }
            item.section = Self.sectionOrder[targetSection]
            lists[from.section].remove(at: from.item)
            let insertAt = min(from.item, lists[targetSection].count)
            lists[targetSection].insert(item, at: insertAt)
            to = IndexPath(item: insertAt, section: targetSection)
        }
        picked = to
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: to, at: .centeredHorizontally, animated: false)
        collectionView.layoutIfNeeded()
        focus(on: to)
    }

    private func focus(on indexPath: IndexPath) {
        forcedFocus = indexPath
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        forcedFocus = nil
        focusedIndexPath = indexPath
    }

    // MARK: - UI helpers

    private func setupUI() {
        view.addSubview(hintLabel)
        view.addSubview(restoreDefaultButton)
        view.addSubview(collectionView)
        restoreDefaultButton.addTarget(self, action: #selector(didTapRestoreDefault), for: .primaryActionTriggered)

        hintLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(12)
            make.leading.equalToSuperview().offset(80)
            make.trailing.lessThanOrEqualTo(restoreDefaultButton.snp.leading).offset(-24)
        }

        let focusGuide = UIFocusGuide()
        view.addLayoutGuide(focusGuide)
        NSLayoutConstraint.activate([
            focusGuide.topAnchor.constraint(equalTo: view.topAnchor),
            focusGuide.leftAnchor.constraint(equalTo: view.leftAnchor),
            focusGuide.rightAnchor.constraint(equalTo: view.rightAnchor),
            focusGuide.bottomAnchor.constraint(equalTo: collectionView.topAnchor),
        ])
        focusGuide.preferredFocusEnvironments = [restoreDefaultButton]

        restoreDefaultButton.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(4)
            make.trailing.equalToSuperview().offset(-80)
            make.height.equalTo(72)
        }

        collectionView.snp.makeConstraints { make in
            make.top.equalTo(hintLabel.snp.bottom).offset(12)
            make.top.greaterThanOrEqualTo(restoreDefaultButton.snp.bottom).offset(12)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom)
            make.leading.equalToSuperview().offset(80)
            make.trailing.equalToSuperview().offset(-80)
        }
    }

    private func updateHintLabel() {
        if let picked, let item = placement(at: picked) {
            hintLabel.text = "正在移动「\(item.page.title)」：← → 调整顺序，↑ ↓ 移到其他区域；按确定、播放或返回键放下"
        } else {
            hintLabel.text = "选中项目后按确定键拿起来移动；移到「隐藏」区域的页面将不再显示"
        }
    }

    private func commitIfNeeded() {
        let newPlacement = lists.flatMap { $0 }
        if newPlacement != originalPlacements {
            Settings.setPlacements(newPlacement)
            originalPlacements = newPlacement
        }
    }

    private func reloadPlacementsFromSettings() {
        let placements = Settings.currentPlacements
        lists = Self.sectionOrder.map { section in placements.filter { $0.section == section } }
        originalPlacements = lists.flatMap { $0 }
        collectionView.reloadData()
    }

    @objc
    private func didTapRestoreDefault() {
        if isEditingItem { drop() }
        let placements = Settings.defaultPlacements
        lists = Self.sectionOrder.map { section in placements.filter { $0.section == section } }
        updateHintLabel()
        collectionView.reloadData()
        commitIfNeeded()
    }

    private func placement(at indexPath: IndexPath) -> Settings.TabBarPagePlacement? {
        guard lists.indices.contains(indexPath.section) else { return nil }
        let list = lists[indexPath.section]
        return list.indices.contains(indexPath.item) ? list[indexPath.item] : nil
    }
}

// MARK: - UICollectionViewDataSource

extension TabBarCustomizationViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        Self.sectionOrder.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        // 空区域放一个占位格，便于看清并移入。
        max(1, lists[section].count)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabBarTileCell.reuseID, for: indexPath) as! TabBarTileCell
        if let placement = placement(at: indexPath) {
            cell.configure(title: placement.page.title, isBeingEdited: indexPath == picked)
        } else {
            cell.configure(title: "（空）", isBeingEdited: false)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView
    {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind,
                                                                   withReuseIdentifier: TabBarSectionHeaderView.reuseID,
                                                                   for: indexPath) as! TabBarSectionHeaderView
        view.label.text = Self.sectionOrder[indexPath.section].title
        return view
    }
}

// MARK: - UICollectionViewDelegate

extension TabBarCustomizationViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool
    {
        // 移动中焦点只能由我们移动（跟随被拿起的项目）。
        guard isEditingItem else { return true }
        return forcedFocus != nil && context.nextFocusedIndexPath == forcedFocus
    }

    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator)
    {
        if let next = context.nextFocusedIndexPath { focusedIndexPath = next }
    }
}

extension TabBarCustomizationViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === menuTap { return isEditingItem }
        return isEditingItem
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 导航控制器的返回手势等我们失败后才生效。
        gestureRecognizer === menuTap && otherGestureRecognizer.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue))
    }
}

// MARK: - Tile Cell

class TabBarTileCell: BLMotionCollectionViewCell {
    static let reuseID = String(describing: TabBarTileCell.self)
    private var isBeingEdited = false

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 28, weight: .medium)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.7
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, isBeingEdited: Bool) {
        titleLabel.text = title
        self.isBeingEdited = isBeingEdited
        setShaking(isBeingEdited)
        updateAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAnimation(forKey: "shake")
        transform = .identity
        isBeingEdited = false
    }

    // MARK: - Private

    private func setShaking(_ shaking: Bool) {
        if shaking {
            guard contentView.layer.animation(forKey: "shake") == nil else { return }
            let anim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            anim.values = [-0.015, 0.015, -0.015]
            anim.duration = 0.22
            anim.repeatCount = .infinity
            contentView.layer.add(anim, forKey: "shake")
        } else {
            contentView.layer.removeAnimation(forKey: "shake")
        }
    }

    private func setupView() {
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 8)
        layer.shadowRadius = 12
        layer.shadowOpacity = 0

        contentView.addSubview(titleLabel)

        titleLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(12)
            make.trailing.lessThanOrEqualToSuperview().offset(-12)
        }
        updateAppearance()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.updateAppearance()
        }
    }

    private func updateAppearance() {
        if isBeingEdited {
            // 被拿起：品红底白字，明显区别于普通焦点。
            contentView.backgroundColor = UIColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1)
            titleLabel.textColor = .white
            layer.shadowOpacity = 0.45
        } else if isFocused {
            contentView.backgroundColor = .white
            titleLabel.textColor = .black
            layer.shadowOpacity = 0.3
        } else {
            contentView.backgroundColor = UIColor(white: 0.15, alpha: 1)
            titleLabel.textColor = .white
            layer.shadowOpacity = 0
        }
    }
}

// MARK: - Section Header

class TabBarSectionHeaderView: UICollectionReusableView {
    static let reuseID = String(describing: TabBarSectionHeaderView.self)

    let label: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 30, weight: .bold)
        l.textColor = .white
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.bottom.equalToSuperview().offset(-4)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
