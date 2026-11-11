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


## macOS 27.0.1 音频服务阻塞与容错（13:38 验收）

- MagicBook macOS 27.0.1 的 AVAudioEngine.inputNode 有时阻塞于系统 HAL；独立 AudioQueueNewInput 成功，但 AudioQueueStart 同样阻塞，说明是系统级音频初始化问题，而非 WSS 加密通道问题。
- 原版 Sender 在同步 CoreAudio 调用时阻塞了整个 TCP 控制队列；系统恢复后甚至可能在录音早已结束时迟到地打开麦克风，存在隐私与安全隐患。
- 修复方式：把 CoreAudio 初始化和停止移动到独立 captureQueue；串行网络队列始终可处理 S/P/K 指令、心跳、断线；对每次录音使用 captureGeneration 取消令牌，使早已停止的请求不再迟到打开麦克风。
- 13:37:51 开始真实远程录音，MagicBook 启动请求；13:38:00 两端日志均报告系统麦克风启动超时；13:38:03 MagicBook 响应远程 P 指令并取消录音请求。整个期间网络握手、控制加密连接持续正常，Mini 录音采样全部为零（398400 帧，零非零样本），**不能声称本轮音频成功**。
- Activity Monitor 正常 Quit/Force Quit 没有成功重启由 _coreaudiod 运行的系统音频服务，普通 launchctl kickstart 返回 SIP Operation not permitted；不尝试绕过 macOS 保护。实际恢复需要使用 macOS 正常管理员授权操作或重新启动 MagicBook，之后重新执行真实音频验收。
- 新版菜单栏在真正发生音频启动超时后应显示明确错误，而非仅「公网已连接」；源码已实现，菜单项显示还需人工 UI 复核。


## MagicBook CoreAudio 恢复后的连续复测（2026-11-11 14:12–14:14）

MagicBook 的系统进程 coreaudiod PID 从 584 变为 19191，表明音频服务器在先前失败之后最终重启。用原始独立硬件测试 App 再次测试，保持正常公网配对、WSS 和 Native Mic：

- 14:12:19 Mini 开始录音，14:12:24 收到真实实体麦克风音频确认（首次恢复耗时 4.77 秒）；录得 398400 帧、76528 个非零采样、峰值 0.0017278751。MagicBook 14:12:20 启动麦克风、14:12:31 关麦。
- 14:13:55 第二轮独立测试，Mini 0.71 秒收到开麦确认；录得 398400 帧、324806 个非零采样、峰值 0.0032755996。MagicBook 14:13:55 启动麦克风、14:14:06 关麦。
- 这两轮经 Cloudflare 公网 Relay 转发加密音频，最终注入 uu伴侣 Native Mic，真实采样并非伪造或仅测试网络连接。
- 前一次 13:38 macOS Core Audio 卡死仍可能在未来复现；容错修复能防止录音请求堵住网络控制与隐私关麦，**不能从根本上修复 macOS HAL 自身卡死**。

### 发行限制

MagicBook 上真实 Developer ID Application 证书构建成功，且 hardened runtime/麦克风 entitlement 签名验证通过。然而三份本地 App Store Connect API 密钥尝试 notarytool history 均返回 401，未找到可用公证 Keychain profile，亦无 Developer ID Installer 可用私钥。尚不能称为 Apple notarized 公开发行安装包。本项目的 GitHub 预览版本只公开源码及构建指引，不提供绕过 Gatekeeper 的说明。


## 15:16–15:20 首次启动稳定性修复与验收

14:41 系统麦克风权限尚未授予时，旧 cloud-bridge 已在配对状态；14:44 sender 获得 TCC 授权并启动，但旧 bridge 不自动连接 localhost，导致远端继续静音。修复后：

- 发送端菜单栏主 App 首次启动先检查并申请麦克风 TCC 权限，拒绝时不会误启动采集，也提供清晰的系统设置提示
- CloudBridge sender 每 3 秒检测配对端在线且本机 TCP 尚未连接时自动重试 127.0.0.1:50555，避免授权时序阻塞
- 麦克风授权后，在独立 captureQueue 对 AVAudioEngine.inputNode 预初始化，**不执行 engine.start()**，避免首次录音才发生 HAL graph 初始化
- 始终由远端录音请求才真正调用 engine.start()，停止录音即 engine.stop()，保留已创建的音频输入图供下次启动；Core Audio 偶发卡死时仍按原有 8 秒超时和取消机制保护
- 使用 Mini 的独立测试 App 从 uu伴侣 Native Mic 实际录音，三轮均为 398400 帧：
  - 15:17:24：259716 非零采样，峰值 0.0033094427；0.62 秒开麦，15:17:36 关麦
  - 15:18:27：327266 非零采样，峰值 0.0024090814；0.60 秒开麦，15:18:38 关麦
  - 15:19:51：**退出并重新打开 MagicBook 的 uu伴侣之后首次录音**，327692 非零采样，峰值 0.0034850787；0.82 秒开麦，15:20:02 关麦
- MagicBook 发送端日志确认三个真实 microphone ON / OFF 周期，服务均保持绑定 127.0.0.1:50555
- Mac mini 始终未更改扬声器默认输出，Native Mic 的输入设备保持正常

这三轮复测是功能通过，并非所有 macOS 驱动组合/长时间运行/整机重启的充分稳定性证明。首启权限和 UI 提示仍需 clean macOS 首次安装验收；Apple 公证仍未通过。
