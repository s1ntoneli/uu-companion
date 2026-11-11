# 安装 uu伴侣（免费开源，macOS）

uu伴侣包含菜单栏 App，以及仅在接收端需要的 Native Mic 虚拟麦克风插件。不需要账号、订阅或关闭 Gatekeeper/SIP。

## 发送端与接收端

1. 从 https://github.com/s1ntoneli/uu-companion/releases 下载经 Apple 公证的 DMG。没有提供公证 DMG 时，仅支持开发者自行从源码构建测试。
2. 打开 DMG，将 uu伴侣.app 拖入 Applications（应用程序）快捷方式。
3. 从「应用程序」启动 uu伴侣，选择「提供本机麦克风」或「使用远程麦克风」。
4. 发送端按 macOS 提示授予麦克风权限，点击「生成新配对码…」。

## 接收端额外安装 Native Mic

1. 在 DMG 中，将 UUMicNative.driver 拖入「音频插件位置」快捷方式。它指向系统目录 /Library/Audio/Plug-Ins/HAL。
2. 按 Finder 的正常系统提示授予管理员权限。不要关闭 Gatekeeper 或 SIP，也不要双击“打开”驱动。
3. 保存工作并正常重新启动接收端 Mac，让 Core Audio 加载新插件。
4. 在「系统设置 → 声音 → 输入」确认能看到 uu伴侣 Native Mic。
5. 接收端菜单栏选择「输入配对码…」，粘贴发送端复制的 16 位配对码。
6. 打开 ChatGPT 或其他录音软件，选择 uu伴侣 Native Mic 作为输入设备并说话。系统播放输出仍保持原来的扬声器。

如果 Finder 没有请求管理员权限，请确认使用的是 /Library/Audio/Plug-Ins/HAL，而不是用户文件夹下的 ~/Library/Audio/Plug-Ins/HAL。

## 配对、隐私及问题排查

- 配对码是长期有效的凭据，不要分享给不信任的人。发送端重新生成即可取消原配对关系。
- 只有接收端实际录音时才自动开麦，停止录音后自动关麦。音频设备启动失败时，请检查菜单栏是否提示超时或权限问题。
- 公网默认通过免费 WSS 发现/中继服务传送端到端加密音频。也可自建 Relay，双方必须选择同一服务器地址。
- 如果未检测到 Native Mic，检查驱动路径和签名，然后正常重启接收端。
- 如果发送端已配对但无法录音，检查「系统设置 → 隐私与安全性 → 麦克风」，必要时正常重启发送端使系统音频服务恢复。
- 本地开发环境可使用 ./build.sh 与 ./NativeMic/package.sh 构建自己的测试包；本地未签名测试 .pkg 不等于公开分发安装包。

更多信息见 README.md 和 Signing/README.md。
