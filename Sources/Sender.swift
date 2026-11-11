// MicBridge Sender — runs on the MacBook Air.
// Advertises itself on the LAN via Bonjour. Receivers stay connected all the time
// and send a one-byte command when they need audio: "S" turns the microphone on,
// "P" turns it off. The microphone is on while at least one receiver wants it.
//
// Wire format, sender → receiver, as framed messages:
//   "H" + UInt32 LE sample rate          sent each time the mic starts
//   "A" + UInt32 LE byte count + Int16 LE mono samples

import AVFoundation
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)

// Fail closed: if the uu伴侣 menu app is killed or crashes, stop this audio
// helper rather than silently continuing to stream the microphone.
let parentAtLaunch = getppid()
let parentWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
parentWatchdog.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
parentWatchdog.setEventHandler {
    if getppid() != parentAtLaunch { exit(0) }
}
parentWatchdog.resume()

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(msg)")
}

let serviceType = "_uucompanion._tcp"
let sharedSecret = ProcessInfo.processInfo.environment["UU_COMPANION_SECRET"] ?? ""
guard sharedSecret.utf8.count >= 32 else { log("missing pairing secret; refusing to listen"); exit(2) }
var port: UInt16 = 50555
var loopbackOnly = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": port = UInt16(args.next() ?? "") ?? port
    case "--loopback-only": loopbackOnly = true
    default:
        print("usage: micbridge-sender [--port N]")
        exit(2)
    }
}

func tcpParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    // Notice a receiver that vanished (sleep, Wi-Fi drop) within ~20 s.
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 2
    let parameters = NWParameters(tls: nil, tcp: tcp)
    if loopbackOnly {
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
    }
    return parameters
}

final class Sender {
    private let queue = DispatchQueue(label: "micbridge.sender")
    // Core Audio / AVAudioEngine can synchronously block in HAL on macOS 27.
    // NEVER initialize or stop the microphone on the network/control queue.
    private let captureQueue = DispatchQueue(label: "uu.capture", qos: .userInitiated)
    private var engine: AVAudioEngine? // captureQueue only
    private var captureGeneration = 0 // network queue only
    private var microphoneStarting = false // network queue only
    private var microphoneStartTime: Date? // network queue only
    private var microphoneRate: Double? // network queue only
    private var microphoneStallLogged = false // network queue only
    private var lastCaptureFailure: Date? // network queue only
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var active: Set<ObjectIdentifier> = []
    private var lastHeartbeat: [ObjectIdentifier: Date] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var authorized: Set<ObjectIdentifier> = []
    private var handshakes: [ObjectIdentifier: Data] = [:]
    private var activity: NSObjectProtocol?
    private var listener: NWListener!

