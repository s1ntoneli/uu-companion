# uu伴侣 — 一个 App 的安装方式

uu伴侣让一台 Mac 使用另一台 Mac 的麦克风。只需下载一个 uu伴侣 App（请从 GitHub Releases 下载，并确认对应版本的 Apple 公证状态）；无需用户账号、付费订阅，也无需关闭 Gatekeeper 或 SIP。

## 用户操作

1. 从 https://github.com/s1ntoneli/uu-companion/releases 下载最新版 One-App ZIP，解压，把 uu伴侣.app 拖入“应用程序”。
2. 启动 uu伴侣，首次选择「提供麦克风」或「使用远程麦克风」。
3. 发送端只需正常授权麦克风，不需要任何驱动。
4. 接收端首次启动时点击「安装 Native Mic」，在 Apple 标准管理员对话框中授权。驱动已包含在 App 内，无需另找安装包、打开终端或手动拖文件到系统文件夹。
5. 安装驱动后，uu伴侣会尝试重新加载 macOS 音频服务，并通过 Core Audio 检查是否真的识别「uu伴侣 Native Mic」。此操作可能短暂中断其他软件的音频；只有重新加载失败时，才需要重启 Mac。
6. **接收端自动进入输入配对码步骤**，发送端自动展示并复制 16 位配对码。看到「另一台 Mac 已在线」和「本机音频已就绪」后，uu伴侣会邀请你「现场试音」。
7. 点击「开始 12 秒试音」，对着提供麦克风的 Mac 说话。程序直接从 Native Mic 录音，并显示电平和有效采样结果，**不保存声音**。通过后再到 ChatGPT、IDE、会议软件中选择「uu伴侣 Native Mic」即可。

## 安装过程与权限

- 内置的 UUMicNative.driver 由 Apple Developer ID Application 签名。安装会先写入系统音频插件目录以外的暂存文件夹、校验签名，再仅替换 uu伴侣自己的驱动。
- 原驱动会备份到 /Library/Application Support/uu伴侣/UUMicNative.previous.driver，不删除其他软件的音频插件。
- 写入 /Library/Audio/Plug-Ins/HAL/ 需要 macOS 管理员授权。uu伴侣不会读取、存储或传送管理员密码。
- 安装时会明确告知用户音频服务重载可能中断其他应用的播放/录音，并使用正常 macOS 管理员授权。若系统能识别设备就不要求整机重启；重载失败或设备仍未出现时才建议重启。
- 如失败，可从菜单「安装 / 修复 Native Mic 驱动…」重新安装。无需命令行。

## 排查

- 接收端看不到 Native Mic：先用菜单「重新加载音频服务」，仍未识别时正常重启；如果依旧没有，请选择「修复 Native Mic 驱动」。
- 已配对但没有波形：检查发送端的麦克风授权，以及菜单中的启动超时提示。macOS 的 Core Audio 卡死时可能需要正常重启发送端。
- 公网不通：确认两端使用同一 WSS 中继服务器。公共中继免费但受配额限制，也支持自部署。
- 16 位配对码是长期有效的访问凭据，不要公开分享。发送端重新生成会撤销旧配对。
- **请核对所下载版本是否已完成 Apple 公证**。已公证 ZIP 首次运行时可由 Gatekeeper 在线查询票据；未经公证的预览版可能被 macOS 阻止启动。不要关闭 Gatekeeper 或 SIP。

开发者可运行 ./build.sh 编译源码；分发版使用 UU_DISTRIBUTION_MODE=1 和 Developer ID 签名。其他信息见 README.md 和 Signing/README.md。

公网模式自动为内部音频选择独立的 127.0.0.1 本机端口，避免与 UU Remote 或其他实例冲突，用户无需手动配置端口。
