import Foundation
import Network
import CryptoKit
import Security

setvbuf(stdout, nil, _IOLBF, 0)

// A thin end-to-end encrypted WSS bridge for the existing tested LAN engine.
// Both Macs establish outbound WSS; receiver listens only on 127.0.0.1:50556;
// sender dials only the existing local 127.0.0.1:50555 microphone service.
// No cloud account, plaintext audio on the server, or public TCP port needed.
let parentPID = getppid()
let parentWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
parentWatch.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
parentWatch.setEventHandler { if getppid() != parentPID { exit(0) } }
parentWatch.resume()

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] cloud: \(msg)")
}

let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
func normalizedCode(_ text: String) -> String? {
    let raw = text.uppercased().filter { $0 != "-" && $0 != " " }
    guard raw.count == 16, raw.allSatisfy({ alphabet.contains($0) }) else { return nil }
    return raw
}
func codeHash(_ domain: String, _ code: String) -> Data {
    Data(SHA256.hash(data: Data((domain + code).utf8)))
}
func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

let environment = ProcessInfo.processInfo.environment
guard let code = environment["UU_RELAY_CODE"].flatMap(normalizedCode),
      let baseString = environment["UU_RELAY_URL"],
      let url = URL(string: baseString),
      url.scheme == "wss",
      let secret = environment["UU_COMPANION_SECRET"],
      secret.utf8.count >= 32 else {
    log("configuration missing/invalid (requires code, wss URL and local app secret)")
    exit(2)
}
let role = CommandLine.arguments.dropFirst().first ?? ""
guard role == "sender" || role == "receiver" else { log("role must be sender or receiver"); exit(2) }
let relayURL = url
let authenticationSecret = secret
let room = hex(codeHash("uu.room.v1:", code))
let sendKey = SymmetricKey(data: codeHash(role == "sender" ? "uu.sender.v1:" : "uu.receiver.v1:", code))
let receiveKey = SymmetricKey(data: codeHash(role == "sender" ? "uu.receiver.v1:" : "uu.sender.v1:", code))
let otherRole = role == "sender" ? "receiver" : "sender"
let tcpPort: UInt16 = role == "sender" ? 50555 : 50556

