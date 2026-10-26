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
        case let .web(item):
            // 与 App 推荐一致：优先推荐理由，否则显示发布时间（相对时间）。
            if let reason = item.rcmd_reason?.content, !reason.isEmpty { return reason }
            return item.pubdate.map { Self.relativeDate($0) }
        }
    }

    /// 两个接口统一成同一种格式：▶ 播放量  ≡ 弹幕数  时长（数字不带文字，由卡片统一补「观看 / 弹幕」）。
    var overlay: DisplayOverlay? {
        var views: String?, danmaku: String?, duration: String?
        switch source {
        case let .app(item):
            // App 接口这几格的含义和顺序不固定：按内容归类。
            let texts = [item.cover_left_text_1, item.cover_left_text_2, item.cover_left_text_3, item.cover_right_text]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for text in texts {
                if text.range(of: #"^\d{1,3}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
                    duration = duration ?? text
                } else if text.contains("弹幕") {
                    danmaku = danmaku ?? Self.number(in: text)
                } else if text.contains("观看") || text.contains("播放") {
                    views = views ?? Self.number(in: text)
                } else if text.range(of: #"^[\d.,]+[万亿]?$"#, options: .regularExpression) != nil {
                    if views == nil { views = text } else if danmaku == nil { danmaku = text }
                }
            }
        case let .web(item):
            views = item.stat?.view.map { $0.numberString() }
            danmaku = item.stat?.danmaku.map { $0.numberString() }
            if let seconds = item.duration, seconds > 0 {
                duration = seconds >= 3600
                    ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
                    : String(format: "%02d:%02d", seconds / 60, seconds % 60)
            }
        }
        var left = [DisplayOverlay.DisplayOverlayItem]()
        if let views { left.append(DisplayOverlay.DisplayOverlayItem(icon: "play.rectangle", text: views)) }
        if let danmaku { left.append(DisplayOverlay.DisplayOverlayItem(icon: "list.bullet.rectangle", text: danmaku)) }
        let right = duration.map { [DisplayOverlay.DisplayOverlayItem(icon: nil, text: $0)] } ?? []
        guard !left.isEmpty || !right.isEmpty else { return nil }
        return DisplayOverlay(leftItems: left, rightItems: right)
    }

    private static func number(in text: String) -> String {
        text.replacingOccurrences(of: "观看", with: "").replacingOccurrences(of: "播放", with: "")
            .replacingOccurrences(of: "弹幕", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func relativeDate(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 3600 { return "\(max(1, Int(elapsed / 60)))分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))小时前" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
}
