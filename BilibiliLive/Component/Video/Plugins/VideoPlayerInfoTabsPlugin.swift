//
//  VideoPlayerInfoTabsPlugin.swift
//  BilibiliLive
//
//  播放界面下滑面板（单页）：简介 → 选集 → UP主视频 → 相关推荐 → 评论。
//  点赞 / 投币 / 收藏放在底部控制栏（与画质、字幕同一行），任一按钮上长按确定 = 一键三连。
//

import AVKit
import Kingfisher
import SnapKit
import UIKit

final class VideoPlayerInfoTabsPlugin: NSObject, CommonPlayerPlugin {
    var onSelectDiscovery: ((PlayInfo) -> Void)?
    var onSelectEpisode: ((PlayInfo) -> Void)?

    private let currentPlayInfo: PlayInfo
    private let sequenceProvider: VideoSequenceProvider?
    private let detail: VideoDetail?
    private let feedInfoViewController: VideoPlayerFeedInfoViewController
    private let interactions: VideoInteractionController
    private let relatedCandidates: [PlayInfo]
    private let ownerMid: Int
    private var uploaderLoadTask: Task<Void, Never>?
    private weak var playerVC: PlayerHost?

    init(detail: VideoDetail?, currentPlayInfo: PlayInfo, sequenceProvider: VideoSequenceProvider?) {
        self.currentPlayInfo = currentPlayInfo
        self.sequenceProvider = sequenceProvider
        self.detail = detail
        ownerMid = detail?.View.owner.mid ?? 0
        relatedCandidates = Self.makeRelatedEntries(detail: detail, currentPlayInfo: currentPlayInfo)
        feedInfoViewController = VideoPlayerFeedInfoViewController(aid: detail?.View.aid ?? currentPlayInfo.aid, detail: detail)
        interactions = VideoInteractionController(aid: detail?.View.aid ?? currentPlayInfo.aid, detail: detail)
        super.init()

        feedInfoViewController.onSelect = { [weak self] playInfo in
            guard let self else { return }
            let currentSequenceKey = self.sequenceProvider.flatMap { provider in
                MainActor.assumeIsolated {
                    provider.current()?.sequenceKey
                }
            } ?? self.currentPlayInfo.sequenceKey
            guard currentSequenceKey != playInfo.sequenceKey else { return }
            self.onSelectDiscovery?(playInfo)
        }
        feedInfoViewController.onSelectEpisode = { [weak self] playInfo in
            self?.onSelectEpisode?(playInfo)
        }
        if let sequenceProvider {
            let (items, current) = MainActor.assumeIsolated { (sequenceProvider.playSeq, sequenceProvider.current()) }
            let currentKey = current?.sequenceKey ?? currentPlayInfo.sequenceKey
            let entries = items.enumerated().map { index, info in
                let label = info.title?.isEmpty == false ? info.title! : "第 \(index + 1) 集"
                let isCurrent = info.sequenceKey == currentKey
                return VideoPlayerDiscoveryInfoViewController.Entry(playInfo: info,
                                                                    displayData: VideoPlayerDiscoveryInfoViewController.DiscoveryDisplayData(title: isCurrent ? "▶ 正在播放 · \(label)" : label,
                                                                                                                                             ownerName: "",
                                                                                                                                             pic: info.coverURL ?? detail?.pic))
            }
            let currentIndex = items.firstIndex { $0.sequenceKey == currentKey }
            feedInfoViewController.update(episodes: entries, current: currentIndex)
        }
        feedInfoViewController.update(related: relatedCandidates.prefix(20).map(Self.makeViewEntry(from:)))
        interactions.onStateChange = { [weak self] in self?.refreshInteractionItems() }
        loadUploaderEntriesIfNeeded()
    }

    deinit {
        uploaderLoadTask?.cancel()
    }

    func playerDidLoad(host: PlayerHost) {
        playerVC = host
        interactions.attach(to: host)
        refreshCustomInfoViewControllers()
    }

    func playerDidDismiss(host: PlayerHost) {
        removeCustomInfoViewControllers()
        uploaderLoadTask?.cancel()
        uploaderLoadTask = nil
    }

