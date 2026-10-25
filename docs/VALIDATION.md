# 验证记录与验收步骤

## 已在本次 Windows 环境执行

- 已核对两个实际仓库的 commit、许可证文本、Xcode project/scheme、同步源码目录及原有 unsigned 构建工作流。
- BTR 原版 `node dev/shared-core-test.js`：12/12 通过。该结果是原版源码健康检查，**不代表 Swift 移植已通过**。
- `node Tests/BTR/oracle.cjs`：直接执行固定版本原函数，生成 40 组加权分配、15 组拆分、4 组测速/竞速参数对照，再加64个自动并发状态转换和8个原版hedgeDue案例，共131组。它们由 macOS 上的 Swift 测试消费。
- BTR原版 `auto-concurrency-test.js`：15/15通过（仍是原版JS测试）。
- 7份新增/修改Swift文件通过tree-sitter语法解析，工作流YAML通过解析；这些不等于Swift类型检查。HTTP故障服务在Windows实跑验证了Range、错误头、截断及尾部补取。
- 本地静态与交付检查结果见交付目录 `LOCAL-CHECKS.txt`。

## 待 Actions 实际执行

本机无 Swift/Xcode，未运行以下测试，未编译出 IPA。

运行 `bash scripts/test-btr.sh` 会编译五份生产 Swift 源码（只替换 Keys.userAgent 常量），并连接本地可控HTTP服务器，不需要B站账号：

1. Swift策略与131组BTR原函数结果逐项一致；另测早期救援预算、暂停/倍速/stale快照deadline。
2. 单源206传输在64KiB后断开，下一轮必须请求65536开始的尾部，最终数据逐字节一致。
3. 慢源与乱序源双路竞争，3MiB内容跨窗口按序交付；结束后活动请求/host归零。
4. 拒绝HTTP200、错误Content-Range、403；SIDX样本冲突源不得拼接，另一有效源仍能完成。
5. 等待响应头期间取消、以及不调用Task.cancel而仅关闭播放会话，均须2秒内结束真实请求并释放额度。
6. 64KiB有界pipe交付512KiB，验证小容量背压无死锁、无丢字节。

通过后工作流用已存在的 `BilibiliLive` scheme，`generic/platform=tvOS`、Release、禁用签名执行archive，验证产物为AppleTVOS，再打包Payload。失败会保留日志，不上传看似成功的IPA。

## Apple TV 实机验收（不能以静态检查代替）

沿用你已经成功的ATVLoadly流程。先保留原Nightly安装包作为回退。改进版与原版使用相同项目bundle配置，重签工具可能覆盖现有安装；请在自己的签名工具中确认目标。

选择同一条曾卡顿的视频、同一清晰度/编码，原版和改进版各播放三次，每次至少5分钟，记录：

- 点击播放到首帧时间；5分钟内卡顿次数和累计等待时间。
- 每分钟观察缓冲是否持续推进；记录实际播放表现，不能只以host/sub数量或测速峰值验收。
- 连续前后seek、快速切换清晰度、退出重进：应无旧画面拼入、花屏、声音错位、请求持续积压。
- 分别测单候选、双候选、网络暂时断开再恢复；原direct回退仍应可用。
- 长视频连续播放30分钟，观察退出后请求归零、应用是否被系统终止；完整内存/能耗数值需要Apple平台诊断环境。

任何花屏、音画错乱、持续重试或退化都应先回退原Nightly。只有Actions通过并完成上述对照后，才可声称此版本可侧载且改善了你的网络场景。当前未作这项结论。

## 尚未覆盖的自动验证

真实CDN签名过期刷新、跨视频/音频共享连接公平性长时间压测、AVPlayer对未知total的206行为、tvOS RSS峰值。自动并发及deadline的源对照与集成测试已写入，但尚未在macOS执行。详见BTR-PORT.md。


## Debug 诊断更新（diag:3）

播放设置中打开 Debug。BTR 信息每秒随浮层刷新，启动尚无 AVPlayer access log 时也显示。

- `auto / reason`：BTR 当前并发上限及调整原因；不是当前连接数。
- `slots / queue`：当前播放会话音视频合计已取得许可的请求数、等待许可数；包括验证请求。
- `ahead`：从播放位置起连续可播放缓冲秒数，不把远处不连续缓冲算进去。
- `play / rate`：播放、等待、暂停或采样过期状态，以及用于截止时间估算的倍速。
- `deadline:mapped`：启用具有时间映射的分片截止时间控制；不表示所有请求都已映射，也不是最早请求剩余时间。暂停/采样过期时为 off。
- `rescue`：启动备用竞速请求的次数，不代表成功救回次数；会话重建时重置。
- `video/audio last`：各轨最近非取消错误及距今秒数。HTTP 412/429 可定位服务端限制，network -1001 为超时，truncated 为响应不足，mismatch 为 Range/内容不匹配。成功后仍保留最近错误，会话重建时清空。
- `gen`：请求会话代次；普通跳转不再使请求失效，关闭会话时改变。
- 原 `hosts/sub/fail/retry/est Mbps` 仍是被采样下载器的数据，并非全会话合计；est Mbps 是历史估计，不是实时有序交付速度。ratio 也不能单独用作浪费带宽判据。

