//
//  Settings.swift
//  BilibiliLive
//
//  Created by whw on 2022/10/19.
//

import Combine
import Foundation
import SwiftUI

enum FeedDisplayStyle: Codable, CaseIterable {
    case large
    case normal
    case sideBar

    var hideInSetting: Bool {
        self == .sideBar
    }
}

class Defaults {
    static let shared = Defaults()
    private init() {}

    @Published(key: "Settings.danmuStatus") var showDanmu = true
}

enum Settings {
    @UserDefaultCodable("Settings.displayStyle", defaultValue: .normal)
    static var displayStyle: FeedDisplayStyle

    /// 进入有观看记录的视频时，询问「继续播放 / 从头播放」。关闭后直接续播。
    @UserDefault("Settings.resumePrompt", defaultValue: true)
    static var resumePrompt: Bool

    // v2：默认 4K（新键名，让已有安装也换成新默认值）。
    @UserDefaultCodable("Settings.mediaQuality.v2", defaultValue: .quality_2160p)
    static var mediaQuality: MediaQualityEnum

    @UserDefaultCodable("Settings.mediaPlayerSpeed", defaultValue: PlaySpeed.default)
    static var mediaPlayerSpeed: PlaySpeed

    @UserDefaultCodable("Settings.danmuArea", defaultValue: .style_75)
    static var danmuArea: DanmuArea

    @UserDefaultCodable("Settings.danmuSize", defaultValue: .size_36)
    static var danmuSize: DanmuSize

    @UserDefaultCodable("Settings.danmuAILevel", defaultValue: 1)
    static var danmuAILevel: Int32

    @UserDefaultCodable("Settings.danmuDuration", defaultValue: 8)
    static var danmuDuration: Double

    @UserDefault("Settings.losslessAudio", defaultValue: false)
    static var losslessAudio: Bool

    // v2：默认 AVC 优先。同一画质下 B 站的 AVC 码率常常是 HEVC 的数倍，画质明显更好。
    @UserDefault("Settings.preferAvc.v2", defaultValue: true)
    static var preferAvc: Bool

    /// 诊断导出地址固定（端口 8765、无随机路径）还是每次随机。
    @UserDefault("Settings.fixedExportAddress", defaultValue: false)
    static var fixedExportAddress: Bool

    /// 列表里焦点所在的那一行：同时预载每个视频的播放地址和第一段，点开更快。
    @UserDefault("Settings.prefetchRow", defaultValue: true)
    static var prefetchRow: Bool

    /// 快速起播：起播时不等缓冲，数据一到就出画面；开始播放后恢复正常缓冲（快进、卡顿按系统默认方式等数据）。
    /// 键名沿用旧的「边下边播」，已开启的用户不受影响。
    @UserDefault("Settings.playWithoutWaiting", defaultValue: false)
    static var playWithoutWaiting: Bool

    /// 试验：用 VLC 引擎播放（不支持杜比视界 / HDR、画中画、画质切换，需要时关掉切回系统播放器）。
    /// 播放器：系统 / VLC / 自动（有杜比视界用系统，其余 VLC）。
    @UserDefaultCodable("Settings.playerEngine", defaultValue: .system)
    static var playerEngine: PlayerEngineChoice

    /// BTR CDN node expansion region (cdn-resolver.js). Default overseas: this port targets overseas Apple TVs.
    @UserDefaultCodable("Settings.btrNodeRegion", defaultValue: .overseas)
    static var btrNodeRegion: BTRNodeRegion

    @UserDefault("Settings.multiCDNEnabled", defaultValue: false)
    static var multiCDNEnabled: Bool

    @UserDefault("Settings.danmuMask", defaultValue: true)
    static var danmuMask: Bool

    @UserDefault("Settings.vnMask", defaultValue: false)
    static var vnMask: Bool

    @UserDefault("Settings.loadHighestVideoOnly", defaultValue: false)
    static var loadHighestVideoOnly: Bool

    @UserDefault("Settings.contentMatch", defaultValue: true)
    static var contentMatch: Bool

    @UserDefault("Settings.contentMatchOnlyInHDR", defaultValue: true)
    static var contentMatchOnlyInHDR: Bool

