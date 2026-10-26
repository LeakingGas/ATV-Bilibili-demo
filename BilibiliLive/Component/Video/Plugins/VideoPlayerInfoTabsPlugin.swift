//
//  VideoPlayerInfoTabsPlugin.swift
//  BilibiliLive
//
//  Created by OpenAI on 2026/4/5.
//

import AVKit
import Kingfisher
import SnapKit
import UIKit

final class VideoPlayerInfoTabsPlugin: NSObject, CommonPlayerPlugin {
    private enum DiscoverySource {
        case uploader
        case related

        var tabTitle: String {
            switch self {
            case .uploader:
                return "博主视频"
            case .related:
                return "相关视频"
            }
        }

        var emptyText: String {
            switch self {
            case .uploader:
                return "当前没有可展示的博主视频"
            case .related:
                return "当前没有可展示的相关视频"
            }
        }
    }

    var onSelectDiscovery: ((PlayInfo) -> Void)?

    private let currentPlayInfo: PlayInfo
    private let sequenceProvider: VideoSequenceProvider?
    private let uploaderInfoViewController = VideoPlayerDiscoveryInfoViewController(title: DiscoverySource.uploader.tabTitle,
                                                                                    emptyText: DiscoverySource.uploader.emptyText)
    private let relatedInfoViewController = VideoPlayerDiscoveryInfoViewController(title: DiscoverySource.related.tabTitle,
                                                                                   emptyText: DiscoverySource.related.emptyText)
    private let actionInfoViewController: VideoPlayerActionInfoViewController
    private let feedInfoViewController: VideoPlayerFeedInfoViewController
    private let relatedCandidates: [PlayInfo]
    private let ownerMid: Int
    private var uploaderEntries = [PlayInfo]()
    private var uploaderLoadTask: Task<Void, Never>?
    private weak var playerVC: AVPlayerViewController?

    init(detail: VideoDetail?, currentPlayInfo: PlayInfo, sequenceProvider: VideoSequenceProvider?) {
        self.currentPlayInfo = currentPlayInfo
        self.sequenceProvider = sequenceProvider
        ownerMid = detail?.View.owner.mid ?? 0
        relatedCandidates = Self.makeRelatedEntries(detail: detail, currentPlayInfo: currentPlayInfo)
        actionInfoViewController = VideoPlayerActionInfoViewController(detail: detail)
        feedInfoViewController = VideoPlayerFeedInfoViewController(aid: currentPlayInfo.aid)
        super.init()

        let onSelect: (PlayInfo) -> Void = { [weak self] playInfo in
            guard let self else { return }
            let currentSequenceKey = self.sequenceProvider.flatMap { provider in
                MainActor.assumeIsolated {
                    provider.current()?.sequenceKey
                }
            } ?? self.currentPlayInfo.sequenceKey
            guard currentSequenceKey != playInfo.sequenceKey else { return }
            self.onSelectDiscovery?(playInfo)
        }
        uploaderInfoViewController.onSelect = onSelect
        relatedInfoViewController.onSelect = onSelect
        feedInfoViewController.onSelect = onSelect
        refreshDiscoveryTabs()
        loadUploaderEntriesIfNeeded()
    }

    deinit {
        uploaderLoadTask?.cancel()
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        refreshCustomInfoViewControllers()
    }

    func playerDidDismiss(playerVC: AVPlayerViewController) {
        removeCustomInfoViewControllers()
        uploaderLoadTask?.cancel()
        uploaderLoadTask = nil
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        removeCustomInfoViewControllers()
        uploaderLoadTask?.cancel()
        uploaderLoadTask = nil
    }

