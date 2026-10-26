//
//  FeedCollectionViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2021/4/5.
//

import GameController
import Kingfisher
import SnapKit
import TVUIKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

protocol DisplayData: Hashable, AvatarProviding {
    var title: String { get }
    var ownerName: String { get }
    var pic: URL? { get }
    var avatar: URL? { get }
    var date: String? { get }
    var overlay: DisplayOverlay? { get }
}

extension DisplayData {
    var avatar: URL? { return nil }
    var date: String? { return nil }
    var overlay: DisplayOverlay? { return nil }
}

struct AnyDispplayData: Hashable {
    let data: any DisplayData

    static func == (lhs: AnyDispplayData, rhs: AnyDispplayData) -> Bool {
        func eq<T: Equatable>(lhs: T, rhs: any Equatable) -> Bool {
            lhs == rhs as? T
        }
        return eq(lhs: lhs.data, rhs: rhs.data)
    }

    func hash(into hasher: inout Hasher) {
        data.hash(into: &hasher)
    }
}

struct DisplayOverlay {
    var leftItems: [DisplayOverlayItem]
    var rightItems: [DisplayOverlayItem]
    var badge: DisplayOverlayBadge?

    init(leftItems: [DisplayOverlayItem], rightItems: [DisplayOverlayItem] = [], badge: DisplayOverlayBadge? = nil) {
        self.leftItems = leftItems
        self.rightItems = rightItems
        self.badge = badge
    }

    struct DisplayOverlayItem {
        var icon: String?
        var text: String
    }

    struct DisplayOverlayBadge {
        var color: UIColor?
        var text: String
    }
}

struct FeedHeaderConfig {
    let elementKind: String
    let estimatedHeight: CGFloat
    let viewProvider: (UICollectionView, String, IndexPath) -> UICollectionReusableView?

    init<T: UICollectionReusableView>(
        viewType: T.Type,
        estimatedHeight: CGFloat = 44,
        configure: @escaping (T, IndexPath) -> Void
    ) {
        elementKind = String(describing: viewType)
        self.estimatedHeight = estimatedHeight

        let registration = UICollectionView.SupplementaryRegistration<T>(elementKind: elementKind) { view, _, indexPath in
            configure(view, indexPath)
        }

        viewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: registration, for: indexPath)
        }
    }
}

class FeedCollectionViewController: UIViewController {
    var collectionView: UICollectionView!

    private enum Section: CaseIterable {
        case main
    }

    var styleOverride: FeedDisplayStyle?
    var didSelect: ((any DisplayData) -> Void)?
    var didLongPress: ((any DisplayData) -> Void)?
    var loadMore: (() -> Void)?
    var finished = false
    var pageSize = 20
    var showHeader: Bool = false
    var headerText = ""
    var customHeaderConfig: FeedHeaderConfig?

    /// 离开列表前最后聚焦的位置。回到列表（例如从侧边栏切回来）时焦点回到这里，
    /// 而不是第 0 个视频（那样会把列表滚回顶部）。整体替换数据时重置。
    private var lastFocusedIndexPath: IndexPath?

    var displayDatas: [any DisplayData] {
        set {
            _displayData = newValue.map { AnyDispplayData(data: $0) }.uniqued()
            finished = false
            lastFocusedIndexPath = nil
            updateBackdropIfNeeded(force: true)
        }
        get {
            _displayData.map { $0.data }
        }
    }

    private var _displayData = [AnyDispplayData]() {
        didSet {
            var snapshot = NSDiffableDataSourceSnapshot<Section, AnyDispplayData>()
            snapshot.appendSections(Section.allCases)
            snapshot.appendItems(_displayData, toSection: .main)
            dataSource.apply(snapshot)
        }
    }

    private var isLoading = false

    typealias DisplayCellRegistration = UICollectionView.CellRegistration<FeedCollectionViewCell, AnyDispplayData>
    private lazy var dataSource = makeDataSource()

    // MARK: - Public

    func show(in vc: UIViewController) {
        vc.addChild(self)
        vc.view.addSubview(view)
        view.makeConstraintsToBindToSuperview()
        didMove(toParent: vc)
        vc.setContentScrollView(collectionView)
    }

    func appendData(displayData: [any DisplayData]) {
        defer { updateBackdropIfNeeded(force: false) }
        isLoading = false
        _displayData.append(contentsOf: displayData.map { AnyDispplayData(data: $0) }.filter({ !_displayData.contains($0) }))
        if displayData.count < pageSize - 5 || displayData.count == 0 {
            finished = true
            return
        }

        if _displayData.count < 12 {
            isLoading = true
            loadMore?()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeCollectionViewLayout())
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        collectionView.dataSource = dataSource
        collectionView.delegate = self
        collectionView.backgroundView = backdrop
        ClickpadRotationTracker.shared.register(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ClickpadRotationTracker.shared.installTouchObserver(on: view.window)
    }

    // MARK: - 毛玻璃背景：取列表首个视频封面做大幅模糊，随页面内容定色调，不随焦点变化。

    private let backdrop = FeedBackdropView()

    private func updateBackdropIfNeeded(force: Bool) {
        guard force || !backdrop.hasImage, let first = _displayData.first?.data.pic else { return }
        backdrop.setImage(url: first)
    }

    // MARK: - 触控板外圈转圈：顺时针 = 下一个视频，逆时针 = 上一个（按阅读顺序跨行）

    private var rotationTarget: IndexPath?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let rotationTarget, let cell = collectionView.cellForItem(at: rotationTarget) { return [cell] }
        return super.preferredFocusEnvironments
    }

