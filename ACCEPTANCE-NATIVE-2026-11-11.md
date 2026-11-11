# uu伴侣 Native Mic — 2026-11-11 现场验收

环境：Mini macOS 27 + Native Mic 0.1.2；MagicBook 实体麦克风 44.1kHz；默认输入 Native Mic，默认输出 Mac mini Speakers。

1. 独立系统进程成功向 HAL 自定义属性注入 600 个合成音频包。
2. Mini 独立系统录音程序读出 398400 帧，101792 个非零样本，证明跨进程 Core Audio 数据链路。
3. 10:09:16 检测真实录音，MagicBook 自动打开麦克风，Native Mic 注入 100 个以上音频包。
4. 10:25:12 重测真实 MagicBook 音频，Mini 独立录音读出 398400 帧，其中 364273 个非零采样，峰值 0.03967639。
5. 10:25:23 停止录音后，MagicBook 和 Mini 日志均确认麦克风关闭。
6. 日常连接保持，MagicBook 待机不持续收音。旧 Loopback/BlackHole 仍在系统仅供回退。

未验收：ChatGPT 客户端使用新 Native Mic 的文本转录、macOS 整机重启登录自启、公开安装包签名/公证、长时间音质和安全加密。