final class Bridge: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    let q = DispatchQueue(label: "uu.cloud.bridge")
    private var session: URLSession!
    private var webSocket: URLSessionWebSocketTask?
    private var generation = 0
    private var opened = false
    private var peerOnline = false
    private var local: NWConnection?
    private var listener: NWListener?
    private var waitingForAuth = false
    private var authBuffer = Data()
    private var pendingCommands = [Data]()
    private var outgoing = [Data]()
    private var audioBatch = Data()
    private var sending = false
    private var reconnectAfter = 2.0
    private var lastTraffic: Date?

    func start() {
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        if role == "receiver" { startListener() }
        connectWebSocket()
        let watchdog = DispatchSource.makeTimerSource(queue: q)
        watchdog.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            // Keep hibernating WebSocket alive over NAT. The relay responds pong.
            if self.opened { self.webSocket?.send(.string("ping")) { _ in } }
        }
        watchdog.resume()
        _watchdog = watchdog
        // Batch streaming PCM every 50 ms rather than one WebSocket message
        // per Core Audio callback; this reduces public relay quota use.
        if role == "sender" {
            let flush = DispatchSource.makeTimerSource(queue: q)
            flush.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            flush.setEventHandler { [weak self] in self?.flushAudio() }
            flush.resume()
            _audioTimer = flush
        }
    }
    private var _watchdog: DispatchSourceTimer?
    private var _audioTimer: DispatchSourceTimer?
    private func flushAudio() {
        guard !audioBatch.isEmpty else { return }
        let batch = audioBatch
        audioBatch.removeAll(keepingCapacity: true)
        writeEncrypted(batch)
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: tcpPort)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] c in
                guard let self else { c.cancel(); return }
                if self.local != nil { c.cancel(); return }
                self.local = c
                self.waitingForAuth = true
                self.authBuffer.removeAll(keepingCapacity: true)
                c.stateUpdateHandler = { [weak self] state in
                    guard let self, self.local === c else { return }
                    switch state {
                    case .ready:
                        log("local microphone consumer connected")
                        self.receiveLocal(c)
                    case .failed, .cancelled:
                        self.closeLocal()
                    default: break
                    }
                }
                c.start(queue: self.q)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: log("local receiver listening on 127.0.0.1:\(tcpPort)")
                case .failed(let e): log("local listen failed: \(e)")
                default: break
                }
            }
            listener.start(queue: q)
        } catch { log("failed to bind local TCP bridge: \(error)"); exit(3) }
    }

    private func connectWebSocket() {
        generation += 1
        let gen = generation
        opened = false
        peerOnline = false
        sending = false
        outgoing.removeAll()
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else { exit(2) }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path + "/v1/rooms/" + room
        components.queryItems = [URLQueryItem(name: "role", value: role)]
        guard let endpoint = components.url else { exit(2) }
        let task = session.webSocketTask(with: endpoint)
        task.maximumMessageSize = 131072
        webSocket = task
        task.resume()
        receiveWebSocket(task, gen)
        log("connecting to free relay with encrypted room ID")
    }
    private func receiveWebSocket(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard self.generation == gen else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           obj["type"] as? String == "peer",
                           let online = obj["online"] as? Bool {
                            let changed = online != self.peerOnline
                            self.peerOnline = online
                            if changed { log(online ? "paired peer online" : "paired peer offline") }
                            if !online && changed { self.closeLocal() }
                            else if online && role == "sender" { self.startLocalSender() }
                        }
                    case .data(let ciphertext):
                        guard let box = try? ChaChaPoly.SealedBox(combined: ciphertext),
                              let content = try? ChaChaPoly.open(box, using: receiveKey) else {
                            log("dropping unauthenticated encrypted frame")
                            break
                        }
                        self.handleDecrypted(content)
                    @unknown default: break
                    }
                    self.receiveWebSocket(task, gen)
                case .failure(let err):
                    log("relay receive closed: \(err.localizedDescription)")
                    self.reconnectIfCurrent(gen)
                }
            }
        }
    }
    private func handleDecrypted(_ content: Data) {
        guard !content.isEmpty else { return }
        if role == "sender" {
            let command = content
            if let local {
                local.send(content: command, completion: .idempotent)
            } else {
                if pendingCommands.count < 100 { pendingCommands.append(command) }
                if peerOnline { startLocalSender() }
            }
        } else {
            if let local, !waitingForAuth { local.send(content: content, completion: .idempotent) }
        }
    }
    private func writeEncrypted(_ data: Data) {
        guard peerOnline, opened, !data.isEmpty else { return }
        guard data.count <= 32000 else { log("dropping oversize audio chunk"); return }
        do {
            let sealed = try ChaChaPoly.seal(data, using: sendKey)
            let combined = sealed.combined
            if outgoing.count >= 180 {
                // Raw PCM stream chunks can span framed messages. Dropping a
                // chunk corrupts the receiver parser; reset the connection
                // instead and re-send the stream header on the next session.
                log("relay backpressure; resetting stream safely")
                reconnectIfCurrent(generation)
                return
            }
            outgoing.append(combined)
            sendNext()
        } catch { log("encryption failed") }
    }
    private func sendNext() {
        guard opened, !sending, !outgoing.isEmpty, let task = webSocket else { return }
        sending = true
        let next = outgoing.removeFirst()
        let gen = generation
        task.send(.data(next)) { [weak self] error in
            guard let self else { return }
            self.q.async {
                guard self.generation == gen else { return }
                self.sending = false
                if let error {
                    log("relay send failed: \(error.localizedDescription)")
                    self.reconnectIfCurrent(gen)
                } else {
                    self.sendNext()
                }
            }
        }
    }
    private func startLocalSender() {
        guard role == "sender", peerOnline, local == nil else { return }
        let params = NWParameters.tcp
        let local = NWConnection(host: .init("127.0.0.1"), port: NWEndpoint.Port(rawValue: tcpPort)!, using: params)
        self.local = local
        local.stateUpdateHandler = { [weak self] state in
            guard let self, self.local === local else { return }
            switch state {
            case .ready:
                local.send(content: Data(("AUTH " + authenticationSecret + "\n").utf8), completion: .idempotent)
                log("connected to local mic provider")
                for c in self.pendingCommands { local.send(content: c, completion: .idempotent) }
                self.pendingCommands.removeAll()
                self.receiveLocal(local)
            case .failed, .cancelled:
                self.closeLocal()
            default: break
            }
        }
        local.start(queue: q)
    }
    private func receiveLocal(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self, self.local === conn else { return }
            if let data, !data.isEmpty {
                if role == "receiver" && self.waitingForAuth {
                    self.authBuffer.append(data)
                    if self.authBuffer.count > 256 { self.closeLocal(); return }
                    if let newline = self.authBuffer.firstIndex(of: 10) {
                        let line = String(decoding: self.authBuffer.prefix(upTo: newline), as: UTF8.self)
                        guard line == "AUTH " + authenticationSecret else { self.closeLocal(); return }
                        let rest = self.authBuffer.suffix(from: self.authBuffer.index(after: newline))
                        self.waitingForAuth = false
                        if !rest.isEmpty { self.writeEncrypted(Data(rest)) }
                        self.authBuffer.removeAll()
                    }
                } else if role == "sender" {
                    // Audio is a byte stream and may be coalesced safely without
                    // modifying the H/A frame structure.
                    self.audioBatch.append(data)
                    if self.audioBatch.count >= 16000 { self.flushAudio() }
                } else {
                    self.writeEncrypted(data)
                }
            }
            if done || error != nil { self.closeLocal() }
            else { self.receiveLocal(conn) }
        }
    }
    private func closeLocal() {
        if let connection = local {
            local = nil
            connection.cancel()
            log("local stream closed")
        }
        authBuffer.removeAll()
        waitingForAuth = false
        audioBatch.removeAll(keepingCapacity: true)
        pendingCommands.removeAll()
    }
    private func reconnectIfCurrent(_ gen: Int) {
        guard generation == gen else { return }
        let wasOnline = peerOnline
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        opened = false
        peerOnline = false
        sending = false
        outgoing.removeAll()
        closeLocal()
        if wasOnline { log("relay disconnected; microphone safe idle") }
        let delay = reconnectAfter
        reconnectAfter = min(12, reconnectAfter * 1.8)
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.connectWebSocket()
        }
    }
    // MARK: URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        q.async {
            guard self.webSocket === webSocketTask else { return }
            self.opened = true
            self.reconnectAfter = 2
            log("relay WSS connected (end-to-end encrypted)")
            self.sendNext()
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        q.async {
            guard self.webSocket === webSocketTask else { return }
            log("relay WSS closed: \(closeCode.rawValue)")
            self.reconnectIfCurrent(self.generation)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            q.async {
                guard self.webSocket === task else { return }
                log("relay network error: \(error.localizedDescription)")
                self.reconnectIfCurrent(self.generation)
            }
        }
    }
}

let bridge = Bridge()
bridge.start()
dispatchMain()
