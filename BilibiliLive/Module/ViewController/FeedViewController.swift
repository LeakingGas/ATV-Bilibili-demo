//
//  FeedViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2021/5/19.
//
//  推荐页（网格模式）。来源可在设置里切换：App / 网页 / 网页旧接口 / 混合。
//

import UIKit

class FeedViewController: StandardVideoCollectionViewController<RecommendFeedItem> {
    private var source = Settings.recommendSource
    private var appLastIdx: Int?
    private var webPage = 0
    private var seenAids = Set<Int>()

    override func setupCollectionView() {
        super.setupCollectionView()
        collectionVC.pageSize = 1
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 设置里换了推荐来源：重新加载。
        if source != Settings.recommendSource {
            source = Settings.recommendSource
            reloadData()
        }
    }

    override func supportVideoQuickActions() -> Bool {
        return true
    }

    override func request(page: Int) async throws -> [RecommendFeedItem] {
        if page == 1 {
            appLastIdx = nil
            webPage = 0
            seenAids.removeAll()
        }
        let items: [RecommendFeedItem]
        switch source {
        case .app:
            items = try await nextApp()
        case .web:
            items = try await nextWeb(legacy: false)
        case .webLegacy:
            items = try await nextWeb(legacy: true)
        case .mixed:
            async let app = try? nextApp()
            async let web = try? nextWeb(legacy: false)
            let (a, w) = await (app ?? [], web ?? [])
            if a.isEmpty, w.isEmpty { throw NSError(domain: "推荐加载失败", code: -1) }
            var mixed = [RecommendFeedItem]()
            for index in 0..<max(a.count, w.count) {
                if index < a.count { mixed.append(a[index]) }
                if index < w.count { mixed.append(w[index]) }
            }
            items = mixed
        }
        return items.filter { $0.aid > 0 && seenAids.insert($0.aid).inserted }
    }

    private func nextApp() async throws -> [RecommendFeedItem] {
        let feeds: [ApiRequest.FeedResp.Items]
        if let appLastIdx {
            feeds = try await ApiRequest.getFeeds(lastIdx: appLastIdx)
        } else {
            feeds = try await ApiRequest.getFeeds()
        }
        if let last = feeds.last?.idx { appLastIdx = last }
        return feeds.filter { $0.goto == "av" }.map { RecommendFeedItem(source: .app($0)) }
    }

    private func nextWeb(legacy: Bool) async throws -> [RecommendFeedItem] {
        webPage += 1
        let response = legacy
            ? try await WebRequest.requestTopFeedRecommendLegacy(pageIndex: webPage, pageSize: 24)
            : try await WebRequest.requestTopFeedRecommend(pageIndex: webPage, pageSize: 24)
        return response.item.filter { ($0.goto ?? "av") == "av" && ($0.id ?? 0) > 0 }.map { RecommendFeedItem(source: .web($0)) }
    }
}

extension ApiRequest.FeedResp.Items: PlayableData {
    var aid: Int { Int(param) ?? 0 }
    var cid: Int { player_args?.cid ?? 0 }
}

/// 统一不同推荐接口的条目。
struct RecommendFeedItem: PlayableData {
    enum Source: Hashable {
        case app(ApiRequest.FeedResp.Items)
        case web(WebTopFeedRecommendResponse.Item)
    }

    let source: Source

    var aid: Int {
        switch source {
        case let .app(item): return item.aid
        case let .web(item): return item.id ?? 0
        }
    }

    var cid: Int {
        switch source {
        case let .app(item): return item.cid
        case let .web(item): return item.cid ?? 0
        }
    }

    var title: String {
        switch source {
        case let .app(item): return item.title
        case let .web(item): return item.title ?? ""
        }
    }

    var ownerName: String {
        switch source {
        case let .app(item): return item.ownerName
        case let .web(item): return item.owner?.name ?? ""
        }
    }

    var pic: URL? {
        switch source {
        case let .app(item): return item.pic
        case let .web(item): return item.pic.flatMap { URL(string: $0) }
        }
    }

    var avatar: URL? {
        switch source {
        case let .app(item): return item.avatar
        case let .web(item): return item.owner?.face.flatMap { URL(string: $0) }
        }
    }

    var date: String? {
        switch source {
        case let .app(item): return item.date
        case let .web(item): return item.rcmd_reason?.content
        }
    }

    var overlay: DisplayOverlay? {
        switch source {
        case let .app(item):
            return item.overlay
        case let .web(item):
            var left = [DisplayOverlay.DisplayOverlayItem]()
            if let view = item.stat?.view { left.append(DisplayOverlay.DisplayOverlayItem(icon: "play.rectangle", text: view.numberString())) }
            if let danmaku = item.stat?.danmaku { left.append(DisplayOverlay.DisplayOverlayItem(icon: "list.bullet.rectangle", text: danmaku.numberString())) }
            var right = [DisplayOverlay.DisplayOverlayItem]()
            if let duration = item.duration, duration > 0 {
                let text = duration >= 3600
                    ? String(format: "%d:%02d:%02d", duration / 3600, duration % 3600 / 60, duration % 60)
                    : String(format: "%02d:%02d", duration / 60, duration % 60)
                right.append(DisplayOverlay.DisplayOverlayItem(icon: nil, text: text))
            }
            return DisplayOverlay(leftItems: left, rightItems: right)
        }
    }
}