    @UserDefault("Settings.continuePlay", defaultValue: true)
    static var continuePlay: Bool

    @UserDefault("DLNA.uuid", defaultValue: "")
    static var uuid: String

    @UserDefault("DLNA.enable", defaultValue: true)
    static var enableDLNA: Bool

    @UserDefault("Settings.continouslyPlay", defaultValue: false)
    static var continouslyPlay: Bool

    @UserDefault("Settings.loopPlay", defaultValue: false)
    static var loopPlay: Bool

    @UserDefault("Settings.play.autoSkip", defaultValue: true)
    static var autoSkip: Bool

    @UserDefault("Settings.requestHotWithoutCookie", defaultValue: false)
    static var requestHotWithoutCookie: Bool

    @UserDefault("Settings.arealimit.unlock", defaultValue: false)
    static var areaLimitUnlock: Bool

    @UserDefault("Settings.arealimit.customServer", defaultValue: "")
    static var areaLimitCustomServer: String

    @UserDefault("Settings.ui.sideMenuAutoSelectChange", defaultValue: false)
    static var sideMenuAutoSelectChange: Bool

    @UserDefaultCodable("Settings.featuredDurationLimit", defaultValue: .minutes10)
    static var featuredDurationLimit: FeaturedDurationLimit

    /// 推荐页内容来源（普通网格模式）。
    @UserDefaultCodable("Settings.recommendSource", defaultValue: .app)
    static var recommendSource: RecommendSource

    @UserDefault("Settings.recommendFeedFlowEnabled", defaultValue: false)
    static var recommendFeedFlowEnabled: Bool

    @UserDefault("Settings.featuredContentSafetyFilterEnabled", defaultValue: true)
    static var featuredContentSafetyFilterEnabled: Bool

    @UserDefault("Settings.followsFeedFlowEnabled", defaultValue: false)
    static var followsFeedFlowEnabled: Bool

    @UserDefaultCodable("Settings.SponsorBlockType", defaultValue: SponsorBlockType.none)
    static var enableSponsorBlock: SponsorBlockType

    @UserDefault("Settings.danmuFilter", defaultValue: false)
    static var enableDanmuFilter: Bool

    @UserDefault("Settings.danmuRemoveDup", defaultValue: false)
    static var enableDanmuRemoveDup: Bool

    @UserDefaultCodable("Settings.danmuAlpha", defaultValue: .alpha_10)
    static var danmuAlpha: DanmuAlpha

    @UserDefaultCodable("Settings.danmuStrokeWidth", defaultValue: .width_20)
    static var danmuStrokeWidth: DanmuStrokeWidth

    @UserDefaultCodable("Settings.danmuStrokeAlpha", defaultValue: .alpha_08)
    static var danmuStrokeAlpha: DanmuStrokeAlpha

    @UserDefaultCodable("Search.histories", defaultValue: [])
    static var searchHistories: [String]
}

extension Settings {
    static func addHistory(_ query: String, limitSize: Int = 6) {
        if query.isEmpty {
            return
        }

        var histories = Settings.searchHistories
        if histories.first == query {
            return
        }

        if let i = histories.firstIndex(of: query) {
            histories.remove(at: i)
        }

        histories.insert(query, at: 0)
        if histories.count > limitSize {
            histories.removeLast()
        }
        Settings.searchHistories = histories
    }

    static func clearHistory() {
        Settings.searchHistories = []
    }
}

struct MediaQuality {
    var qn: Int
    var fnval: Int
}

enum SponsorBlockType: String, Codable, CaseIterable {
    case none
    case jump
    case tip

    var title: String {
        switch self {
        case .none:
            return "关"
        case .jump:
            return "自动跳过"
        case .tip:
            return "手动跳过"
        }
    }
}

enum DanmuArea: Codable, CaseIterable {
    case style_75
    case style_50
    case style_25
    case style_0
}

enum DanmuSize: String, Codable, CaseIterable {
    case size_25
    case size_31
    case size_36
    case size_42
    case size_48
    case size_57

    var title: String {
        return "\(Int(size)) pt"
    }

    var size: CGFloat {
        switch self {
        case .size_25:
            return 25
        case .size_31:
            return 31
        case .size_36:
            return 36
        case .size_42:
            return 42
        case .size_48:
            return 48
        case .size_57:
            return 57
        }
    }
}

