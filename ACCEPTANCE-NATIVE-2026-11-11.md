# uu伴侣 Native Mic — 2026-11-11 现场验收

环境：Mini macOS 27 + Native Mic 0.1.2；MagicBook 实体麦克风 44.1kHz；默认输入 Native Mic，默认输出 Mac mini Speakers。

1. 独立系统进程成功向 HAL 自定义属性注入 600 个合成音频包。
2. Mini 独立系统录音程序读出 398400 帧，101792 个非零样本，证明跨进程 Core Audio 数据链路。
3. 10:09:16 检测真实录音，MagicBook 自动打开麦克风，Native Mic 注入 100 个以上音频包。
4. 10:25:12 重测真实 MagicBook 音频，Mini 独立录音读出 398400 帧，其中 364273 个非零采样，峰值 0.03967639。
5. 10:25:23 停止录音后，MagicBook 和 Mini 日志均确认麦克风关闭。
6. 日常连接保持，MagicBook 待机不持续收音。旧 Loopback/BlackHole 仍在系统仅供回退。

未验收：ChatGPT 客户端使用新 Native Mic 的文本转录、macOS 整机重启登录自启、公开安装包签名/公证、长时间音质和安全加密。

## 应用重启与重连验收
- Mini 自有驱动菜单栏程序在 10:38、10:45 多次重启成功，并自动恢复 Native Mic 默认输入、Mini 扬声器默认输出和认证连接。
- macOS 登录项状态 SMAppService.Status.enabled (rawValue 1)，已注册；尚未整机重启测试。
- 发送端断线后接收端退出连接、限频重试；MagicBook 10:46:33 恢复监听，Mini 10:46:34 自动重连并完成认证。
- 配对设置、Native Mic 选择、Loopback 回退均通过隔离 HOME 的模拟重装/切换测试，不打印配对密钥。
- 注意：每次重新用 ad-hoc 签名构建主 App 后，独立 self-test 的麦克风 TCC 可能重新要求授权；当前真正的 ChatGPT 录音权限与该测试模式不同。正式发布需稳定的 Developer ID Application 签名、公证。