    /// 焦点在本列表内时处理一步转圈，返回是否已处理。
    func handleRotationStep(_ step: Int) -> Bool {
        guard isViewLoaded, let focused = UIScreen.main.focusedView, focused.isDescendant(of: collectionView),
              let current = lastFocusedIndexPath else { return false }
        let count = collectionView.numberOfItems(inSection: current.section)
        let next = current.item + step
        guard next >= 0, next < count else { return true }
        let target = IndexPath(item: next, section: current.section)
        if collectionView.cellForItem(at: target) == nil {
            collectionView.scrollToItem(at: target, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        rotationTarget = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        rotationTarget = nil
        return true
    }

    // MARK: - Private

    private func makeCollectionViewLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout {
            [weak self] _, _ in
            return self?.makeGridLayoutSection()
        }
    }

    private func makeGridLayoutSection() -> NSCollectionLayoutSection {
        var style = Settings.displayStyle
        if let styleOverride {
            style = styleOverride
        }

        let heightDimension = NSCollectionLayoutDimension.estimated(style.heightEstimated)
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(style.fractionalWidth),
            heightDimension: heightDimension
        ))
        let hSpacing: CGFloat = style == .large ? 35 : 30
        item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: hSpacing, bottom: 0, trailing: hSpacing)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: heightDimension
            ),
            repeatingSubitem: item,
            count: style.feedColCount
        )
        let vSpacing: CGFloat = style == .large ? 24 : 16
        let baseSpacing: CGFloat = style == .sideBar ? 24 : 0
        group.edgeSpacing = NSCollectionLayoutEdgeSpacing(leading: .fixed(baseSpacing), top: .fixed(vSpacing), trailing: .fixed(0), bottom: .fixed(vSpacing))
        let section = NSCollectionLayoutSection(group: group)
        if baseSpacing > 0 {
            section.contentInsets = NSDirectionalEdgeInsets(top: baseSpacing, leading: 0, bottom: 0, trailing: 0)
        }

        if showHeader {
            let headerHeight = customHeaderConfig?.estimatedHeight ?? 44
            let headerKind = customHeaderConfig?.elementKind ?? TitleSupplementaryView.reuseIdentifier
            let titleSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0),
                                                   heightDimension: .estimated(headerHeight))
            let titleSupplementary = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: titleSize,
                elementKind: headerKind,
                alignment: .top
            )
            section.boundarySupplementaryItems = [titleSupplementary]
        }
        return section
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, AnyDispplayData> {
        let dataSource = UICollectionViewDiffableDataSource<Section, AnyDispplayData>(collectionView: collectionView, cellProvider: makeCellRegistration().cellProvider)

        let supplementaryRegistration = UICollectionView.SupplementaryRegistration<TitleSupplementaryView>(elementKind: TitleSupplementaryView.reuseIdentifier) {
            [weak self] supplementaryView, string, indexPath in
            guard let self else { return }
            supplementaryView.label.text = self.headerText
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self else { return nil }

            // 如果有自定义 header 配置，使用自定义的
            if let customConfig = self.customHeaderConfig, kind == customConfig.elementKind {
                return customConfig.viewProvider(collectionView, kind, indexPath)
            }

            // 否则使用默认的 TitleSupplementaryView
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: supplementaryRegistration, for: indexPath
            )
        }

        return dataSource
    }

    private func makeCellRegistration() -> DisplayCellRegistration {
        DisplayCellRegistration { [weak self] cell, indexPath, displayData in
            cell.styleOverride = self?.styleOverride
            cell.setup(data: displayData.data)
            cell.onLongPress = {
                self?.didLongPress?(displayData.data)
            }
        }
    }
}

extension FeedCollectionViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let data = dataSource.itemIdentifier(for: indexPath) {
            didSelect?(data.data)
        }
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let last = lastFocusedIndexPath,
           last.section < collectionView.numberOfSections,
           last.item < collectionView.numberOfItems(inSection: last.section)
        {
            return last
        }
        return IndexPath(item: 0, section: 0)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        if let next = context.nextFocusedIndexPath { lastFocusedIndexPath = next }
    }

    func collectionView(_ collectionView: UICollectionView, shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        // 正在外圈转圈时，系统把这段滑动当成普通方向滑动产生的焦点移动要忽略，只接受转圈带来的移动。
        if ClickpadRotationTracker.shared.isRotating, rotationTarget == nil { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard _displayData.count > 0 else { return }
        guard indexPath.row == _displayData.count - 1, !isLoading, !finished else {
            return
        }
        isLoading = true
        loadMore?()
    }

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        collectionView.visibleCells.compactMap { $0 as? BLMotionCollectionViewCell }.forEach { cell in
            cell.updateTransform()
        }
    }
}

