import AppKit
import AVFoundation
import CoreAudio
import Foundation

// Read the device Core Audio actually exposes, not the presence of a .driver
// bundle on disk. Installing a HAL plug-in alone does not prove it was loaded.
enum NativeMicAudioSupport {
    static func deviceID() -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return nil }
        var devices = [AudioDeviceID](repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil,
                                       &size, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        for device in devices {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize,
                                          &name) == noErr, let name {
                if (name.takeRetainedValue() as String) == "uu伴侣 Native Mic" {
                    return device
                }
            }
        }
        return nil
    }

    static func isDefaultInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var selected = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &selected) == noErr && selected == device
    }
}

// A real receiver-side audio capture: opening the Native Mic is the very
// recording action which should ask the sender to enable its physical mic.
// Raw audio is never saved or sent to the UI; only aggregate sample levels
// cross the audio callback -> main thread boundary.
final class LiveMicTest: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var headline: NSTextField?
    private var detail: NSTextField?
    private var meter: NSProgressIndicator?
    private var testButton: NSButton?
    private var closeButton: NSButton?
    private var settingsButton: NSButton?
    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var testGeneration = 0
    private var prerequisite: (() -> String?)?
    private let lock = NSLock()
    private var frames = 0
    private var nonzero = 0
    private var peak: Float = 0
    private var recentPeak: Float = 0

    func present(check: @escaping () -> String?) {
        prerequisite = check
        if panel == nil { buildWindow() }
        guard let panel else { return }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if engine == nil {
            headline?.stringValue = "测试远程麦克风"
            detail?.stringValue = "对着提供麦克风的 Mac 说话。这台 Mac 将实际录音，检测是否收到声音。"
            meter?.doubleValue = 0
            testButton?.title = "开始 12 秒试音"
        }
    }

    private func buildWindow() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 250),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        p.title = "uu伴侣 · 试音"
        p.isReleasedWhenClosed = false
        p.delegate = self
        guard let view = p.contentView else { return }

        let title = NSTextField(labelWithString: "测试远程麦克风")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.frame = NSRect(x: 25, y: 181, width: 425, height: 31)
        view.addSubview(title)
        headline = title

        let description = NSTextField(wrappingLabelWithString:
            "对着提供麦克风的 Mac 说话。这台 Mac 将实际录音，检测是否收到声音。")
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        description.frame = NSRect(x: 26, y: 115, width: 422, height: 60)
        view.addSubview(description)
        detail = description

        let progress = NSProgressIndicator(frame:
            NSRect(x: 27, y: 89, width: 420, height: 14))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        view.addSubview(progress)
        meter = progress

        let privacy = NSTextField(labelWithString: "仅本地统计音量 · 不保存录音")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .tertiaryLabelColor
        privacy.frame = NSRect(x: 27, y: 57, width: 310, height: 17)
        view.addSubview(privacy)

        let start = NSButton(title: "开始 12 秒试音", target: self,
                             action: #selector(toggle))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.frame = NSRect(x: 268, y: 16, width: 181, height: 32)
        view.addSubview(start)
        testButton = start

        let close = NSButton(title: "关闭", target: self,
                             action: #selector(closePanel))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 25, y: 16, width: 92, height: 32)
        view.addSubview(close)
        closeButton = close

        let settings = NSButton(title: "打开麦克风权限", target: self,
                                action: #selector(openMicrophoneSettings))
        settings.bezelStyle = .rounded
        settings.frame = NSRect(x: 119, y: 16, width: 141, height: 32)
        settings.isHidden = true
        view.addSubview(settings)
        settingsButton = settings
        panel = p
    }

    @objc private func closePanel() { panel?.close() }
    @objc private func openMicrophoneSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func toggle() {
        if engine != nil {
            stopTesting()
            headline?.stringValue = "试音已停止"
            detail?.stringValue = "可以再次开始测试。"
            return
        }
        startTesting()
    }

    private func startTesting() {
        if let problem = prerequisite?() {
            headline?.stringValue = "还不能开始试音"
            detail?.stringValue = problem
            return
        }
        guard let device = NativeMicAudioSupport.deviceID() else {
            headline?.stringValue = "未找到 Native Mic"
            detail?.stringValue = "请先完成驱动安装与音频服务加载，然后再试。"
            return
        }
        guard NativeMicAudioSupport.isDefaultInput(device) else {
            headline?.stringValue = "等待接收端选择 Native Mic"
            detail?.stringValue = "重新连接 uu伴侣，确认 Native Mic 已成为本机输入设备后再试。"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginCapture()
        case .notDetermined:
            headline?.stringValue = "请授权这台 Mac 读取 Native Mic"
            detail?.stringValue = "macOS 即将申请麦克风权限，仅用于本次试音。"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] accepted in
                DispatchQueue.main.async {
                    if accepted {
                        self?.beginCapture()
                    } else {
                        self?.headline?.stringValue = "麦克风权限未允许"
                        self?.settingsButton?.isHidden = false
                        self?.detail?.stringValue =
                            "打开系统设置 → 隐私与安全性 → 麦克风，允许 uu伴侣后重试。"
                    }
                }
            }
        case .denied, .restricted:
            headline?.stringValue = "麦克风权限被拒绝"
            settingsButton?.isHidden = false
            detail?.stringValue =
                "在系统设置 → 隐私与安全性 → 麦克风中允许 uu伴侣，然后再次试音。"
        @unknown default:
            headline?.stringValue = "无法确定麦克风权限"
        }
    }

    private func beginCapture() {
        guard engine == nil, prerequisite?() == nil else { return }
        settingsButton?.isHidden = true
        testGeneration += 1
        let generation = testGeneration
        lock.lock()
        frames = 0; nonzero = 0; peak = 0; recentPeak = 0
        lock.unlock()
        headline?.stringValue = "正在启动真实录音…"
        detail?.stringValue = "请对着另一台 Mac 的实体麦克风说一句话。"
        testButton?.isEnabled = false
        meter?.doubleValue = 0

        // Core Audio sometimes hangs at input graph initialization.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.testGeneration == generation,
                  self.engine == nil else { return }
            self.testGeneration += 1
            self.headline?.stringValue = "macOS 麦克风初始化超时"
            self.detail?.stringValue = "可重新连接后重试；音频系统卡住不代表配对码错误。"
            self.testButton?.isEnabled = true
            self.testButton?.title = "重新测试"
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let candidate = AVAudioEngine()
            let input = candidate.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
                guard let self, let channel = buffer.floatChannelData?[0] else { return }
                var positive = 0
                var maxSample: Float = 0
                let count = Int(buffer.frameLength)
                for i in 0..<count {
                    let value = abs(channel[i])
                    if value > 0.0001 { positive += 1 }
                    maxSample = max(maxSample, value)
                }
                self.lock.lock()
                self.frames += count
                self.nonzero += positive
                self.peak = max(self.peak, maxSample)
                self.recentPeak = max(self.recentPeak, maxSample)
                self.lock.unlock()
            }
            do {
                try candidate.start()
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.testGeneration else {
                        candidate.stop(); input.removeTap(onBus: 0); return
                    }
                    self.engine = candidate
                    self.headline?.stringValue = "正在试音 · 请说话"
                    self.testButton?.title = "停止试音"
                    self.testButton?.isEnabled = true
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) {
                        [weak self] _ in self?.refreshMeter(generation: generation)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self, self.testGeneration == generation else { return }
                        self.finishTest()
                    }
                }
            } catch {
                input.removeTap(onBus: 0)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.testGeneration else { return }
                    self.headline?.stringValue = "音频测试启动失败"
                    self.detail?.stringValue = error.localizedDescription
                    self.testButton?.isEnabled = true
                }
            }
        }
    }

    private func refreshMeter(generation: Int) {
        guard generation == testGeneration, engine != nil else { return }
        lock.lock()
        let v = recentPeak, count = nonzero
        recentPeak = 0
        lock.unlock()
        meter?.doubleValue = min(1, Double(v) * 18)
        detail?.stringValue = count > 100 ?
            "已接收到音频采样，继续说话…" :
            "正在录音，但尚未收到明显声音。请对着另一台 Mac 说话。"
    }

    private func finishTest() {
        lock.lock()
        let samples = nonzero
        let total = frames
        let maximum = peak
        lock.unlock()
        stopTesting()
        if samples > 1000 && maximum > 0.0005 {
            headline?.stringValue = "试音通过 · 收到远程声音"
            detail?.stringValue =
                "录音帧 \(total)，有效采样 \(samples)。远程麦克风链路可用。"
        } else {
            headline?.stringValue = "没有检测到明显声音"
            detail?.stringValue =
                "录音已启动，但未收到足够非零采样。请检查另一台 Mac 是否在线、麦克风权限，以及本机连接状态。"
        }
    }

    private func stopTesting() {
        testGeneration += 1
        timer?.invalidate(); timer = nil
        if let engine {
            let input = engine.inputNode
            engine.stop()
            input.removeTap(onBus: 0)
        }
        engine = nil
        testButton?.isEnabled = true
        testButton?.title = "再次试音"
    }

    func windowWillClose(_ notification: Notification) { stopTesting() }
}
