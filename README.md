# uu伴侣 (UU Companion)

Free and open-source accountless microphone sharing between Macs.

**中文**：让另一台 Mac 的实体麦克风，像本机麦克风一样被 ChatGPT、会议软件和任意录音应用使用。完全免费，MIT 开源，不要求账号或订阅。

## 主要功能

- 局域网：Bonjour 发现或指定 IP，直接 TCP 连接。
- 公网：两端主动连接 WSS 免费中继，无需固定 IP、端口映射或 VPN。16 位随机配对码代替登录账号。
- 音频在两台 Mac 上经过 CryptoKit ChaCha20-Poly1305 加密，Relay 只看到密文。
- 接收端使用开源的 uu伴侣 Native Mic 驱动（macOS AudioServerPlugIn），不依赖付费 Loopback。
- 当接收端开始录音才自动开启发送端实体麦克风，停止约 3 秒后关麦；心跳超时和异常退出也会关闭麦克风。
- 可选自部署 Relay 服务。官方免费服务不是使用这个应用的必要条件。

## 用户怎么配对

1. 在两台 Mac 安装、启动同一个 uu伴侣 App。发送端允许麦克风权限；接收端安装 Native Mic 驱动。
2. 提供麦克风的 Mac：菜单栏 uu伴侣 → 生成新配对码…。16 位随机码自动复制到剪贴板。
3. 接收麦克风的 Mac：菜单栏 uu伴侣 → 输入配对码…，粘贴并确认。
4. 两端显示公网已连接后，打开 ChatGPT 或其他软件，选择 uu伴侣 Native Mic，直接说话。
5. 配对后不必重复输入。想撤销配对，发送端重新生成配对码，或两端切回局域网直连。

注意：这个 16 位配对码是**长期有效的访问凭据**，不是六位数字一次性验证码。不要在公开截图中展示，想撤销原码可重新生成。无需登录账号。

在菜单栏的 发现 / 中继服务器… 也可以填写任意自部署的 WSS 服务地址。**双方必须使用同一个服务地址。**

## 传输架构

发送端 MagicBook（实体麦克风）：
 - uu-sender 在本机 TCP 50555 端口服务
 - uu-cloud-bridge 将本机流通过 WSS 加密发送到 Relay

公开开源 Relay：只协调发现和转发加密数据，不保存原始配对码、不解密录音。

接收端 Mini（ChatGPT）：
 - uu-cloud-bridge 仅在 127.0.0.1:50556 提供本机 TCP 代理
 - uu-receiver 通过代理接收加密传输后的音频
 - 自有 Native Mic 将声音提供为标准系统输入设备

目前跨公网的 Anywhere 模式是**加密服务器中继**，并非 ICE/P2P 直连。局域网直连是另一个独立模式，不走服务器。

## 本地构建和安装

要求 macOS 14.2+、Apple Silicon。已在 macOS 27 的 Mac mini 和 MagicBook 上完成真实硬件验收。

首先编译：./build.sh

接收端安装虚拟麦克风：运行 NativeMic/package.sh 生成本机测试安装包，然后使用 macOS Installer 安装 NativeMic/build/UUMicNative-0.1.2.pkg，正常确认管理员权限。驱动源码及注意事项见 NativeMic/README.md。

首次安装仍需一份用于本机 Legacy TCP 鉴权的随机密钥文件，安全方式生成：
    openssl rand -hex 32 > .pairing-secret

本地发送端：
    ./install.sh sender .pairing-secret

本地接收端：
    ./install.sh receiver .pairing-secret 发送端局域网IP

在跨公网 Anywhere 模式下，两台 Mac 的这个 Legacy TCP 密钥**不必相同**，因为各自只用于本机 Bridge ↔ 本机音频服务的认证。公网两端的加密与发现使用独立的配对码。不要把密钥或配对码提交到 GitHub。

首次打开 App 应遵守 macOS 提示完成麦克风、本地网络与登录项授权。接收端默认输入设备可以设置为 uu伴侣 Native Mic；默认播放输出仍为扬声器。

## 公共服务器与自部署

免费公开中继：wss://uu-companion-relay.auv1107.workers.dev

健康检查：https://uu-companion-relay.auv1107.workers.dev/health

服务器代码：Relay/worker.mjs（MIT）。使用自己的 Cloudflare 免费账户可运行：
    CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... python3 Relay/deploy.py

脚本仅使用 Python 3 标准库和 Cloudflare 官方 API。详细说明见 Relay/README.md。

**完全免费、没有付费功能**不等于托管流量无限：Cloudflare 免费计划有使用配额，免费公共实例属于尽力服务；超过免费额度时流量可能受限。即使公共实例停用，局域网直连和自部署仍可使用。

## 安全与限制

- 公网通道：TLS WebSocket + 设备端 ChaCha20-Poly1305；中继只处理密文。
- 配对码使用 16 个 Base32 字符，约 80 bit 随机熵，经域分离 SHA-256 导出房间标识和两个方向密钥。客户端本地文件权限为 0600。
- 服务器仍可看到配对房间哈希、客户端 IP、连接时间和流量大小；本项目尚未经过独立密码学审计，也尚未实现完整的反重放保护。
- 当前公网模式不能穿透之后的 ICE/P2P；音频由 Relay 转发，因此中继配额会影响使用时长。
- 自有驱动的本机注入接口尚未完成强进程身份校验，请仅在可信 Mac 上使用。
- 面向公众的开发者签名、公证、全自动安装、全面长时间稳定性测试待发布验收。当前源码可由开发者本地构建，不应绕过 Gatekeeper 安全保护。

## 验收结果

- 局域网 Native Mic 实际录制 398,400 帧，其中 364,273 个非零采样。
- 公网加密音频桥接后，Mini 独立录音测试捕获 398,400 帧，其中 316,589 个非零采样；发送端停止录音后自动关麦。
- 已在两台 Mac 验证 WSS 上线、鉴权连接、MagicBook 远端录音控制、Mini 虚拟音频输入。
- 本机 Git 提交与原始验收记录：ACCEPTANCE-NATIVE-2026-11-11.md。

## License

MIT。原始第三方 MIT 授权声明见 THIRD_PARTY_NOTICES.md、LICENSE-MicBridge-MIT.txt 和 NativeMic/LICENSE-Hush-MIT.txt。