    func playerWillCleanUp(host: PlayerHost) {
        removeCustomInfoViewControllers()
        interactions.detach()
        uploaderLoadTask?.cancel()
        uploaderLoadTask = nil
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        interactions.menuItems()
    }

    private func refreshInteractionItems() {
        guard let playerVC else { return }
        let fresh = Dictionary(uniqueKeysWithValues: interactions.menuItems().map { ($0.identifier, $0) })
        var changed = false
        let items = playerVC.transportBarCustomMenuItems.map { element -> UIMenuElement in
            guard let action = element as? UIAction, let replacement = fresh[action.identifier] else { return element }
            changed = true
            return replacement
        }
        if changed { playerVC.transportBarCustomMenuItems = items }
    }

    private func loadUploaderEntriesIfNeeded() {
        guard ownerMid > 0 else { return }
        uploaderLoadTask = Task { [weak self] in
            guard let self else { return }
            let records = (try? await ApiRequest.requestUpSpaceVideo(mid: self.ownerMid, lastAid: nil, pageSize: 20)) ?? []
            guard !Task.isCancelled else { return }
            var seenAids = Set<Int>()
            let entries = records.compactMap { record -> PlayInfo? in
                guard record.aid > 0, record.aid != self.currentPlayInfo.aid, seenAids.insert(record.aid).inserted else { return nil }
                return PlayInfo(aid: record.aid, title: record.title, ownerName: record.ownerName, coverURL: record.pic)
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.feedInfoViewController.update(uploader: entries.map(Self.makeViewEntry(from:)))
            }
        }
    }

    private static func makeViewEntry(from playInfo: PlayInfo) -> VideoPlayerDiscoveryInfoViewController.Entry {
        VideoPlayerDiscoveryInfoViewController.Entry(playInfo: playInfo,
                                                     displayData: VideoPlayerDiscoveryInfoViewController.DiscoveryDisplayData(title: playInfo.title ?? "",
                                                                                                                              ownerName: playInfo.ownerName ?? "",
                                                                                                                              pic: playInfo.coverURL))
    }

    private func refreshCustomInfoViewControllers() {
        guard let playerVC else { return }
        // 只保留一个面板：下滑即是完整的简介 / 推荐 / 评论页，不再分多个 tab。
        playerVC.customInfoViewControllers = [feedInfoViewController]
    }

    private func removeCustomInfoViewControllers() {
        guard let playerVC else { return }
        playerVC.customInfoViewControllers.removeAll { $0 === feedInfoViewController }
    }

    private static func makeRelatedEntries(detail: VideoDetail?, currentPlayInfo: PlayInfo) -> [PlayInfo] {
        let related = detail?.Related ?? []
        var seenAids = Set<Int>()
        return related.compactMap { info -> PlayInfo? in
            guard info.aid > 0, info.aid != currentPlayInfo.aid, seenAids.insert(info.aid).inserted else { return nil }
            return PlayInfo(aid: info.aid, cid: info.cid, title: info.title, ownerName: info.ownerName, coverURL: info.pic)
        }
    }
}

// MARK: - 点赞 / 投币 / 收藏 + 一键三连

final class VideoInteractionController: NSObject, UIGestureRecognizerDelegate {
    enum Kind: String, CaseIterable {
        case like, coin, favorite
        var title: String { self == .like ? "点赞" : self == .coin ? "投币" : "收藏" }
        var image: String { self == .like ? "hand.thumbsup" : self == .coin ? "bitcoinsign.circle" : "star" }
        var identifier: UIAction.Identifier { UIAction.Identifier("btr.interaction." + rawValue) }
    }

    var onStateChange: (() -> Void)?

    private let aid: Int
    private var liked = false
    private var coins = 0
    private var favorited = false
    private var counts: [Kind: Int]
    private var busy = Set<Kind>()
    private var focusedKind: Kind?
    private var suppressActionsUntil = Date.distantPast
    private weak var host: PlayerHost?
    private var playerView: UIView? { host?.hostViewController.view }
    private var longPress: UILongPressGestureRecognizer?
    private var focusObserver: NSObjectProtocol?

