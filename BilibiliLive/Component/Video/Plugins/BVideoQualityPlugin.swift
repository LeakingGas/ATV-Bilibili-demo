//
//  BVideoQualityPlugin.swift
//  BilibiliLive
//

import AVKit

class BVideoQualityPlugin: NSObject, CommonPlayerPlugin {
    private weak var playerVC: PlayerHost?
    private let playData: PlayerDetailData
    private var availableQualities: [QualityOption] = []
    private var currentQualityId: Int?
    private var currentStreamIndex: Int? // 当前选中的流索引
    private var isQualityLocked: Bool = false // 是否手动锁定了画质
    private var onQualityChange: ((Int, Int?) -> Void)? // (qualityId, streamIndex)
    /// 当前实际播放的流（由播放插件提供）；用于在菜单里勾选当前画质。
    var currentMediaProvider: (() -> VideoPlayURLInfo.DashInfo.DashMediaInfo?)?

    /// 当前实际播放的流在 dash.video 中的索引。
    private var playingStreamIndex: Int? {
        if let media = currentMediaProvider?() {
            let streams = playData.videoPlayURLInfo.dash.video
            if let index = streams.firstIndex(of: media) { return index }
            // 回前台 / 地址过期后会重新请求播放地址，新流的 URL 签名不同，整体比较对不上；
            // 按画质、编码、码率、分辨率认同一条流。
            if let index = streams.firstIndex(where: {
                $0.id == media.id && $0.codecs == media.codecs && $0.bandwidth == media.bandwidth
                    && $0.width == media.width && $0.height == media.height
            }) { return index }
            if let index = streams.firstIndex(where: { $0.id == media.id && $0.codecs == media.codecs }) { return index }
        }
        return isQualityLocked ? currentStreamIndex : nil
    }

    struct QualityOption {
        let id: Int
        let name: String
        let description: String
        let bandwidth: Int // 该流的码率（bps）
        let codec: String // 编码格式（如 avc1, hev1）
        let streamIndex: Int? // 在 dash.video 数组中的索引（用于精确定位流）
    }

    init(detailData: PlayerDetailData, onQualityChange: @escaping (Int, Int?) -> Void) {
        playData = detailData
        self.onQualityChange = onQualityChange
        super.init()

        // 从 VideoPlayURLInfo 中提取可用画质
        extractAvailableQualities()
    }

    func playerDidLoad(host: PlayerHost) {
        playerVC = host
    }

    // 流确定后（以及每次切换画质后）刷新菜单，标记当前画质。
    func playerWillStart(engine: PlayerEngine) {
        refreshMenu()
    }

    func playerDidStart(engine: PlayerEngine) {
        refreshMenu()
    }

    private func refreshMenu() {
        guard let playerVC, let fresh = addMenuItems(current: &placeholderMenus).first as? UIMenu else { return }
        var replaced = false
        let items = playerVC.transportBarCustomMenuItems.map { element -> UIMenuElement in
            guard let menu = element as? UIMenu, menu.identifier == fresh.identifier else { return element }
            replaced = true
            return fresh
        }
        if replaced { playerVC.transportBarCustomMenuItems = items }
    }

    private var placeholderMenus = [UIMenuElement]()