建议分别录下正常播放、卡顿出现前后约 10 秒、拖动进度后约 10 秒的浮层，同时记录清晰度和倍速。优先判断 ahead 是否下降、queue 是否积压、错误是否持续刷新、是否退回 direct。仅凭一个数字不能断定原因。

诊断不输出完整地址、签名、Cookie 或错误描述中的 URL。新增代码已做语法解析与 diff 检查；尚未经 Xcode 编译或 Apple TV 显示验证。实际截止时间倒计时、逐 CDN 实时速度和有序交付速率尚未加入浮层。


## diag:5 请求生命周期修复

现场已证实 lifecycle:4 可起播但反复卡顿，随后 BTR 信息消失且访问地址变为公网；与加速失败回退直连路径一致，但缺少错误日志不能认定最终根因。

发现：时间跳变通知一律增加 generation，使所有已接受的 Range 响应失效，甚至包括 AVPlayer 在通知前发出的新目标请求。修正为固定字节响应保持有效，时间变化只调整调度；连接写入失败取消对应任务，关闭/更换 item 仍取消全部旧请求。权衡：seek 后客户端尚未断开的旧响应可能继续短暂占用额度，不能宣称立即清除所有旧预取。

新增原生回归案例：重复通知保留请求、真实慢 HTTP 响应跨 seek 后字节完整、会话关闭仍在两秒内取消等待请求。测试已纳入现有 Actions 测试入口，当前修订尚未在 macOS 执行；本地仅完成 Swift 语法解析和 diff 检查。

Debug 始终显示 transport，包括 direct；BTR diag:5；失败回退保留数值错误码、底层数值错误码、回退前会话快照及下载器摘要。没有输出 NSError 描述或 userInfo 中的 URL。快照是失败时历史值，不是直连实时值。截图保留该段可用于下一步定位。

验收：普通连续播放、恢复历史位置、前后seek、切换清晰度；检查不因普通时间通知突然取消全部下载。若回退，拍下 BTR failure -> direct 下的错误快照。新改动仍需新 Actions 构建以及真机验证。


## diag5 构建失败排查：/resume -1005

用户提供日志：原生测试在 /resume 出现 NSURLErrorNetworkConnectionLost，最终未捕获顶层错误触发退出133。该URL为本机故障注入服务，并非实际CDN。日志没有逐次接收字节数，不能断言前缀未保存还是断连前未交付。

本次保持生产续传策略与严格断言，调整fixture：64KiB按16KiB分批发送后短暂等待，再以短于Content-Length的EOF结束响应；每次从0起点仍截断，不能靠整块重试绕过测试。仍断言下一请求从65536开始，完整内容逐字节一致。该场景验证已交付前缀后的EOF恢复，不等同于验证所有TCP reset时序。

下载器新增最多12条不含URL的请求记录（Range起止、实际接收长度、结果码）；测试失败时打印该记录，stdout不缓存，顶层捕获错误并退出1。未跳过失败测试。

本机HTTP fixture smoke通过：正确Range、错误头、64KiB截断、尾部恢复；Swift语法解析通过。尚未在macOS运行本次Swift修订，不能声称已修复真实网络卡顿或本次CI根因。新运行如仍失败，请提供 RESUME ATTEMPTS 和 BTR TEST FAILED 行、test-server.log。


## diag:6 实机证据与诊断修正

实机diag:5显示：有序播放、ahead 16.8s；之后自动额度16、slots13、queue3到5、ahead9.6到8.6、历史网络错误-1001/-1005；最终transport:direct。说明请求实际运行且发生回退，不足以证明网络带宽是唯一根因。rescue为累计启动副本数量，不是失败数量。

确认两个诊断缺陷并修复：60秒waiting看门狗绕过playerDidFail里的快照保存；旧hosts/sub仅来自最后完成请求所对应下载器，不是实时会话值。将回退快照移到公共入口，标明waiting-60s或player-failed；新增会话live hosts/http、最近5秒写入有序管道的平均Mbps、上次网络数据和有序写入距今时间。ordered5s是音视频及索引合计写入管道速度，不是AVPlayer实际消费速度；暂停或缓冲充足时低值正常。旧行标明last completed track。