    private func loadUploaderEntriesIfNeeded() {
        guard ownerMid > 0 else { return }
        uploaderLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let records = try await ApiRequest.requestUpSpaceVideo(mid: self.ownerMid, lastAid: nil, pageSize: 18)
                guard !Task.isCancelled else { return }

                var seenAids = Set<Int>()
                let entries = records.compactMap { record -> PlayInfo? in
                    guard record.aid > 0,
                          record.aid != self.currentPlayInfo.aid,
                          seenAids.insert(record.aid).inserted
                    else {
                        return nil
                    }
                    return PlayInfo(aid: record.aid,
                                    title: record.title,
                                    ownerName: record.ownerName,
                                    coverURL: record.pic)
                }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.uploaderEntries = Array(entries.prefix(6))
                    self.refreshDiscoveryTabs()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.uploaderEntries = []
                    self.refreshDiscoveryTabs()
                }
            }
        }
    }

    private func refreshDiscoveryTabs() {
        uploaderInfoViewController.update(entries: uploaderEntries.prefix(6).map(makeViewEntry(from:)))
        relatedInfoViewController.update(entries: relatedCandidates.prefix(6).map(makeViewEntry(from:)))
        feedInfoViewController.update(videos: relatedCandidates.prefix(20).map(makeViewEntry(from:)))
    }

    private func makeViewEntry(from playInfo: PlayInfo) -> VideoPlayerDiscoveryInfoViewController.Entry {
        VideoPlayerDiscoveryInfoViewController.Entry(playInfo: playInfo,
                                                     displayData: VideoPlayerDiscoveryInfoViewController.DiscoveryDisplayData(title: playInfo.title ?? "",
                                                                                                                              ownerName: playInfo.ownerName ?? "",
                                                                                                                              pic: playInfo.coverURL))
    }

    private func refreshCustomInfoViewControllers() {
        guard let playerVC else { return }
        var controllers = playerVC.customInfoViewControllers.filter {
            $0 !== uploaderInfoViewController &&
                $0 !== relatedInfoViewController &&
                $0 !== actionInfoViewController &&
                $0 !== feedInfoViewController
        }
        // 下滑第一个面板：推荐 + 评论（相关视频已并入其中）。
        controllers.insert(feedInfoViewController, at: 0)
        controllers.append(uploaderInfoViewController)
        controllers.append(actionInfoViewController)
        playerVC.customInfoViewControllers = controllers
    }

    private func removeCustomInfoViewControllers() {
        guard let playerVC else { return }
        playerVC.customInfoViewControllers.removeAll {
            $0 === uploaderInfoViewController ||
                $0 === relatedInfoViewController ||
                $0 === actionInfoViewController ||
                $0 === feedInfoViewController
        }
    }

    private static func makeRelatedEntries(detail: VideoDetail?, currentPlayInfo: PlayInfo) -> [PlayInfo] {
        let related = detail?.Related ?? []
        var seenAids = Set<Int>()
        return related.compactMap { info -> PlayInfo? in
            guard info.aid > 0,
                  info.aid != currentPlayInfo.aid,
                  seenAids.insert(info.aid).inserted
            else {
                return nil
            }

            return PlayInfo(aid: info.aid,
                            cid: info.cid,
                            title: info.title,
                            ownerName: info.ownerName,
                            coverURL: info.pic)
        }
    }
}

// MARK: - 推荐与评论（播放界面下滑面板）

/// 第一行：相关推荐（横向）；往下：评论列表。带回复的评论按「确定」展开 / 收起楼中楼。
final class VideoPlayerFeedInfoViewController: UIViewController {
    private enum Section: Hashable { case videos, comments }
    private enum Item: Hashable {
        case video(VideoPlayerDiscoveryInfoViewController.Entry)
        case comment(root: Int, child: Int?)
        case rootLoading(Int)
        case status(String)
    }

    var onSelect: ((PlayInfo) -> Void)?

    private let aid: Int
    private var videos = [VideoPlayerDiscoveryInfoViewController.Entry]()
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
            switch section {
            case .videos:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(320), heightDimension: .absolute(248)), subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 24, leading: 32, bottom: 24, trailing: 32)
                layoutSection.interGroupSpacing = 28
                layoutSection.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
                return layoutSection
            case .comments:
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(150))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 48, bottom: 40, trailing: 48)
                layoutSection.interGroupSpacing = 14
                return layoutSection
            }
        }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.delegate = self
        view.remembersLastFocusedIndexPath = true
        view.register(RelatedVideoCell.self, forCellWithReuseIdentifier: String(describing: RelatedVideoCell.self))
        view.register(PlayerCommentCell.self, forCellWithReuseIdentifier: String(describing: PlayerCommentCell.self))
        return view
    }()

    init(aid: Int) {
        self.aid = aid
        super.init(nibName: nil, bundle: nil)
        title = "推荐·评论"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTasks.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 0, height: 720)
        view.backgroundColor = .clear
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { $0.edges.equalToSuperview() }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            self?.cell(collectionView, indexPath: indexPath, item: item) ?? UICollectionViewCell()
        }
        applySnapshot(animated: false)
        loadNextPage()
    }

    func update(videos: [VideoPlayerDiscoveryInfoViewController.Entry]) {
        self.videos = videos
        if isViewLoaded { applySnapshot(animated: false) }
    }

    // MARK: Data

    private func children(of root: Int) -> [Replys.Reply] {
        fetchedChildren[root] ?? roots[root].replies ?? []
    }

    private func replyCount(of root: Int) -> Int {
        max(roots[root].rcount ?? 0, roots[root].replies?.count ?? 0)
    }

    private func loadNextPage() {
        guard hasMore, !isLoadingPage else { return }
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
        if !videos.isEmpty {
            snapshot.appendSections([.videos])
            snapshot.appendItems(videos.map { .video($0) }, toSection: .videos)
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
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func cell(_ collectionView: UICollectionView, indexPath: IndexPath, item: Item) -> UICollectionViewCell {
        switch item {
        case let .video(entry):
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
        case let .video(entry):
            onSelect?(entry.playInfo)
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
