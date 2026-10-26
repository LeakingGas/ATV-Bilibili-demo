//
//  BLTabBarViewController.swift
//  BilibiliLive
//
//  Created by Etan Chen on 2021/4/5.
//

import Kingfisher
import SnapKit
import UIKit

protocol BLTabBarContentVCProtocol {
    func reloadData()
}

/// 主界面。系统顶部 tab 栏隐藏，改为左侧毛玻璃悬浮侧边栏：
/// 平时内容全屏；按返回从左侧弹出侧边栏；侧边栏打开时再按返回回到 Apple TV 主屏幕；
/// 按右方向键（或选中某一项）收起侧边栏，回到刚才的内容。
/// （tvOS SDK 未开放系统侧边栏 UITabBarController.Mode.tabSidebar，因此自行实现。）
class BLTabBarViewController: UITabBarController, UITabBarControllerDelegate {
    private let sidebar = BLSidebarView()
    private let currentPill = BLCurrentPagePill()
    private let dimView = UIView()
    private let rightFocusGuide = UIFocusGuide()
    private var sidebarVisible = false
    private var menuPressConsumed = false
    private var isPreviewing = false

    private func preview(index: Int) {
        guard sidebarVisible, index != selectedIndex, let controllers = viewControllers, controllers.indices.contains(index) else { return }
        isPreviewing = true
        selectedIndex = index
        if let selected = selectedViewController { rightFocusGuide.preferredFocusEnvironments = [selected] }
        view.bringSubviewToFront(dimView)
        view.bringSubviewToFront(sidebar)
        // 切换页面时系统可能把焦点交给新页面；侧边栏仍打开时把焦点留在侧边栏。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPreviewing = false
            if self.sidebarVisible, let focused = UIScreen.main.focusedView, !focused.isDescendant(of: self.sidebar) {
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        Settings.bootstrapTabBarPlacementModelIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabBarPagesDidChange), name: .tabBarPagesDidChange, object: nil)
        tabBar.isHidden = true
        // 给左上角的当前页面胶囊留出位置：内容的安全区下移，列表滚动时从胶囊下方穿过。
        additionalSafeAreaInsets = UIEdgeInsets(top: 50, left: 0, bottom: 0, right: 0)
        setupSidebar()
        setupMenuGesture()
        reloadTabs(animated: false)
    }

    // MARK: - 返回键

    private let menuTap = UITapGestureRecognizer()

    /// 系统 UITabBarController 会先用返回键把焦点交给（已隐藏的）tab 栏，导致要按两次。
    /// 用自己的返回键手势抢先处理：根页面按返回直接弹出侧边栏。
    private func setupMenuGesture() {
        menuTap.addTarget(self, action: #selector(handleMenuTap))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuTap.delegate = self
        view.addGestureRecognizer(menuTap)
    }

    /// 刚启动、列表还没加载出来时没有任何获得焦点的元素，返回键不经过本页面，直接退出 App。
    /// 把返回键手势挂到窗口上，没有焦点时也能先弹出侧边栏。
    private func moveMenuGestureToWindowIfNeeded() {
        guard let window = view.window, menuTap.view !== window else { return }
        menuTap.view?.removeGestureRecognizer(menuTap)
        window.addGestureRecognizer(menuTap)
    }

    @objc private func handleMenuTap() {
        setSidebar(visible: true)
    }

    private var canShowSidebarOnMenu: Bool {
        guard !sidebarVisible, presentedViewController == nil, view.window != nil else { return false }
        if let nav = selectedViewController as? UINavigationController, nav.viewControllers.count > 1 { return false }
        return true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        moveMenuGestureToWindowIfNeeded()
        // 关掉系统自带的返回键手势（把焦点移到 tab 栏），避免抢在我们前面。
        for gesture in (view.gestureRecognizers ?? []) + (tabBar.gestureRecognizers ?? []) where gesture !== menuTap {
            if gesture.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue)) { gesture.isEnabled = false }
        }
    }

    // MARK: - 预加载

    /// 后台依次加载每个页面（数据也随之请求），侧边栏切换时内容已就绪、无需等待。
    private func preloadPages() {
        guard let controllers = viewControllers else { return }
        for (offset, controller) in controllers.enumerated() where controller !== selectedViewController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(offset) * 0.15) { [weak self, weak controller] in
                guard let self, let controller, !controller.isViewLoaded else { return }
                controller.loadViewIfNeeded()
                controller.view.frame = self.view.bounds
                controller.view.layoutIfNeeded()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tabBar.isHidden = true
        view.bringSubviewToFront(currentPill)
        view.bringSubviewToFront(dimView)
        view.bringSubviewToFront(sidebar)
    }

    private func updateCurrentPill() {
        let pages = Settings.tabBarPages
        let title = pages.indices.contains(selectedIndex) ? pages[selectedIndex].title : ""
        currentPill.update(title: title, account: AccountManager.shared.activeAccount?.profile)
    }

    private func setupSidebar() {
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        view.addSubview(dimView)
        dimView.snp.makeConstraints { $0.edges.equalToSuperview() }

        view.addSubview(sidebar)
        // 左上角悬浮，高度随内容（不再贯穿整个屏幕）。
        sidebar.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(56)
            make.top.equalToSuperview().offset(44)
            make.bottom.lessThanOrEqualToSuperview().inset(44)
            make.width.equalTo(360)
        }

        // 左上角：头像 + 当前页面名称的小胶囊（侧边栏收起时显示）。
        view.addSubview(currentPill)
        currentPill.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(56)
            make.top.equalToSuperview().offset(44)
        }
        sidebar.onSelect = { [weak self] index in
            guard let self else { return }
            if index != self.selectedIndex, let controllers = self.viewControllers, controllers.indices.contains(index) {
                self.selectedIndex = index
            }
            self.setSidebar(visible: false)
        }
        // 焦点移到哪一项，背后就切换到哪个页面（稍作防抖，快速滑过不逐个加载）。
        // 焦点移到哪一项，背后立刻切换到哪个页面（各页面已在后台预加载）。
        sidebar.onFocus = { [weak self] index in
            guard let self, self.sidebarVisible else { return }
            self.preview(index: index)
        }
        sidebar.alpha = 0
        sidebar.transform = CGAffineTransform(translationX: -560, y: 0)
        sidebar.isHidden = true

        // 侧边栏右侧：按右方向键总能回到内容（即使右边一时没有可聚焦的元素）。
        view.addLayoutGuide(rightFocusGuide)
        rightFocusGuide.snp.makeConstraints { make in
            make.leading.equalTo(sidebar.snp.trailing)
            make.width.equalTo(40)
            make.top.bottom.equalTo(sidebar)
        }
        rightFocusGuide.isEnabled = false
    }

    private func setSidebar(visible: Bool) {
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible
        if visible {
            sidebar.update(account: AccountManager.shared.activeAccount?.profile)
            sidebar.isHidden = false
            if let selected = selectedViewController { rightFocusGuide.preferredFocusEnvironments = [selected] }
        }
        rightFocusGuide.isEnabled = visible
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.4, options: [.beginFromCurrentState]) {
            self.currentPill.alpha = visible ? 0 : 1
            self.sidebar.alpha = visible ? 1 : 0
            self.sidebar.transform = visible ? .identity : CGAffineTransform(translationX: -560, y: 0)
            self.dimView.alpha = visible ? 1 : 0
        } completion: { _ in
            if !self.sidebarVisible { self.sidebar.isHidden = true }
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if sidebarVisible { return [sidebar] }
        return super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // 焦点离开侧边栏（按右方向键回到内容）即收起。
        if sidebarVisible, !isPreviewing, let next = context.nextFocusedView, !next.isDescendant(of: sidebar) {
            setSidebar(visible: false)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), !sidebarVisible, presentedViewController == nil {
            // 内容没有处理返回键（已在根页面）：弹出侧边栏，而不是退出 App。
            menuPressConsumed = true
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuPressConsumed {
            menuPressConsumed = false
            setSidebar(visible: true)
            return
        }
        super.pressesEnded(presses, with: event)
        guard let buttonPress = presses.first?.type else { return }
        if buttonPress == .playPause {
            if let reloadVC = topMostViewController() as? BLTabBarContentVCProtocol {
                print("send reload to \(reloadVC)")
                reloadVC.reloadData()
            }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuPressConsumed {
            menuPressConsumed = false
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        sidebar.select(index: selectedIndex)
        updateCurrentPill()
    }

    @objc private func handleTabBarPagesDidChange() {
        reloadTabs(animated: false)
    }

    private func reloadTabs(animated: Bool) {
        let previousPage = selectedViewController?.tabBarItem.accessibilityIdentifier
        let pages = Settings.tabBarPages
        let controllers = pages.map { controller(for: $0) }

        setViewControllers(controllers, animated: animated)

        if let previousPage, let index = controllers.firstIndex(where: { $0.tabBarItem.accessibilityIdentifier == previousPage }) {
            selectedIndex = index
        }
        sidebar.setItems(pages.map { ($0.title, $0.symbolName) }, selected: selectedIndex)
        updateCurrentPill()
        preloadPages()
    }

    override var selectedIndex: Int {
        didSet {
            sidebar.select(index: selectedIndex)
            updateCurrentPill()
        }
    }

    private func controller(for page: TabBarPage) -> UIViewController {
        return TabBarPageVCFactory.createVC(for: page)
    }
}

// MARK: - Sidebar

final class BLSidebarView: UIView {
    var onSelect: ((Int) -> Void)?
    var onFocus: ((Int) -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let stack = UIStackView()
    private var rows = [BLSidebarRow]()
    private var selectedIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 30
        layer.shadowOffset = CGSize(width: 0, height: 16)
        blur.layer.cornerRadius = 36
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        blur.layer.borderWidth = 1
        blur.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }

        avatarView.layer.cornerRadius = 26
        avatarView.clipsToBounds = true
        avatarView.contentMode = .scaleAspectFill
        avatarView.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")
        avatarView.tintColor = UIColor.white.withAlphaComponent(0.7)
        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.textColor = .white
        let header = UIStackView(arrangedSubviews: [avatarView, nameLabel])
        header.axis = .horizontal
        header.spacing = 16
        header.alignment = .center
        avatarView.snp.makeConstraints { $0.width.height.equalTo(52) }

        stack.axis = .vertical
        stack.spacing = 6
        blur.contentView.addSubview(header)
        blur.contentView.addSubview(stack)
        header.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(28)
            make.leading.trailing.equalToSuperview().inset(28)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom).offset(22)
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().inset(20)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(account: AccountManager.Profile?) {
        nameLabel.text = account?.username ?? "未登录"
        if let avatar = account?.avatar, let url = URL(string: avatar), !avatar.isEmpty {
            avatarView.kf.setImage(with: url, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 136, height: 136))), .cacheOriginalImage])
        }
    }

    func setItems(_ items: [(title: String, symbol: String)], selected: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = BLSidebarRow(title: item.title, symbol: item.symbol)
            row.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .primaryActionTriggered)
            row.onFocus = { [weak self] in self?.onFocus?(index) }
            stack.addArrangedSubview(row)
            return row
        }
        select(index: selected)
    }

    func select(index: Int) {
        selectedIndex = index
        for (i, row) in rows.enumerated() { row.isCurrent = i == index }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        rows.indices.contains(selectedIndex) ? [rows[selectedIndex]] : rows
    }
}

