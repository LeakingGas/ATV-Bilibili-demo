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
5. 等待响应头期间取消、以及不调用Task.cancel而仅改变seek generation，均须2秒内结束真实请求并释放额度。
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
- `rescue`：启动备用竞速请求的次数，不代表成功救回次数；跳转时重置。
- `video/audio last`：各轨最近非取消错误及距今秒数。HTTP 412/429 可定位服务端限制，network -1001 为超时，truncated 为响应不足，mismatch 为 Range/内容不匹配。成功后仍保留最近错误，跳转时清空。
- `gen`：播放代次；跳转后改变，用于检查旧请求是否清理。
- 原 `hosts/sub/fail/retry/est Mbps` 仍是被采样下载器的数据，并非全会话合计；est Mbps 是历史估计，不是实时有序交付速度。ratio 也不能单独用作浪费带宽判据。

建议分别录下正常播放、卡顿出现前后约 10 秒、拖动进度后约 10 秒的浮层，同时记录清晰度和倍速。优先判断 ahead 是否下降、queue 是否积压、错误是否持续刷新、是否退回 direct。仅凭一个数字不能断定原因。

诊断不输出完整地址、签名、Cookie 或错误描述中的 URL。新增代码已做语法解析与 diff 检查；尚未经 Xcode 编译或 Apple TV 显示验证。实际截止时间倒计时、逐 CDN 实时速度和有序交付速率尚未加入浮层。