extension FeedDisplayStyle {
    var feedColCount: Int {
        switch self {
        case .normal: return 4
        case .large, .sideBar: return 3
        }
    }
}

/// Siri Remote 触控板外圈转圈识别。
/// 手指位置来自 GameController 的绝对坐标；按下 / 抬起来自 UIKit 触摸事件（绝对坐标在抬起时
/// 不一定回到 0，之前据此判断抬起，导致第二次转圈失效）。
/// 手指从外圈开始、沿外圈转动时，每转约 55° 发出一步：顺时针 +1，逆时针 -1。
final class ClickpadRotationTracker {
    static let shared = ClickpadRotationTracker()

    private(set) var isRotating = false
    private let feeds = NSHashTable<FeedCollectionViewController>.weakObjects()
    private var lastAngle: Double?
    private var accumulated = 0.0
    private var touching = false
    private var decided = false
    private var startedOnRing = false
    private weak var observedWindow: UIWindow?
    private let ringRadius = 0.55
    private let startThreshold = 0.45
    private let stepAngle = 0.95

    private init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachControllers()
        }
        attachControllers()
    }

    func register(_ feed: FeedCollectionViewController) {
        feeds.add(feed)
    }

    func installTouchObserver(on window: UIWindow?) {
        guard let window, observedWindow !== window else { return }
        observedWindow = window
        let observer = TouchPresenceGestureRecognizer()
        observer.onBegan = { [weak self] in self?.touchBegan() }
        observer.onEnded = { [weak self] in self?.touchEnded() }
        window.addGestureRecognizer(observer)
    }

    private func attachControllers() {
        for controller in GCController.controllers() {
            guard let pad = controller.microGamepad else { continue }
            pad.reportsAbsoluteDpadValues = true
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                DispatchQueue.main.async { self?.update(x: Double(x), y: Double(y)) }
            }
        }
    }

    private func reset() {
        decided = false; startedOnRing = false; isRotating = false
        lastAngle = nil; accumulated = 0
    }

    private func touchBegan() {
        touching = true
        reset()
    }

    private func touchEnded() {
        touching = false
        reset()
    }

    private func update(x: Double, y: Double) {
        let radius = hypot(x, y)
        if radius < 0.001 { reset(); return }
        // 没有触摸观察者时（极少见）退化为：有坐标即视为按住。
        if observedWindow == nil { touching = true }
        guard touching else { return }
        if !decided {
            decided = true
            startedOnRing = radius >= ringRadius
        }
        guard startedOnRing, radius >= ringRadius * 0.8 else {
            // 划过中间：这次触摸按普通滑动处理
            startedOnRing = false; isRotating = false; lastAngle = nil; accumulated = 0
            return
        }
        let angle = atan2(y, x)
        defer { lastAngle = angle }
        guard let last = lastAngle else { return }
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        accumulated += delta
        if !isRotating, abs(accumulated) > startThreshold { isRotating = true }
        guard isRotating else { return }
        // y 轴向上为正：顺时针时角度减小。
        while accumulated <= -stepAngle { accumulated += stepAngle; step(+1) }
        while accumulated >= stepAngle { accumulated -= stepAngle; step(-1) }
    }

    private func step(_ value: Int) {
        for feed in feeds.allObjects where feed.handleRotationStep(value) { return }
    }
}

/// 只观察触控板触摸的开始 / 结束，从不识别、不拦截任何事件。
final class TouchPresenceGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onBegan?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onEnded?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onEnded?()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// 列表背景：封面图大幅模糊 + 深色毛玻璃 + 渐变，柔和、不抢内容。
final class FeedBackdropView: UIView {
    private let imageView = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let gradient = CAGradientLayer()
    private(set) var hasImage = false
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.alpha = 0
        addSubview(imageView)
        imageView.snp.makeConstraints { $0.edges.equalToSuperview().inset(-60) }
        addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }
        gradient.colors = [UIColor.black.withAlphaComponent(0.15).cgColor, UIColor.black.withAlphaComponent(0.5).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    func setImage(url: URL) {
        var url = url
        if url.scheme == nil, let fixed = URL(string: "https:\(url.absoluteString)") { url = fixed }
        guard url != currentURL else { return }
        currentURL = url
        hasImage = true
        // 小尺寸下采样后再放大，模糊更柔和、开销更小。
        imageView.kf.setImage(with: url, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 192, height: 108))), .cacheOriginalImage]) { [weak self] result in
            guard let self, case .success = result else { return }
            UIView.animate(withDuration: 0.6) { self.imageView.alpha = 0.9 }
        }
    }
}
