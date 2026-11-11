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
    private var driverInstallationProcess: Process?
    private var driverInstallationInProgress = false
    private let driverRestartKey = "uuNativeDriverInstalledAtBootEpoch"
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
    private var currentBootEpoch: Double {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            return Double(boot.tv_sec)
        }
        return Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    }
    private var driverRestartPending: Bool {
        let installedDuringBoot = UserDefaults.standard.double(forKey: driverRestartKey)
        guard installedDuringBoot > 0 else { return false }
        // Compare boot identities, not uptime. A login after reboot may take
        // longer than the previous session had been running.
        if abs(installedDuringBoot - currentBootEpoch) >= 2 {
            UserDefaults.standard.removeObject(forKey: driverRestartKey)
            return false
        }
        return true
    }
    private func quoteShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private func quoteAppleScript(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    @objc private func installDriver() {
        if driverInstallationInProgress {
            status.title = "正在通过 macOS 安装 Native Mic…"
            return
        }
        if nativeDriverAvailable && driverRestartPending {
            status.title = "安装成功 · 重启此 Mac 后启用 Native Mic"
            let alert = NSAlert()
            alert.messageText = "Native Mic 已安装"
            alert.informativeText = "需要重新启动这台 Mac，让系统音频服务加载驱动。请保存工作后正常重启。"
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let driver = Bundle.main.resourceURL?.appendingPathComponent("UUMicNative.driver", isDirectory: true)
        guard let source = driver,
              FileManager.default.fileExists(atPath: source.appendingPathComponent("Contents/MacOS/UUMicNative").path) else {
            status.title = "此版本缺少 Native Mic 驱动"
            let guide = NSAlert()
            guide.messageText = "缺少内置驱动"
            guide.informativeText = "请从 GitHub 下载新版完整 uu伴侣.app。下载一个 App 即可，不需要寻找其他驱动安装包。"
            guide.addButton(withTitle: "查看安装说明")
            guide.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if guide.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "https://github.com/s1ntoneli/uu-companion/blob/main/INSTALL-MAC.md") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = nativeDriverAvailable ? "修复 Native Mic" : "安装 Native Mic"
        alert.informativeText = "uu伴侣会将内置的已签名虚拟麦克风安装到 macOS 系统音频目录。系统将要求管理员授权。安装后需要重启这台 Mac；不会关闭系统安全保护或影响其他音频插件。"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let support = "/Library/Application Support/uu伴侣"
        let staging = support + "/UUMicNative.next.driver"
        let backup = support + "/UUMicNative.previous.driver"
        let destination = "/Library/Audio/Plug-Ins/HAL/UUMicNative.driver"
        // Stage and verify the signed driver BEFORE changing the active HAL
        // directory. Only our own named bundle is replaced, never other
        // installed audio drivers. Keep the old bundle outside HAL for rollback.
        let shell = [
            "/bin/mkdir -p " + quoteShell(support) + " /Library/Audio/Plug-Ins/HAL",
            "/bin/rm -rf " + quoteShell(staging),
            "/usr/bin/ditto " + quoteShell(source.path) + " " + quoteShell(staging),
            "/usr/bin/codesign --verify --strict " + quoteShell(staging),
            "/usr/sbin/chown -R root:wheel " + quoteShell(staging),
            "/bin/chmod -R go-w " + quoteShell(staging),
            "/bin/chmod -R a+rX " + quoteShell(staging),
            "/bin/rm -rf " + quoteShell(backup),
            "if [ -e " + quoteShell(destination) + " ]; then /bin/mv " +
                quoteShell(destination) + " " + quoteShell(backup) + "; fi",
            "/bin/mv " + quoteShell(staging) + " " + quoteShell(destination),
            "/usr/bin/codesign --verify --strict " + quoteShell(destination)
        ].joined(separator: " && ")
        // The privileged action uses the normal macOS administrator dialog.
        // No password is read, logged, stored, or transmitted by uu伴侣.
        let appleScript = "do shell script " + quoteAppleScript(shell) + " with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        driverInstallationInProgress = true
        driverItem.isEnabled = false
        status.title = "请完成 macOS 管理员授权…"
        process.terminationHandler = { [weak self] finished in
            let details = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.driverInstallationProcess = nil
                self.driverInstallationInProgress = false
                self.driverItem.isEnabled = true
                if finished.terminationStatus == 0 && self.nativeDriverAvailable {
                    UserDefaults.standard.set(self.currentBootEpoch,
                                              forKey: self.driverRestartKey)
                    self.status.title = "Native Mic 已安装 · 请重启这台 Mac"
                    self.enabled = false
                    self.task?.terminate()
                    self.task = nil
                    self.cloudTask?.terminate()
                    self.cloudTask = nil
                    self.appendLoginDiagnostic("Native Mic installation succeeded; reboot required")
                    let complete = NSAlert()
                    complete.messageText = "Native Mic 安装成功"
                    complete.informativeText = "驱动已安装。请保存工作并正常重启这台 Mac。重新打开 uu伴侣后即可配对使用远程麦克风。"
                    complete.addButton(withTitle: "知道了")
                    NSApp.activate(ignoringOtherApps: true)
                    complete.runModal()
                } else {
                    let cancelled = details.contains("User canceled") || details.contains("-128")
                    self.status.title = cancelled ? "已取消驱动安装" : "驱动安装失败"
                    self.appendLoginDiagnostic("Native Mic installation failed or cancelled, exit=\(finished.terminationStatus)")
                    if !cancelled {
                        let failure = NSAlert()
                        failure.messageText = "Native Mic 安装失败"
                        failure.informativeText = "系统未完成管理员授权或无法写入音频插件目录。请检查磁盘权限后重试。\n\n" + String(details.suffix(280))
                        failure.addButton(withTitle: "知道了")
                        NSApp.activate(ignoringOtherApps: true)
                        failure.runModal()
                    }
                }
            }
        }
        do {
            try process.run()
            driverInstallationProcess = process
        } catch {
            driverInstallationInProgress = false
            driverItem.isEnabled = true
            status.title = "无法启动系统安装授权：\(error.localizedDescription)"
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
        } else if CommandLine.arguments.contains("--acceptance-install-driver") &&
                  settings?.role == "receiver" {
            // Internal E2E hook: exercise the exact menu's installer function,
            // including the normal macOS administrator permission prompt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.installDriver()
            }
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
        if settings.role == "receiver", (!nativeDriverAvailable || driverRestartPending) {
            status.title = driverRestartPending ? "请重启 Mac 以启用 Native Mic" : "需要安装 Native Mic"
            return
        }
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
        if settings.role == "receiver" {
            driverItem.title = nativeDriverAvailable ? "修复 Native Mic 驱动…" : "安装 Native Mic 驱动…"
            if driverInstallationInProgress {
                status.title = "正在等待 macOS 安装授权…"
                return
            }
            if driverRestartPending {
                status.title = "Native Mic 已安装 · 请重启这台 Mac"
                return
            }
        }
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
