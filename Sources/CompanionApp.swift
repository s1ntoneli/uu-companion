import AppKit
import AVFoundation
import ServiceManagement
import Foundation

struct CompanionSettings: Codable {
    let role: String
    let host: String?
    let port: Int?
    let token: String
    let virtualDeviceName: String?
}
struct CloudPair: Codable {
    let code: String
    let server: String
}
final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let status = NSMenuItem(title: "准备中…", action: nil, keyEquivalent: "")
    private let mode = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var toggle = NSMenuItem(title: "暂停", action: #selector(toggleTransfer), keyEquivalent: "")
    private var task: Process?
    private var cloudTask: Process?
    private var cloudPair: CloudPair?
    private var pairItem: NSMenuItem!
    private var codeItem: NSMenuItem!
    private var serverItem: NSMenuItem!
    private var localItem: NSMenuItem!
    private var driverItem: NSMenuItem!
    private var enabled = true
    private var microphonePermissionInFlight = false
    private var settings: CompanionSettings?
    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/uu-companion.log")
    }
    private func appendLoginDiagnostic(_ info: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/uu-companion-login.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let file = FileHandle(forWritingAtPath: url.path) {
            file.seekToEndOfFile()
            file.write(Data(("[\(Date())] " + info + "\n").utf8))
            try? file.close()
        }
    }
    private var relayURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/uu伴侣/relay.json")
    }
    private var cloudLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/uu-companion-cloud.log")
    }
    private let officialRelay = "wss://uu-companion-relay.auv1107.workers.dev"
    private let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private func loadCloudPair() {
        guard let data = try? Data(contentsOf: relayURL),
              let value = try? JSONDecoder().decode(CloudPair.self, from: data),
              value.code.count == 16,
              value.code.allSatisfy({ alphabet.contains($0) }),
              URL(string: value.server)?.scheme == "wss" else {
            cloudPair = nil
            return
        }
        cloudPair = value
    }
    private func persistCloudPair(_ pair: CloudPair?) {
        let directory = relayURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        if let pair {
            guard let data = try? JSONEncoder().encode(pair) else { return }
            do {
                try data.write(to: relayURL, options: [.atomic])
                chmod(relayURL.path, 0o600)
                cloudPair = pair
            } catch {
                status.title = "配对信息保存失败"
                return
            }
        } else {
            try? FileManager.default.removeItem(at: relayURL)
            cloudPair = nil
        }
        updatePairingMenu()
        restartForPairing()
    }
    private func updatePairingMenu() {
        guard pairItem != nil else { return }
        let receiver = settings?.role == "receiver"
        pairItem.isEnabled = settings != nil
        pairItem.title = receiver ? "输入配对码…" : "生成新配对码…"
        if cloudPair != nil {
            codeItem.title = receiver ? "已配对 · 复制配对码" : "已生成配对码 · 点击复制"
            codeItem.isHidden = false
            localItem.isHidden = false
        } else {
            codeItem.isHidden = true
            localItem.isHidden = true
        }
    }
    private var nativeDriverAvailable: Bool {
        FileManager.default.fileExists(
            atPath: "/Library/Audio/Plug-Ins/HAL/UUMicNative.driver/Contents/MacOS/UUMicNative")
    }
    @objc private func installDriver() {
        guard let pkg = Bundle.main.url(forResource: "UUMicNative-0.1.2", withExtension: "pkg") else {
            // Public notarized ZIP ships the signed driver beside the app, not
            // an unsigned .pkg nested inside the app bundle.
            let guide = NSAlert()
            guide.messageText = "安装 uu伴侣 Native Mic"
            guide.informativeText = "在 GitHub 下载的 ZIP 解压文件夹中，将 UUMicNative.driver 拖入「音频插件位置」文件夹（/Library/Audio/Plug-Ins/HAL）。按 macOS 提示输入管理员密码，随后重启 Mac，再打开 uu伴侣。无需关闭任何系统安全保护。"
            guide.addButton(withTitle: "查看安装步骤")
            guide.addButton(withTitle: "稍后安装")
            NSApp.activate(ignoringOtherApps: true)
            if guide.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "https://github.com/s1ntoneli/uu-companion/blob/main/INSTALL-MAC.md") {
                NSWorkspace.shared.open(url)
            }
            status.title = "请从 ZIP 解压目录安装 Native Mic 并重启 Mac"
            return
        }
        let alert = NSAlert()
        alert.messageText = "安装 uu伴侣 Native Mic"
        alert.informativeText = "需要通过 macOS 安装器安装开源虚拟麦克风驱动。系统会要求管理员授权，安装后返回此 App，点击启用透传即可。"
        alert.addButton(withTitle: "打开系统安装器")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if NSWorkspace.shared.open(pkg) {
            status.title = "请在系统安装器中批准安装 Native Mic"
        } else {
            status.title = "无法打开安装器"
        }
    }

    @objc private func selectRole() {
        let alert = NSAlert()
        alert.messageText = "这台 Mac 要做什么？"
        alert.informativeText = "提供本机麦克风，或使用另一台 Mac 的麦克风。以后可随时切换。"
        alert.addButton(withTitle: "提供本机麦克风")
        alert.addButton(withTitle: "使用远程麦克风")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
        let role = choice == .alertFirstButtonReturn ? "sender" : "receiver"
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            status.title = "无法生成本机认证密钥"
            return
        }
        let token = settings?.token ?? random.map { String(format: "%02x", $0) }.joined()
        let nativeAvailable = nativeDriverAvailable
        let preferred = role == "receiver" ? "uu伴侣 Native Mic" : nil
        let newSettings = CompanionSettings(role: role, host: settings?.host,
                                            port: 50555, token: token,
                                            virtualDeviceName: preferred)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/uu伴侣/config.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(newSettings).write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        } catch {
            status.title = "无法保存角色设置：\(error.localizedDescription)"
            return
        }
        // Invalidate an old pairing when changing roles so it does not silently
        // grant microphone access to a previously connected device.
        if settings?.role != role { try? FileManager.default.removeItem(at: relayURL) }
        settings = nil
        enabled = role != "receiver" || nativeAvailable
        toggle.isEnabled = true
        loadSettings()
        loadCloudPair()
        pairItem.action = role == "receiver" ? #selector(enterCode) : #selector(generateCode)
        updatePairingMenu()
        restartForPairing()
        if role == "receiver" && !nativeAvailable {
            status.title = "请先安装 Native Mic 驱动"
            installDriver()
        }
    }

    @objc private func generateCode() {
        guard settings?.role == "sender" else { return }
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            status.title = "随机配对码生成失败"
            return
        }
        let code = String(random.map { alphabet[Int($0 & 31)] })
        let server = cloudPair?.server ??
            UserDefaults.standard.string(forKey: "uuRelayURL") ?? officialRelay
        persistCloudPair(CloudPair(code: code, server: server))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        status.title = "配对码已复制，另一台 Mac 输入即可连接"
    }
    @objc private func enterCode() {
        guard settings?.role == "receiver" else { return }
        let alert = NSAlert()
        alert.messageText = "连接另一台 Mac 的麦克风"
        alert.informativeText = "在提供麦克风的 Mac 上复制配对码，粘贴到这里。无需账号。"
        let field = NSTextField(string: "")
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.uppercased().filter { $0 != "-" && $0 != " " }
        guard input.count == 16, input.allSatisfy({ alphabet.contains($0) }) else {
            status.title = "配对码格式不正确"
            return
        }
        let server = cloudPair?.server ??
            UserDefaults.standard.string(forKey: "uuRelayURL") ?? officialRelay
        persistCloudPair(CloudPair(code: input, server: server))
        status.title = "正在通过公网连接配对设备…"
    }
    @objc private func copyCode() {
        guard let code = cloudPair?.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        status.title = "已复制配对码"
    }
    @objc private func chooseServer() {
        let alert = NSAlert()
        alert.messageText = "发现 / 中继服务器"
        alert.informativeText = "可以使用免费公共服务，也可以填写自己部署的 WSS 服务器地址。"
        let field = NSTextField(string: cloudPair?.server ??
            UserDefaults.standard.string(forKey: "uuRelayURL") ?? officialRelay)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newURL = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: newURL),
              parsed.scheme == "wss", parsed.host != nil else {
            status.title = "服务器地址必须是 wss://"
            return
        }
        UserDefaults.standard.set(newURL, forKey: "uuRelayURL")
        if let pair = cloudPair {
            persistCloudPair(CloudPair(code: pair.code, server: newURL))
        } else { status.title = "服务器已保存，生成或输入配对码后生效" }
    }
    @objc private func useLocalNetwork() {
        persistCloudPair(nil)
        status.title = "已切回局域网直连"
    }
    private func restartForPairing() {
        task?.terminate()
        task = nil
        cloudTask?.terminate()
        cloudTask = nil
        guard enabled else { return }
        startCloudBridge()
        start()
    }
    private func startCloudBridge() {
        guard enabled, cloudTask == nil, let cloudPair, let settings else { return }
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("uu-cloud-bridge") else { return }
        let p = Process()
        p.executableURL = binary
        p.arguments = [settings.role]
        var environment = ProcessInfo.processInfo.environment
        environment["UU_COMPANION_SECRET"] = settings.token
        environment["UU_RELAY_CODE"] = cloudPair.code
        environment["UU_RELAY_URL"] = cloudPair.server
        p.environment = environment
        FileManager.default.createFile(atPath: cloudLogURL.path, contents: nil)
        if let file = FileHandle(forWritingAtPath: cloudLogURL.path) {
            file.seekToEndOfFile()
            p.standardOutput = file
            p.standardError = file
        }
        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.cloudTask === process else { return }
                self.cloudTask = nil
                if self.enabled && self.cloudPair != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.startCloudBridge()
                    }
                }
            }
        }
        do {
            try p.run()
            cloudTask = p
        } catch { status.title = "公网桥接启动失败：\(error.localizedDescription)" }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "uu伴侣")
        item.button?.toolTip = "uu伴侣 — 远程麦克风"
        let menu = NSMenu()
        let title = NSMenuItem(title: "uu伴侣", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(mode)
        menu.addItem(status)
        let select = NSMenuItem(title: "设置本机角色…",
                                action: #selector(selectRole), keyEquivalent: "")
        select.target = self
        menu.addItem(select)
        driverItem = NSMenuItem(title: "安装 / 修复 Native Mic 驱动…",
                                action: #selector(installDriver), keyEquivalent: "")
        driverItem.target = self
        menu.addItem(driverItem)
        menu.addItem(.separator())
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        pairItem = NSMenuItem(title: "配对设备…", action: #selector(generateCode), keyEquivalent: "")
        pairItem.target = self
        menu.addItem(pairItem)
        codeItem = NSMenuItem(title: "配对码", action: #selector(copyCode), keyEquivalent: "")
        codeItem.target = self
        menu.addItem(codeItem)
        serverItem = NSMenuItem(title: "发现 / 中继服务器…", action: #selector(chooseServer), keyEquivalent: "")
        serverItem.target = self
        menu.addItem(serverItem)
        localItem = NSMenuItem(title: "切回局域网直连", action: #selector(useLocalNetwork), keyEquivalent: "")
        localItem.target = self
        menu.addItem(localItem)
        let logs = NSMenuItem(title: "查看运行日志", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 uu伴侣", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        loadSettings()
        loadCloudPair()
        if settings?.role == "receiver" { pairItem.action = #selector(enterCode) }
        updatePairingMenu()
        if settings == nil {
            DispatchQueue.main.async { [weak self] in self?.selectRole() }
        }
        // Register our single menu-bar app as a login item. No separate
        // legacy LaunchAgent is necessary for future installs.
        let loginBefore = SMAppService.mainApp.status
        if loginBefore != .enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                appendLoginDiagnostic("Login registration error: \(error)")
            }
        }
        appendLoginDiagnostic("SMAppService previous=\(loginBefore), current=\(SMAppService.mainApp.status)")
        startCloudBridge()
        start()
        Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(updateStatus), userInfo: nil, repeats: true)
    }
    private func loadSettings() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/uu伴侣/config.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONDecoder().decode(CompanionSettings.self, from: data),
              ["sender", "receiver"].contains(parsed.role), parsed.token.utf8.count >= 32 else {
            status.title = "首次使用：请设置本机角色"
            mode.title = "未设置"
            enabled = false
            toggle.isEnabled = false
            return
        }
        settings = parsed
        if parsed.role == "sender" {
            mode.title = "发送端 · 本机麦克风"
        } else if parsed.virtualDeviceName?.contains("Native") == true {
            mode.title = "接收端 · Native Mic"
        } else {
            mode.title = "接收端 · \(parsed.virtualDeviceName ?? "默认设备")"
        }
        mode.isEnabled = false
        driverItem?.isHidden = parsed.role != "receiver"
    }
    private func start() {
        guard enabled, task == nil, let settings else { return }
        if settings.role == "sender" {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                status.title = "需要授权本机麦克风"
                if !microphonePermissionInFlight {
                    microphonePermissionInFlight = true
                    NSApp.activate(ignoringOtherApps: true)
                    AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.microphonePermissionInFlight = false
                            if allowed {
                                self.start()
                            } else {
                                self.status.title = "麦克风未授权 · 请在系统设置中允许"
                            }
                        }
                    }
                }
                return
            case .denied, .restricted:
                status.title = "麦克风权限受限 · 请在系统设置中允许"
                return
            @unknown default:
                status.title = "麦克风权限状态未知"
                return
            }
        }
        let binary = settings.role == "sender" ? "uu-sender" : "uu-receiver"
        guard let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(binary) else { return }
        let p = Process()
        p.executableURL = path
        if settings.role == "receiver" {
            var args = ["--port", String(cloudPair == nil ? (settings.port ?? 50555) : 50556)]
            if cloudPair != nil {
                args += ["--host", "127.0.0.1"]
            } else if let host = settings.host, !host.isEmpty {
                args += ["--host", host]
            }
            if let name = settings.virtualDeviceName, !name.isEmpty { args += ["--device", name] }
            if CommandLine.arguments.contains("--test-stream") {
                args.append("--always-on")
            }
            p.arguments = args
        } else {
            p.arguments = ["--port", String(settings.port ?? 50555)]
            if cloudPair != nil { p.arguments?.append("--loopback-only") }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["UU_COMPANION_SECRET"] = settings.token
        p.environment = environment
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let file = FileHandle(forWritingAtPath: logURL.path) {
            file.seekToEndOfFile()
            p.standardOutput = file
            p.standardError = file
        }
        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.task === process {
                    self.task = nil
                    self.updateStatus()
                    if self.enabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.start() }
                    }
                }
            }
        }
        do {
            try p.run()
            task = p
            status.title = "已启动，等待连接"
        } catch {
            status.title = "无法启动音频服务：\(error.localizedDescription)"
        }
        updateStatus()
    }
    @objc private func toggleTransfer() {
        enabled.toggle()
        if enabled { startCloudBridge(); start() }
        else {
            task?.terminate(); task = nil
            cloudTask?.terminate(); cloudTask = nil
            updateStatus()
        }
    }
    @objc private func updateStatus() {
        toggle.title = enabled ? "暂停透传" : "启用透传"
        item.button?.image = NSImage(systemSymbolName: enabled ? "mic" : "mic.slash", accessibilityDescription: "uu伴侣")
        guard let settings else { status.title = "请设置本机角色"; return }
        if settings.role == "receiver" && !nativeDriverAvailable &&
           settings.virtualDeviceName?.contains("Native") == true {
            status.title = "需要安装 Native Mic 驱动"
            return
        }
        guard enabled else { status.title = "已暂停"; return }
        if settings.role == "sender" {
            let micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
            if micAccess != .authorized {
                status.title = micAccess == .notDetermined ?
                    "请完成麦克风授权" : "麦克风未授权 · 系统设置"
                return
            }
        }
        if cloudPair != nil {
            let audioLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let audioEvents = audioLog.components(separatedBy: .newlines).suffix(120).filter {
                if settings.role == "sender" {
                    return $0.contains("listening on") ||
                        $0.contains("microphone initialization requested") ||
                        $0.contains("microphone startup stalled") ||
                        $0.contains("microphone ON") || $0.contains("microphone OFF") ||
                        $0.contains("microphone permission denied") ||
                        $0.contains("failed to start microphone")
                }
                return $0.contains("connected to") ||
                    $0.contains("an app started recording") ||
                    $0.contains("remote microphone startup timed out") ||
                    $0.contains("MacBook mic is on") ||
                    $0.contains("no app is recording any more")
            }
            if let latest = audioEvents.last {
                if latest.contains("startup stalled") || latest.contains("startup timed out") {
                    status.title = "已配对 · 麦克风启动超时"
                    return
                }
                if latest.contains("permission denied") {
                    status.title = "请授权本机麦克风"
                    return
                }
                if latest.contains("failed to start microphone") {
                    status.title = "本机麦克风启动失败"
                    return
                }
                if latest.contains("microphone ON") {
                    status.title = "正在传输麦克风"
                    return
                }
            }
            let raw = (try? String(contentsOf: cloudLogURL, encoding: .utf8)) ?? ""
            let events = raw.components(separatedBy: .newlines).suffix(90).filter {
                $0.contains("paired peer online") || $0.contains("paired peer offline") ||
                $0.contains("relay disconnected") || $0.contains("relay WSS connected")
            }
            let last = events.last ?? ""
            if last.contains("paired peer online") {
                status.title = "公网已连接 · 待机"
            } else if last.contains("relay WSS connected") || last.contains("offline") {
                status.title = "等待配对设备上线…"
            } else {
                status.title = "正在连接发现服务器…"
            }
            return
        }
        guard task?.isRunning == true else { status.title = "连接服务中…"; return }
        let raw = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = raw.components(separatedBy: .newlines).suffix(80)
        if lines.contains(where: { $0.contains("permission denied") }) {
            status.title = "请在系统设置中授权麦克风"
            return
        }
        if settings.role == "sender" {
            let events = lines.filter { $0.contains("microphone ON") || $0.contains("microphone OFF") }
            status.title = events.last?.contains("microphone ON") == true ? "正在向远程电脑送音" : "待机，等待远端使用麦克风"
        } else {
            let events = lines.filter { $0.contains("connected to") || $0.contains("disconnected from sender") }
            let stages = lines.filter { $0.contains("HAL stage 3") || $0.contains("audio output ready") ||
                $0.contains("HAL stage 8") || $0.contains("could not start audio output") }
            if stages.last?.contains("HAL stage 3") == true {
                status.title = "虚拟麦克风设备未就绪"
            } else if stages.last?.contains("could not start") == true {
                status.title = "虚拟麦克风启动失败"
            } else {
                status.title = events.last?.contains("connected to") == true ?
                    "已连接 · 待机" : "正在寻找发送端"
            }
        }
    }
    @objc private func openLogs() { NSWorkspace.shared.open(logURL) }
    @objc private func quit() {
        enabled = false
        task?.terminate()
        task = nil
        cloudTask?.terminate()
        cloudTask = nil
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        task?.terminate()
        cloudTask?.terminate()
    }
}
// Internal E2E harness: run from this already-authorized app's own bundle,
// record only aggregate sample levels, never audio. Not shown in the menu UI.
final class RecordingSelfTest: NSObject, NSApplicationDelegate {
    private let path = NSHomeDirectory() + "/Library/Logs/uu-companion-e2e-test.log"
    private let lock = NSLock()
    private var frames = 0
    private var nonzero = 0
    private var peak: Float = 0
    private var engine: AVAudioEngine?

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let f = FileHandle(forWritingAtPath: path) {
            f.seekToEndOfFile()
            f.write(Data(line.utf8))
            try? f.close()
        }
        print(line, terminator: "")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FileManager.default.createFile(atPath: path, contents: nil)
        log("Mic authorization state \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        AVCaptureDevice.requestAccess(for: .audio) { authorized in
            DispatchQueue.main.async {
                self.log("Mic authorized: \(authorized)")
                guard authorized else { NSApp.terminate(nil); return }
                self.record()
            }
        }
    }
    private func record() {
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        log("Recording input at \(format.sampleRate)Hz, \(format.channelCount) channels")
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            var active = 0
            var pk: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                let v = abs(data[i])
                if v > 0.00005 { active += 1 }
                pk = max(pk, v)
            }
            self.lock.lock()
            self.frames += Int(buffer.frameLength)
            self.nonzero += active
            self.peak = max(self.peak, pk)
            self.lock.unlock()
        }
        do {
            try e.start()
            engine = e
            log("RECORDING START")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                e.stop()
                input.removeTap(onBus: 0)
                self.lock.lock()
                let result = "RECORDING STOP frames=\(self.frames) nonZeroSamples=\(self.nonzero) peak=\(self.peak)"
                self.lock.unlock()
                self.log(result)
                NSApp.terminate(nil)
            }
        } catch {
            log("RECORDING FAILED \(error)")
            NSApp.terminate(nil)
        }
    }
}
let application = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    let testDelegate = RecordingSelfTest()
    application.delegate = testDelegate
    application.run()
} else {
    let delegate = CompanionDelegate()
    application.delegate = delegate
    application.run()
}
