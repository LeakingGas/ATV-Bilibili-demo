# BTR → tvOS 下载核心移植

## 定位

这是 BTR 下载层的 Swift 原生移植，替换 `MediaRangeDownloader` 内部算法，不是修补旧 ATV AIMD 实现。保留该类型名只是为了保持 ATV 的 loopback HTTP 适配接口。UI、账号、DASH/SIDX/HLS 转换、AVPlayer 及原有 direct 回退路径未重写。

BTR 浏览器 DOM、MSE、脚本注入与播放器接管不进入 tvOS。自动并发、playback deadline、early rescue 已原生接入；无可用分片时间映射时保留BTR compatibility计时路径。地址刷新与 CDN host 重写/ban-list 没有移植，候选仅采用 ATV API 返回的带签名 URL。这仍不是浏览器插件逐功能复刻。

AVPlayer由主线程每250ms采样；HLS字节范围与累计EXTINF时间来自同一次播放列表生成。视频、音频及自动清晰度rendition共享一个BTRPlaybackSession，控制器只收到纯数值，不跨线程读取AVPlayer。初始化/索引请求使用critical队列；媒体按实时deadline获得紧迫度和等待老化加权。

显式拖动/时间跳变使旧generation失效；排队、网络、背压写入都会退出。倍速变化会重新计算deadline；暂停及超过1.5秒未刷新的播放快照不产生媒体deadline，也不触发低缓冲加并发。状态恢复后重新计算。手动换清晰度和退出会关闭旧会话。

## 逐函数对应

| BTR 原文件/函数 | Swift 对应 | 行为与适配 |
|---|---|---|
| range-core.js `splitRange` | BTRPolicy.split | 均分、余数分配；用原版 JS 生成对照数据 |
| idm-downloader.js `recordMeter` | BTRPolicy.record | 48KiB 采样下限、0.7/0.3 EWMA |
| `adaptiveMinChunk` | BTRPolicy.minimumChunk | 0.6秒目标、64KiB台阶、1MiB上限、跨源铺开 |
| `hedgeDelayMs` | BTRPolicy.hedgeDelay | 250–900ms、1.5倍实测分片时间 |
| `assignPrimaries` | BTRPolicy.assign | 平滑加权轮转、1/12淘汰、尾部未知节点试探、每第四个小 Range 试探 |
| `Semaphore.acquire/drainQueue` | MediaDownloadBudget.acquire | queue class、实时deadline紧迫度、普通请求等待老化、FIFO；原生可取消10ms异步队列轮询；音视频共享自适应额度 |
| `createAutoConcurrency` | BTRAutoConcurrency / BTRPlaybackSession | 原版8/12/16/24/32/48/64梯度；2.5秒冷却、10秒试运行、5秒吞吐/饱和窗口、90秒软冷却、412/429后180秒硬冷却；起播16、15秒缓冲舒适阈值 |
| `hedgeDue` / `observeFirst` / `createEarlyHedge` | BTRHedgeObservation / BTRRescue / waitForHedge | 从连接实际开始计时；有余量不复制；慢于同伴/预计赶不上时有界救援；每个Range共享progress与stale预算 |
| `downloadPiece`/`keepProgress`/`liveProgress`/`begin` | downloadPiece / Piece / Context / lane | 三轮、25秒重试准入窗口、500/1000ms轮间等待、双路竞速；拿到连接许可后重新读取最长前缀；>=32KiB只请求缺失尾部 |
| `Promise.any`/`firstFailure` | race | 仅成功胜出；主路失败即启动备路；成功后立即取消副本，移除旧100ms比较宽限 |
| `attempt`/`readBody` | BTRHTTPClient | URLSession delegate原生块读取；首响应5.5秒、无进展4秒、总尝试15秒；检查206、Content-Range、总长、实际长度 |
| cdn-resolver.js `success`/`sample`/`speed`/`failure` | sample / speed / health / pool | 节点速度0.65/0.35平滑、90秒有效期、取消副本也测速、3*2^failures退避（60秒封顶）；当前以完整候选URL为key，没有移植跨签名URL的route复用 |
| `downloadStartupMediaRange` / `onOrderedChunk` | stream | 无测速时先64KiB探针；完成块按序交付；tvOS适配为2MiB窗口，不缓存整个大Range |

BTR 完整原函数保留于 `ThirdParty/BTR/src/`，作为审查依据和测试 oracle，而非生产时执行的 JavaScript。生产代码只有 Swift。源版本固定，不依赖在线脚本。

## 原生边界

- 主分片数随自动额度变化，扣除ceil(额度/8)的救援份额；音频分片数限制为该份额。所有会话全局64/每host8硬上限；控制器可升档上限同时受已注册候选host数*8约束，例如仅两个host最多16。8起步，起播尝试16（受host约束），不是固定开64连接。每track最多2个Range生产者，单个Range最大16MiB沿用ATV限制。
- 自动控制算法保留原版的回退判据（稳态饱和且试运行吞吐低于baseline才回退）；采样仅计完整胜出分片，不把落选副本字节算成收益。每50ms检查deadline救援；early deficit只在新数据进展时累计，避免两个空轮询误触发。
- tvOS适配：控制器状态按播放item隔离，不保留浏览器page跨视频历史；显式时间跳变均重新进入起播阶段，而不是只在缓冲外seek时重置。
- 两个2MiB窗口生产者加双路副本/前缀和有界pipe，使活跃缓冲有界。不是严格全进程RSS上限；URLSession、多个track和AVPlayer另有内存。真机需测峰值内存。
- 新增 SIDX anchor/小样本一致性门控是tvOS安全适配，不是BTR原有算法。样本失败不放行，已知总长变化不放行。采样不能证明全文件逐字节相同；仅用API为同一representation返回的候选。
- 每条HTTP请求持有唯一预算许可；成功、错误、取消都等待显式释放。URLSession delegate完成后才返回，避免落选者后台继续下载。
- 不记录或输出签名URL、Cookie或账号信息。URLSession不发送持久Cookie，保留原Referer/User-Agent，要求identity编码。
- estimatedAggregateMbps仍只是源测速估计，不是实际AVPlayer有用吞吐；extraBytes含样本、重复及未交付字节，活动窗口尚未交付时会暂时偏高。

## 现有问题依据与结论限制

旧源确实存在固定1秒hedge、胜者最多再等100ms、失败后整块重取、按轮转而非速度权重分派，以及URLSession AsyncBytes逐字节组装。新实现用BTR对应实现替换这些路径。

它们是源码中可确认的机制，不是已复现的用户卡顿根因。`transport: accel / hosts:2 / sub:8`只说明启用了加速及活动请求，不能证明有效吞吐或没有队头阻塞。改善幅度需要同视频、同码率、同网络的真机对照。
