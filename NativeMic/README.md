# uu伴侣 Native Mic — 自有虚拟麦克风驱动

基于 MIT 许可的 Hush 虚拟输入 HAL 驱动，扩展 CFData 进程间音频注入和环形缓冲，并由 uu伴侣接收端负责解码、重采样和向系统注入。MIT 许可证见 LICENSE-Hush-MIT.txt，也随 .driver 资源打包。

## 构建

- ./build.sh 生成 Apple Silicon 自有驱动并完成本机 ad-hoc 签名。
- ./package.sh 生成仅供本机管理员授权的测试安装包。
- clang -O2 Tests/DriverABITest.c -framework CoreAudio -framework CoreFoundation -o build/uu-native-driver-abi-test && ./build/uu-native-driver-abi-test 验证 Driver factory、CFData 注入、音频回调读取非零样本。
- Tests/build-probe.sh 生成系统设备注入测试器（需先安装自有驱动）。

## 设备接入与回退

- 用 macOS Installer 安装 NativeMic/build/UUMicNative-0.1.2.pkg，然后确认系统出现「uu伴侣 Native Mic」。
- ./activate-native.sh 选择 Native Mic，手动退出并重新打开 uu伴侣。
- ./restore-loopback.sh 选择「uu伴侣 Mic」备用设备，手动退出并重新打开 uu伴侣。

## 核心限制

驱动当前直接接受任何本地进程通过 Core Audio 自定义属性注入 Float32 双声道数据，尚无本地调用者身份校验；网络 TCP 载荷也尚未加密。不能在不可信环境中直接发布使用。当前未持有 Developer ID Installer 分发签名/公证，不可公开分发测试 PKG。整机重启、ChatGPT UI 实际转录和长期稳定性尚未完成验收。请先保留旧 Loopback 备用驱动。

设备为输入-only、固定 48kHz Float32 双声道，不创建系统输出声道，不更改扬声器选择。
