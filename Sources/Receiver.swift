// MicBridge Receiver — runs on the Mac mini.
// Watches whether any app is recording from the BlackHole virtual device.
// It keeps a connection to the sender on the MacBook Air open at all times; when an
// app records, it asks the Air to switch its microphone on and plays the incoming
// audio into BlackHole, so the app hears the Air's mic. When recording stops, it
// asks the Air to switch the microphone off again.

import AudioToolbox
import CoreAudio
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
guard sharedSecret.utf8.count >= 32 else { log("missing pairing secret; refusing to connect"); exit(2) }
var host: String?
var port: UInt16 = 50555
var deviceMatch = "BlackHole"
var alwaysOn = false
var setDefault = true
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--host": host = args.next()
    case "--port": port = UInt16(args.next() ?? "") ?? port
    case "--device": deviceMatch = args.next() ?? deviceMatch
    case "--always-on": alwaysOn = true
    case "--no-set-default": setDefault = false
    default:
        print("""
        usage: micbridge-receiver [--host IP] [--port N] [--device NAME] [--always-on] [--no-set-default]
          --host        connect to this address instead of finding the Air via Bonjour
          --device      virtual device name to feed (default: BlackHole)
          --always-on   keep streaming even when nothing is recording
          --no-set-default  don't make the virtual device the default input
        """)
        exit(2)
    }
}

// MARK: - Core Audio helpers

func getProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr else { return [] }
    let typed = ptr.bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "" }
    return n.takeRetainedValue() as String
}

func findDevice(matching: String) -> AudioDeviceID? {
    let ids: [AudioDeviceID] = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return ids.first { deviceName($0).localizedCaseInsensitiveContains(matching) }
}

func setDefaultInput(_ id: AudioDeviceID) {
    var dev = id
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

/// True when some process other than us is currently recording from `device`.
func processBundleID(_ process: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr,
          let value else { return "" }
    return value.takeRetainedValue() as String
}

func someoneIsRecording(from device: AudioDeviceID) -> Bool {
    let me = getpid()
    let procs: [AudioObjectID] = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    for p in procs {
        let pid: [pid_t] = getProperty(p, kAudioProcessPropertyPID)
        guard let pid = pid.first, pid != me else { continue }
        let running: [UInt32] = getProperty(p, kAudioProcessPropertyIsRunningInput)
        guard running.first ?? 0 != 0 else { continue }
        if processBundleID(p) == "com.apple.replayd" { continue }
        let devices: [AudioObjectID] = getProperty(p, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        if devices.contains(device) { return true }
        if devices.isEmpty {
            // A few apps do not enumerate device IDs. Treat those as default-input
            // recordings only when BlackHole is the selected default device.
            let defaults: [AudioDeviceID] = getProperty(AudioObjectID(kAudioObjectSystemObject),
                                                        kAudioHardwarePropertyDefaultInputDevice)
            if defaults.first == device { return true }
        }
    }
    return false
}

// MARK: - Jitter buffer

final class RingBuffer {
    private var buf: [Float]
    private var readIdx = 0, writeIdx = 0
    private(set) var count = 0
    private var lock = os_unfair_lock()
    private var primed = false
    private var consumedFrames = 0
    private var consumedNonZero = 0
    private var audioCallbacks = 0
    let target: Int, maxFill: Int

    init(sampleRate: Double) {
        buf = [Float](repeating: 0, count: Int(sampleRate * 2))
        target = Int(sampleRate * 0.04)   // ~40 ms cushion before playback starts
        maxFill = Int(sampleRate * 0.2)   // drop old audio if latency builds past 200 ms
    }

    func write(_ samples: [Float]) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for s in samples {
            buf[writeIdx] = s
            writeIdx = (writeIdx + 1) % buf.count
            if count == buf.count { readIdx = (readIdx + 1) % buf.count } else { count += 1 }
        }
        if count > maxFill {
            let skip = count - target
            readIdx = (readIdx + skip) % buf.count
            count -= skip
        }
    }

    func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        readIdx = 0; writeIdx = 0; count = 0; primed = false
    }

    func diagnosticSnapshot() -> (Int, Int, Int, Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (audioCallbacks, consumedFrames, consumedNonZero, count)
    }

    func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        audioCallbacks += 1
        if !primed && count >= target { primed = true }
        var i = 0
        if primed {
            while i < frames && count > 0 {
                out[i] = buf[readIdx]
                consumedFrames += 1
                if abs(out[i]) > 0.0001 { consumedNonZero += 1 }
                readIdx = (readIdx + 1) % buf.count
                count -= 1
                i += 1
            }
            if count == 0 { primed = false }  // underrun: re-buffer before resuming
        }
        while i < frames { out[i] = 0; i += 1 }
    }
}

