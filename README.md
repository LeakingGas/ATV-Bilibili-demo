# Bili-ATV-MultiThread

Apple TV（tvOS）上的哔哩哔哩客户端，用系统播放器播放，视频经本地代理从多个 CDN 节点多线程下载。

基于 [yichengchen/ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo) 修改，下载核心移植自 [Bilibili-thread-ripper（BTR，B 站线程撕裂者）](https://github.com/MrTangLuyao/Bilibili-thread-ripper)。

> **本项目没有任何 Testflight 发放，也没有任何收费版本，从未在 App Store 或其他平台上架。**
> 如果看到有人以收费方式提供本项目或基于本项目的应用，那是未经授权的行为，由此引发的安全风险与本项目无关。
> （这条声明沿用自原项目，原作者明确反对把项目用于商业盈利。）

## 和原版相比

**播放**
- 多线程、多 CDN 节点并行下载：节点自动测速、慢节点自动避开，慢的分片会同时向别的节点请求。
- 起播时只下载播放器正在等的数据，开始播放后再预读后面的内容；视频详情不挡起播。
- HDR10 和杜比视界：加载前按片源自动把电视切到对应的显示模式（需要打开系统的「匹配动态范围」）。杜比视界按片源的配置正确声明，电视显示杜比视界标志。
- 长按触控板 1 秒：2 倍速播放，期间不显示控制栏，松手恢复原速。
- 播完停在最后一帧（毛玻璃）并显示重播按钮，不自动退出；是否自动连播可在设置里开关。
- 加载时显示封面毛玻璃，不黑屏。

**控制栏和面板**
- 最左边的 UP 主按钮：进入主页、关注 / 取消关注。
- 点赞、点踩（长按点赞一键三连）。
- 弹幕设置合并到一个菜单：开关、透明度、显示区域。
- 下滑面板：简介、选集、UP 主的其他视频、相关推荐、评论（可展开回复，按返回先收起展开的评论）。

**列表**
- 推荐里长按「不感兴趣」：提交给 B 站推荐系统，视频从列表消失，后面的顶上来。

**诊断**
- 运行日志、下载过程记录、投屏日志可在设置里扫码导出（地址可选固定或随机），方便排查问题。

## 原版已有的功能

二维码登录、推荐、热门、排行榜、搜索、关注、历史、稍后再看、直播与弹幕、视频弹幕、弹幕防挡、字幕、云视听小电视投屏协议。

![](imgs/1.jpg)
![](imgs/2.jpg)
![](imgs/3.png)

## 获取安装包

本项目不提供现成的安装包，需要自己编译、自己签名侧载：

1. 在本仓库的 **Actions** 里选 **BTR unsigned tvOS IPA**，点 **Run workflow**，分支选 `main`。
2. 跑完后在那次运行页面的最下方下载 **ATV-BTR-unsigned**，解压得到未签名的 IPA。
3. 用你自己的签名工具签名后侧载到 Apple TV。编译流程不需要任何 Apple 账号、证书或密钥。

如果编译失败，下载同一页面的 **BTR-build-diagnostics** 查看失败原因。

最低系统要求：tvOS 16.0。

## 许可证和致谢

- 本项目基于 [yichengchen/ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)，以 **GPL-2.0** 发布，见 [LICENSE.md](LICENSE.md)。分发修改版时须保留许可证并提供对应源码（Actions 编译时会把该次提交的源码一并打包）。
- 下载核心移植自 [Bilibili-thread-ripper（BTR）](https://github.com/MrTangLuyao/Bilibili-thread-ripper)：一个为海外用户加速 B 站播放的浏览器扩展，把视频按字节范围拆开、从多个 CDN 节点并发下载。本项目把它的下载调度（分片、测速、节点选择、慢分片补发、自动并发）用 Swift 原生重写到 tvOS 上。**MIT** 许可，原文和原始核心源码保存在 [ThirdParty/BTR](ThirdParty/BTR)，许可证随应用保留在 `BilibiliLive/BTR-LICENSE.txt`。移植细节见 [docs/BTR-PORT.md](docs/BTR-PORT.md)。
- 原项目的致谢：
  - App Icon [【22娘×33娘】亲爱的UP主，你怎么还在咕咕咕？](https://www.bilibili.com/video/BV1AB4y1k7em)
  - [thmatuza/MPEGDASHAVPlayerDemo](https://github.com/thmatuza/MPEGDASHAVPlayerDemo)
  - [dreamCodeMan/B-webmask](https://github.com/dreamCodeMan/B-webmask)
  - [分析Bilibili客户端的“哔哩必连”协议](https://xfangfang.github.io/028)
