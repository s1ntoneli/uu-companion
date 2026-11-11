# uu伴侣 Mac2Mac 麦克风联调 — 2026-11-11

## 设备配置
- 发送端 MagicBook：~/Applications/uu伴侣.app
- 接收端 Mini（macOS 27.0）：~/Applications/uu伴侣.app
- 接收端虚拟设备 uu伴侣 Mic（由 Loopback 2.5.1 / ARK 试用版创建）
- 默认输入 uu伴侣 Mic；默认输出、系统输出 Mac mini Speakers
- 传输：可信局域网 TCP 50555，密钥配对，PCM 明文，不能直接对公网开放
- 接收端：AudioQueue 输出到设备 UID，mono PCM 扩展到双声道
- Sender 具有心跳超时关麦保护，接收端异常时自动停止收音

## 故障根因与修复
1. Mini 在 macOS 27 + BlackHole 2ch 0.7.1 上 Core Audio HAL 初始化及 AudioQueueStart 会阻塞，ChatGPT 虽显示麦克风启用却没有音频输入。
2. Loopback/ARK Pass-Thru 解决 BlackHole 驱动问题，但之前使用的 HAL AudioUnit 偶发卡在 AudioUnitSetProperty(CurrentDevice)。
3. uu伴侣接收端改为 AudioQueue 输出，验证在 Loopback GUI 启动和退出后均可正常初始化、重启。

## 2026-11-11 09:12–09:13 实测证据
- 09:12:27 AudioQueue 在 uu伴侣 Mic 以 44.1 kHz 启动；远端麦克风约 0.22 秒开启。
- 09:12:29 接收 88576 个网络 PCM 采样，其中 74789 个非零，峰值 0.014129639。
- 09:12:39 输出回调 1083 次，消费 550400 帧，其中 492470 个非零采样。
- 独立录音自测：48kHz、双声道，约 8 秒，398400 帧，第一声道 382657 个非零采样，峰值 0.031583153。
- 09:13:20 结束测试接收，MagicBook 自动关闭麦克风。
- 09:13:29 恢复正常按需录音模式，Mini 虚拟音频输出初始化成功，连接和配对认证通过；MagicBook 没有持续收音。

## 尚未验收/限制
- 尚未在 Mini 现有 ChatGPT 客户端真正读取转录波形和文本。需由用户在 ChatGPT 中重新启动转录验证。
- Loopback 是试用版，约 20 分钟后叠加噪声，不是长期免费生产方案。
- 完全独立交付需要自有或许可允许、兼容 macOS 27 的虚拟音频驱动，以及重启/登录和 ChatGPT 客户端完整验收。