// MARK: - Output to the virtual device

/// Plays the ring buffer into one specific device through its own HAL output unit.
/// Unlike AVAudioEngine's output node, this stays on that device when the user
/// changes the system's default output (e.g. back to the speakers).
/// AudioQueue output is used instead of HALOutput: on this macOS 27 Mini the
/// HAL AudioUnit can block for minutes during CurrentDevice/StartIO even
/// though the ARK virtual device itself is healthy.
final class DeviceOutput {
    private var queue: AudioQueueRef?
    private let ring: RingBuffer
    private let framesPerBuffer = 512

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    init(device: AudioDeviceID, sampleRate: Double, ring: RingBuffer) throws {
        self.ring = ring
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var managedUID: Unmanaged<CFString>?
        var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = AudioObjectGetPropertyData(device, &addr, 0, nil, &bytes, &managedUID)
        guard result == noErr, let managedUID else {
            throw Failure(step: "read virtual device UID", status: result)
        }
        var uid = managedUID.takeRetainedValue()
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var newQueue: AudioQueueRef?
        try Self.check("create AudioQueue", AudioQueueNewOutput(
            &format, { userData, callbackQueue, buffer in
                guard let userData else { return }
                let player = Unmanaged<DeviceOutput>.fromOpaque(userData).takeUnretainedValue()
                player.fill(buffer, queue: callbackQueue)
            }, Unmanaged.passUnretained(self).toOpaque(),
            nil, nil, 0, &newQueue))
        guard let output = newQueue else {
            throw Failure(step: "allocate AudioQueue", status: -1)
        }
        queue = output
        let selected = withUnsafePointer(to: &uid) {
            AudioQueueSetProperty(output, kAudioQueueProperty_CurrentDevice, $0,
                                  UInt32(MemoryLayout<CFString>.size))
        }
        try Self.check("select \(deviceName(device))", selected)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try Self.check("allocate output buffer", AudioQueueAllocateBuffer(
                output, UInt32(framesPerBuffer * 2 * MemoryLayout<Float>.size), &buffer))
            guard let buffer else {
                throw Failure(step: "missing output buffer", status: -1)
            }
            fill(buffer, queue: output)
        }
        try Self.check("start AudioQueue", AudioQueueStart(output, nil))
        log("AudioQueue running on \(deviceName(device)) at \(Int(sampleRate)) Hz")
    }

    /// The queue uses interleaved stereo. Expand mono samples in reverse order
    /// so the ring's first half-buffer can be duplicated in place safely.
    private func fill(_ buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let frames = Int(buffer.pointee.mAudioDataBytesCapacity) / (MemoryLayout<Float>.size * 2)
        guard frames > 0 else { return }
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        ring.read(into: samples, frames: frames)
        for i in stride(from: frames - 1, through: 0, by: -1) {
            let value = samples[i]
            samples[2 * i] = value
            samples[2 * i + 1] = value
        }
        buffer.pointee.mAudioDataByteSize = UInt32(frames * 2 * MemoryLayout<Float>.size)
        _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    func stop() {
        guard let output = queue else { return }
        queue = nil
        AudioQueueStop(output, true)
        AudioQueueDispose(output, true)
    }

    deinit { stop() }

    private static func check(_ step: String, _ result: OSStatus) throws {
        if result != noErr { throw Failure(step: step, status: result) }
    }
}