    init(aid: Int, detail: VideoDetail?) {
        self.aid = aid
        let stat = detail?.View.stat
        counts = [.like: stat?.like ?? 0, .coin: stat?.coin ?? 0, .favorite: stat?.favorite ?? 0]
        super.init()
        guard aid > 0 else { return }
        WebRequest.requestLikeStatus(aid: aid) { [weak self] value in
            DispatchQueue.main.async { self?.liked = value; self?.onStateChange?() }
        }
        WebRequest.requestCoinStatus(aid: aid) { [weak self] value in
            DispatchQueue.main.async { self?.coins = value; self?.onStateChange?() }
        }
        WebRequest.requestFavoriteStatus(aid: aid) { [weak self] value in
            DispatchQueue.main.async { self?.favorited = value; self?.onStateChange?() }
        }
    }

    deinit {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    private func isOn(_ kind: Kind) -> Bool {
        switch kind {
        case .like: return liked
        case .coin: return coins > 0
        case .favorite: return favorited
        }
    }

    func menuItems() -> [UIAction] {
        Kind.allCases.map { kind in
            let on = isOn(kind)
            let count = counts[kind] ?? 0
            let title = count > 0 ? "\(kind.title) \(count.numberString())" : kind.title
            return UIAction(title: title, image: UIImage(systemName: kind.image + (on ? ".fill" : "")),
                            identifier: kind.identifier, state: on ? .on : .off) { [weak self] _ in
                self?.perform(kind)
            }
        }
    }

    // MARK: attach

    func attach(to host: PlayerHost) {
        guard self.host !== host else { return }
        detach()
        self.host = host
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        gesture.minimumPressDuration = 0.8
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        host.hostViewController.view.addGestureRecognizer(gesture)
        longPress = gesture
        focusObserver = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            self?.focusedKind = context.nextFocusedView.flatMap { Self.kind(near: $0) }
        }
    }

    func detach() {
        if let longPress { longPress.view?.removeGestureRecognizer(longPress) }
        longPress = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        focusedKind = nil
    }

    /// The transport bar buttons are AVKit views; identify ours by the visible title.
    private static func kind(near view: UIView) -> Kind? {
        func match(_ text: String?) -> Kind? {
            guard let text else { return nil }
            return Kind.allCases.first { text.hasPrefix($0.title) }
        }
        func search(_ view: UIView, depth: Int) -> Kind? {
            if let found = match(view.accessibilityLabel) { return found }
            if let label = view as? UILabel, let found = match(label.text) { return found }
            guard depth > 0 else { return nil }
            for subview in view.subviews { if let found = search(subview, depth: depth - 1) { return found } }
            return nil
        }
        return search(view, depth: 4)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        focusedKind != nil
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, focusedKind != nil else { return }
        suppressActionsUntil = Date().addingTimeInterval(1.5)
        triple()
    }

    // MARK: actions

    private func perform(_ kind: Kind) {
        guard Date() >= suppressActionsUntil, aid > 0, !busy.contains(kind) else { return }
        switch kind {
        case .like: toggleLike()
        case .coin: askCoin()
        case .favorite: toggleFavorite()
        }
    }

    private func bump(_ kind: Kind, _ delta: Int) {
        counts[kind] = max(0, (counts[kind] ?? 0) + delta)
    }

    private func toggleLike() {
        busy.insert(.like)
        let next = !liked
        liked = next; bump(.like, next ? 1 : -1); onStateChange?()
        Task { @MainActor in
            let ok = await WebRequest.requestLike(aid: aid, like: next)
            if !ok { liked = !next; bump(.like, next ? -1 : 1) }
            busy.remove(.like); onStateChange?()
            if ok, next { VideoInteractionAnimationView.show(in: playerView, kinds: [.like], text: "已点赞") }
        }
    }

