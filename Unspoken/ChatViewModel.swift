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
    @Published var peerLubTick: Int = 0
    @Published var peerDubTick: Int = 0
    @Published var isReconnecting: Bool = false

    private var socket: StarscreamWebSocket?
    var healthStore: HKHealthStore?
    var heartRateTimer: Timer?
    var hapticLoopActive = false
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
    var reconnectTimer: Timer?
    var reconnectAttempts: Int = 0
    var isUserLeft: Bool = false
    var didEnterBackground: Bool = false
    private var pathMonitor: NWPathMonitor?
    var isSocketConnected: Bool = false
    var didShowDisconnectMessage: Bool = false

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
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didEnterBackground = true
            self?.beginHeartRateBackgroundTaskIfNeeded()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endHeartRateBackgroundTask()
            guard let self, self.isChatOpen, !self.isUserLeft, self.didEnterBackground else { return }
            self.didEnterBackground = false
            self.reconnectAttempts = 0
            self.scheduleReconnect()
        }
    }

    private func setupNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, self.isChatOpen, !self.isUserLeft else { return }
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
        guard isChatOpen, !isUserLeft else { return }
        if !isReconnecting && !didShowDisconnectMessage {
            didShowDisconnectMessage = true
            addSystemMessage("Connection lost. Reconnecting...")
        }
        reconnectTimer?.invalidate()
        let delay = min(pow(2.0, Double(reconnectAttempts)), 15.0)
        reconnectAttempts = min(reconnectAttempts + 1, 4)
        isReconnecting = true
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isChatOpen, !self.isUserLeft else { return }
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
        reconnectAttempts = 0
        pendingAction = { [weak self] in
            self?.sendLogin()
            self?.sendJSON(["action": "create_room", "user_id": self?.userId as Any])
        }
    }

    func joinRoom() {
        isUserLeft = false
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

    func leaveRoom() {
        isUserLeft = true
        reconnectTimer?.invalidate()
        isReconnecting = false
        stopHeartRateMode()
        stopPeerHeartRate()
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
            if let imageData = msg.imageData {
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
        } else if !msg.content.isEmpty {
            return .text(String(msg.content.prefix(80)))
        }
        return nil
    }
}