// MARK: - Native input-only driver injection
// Instead of creating an output stream (as required by Loopback/BlackHole),
// push short blocks of PCM into the uu伴侣 Native Mic's own MIT HAL plug-in.
// The driver publishes only an input device, so it never changes system audio output.
final class NativeMicFeed {
    private let device: AudioDeviceID
    private let sourceRate: Double
    private var previous: Float = 0
    private var hasPrevious = false
    private var phase: Double = 0
    private let audioPacketSelector: UInt32 = 0x7575_6170 // 'uuap'
    private var successfulWrites = 0
    private var failedWrites = 0

    init(device: AudioDeviceID, sourceRate: Double) {
        self.device = device
        self.sourceRate = sourceRate
    }

    func write(_ mono: [Float]) {
        guard !mono.isEmpty else { return }
        var resampled: [Float] = []
        if abs(sourceRate - 48_000) < 0.001 {
            resampled = mono
        } else {
            let step = sourceRate / 48_000
            if !hasPrevious { previous = mono[0]; hasPrevious = true }
            // The first sample is the tail of the previous packet, ensuring
            // interpolation is continuous across TCP chunk boundaries.
            let input = [previous] + mono
            var cursor = phase
            while cursor + 1 < Double(input.count) {
                let index = Int(cursor)
                let fraction = Float(cursor - Double(index))
                resampled.append(input[index] * (1 - fraction) + input[index + 1] * fraction)
                cursor += step
            }
            phase = cursor - Double(input.count - 1)
            previous = mono[mono.count - 1]
        }
        guard !resampled.isEmpty else { return }
        let batchSize = 1_024
        for start in stride(from: 0, to: resampled.count, by: batchSize) {
            let frames = min(batchSize, resampled.count - start)
            var stereo = [Float](repeating: 0, count: frames * 2)
            for f in 0..<frames {
                let v = resampled[start + f]
                stereo[2 * f] = v
                stereo[2 * f + 1] = v
            }
            var addr = AudioObjectPropertyAddress(
                mSelector: audioPacketSelector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var cfData = stereo.withUnsafeBytes { raw -> CFData in
                CFDataCreate(kCFAllocatorDefault,
                             raw.bindMemory(to: UInt8.self).baseAddress, raw.count)!
            }
            // HAL custom properties are marshaled through a CFPropertyList
            // boundary. Pass CFDataRef rather than raw PCM pointer.
            let result = withUnsafePointer(to: &cfData) {
                AudioObjectSetPropertyData(device, &addr, 0, nil,
                                           UInt32(MemoryLayout<CFData>.size), $0)
            }
            if result == noErr {
                successfulWrites += 1
                if successfulWrites == 100 {
                    log("native microphone PCM injection verified: 100 packets sent")
                }
            } else {
                failedWrites += 1
                if failedWrites <= 3 || failedWrites % 100 == 0 {
                    log("native microphone injection failed: HAL status \(result)")
                }
            }
        }
    }
}

// MARK: - Receiver

final class Receiver {
    private let queue = DispatchQueue(label: "micbridge.receiver")
    private let device: AudioDeviceID
    private var browser: NWBrowser?
    private var senderEndpoint: NWEndpoint?
    private var conn: NWConnection?
    private var ready = false
    private var micRequested = false
    private var output: DeviceOutput?
    private var nativeOutput: NativeMicFeed?
    private var outputRate: Double = 0
    private var ring: RingBuffer?
    private var pending = Data()
    private var receivedFrames = 0
    private var receivedNonZero = 0
    private var receivedPeak: Float = 0
    private var loggedFirstAudioWindow = false
    private var idleSince: Date?
    private var lastAttempt: Date?
    private var failures = 0  // consecutive failed attempts, for backoff and quieter logs
    private var lastDiagnostic: Date?
    private var lastKeepaliveSent: Date?
    private var requestedAt: Date?
    private var micStartTimeoutLogged = false

    init(device: AudioDeviceID) { self.device = device }