    func start() throws {
        listener = try NWListener(using: tcpParameters(), on: NWEndpoint.Port(rawValue: port)!)
        if !loopbackOnly {
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "MacBook", type: serviceType)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if loopbackOnly {
                    log("listening on 127.0.0.1:\(port) (cloud bridge only)")
                } else {
                    log("listening on port \(port), advertised as \(serviceType)")
                }
            case .failed(let e): log("listener failed: \(e)"); exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: .seconds(1))
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for id in Array(self.active) {
                if now.timeIntervalSince(self.lastHeartbeat[id] ?? .distantPast) > 8 {
                    log("receiver heartbeat expired — closing microphone for privacy")
                    self.active.remove(id)
                    self.lastHeartbeat[id] = nil
                }
            }
            if self.active.isEmpty && (self.microphoneRate != nil || self.microphoneStarting) {
                self.stopMic()
            }
            if self.microphoneStarting, !self.microphoneStallLogged,
               let begun = self.microphoneStartTime,
               now.timeIntervalSince(begun) > 8 {
                self.microphoneStallLogged = true
                log("microphone startup stalled in macOS Core Audio; control connection remains responsive")
            }
        }
        watchdog.resume()
        heartbeatTimer = watchdog
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("receiver connected: \(conn.endpoint)")
                self.clients[id] = conn
                self.readCommands(conn)
            case .failed, .cancelled:
                self.drop(conn)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func readCommands(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, done, err in
            guard let self else { return }
            let id = ObjectIdentifier(conn)
            var payload = data ?? Data()
            if !self.authorized.contains(id) {
                self.handshakes[id, default: Data()].append(payload)
                guard let bytes = self.handshakes[id], bytes.count < 256 else {
                    conn.cancel(); self.drop(conn); return
                }
                if let newline = bytes.firstIndex(of: 10) {
                    let line = String(decoding: bytes.prefix(upTo: newline), as: UTF8.self)
                    guard line == "AUTH " + sharedSecret else {
                        log("rejected unauthenticated receiver")
                        conn.cancel(); self.drop(conn); return
                    }
                    self.authorized.insert(id)
                    self.handshakes[id] = nil
                    payload = Data(bytes.suffix(from: bytes.index(after: newline)))
                    log("receiver authenticated")
                } else {
                    if done || err != nil { conn.cancel(); self.drop(conn) }
                    else { self.readCommands(conn) }
                    return
                }
            }
            for byte in payload {
                switch byte {
                case UInt8(ascii: "S"): self.setActive(conn, true)
                case UInt8(ascii: "P"): self.setActive(conn, false)
                case UInt8(ascii: "K"):
                    self.lastHeartbeat[id] = Date()
                    if !self.active.contains(id) { self.setActive(conn, true) }
                default: break
                }
            }
            if done || err != nil { conn.cancel(); self.drop(conn) } else { self.readCommands(conn) }
        }
    }

    private func setActive(_ conn: NWConnection, _ on: Bool) {
        let id = ObjectIdentifier(conn)
        let wasOn = !active.isEmpty
        if on { active.insert(id); lastHeartbeat[id] = Date() }
        else { active.remove(id); lastHeartbeat[id] = nil }
        if on {
            if let rate = microphoneRate { send(header(rate: rate), to: conn) }
            else if !microphoneStarting &&
                    (lastCaptureFailure == nil ||
                     Date().timeIntervalSince(lastCaptureFailure!) > 10) {
                startMic()
            }
        } else if wasOn && active.isEmpty {
            stopMic()
        }
    }

    private func drop(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        guard clients.removeValue(forKey: id) != nil else { return }
        authorized.remove(id)
        handshakes[id] = nil
        lastHeartbeat[id] = nil
        log("receiver disconnected")
        if active.remove(id) != nil && active.isEmpty { stopMic() }
    }

    private func header(rate: Double) -> Data {
        var d = Data("H".utf8)
        withUnsafeBytes(of: UInt32(rate).littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    private func send(_ data: Data, to conn: NWConnection) {
        conn.send(content: data, completion: .idempotent)
    }

    private func captureFailure(_ detail: String, generation: Int) {
        queue.async {
            guard self.captureGeneration == generation else { return }
            self.microphoneStarting = false
            self.microphoneStartTime = nil
            self.lastCaptureFailure = Date()
            log(detail)
        }
    }

    private func startMic() {
        guard !microphoneStarting && microphoneRate == nil else { return }
        captureGeneration += 1
        let generation = captureGeneration
        microphoneStarting = true
        microphoneStartTime = Date()
        microphoneStallLogged = false
        log("microphone initialization requested")
        captureQueue.async { [weak self] in
            guard let self else { return }
            // Potentially blocking calls below live on the capture queue.
            let newEngine = AVAudioEngine()
            let input = newEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                self.captureFailure("no physical microphone available", generation: generation)
                return
            }

            let sink = AVAudioSinkNode { [weak self] _, frames, abl -> OSStatus in
                guard let self else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                guard let ch0 = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let n = Int(frames)
                var audio = Data(count: 5 + n * 2)
                audio.withUnsafeMutableBytes { raw in
                    raw[0] = UInt8(ascii: "A")
                    raw.storeBytes(of: UInt32(n * 2).littleEndian, toByteOffset: 1, as: UInt32.self)
                    for i in 0..<n {
                        let sample = max(-1, min(1, ch0[i]))
                        raw.storeBytes(of: Int16(sample * 32767).littleEndian,
                                       toByteOffset: 5 + i * 2, as: Int16.self)
                    }
                }
                self.queue.async {
                    guard self.captureGeneration == generation else { return }
                    for id in self.active {
                        if let connection = self.clients[id] {
                            self.send(audio, to: connection)
                        }
                    }
                }
                return noErr
            }
            newEngine.attach(sink)
            newEngine.connect(input, to: sink, format: format)
            // If the user already stopped recording while HAL initialization
            // blocked, do not start the microphone when the OS finally returns.
            let stillWanted = self.queue.sync {
                self.captureGeneration == generation && !self.active.isEmpty
            }
            guard stillWanted else { return }
            do {
                try newEngine.start()
                self.engine = newEngine
                self.activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                    reason: "Sharing this Mac microphone with a paired Mac")
                self.queue.async {
                    guard self.captureGeneration == generation && !self.active.isEmpty else {
                        self.captureQueue.async { self.stopEngineOnCaptureQueue() }
                        return
                    }
                    self.microphoneRate = format.sampleRate
                    self.microphoneStarting = false
                    self.microphoneStartTime = nil
                    self.lastCaptureFailure = nil
                    for id in self.active {
                        if let connection = self.clients[id] {
                            self.send(self.header(rate: format.sampleRate), to: connection)
                        }
                    }
                    log("microphone ON (\(Int(format.sampleRate)) Hz)")
                }
            } catch {
                self.captureFailure("failed to start microphone: \(error)", generation: generation)
            }
        }
    }

    private func stopEngineOnCaptureQueue() {
        if let engine { engine.stop(); self.engine = nil }
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func stopMic() {
        // Cancel any blocked/in-flight startup before queuing the stop.
        captureGeneration += 1
        microphoneStarting = false
        microphoneStartTime = nil
        microphoneRate = nil
        microphoneStallLogged = false
        captureQueue.async { [weak self] in
            self?.stopEngineOnCaptureQueue()
        }
        log("microphone OFF")
    }

}

AVCaptureDevice.requestAccess(for: .audio) { granted in
    if !granted {
        log("microphone permission denied — allow it in System Settings › Privacy & Security › Microphone")
    }
}

let sender = Sender()
do { try sender.start() } catch { log("cannot start: \(error)"); exit(1) }
dispatchMain()