enum DanmuAlpha: Double, Codable, CaseIterable {
    case alpha_03 = 0.3
    case alpha_04 = 0.4
    case alpha_05 = 0.5
    case alpha_06 = 0.6
    case alpha_07 = 0.7
    case alpha_08 = 0.8
    case alpha_09 = 0.9
    case alpha_10 = 1.0

    var title: String {
        return String(format: "%.1f", rawValue)
    }
}

enum DanmuStrokeWidth: Double, Codable, CaseIterable {
    case width_0 = 0.0
    case width_05 = 0.5
    case width_10 = 1.0
    case width_15 = 1.5
    case width_20 = 2.0

    var title: String {
        return String(format: "%.1f", rawValue)
    }
}

enum DanmuStrokeAlpha: Double, Codable, CaseIterable {
    case alpha_00 = 0.0
    case alpha_01 = 0.1
    case alpha_02 = 0.2
    case alpha_03 = 0.3
    case alpha_04 = 0.4
    case alpha_05 = 0.5
    case alpha_06 = 0.6
    case alpha_07 = 0.7
    case alpha_08 = 0.8
    case alpha_09 = 0.9
    case alpha_10 = 1.0

    var title: String {
        return String(format: "%.1f", rawValue)
    }
}

extension DanmuArea {
    var title: String {
        switch self {
        case .style_75:
            return "3/4屏"
        case .style_50:
            return "半屏"
        case .style_25:
            return "1/4屏"
        case .style_0:
            return "不限制"
        }
    }

    var percent: CGFloat {
        switch self {
        case .style_75:
            return 0.75
        case .style_50:
            return 0.5
        case .style_25:
            return 0.25
        case .style_0:
            return 1
        }
    }
}

enum FeaturedDurationLimit: Codable, CaseIterable, Equatable {
    case minutes3
    case minutes5
    case minutes10
    case minutes15
    case unlimited
}

extension FeaturedDurationLimit {
    var title: String {
        switch self {
        case .minutes3:
            return "3 分钟"
        case .minutes5:
            return "5 分钟"
        case .minutes10:
            return "10 分钟"
        case .minutes15:
            return "15 分钟"
        case .unlimited:
            return "不限"
        }
    }

    var maxDuration: Int? {
        switch self {
        case .minutes3:
            return 3 * 60
        case .minutes5:
            return 5 * 60
        case .minutes10:
            return 10 * 60
        case .minutes15:
            return 15 * 60
        case .unlimited:
            return nil
        }
    }
}

enum MediaQualityEnum: Codable, CaseIterable {
    case quality_1080p
    case quality_2160p
    case quality_hdr_dolby
}

extension MediaQualityEnum {
    var desp: String {
        switch self {
        case .quality_1080p:
            return "1080p"
        case .quality_2160p:
            return "4K"
        case .quality_hdr_dolby:
            return "杜比视界"
        }
    }

    var qn: Int {
        switch self {
        case .quality_1080p:
            return 116
        case .quality_2160p:
            return 120
        case .quality_hdr_dolby:
            return 126
        }
    }

    var fnval: Int {
        switch self {
        case .quality_1080p:
            return 16
        case .quality_2160p:
            return 144
        case .quality_hdr_dolby:
            return 976
        }
    }
}

/// 推荐来源：B 站不同端的首页推荐接口，候选池与排序策略各不相同。
enum RecommendSource: String, Codable, CaseIterable {
    case app
    case web
    case webLegacy
    case mixed

    var title: String {
        switch self {
        case .app: return "App 推荐"
        case .web: return "网页版推荐"
        case .webLegacy: return "网页版推荐（无签名旧接口）"
        case .mixed: return "混合（App + 网页交替）"
        }
    }

    var detail: String {
        switch self {
        case .app: return "手机 / 平板 App 首页推荐（x/v2/feed/index）"
        case .web: return "bilibili.com 首页推荐（wbi/index/top/feed/rcmd）"
        case .webLegacy: return "网页首页推荐旧路径（index/top/feed/rcmd），可能随时失效"
        case .mixed: return "App 与网页推荐交替排列并去重"
        }
    }
}
