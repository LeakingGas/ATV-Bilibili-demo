//
//  FeedCollectionViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2021/4/5.
//

import Kingfisher
import SnapKit
import TVUIKit
import UIKit

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
            // 整体替换（包括刷新时先清空）：下一批数据到来时必须换背景。
            backdropStale = true
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
            if oldValue.isEmpty, !_displayData.isEmpty { requestInitialFocusIfNeeded() }
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

    /// 去掉一个视频（例如点了不感兴趣），后面的顶上来，焦点落在顶上来的那个上。
    func remove(where match: (any DisplayData) -> Bool) {
        guard let index = _displayData.firstIndex(where: { match($0.data) }) else { return }
        _displayData.remove(at: index)
        guard !_displayData.isEmpty else { return }
        lastFocusedIndexPath = IndexPath(item: min(index, _displayData.count - 1), section: 0)
        collectionView.setNeedsFocusUpdate()
        collectionView.updateFocusIfNeeded()
        if _displayData.count < 12, !finished, !isLoading {
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
    }

    /// 第一批数据到达时，如果屏幕上还没有任何获得焦点的元素（刚从主屏幕进入 App），
    /// 主动请求一次焦点更新，让第一个视频被选中。
    private func requestInitialFocusIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window, !self.view.isHidden else { return }
            // 已经有焦点、且在可见的内容里：不打扰。焦点不存在或落在隐藏的系统 tab 栏上时纠正。
            if let focused = UIScreen.main.focusedView, focused.window != nil, !(focused is BLCurrentPagePill),
               !(focused.isDescendant(of: (window.rootViewController as? UITabBarController)?.tabBar ?? UIView())) { return }
            let root = window.rootViewController
            root?.setNeedsFocusUpdate()
            root?.updateFocusIfNeeded()
        }
    }

    // MARK: - 毛玻璃背景：取列表首个视频封面做大幅模糊，随页面内容定色调，不随焦点变化。

    private let backdrop = FeedBackdropView()

    private var backdropStale = true

    private func updateBackdropIfNeeded(force: Bool) {
        guard force || backdropStale || !backdrop.hasImage, let first = _displayData.first?.data.pic else { return }
        backdropStale = false
        backdrop.setImage(url: first)
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
        let vSpacing: CGFloat = style == .large ? 34 : 28
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
            cell.setup(data: displayData.data, index: indexPath.item + 1)
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

/// 列表背景：首个视频封面高斯模糊铺满全屏（保留色彩），再叠一层轻薄毛玻璃和渐变保证文字可读。
final class FeedBackdropView: UIView {
    private let imageView = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
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
        // 毛玻璃只取一部分强度：既有磨砂质感，又让封面颜色透出来。
        blur.alpha = 0.55
        gradient.colors = [UIColor.black.withAlphaComponent(0.05).cgColor, UIColor.black.withAlphaComponent(0.42).cgColor]
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
        // 先缩小再高斯模糊：色块柔和、无马赛克感，开销也小。换背景时淡入淡出。
        let processor = DownsamplingImageProcessor(size: CGSize(width: 192, height: 108)) |> BlurImageProcessor(blurRadius: 14)
        imageView.kf.setImage(with: url, options: [.processor(processor), .cacheOriginalImage, .transition(.fade(0.8))]) { [weak self] result in
            guard let self, case .success = result else { return }
            UIView.animate(withDuration: 0.6) { self.imageView.alpha = 1 }
        }
    }
}
