//
//  PersonalViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/8/20.
//

import Alamofire
import Kingfisher
import SnapKit
import SwiftyJSON
import UIKit

class PersonalViewController: UIViewController, BLTabBarContentVCProtocol {
    struct CellModel {
        let title: String
        var autoSelect: Bool? = true
        var contentVC: UIViewController? = nil
        var action: (() -> Void)? = nil
    }

    static func create() -> PersonalViewController {
        return PersonalViewController()
    }

    private let leftContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let profileContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// 顶部胶囊选项栏（毛玻璃）。焦点移到哪一项，下方就显示哪一项的内容。
    private let pillBackground: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        return view
    }()

    private var pillWidthConstraint: Constraint?

    private let leftCollectionView: UICollectionView = {
        let size = NSCollectionLayoutSize(widthDimension: .estimated(130), heightDimension: .absolute(56))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        let layout = UICollectionViewCompositionalLayout(section: section, configuration: configuration)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.remembersLastFocusedIndexPath = true
        return collectionView
    }()

    private var selectedIndex = 0

    weak var currentViewController: UIViewController?

    var cellModels = [CellModel]()
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupData()
        leftCollectionView.reloadData()
        avatarImageView.layer.cornerRadius = 32
        leftCollectionView.register(BLPillCell.self, forCellWithReuseIdentifier: "cell")
        show(index: 0)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAccountUpdate),
                                               name: AccountManager.didUpdateNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleTabBarPagesDidChange),
                                               name: .tabBarPagesDidChange,
                                               object: nil)
        updateAccountInfo()
        AccountManager.shared.refreshActiveAccountProfile()
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleHorizontalSwipe(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setupData() {
        cellModels.removeAll()

        let setting = CellModel(title: "设置", contentVC: SettingsViewController())
        cellModels.append(setting)

        for page in Settings.personalPages {
            if let model = makeCellModel(for: page) {
                cellModels.append(model)
            }
        }

        preloadContent()
    }

    /// 后台提前加载各选项的页面和数据，焦点移过去时立刻显示。
    private func preloadContent() {
        for (offset, model) in cellModels.enumerated() {
            guard let vc = model.contentVC else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(offset) * 0.12) { [weak self, weak vc] in
                guard let self, let vc, !vc.isViewLoaded else { return }
                vc.loadViewIfNeeded()
                vc.view.frame = self.contentView.bounds.isEmpty ? self.view.bounds : self.contentView.bounds
                vc.view.layoutIfNeeded()
            }
        }
    }

    private func makeCellModel(for page: TabBarPage) -> CellModel? {
        let vc = TabBarPageVCFactory.createVC(for: page)
        // 收藏直接嵌在下方显示（默认收藏夹在前），焦点移上去即可看到，与其他选项一致。
        if page.requirePresentInPersonalPage, page != .favorite {
            return CellModel(title: page.title) { [weak self] in
                self?.present(vc, animated: true)
            }
        }

        return CellModel(title: page.title, contentVC: vc)
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

    func actionLogout() {
        let alert = UIAlertController(title: "确定登出？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) {
            _ in
            WebRequest.logout {
                ApiRequest.logout { hasRemainingAccount in
                    if hasRemainingAccount {
                        AccountManager.shared.refreshActiveAccountProfile()
                    } else {
                        AppDelegate.shared.showLogin()
                    }
                }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func handleAccountUpdate() {
        updateAccountInfo()
    }

    @objc private func handleTabBarPagesDidChange() {
        setupData()
        leftCollectionView.reloadData()
        show(index: 0)
    }

    private func updateAccountInfo() {
        guard let account = AccountManager.shared.activeAccount else {
            usernameLabel.text = "未登录"
            avatarImageView.image = nil
            return
        }
        usernameLabel.text = account.profile.username
        if let url = URL(string: account.profile.avatar), !account.profile.avatar.isEmpty {
            avatarImageView.kf.setImage(with: url)
        } else {
            avatarImageView.image = UIImage(systemName: "person.crop.circle.fill")
        }
    }

    private func setupUI() {
        view.addSubview(profileContainerView)
        view.addSubview(pillBackground)
        pillBackground.contentView.addSubview(leftCollectionView)
        view.addSubview(contentView)
        profileContainerView.addSubview(avatarImageView)
        profileContainerView.addSubview(usernameLabel)

        leftCollectionView.delegate = self
        leftCollectionView.dataSource = self

        // 头像 + 用户名已由主界面左上角的胶囊显示，这里隐藏以免重复。
        profileContainerView.isHidden = true
        profileContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(80)
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(4)
            make.height.equalTo(64)
        }
        avatarImageView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(avatarImageView.snp.height)
        }
        usernameLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        usernameLabel.snp.makeConstraints { make in
            make.leading.equalTo(avatarImageView.snp.trailing).offset(16)
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
            make.width.lessThanOrEqualTo(260)
        }

        // 顶部居中：胶囊选项栏
        pillBackground.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(profileContainerView)
            make.height.equalTo(76)
            make.leading.greaterThanOrEqualTo(profileContainerView.snp.trailing).offset(40)
            make.trailing.lessThanOrEqualToSuperview().inset(80)
            pillWidthConstraint = make.width.equalTo(900).priority(.high).constraint
        }
        pillBackground.layer.cornerRadius = 38
        leftCollectionView.snp.makeConstraints { $0.edges.equalToSuperview() }

        // 下方：所选项的内容
        contentView.snp.makeConstraints { make in
            make.top.equalTo(pillBackground.snp.bottom).offset(24)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = leftCollectionView.collectionViewLayout.collectionViewContentSize.width
        if width > 0 { pillWidthConstraint?.update(offset: width) }
    }

    // MARK: - 设置页里按左 / 右：切换顶部选项

    private var lastFocusChange = 0.0
    private var pressStartedAt = 0.0
    private var forcedPill: IndexPath?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let forcedPill, let cell = leftCollectionView.cellForItem(at: forcedPill) { return [cell] }
        return super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        lastFocusChange = ProcessInfo.processInfo.systemUptime
    }

    /// 设置是竖向列表，左右键本来没有作用：这时左右键切换到顶部的上 / 下一个选项。
    private var horizontalSwitchEnabled: Bool {
        guard currentViewController is SettingsViewController,
              let focused = UIScreen.main.focusedView else { return false }
        return focused.isDescendant(of: contentView)
    }

    private func direction(of type: UIPress.PressType) -> Int? {
        switch type {
        case .rightArrow: return 1
        case .leftArrow: return -1
        default: return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let type = presses.first?.type, direction(of: type) != nil { pressStartedAt = ProcessInfo.processInfo.systemUptime }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        guard let type = presses.first?.type, let step = direction(of: type), horizontalSwitchEnabled else { return }
        let started = pressStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.lastFocusChange < started else { return } // 焦点动了就不切换
            self.switchPill(by: step)
        }
    }

    @objc private func handleHorizontalSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard horizontalSwitchEnabled else { return }
        let step = gesture.direction == .right ? 1 : -1
        let swipedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.lastFocusChange < swipedAt - 0.4 else { return }
            self.switchPill(by: step)
        }
    }

    private func switchPill(by step: Int) {
        var index = selectedIndex + step
        while cellModels.indices.contains(index), cellModels[index].contentVC == nil { index += step }
        guard cellModels.indices.contains(index) else { return }
        show(index: index)
        let path = IndexPath(item: index, section: 0)
        leftCollectionView.scrollToItem(at: path, at: .centeredHorizontally, animated: true)
        leftCollectionView.layoutIfNeeded()
        forcedPill = path
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        forcedPill = nil
    }

    private func show(index: Int) {
        guard cellModels.indices.contains(index) else { return }
        let model = cellModels[index]
        if let vc = model.contentVC {
            selectedIndex = index
            setViewController(vc: vc)
            leftCollectionView.visibleCells.forEach { cell in
                if let pill = cell as? BLPillCell, let path = leftCollectionView.indexPath(for: cell) {
                    pill.isCurrent = path.item == selectedIndex
                }
            }
        }
    }
}