final class BLSidebarRow: UIControl {
    private let background = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    var isCurrent = false {
        didSet { updateAppearance() }
    }

    var onFocus: (() -> Void)?

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        background.layer.cornerRadius = 26
        background.layer.cornerCurve = .continuous
        background.isUserInteractionEnabled = false
        addSubview(background)
        background.snp.makeConstraints { $0.edges.equalToSuperview() }
        iconView.image = UIImage(systemName: symbol)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        iconView.contentMode = .scaleAspectFit
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 26, weight: .medium)
        [iconView, titleLabel].forEach { background.addSubview($0) }
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(22)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(32)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(16)
            make.trailing.equalToSuperview().inset(20)
            make.centerY.equalToSuperview()
        }
        snp.makeConstraints { $0.height.equalTo(60) }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            sendActions(for: .primaryActionTriggered)
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.updateAppearance() }
        if context.nextFocusedView === self { onFocus?() }
    }

    private func updateAppearance() {
        let focused = isFocused
        background.backgroundColor = focused ? .white : isCurrent ? UIColor.white.withAlphaComponent(0.16) : .clear
        let color: UIColor = focused ? .black : isCurrent ? .white : UIColor.white.withAlphaComponent(0.72)
        iconView.tintColor = color
        titleLabel.textColor = color
        transform = focused ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = focused ? 0.25 : 0
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)
    }
}

