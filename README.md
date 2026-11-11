# uu伴侣 / UU Companion

独立 macOS 菜单栏应用，把一台 Mac 的实体麦克风按需透传给另一台 Mac 的虚拟输入设备。

## 当前工作状态（2026-11-11）

在 macOS 27 Mini、MagicBook 的局域网组合中，已用 uu伴侣自己的 Native Mic 完成真实声音录制验收：

- 接收端默认输入：uu伴侣 Native Mic（0.1.2，自有 AudioServerPlugIn）；默认输出 Mac mini Speakers。
- MagicBook 发送 44.1 kHz 实体麦克风声音；Mini 自有接收端重采样至 48 kHz 后注入 Native Mic。
- Mini 独立录音自测 398400 帧，其中 364273 个非零采样。
- 录音开始时自动开麦，停止约 3 秒后自动关闭；收音机端加入心跳超时保护。
- 原有 Loopback 和 BlackHole 留在系统作为回退，但不参与 Native Mic 正常运行。

Native Mic 源码、MIT 许可和开发安装工具见 NativeMic/README.md。

## 安装说明

目前仅提供本机测试版，macOS 14.2+ Apple Silicon；自有驱动仅在 macOS 27 进行过完整实测。

1. 在 Mini 上运行 NativeMic/package.sh 构建测试安装包，用 macOS Installer 打开 NativeMic/build/UUMicNative-0.1.2.pkg，批准系统管理员授权。
2. 确认系统设置的声音输入中出现「uu伴侣 Native Mic」。
3. 在 Mini 和 MagicBook 上执行 ./build.sh 构建 uu伴侣.app；实际安装所需的两个本机应用需使用相同的随机配对密钥文件。
4. 发送端：./install.sh sender .pairing-secret
5. 接收端：./install.sh receiver .pairing-secret 发送端IP
6. 两端首次打开 ~/Applications/uu伴侣.app，允许麦克风、本地网络和登录项权限。接收端默认输入会自动选择 Native Mic。

配对密钥可在可信机器通过 openssl rand -hex 32 生成，应只在本地安全传输，不得提交到仓库。旧设置如存在会被安装脚本备份；接收端原来可用的虚拟音频设备会优先保留。

没有自有驱动时，若已安装备用 Loopback，「uu伴侣 Mic」仍可运行并可随时回退：
- NativeMic/activate-native.sh：选自有驱动，重启 uu伴侣后生效。
- NativeMic/restore-loopback.sh：使用已有的 Loopback 备用虚拟设备，重启 uu伴侣后生效。

## 功能

- 两端同一个 App：sender 负责录制本地实体麦克风，receiver 负责监视虚拟输入是否被应用实际使用。
- 接收端按需触发、自动关麦、断线重连，并提供菜单栏暂停和日志入口。
- 随机共享密钥阻止未配对的远端请求开启本地麦克风。
- 进程看门狗确保菜单栏退出/异常终止后收音辅助进程退出。
- macOS SMAppService 注册开机登录项（整机重启自启尚未实测）。

## 安全和发布限制

- 当前网络音频载荷是未加密的 PCM/TCP；只可在可信局域网使用，不能直接暴露公网 50555 端口。跨公网必须使用加密 VPN。
- 驱动自定义注入属性仍可被其他本地进程调用，待上线前需完成本机进程身份验证或专用 IPC 授权。
- NativeMic .pkg 当前为本机未签名测试安装包；正式公开发行前必须使用 Developer ID Installer 签名与 Apple 公证。
- 真正的 ChatGPT 文字转录 UI、整机重启的自动登录项、长时间稳定性还需要独立验收。
- 不要在上述验收完成前卸载 Loopback 备用设备。

## 开源引用

- MicBridge（iecht / MIT）：采集、监听、基础协议与 HAL 输出相关原始代码；根目录 LICENSE 保留其 MIT 许可。
- Hush（Tim Schmolka / MIT）：Native Mic 虚拟输入 HAL 结构；其 MIT 许可在 NativeMic/LICENSE-Hush-MIT.txt 和驱动资源中附带。

## 开发者构建签名

默认本地调试使用 ad-hoc 签名。需要稳定正式应用身份时，可通过环境变量 UU_COMPANION_SIGN_IDENTITY 指定 Developer ID Application 证书给 ./build.sh 使用；NativeMic/build.sh 相应支持 UU_DRIVER_SIGN_IDENTITY。仅签名应用和驱动不足以公开分发：驱动的安装 PKG 还需要 Developer ID Installer 证书、公证及升级路径验收。