    private func extractAvailableQualities() {
        let supportFormats = playData.videoPlayURLInfo.support_formats
        let videoStreams = playData.videoPlayURLInfo.dash.video

        // 为每个视频流创建一个 QualityOption
        availableQualities = videoStreams.enumerated().map { index, stream in
            // 尝试从 support_formats 中找到该画质的描述信息
            let format = supportFormats.first { $0.quality == stream.id }
            let baseName = format?.new_description ?? "画质 \(stream.id)"

            // 提取编码类型（avc1 -> AVC, hev1 -> HEVC）
            let codecType: String
            if stream.codecs.starts(with: "avc") {
                codecType = "AVC"
            } else if stream.codecs.starts(with: "hev") || stream.codecs.starts(with: "hvc") {
                codecType = "HEVC"
            } else {
                codecType = String(stream.codecs.prefix(4))
            }

            // 构建完整的名称：画质名称 (编码, 码率)
            let mbps = Double(stream.bandwidth) / 1_000_000.0
            let fullName = String(format: "%@ (%@, %.1f Mbps)", baseName, codecType, mbps)

            return QualityOption(
                id: stream.id,
                name: fullName,
                description: format?.display_desc ?? "",
                bandwidth: stream.bandwidth,
                codec: stream.codecs,
                streamIndex: index
            )
        }

        // 按画质 ID 降序排序，同画质按码率降序排序
        availableQualities.sort {
            if $0.id != $1.id {
                return $0.id > $1.id
            } else {
                return $0.bandwidth > $1.bandwidth
            }
        }

        // 设置当前画质为实际返回的画质
        currentQualityId = playData.videoPlayURLInfo.quality
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        guard !availableQualities.isEmpty else { return [] }

        let qualityImage = UIImage(systemName: "video.fill")

        // 按画质 ID 分组
        let groupedQualities = Dictionary(grouping: availableQualities, by: { $0.id })

        // 获取所有唯一的画质 ID 并排序
        let sortedQualityIds = groupedQualities.keys.sorted(by: >)

        // 菜单结构与系统「字幕」菜单保持一致：只有平铺的选项和内嵌分组（.displayInline），
        // 不用多层子菜单、不用灰色不可选项。实测我们原来的嵌套结构会让 AVKit 关菜单后状态错乱
        // （之后按返回直接关掉播放器），而结构简单的系统菜单不会。
        let playing = playingStreamIndex
        let qualitySubmenus = sortedQualityIds.map { qualityId -> UIMenuElement in
            let streams = groupedQualities[qualityId]!

            // 获取画质的基础名称（去掉编码和码率信息）
            let baseName: String
            if let firstStream = streams.first {
                // 从完整名称中提取基础名称（如 "4K 超高清 (AVC, 27.2 Mbps)" -> "4K 超高清"）
                if let range = firstStream.name.range(of: " (") {
                    baseName = String(firstStream.name[..<range.lowerBound])
                } else {
                    baseName = firstStream.name
                }
            } else {
                baseName = "画质 \(qualityId)"
            }

            // 为该画质下的每个流创建菜单项
            let streamActions = streams.map { quality -> UIAction in
                // 检查是否是当前实际播放的流
                let isCurrentStream = quality.streamIndex != nil && quality.streamIndex == playing

                // 提取编码和码率信息（如 "AVC, 27.2 Mbps"）
                let streamInfo: String
                if let range = quality.name.range(of: " (") {
                    let infoWithParens = String(quality.name[range.lowerBound...])
                    streamInfo = infoWithParens.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                } else {
                    let mbps = Double(quality.bandwidth) / 1_000_000.0
                    streamInfo = String(format: "%.1f Mbps", mbps)
                }

                return UIAction(
                    title: streamInfo,
                    state: isCurrentStream ? .on : .off
                ) { [weak self] _ in
                    self?.switchQuality(to: quality)
                }
            }

            // 只有一个流：直接一个选项（不再包一层子菜单）。
            if streams.count == 1, let stream = streams.first, let action = streamActions.first {
                let mbps = Double(stream.bandwidth) / 1_000_000.0
                let codec = stream.name.range(of: "(").map { String(stream.name[$0.upperBound...]).components(separatedBy: ",").first ?? "" } ?? ""
                return UIAction(title: String(format: "%@ · %@ %.1f Mbps", baseName, codec, mbps),
                                state: action.state) { [weak self] _ in self?.switchQuality(to: stream) }
            }
            // 多个流（不同编码 / 码率）：内嵌分组，组标题是画质名；当前流以勾选标出。
            return UIMenu(title: baseName, options: [.displayInline], children: streamActions)
        }

        let children: [UIMenuElement] = qualitySubmenus
        let qualityMenu = UIMenu(
            title: "画质",
            image: qualityImage,
            identifier: UIMenu.Identifier(rawValue: "quality"),
            children: children
        )

        return [qualityMenu]
    }

    private func switchQuality(to quality: QualityOption) {
        // 选的就是正在播放的流：什么都不做（之前会重新加载一遍，看起来像切了画质）。
        if let playing = playingStreamIndex, quality.streamIndex == playing { return }
        // 更新状态：标记为手动锁定
        isQualityLocked = true
        currentQualityId = quality.id
        currentStreamIndex = quality.streamIndex

        // 触发画质切换
        onQualityChange?(quality.id, quality.streamIndex)
    }
}
