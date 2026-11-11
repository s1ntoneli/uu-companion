# uu伴侣 — 一个 App 的安装方式

uu伴侣让一台 Mac 使用另一台 Mac 的麦克风。只下载一个经 Apple 公证的 uu伴侣 App；无需用户账号、付费订阅，也无需关闭 Gatekeeper 或 SIP。

## 用户操作

1. 从 https://github.com/s1ntoneli/uu-companion/releases 下载最新版 One-App ZIP，解压，把 uu伴侣.app 拖入“应用程序”。
2. 启动 uu伴侣，首次选择「提供本机麦克风」或「使用远程麦克风」。
3. 发送端只需正常授权麦克风，不需要任何驱动。
4. 接收端首次启动时点击「安装 Native Mic」，在 Apple 标准管理员对话框中授权。驱动已包含在 App 内，无需另找安装包、打开终端或手动拖文件到系统文件夹。
5. 安装成功后保存工作并正常重启接收端，macOS 的 Core Audio 才会加载新插件。再次打开 uu伴侣即可使用，无需重复安装。
6. 发送端点击「生成新配对码…」，接收端点击「输入配对码…」。在 ChatGPT 等程序中选择 uu伴侣 Native Mic 作为音频输入设备。

## 安装过程与权限

- 内置的 UUMicNative.driver 由 Apple Developer ID Application 签名。安装会先写入系统音频插件目录以外的暂存文件夹、校验签名，再仅替换 uu伴侣自己的驱动。
- 原驱动会备份到 /Library/Application Support/uu伴侣/UUMicNative.previous.driver，不删除其他软件的音频插件。
- 写入 /Library/Audio/Plug-Ins/HAL/ 需要 macOS 管理员授权。uu伴侣不会读取、存储或传送管理员密码。
- 系统音频驱动安装成功后，需要正常重启接收端。App 不会强制重启或关闭 macOS 安全保护。
- 如失败，可从菜单「安装 / 修复 Native Mic 驱动…」重新安装。无需命令行。

## 排查

- 接收端看不到 Native Mic：确认安装成功，正常重启；若仍未出现，尝试菜单「修复 Native Mic 驱动」。
- 已配对但没有波形：检查发送端的麦克风授权，以及菜单中的启动超时提示。macOS 的 Core Audio 卡死时可能需要正常重启发送端。
- 公网不通：确认两端使用同一 WSS 中继服务器。公共中继免费但受配额限制，也支持自部署。
- 16 位配对码是长期有效的访问凭据，不要公开分享。发送端重新生成会撤销旧配对。
- ZIP 的公证票据在首次运行时由 Gatekeeper 通过互联网查询 Apple。无需关闭 Gatekeeper 或 SIP。

开发者可运行 ./build.sh 编译源码；分发版使用 UU_DISTRIBUTION_MODE=1 和 Developer ID 签名。其他信息见 README.md 和 Signing/README.md。
