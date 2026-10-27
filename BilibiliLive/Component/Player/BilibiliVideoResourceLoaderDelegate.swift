//
//  BilibiliVideoResourceLoaderDelegate.swift
//  MPEGDASHAVPlayerDemo
//
//  Created by yicheng on 2022/08/20.
//  Copyright © 2022 yicheng. All rights reserved.
//

import Alamofire
import AVFoundation
import Swifter
import SwiftyJSON
import UIKit

class BilibiliVideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    enum URLs {
        static let customScheme = "atv"
        static let customPrefix = customScheme + "://list/"
        static let play = customPrefix + "play"
        static let customSubtitlePrefix = customScheme + "://subtitle/"
        static let customDashPrefix = customScheme + "://dash/"
    }

    struct PlaybackInfo {
        let info: VideoPlayURLInfo.DashInfo.DashMediaInfo
        let url: String
        let duration: Int
    }

    private var audioPlaylist = ""
    private var videoPlaylist = ""
    private var backupVideoPlaylist = ""
    private var masterPlaylist = ""

    private let badRequestErrorCode = 455

    private var playlists = [String]()
    private var subtitles = [String: String]()
    private var videoInfo = [PlaybackInfo]()
    /// diag13: 历史进度。生成媒体播放列表时写入 EXT-X-START，让 AVPlayer 直接从该位置
    /// 请求首段，而不是先下 0 秒处的首段、ready 后再 seek。仅首次进入时设置。
    var startOffset: Double?
    /// 当前实际播放的视频流（默认模式下为允许的最高画质）。
    var primaryMedia: VideoPlayURLInfo.DashInfo.DashMediaInfo? { videoInfo.first?.info }
    /// 当前首选视频流的简短描述（debug 浮层显示）。
    var primaryVideoDescription: String {
        guard let media = videoInfo.first?.info else { return "" }
        return "qn=\(media.id) \(media.codecs) \(media.width ?? 0)x\(media.height ?? 0) \(String(format: "%.1f", Double(media.bandwidth) / 1_000_000))Mbps"
    }
    // Keep SIDX selection scoped to this playback session. A shared cache can
    // leak the CDN chosen for one player into another concurrent player (for
    // example, picture-in-picture) because preferredHost is not part of the
    // media-info cache key.
    private let segmentInfoCache = SidxDownloader(maxEntries: 16)
    private var hasAudioInMasterListAdded = false
    private var audioRenditionIndex = 0
    private(set) var playInfo: VideoPlayURLInfo?
    private var hasSubtitle = false
    private var hasPreferSubtitleAdded = false
    private var httpServer = HttpServer()
    private var aid = 0
    private(set) var httpPort = 0
    private(set) var isHDR = false
    /// 首选视频流的全部 CDN 候选，按 host 去重，供 CDNDiagnostics 实测
    private(set) var cdnCandidates = [String]()
    /// 首选视频流的声明带宽（bps），access log 的 indicatedBitrate 尚未就绪时作健康检测兜底
    private(set) var primaryVideoBandwidth = 0
    /// 最近一次生成媒体播放列表时实际选用的分片 host
    private(set) var currentSegmentHost: String?
    /// 实际传输模式（内部执行模式，非用户设置）。始终使用 BTR。
    private(set) var transportMode: MediaTransportMode = .accelerated
    /// Mandatory BTR; unavailable proxy fails loading instead of changing modes.
    var effectiveTransportMode: MediaTransportMode {
        .accelerated
    }

    /// 本地代理是否可用（服务器启动成功且已注册媒体）。不可用时拒绝媒体加载。
    private(set) var proxyAvailable = false
    /// 媒体代理注册表（线程安全，Swifter 同步 handler 与播放列表生成并发访问）。
    private let proxyRegistry = MediaProxyRegistry()
    let btrPlayback = BTRPlaybackSession()
    private let diagLock = NSLock()
    private var _accelerationText = ""
    /// 播放中途检测到当前 host 吞吐撑不住时，外部（BVideoPlayPlugin）指定的优先 host，
    /// sidx 探测会把它排到候选队首，覆盖默认 URL 顺序
    private var preferredHost: String?
    deinit {
        Diag.mark("PROXY \(Diag.id(self)) deinit port=\(httpPort)")
        btrPlayback.invalidate()
        cancelPendingIndexLoads()
        httpServer.stop()
    }

    /// 加速诊断文本（同步读取，供 DebugPlugin 展示；敏感签名已剔除）。
    var accelerationDebugInfo: String {
        diagLock.lock()
        defer { diagLock.unlock() }
        return _accelerationText
    }

    private func updateAccelerationText(_ text: String) {
        diagLock.lock()
        _accelerationText = text
        diagLock.unlock()
    }

    var infoDebugText: String {
        let videoCodec = playInfo?.dash.video.map({ $0.codecs }).prefix(5).joined(separator: ",") ?? "nil"
        let audioCodec = playInfo?.dash.audio?.map({ $0.codecs }).prefix(5).joined(separator: ",") ?? "nil"
        return "video codecs: \(videoCodec), audio: \(audioCodec)"
    }

    // 黑名单：不支持的编码
    // 注：经过测试，avc1.640034 (H.264 High 5.2) 在现代设备上是支持的，已移除
    let videoCodecBlackList: [String] = []

    private func reset() {
        playlists.removeAll()
        audioRenditionIndex = 0
        hasAudioInMasterListAdded = false
        proxyAvailable = false
        proxyRegistry.removeAll()
        updateAccelerationText("")
        masterPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS


        """
    }

    /// DASH manifest 的 bandwidth 是平均码率，而 HLS 的 BANDWIDTH 要求的是分片峰值码率。
    /// 直接照搬会让 CoreMedia 每拉一个分片都判定 "Segment exceeds specified bandwidth for
    /// variant" (-12318) 并自行上调内部估计，ABR 从起播起就在用错误的依据决策。
    ///
    /// 实测 B 站分片的峰值约为平均的 1.5 倍：785kbps 的流被上调到 1.21Mbps，
    /// 3.17Mbps 的流被上调到 4.81Mbps。真实平均值仍通过 AVERAGE-BANDWIDTH 如实声明，
    /// 稳态选流靠它，所以这里的峰值宁可略高。
    private static func peakBandwidth(forAverage average: Int) -> Int {
        return Int(Double(average) * 1.5)
    }

    private func addVideoPlayBackInfo(info: VideoPlayURLInfo.DashInfo.DashMediaInfo, url: String, duration: Int) {
        // 黑名单已经在 setBilibili 中过滤了，这里不需要再检查
        let subtitlePlaceHolder = hasSubtitle ? ",SUBTITLES=\"subs\"" : ""
        let isDolby = info.id == MediaQualityEnum.quality_hdr_dolby.qn
        let isHDR10 = info.id == 125
        // hdr 10 formate exp: hev1.2.4.L156.90
        //  Codec.Profile.Flags.TierLevel.Constraints
        let isHDR = isDolby || isHDR10
        if isHDR {
            self.isHDR = true
        }
        var videoRange = isHDR ? "HLG" : "SDR"
        var codecs = info.codecs
        var supplementCodesc = ""
        // TODO: Need update all codecs with https://developer.apple.com/documentation/http_live_streaming/http_live_streaming_hls_authoring_specification_for_apple_devices/hls_authoring_specification_for_apple_devices_appendixes
        var framerate = info.frame_rate ?? "25"
        if isHDR10 {
            videoRange = "PQ"
            if let value = Double(framerate), value <= 30 {} else {
                framerate = "30"
            }
        }
        if codecs == "dvh1.08.07" || codecs == "dvh1.08.03" {
            supplementCodesc = codecs + "/db4h"
            codecs = "hvc1.2.4.L153.b0"
            videoRange = "HLG"
        } else if codecs == "dvh1.08.06" {
            supplementCodesc = codecs + "/db1p"
            codecs = "hvc1.2.4.L150"
            videoRange = "PQ"
        } else if codecs.hasPrefix("dvh1.05") {
            videoRange = "PQ"
        } else if isHDR {
            Logger.warn("unknown hdr codecs: \(codecs)")
        }

        if let value = Double(framerate), value >= 60 {
            framerate = "60"
        }

        if supplementCodesc.count > 0 {
            supplementCodesc = ",SUPPLEMENTAL-CODECS=\"\(supplementCodesc)\""
        }
        let content = """
        #EXT-X-STREAM-INF:AUDIO="audio"\(subtitlePlaceHolder),CODECS="\(codecs)"\(supplementCodesc),RESOLUTION=\(info.width ?? 0)x\(info.height ?? 0),FRAME-RATE=\(framerate),BANDWIDTH=\(Self.peakBandwidth(forAverage: info.bandwidth)),AVERAGE-BANDWIDTH=\(info.bandwidth),VIDEO-RANGE=\(videoRange)
        \(URLs.customDashPrefix)\(videoInfo.count)?codec=\(info.codecs)&rate=\(info.frame_rate ?? framerate)&width=\(info.width ?? 0)&host=\(URL(string: url)?.host ?? "none")&range=\(info.id)

        """
        masterPlaylist.append(content)
        videoInfo.append(PlaybackInfo(info: info, url: url, duration: duration))
    }

    private func collectCDNCandidates(from video: VideoPlayURLInfo.DashInfo.DashMediaInfo?) {
        guard let video else {
            cdnCandidates = []
            primaryVideoBandwidth = 0
            return
        }
        primaryVideoBandwidth = video.bandwidth
        var seenHosts = Set<String>()
        cdnCandidates = video.playableURLs.filter { url in
            guard let host = URLComponents(string: url)?.host else { return false }
            return seenHosts.insert(host).inserted
        }

        let detail = cdnCandidates
            .map { url in
                let host = URLComponents(string: url)?.host ?? "?"
                return BVideoUrlUtils.isPCDN(url) ? "  PCDN \(host)" : "  \(host)"
            }
            .joined(separator: "\n")
        Logger.info("cdn candidates for qn \(video.id) (\(video.bandwidth / 1000)kbps):\n\(detail)")
    }

    private func getVideoPlayList(info: PlaybackInfo) async throws -> String {
        BTRTrace.shared.event("playlist_begin",["session":btrPlayback.id.uuidString,"quality":info.info.id,"codec":info.info.codecs])
        let indexStarted = BTRTrace.now
        let sidxResult = await segmentInfoCache.sidx(from: info.info, preferredHost: preferredHost)
        BTRTrace.shared.event("index_result",["session":btrPlayback.id.uuidString,"quality":info.info.id,"available":sidxResult != nil,"elapsedMs":BTRTrace.now-indexStarted])
        let inits = info.info.segment_base.initialization.components(separatedBy: "-")
        guard let moovIdxStr = inits.last,
              let moovIdx = Int(moovIdxStr),
              let moovOffset = inits.first,
              let offsetStr = info.info.segment_base.index_range.components(separatedBy: "-").last,
              var offset = Int(offsetStr),
              let sidxResult = sidxResult
        else {
            updateAccelerationText("BTR ONLY error: index-unavailable")
            throw NSError(domain: "BTRStrict", code: 1, userInfo: [NSLocalizedDescriptionKey: "BTR索引不可用；直连已禁用"])

        }

        // 使用 sidx 实际下载成功的 URL——它已经完成了对 CDN 可用性的探测，
        // 首选 CDN 挂掉时 segment 会整体切到探测成功的备用 URL
        let segment = sidxResult.sidx
        let segmentURL = sidxResult.url
        currentSegmentHost = URLComponents(string: segmentURL)?.host
        // sidx 索引字节作为跨 CDN 等价性验证的信任锚点：它是播放前已从探测
        // 成功的 URL 取回的原始字节，后续各 CDN 的同区间样本必须与之逐字节一致。
        // 锚点设置与媒体请求并发进行，先到的下载请求可能回退为双边采样，不影响正确性。
        if let anchorRange = Self.indexRange(info.info),
           sidxResult.indexBytes.count == anchorRange.length,
           let downloader = proxyRegistry.downloader(for: info.info)
        {
            await downloader.setTrustAnchor(range: anchorRange, bytes: sidxResult.indexBytes)
        }
        // 代理启用且媒体已成功注册时，用本地 HTTP URL 替换 CDN 地址；
        // 保留原 Range、分段持续时间和全部 HLS 标签。SIDX 失败抛出明确错误。
        guard let mediaURL = mediaTransportURL(for: info.info) else {
            updateAccelerationText("BTR ONLY error: proxy-unavailable")
            throw NSError(domain: "BTRStrict", code: 2, userInfo: [NSLocalizedDescriptionKey: "BTR代理不可用；直连已禁用"])
        }
        var playList = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(segment.maxSegmentDuration() ?? info.duration)
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="\(mediaURL)",BYTERANGE="\(moovIdx + 1)@\(moovOffset)"

        """
        if let startOffset, startOffset > 0 {
            playList.append("#EXT-X-START:TIME-OFFSET=\(String(format: "%.3f", startOffset)),PRECISE=YES\n")
            BTRTrace.shared.event("playlist_start_offset",["quality":info.info.id,"offset":startOffset])
        }
        offset += 1
        var btrTimings = [BTRSegmentTiming]()
        var presentation = 0.0 // HLS timeline starts at zero; match the playlist we actually serve.
        for segInfo in segment.segments {
            let segStr = """
            #EXTINF:\(Double(segInfo.duration) / Double(segment.timescale)),
            #EXT-X-BYTERANGE:\(segInfo.size)@\(offset)
            \(mediaURL)

            """
            if segment.timescale > 0, segInfo.size > 0,
               let byteRange = try? MediaByteRange(start: Int64(offset), end: Int64(offset + segInfo.size - 1)) {
                btrTimings.append(BTRSegmentTiming(range: byteRange, start: presentation))
                presentation += Double(segInfo.duration) / Double(segment.timescale)
            }
            playList.append(segStr)
            offset += (segInfo.size)
        }

        if let downloader = proxyRegistry.downloader(for: info.info) {
            await downloader.setTimings(btrTimings)
        }
        playList.append("\n#EXT-X-ENDLIST")

        return playList
    }

    private func addAudioPlayBackInfo(info: VideoPlayURLInfo.DashInfo.DashMediaInfo, url: String, duration: Int) {
        guard !videoCodecBlackList.contains(info.codecs) else { return }
        let isFirst = !hasAudioInMasterListAdded
        let defaultStr = isFirst ? "YES" : "NO"

        // 构建音轨名称
        let bitrateKbps = info.bandwidth / 1000
        let name = "音轨 (\(bitrateKbps)kbps)"

        let content = """
        #EXT-X-MEDIA:TYPE=AUDIO,DEFAULT=\(defaultStr),AUTOSELECT=YES,GROUP-ID="audio",LANGUAGE="zh",NAME="\(name)",URI="\(URLs.customDashPrefix)\(videoInfo.count)"

        """

        masterPlaylist.append(content)

        // 只有在真正添加音轨时才更新状态
        hasAudioInMasterListAdded = true
        audioRenditionIndex += 1
        videoInfo.append(PlaybackInfo(info: info, url: url, duration: duration))
    }

    private func addAudioPlayBackInfo(codec: String, bandwidth: Int, duration: Int, url: String) {
        let isFirst = !hasAudioInMasterListAdded
        let defaultStr = isFirst ? "YES" : "NO"

        // 构建音轨名称
        let bitrateKbps = bandwidth / 1000
        let name = "音轨 (\(bitrateKbps)kbps)"

        let content = """
        #EXT-X-MEDIA:TYPE=AUDIO,DEFAULT=\(defaultStr),AUTOSELECT=YES,GROUP-ID="audio",LANGUAGE="zh",NAME="\(name)",URI="\(URLs.customPrefix)\(playlists.count)"

        """
        masterPlaylist.append(content)

        // 只有在真正添加音轨时才更新状态
        hasAudioInMasterListAdded = true
        audioRenditionIndex += 1

        let playList = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:\(duration)
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(duration)
        \(url)
        #EXT-X-ENDLIST
        """
        playlists.append(playList)
    }

    private func addSubtitleData(lang: String, name: String, duration: Int, url: String) {
        var lang = lang
        var canBeDefault = !hasPreferSubtitleAdded
        if lang.hasPrefix("ai-") {
            lang = String(lang.dropFirst(3))
            canBeDefault = false
        }
        if canBeDefault {
            hasPreferSubtitleAdded = true
        }
        let defaultStr = canBeDefault ? "YES" : "NO"

        let master = """
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="\(lang)",NAME="\(name)",AUTOSELECT=\(defaultStr),DEFAULT=\(defaultStr),URI="\(URLs.customPrefix)\(playlists.count)"

        """
        masterPlaylist.append(master)

        let playList = """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(duration)
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(duration),

        \(URLs.customSubtitlePrefix)\(url.addingPercentEncoding(withAllowedCharacters: .afURLQueryAllowed) ?? url)
        #EXT-X-ENDLIST

        """
        playlists.append(playList)
    }

    func setBilibili(info: VideoPlayURLInfo, subtitles: [SubtitleData], aid: Int, maxQuality: Int? = nil, streamIndex: Int? = nil, preferredHost: String? = nil, transportMode: MediaTransportMode = .accelerated) {
        playInfo = info
        self.aid = aid
        self.preferredHost = preferredHost
        self.transportMode = .accelerated
        reset()
        // reset() 会清 proxyAvailable；恢复本会话的模式（reset 后设置，避免被清掉）
        self.transportMode = .accelerated
        hasSubtitle = subtitles.count > 0
        var videos = info.dash.video
        if Settings.preferAvc {
            let videosMap = Dictionary(grouping: videos, by: { $0.id })
            for (key, values) in videosMap {
                if values.contains(where: { !$0.isHevc }) {
                    videos.removeAll(where: { $0.id == key && $0.isHevc })
                }
            }
        }

        // 先过滤黑名单编码（避免后续强制模式选择了被黑名单的流）
        videos = videos.filter { !videoCodecBlackList.contains($0.codecs) }
        // diag13: 同一画质优先 HEVC（含杜比视界）。B 站 4K AVC 常见 20-30 Mbps，HEVC 约一半，
        // 首段更小、起播更快、更不容易卡。Apple TV 4K 均有 HEVC 硬解。用户开启「Avc优先」时不生效。
        if !Settings.preferAvc {
            let videosMap = Dictionary(grouping: videos, by: { $0.id })
            for (key, values) in videosMap where values.contains(where: { $0.isHevc }) {
                videos.removeAll(where: { $0.id == key && !$0.isHevc })
            }
        }

        // 智能画质模式：
        // 1. 如果用户手动选择了具体的流（streamIndex 不为 nil），只使用该流
        // 2. 如果用户手动选择了画质（maxQuality 不为 nil），只保留该画质的流（强制模式）
        // 3. 如果是默认模式，使用设置限制并保留多级画质作为后备（自适应模式）
        if let streamIndex = streamIndex, streamIndex < info.dash.video.count {
            // 用户选择了具体的流，直接使用该流
            videos = [info.dash.video[streamIndex]]
        } else if let maxQuality = maxQuality {
            // 用户选择了画质，保留该画质的最高码率流
            // （手动切画质时一般会带 streamIndex，走上面精确选流；这里是无 streamIndex 的兜底）
            let matchingStreams = videos.filter { $0.id == maxQuality }
            if let highestBandwidthStream = matchingStreams.max(by: { $0.bandwidth < $1.bandwidth }) {
                videos = [highestBandwidthStream]
            } else {
                videos = matchingStreams
            }
        } else {
            // 默认模式：自适应模式
            // 使用设置中的画质限制
            let qualityLimit = Settings.mediaQuality.qn
            videos = videos.filter { $0.id <= qualityLimit }

            // 保留最高画质 + 中等画质（1080P）+ 低画质（720P 及以下）作为后备
            // 这样 AVPlayer 可以根据网络状况自动降级
            let highestQuality = videos.map { $0.id }.max() ?? qualityLimit

            // 保留最高画质的所有编码
            let highQualityVideos = videos.filter { $0.id == highestQuality }

            // diag12: 只保留最高画质。经本地 BTR 代理时 AVPlayer 的自适应码率估计不可靠：
            // diag9/diag10 实机日志显示起播即降到 2-4 Mbps 的后备流（indicatedBps 2.29M/4.09M），
            // 用户每次都要手动切回最高画质。BTR 现已能提供 >50 Mbps，不再交给 AVPlayer 自动降级。
            videos = highQualityVideos
        }

        // 按 bandwidth 降序排序（码率最高的优先，让 AVPlayer 优先选择）
        // 这样可以确保在同一画质等级下，AVPlayer 会选择码率最高的流
        videos.sort { $0.bandwidth > $1.bandwidth }

        collectCDNCandidates(from: videos.first)

        // 添加所有 CDN 节点的 URL，让 AVPlayer 自动选择最快的
        // 这样可以解决单个 CDN 节点速度慢的问题
        for video in videos {
            for url in video.playableURLs {
                addVideoPlayBackInfo(info: video, url: url, duration: info.dash.duration)
            }
        }

        if Settings.losslessAudio {
            if let audios = info.dash.dolby?.audio {
                // 只添加第一个杜比音频流的第一个 URL
                if let firstAudio = audios.first,
                   let firstUrl = BVideoUrlUtils.sortUrls(base: firstAudio.base_url, backup: firstAudio.backup_url).first
                {
                    addAudioPlayBackInfo(info: firstAudio, url: firstUrl, duration: info.dash.duration)
                }
            } else if let audio = info.dash.flac?.audio,
                      let firstUrl = audio.playableURLs.first
            {
                // 只添加第一个 FLAC 音频 URL
                addAudioPlayBackInfo(info: audio, url: firstUrl, duration: info.dash.duration)
            }
        }

        // 只添加第一个普通音频流的第一个 URL
        if let firstAudio = info.dash.audio?.first,
           let firstUrl = firstAudio.playableURLs.first
        {
            addAudioPlayBackInfo(info: firstAudio, url: firstUrl, duration: info.dash.duration)
        }

        // i-frame（拖动进度条时的预览缩略图）。diag14 拖动日志：之前用的是正在播放的同一条 4K 流，
        // 系统每取一张预览图就要下载一整段（约 18 MB），拖动时同时在好几个位置下载，
        // 把真正要播的那段挤得很慢。改用这个视频码率最低的一条流（每段只有几百 KB）。
        if let video = info.dash.video
            .filter({ !videoCodecBlackList.contains($0.codecs) && ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 })
            .min(by: { $0.bandwidth < $1.bandwidth }),
            let url = video.playableURLs.first
        {
            let media = """
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\(Self.peakBandwidth(forAverage: video.bandwidth)),RESOLUTION=\(video.width!)x\(video.height!),URI="\(URLs.customDashPrefix)\(videoInfo.count)"

            """
            masterPlaylist.append(media)
            videoInfo.append(PlaybackInfo(info: video, url: url, duration: info.dash.duration))
        }

        do {
            // 只使用当前实例的 Server，不为媒体另建监听器；限制 loopback，动态端口。
            httpServer.listenAddressIPv4 = "127.0.0.1"
            do {
                try httpServer.start(0, forceIPv4: true)
                bindHttpServer()
                httpPort = (try? httpServer.port()) ?? 0
                Diag.mark("PROXY \(Diag.id(self)) server started port=\(httpPort)")
                // 注册当前会话的媒体流及其 CDN 候选（播放列表生成时用本地 URL）。
                if httpPort > 0 {
                    registerProxyMedia(aid: aid)
                    proxyAvailable = true
                }
            } catch {
                // 监听器启动失败则拒绝加载媒体
                Logger.warn("BTR proxy startup failed; direct disabled")
                Diag.mark("PROXY \(Diag.id(self)) server start FAILED \((error as NSError).domain)#\((error as NSError).code)")
                proxyAvailable = false
            }
        }
        for subtitle in subtitles {
            if let url = subtitle.url {
                addSubtitleData(lang: subtitle.lan, name: subtitle.lan_doc, duration: info.dash.duration, url: url.absoluteString)
            }
        }


        masterPlaylist.append("\n#EXT-X-ENDLIST\n")

        Logger.debug("masterPlaylist: \(masterPlaylist)")
    }

    /// diag13: 播放器开口之前预下载起播位置所在的视频/音频段（AVPlayer 需整段到齐才出画面），
    /// 并发校验全部节点。只在真正开始播放时调用（预加载的下一集不调用，避免浪费带宽）。
    func prewarmStart(at seconds: Double) async {
        guard transportMode == .accelerated else { return }
        var seen = Set<VideoPlayURLInfo.DashInfo.DashMediaInfo>()
        let firstAudio = videoInfo.first { infoIsAudio($0.info) }?.info
        let targets = [videoInfo.first?.info, firstAudio].compactMap { $0 }
        for media in targets where seen.insert(media).inserted {
            guard let downloader = proxyRegistry.downloader(for: media) else { continue }
            await downloader.verifyAllHosts()
            guard let sidx = await segmentInfoCache.sidx(from: media, preferredHost: preferredHost)?.sidx,
                  sidx.timescale > 0,
                  let indexEnd = media.segment_base.index_range.components(separatedBy: "-").last.flatMap({ Int64($0) })
            else { continue }
            var offset = indexEnd + 1
            var presentation = 0.0
            for (index, segment) in sidx.segments.enumerated() {
                let duration = Double(segment.duration) / Double(sidx.timescale)
                let size = Int64(segment.size)
                if seconds < presentation + duration || index == sidx.segments.count - 1 {
                    // diag14: AVPlayer only becomes ready once the NEXT segment has started arriving too
                    // (device traces: first segment complete at ~3.3-5.4 s, ready at ~7.8 s while the 2nd
                    // segment's first piece crawled). Prewarm both, so both are hedged as startup-critical.
                    // （试过同时预下载下一段：两段一起抢带宽，第一段反而更慢，已撤回。）
                    if size > 0, let range = try? MediaByteRange(start: offset, end: offset + size - 1) {
                        await downloader.prewarm(range: range)
                    }
                    break
                }
                offset += size
                presentation += duration
            }
        }
    }

    func prewarmPrimaryVideoIndex() async {
        guard let firstVideo = videoInfo.first else { return }
        _ = await segmentInfoCache.sidx(from: firstVideo.info, preferredHost: preferredHost)
    }

    func cancelPendingIndexLoads() {
        let cache = segmentInfoCache
        Task {
            await cache.cancelAll()
        }
    }

    private func reportError(_ loadingRequest: AVAssetResourceLoadingRequest, withErrorCode error: Int) {
        loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: error, userInfo: nil))
    }

    private func report(_ loadingRequest: AVAssetResourceLoadingRequest, content: String) {
        if let data = content.data(using: .utf8) {
            loadingRequest.dataRequest?.respond(with: data)
            loadingRequest.finishLoading()
        } else {
            reportError(loadingRequest, withErrorCode: badRequestErrorCode)
        }
    }

    func resourceLoader(_: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool
    {
        guard let scheme = loadingRequest.request.url?.scheme, scheme == URLs.customScheme else {
            return false
        }

        // 直接在 loader 串行队列处理，避免被主线程（弹幕渲染等）阻塞。
        // playlist 相关状态在 setBilibili 中写入且发生在 setDelegate 之前，此处只读，无竞争。
        handleCustomPlaylistRequest(loadingRequest)
        return true
    }
}

private extension BilibiliVideoResourceLoaderDelegate {
    func handleCustomPlaylistRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let customUrl = loadingRequest.request.url else {
            reportError(loadingRequest, withErrorCode: badRequestErrorCode)
            return
        }
        let urlStr = customUrl.absoluteString
        Logger.debug("handleCustomPlaylistRequest: \(urlStr)")
        if urlStr == URLs.play {
            guard proxyAvailable else {
                updateAccelerationText("BTR ONLY error: proxy-startup-failed")
                loadingRequest.finishLoading(with: NSError(domain: "BTRStrict", code: 2))
                return
            }
            BTRTrace.shared.event("loader_master")
            report(loadingRequest, content: masterPlaylist)
            return
        }

        if urlStr.hasPrefix(URLs.customPrefix), let index = Int(customUrl.lastPathComponent) {
            let playlist = playlists[index]
            BTRTrace.shared.event("loader_list", ["index": index])
            report(loadingRequest, content: playlist)
            return
        }
        if urlStr.hasPrefix(URLs.customDashPrefix), let index = Int(customUrl.lastPathComponent) {
            let info = videoInfo[index]
            let requested = BTRTrace.now
            BTRTrace.shared.event("loader_media_begin", ["index": index, "quality": info.info.id])
            Task {
                do {
                    let list = try await getVideoPlayList(info: info)
                    BTRTrace.shared.event("loader_media_served", ["index": index, "quality": info.info.id, "elapsedMs": BTRTrace.now - requested])
                    report(loadingRequest, content: list)
                } catch {
                    BTRTrace.shared.event("loader_media_failed", ["index": index, "elapsedMs": BTRTrace.now - requested])
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
        if urlStr.hasPrefix(URLs.customSubtitlePrefix) {
            BTRTrace.shared.event("loader_subtitle")
            let url = String(urlStr.dropFirst(URLs.customSubtitlePrefix.count))
            let req = url.removingPercentEncoding ?? url
            Task {
                do {
                    if subtitles[req] == nil {
                        let content = try await WebRequest.requestSubtitle(url: URL(string: req)!)
                        let vtt = BVideoUrlUtils.convertToVTT(subtitle: content)
                        subtitles[req] = vtt
                    }
                    let port = try self.httpServer.port()
                    let url = "http://127.0.0.1:\(port)/subtitle?u=" + url
                    let redirectRequest = URLRequest(url: URL(string: url)!)
                    let redirectResponse = HTTPURLResponse(url: URL(string: url)!, statusCode: 302, httpVersion: nil, headerFields: nil)

                    loadingRequest.redirect = redirectRequest
                    loadingRequest.response = redirectResponse
                    loadingRequest.finishLoading()
                    return
                } catch let err {
                    loadingRequest.finishLoading(with: err)
                }
            }
            return
        }
        Logger.debug("handle loading \(customUrl)")
    }

    func bindHttpServer() {
        httpServer["/subtitle"] = { [weak self] req in
            if let url = req.queryParams.first(where: { $0.0 == "u" })?.1 {
                let req = url.removingPercentEncoding ?? url
                if let content = self?.subtitles[req] {
                    return HttpResponse.ok(.text(content))
                }
            }
            return HttpResponse.notFound()
        }
        // 只接受当前播放会话媒体标识的 /media/:id，不接受请求直接指定外部 URL，
        // 不将带签名的真实 CDN URL 编码到本地路径中。
        httpServer["/media/:id"] = { [weak self] req in
            guard let self else { return HttpResponse.internalServerError(nil) }
            return self.handleMediaProxyRequest(req)
        }
    }

    // MARK: - 本地媒体代理

    /// 解析 DASH segment_base.index_range（"start-end"），供信任锚点使用。
    private static func indexRange(_ media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> MediaByteRange? {
        let parts = media.segment_base.index_range.components(separatedBy: "-")
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(parts[1].trimmingCharacters(in: .whitespaces)),
              let range = try? MediaByteRange(start: start, end: end)
        else { return nil }
        return range
    }

    /// 为当前会话已注册的媒体流生成本地 URL；未注册/不可用时返回 nil（调用方抛错）。
    func mediaTransportURL(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> String? {
        guard transportMode != .direct, proxyAvailable, httpPort > 0 else { return nil }
        guard let id = proxyRegistry.id(for: media) else { return nil }
        return "http://127.0.0.1:\(httpPort)/media/\(id)"
    }

    private func infoIsAudio(_ media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> Bool {
        playInfo?.dash.audio?.contains(where: { $0 == media }) == true
    }

    private func registerProxyMedia(aid: Int) {
        let referer = Keys.referer(for: aid)
        // 同一 DashMediaInfo 的多 CDN URL 共享同一媒体 ID；不同清晰度/codec/音视频轨道
        // 因 DashMediaInfo 不同而自然隔离，不会共用错误标识。
        var seen = Set<VideoPlayURLInfo.DashInfo.DashMediaInfo>()
        for entry in videoInfo {
            let media = entry.info
            guard seen.insert(media).inserted else { continue }
            // diag12: BTR cdn-resolver node expansion (same signed address on several nodes).
            let candidates = BTRCDN.candidates(media.playableURLs, region: Settings.btrNodeRegion)
            guard !candidates.isEmpty else { continue }
            let mode: MediaTransportMode = transportMode == .accelerated ? .accelerated : .proxy
            let downloader = MediaRangeDownloader(candidates: candidates, referer: referer, mode: mode, playback: btrPlayback, isAudio: infoIsAudio(media), traceLabel: "qn=\(media.id) codec=\(media.codecs) size=\(media.width ?? 0)x\(media.height ?? 0) bps=\(media.bandwidth)")
            BTRTrace.shared.event("track_registered",["track":downloader.traceID,"session":btrPlayback.id.uuidString,
                "quality":media.id,"codec":media.codecs,"width":media.width ?? 0,"height":media.height ?? 0,
                "bandwidth":media.bandwidth,"audio":infoIsAudio(media),
                "hosts":candidates.compactMap { URL(string:$0)?.host }])
            proxyRegistry.register(media: media, candidates: candidates, referer: referer, downloader: downloader)
        }
    }

    /// Swifter 同步 handler（运行在后台连接队列，禁止阻塞主线程）。
    /// 响应头发送前完成元信息验证；206 发送后只允许补齐剩余字节或截断触发播放器级恢复。
    /// 注意：handler 只持有注册表的不可变元信息快照（锁内一次性拷贝），
    /// 不直接读取可变的 Entry，避免与 totalLength 更新竞争。
    private func handleMediaProxyRequest(_ req: HttpRequest) -> HttpResponse {
        guard let mediaID = req.params[":id"], !mediaID.isEmpty else {
            return HttpResponse.badRequest(nil)
        }
        guard let entry = proxyRegistry.snapshot(for: mediaID) else {
            return HttpResponse.notFound(nil)
        }
        let method = req.method.uppercased()
        if method == "HEAD" {
            // 返回与当前可用元信息一致的头，不传 body
            let headers = MediaRangeResponseHeaders.head(totalLength: entry.totalLength)
            return HttpResponse.raw(200, "OK", headers, nil)
        }
        guard method == "GET" else {
            return HttpResponse.badRequest(nil)
        }
        let rangeHeader = req.headers["range"]
        // Only the player's byte-range syntax; no URL, headers or cookies are exported.
        let safeRange = (rangeHeader ?? "missing").prefix(100)
        BTRTrace.shared.event("proxy_request",["track":entry.downloader.traceID,"range":String(safeRange),"total":entry.totalLength ?? -1])
        let parsed = MediaRangeParsing.parse(header: rangeHeader, fileLength: entry.totalLength)
        switch parsed {
        case .missing:
            return strictProxyFailure("range-required")
        case .multiUnsupported:
            let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: entry.totalLength)
            return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
        case .invalid:
            return HttpResponse.badRequest(nil)
        case let .unsatisfiable(total):
            let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: total ?? entry.totalLength)
            return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
        case .openEnded, .suffix:
            // 需 total 归一化；未知 total 明确失败，不重定向
            if let total = entry.totalLength {
                let normalized = MediaRangeParsing.normalizeUnbounded(parsed, fileLength: total)
                if case let .single(range) = normalized {
                    return serveVerifiedRange(range, entry: entry, mediaID: mediaID)
                }
                let headers = MediaRangeResponseHeaders.rangeNotSatisfiable(totalLength: total)
                return HttpResponse.raw(416, "Range Not Satisfiable", headers, nil)
            }
            return strictProxyFailure("total-unknown")
        case let .single(range):
            // Large valid ranges are streamed through bounded windows and the byte pipe.
            return serveVerifiedRange(range, entry: entry, mediaID: mediaID)
        }
    }

    private func strictProxyFailure(_ reason: String) -> HttpResponse {
        BTRTrace.shared.event("proxy_rejected",["session":btrPlayback.id.uuidString,"reason":reason])
        updateAccelerationText("BTR ONLY error: " + reason)
        return HttpResponse.raw(503, "BTR transport unavailable", ["Content-Length": "0", "X-BTR-Error": reason], nil)
    }

    private func serveVerifiedRange(_ range: MediaByteRange, entry: MediaProxyRegistry.MediaSnapshot, mediaID: String) -> HttpResponse {
        // 首次请求时 total 通常未知，按 RFC 以 * 声明；AVPlayer 在当前 HLS 链路
        // 是否接受 bytes start-end/* 仍需真机验证（见验收 P2）。后续请求复用已缓存的 total。
        let headers = MediaRangeResponseHeaders.partialContent(range: range, totalLength: entry.totalLength)
        let downloader = entry.downloader
        let candidates = entry.candidates
        weak var weakSelf = self
        return HttpResponse.raw(206, "Partial Content", headers) { writer in
            let pipe = MediaBytePipe()
            let requestID = pipe.traceID
            BTRTrace.shared.event("proxy_begin",["request":requestID,"track":downloader.traceID,"start":range.start,"end":range.end,"total":entry.totalLength ?? -1])
            var written = 0
            var lastWriteTrace = -Double.infinity
            var lastReadTrace = -Double.infinity
            let streamTask = Task {
                await downloader.stream(range: range, to: pipe)
            }
            // 后台同步排空：不阻塞主线程或 URLSession 回调线程
            assert(!Thread.isMainThread, "media proxy writer must not run on main thread")
            do {
                while true {
                    let chunk: Data?
                    do {
                        let readingAt = BTRTrace.now
                        let reportRead = readingAt-lastReadTrace >= 1000
                        if reportRead { BTRTrace.shared.event("proxy_read_begin",["request":requestID,"written":written]) }
                        chunk = try pipe.readSync(maxLength: 64 * 1024, timeout: 30)
                        if reportRead || BTRTrace.now-readingAt >= 250 {
                            lastReadTrace = BTRTrace.now
                            BTRTrace.shared.event("proxy_read_end",["request":requestID,"bytes":chunk?.count ?? 0,"waitMs":BTRTrace.now-readingAt])
                        }
                    } catch {
                        streamTask.cancel()
                        throw error
                    }
                    guard let chunk else { break }
                    do {
                        let writingAt = BTRTrace.now
                        if BTRTrace.now-lastWriteTrace >= 1000 {
                            BTRTrace.shared.event("proxy_write_begin",["request":requestID,"written":written,"bytes":chunk.count])
                        }
                        try writer.write(chunk)
                        written += chunk.count
                        if BTRTrace.now-lastWriteTrace >= 1000 || BTRTrace.now-writingAt >= 250 {
                            lastWriteTrace = BTRTrace.now
                            BTRTrace.shared.event("proxy_write_end",["request":requestID,"written":written,"writeMs":BTRTrace.now-writingAt])
                        }
                    } catch {
                        // 读取方关闭/超时/写入失败：立即取消生产者（幂等），截断连接
                        streamTask.cancel()
                        throw error
                    }
                }
            } catch {
                streamTask.cancel()
                BTRTrace.shared.event("proxy_failed",BTRTrace.errorFields(error).merging(["request":requestID,"written":written]) { _,new in new })
                // 206 已发送：不能改写状态码，只能截断；播放器级恢复由 BVideoPlayPlugin 触发
                throw error
            }
            BTRTrace.shared.event("proxy_complete",["request":requestID,"written":written])
            // 成功交付后异步更新诊断与 total 缓存（不阻塞 writer）
            Task { [weakSelf, downloader, candidates, mediaID] in
                if let total = await downloader.knownTotal() {
                    weakSelf?.proxyRegistry.updateTotalLength(total, for: mediaID)
                }
                if let diag = await weakSelf?.buildAccelerationText(downloader: downloader) {
                    weakSelf?.updateAccelerationText(diag)
                }
                _ = candidates
            }
        }
    }

    private func buildAccelerationText(downloader: MediaRangeDownloader) async -> String {
        let diag = await downloader.diagnostics()
        let modeText: String
        switch diag.transportMode {
        case .direct: modeText = "direct"
        case .proxy: modeText = "proxy"
        case .accelerated: modeText = "accel"
        }
        // 不输出 URL 查询参数/签名/Cookie；Mbps 为估计聚合值，仅供参考
        return String(format: "accel mode:%@ nodes:%d/%d busy:%d est %.1fMbps sub:%d fail:%d retry:%d ratio:%.2f ahead:%d/%.1fMB%@",
                      modeText, diag.candidateCount - diag.bannedCount, diag.candidateCount, diag.activeHosts, diag.estimatedAggregateMbps,
                      diag.activeSubrequests, diag.failures, diag.retries,
                      diag.redundancyRatio, diag.readAheadSlots, Double(diag.readAheadBytes) / 1_048_576,
                      diag.downgradedToDirect ? " downgraded" : "")
    }
}

/// 当前播放会话内的媒体代理注册表（同步线程安全）。
/// 媒体 ID 映射到当前会话已注册的媒体流及其 CDN 候选；不接受外部 URL，不跨会话共享。
/// 对外只提供不可变的元信息快照：totalLength 的写入（锁内）与读取（快照拷贝）
/// 不会竞争；downloader 自身是 actor，跨线程引用安全。
final class MediaProxyRegistry: @unchecked Sendable {
    /// 不可变的单次请求视图。downloader 为 actor 引用，可在 handler 线程使用；
    /// totalLength/candidates 为读取时刻的拷贝。
    struct MediaSnapshot {
        let candidates: [String]
        let referer: String
        let downloader: MediaRangeDownloader
        let totalLength: Int64?
    }

    private final class Entry {
        let candidates: [String]
        let referer: String
        let downloader: MediaRangeDownloader
        var totalLength: Int64?
        init(candidates: [String], referer: String, downloader: MediaRangeDownloader) {
            self.candidates = candidates
            self.referer = referer
            self.downloader = downloader
        }

        func snapshot() -> MediaSnapshot {
            MediaSnapshot(candidates: candidates, referer: referer,
                          downloader: downloader, totalLength: totalLength)
        }
    }

    private let lock = NSLock()
    private var entries = [String: Entry]()
    private var idByMedia = [VideoPlayURLInfo.DashInfo.DashMediaInfo: String]()

    func register(media: VideoPlayURLInfo.DashInfo.DashMediaInfo, candidates: [String], referer: String, downloader: MediaRangeDownloader) {
        lock.lock()
        defer { lock.unlock() }
        if idByMedia[media] != nil { return }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        idByMedia[media] = id
        entries[id] = Entry(candidates: candidates, referer: referer, downloader: downloader)
    }

    func id(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return idByMedia[media]
    }

    /// 锁内一次性拷贝，后续读取不再触碰共享可变状态。
    func snapshot(for id: String) -> MediaSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.snapshot()
    }

    /// 取指定媒体的下载器引用（actor，跨线程使用安全），用于设置信任锚点等。
    func downloader(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo) -> MediaRangeDownloader? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = idByMedia[media] else { return nil }
        return entries[id]?.downloader
    }

    func updateTotalLength(_ total: Int64, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[id]?.totalLength = total
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        idByMedia.removeAll()
        lock.unlock()
    }
}

enum BVideoUrlUtils {
    static func sortUrls(base: String, backup: [String]?) -> [String] {
        var urls = [base]
        if let backup {
            urls.append(contentsOf: backup)
        }
        // 只把 PCDN 垫底；其余保持 API 返回顺序，具体快慢交给动态测速
        return urls.enumerated()
            .sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }
            .map(\.element)
    }

    // PCDN 特征：带端口，或已知的 P2P CDN 域名（部分 PCDN 域名不带端口，仅靠端口判断会漏）
    static func isPCDN(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString) else {
            return false
        }
        if components.port != nil {
            return true
        }
        guard let host = components.host?.lowercased() else {
            return false
        }
        return host.hasSuffix("szbdyd.com") || host.hasSuffix("mcdn.bilivideo.cn")
    }

    /// 0 = 普通 CDN，1 = PCDN（仅作安全策略垫底，不再做 upos/akam 等静态速度假设）
    static func tier(_ urlString: String) -> Int {
        isPCDN(urlString) ? 1 : 0
    }

    static func convertVTTFormate(_ time: CGFloat) -> String {
        let seconds = Int(time)
        let hour = seconds / 3600
        let min = (seconds % 3600) / 60
        let second = CGFloat((seconds % 3600) % 60) + time - CGFloat(Int(time))
        return String(format: "%02d:%02d:%06.3f", hour, min, second)
    }

    static func convertToVTT(subtitle: [SubtitleContent]) -> String {
        var vtt = "WEBVTT\n\n"
        for model in subtitle {
            let from = convertVTTFormate(model.from)
            let to = convertVTTFormate(model.to)
            // hours:minutes:seconds.millisecond
            vtt.append("\(from) --> \(to)\n\(model.content)\n\n")
        }
        return vtt
    }
}

extension VideoPlayURLInfo.DashInfo.DashMediaInfo {
    var playableURLs: [String] {
        BVideoUrlUtils.sortUrls(base: base_url, backup: backup_url)
    }

    var isHevc: Bool {
        return codecs.starts(with: "hev") || codecs.starts(with: "hvc") || codecs.starts(with: "dvh1")
    }
}

actor SidxDownloader {
    struct SidxResult {
        let sidx: SidxParseUtil.Sidx
        let url: String
        /// 索引区间的原始字节（等价性验证的信任锚点，不参与播放数据）。
        let indexBytes: Data
    }

    private enum CacheEntry {
        case inProgress(token: UUID, task: Task<SidxResult?, Never>)
        case ready(SidxResult)
    }

    // sidx 只有几 KB，用短超时的独立 Session，避免默认 60s 超时把起播卡死
    private static let session: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    private let maxEntries: Int
    private var cache: [VideoPlayURLInfo.DashInfo.DashMediaInfo: CacheEntry] = [:]
    private var accessOrder: [VideoPlayURLInfo.DashInfo.DashMediaInfo] = []

    init(maxEntries: Int = 16) {
        self.maxEntries = maxEntries
    }

    func sidx(from info: VideoPlayURLInfo.DashInfo.DashMediaInfo, preferredHost: String? = nil) async -> SidxResult? {
        if let cached = cache[info] {
            touch(info)
            switch cached {
            case let .ready(sidx):
                Logger.debug("sidx cache hit \(info.id)")
                return sidx
            case let .inProgress(_, task):
                Logger.debug("sidx cache wait \(info.id)")
                return await task.value
            }
        }

        let token = UUID()
        let task = Task<SidxResult?, Never> {
            guard !Task.isCancelled else { return nil }
            return await downloadSidx(info: info, preferredHost: preferredHost)
        }

        cache[info] = .inProgress(token: token, task: task)
        touch(info)

        let sidx = await task.value
        guard case let .inProgress(currentToken, _) = cache[info],
              currentToken == token
        else {
            return nil
        }
        if let sidx {
            cache[info] = .ready(sidx)
        } else {
            cache[info] = nil
            accessOrder.removeAll { $0 == info }
        }
        trimToCapacity()
        Logger.debug("get sidx \(info.id)")
        return sidx
    }

    func cancelAll() {
        for entry in cache.values {
            if case let .inProgress(_, task) = entry {
                task.cancel()
            }
        }
        cache.removeAll()
        accessOrder.removeAll()
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func touch(_ info: VideoPlayURLInfo.DashInfo.DashMediaInfo) {
        accessOrder.removeAll { $0 == info }
        accessOrder.append(info)
    }

    private func trimToCapacity() {
        while cache.count > maxEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            if case let .inProgress(_, task) = cache[oldest] {
                task.cancel()
            }
            cache[oldest] = nil
        }
    }

    private func downloadSidx(info: VideoPlayURLInfo.DashInfo.DashMediaInfo, preferredHost: String? = nil) async -> SidxResult? {
        let range = info.segment_base.index_range
        var urls = info.playableURLs
        // sidx 只有几 KB，探测到的只是延迟不是吞吐；运行时如果发现当前 host 扛不住实际码率，
        // 由外部指定 preferredHost 时强制优先试这个 host
        if let preferredHost,
           let idx = urls.firstIndex(where: { URLComponents(string: $0)?.host == preferredHost })
        {
            urls.insert(urls.remove(at: idx), at: 0)
        }
        for url in urls.prefix(3) {
            guard !Task.isCancelled else { return nil }
            let host = URLComponents(string: url)?.host ?? url
            let start = Date()
            if let res = try? await Self.session.request(url,
                                                         headers: ["Range": "bytes=\(range)",
                                                                   "Referer": "https://www.bilibili.com/"])
                .serializingData().result.get(),
                !Task.isCancelled,
                let segment = SidxParseUtil.processIndexData(data: res),
                !segment.segments.isEmpty
            {
                Logger.info("sidx ok in \(elapsedMs(since: start))ms from \(host)")
                return SidxResult(sidx: segment, url: url, indexBytes: res)
            }
            Logger.warn("sidx download failed in \(elapsedMs(since: start))ms on \(host), try next url")
        }
        return nil
    }
}


// Separate opt-in LAN exporter. The media server remains loopback-only.
// Retained across quality switches/player teardown so the failure trace survives.
final class BTRTraceExport {
    static let shared = BTRTraceExport()
    private var server: HttpServer?
    private(set) var address: String?
    private(set) var diagAddress: String?

    /// 只开下载服务导出闪退诊断报告（不清空、不开始 BTR 记录）。
    func startDiagnostics() throws -> String {
        if let diagAddress { return diagAddress }
        _ = try start(recordBTR: false)
        return diagAddress ?? ""
    }

    func start(recordBTR: Bool = true) throws -> String {
        stop()
        let server = HttpServer()
        server.listenAddressIPv4 = "0.0.0.0"
        let token = UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(12).lowercased()
        let path = "/" + token + "/btr.jsonl"
        server[path] = { _ in
            BTRTrace.shared.freeze()
            let bytes = Data(BTRTrace.shared.export().utf8)
            return HttpResponse.raw(200,"OK",["Content-Type":"application/x-ndjson; charset=utf-8",
                "Content-Disposition":"attachment; filename=btr-diag13.jsonl",
                "Cache-Control":"no-store","Content-Length":String(bytes.count)]) { writer in
                try writer.write(bytes)
            }
        }
        let diagPath = "/" + token + "/diag.txt"
        // 纯文本直接在浏览器里显示（不再强制下载）。
        server[diagPath] = { _ in
            let bytes = Data(Diag.exportText().utf8)
            return HttpResponse.raw(200,"OK",["Content-Type":"text/plain; charset=utf-8",
                "Cache-Control":"no-store","Content-Length":String(bytes.count)]) { writer in
                try writer.write(bytes)
            }
        }
        // 带「复制全部」按钮的网页，手机上也方便复制。
        let pagePath = "/" + token + "/diag"
        server[pagePath] = { _ in
            let escaped = Diag.exportText()
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>诊断日志</title><style>
            body{margin:0;font:15px -apple-system,system-ui,sans-serif;background:#111;color:#eee}
            header{position:sticky;top:0;display:flex;gap:10px;align-items:center;padding:12px 16px;background:#1c1c1e;border-bottom:1px solid #333}
            button,a.btn{font:inherit;padding:10px 18px;border-radius:999px;border:0;background:#fff;color:#000;text-decoration:none}
            a.btn{background:#333;color:#fff}#s{color:#8e8e93}
            pre{margin:0;padding:16px;white-space:pre-wrap;word-break:break-all;font:12px ui-monospace,Menlo,monospace}
            </style></head><body><header><button id="c">复制全部</button><a class="btn" href="diag.txt" download="bili-diag.txt">下载 txt</a><span id="s"></span></header>
            <pre id="t">\(escaped)</pre><script>
            document.getElementById('c').onclick=async()=>{const t=document.getElementById('t').innerText,s=document.getElementById('s');
            try{await navigator.clipboard.writeText(t);s.textContent='已复制';}catch(e){const r=document.createRange();r.selectNodeContents(document.getElementById('t'));
            const sel=getSelection();sel.removeAllRanges();sel.addRange(r);s.textContent=document.execCommand('copy')?'已复制':'已全选，请手动复制';}};
            </script></body></html>
            """
            let bytes = Data(html.utf8)
            return HttpResponse.raw(200,"OK",["Content-Type":"text/html; charset=utf-8",
                "Cache-Control":"no-store","Content-Length":String(bytes.count)]) { writer in
                try writer.write(bytes)
            }
        }
        do { try server.start(0,forceIPv4:true) }
        catch { server.stop(); throw error }
        let port: Int
        do { port = Int(try server.port()) }
        catch { server.stop(); throw error }
        self.server = server
        let base = "http://" + (Self.localIPv4() ?? "APPLE-TV-IP") + ":" + String(port)
        let address = base + path
        self.address = address
        diagAddress = base + pagePath
        if recordBTR {
            BTRTrace.shared.start()
            BTRTrace.shared.event("recording_started")
        }
        return address
    }
    func stop() {
        BTRTrace.shared.freeze()
        server?.stop(); server = nil; address = nil; diagAddress = nil
    }
    private static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var current = list
        while let ptr = current {
            defer { current = ptr.pointee.ifa_next }
            let item = ptr.pointee
            guard let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString:item.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(addr,socklen_t(addr.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {
                return String(cString:host)
            }
        }
        return nil
    }
}