extension PersonalViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! BLPillCell
        cell.titleLabel.text = cellModels[indexPath.item].title
        cell.isCurrent = indexPath.item == selectedIndex
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return cellModels.count
    }
}

extension PersonalViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let model = cellModels[indexPath.item]
        if model.contentVC != nil {
            show(index: indexPath.item)
        }
        model.action?()
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        // 焦点移到哪个选项，下方就显示哪个选项（「账号切换」「登出」等操作项需按确定）。
        guard let next = context.nextFocusedIndexPath, cellModels.indices.contains(next.item) else { return }
        let model = cellModels[next.item]
        guard model.autoSelect != false, model.contentVC != nil, next.item != selectedIndex else { return }
        show(index: next.item)
    }
}

/// 胶囊选项：焦点白底黑字，当前项淡白底。
final class BLPillCell: UICollectionViewCell {
    let titleLabel = UILabel()
    private let background = UIView()

    var isCurrent = false {
        didSet { updateAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 28
        background.layer.cornerCurve = .continuous
        contentView.addSubview(background)
        background.snp.makeConstraints { $0.edges.equalToSuperview() }
        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        titleLabel.textAlignment = .center
        background.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(26)
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
        background.backgroundColor = isFocused ? .white : isCurrent ? UIColor.white.withAlphaComponent(0.18) : .clear
        titleLabel.textColor = isFocused ? .black : UIColor.white.withAlphaComponent(isCurrent ? 1 : 0.75)
        transform = isFocused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = isFocused ? 0.3 : 0
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)
    }
}

class EmptyViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let label = UILabel()
        label.text = "Nothing Here"
        view.addSubview(label)
        label.makeConstraintsBindToCenterOfSuperview()
    }
}

extension PersonalViewController: BLMenuPressHandling {
    /// 焦点在下方内容里（某个视频、收藏夹……）时，返回键先把焦点移回顶部当前选项；
    /// 焦点已经在顶部标题栏时返回 false，由主界面弹出侧边栏。
    func handleMenuPress() -> Bool {
        guard let focused = UIScreen.main.focusedView, focused.isDescendant(of: contentView) else { return false }
        let path = IndexPath(item: selectedIndex, section: 0)
        leftCollectionView.scrollToItem(at: path, at: .centeredHorizontally, animated: true)
        leftCollectionView.layoutIfNeeded()
        forcedPill = path
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        forcedPill = nil
        return true
    }
}

extension PersonalViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