    func start() {
        if let host {
            senderEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        } else {
            let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            b.stateUpdateHandler = { state in
                log("Bonjour discovery state: \(state)")
            }
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                let ep = results.first?.endpoint
                if ep != self.senderEndpoint {
                    self.senderEndpoint = ep
                    log(ep.map { "found sender: \($0)" } ?? "sender went away")
                    // An attempt still pending from before the sender went away (e.g. it
                    // fell asleep mid-connect) will never finish; start over.
                    if ep != nil && self.conn != nil && !self.ready { self.disconnect() }
                    // It just (re)appeared, so try right away instead of waiting out the backoff.
                    if ep != nil { self.lastAttempt = nil; self.failures = 0 }
                }
            }
            b.start(queue: queue)
            browser = b
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        _timer = timer
    }
    private var _timer: DispatchSourceTimer?

    private func tick() {
        if micRequested && ready, !micStartTimeoutLogged,
           let requestedAt, Date().timeIntervalSince(requestedAt) > 8 {
            micStartTimeoutLogged = true
            log("remote microphone startup timed out (no audio header after 8s)")
        }
        if micRequested && ready &&
           (lastKeepaliveSent == nil || Date().timeIntervalSince(lastKeepaliveSent!) >= 2) {
            command("K")
            lastKeepaliveSent = Date()
        }
        if micRequested, (lastDiagnostic == nil || Date().timeIntervalSince(lastDiagnostic!) >= 3) {
            if let snapshot = ring?.diagnosticSnapshot() {
                log("HAL output diagnostic callbacks=\(snapshot.0), consumedFrames=\(snapshot.1), nonZeroOutput=\(snapshot.2), bufferPending=\(snapshot.3)")
            }
            lastDiagnostic = Date()
        }
        if conn != nil && !ready, let t = lastAttempt, Date().timeIntervalSince(t) > 8 {
            failures += 1
            if failures == 1 { log("connection attempt timed out — retrying in the background") }
            disconnect()
        }
        if conn == nil { connect() }
        let wanted = alwaysOn || someoneIsRecording(from: device)
        if wanted {
            idleSince = nil
            if ready && !micRequested {
                log("an app started recording — turning the MacBook mic on")
                command("S")
                micRequested = true
                requestedAt = Date()
                micStartTimeoutLogged = false
            }
        } else if micRequested {
            // Short grace period so brief pauses between recordings don't bounce the mic.
            if idleSince == nil { idleSince = Date() }
            if Date().timeIntervalSince(idleSince!) > 3 {
                log("no app is recording any more — turning the MacBook mic off")
                command("P")
                micRequested = false
                requestedAt = nil
                micStartTimeoutLogged = false
                idleSince = nil
            }
        }
    }

    private func command(_ c: String) {
        conn?.send(content: Data(c.utf8), completion: .idempotent)
    }