未增加线程或调整救援阈值；本轮是诊断准确性修正，不能宣称修复了吞吐或卡顿。原生语法解析与diff检查通过，Actions类型检查/测试及真机尚待执行。看门狗快照为历史值。


追加：用户报告direct后又自动回到accel。源码确认switchHost调用playmedia(isQualitySwitch:true)，preparedMedia原本重新读取全局BTR开关，覆盖了失败后的direct状态。diag6现保留换源/换画质前的当前传输模式；退出重开视频才重新读取设置。新增异步测速generation检查、回退重入保护、恢复seek/play前检查，防止旧操作操纵新播放器。此行为修正可消除该条模式反复切换路径，但没有证明网络超时全部解决；原生UI回归仍待真机。


## diag:7 BTR-only（用户明确要求）

本节取代之前各节的直连回退说明。点播DASH链路始终使用BTR，忽略旧multiCDNEnabled存储值；设置显示BTR CDN并行（始终开启）。预热、换画质、新视频统一强制加速模式。删除播放器级直连恢复和旧CDN测速换源路径。失败仅记录，不重建成直连。60秒等待仍记录诊断，正在进行的BTR请求可继续恢复。

删除SIDX失败时生成外部媒体播放列表的分支；解析失败抛BTRStrict错误。代理不可用时加载失败。播放器媒体URL仅为loopback；字幕的本地重定向保留。无Range、未知总长的开放/后缀Range、超16MiB请求明确返回503与X-BTR-Error，不再307到外部CDN。此处采用拒绝策略，尚未实现这些请求类型的BTR传输，所以可能降低兼容性；不能将不再直连等同于解决卡顿。

作用范围是本次改造的B站点播音视频链路；BTR本身仍需从CDN下载，SIDX元数据探测、字幕/API及独立直播模块不是这里所说的AVPlayer直连媒体降级。

验证：Swift语法解析、无外部媒体重定向/直连播放列表回退的静态检查和ZIP检查。没有macOS本地编译，也没有真机结果。需Actions构建后验证普通播放、换画质、超时等待、索引失败、代理失败；网络故障期间不得出现transport:direct。标记BTR diag:7 / BTR ONLY。

## diag8: rolling admission instead of a batch barrier

The downloader previously waited for every piece in a 2 MiB window before scheduling any of the next window. It now refills after ordered delivery releases space. Admitted piece bytes, including completed out-of-order results, remain capped at 2 MiB per stream; existing byte-pipe backpressure and concurrency limits remain in force. BTR split/assignment/hedge implementations are unchanged, but pieces are planned for this HTTP range before scheduling rather than replanned after each completed window. Runtime auto-concurrency still gates network permits.

Regression: `/window` holds the piece ending at byte 2162687 (64 KiB startup probe + first 2 MiB window) until a request starting at or beyond 2162688 arrives, with a three-second safety timeout. The native test checks that the next window started before the hold expired, exact final bytes, and zero active requests. This detects the old batch barrier even when final output bytes match.

Local validation: Swift syntax parser and git whitespace checks pass. Python HTTP fixture smoke checks pass, including both blocked and released boundary outcomes. No local Swift compiler/Xcode is available: the new native regression and tvOS archive must run in Actions. This addresses a confirmed scheduling barrier, not a verified complete fix for device 4K stalls. Diagnostic marker is `BTR diag:8`; BTR-only mode remains enforced.

## diag9 diagnostic baseline

Supersedes the diag8 experiment: restored diag7 window scheduling and added opt-in flight recording only. See DIAGNOSTICS.zh-CN.md. Native trace tests are added, not locally executed; Xcode and device LAN export validation remain outstanding.

## diag10 device-proven large Range rejection

Device trace requested bytes=322059864-339048564 (16988701 bytes), 12 repeats. Proxy returned range-over-limit; preceding range ending 322059863 completed. Buffer exhausted and playhead stopped at 130.03685 s. Remove both stream and proxy 16 MiB rejection; keep fetch/Data cap and original bounded windows/backpressure. Native regression replays exact range via 128 KiB pipe and validates every byte/header/cleanup plus fetch cap. Python fixture and syntax checks passed locally; native Swift regression and Xcode archive not run locally. Earlier recoverable stall is a separate unresolved issue.

## diag11 resume once

Device trace restored 23 s after quality change then jumped to 135 s on readiness and later stalled at 156.2959 s. Code reapplied playData.playerStartPos on every new ready player. Consume history once, including when quality switches before initial readiness; capture per-switch fractional target. Add seek source/target events and native state-sequence regression. Existing large-range fix is device-verified (16988701 and 19136126 bytes completed); sustained slow video requests remain unresolved. Syntax/whitespace checks pass locally; native tests/archive pending Actions.
