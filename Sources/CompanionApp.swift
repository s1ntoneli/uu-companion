import AppKit
import AVFoundation
import ServiceManagement
import Foundation

struct CompanionSettings: Decodable {
    let role: String
    let host: String?
    let port: Int?
    let token: String
    let virtualDeviceName: String?
}
final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let status = NSMenuItem(title: "准备中…", action: nil, keyEquivalent: "")
    private let mode = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var toggle = NSMenuItem(title: "暂停", action: #selector(toggleTransfer), keyEquivalent: "")
    private var task: Process?
    private var enabled = true
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
        menu.addItem(.separator())
        toggle.target = self
        menu.addItem(toggle)
        let logs = NSMenuItem(title: "查看运行日志", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 uu伴侣", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        loadSettings()
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
        start()
        Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(updateStatus), userInfo: nil, repeats: true)
    }
    private func loadSettings() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/uu伴侣/config.json")
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONDecoder().decode(CompanionSettings.self, from: data),
              ["sender", "receiver"].contains(parsed.role), parsed.token.utf8.count >= 32 else {
            status.title = "缺少配对配置，请运行安装程序"
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
    }
    private func start() {
        guard enabled, task == nil, let settings else { return }
        let binary = settings.role == "sender" ? "uu-sender" : "uu-receiver"
        guard let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(binary) else { return }
        let p = Process()
        p.executableURL = path
        if settings.role == "receiver" {
            var args = ["--port", String(settings.port ?? 50555)]
            if let host = settings.host, !host.isEmpty { args += ["--host", host] }
            if let name = settings.virtualDeviceName, !name.isEmpty { args += ["--device", name] }
            if CommandLine.arguments.contains("--test-stream") {
                args.append("--always-on")
            }
            p.arguments = args
        } else {
            p.arguments = ["--port", String(settings.port ?? 50555)]
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
        if enabled { start() }
        else { task?.terminate(); task = nil; updateStatus() }
    }
    @objc private func updateStatus() {
        toggle.title = enabled ? "暂停透传" : "启用透传"
        item.button?.image = NSImage(systemSymbolName: enabled ? "mic" : "mic.slash", accessibilityDescription: "uu伴侣")
        guard enabled else { status.title = "已暂停"; return }
        guard task?.isRunning == true else { status.title = "连接服务中…"; return }
        let raw = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = raw.components(separatedBy: .newlines).suffix(80)
        if lines.contains(where: { $0.contains("permission denied") }) {
            status.title = "请在系统设置中授权麦克风"
            return
        }
        if let settings, settings.role == "sender" {
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
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { task?.terminate() }
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