    // The connection stays up all the time so a recording only has to wait for the
    // Air's microphone to switch on, not for discovery, TCP setup and audio engine start.
    private func connect() {
        guard let ep = senderEndpoint else { return }
        // Retry at 2 s initially and cap backoff at 10 s. The previous 30 s
        // maximum made re-opening the MacBook app feel disconnected for too long.
        // We still keep bounded retries rather than spin while the sender is offline.
        let delay = min(10, 2 * pow(2, Double(min(failures, 3))))
        if let t = lastAttempt, Date().timeIntervalSince(t) < delay { return }
        lastAttempt = Date()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        tcp.connectionTimeout = 5
        let c = NWConnection(to: ep, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.conn === c else { return }
            switch state {
            case .ready:
                log("connected to \(ep)")
                self.ready = true
                self.failures = 0
                self.pending = Data()
                c.send(content: Data(("AUTH " + sharedSecret + "\n").utf8), completion: .idempotent)
                self.ensurePlayback(sampleRate: 48000)  // warm up; rebuilt if the Air uses another rate
                self.receive(c)
            case .waiting(let e):
                if #available(macOS 15.0, *),
                   c.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    log("Local Network access is blocked. Allow uu伴侣 under System Settings > Privacy & Security > Local Network.")
                    return // macOS resumes the connection after permission is granted.
                }
                self.failures += 1
                if self.failures == 1 || self.failures % 20 == 0 {
                    log("cannot reach sender (\(e)) — retrying in the background")
                }
                self.disconnect()
            case .failed(let e):
                self.failures += 1
                if self.failures == 1 || self.failures % 20 == 0 {
                    log("cannot reach sender (\(e)) — retrying in the background")
                }
                self.disconnect()
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func disconnect() {
        let wasReady = ready
        conn?.cancel()
        conn = nil
        ready = false
        micRequested = false
        requestedAt = nil
        micStartTimeoutLogged = false
        idleSince = nil
        output?.stop()
        output = nil
        nativeOutput = nil
        outputRate = 0
        ring = nil
        if wasReady { log("disconnected from sender") }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self, self.conn === c else { return }
            if let data { self.handle(data) }
            if done || err != nil { log("sender closed the connection"); self.disconnect(); return }
            self.receive(c)
        }
    }

    private func handle(_ data: Data) {
        pending.append(data)
        var samples: [Float] = []
        var consumed = 0
        var newRate: Double?
        pending.withUnsafeBytes { raw in
            while raw.count - consumed >= 5 {
                let type = raw[consumed]
                let value = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: consumed + 1, as: UInt32.self))
                if type == UInt8(ascii: "H") {
                    newRate = Double(value)
                    samples.removeAll()
                    consumed += 5
                } else if type == UInt8(ascii: "A") {
                    let len = Int(value)
                    guard raw.count - consumed >= 5 + len else { break }
                    for i in 0..<len / 2 {
                        let s = raw.loadUnaligned(fromByteOffset: consumed + 5 + i * 2, as: Int16.self)
                        samples.append(Float(Int16(littleEndian: s)) / 32768)
                    }
                    consumed += 5 + len
                } else {
                    consumed = -1
                    break
                }
            }
        }
        guard consumed >= 0 else { log("bad data from sender — is the Air running an older MicBridge?"); disconnect(); return }
        pending.removeFirst(consumed)
        if let newRate {
            receivedFrames = 0
            receivedNonZero = 0
            receivedPeak = 0
            loggedFirstAudioWindow = false
            ensurePlayback(sampleRate: newRate)
            ring?.reset()
            if let t = requestedAt {
                log(String(format: "MacBook mic is on (%.2f s after the request)", Date().timeIntervalSince(t)))
                requestedAt = nil
            }
        }
        if !samples.isEmpty {
            if !loggedFirstAudioWindow {
                receivedFrames += samples.count
                for sample in samples {
                    let magnitude = abs(sample)
                    receivedPeak = max(receivedPeak, magnitude)
                    if magnitude > 0.0001 { receivedNonZero += 1 }
                }
                if receivedFrames >= Int(max(1, outputRate) * 2) {
                    log("received microphone audio: \(receivedFrames) samples, nonzero=\(receivedNonZero), peak=\(receivedPeak)")
                    loggedFirstAudioWindow = true
                }
            }
            ring?.write(samples)
            nativeOutput?.write(samples)
        }
    }

    private func ensurePlayback(sampleRate: Double) {
        if outputRate == sampleRate && (output != nil || nativeOutput != nil) { return }
        output?.stop()
        output = nil
        nativeOutput = nil
        if deviceName(device).contains("uu伴侣 Native Mic") {
            self.ring = nil
            nativeOutput = NativeMicFeed(device: device, sourceRate: sampleRate)
            outputRate = sampleRate
            log("native microphone injector ready → \(deviceName(device)) (source \(Int(sampleRate)) Hz, output 48000 Hz)")
            return
        }
        let ring = RingBuffer(sampleRate: sampleRate)
        self.ring = ring
        do {
            output = try DeviceOutput(device: device, sampleRate: sampleRate, ring: ring)
            outputRate = sampleRate
            log("audio output ready → \(deviceName(device)) (\(Int(sampleRate)) Hz)")
        } catch {
            log("could not start audio output: \(error)")
            outputRate = 0
        }
    }
}

guard let device = findDevice(matching: deviceMatch) else {
    log("no audio device matching \"\(deviceMatch)\" — check that the virtual audio driver is installed and enabled")
    exit(1)
}
log("using virtual device: \(deviceName(device))")
if setDefault {
    setDefaultInput(device)
    log("set \(deviceName(device)) as the default input device")
}

let receiver = Receiver(device: device)
receiver.start()
log(alwaysOn ? "always-on mode" : "the MacBook mic turns on when an app records from \(deviceName(device))")
dispatchMain()
