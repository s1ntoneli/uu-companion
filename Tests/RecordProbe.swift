import AVFoundation
import AppKit
import Foundation

final class RecordProbe: NSObject, NSApplicationDelegate {
    private let logPath = NSHomeDirectory() + "/Library/Logs/uu-companion-e2e-test.log"
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var frames = 0
    private var nonZeroSamples = 0
    private var peak: Float = 0

    private func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
        print(line, terminator: "")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        write("Starting microphone authorization")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.write("Microphone permission: \(granted)")
                guard granted else { NSApp.terminate(nil); return }
                self.record()
            }
        }
    }
    private func record() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        write("Selected default microphone sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var nonZero = 0
            var maxSample: Float = 0
            for i in 0..<count {
                let v = abs(channel[i])
                if v > 0.00005 { nonZero += 1 }
                maxSample = max(maxSample, v)
            }
            self.lock.lock()
            self.frames += count
            self.nonZeroSamples += nonZero
            self.peak = max(self.peak, maxSample)
            self.lock.unlock()
        }
        do {
            try engine.start()
            self.engine = engine
            write("RECORDING START")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self else { return }
                engine.stop()
                input.removeTap(onBus: 0)
                self.lock.lock()
                let summary = "RECORDING STOP frames=\(self.frames) nonZeroSamples=\(self.nonZeroSamples) peak=\(self.peak)"
                self.lock.unlock()
                self.write(summary)
                NSApp.terminate(nil)
            }
        } catch {
            write("Recording failed: \(error)")
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let delegate = RecordProbe()
app.delegate = delegate
app.run()