    private func askCoin() {
        guard coins < 2 else {
            VideoInteractionAnimationView.show(in: playerView, kinds: [], text: "已经投过 2 个硬币了")
            return
        }
        let alert = UIAlertController(title: "投币", message: "投币会同时点赞", preferredStyle: .actionSheet)
        for count in 1...(2 - coins) {
            alert.addAction(UIAlertAction(title: "投 \(count) 个", style: .default) { [weak self] _ in self?.coin(count) })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presenter()?.present(alert, animated: true)
    }

    private func coin(_ count: Int) {
        WebRequest.requestCoin(aid: aid, num: count)
        coins += count; bump(.coin, count)
        if !liked { liked = true; bump(.like, 1) }
        onStateChange?()
        VideoInteractionAnimationView.show(in: playerView, kinds: [.like, .coin], text: "投币成功")
    }

    private func toggleFavorite() {
        busy.insert(.favorite)
        Task { @MainActor in
            defer { busy.remove(.favorite) }
            guard let lists = try? await WebRequest.requestFavVideosList(), !lists.isEmpty else { return }
            if favorited {
                WebRequest.removeFavorite(aid: aid, mid: lists.map(\.id))
                favorited = false; bump(.favorite, -1); onStateChange?()
                return
            }
            let alert = UIAlertController(title: "收藏到", message: nil, preferredStyle: .actionSheet)
            for list in lists {
                alert.addAction(UIAlertAction(title: list.title, style: .default) { [weak self] _ in
                    guard let self else { return }
                    WebRequest.requestFavorite(aid: self.aid, mid: list.id)
                    self.favorited = true; self.bump(.favorite, 1); self.onStateChange?()
                    VideoInteractionAnimationView.show(in: self.playerView, kinds: [.favorite], text: "已收藏")
                })
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            presenter()?.present(alert, animated: true)
        }
    }

    private func triple() {
        guard aid > 0 else { return }
        VideoInteractionAnimationView.show(in: playerView, kinds: Kind.allCases, text: "一键三连中…", pending: true)
        Task { @MainActor in
            guard let result = await WebRequest.requestTriple(aid: aid) else {
                VideoInteractionAnimationView.show(in: playerView, kinds: [], text: "三连失败，请稍后再试")
                return
            }
            if result.like, !liked { liked = true; bump(.like, 1) }
            if result.coin, coins == 0 { coins = 2; bump(.coin, 2) }
            if result.favorite, !favorited { favorited = true; bump(.favorite, 1) }
            onStateChange?()
            let done = Kind.allCases.filter { isOn($0) }
            VideoInteractionAnimationView.show(in: playerView, kinds: done,
                                               text: done.count == 3 ? "一键三连成功！" : "三连完成 \(done.count)/3")
        }
    }

    private func presenter() -> UIViewController? {
        var top: UIViewController? = host?.hostViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// 居中毛玻璃胶囊：三个图标依次弹出 + 文案，约 1.6 秒后淡出。
final class VideoInteractionAnimationView: UIVisualEffectView {
    private static weak var current: VideoInteractionAnimationView?

    static func show(in host: UIView?, kinds: [VideoInteractionController.Kind], text: String, pending: Bool = false) {
        guard let host else { return }
        current?.removeFromSuperview()
        let view = VideoInteractionAnimationView(kinds: kinds, text: text, pending: pending)
        current = view
        host.addSubview(view)
        view.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.height.equalTo(kinds.isEmpty ? 120 : 220)
        }
        view.animateIn()
    }

    private let stack = UIStackView()
    private let icons: [UIImageView]
    private let label = UILabel()
    private let pending: Bool

    private init(kinds: [VideoInteractionController.Kind], text: String, pending: Bool) {
        self.pending = pending
        icons = kinds.map { kind in
            let view = UIImageView(image: UIImage(systemName: kind.image + ".fill"))
            view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
            view.tintColor = UIColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1)
            view.contentMode = .scaleAspectFit
            return view
        }
        super.init(effect: UIBlurEffect(style: .regular))
        isUserInteractionEnabled = false
        layer.cornerRadius = 44
        layer.cornerCurve = .continuous
        clipsToBounds = true
        let iconRow = UIStackView(arrangedSubviews: icons)
        iconRow.axis = .horizontal
        iconRow.spacing = 48
        label.text = text
        label.font = .systemFont(ofSize: 32, weight: .semibold)
        label.textColor = .label
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        if !icons.isEmpty { stack.addArrangedSubview(iconRow) }
        stack.addArrangedSubview(label)
        contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(64)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func animateIn() {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        icons.forEach { $0.transform = CGAffineTransform(scaleX: 0.2, y: 0.2); $0.alpha = 0 }
        UIView.animate(withDuration: 0.25) {
            self.alpha = 1
            self.transform = .identity
        }
        for (index, icon) in icons.enumerated() {
            UIView.animate(withDuration: 0.5, delay: 0.1 + Double(index) * 0.12, usingSpringWithDamping: 0.5,
                           initialSpringVelocity: 0.8, options: []) {
                icon.alpha = 1
                icon.transform = .identity
            }
        }
        if pending {
            UIView.animate(withDuration: 0.6, delay: 0.5, options: [.autoreverse, .repeat, .allowUserInteraction]) {
                self.icons.forEach { $0.alpha = 0.45 }
            }
            return
        }
        UIView.animate(withDuration: 0.4, delay: 1.6, options: []) {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
        } completion: { _ in
            self.removeFromSuperview()
        }
    }
}

// MARK: - 下滑面板：简介 / UP主视频 / 相关推荐 / 评论

final class VideoPlayerFeedInfoViewController: UIViewController {
    private enum Section: Hashable { case intro, episodes, uploader, related, comments }
    private enum Item: Hashable {
        case intro
        case video(Section, VideoPlayerDiscoveryInfoViewController.Entry)
        case comment(root: Int, child: Int?)
        case rootLoading(Int)
        case status(String)
    }

    var onSelect: ((PlayInfo) -> Void)?
    var onSelectEpisode: ((PlayInfo) -> Void)?

    private let aid: Int
    private var episodes = [VideoPlayerDiscoveryInfoViewController.Entry]()
    private var currentEpisode: Int?
    private let detail: VideoDetail?
    private var introExpanded = false
    private var uploaderVideos = [VideoPlayerDiscoveryInfoViewController.Entry]()
    private var relatedVideos = [VideoPlayerDiscoveryInfoViewController.Entry]()
    private var roots = [Replys.Reply]()
    private var fetchedChildren = [Int: [Replys.Reply]]()
    private var expanded = Set<Int>()
    private var loadingRoots = Set<Int>()
    private var page = 0
    private var hasMore = true
    private var isLoadingPage = false
    private var statusText = "评论加载中…"
    private var loadTasks = [Task<Void, Never>]()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, _ in
            let sections = self?.dataSource?.snapshot().sectionIdentifiers ?? []
            let section = sections.indices.contains(index) ? sections[index] : .comments
            return Self.layoutSection(for: section)
        }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.delegate = self
        view.remembersLastFocusedIndexPath = true
        view.register(RelatedVideoCell.self, forCellWithReuseIdentifier: String(describing: RelatedVideoCell.self))
        view.register(PlayerCommentCell.self, forCellWithReuseIdentifier: String(describing: PlayerCommentCell.self))
        view.register(PlayerIntroCell.self, forCellWithReuseIdentifier: String(describing: PlayerIntroCell.self))
        view.register(PlayerSectionHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: String(describing: PlayerSectionHeaderView.self))
        return view
    }()

    init(aid: Int, detail: VideoDetail?) {
        self.aid = aid
        self.detail = detail
        super.init(nibName: nil, bundle: nil)
        // AVKit 总会给面板显示一个标签胶囊（标题为空时显示成 application），无法去掉，直接写清楚内容。
        title = "推荐和评论"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTasks.forEach { $0.cancel() }
    }

    private static func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(52)),
                                                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    private static func layoutSection(for section: Section) -> NSCollectionLayoutSection {
        switch section {
        case .intro:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(200))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 48, bottom: 16, trailing: 48)
            return layoutSection
        case .episodes, .uploader, .related:
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(320), heightDimension: .absolute(248)), subitems: [item])
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 48, bottom: 24, trailing: 48)
            layoutSection.interGroupSpacing = 32
            layoutSection.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
            layoutSection.boundarySupplementaryItems = [header()]
            return layoutSection
        case .comments:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(150))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 48, bottom: 48, trailing: 48)
            layoutSection.interGroupSpacing = 16
            layoutSection.boundarySupplementaryItems = [header()]
            return layoutSection
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 0, height: 760)
        view.backgroundColor = .clear
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { $0.edges.equalToSuperview() }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            self?.cell(collectionView, indexPath: indexPath, item: item) ?? UICollectionViewCell()
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: String(describing: PlayerSectionHeaderView.self), for: indexPath) as! PlayerSectionHeaderView
            let sections = self?.dataSource.snapshot().sectionIdentifiers ?? []
            let section = sections.indices.contains(indexPath.section) ? sections[indexPath.section] : .comments
            header.label.text = self?.headerTitle(section)
            return header
        }
        applySnapshot(animated: false)
        loadNextPage()
    }

    func update(episodes: [VideoPlayerDiscoveryInfoViewController.Entry], current: Int?) {
        self.episodes = episodes
        currentEpisode = current
        if isViewLoaded { applySnapshot(animated: false) }
    }

    func update(uploader: [VideoPlayerDiscoveryInfoViewController.Entry]) {
        uploaderVideos = uploader
        if isViewLoaded { applySnapshot(animated: false) }
    }

    func update(related: [VideoPlayerDiscoveryInfoViewController.Entry]) {
        relatedVideos = related
        if isViewLoaded { applySnapshot(animated: false) }
    }

    private func headerTitle(_ section: Section) -> String {
        switch section {
        case .intro: return ""
        case .episodes: return "选集 · 共 \(episodes.count) 集"
        case .uploader: return "UP主 · \(detail?.View.owner.name ?? "") 的更多视频"
        case .related: return "相关推荐"
        case .comments: return "评论"
        }
    }

    // MARK: Data

    private func children(of root: Int) -> [Replys.Reply] {
        fetchedChildren[root] ?? roots[root].replies ?? []
    }

    private func replyCount(of root: Int) -> Int {
        max(roots[root].rcount ?? 0, roots[root].replies?.count ?? 0)
    }

    private func loadNextPage() {
        guard hasMore, !isLoadingPage, aid > 0 else { return }
        isLoadingPage = true
        let next = page + 1
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await WebRequest.requestReplys(aid: self.aid, page: next)
                guard !Task.isCancelled else { return }
                let items = result.replies ?? []
                self.page = next
                self.roots.append(contentsOf: items)
                self.hasMore = !items.isEmpty && next < 20
                self.statusText = self.roots.isEmpty ? "暂无评论" : ""
            } catch {
                guard !Task.isCancelled else { return }
                self.hasMore = false
                if self.roots.isEmpty { self.statusText = "评论加载失败" }
            }
            self.isLoadingPage = false
            self.applySnapshot(animated: false)
        }
        loadTasks.append(task)
    }

    private func toggle(root: Int) {
        guard replyCount(of: root) > 0 else { return }
        if expanded.contains(root) {
            expanded.remove(root)
            applySnapshot(animated: true)
            return
        }
        expanded.insert(root)
        let reply = roots[root]
        if fetchedChildren[root] == nil, let rpid = reply.rpid, replyCount(of: root) > (reply.replies?.count ?? 0) {
            loadingRoots.insert(root)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                if let result = try? await WebRequest.requestReplyReplies(aid: self.aid, root: rpid), let list = result.replies, !list.isEmpty {
                    self.fetchedChildren[root] = list
                }
                self.loadingRoots.remove(root)
                self.applySnapshot(animated: true)
            }
            loadTasks.append(task)
        }
        applySnapshot(animated: true)
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if detail != nil {
            snapshot.appendSections([.intro])
            snapshot.appendItems([.intro], toSection: .intro)
        }
        if episodes.count > 1 {
            snapshot.appendSections([.episodes])
            snapshot.appendItems(episodes.map { .video(.episodes, $0) }, toSection: .episodes)
        }
        if !uploaderVideos.isEmpty {
            snapshot.appendSections([.uploader])
            snapshot.appendItems(uploaderVideos.map { .video(.uploader, $0) }, toSection: .uploader)
        }
        if !relatedVideos.isEmpty {
            snapshot.appendSections([.related])
            snapshot.appendItems(relatedVideos.map { .video(.related, $0) }, toSection: .related)
        }
        snapshot.appendSections([.comments])
        var items = [Item]()
        if roots.isEmpty {
            items.append(.status(statusText.isEmpty ? "暂无评论" : statusText))
        }
        for index in roots.indices {
            items.append(.comment(root: index, child: nil))
            guard expanded.contains(index) else { continue }
            items.append(contentsOf: children(of: index).indices.map { .comment(root: index, child: $0) })
            if loadingRoots.contains(index) { items.append(.rootLoading(index)) }
        }
        if !roots.isEmpty, hasMore { items.append(.status("继续加载评论…")) }
        snapshot.appendItems(items, toSection: .comments)
        if animated {
            let shown = Set(dataSource.snapshot().itemIdentifiers)
            let roots = snapshot.itemIdentifiers(inSection: .comments).filter { item in
                guard shown.contains(item), case .comment(_, nil) = item else { return false }
                return true
            }
            snapshot.reconfigureItems(roots)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func cell(_ collectionView: UICollectionView, indexPath: IndexPath, item: Item) -> UICollectionViewCell {
        switch item {
        case .intro:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: PlayerIntroCell.self), for: indexPath) as! PlayerIntroCell
            if let detail { cell.configure(detail: detail, expanded: introExpanded) }
            return cell
        case let .video(_, entry):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: RelatedVideoCell.self), for: indexPath) as! RelatedVideoCell
            cell.update(data: entry.displayData)
            return cell
        case let .comment(root, child):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: PlayerCommentCell.self), for: indexPath) as! PlayerCommentCell
            if let child {
                let list = children(of: root)
                if list.indices.contains(child) { cell.configure(reply: list[child], isChild: true, footer: nil) }
            } else {
                let count = replyCount(of: root)
                let footer = count == 0 ? nil : expanded.contains(root) ? "▾ 收起 \(count) 条回复" : "▸ \(count) 条回复 · 按确定展开"
                cell.configure(reply: roots[root], isChild: false, footer: footer)
            }
            return cell
        case .rootLoading:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: PlayerCommentCell.self), for: indexPath) as! PlayerCommentCell
            cell.configure(status: "回复加载中…", isChild: true)
            return cell
        case let .status(text):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: PlayerCommentCell.self), for: indexPath) as! PlayerCommentCell
            cell.configure(status: text, isChild: false)
            return cell
        }
    }
}

extension VideoPlayerFeedInfoViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .intro:
            introExpanded.toggle()
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([.intro])
            dataSource.apply(snapshot, animatingDifferences: true)
        case let .video(section, entry):
            if section == .episodes { onSelectEpisode?(entry.playInfo) } else { onSelect?(entry.playInfo) }
        case let .comment(root, child):
            if child == nil { toggle(root: root) }
            else { expanded.remove(root); applySnapshot(animated: true) }
        case .status:
            loadNextPage()
        case .rootLoading:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if case .status? = dataSource.itemIdentifier(for: indexPath), !roots.isEmpty { loadNextPage() }
    }
}

final class PlayerSectionHeaderView: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 30, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        addSubview(label)
        label.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalToSuperview().inset(6)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PlayerIntroCell: UICollectionViewCell {
    private let background = UIView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let descLabel = UILabel()
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        background.layer.cornerRadius = 24
        background.layer.cornerCurve = .continuous
        contentView.addSubview(background)
        background.snp.makeConstraints { $0.edges.equalToSuperview() }
        titleLabel.font = .systemFont(ofSize: 36, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        metaLabel.font = .systemFont(ofSize: 24, weight: .medium)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        descLabel.font = .systemFont(ofSize: 26)
        descLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        hintLabel.font = .systemFont(ofSize: 22, weight: .medium)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        let stack = UIStackView(arrangedSubviews: [titleLabel, metaLabel, descLabel, hintLabel])
        stack.axis = .vertical
        stack.spacing = 12
        background.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 26, left: 32, bottom: 24, right: 32)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(detail: VideoDetail, expanded: Bool) {
        let info = detail.View
        titleLabel.text = info.title
        var meta = [info.owner.name, "\(info.stat.view.numberString())播放", "\(info.stat.danmaku.numberString())弹幕"]
        if let pubdate = info.pubdate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            meta.append(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(pubdate))))
        }
        if let bvid = info.bvid { meta.append(bvid) }
        metaLabel.text = meta.joined(separator: "  ·  ")
        let desc = (info.desc ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        descLabel.text = desc.isEmpty || desc == "-" ? "暂无简介" : desc
        descLabel.numberOfLines = expanded ? 0 : 2
        hintLabel.text = expanded ? "按确定收起" : "按确定展开简介"
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.background.backgroundColor = UIColor.white.withAlphaComponent(self.isFocused ? 0.22 : 0.08)
            self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.01, y: 1.01) : .identity
        }
    }
}

