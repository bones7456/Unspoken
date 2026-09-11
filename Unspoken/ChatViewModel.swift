//
//  ChatViewModel.swift
//  Unspoken
//

import SwiftUI
import Starscream
import CryptoKit
import LocalAuthentication
import HealthKit
import UIKit
import WatchConnectivity
import Network

typealias StarscreamWebSocket = Starscream.WebSocket

/// Why a room ended. Both cases keep the conversation readable instead of closing the chat.
enum FarewellReason: Equatable {
    case unpinnedByPeer
    case hostClosed

    var systemText: String {
        switch self {
        case .unpinnedByPeer: return "Your peer unpinned this room."
        case .hostClosed:     return "Host has left the room. The room is closed."
        }
    }
}

class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var typingContent: String = ""
    @Published var isChatOpen: Bool = false
    @Published var roomId: String = ""
    @Published var serverAddress: String = "wss://unspoken.luy.li:8765"
    @Published var serverHost: String = "unspoken.luy.li"
    @Published var serverPort: String = "8765"
    @Published var useSSL: Bool = true
    @Published var role: String = ""
    @Published var isPinned: Bool = false
    @Published var peerIsOnline: Bool = false
    @Published var pinRequestPending: Bool = false
    @Published var pinRequestReceived: Bool = false
    @Published var pinnedRoomEntries: [PinnedRoomEntry] = []
    @Published var isPinnedListUnlocked: Bool = false
    @Published var isHeartRateMode: Bool = false
    @Published var currentBPM: Int? = nil
    @Published var peerBPM: Int?
    @Published var heartRateModeError: String?
    @Published var isTalking: Bool = false        // self is recording a voice message
    @Published var voiceError: String?            // mic denied etc., surfaced as an alert
    /// Language used to transcribe voice messages (iOS 26+). nil until first resolved — the
    /// engine's locale list is async, so it can't be settled in init. See ChatViewModel+Transcript.
    @Published var transcriptLocale: Locale?
    /// Populated the first time the language picker is opened.
    @Published var availableTranscriptLocales: [Locale] = []
    @Published var peerLubTick: Int = 0
    @Published var peerDubTick: Int = 0
    @Published var isReconnecting: Bool = false
    /// When a pinned-room chat is sent to the background, the chat UI is hidden (the login
    /// screen is shown in its place, including in the app-switcher snapshot) while all
    /// in-memory state — messages, peer keys, room metadata — is preserved. Face ID restores it.
    @Published var isLocked: Bool = false
    /// Non-nil once the room has ended. The conversation stays on screen, read-only, until the
    /// user closes it — see enterFarewell(). Nothing can be sent in this state.
    @Published var farewell: FarewellReason?
    /// Still pulling the last queued messages out of the server before the room is closed.
    @Published var farewellDraining: Bool = false
    /// Server-side destruction deadline of a room unpinned with grace (nil = already gone).
    @Published var farewellGraceUntil: Date?
    /// A rejoin the server refused because the room no longer exists; shown on the selection screen.
    @Published var joinError: String?

    var isFarewell: Bool { farewell != nil }

    private var socket: StarscreamWebSocket?
    private var farewellDrainTimer: Timer?
    var healthStore: HKHealthStore?
    var heartRateTimer: Timer?
    var hapticLoopActive = false
    var transcriptTasks: [UUID: Task<Void, Never>] = [:]
    var hkObserverQuery: HKObserverQuery?
    let userId: String = {
        let key = "stableUserId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let new = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    var privateKey: SecKey?
    var publicKey: SecKey?
    var peerPublicKey: SecKey?
    var peerUserId: String?

    var pendingAction: (() -> Void)?
    var wcAdapter: WCAdapter?
    var heartRateBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var nextSeq: Int = 1
    // Voice: shared bubble player (observed by MessageView) + push-to-talk capture.
    let voiceMessagePlayer = VoiceMessagePlayer()
    private let voiceCapture = VoiceCapture()
    private var talkRequested: Bool = false       // button held; guards the async mic-permission race
    var reconnectTimer: Timer?
    var reconnectAttempts: Int = 0
    var isUserLeft: Bool = false
    var didEnterBackground: Bool = false
    private var pathMonitor: NWPathMonitor?
    var isSocketConnected: Bool = false
    var didShowDisconnectMessage: Bool = false
    // Set while reading the clipboard: the iOS 16+ "Allow Paste" alert briefly resigns active,
    // which must NOT trigger the pinned-room privacy auto-lock (that would unmount the chat and
    // tear down the image-confirm sheet). A genuine background still locks (see didEnterBackground).
    private var suppressPasteLock: Bool = false

    init() {
        if loadKeyPair() {
            print("my userId:\(self.userId), Restored saved key pair.")
        } else {
            generateKeyPair()
            print("my userId:\(self.userId), Key pair generated.")
        }
        migrateLegacyPinnedRoomIfNeeded()
        self.serverAddress = "wss://\(serverHost):\(serverPort)"
        setupWatchConnectivity()
        setupBackgroundTaskObservers()
        setupNetworkMonitor()
    }

    private func setupBackgroundTaskObservers() {
        // willResignActive fires before iOS captures the app-switcher snapshot, so hiding the
        // chat here keeps the conversation out of that snapshot.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Skip the lock for the transient resign-active caused by the system paste alert.
            if self.suppressPasteLock { return }
            self.lockPinnedRoomForPrivacy()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.didEnterBackground = true
            // A genuine background while a paste prompt suppressed the resign-active lock: lock
            // now so the Face ID gate still holds (snapshot of the messages stays covered by
            // ScreenshotProtected meanwhile).
            if self.suppressPasteLock {
                self.suppressPasteLock = false
                self.lockPinnedRoomForPrivacy()
            }
            self.beginHeartRateBackgroundTaskIfNeeded()
            // A locked pinned session that genuinely backgrounded: drop the live connection so
            // it can only be resumed via Face ID.
            if self.isLocked {
                self.disconnectLockedSession()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endHeartRateBackgroundTask()
            guard let self else { return }
            // The paste alert (if any) is gone; stop suppressing the privacy lock.
            self.suppressPasteLock = false
            if self.isLocked {
                // If we only briefly resigned active (Control Center, a banner) without actually
                // backgrounding, the socket is still alive — restore silently, no Face ID needed.
                // Otherwise stay locked and wait for the user to double-tap + Face ID.
                if !self.didEnterBackground {
                    self.isLocked = false
                }
                self.didEnterBackground = false
                return
            }
            guard self.isChatOpen, !self.isUserLeft, self.didEnterBackground else { return }
            self.didEnterBackground = false
            self.reconnectAttempts = 0
            self.scheduleReconnect()
        }
    }

    /// Privacy guard: when a pinned-room chat resigns active, hide the chat UI (the login screen
    /// is shown in its place) and re-lock the pinned list so no room metadata leaks into the
    /// app-switcher snapshot. All in-memory state is preserved for a later Face ID restore.
    /// Non-pinned rooms keep the existing reconnect-on-foreground behavior.
    private func lockPinnedRoomForPrivacy() {
        guard isChatOpen, isPinned, !isUserLeft, !isLocked else { return }
        isLocked = true
        isPinnedListUnlocked = false
        pinnedRoomEntries = []
    }

    /// Call right before reading `UIPasteboard` so the resulting "Allow Paste" alert's transient
    /// resign-active doesn't trip the pinned-room privacy lock. Cleared on didBecomeActive, on a
    /// genuine background, or via `endSystemPasteboardAccess()` when the paste flow is abandoned.
    func beginSystemPasteboardAccess() { suppressPasteLock = true }

    func endSystemPasteboardAccess() { suppressPasteLock = false }

    /// Tear down the live connection for a locked pinned session without touching the preserved
    /// conversation state (messages, peer keys, room metadata).
    private func disconnectLockedSession() {
        stopHeartRateMode(notifyPeer: false)
        stopPeerHeartRate()
        reconnectTimer?.invalidate()
        isReconnecting = false
        socket?.delegate = nil
        socket?.disconnect()
        isSocketConnected = false
    }

    /// Resume a locked pinned session after Face ID: reconnect and rejoin while keeping the
    /// already-loaded messages on screen.
    func restoreLockedSession() {
        isLocked = false
        didEnterBackground = false
        reconnectAttempts = 0
        joinRoom()
        setupWebSocket()
    }

    private func setupNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, self.isChatOpen, !self.isUserLeft, !self.isLocked else { return }
                if path.status == .satisfied {
                    if self.isReconnecting {
                        self.reconnectAttempts = 0
                        self.scheduleReconnect()
                    } else if !self.isSocketConnected {
                        self.scheduleReconnect()
                    }
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - WebSocket Setup

    func setupWebSocket() {
        socket?.delegate = nil
        socket?.disconnect()
        guard let url = URL(string: serverAddress) else {
            print("Invalid server address: \(serverAddress)")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        socket = StarscreamWebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }

    func scheduleReconnect() {
        guard isChatOpen, !isUserLeft, !isLocked else { return }
        if !isReconnecting && !didShowDisconnectMessage {
            didShowDisconnectMessage = true
            addSystemMessage("Connection lost. Reconnecting...")
        }
        reconnectTimer?.invalidate()
        let delay = min(pow(2.0, Double(reconnectAttempts)), 15.0)
        reconnectAttempts = min(reconnectAttempts + 1, 4)
        isReconnecting = true
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isChatOpen, !self.isUserLeft, !self.isLocked else { return }
            self.joinRoom()
            self.setupWebSocket()
        }
    }

    func addSystemMessage(_ text: String) {
        messages.append(Message(content: text, isFromMe: false, isTyping: false, isSystem: true))
    }

    // MARK: - Room Actions

    func sendLogin() {
        guard let publicKey = publicKey else { return }
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("Failed to get public key data: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return
        }
        let publicKeyBase64 = publicKeyData.base64EncodedString()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        sendJSON(["action": "login", "user_id": userId, "public_key": publicKeyBase64, "client_version": version])
    }

    func createRoom() {
        isUserLeft = false
        isLocked = false
        reconnectAttempts = 0
        pendingAction = { [weak self] in
            self?.sendLogin()
            self?.sendJSON(["action": "create_room", "user_id": self?.userId as Any])
        }
    }

    func joinRoom() {
        isUserLeft = false
        isLocked = false
        pendingAction = { [weak self] in
            self?.sendLogin()
            var msg: [String: Any] = [
                "action": "join_room",
                "room_id": self?.roomId as Any,
                "user_id": self?.userId as Any
            ]
            if let pubKey = self?.getPublicKeyBase64() {
                msg["public_key"] = pubKey
            }
            self?.sendJSON(msg)
        }
    }

    // MARK: - Farewell (the room ended, but its messages stay readable)

    /// Put the session into read-only farewell mode: the conversation stays on screen until the
    /// user closes it, but nothing can be sent any more.
    ///
    /// `roomAlive` marks a room that was unpinned *with grace*: it still exists server-side, so
    /// the connection is kept — queued messages may still be draining, and a Face ID restore can
    /// rejoin it. Otherwise the room is already gone and every reconnect path is frozen instead.
    /// `graceUntil` is that room's destruction deadline, shown to the user.
    func enterFarewell(_ reason: FarewellReason, roomAlive: Bool = false, graceUntil: Date? = nil, draining: Bool = false) {
        let firstEntry = (farewell == nil)
        farewell = reason
        farewellGraceUntil = graceUntil
        farewellDraining = draining

        // Close the sending gate. Receiving still works — decryption uses our own private key.
        peerPublicKey = nil
        peerIsOnline = false
        typingContent = ""
        stopHeartRateMode(notifyPeer: false)
        stopPeerHeartRate()
        abortVoiceCapture()

        if !roomAlive {
            // Nothing left on the server: stop reconnecting, rejoining and draining.
            isUserLeft = true
            reconnectTimer?.invalidate()
            isReconnecting = false
            socket?.delegate = nil
            socket?.disconnect()
            isSocketConnected = false
            farewellDraining = false
            messages.removeAll { $0.isPendingPlaceholder }
        }

        if firstEntry { addSystemMessage(reason.systemText) }
        if farewellDraining { scheduleFarewellDrainTimeout() } else { farewellDrainTimer?.invalidate() }
    }

    /// Called for every queued message delivered while draining. `remaining == 0` ends the drain.
    func noteFarewellDrainProgress(remaining: Int) {
        guard farewellDraining else { return }
        if remaining <= 0 { finishFarewellDrain() } else { scheduleFarewellDrainTimeout() }
    }

    /// A queued message that fails to decrypt is never acked, which stalls the stop-and-wait
    /// queue — never let "delivering the last messages" hang on that.
    private func scheduleFarewellDrainTimeout() {
        farewellDrainTimer?.invalidate()
        farewellDrainTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.finishFarewellDrain()
        }
    }

    private func finishFarewellDrain() {
        guard farewellDraining else { return }
        farewellDrainTimer?.invalidate()
        farewellDraining = false
        messages.removeAll { $0.isPendingPlaceholder }
    }

    /// The farewell screen's Close button: destroy the room everywhere, then wipe the session.
    func dismissFarewell() {
        if isPinned {
            // No 'grace' flag: the last reader is done, so destroy it server-side right now.
            sendJSON(["action": "unpin_room", "room_id": roomId, "role": role])
            clearPinnedRoom()
        }
        leaveRoom()
    }

    func leaveRoom() {
        isUserLeft = true
        isLocked = false
        farewell = nil
        farewellDraining = false
        farewellGraceUntil = nil
        farewellDrainTimer?.invalidate()
        reconnectTimer?.invalidate()
        isReconnecting = false
        stopHeartRateMode()
        stopPeerHeartRate()
        abortVoiceCapture()
        voiceMessagePlayer.stop()
        cancelAllTranscriptions()
        sendJSON(["action": "leave_room", "room_id": roomId, "role": role, "user_id": userId])

        // Clear all room state BEFORE flipping isChatOpen, so the parent view
        // never observes a transient (!isChatOpen && !messages.isEmpty) frame
        // that could leave a SwiftUI alert orphaned.
        messages = []
        typingContent = ""
        peerPublicKey = nil
        peerUserId = nil
        roomId = ""
        role = ""
        isPinned = false
        peerIsOnline = false
        pinRequestPending = false
        pinRequestReceived = false
        isChatOpen = false
    }

    func updateServerAddress(address: String, port: String) {
        self.serverHost = address
        self.serverPort = port
        let scheme = useSSL ? "wss" : "ws"
        self.serverAddress = "\(scheme)://\(address):\(port)"
        print("Server set to \(serverAddress)")
        setupWebSocket()
    }

    func reportUser() {
        guard let peerUserId = peerUserId else { return }
        sendJSON(["action": "report_user", "reported_user_id": peerUserId])
        if isPinned {
            unpinRoom()
        } else {
            leaveRoom()
        }
    }

    // MARK: - Messaging

    func sendTyping(content: String) {
        if isPinned && !peerIsOnline { return }
        guard let (encryptedAESKey, encryptedContent) = encryptMessage(content) else { return }
        sendJSON([
            "action": "typing",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encryptedAESKey,
            "encrypted_content": encryptedContent
        ])
    }

    func sendMessage(content: String, quotedMessage: Message? = nil) {
        let seq = nextSeq; nextSeq += 1
        let quote: QuoteContent? = quotedMessage.flatMap { makeQuoteContent(from: $0) }
        let payload = wrapPayload(type: "text", data: content, quote: quote)
        guard let (encryptedAESKey, encryptedContent) = encryptMessage(payload) else { return }
        sendJSON([
            "action": "send_message",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encryptedAESKey,
            "encrypted_content": encryptedContent,
            "seq": seq
        ])
        messages.append(Message(content: content, isFromMe: true, isTyping: false, seq: seq, quote: quote))
    }

    func sendImage(_ imageData: Data, quotedMessage: Message? = nil) {
        guard peerPublicKey != nil else { return }
        guard imageData.count < 5 * 1024 * 1024 else {
            DispatchQueue.main.async {
                self.messages.append(Message(content: "Image too large to send (max ~5 MB).", isFromMe: false, isTyping: false, isSystem: true))
            }
            return
        }
        let seq = nextSeq; nextSeq += 1
        let quote: QuoteContent? = quotedMessage.flatMap { makeQuoteContent(from: $0) }
        let base64 = imageData.base64EncodedString()
        let payload = wrapPayload(type: "image", data: base64, quote: quote)
        guard let encrypted = encryptMessage(payload) else { return }
        sendJSON([
            "action": "send_message",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encrypted.0,
            "encrypted_content": encrypted.1,
            "seq": seq
        ])
        messages.append(Message(content: "", isFromMe: true, isTyping: false, imageData: imageData, seq: seq, quote: quote))
    }

    // MARK: - Voice (push-to-talk voice messages)

    /// Push-to-talk pressed: record the whole hold into one voice message, sent on release.
    /// Only started when the result can actually be delivered — live to an online peer, or
    /// queued for an offline one in a pinned room.
    func startTalking() {
        guard peerPublicKey != nil, !isTalking, !talkRequested else { return }
        guard peerIsOnline || isPinned else { return }   // non-pinned + peer offline: nowhere to go

        talkRequested = true
        voiceCapture.onFileComplete = { [weak self] data, dur in self?.sendVoiceMessage(data, duration: dur) }
        voiceCapture.start { [weak self] ok in
            guard let self else { return }
            // Button was released before the mic became ready — tear down without emitting.
            guard self.talkRequested else {
                self.voiceCapture.onFileComplete = nil
                self.voiceCapture.stop { }
                return
            }
            if ok {
                self.isTalking = true
            } else {
                self.talkRequested = false
                self.voiceError = "Microphone access is needed to send voice. Enable it in Settings."
            }
        }
    }

    /// Push-to-talk released. The recording is flushed and `sendVoiceMessage` appends its bubble.
    func stopTalking() {
        // A start may still be pending its permission callback; cancelling the request makes
        // that callback tear the capture down instead of going live.
        guard isTalking else { talkRequested = false; return }
        talkRequested = false
        isTalking = false
        voiceCapture.stop { }
    }

    /// One voice message. Goes through send_message like an image: relayed straight to an online
    /// peer, or queued by the server (pinned room) and delivered when the peer comes back.
    func sendVoiceMessage(_ data: Data, duration: TimeInterval) {
        guard peerPublicKey != nil else { return }
        guard data.count < 5 * 1024 * 1024 else {
            self.messages.append(Message(content: "Voice message too large to send (max ~5 MB).", isFromMe: false, isTyping: false, isSystem: true))
            return
        }
        let seq = nextSeq; nextSeq += 1
        let payload = wrapPayload(type: "audio", data: data.base64EncodedString())
        guard let enc = encryptMessage(payload) else { return }
        sendJSON([
            "action": "send_message",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": enc.0,
            "encrypted_content": enc.1,
            "seq": seq
        ])
        messages.append(Message(content: "", isFromMe: true, isTyping: false, audioData: data, audioDuration: duration, seq: seq))
    }

    /// Tear down an in-progress capture without emitting the recording (used when leaving the
    /// room or losing the peer mid-hold, where there is no longer anywhere to send it).
    func abortVoiceCapture() {
        talkRequested = false
        guard isTalking else { return }
        isTalking = false
        voiceCapture.onFileComplete = nil
        voiceCapture.stop { }
    }

    func sendJSON(_ dictionary: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dictionary, options: [])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
                socket?.write(string: jsonString)
            }
        } catch {
            print("Error encoding JSON: \(error)")
        }
    }

    func retryPendingMessages() {
        let pending = messages.filter {
            $0.isFromMe && !$0.isAcked && !$0.isSystem && !$0.isTyping && !$0.isPendingPlaceholder && $0.seq != nil
        }
        guard !pending.isEmpty, peerPublicKey != nil else { return }
        for msg in pending {
            if let audioData = msg.audioData {
                let payload = wrapPayload(type: "audio", data: audioData.base64EncodedString(), quote: msg.quote)
                guard let encrypted = encryptMessage(payload) else { continue }
                sendJSON([
                    "action": "send_message",
                    "room_id": roomId,
                    "role": role,
                    "encrypted_aes_key": encrypted.0,
                    "encrypted_content": encrypted.1,
                    "seq": msg.seq!
                ])
            } else if let imageData = msg.imageData {
                let payload = wrapPayload(type: "image", data: imageData.base64EncodedString(), quote: msg.quote)
                guard let encrypted = encryptMessage(payload) else { continue }
                sendJSON([
                    "action": "send_message",
                    "room_id": roomId,
                    "role": role,
                    "encrypted_aes_key": encrypted.0,
                    "encrypted_content": encrypted.1,
                    "seq": msg.seq!
                ])
            } else {
                let payload = wrapPayload(type: "text", data: msg.content, quote: msg.quote)
                guard let (encryptedAESKey, encryptedContent) = encryptMessage(payload) else { continue }
                sendJSON([
                    "action": "send_message",
                    "room_id": roomId,
                    "role": role,
                    "encrypted_aes_key": encryptedAESKey,
                    "encrypted_content": encryptedContent,
                    "seq": msg.seq!
                ])
            }
        }
    }

    // Build a QuoteContent from the message being quoted.
    // Only uses the top-level content (ignores any nested quote) to prevent nesting.
    private func makeQuoteContent(from msg: Message) -> QuoteContent? {
        if let imgData = msg.imageData {
            let thumb = makeQuoteThumbnail(imgData) ?? imgData
            return .image(thumb)
        } else if msg.audioData != nil {
            return .audio(msg.audioDuration ?? 0)
        } else if !msg.content.isEmpty {
            return .text(String(msg.content.prefix(80)))
        }
        return nil
    }
}
