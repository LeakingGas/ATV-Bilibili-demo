# ATV-BTR 原生移植版（待 macOS 编译验证）

本目录是完整源码，可在 Windows 保存和上传，无需 Mac 或 NAS。

本版已补齐上次明确缺少的两项（自动并发与播放deadline）；请使用本次更新的包，覆盖旧包。

当前状态：已接入 BTR 下载核心、自动并发、播放deadline和seek取消，并更新测试工作流；**尚未运行 macOS 原生测试、Xcode 构建或 Apple TV 真机验证，也没有已生成的 IPA**。不要把源码交付理解为可直接安装的成品。

## Windows 操作

1. 在自己的浏览器登录 GitHub，Fork `https://github.com/yichengchen/ATV-Bilibili-demo`。不用向任何人提供密码、token 或 Apple Account。
2. 解压同目录交付的 `ATV-BTR-upload.zip`。这是需要修改/新增的文件，包含 `.github` 目录。在 fork 的 **Code → Add file → Upload files**，把解压后的顶层文件和文件夹上传到仓库根目录，提交到 `main`。文件路径必须保留，不能把整个外层文件夹嵌进仓库。
3. 打开 **Actions**，如 fork 尚未启用 Actions，先启用。选择 **BTR unsigned tvOS IPA → Run workflow → main**。
4. 等待测试与 Archive 两步都变绿。下载 `ATV-BTR-unsigned` artifact，解压取得 `ATV-BTR-unsigned.ipa`。这份 IPA 没有签名，不能直接安装。
5. 在你自己的 Windows ATVLoadly 中，沿用已经成功安装 Nightly 的签名侧载流程。凭据只在你自己的签名工具里输入；工作流不需要 Apple 密钥、证书、付费开发者账号或 Secrets。
6. 若失败，下载 `BTR-build-diagnostics`，提供失败步骤的日志即可。无需提供登录凭据。

源码项目名和 scheme 均核实为 `BilibiliLive`；最低 tvOS 为 16.0。实际构建工具版本会保存在 artifact 的诊断日志中。Actions 用 macOS runner，签名由你在 Windows 完成；这两个步骤相互独立。

`ATV-BTR-source.zip` 是完整源码快照；`ATV-BTR.patch` 是相对下述 ATV 基线的可审查补丁。上传包用于浏览器操作，完整源码包供保存/审查。若 GitHub 网页不接受覆盖上传，可在 Windows Git Bash 中克隆自己的 fork，将上传包解压覆盖，`git add -A`、`git commit` 后 `git push`；GitHub 的登录仍由你自己完成。

## 源码基线与许可证

- ATV: `46904be27583f57afbd9ba45e6264a81eee80f55`，GPL-2.0，保留根目录 `LICENSE.md`。
- BTR: `49bdfe88e90c78cfa51f7c25de92fffd6cf0924d`，MIT，原文和三份原始核心源码保存在 `ThirdParty/BTR/`。
- BTR MIT 通知另随 app 资源保留在 `BilibiliLive/BTR-LICENSE.txt`。分发本修改版时保留许可证和对应源码；Actions 会随 IPA 打包该次提交的源码。

详细移植对应关系、边界与测试情况见 [BTR-PORT.md](docs/BTR-PORT.md) 和 [VALIDATION.md](docs/VALIDATION.md)。