final class PlayerCommentCell: UICollectionViewCell {
    private let background = UIView()
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let contentLabel = UILabel()
    private let footerLabel = UILabel()
    private var leadingConstraint: Constraint?
    private var avatarSizeConstraint: Constraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        background.layer.cornerRadius = 16
        contentView.addSubview(background)
        background.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            leadingConstraint = make.leading.equalToSuperview().constraint
        }
        avatarView.layer.cornerRadius = 28
        avatarView.clipsToBounds = true
        avatarView.contentMode = .scaleAspectFill
        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        contentLabel.font = .systemFont(ofSize: 28)
        contentLabel.textColor = .white
        contentLabel.numberOfLines = 0
        footerLabel.font = .systemFont(ofSize: 22, weight: .medium)
        footerLabel.textColor = UIColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1)
        [avatarView, nameLabel, contentLabel, footerLabel].forEach(background.addSubview)
        avatarView.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(20)
            avatarSizeConstraint = make.width.height.equalTo(56).constraint
        }
        nameLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(18)
            make.leading.equalTo(avatarView.snp.trailing).offset(18)
            make.trailing.equalToSuperview().inset(24)
        }
        contentLabel.snp.makeConstraints { make in
            make.top.equalTo(nameLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(nameLabel)
        }
        footerLabel.snp.makeConstraints { make in
            make.top.equalTo(contentLabel.snp.bottom).offset(8)
            make.leading.trailing.equalTo(nameLabel)
            make.bottom.equalToSuperview().inset(18)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(reply: Replys.Reply, isChild: Bool, footer: String?) {
        leadingConstraint?.update(offset: isChild ? 96 : 0)
        avatarSizeConstraint?.update(offset: isChild ? 44 : 56)
        avatarView.layer.cornerRadius = isChild ? 22 : 28
        avatarView.isHidden = false
        avatarView.kf.setImage(with: URL(string: reply.member.avatar),
                               options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 112, height: 112))), .cacheOriginalImage])
        let likes = (reply.like ?? 0) > 0 ? "  ·  👍 \(reply.like!)" : ""
        nameLabel.text = reply.member.uname + likes
        contentLabel.font = .systemFont(ofSize: isChild ? 25 : 28)
        contentLabel.numberOfLines = isChild ? 4 : 8
        if let attr = reply.createAttributedString(displayView: contentLabel) {
            contentLabel.attributedText = attr
        } else {
            contentLabel.text = reply.content.message
        }
        footerLabel.text = footer
        footerLabel.isHidden = footer == nil
    }

    func configure(status: String, isChild: Bool) {
        leadingConstraint?.update(offset: isChild ? 96 : 0)
        avatarSizeConstraint?.update(offset: 0)
        avatarView.isHidden = true
        avatarView.image = nil
        nameLabel.text = nil
        contentLabel.attributedText = nil
        contentLabel.text = status
        contentLabel.font = .systemFont(ofSize: 26)
        footerLabel.text = nil
        footerLabel.isHidden = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.kf.cancelDownloadTask()
        avatarView.image = nil
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            self.background.backgroundColor = UIColor.white.withAlphaComponent(self.isFocused ? 0.28 : 0.08)
            self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.015, y: 1.015) : .identity
        }
    }
}
