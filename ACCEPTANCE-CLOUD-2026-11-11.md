# uu伴侣 Cloud Bridge — 2026-11-11 公网验收记录

## 架构
- 双端均主动连接 wss://uu-companion-relay.auv1107.workers.dev，无需固定公网 IP、端口映射或账号
- 随机 16 位 Base32 配对码（约 80 bit 熵）本地保存于 relay.json（0600）
- 房间 ID 是经域分离 SHA-256 的配对码摘要，原始配对码不提交给中继
- 控制/音频通过 CryptoKit ChaCha20-Poly1305 加密，服务端仅转发加密帧
- Sender 在公网模式下只监听本机 127.0.0.1:50555
- Receiver 从本机 127.0.0.1:50556 获取云桥接音频并注入 Native Mic
- 旧 LAN 模式保留，且可由菜单栏切换回来

## 真实验收结果
1. 两台 Mac 均收到 Cloudflare Worker 的 WSS 已连接、配对端 online 事件
2. Mini 自有驱动接收真实 MagicBook PCM，原先 cloud self-test 采集 398400 帧，316589 个非零采样
3. 增加 WebSocket 音频 50 ms 批量发送后，完成最终复测：2026-11-11 12:14:30 Mini 独立录音开始；录音结束累计 398400 帧，274882 个非零采样，峰值 0.027517848
4. MagicBook 于 12:14:31 自动开启实体麦克风，12:14:42 自动关闭；源采样率 44.1kHz，Native Mic 输入 48kHz
5. Mini 通过云桥接完成 100 个以上 Native Mic PCM 包注入
6. 服务端发现旧 WebSocket 的角色残留导致 Mini 收到错误响应，2026-11-11 12:14 修复为新角色连接取代旧 WebSocket；Mini 在 12:14:04 自动重新在线
7. 发送端隔离测试在 127.0.0.1:50557 监听，127.0.0.1 可以连接；对 192.168.5.30:50557 的 TCP 连接被拒绝。正式公网版 MagicBook 实测监听 127.0.0.1:50555。
8. GitHub 仓库 https://github.com/s1ntoneli/uu-companion 已公开，首轮 GitHub Actions macOS 自动编译结果为 success。

## 发布前仍需注意
- 当前是中继式跨公网加密传输，尚未实现 ICE/P2P 直连
- 已有 80-bit 高熵共享配对码和 AEAD，但没有独立的专业安全审计，也没有完整的反重放与身份设备证书管理
- 免费云服务受 Cloudflare 免费额度、可用性限制，用户可独立部署同协议服务器
- Apple Developer ID / notarization、完全自动安装驱动的公证分发、安全升级与整机重启自启仍需独立验收
- 用户需要通过 macOS 正常权限提示授权，不提供绕过系统权限的方式
