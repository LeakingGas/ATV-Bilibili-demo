//
//  VideoQuickActionMenu.swift
//  BilibiliLive
//
//  视频快捷操作菜单：加入/移出稍后再看、收藏视频、不感兴趣（只有首页推荐的视频有）。
//  经典 Feed（FeedCollectionViewController）与沉浸式 Feed（FeedFlowBrowserViewController）共用。
//

import SwiftyJSON
import UIKit

@MainActor
final class VideoQuickActionMenu {
    static let shared = VideoQuickActionMenu()

    /// 本次运行中通过快捷菜单成功加入稍后再看的视频
    private var addedToViewAids = Set<Int>()
    private var inFlightAids = Set<Int>()

    private init() {}

    /// - dislike: 首页推荐的「不感兴趣」目标；nil 时不提供这一项（别的列表没有这个接口）。
    /// - onDisliked: 不感兴趣提交成功后调用（列表据此去掉这个视频）。失败会弹出错误，视频留在列表里。
    func present(aid: Int, title: String?, dislike: RecommendDislike? = nil, onDisliked: (() -> Void)? = nil, from presenter: UIViewController) {
        guard aid > 0 else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

        if addedToViewAids.contains(aid) {
            alert.addAction(UIAlertAction(title: "移出稍后再看", style: .destructive) { [weak self, weak presenter] _ in
                self?.removeFromToView(aid: aid, presenter: presenter)
            })
        } else {
            alert.addAction(UIAlertAction(title: "加入稍后再看", style: .default) { [weak self, weak presenter] _ in
                self?.addToView(aid: aid, presenter: presenter)
            })
        }

        alert.addAction(UIAlertAction(title: "收藏视频", style: .default) { [weak self, weak presenter] _ in
            self?.favorite(aid: aid, presenter: presenter)
        })

        if let dislike {
            alert.addAction(UIAlertAction(title: "不感兴趣", style: .default) { [weak self, weak presenter] _ in
                self?.submitDislike(dislike, aid: aid, presenter: presenter, onDisliked: onDisliked)
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presenter.present(alert, animated: true)
    }

    // MARK: - 稍后再看

    private func addToView(aid: Int, presenter: UIViewController?) {
        guard !inFlightAids.contains(aid) else { return }
        inFlightAids.insert(aid)
        Task { [weak self] in
            do {
                try await WebRequest.requestAddToView(aid: aid)
                self?.inFlightAids.remove(aid)
                self?.addedToViewAids.insert(aid)
            } catch let err {
                self?.inFlightAids.remove(aid)
                self?.showError(title: "加入稍后再看失败", error: err, presenter: presenter)
            }
        }
    }

    private func removeFromToView(aid: Int, presenter: UIViewController?) {
        guard !inFlightAids.contains(aid) else { return }
        inFlightAids.insert(aid)
        Task { [weak self] in
            do {
                try await WebRequest.requestRemoveToView(aid: aid)
                self?.inFlightAids.remove(aid)
                self?.addedToViewAids.remove(aid)
            } catch let err {
                self?.inFlightAids.remove(aid)
                self?.showError(title: "移出稍后再看失败", error: err, presenter: presenter)
            }
        }
    }

    // MARK: - 不感兴趣

    private func submitDislike(_ dislike: RecommendDislike, aid: Int, presenter: UIViewController?, onDisliked: (() -> Void)?) {
        let finish: (Result<JSON, RequestError>) -> Void = { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success:
                    Diag.mark("FEED dislike aid=\(aid) \(dislike.logText) ok")
                    onDisliked?()
                case let .failure(error):
                    Diag.mark("FEED dislike aid=\(aid) \(dislike.logText) failed \(error)")
                    self?.showError(title: "不感兴趣提交失败", error: error, presenter: presenter)
                }
            }
        }
        switch dislike {
        case let .app(goto, id, reasons):
            // 「不感兴趣」对应的原因：名字是「不感兴趣」的那一项，没有就用 id 1。
            guard let reason = reasons.first(where: { $0.name?.contains("不感兴趣") == true }) ?? reasons.first(where: { $0.id == 1 }) else {
                let list = reasons.map { "\($0.id):\($0.name ?? "")" }.joined(separator: ",")
                Diag.mark("FEED dislike aid=\(aid) no reason in [\(list)]")
                showError(title: "不感兴趣提交失败", error: RequestError.statusFail(code: -1, message: "这条推荐没有「不感兴趣」选项（\(list)）"), presenter: presenter)
                return
            }
            ApiRequest.requestFeedDislike(goto: goto, id: id, reasonID: reason.id, complete: finish)
        case let .web(aid, mid, trackID):
            WebRequest.requestRecommendDislike(aid: aid, mid: mid, trackID: trackID, complete: finish)
        }
    }

    // MARK: - 收藏

    private func favorite(aid: Int, presenter: UIViewController?) {
        Task { [weak self, weak presenter] in
            let favList: [FavListData]
            do {
                favList = try await WebRequest.requestFavVideosList()
            } catch let err {
                self?.showError(title: "获取收藏夹失败", error: err, presenter: presenter)
                return
            }
            guard let presenter, presenter.viewIfLoaded?.window != nil else { return }
            let alert = UIAlertController(title: "收藏", message: nil, preferredStyle: .actionSheet)
            for fav in favList {
                alert.addAction(UIAlertAction(title: fav.title, style: .default) { _ in
                    WebRequest.requestFavorite(aid: aid, mid: fav.id)
                })
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            presenter.present(alert, animated: true)
        }
    }

    // MARK: - Helper

    private func showError(title: String, error: Error, presenter: UIViewController?) {
        guard let presenter, presenter.viewIfLoaded?.window != nil else { return }
        var message = "\(error)"
        if let requestError = error as? RequestError,
           case let .statusFail(code, msg) = requestError
        {
            message = "\(msg) (\(code))"
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ok", style: .cancel))
        presenter.present(alert, animated: true)
    }
}

/// 首页推荐「不感兴趣」要提交的内容（App 推荐和网页推荐是两个接口）。
enum RecommendDislike: Hashable {
    case app(goto: String, id: Int, reasons: [ApiRequest.FeedResp.ThreePoint.Reason])
    case web(aid: Int, mid: Int, trackID: String)

    var logText: String {
        switch self {
        case let .app(goto, id, reasons): return "app goto=\(goto) id=\(id) reasons=\(reasons.map(\.id))"
        case let .web(_, mid, trackID): return "web mid=\(mid) track=\(trackID)"
        }
    }
}

extension WebRequest {
    /// POST /x/v2/history/toview/add，参数 aid + csrf（csrf 由 requestData 自动附带）
    static func requestAddToView(aid: Int) async throws {
        _ = try await requestJSON(method: .post,
                                  url: "https://api.bilibili.com/x/v2/history/toview/add",
                                  parameters: ["aid": aid])
    }

    /// POST /x/v2/history/toview/del，参数 aid + csrf
    static func requestRemoveToView(aid: Int) async throws {
        _ = try await requestJSON(method: .post,
                                  url: "https://api.bilibili.com/x/v2/history/toview/del",
                                  parameters: ["aid": aid])
    }
}
