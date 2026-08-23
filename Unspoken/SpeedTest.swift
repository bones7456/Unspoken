//
//  SpeedTest.swift
//  Unspoken
//
//  Connection check for the room-selection screen: it rehearses a whole conversation
//  against the server — text messages and a photo, both directions — and turns the
//  measurements into a verdict a non-technical user can act on.
//
//  It runs on its own WebSocket so nothing here can disturb a live chat, and it speaks
//  only the `speedtest` action, which touches no room, no key and no storage server-side.
//

import Foundation
import Starscream

// MARK: - Result

/// One finished run. Raw measurements only — every sentence the result screen shows is
/// derived from these here, so the wording and the numbers can never drift apart.
struct SpeedTestReport {
    var connectMs: Double
    var latencyMs: Double        // median round trip of a text-sized message
    var latencyBestMs: Double
    var jitterMs: Double         // slowest minus fastest round trip
    var uploadKBps: Double
    var downloadKBps: Double
    var bytesTransferred: Int

    /// What one photo costs on the wire: ~400 KB of JPEG (the app caps images at 1200 px,
    /// quality 0.6) grows by a third in base64 before it is encrypted and sent.
    static let photoWireKB: Double = 540
    /// What one second of speech costs on the wire: 32 kbps AAC (4 KB/s), plus a third for base64.
    static let voiceWireKBPerSecond: Double = 5.4
    /// The length the voice-message estimate is quoted for.
    static let voiceSampleSeconds: Double = 20

    static let empty = SpeedTestReport(connectMs: 0, latencyMs: 0, latencyBestMs: 0, jitterMs: 0,
                                       uploadKBps: 0, downloadKBps: 0, bytesTransferred: 0)

    enum Grade: Int, Comparable {
        case poor = 0, fair, good, excellent

        static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .excellent: return "Excellent"
            case .good:      return "Good"
            case .fair:      return "Usable"
            case .poor:      return "Poor"
            }
        }
    }

    var latencyGrade: Grade {
        switch latencyMs {
        case ..<150:  return .excellent
        case ..<300:  return .good
        case ..<700:  return .fair
        default:      return .poor
        }
    }

    var speedGrade: Grade {
        // Graded on the slower of the two directions: sending a photo is the painful half.
        switch min(uploadKBps, downloadKBps) {
        case 500...:  return .excellent
        case 150...:  return .good
        case 40...:   return .fair
        default:      return .poor
        }
    }

    /// Voice messages are far lighter than photos, so the same link can be fine for one and
    /// painful for the other. Graded against the length of the message itself: 1.0 would mean
    /// sending takes as long as speaking did.
    var voiceGrade: Grade {
        guard uploadKBps > 0 else { return .poor }
        switch voiceSendSeconds / SpeedTestReport.voiceSampleSeconds {
        case ..<0.1:  return .excellent
        case ..<0.25: return .good
        case ..<1:    return .fair
        default:      return .poor
        }
    }

    /// The connection is only as good as its weakest part — that is what the user will feel.
    /// Voice is left out: it is derived from the same upload speed and never the binding limit.
    var grade: Grade { min(latencyGrade, speedGrade) }

    var headline: String {
        switch grade {
        case .excellent: return "Everything will feel instant"
        case .good:      return "Good enough for everything"
        case .fair:      return "Fine for chatting, slow for photos"
        case .poor:      return "This connection will feel sluggish"
        }
    }

    var photoSendSeconds: Double { uploadKBps > 0 ? SpeedTestReport.photoWireKB / uploadKBps : 0 }
    var photoReceiveSeconds: Double { downloadKBps > 0 ? SpeedTestReport.photoWireKB / downloadKBps : 0 }
    /// How long sending a `voiceSampleSeconds`-long voice message takes on this link.
    var voiceSendSeconds: Double {
        guard uploadKBps > 0 else { return 0 }
        return SpeedTestReport.voiceSampleSeconds * SpeedTestReport.voiceWireKBPerSecond / uploadKBps
    }

    /// The conclusion, one plain sentence per thing the user actually does in the app.
    var plainFindings: [(icon: String, text: String, grade: Grade)] {
        var out: [(icon: String, text: String, grade: Grade)] = []

        let seconds = latencyMs / 1000
        let feel: String
        switch latencyGrade {
        case .excellent: feel = "you won't notice any delay"
        case .good:      feel = "barely noticeable"
        case .fair:      feel = "you'll see a short pause"
        case .poor:      feel = "expect a real wait after each send"
        }
        out.append(("bubble.left.and.bubble.right.fill",
                    "Text messages arrive in about \(formatSeconds(seconds)) — \(feel).",
                    latencyGrade))

        if uploadKBps > 0 && downloadKBps > 0 {
            out.append(("photo.fill",
                        "A photo takes about \(formatSeconds(photoSendSeconds)) to send "
                        + "and \(formatSeconds(photoReceiveSeconds)) to receive.",
                        speedGrade))
        }

        if uploadKBps > 0 {
            out.append(("mic.fill",
                        "A \(Int(SpeedTestReport.voiceSampleSeconds))-second voice message "
                        + "takes about \(formatSeconds(voiceSendSeconds)) to send.",
                        voiceGrade))
        }

        return out
    }

    /// The same run in numbers, for whoever wants them.
    var detailRows: [(String, String)] {
        [
            ("Round trip", "\(Int(latencyMs.rounded())) ms (best \(Int(latencyBestMs.rounded())) ms)"),
            ("Jitter", "\(Int(jitterMs.rounded())) ms"),
            ("Upload", formatRate(uploadKBps)),
            ("Download", formatRate(downloadKBps)),
            ("Connected in", "\(Int(connectMs.rounded())) ms"),
            ("Data used", String(format: "%.1f MB", Double(bytesTransferred) / 1_048_576)),
        ]
    }
}

