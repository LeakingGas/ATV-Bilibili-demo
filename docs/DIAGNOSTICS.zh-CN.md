# diag9 诊断版：先定位，再修复

本版以已在设备上测试的 diag7 下载调度为基线，只增加诊断记录。没有包含 diag8 的滚动调度改动；仍然永不直连。

## 操作（一次复现）
1. 上传本包中的 BilibiliLive、Tests、docs 到仓库根目录并提交，启动新的 Actions Run workflow/main。构建成功后下载 IPA，通过 ATVLoadly 覆盖安装。播放 debug 应显示 BTR diag:9 trace。
2. Apple TV 应用的设置 → 音视频 → BTR 诊断日志 → 开始新记录。记下显示的下载地址，按“返回”，正常打开视频。
3. 同一个视频先用 1080 播放约 20 秒，再切 4K。若卡住，等待约 15 秒。不要反复切画质、重启或更换视频。
4. 最好直接在同一网络的 Windows 浏览器打开第 2 步的地址；下载会自动冻结记录，下载 btr-diag9.jsonl。也可返回应用设置 → BTR 诊断日志 → 冻结记录并显示下载地址。
5. 把 btr-diag9.jsonl 发到聊天。下载后可关闭日志下载服务。

保持 Apple TV 应用在前台；不必打开 ATVLoadly。地址只用于同一局域网，媒体代理依然只监听 127.0.0.1。若地址含 APPLE-TV-IP，请换成 Apple TV 系统设置中的 IP。不要再次点“开始新记录”，否则会清空本次记录。

## 日志如何定位
- quality_switch、track_registered、stream_begin：关联切换、会话、音/视频、清晰度、编码、CDN 候选。
- playlist_begin、index_result、proxy_request、proxy_rejected：区分索引等待、播放器未发媒体请求、Range 被拒绝。
- queue_begin/end、verify_begin/end：区分排队和 CDN 样本验证耗时。
- http_begin/headers/first_byte/progress/end/timeout：每次实际 HTTP 尝试独立编号，关联父请求。只输出 host、字节范围、数量、状态码和时间；不输出 URL 查询参数。
- piece_round、hedge_start、piece_ready、ordered_delivery：定位断点续传、重复补救及具体阻塞连续交付的分片。
- pipe_backpressure、proxy_read、proxy_write：区分生产者没供数、管道满、向 AVPlayer 写入阻塞。
- player_sample：每秒记录播放位置、缓冲、清晰度、状态、空缓冲、错误码、并发上限。

时间均以开始记录为零点，单位 ms。最多记录 10 分钟、最近 12000 条，每条上限 2048 字节；首行 overwritten 表示覆盖了多少旧事件。应在复现后立即冻结，通常一两分钟足够。冻结/下载保留数据；新记录或应用进程退出会丢弃旧数据。

## 验证与限制
已做：本地 Swift 语法解析、diff 空白检查、检查新增调用与项目现有类型/接口一致、ZIP 文件一致性检查。
已加入 Actions：实际生产下载器下的请求 ID 传递、导出 JSON 解析、签名查询不泄露、冻结稳定性、环形日志顺序与容量测试；随后完整 Xcode archive。
尚未运行：本机无 Swift/Xcode，新增 Swift 测试与 tvOS 编译未在本机执行；LAN 导出入口需在 Apple TV 上首次验证。构建成功不等于卡顿原因已经确认。
日志能缩小故障范围，但不能保证一次就覆盖所有故障；只有关联到具体阻塞链并复现后才修改播放逻辑。