extension BLTabBarViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === menuTap else { return true }
        return canShowSidebarOnMenu
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 其他返回键手势等我们失败后才生效（侧边栏已打开时我们不开始，系统照常退回主屏幕）。
        gestureRecognizer === menuTap && otherGestureRecognizer.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue))
    }
}

/// 左上角小胶囊：‹ 头像 当前页面。提示「按返回打开菜单」，不可聚焦。
final class BLCurrentPagePill: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.left"))
    private let avatarView = UIImageView()
    private let titleLabel = UILabel()
    private var avatarURL: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        blur.layer.cornerRadius = 32
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        blur.layer.borderWidth = 1
        blur.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        chevron.tintColor = UIColor.white.withAlphaComponent(0.6)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        chevron.contentMode = .scaleAspectFit
        avatarView.layer.cornerRadius = 22
        avatarView.clipsToBounds = true
        avatarView.contentMode = .scaleAspectFill
        avatarView.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        let row = UIStackView(arrangedSubviews: [chevron, avatarView, titleLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.setCustomSpacing(10, after: chevron)
        blur.contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(10)
            make.leading.equalToSuperview().offset(18)
            make.trailing.equalToSuperview().inset(30)
        }
        avatarView.snp.makeConstraints { $0.width.height.equalTo(44) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, account: AccountManager.Profile?) {
        titleLabel.text = title
        guard let avatar = account?.avatar, !avatar.isEmpty, avatar != avatarURL, let url = URL(string: avatar) else { return }
        avatarURL = avatar
        avatarView.kf.setImage(with: url, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 88, height: 88))), .cacheOriginalImage])
    }
}