private func formatSeconds(_ s: Double) -> String {
    if s < 0.1 { return String(format: "%.0f ms", s * 1000) }
    if s < 10 { return String(format: "%.1f s", s) }
    return String(format: "%.0f s", s)
}

private func formatRate(_ kbps: Double) -> String {
    String(format: "%.1f Mbps (%.0f KB/s)", kbps * 8 / 1000, kbps)
}

// MARK: - Runner

/// Drives one run and publishes its progress. Timing happens on a private queue so a busy
/// main thread can't inflate the numbers; only the `@Published` values hop back to main.
final class SpeedTestRunner: ObservableObject, WebSocketDelegate {

    enum Phase: Equatable {
        case idle
        case connecting
        case messages      // text-sized round trips
        case sendingPhoto  // upload burst
        case receivingPhoto
        case done
        case failed

        var caption: String {
            switch self {
            case .idle:           return ""
            case .connecting:     return "Reaching the server…"
            case .messages:       return "Sending test messages…"
            case .sendingPhoto:   return "Sending a test photo…"
            case .receivingPhoto: return "Receiving a test photo…"
            case .done:           return "Done"
            case .failed:         return "Stopped"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0   // 0…1, for the ring
    @Published private(set) var report: SpeedTestReport?
    @Published private(set) var errorMessage: String?

    var isRunning: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    // Test shape: ~2.1 MB and ~8 s at most, less on a slow link (each byte budget is
    // capped by a time budget, so a bad connection finishes early with fewer bytes).
    private let latencySamples = 6
    private let textChars = 96              // a short encrypted text message on the wire
    private let chunkChars = 65_536         // 64 KB, a slice of a photo
    private let burstWindow = 4             // chunks kept in flight
    private let burstBudget: TimeInterval = 3.0
    private let burstMaxBytes = 1_048_576   // 1 MB per direction, whichever comes first
    private let overallTimeout: TimeInterval = 45
    private let firstProbeTimeout: TimeInterval = 8
    private let connectTimeout: TimeInterval = 8

    private let q = DispatchQueue(label: "unspoken.speedtest")
    private var socket: StarscreamWebSocket?
    private var runToken = 0
    private var seq = 0
    private var pending: [Int: (_ rtt: TimeInterval, _ bytesDown: Int) -> Void] = [:]
    private var sentAt: [Int: TimeInterval] = [:]
    private var bytesTransferred = 0
    private var startedAt: TimeInterval = 0
    private var connectMs: Double = 0
    private var userId = ""
    private var publicKeyBase64 = ""
    private var draft = SpeedTestReport.empty

    // MARK: Lifecycle

    /// `host`/`port`/`useSSL` come straight from the fields on the selection screen, so the
    /// test measures exactly the server the user is about to chat through.
    func start(host: String, port: String, useSSL: Bool, userId: String, publicKeyBase64: String?) {
        cancel()
        let scheme = useSSL ? "wss" : "ws"
        guard !host.isEmpty, !port.isEmpty,
              let url = URL(string: "\(scheme)://\(host):\(port)") else {
            publish { self.phase = .failed; self.errorMessage = "That server address doesn't look right." }
            return
        }
        self.userId = userId
        self.publicKeyBase64 = publicKeyBase64 ?? ""

        publish {
            self.phase = .connecting
            self.progress = 0
            self.report = nil
            self.errorMessage = nil
        }

        q.async {
            self.runToken += 1
            let token = self.runToken
            self.seq = 0
            self.pending = [:]
            self.sentAt = [:]
            self.bytesTransferred = 0
            self.startedAt = Self.now()
            self.connectMs = 0
            self.draft = SpeedTestReport.empty

            var request = URLRequest(url: url)
            request.timeoutInterval = self.connectTimeout
            let socket = StarscreamWebSocket(request: request)
            socket.callbackQueue = self.q
            socket.delegate = self
            self.socket = socket
            socket.connect()

            self.q.asyncAfter(deadline: .now() + self.connectTimeout) {
                guard token == self.runToken, self.connectMs == 0 else { return }
                self.fail("Could not reach \(host). Check the address, the port and your network.")
            }
            self.q.asyncAfter(deadline: .now() + self.overallTimeout) {
                guard token == self.runToken else { return }   // a finished run bumps the token
                self.fail("The connection is too slow to finish the test.")
            }
        }
    }

    func cancel() {
        q.async {
            self.runToken += 1
            self.teardown()
            self.connectMs = 0
        }
    }

    private func teardown() {
        socket?.delegate = nil
        socket?.disconnect()
        socket = nil
        pending = [:]
        sentAt = [:]
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func fail(_ message: String) {
        teardown()
        runToken += 1
        publish {
            guard self.report == nil else { return }   // a finished run keeps its result
            self.phase = .failed
            self.errorMessage = message
        }
    }

    // MARK: WebSocket

    func didReceive(event: Starscream.WebSocketEvent, client: any Starscream.WebSocketClient) {
        switch event {
        case .connected:
            connectMs = (Self.now() - startedAt) * 1000
            draft.connectMs = connectMs
            send(["action": "login", "user_id": userId, "public_key": publicKeyBase64,
                  "client_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"])
            runLatency(samples: [])
        case .text(let string):
            handle(string)
        case .disconnected(let reason, _):
            fail(reason.isEmpty ? "The server closed the connection." : "The server closed the connection: \(reason)")
        case .error(let error):
            fail(error.map { "Could not reach the server: \($0.localizedDescription)" }
                 ?? "Could not reach the server.")
        case .cancelled, .peerClosed:
            fail("The connection dropped before the test finished.")
        default:
            break
        }
    }

    private func handle(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch json["action"] as? String {
        case "speedtest_result":
            guard let s = json["seq"] as? Int, let sent = sentAt.removeValue(forKey: s) else { return }
            let down = (json["payload"] as? String)?.count ?? 0
            bytesTransferred += down
            let handler = pending.removeValue(forKey: s)
            handler?(Self.now() - sent, down)
        case "error", "failed", "login_failed", "blocked":
            fail((json["message"] as? String) ?? "The server refused the test.")
        default:
            break
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: text)
    }

    /// Fire one probe and route its answer back. `timeout` failing the whole run is deliberate:
    /// every step here is short enough that a lost probe means the link is unusable anyway.
    private func probe(mode: String, payload: String?, size: Int?, timeout: TimeInterval,
                       timeoutMessage: String? = nil,
                       onReply: @escaping (_ rtt: TimeInterval, _ bytesDown: Int) -> Void,
                       onTimeout: (() -> Void)? = nil) {
        seq += 1
        let s = seq
        let token = runToken
        var msg: [String: Any] = ["action": "speedtest", "seq": s, "mode": mode]
        if let payload { msg["payload"] = payload; bytesTransferred += payload.count }
        if let size { msg["size"] = size }
        pending[s] = onReply
        sentAt[s] = Self.now()
        send(msg)
        q.asyncAfter(deadline: .now() + timeout) {
            guard token == self.runToken, self.pending.removeValue(forKey: s) != nil else { return }
            self.sentAt.removeValue(forKey: s)
            if let onTimeout {
                onTimeout()
            } else {
                self.fail(timeoutMessage ?? "The server stopped answering.")
            }
        }
    }

    /// Random-looking filler, so a link that compresses traffic can't flatter itself.
    private func filler(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: (count / 4 + 1) * 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(Data(bytes).base64EncodedString().prefix(count))
    }

    // MARK: Steps

    /// Step 1 — text messages: sequential round trips, the way typing actually works.
    private func runLatency(samples: [Double]) {
        let token = runToken
        publish { self.phase = .messages; self.progress = 0.05 + 0.2 * Double(samples.count) / Double(self.latencySamples) }
        guard samples.count < latencySamples else { return finishLatency(samples) }
        // The very first probe doubles as the "does this server know about speed tests?" check.
        let isFirst = samples.isEmpty
        probe(mode: "echo", payload: filler(textChars), size: nil,
              timeout: isFirst ? firstProbeTimeout : 5,
              timeoutMessage: isFirst
                ? "This server is running an older version that has no speed test. Ask the server owner to update it."
                : nil,
              onReply: { [weak self] rtt, _ in
                  guard let self, token == self.runToken else { return }
                  var next = samples
                  next.append(rtt * 1000)
                  self.q.asyncAfter(deadline: .now() + 0.06) {
                      guard token == self.runToken else { return }
                      self.runLatency(samples: next)
                  }
              })
    }

    private func finishLatency(_ samples: [Double]) {
        // Drop the first sample: it carries the cost of warming the connection up.
        let useful = samples.count > 1 ? Array(samples.dropFirst()) : samples
        let sorted = useful.sorted()
        guard !sorted.isEmpty else { return fail("The server never answered.") }
        draft.latencyMs = sorted[sorted.count / 2]
        draft.latencyBestMs = sorted.first ?? 0
        draft.jitterMs = (sorted.last ?? 0) - (sorted.first ?? 0)
        runBurst(mode: "upload", phase: .sendingPhoto, progressBase: 0.25) { [weak self] kbps in
            guard let self else { return }
            self.draft.uploadKBps = kbps
            self.runBurst(mode: "download", phase: .receivingPhoto, progressBase: 0.6) { kbps in
                self.draft.downloadKBps = kbps
                self.draft.bytesTransferred = self.bytesTransferred
                self.finishRun()
            }
        }
    }

    /// Steps 2 & 3 — a photo, in both directions: chunks kept in flight until the time or
    /// byte budget runs out, so a fast link finishes early and a slow one still finishes.
    private func runBurst(mode: String, phase: Phase, progressBase: Double,
                          completion: @escaping (Double) -> Void) {
        let token = runToken
        publish { self.phase = phase; self.progress = progressBase }
        let start = Self.now()
        var sentBytes = 0
        var doneBytes = 0
        var inFlight = 0
        var stopped = false
        var lastArrival = start
        // Chunks are pipelined, so only the first one pays the round-trip latency. Timing from
        // its arrival — and not counting it — measures bandwidth instead of bandwidth+ping,
        // which on a fast link would otherwise dominate the short measurement window.
        var firstArrival: TimeInterval?
        var countedBytes = 0
        // Generated once: regenerating per chunk would measure this device's CPU, not the link.
        let payload = mode == "upload" ? filler(chunkChars) : nil

        func refill() {
            guard token == self.runToken else { return }
            while !stopped, inFlight < self.burstWindow, sentBytes < self.burstMaxBytes,
                  Self.now() - start < self.burstBudget {
                inFlight += 1
                sentBytes += self.chunkChars
                self.probe(mode: mode, payload: payload,
                           size: mode == "download" ? self.chunkChars : nil,
                           timeout: 20,
                           timeoutMessage: "The connection is too slow to move a photo.",
                           onReply: { _, _ in
                               guard token == self.runToken else { return }
                               inFlight -= 1
                               doneBytes += self.chunkChars
                               lastArrival = Self.now()
                               if firstArrival == nil { firstArrival = lastArrival } else { countedBytes += self.chunkChars }
                               let elapsed = lastArrival - start
                               if elapsed >= self.burstBudget || sentBytes >= self.burstMaxBytes {
                                   stopped = true
                               }
                               self.publish {
                                   self.progress = progressBase + 0.35 * min(1, elapsed / self.burstBudget)
                               }
                               refill()
                               if inFlight == 0 {
                                   if let first = firstArrival, countedBytes > 0, lastArrival > first {
                                       completion(Double(countedBytes) / 1024 / (lastArrival - first))
                                   } else {
                                       // Only one chunk ever came back: all we have is the round trip.
                                       completion(Double(doneBytes) / 1024 / max(0.001, lastArrival - start))
                                   }
                               }
                           })
            }
        }
        refill()
    }

    private func finishRun() {
        teardown()
        runToken += 1
        let result = draft
        publish {
            self.report = result
            self.phase = .done
            self.progress = 1
        }
    }
}
