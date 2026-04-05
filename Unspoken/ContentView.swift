//
//  ContentView.swift
//  Unspoken
//
//  Created by Luyang Li on 11/8/24.
//

import SwiftUI
import Starscream
import CryptoKit
import LocalAuthentication
import HealthKit
import UIKit
import WatchConnectivity
import ImageIO

class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var typingContent: String = ""
    @Published var isChatOpen: Bool = false
    @Published var roomId: String = ""
    @Published var serverAddress: String = "wss://unspoken.luy.li:8765"
    @Published var serverHost: String = "unspoken.luy.li"
    @Published var serverPort: String = "8765"
    #if DEBUG
    @Published var useSSL: Bool = true
    #endif
    @Published var role: String = ""
    @Published var isPinned: Bool = false
    @Published var peerIsOnline: Bool = false
    @Published var pinRequestPending: Bool = false
    @Published var pinRequestReceived: Bool = false
    @Published var isHeartRateMode: Bool = false
    @Published var currentBPM: Int? = nil
    @Published var peerBPM: Int?
    @Published var heartRateModeError: String?
    @Published var peerLubTick: Int = 0
    @Published var peerDubTick: Int = 0

    private var socket: WebSocket?
    private var healthStore: HKHealthStore?
    private var heartRateTimer: Timer?
    private var hapticLoopActive = false
    private var hkObserverQuery: HKObserverQuery?
    private let userId: String = {
        let key = "stableUserId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let new = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    private var privateKey: SecKey?
    private var publicKey: SecKey?
    var peerPublicKey: SecKey?
    private var peerUserId: String?

    private var pendingAction: (() -> Void)?
    private var wcAdapter: WCAdapter?
    private var heartRateBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var nextSeq: Int = 1
    private var reconnectTimer: Timer?
    private var reconnectAttempts: Int = 0
    private var isUserLeft: Bool = false
    @Published var isReconnecting: Bool = false

    // MARK: - UserDefaults keys for pin persistence
    private let kPinnedRoomId = "pinnedRoomId"
    private let kPinnedRole = "pinnedRole"
    private let kPinnedServerHost = "pinnedServerHost"
    private let kPinnedServerPort = "pinnedServerPort"
    private let kPinnedPeerPublicKey = "pinnedPeerPublicKey"
    private let kPinnedPeerUserId = "pinnedPeerUserId"
    private let kSavedPrivateKey = "savedPrivateKey"
    private let kSavedPublicKey = "savedPublicKey"

    init() {
        if loadKeyPair() {
            print("my userId:\(self.userId), Restored saved key pair.")
        } else {
            generateKeyPair()
            print("my userId:\(self.userId), Key pair generated.")
        }
        self.serverAddress = "wss://\(serverHost):\(serverPort)"
        setupWatchConnectivity()
        setupBackgroundTaskObservers()
    }

    private func setupBackgroundTaskObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.beginHeartRateBackgroundTaskIfNeeded()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endHeartRateBackgroundTask()
            // Reconnect if we're in a room — the connection may have dropped in background
            guard let self, self.isChatOpen, !self.isUserLeft else { return }
            self.reconnectAttempts = 0
            self.scheduleReconnect()
        }
    }

    private func beginHeartRateBackgroundTaskIfNeeded() {
        guard isHeartRateMode, heartRateBackgroundTask == .invalid else { return }
        heartRateBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HeartRateTransmission") { [weak self] in
            // 系统到期时优雅停止
            self?.stopHeartRateMode(notifyPeer: true)
            self?.endHeartRateBackgroundTask()
        }
    }

    private func endHeartRateBackgroundTask() {
        guard heartRateBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(heartRateBackgroundTask)
        heartRateBackgroundTask = .invalid
    }

    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        let adapter = WCAdapter { [weak self] bpm in
            DispatchQueue.main.async { self?.currentBPM = bpm }
        }
        self.wcAdapter = adapter
        WCSession.default.delegate = adapter
        WCSession.default.activate()
    }

    /// Whether there is a saved pinned room in UserDefaults (checked without loading keys)
    var hasSavedPinnedRoom: Bool {
        guard let saved = UserDefaults.standard.string(forKey: kPinnedRoomId) else { return false }
        return !saved.isEmpty
    }

    /// Authenticate with Face ID / Touch ID, then load pinned room data
    func unlockPinnedRoom() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            print("Biometrics unavailable: \(error?.localizedDescription ?? "Unknown")")
            _ = loadPinnedRoom()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock your pinned room") { success, authError in
            DispatchQueue.main.async {
                if success {
                    if self.loadPinnedRoom() {
                        print("Pinned room unlocked via biometrics: \(self.roomId)")
                    }
                } else {
                    print("Biometric auth failed: \(authError?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }

    // MARK: - Key Persistence

    private func saveKeyPair() {
        guard let privateKey = privateKey, let publicKey = publicKey else { return }
        var error: Unmanaged<CFError>?
        if let privData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? {
            UserDefaults.standard.set(privData, forKey: kSavedPrivateKey)
        }
        if let pubData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? {
            UserDefaults.standard.set(pubData, forKey: kSavedPublicKey)
        }
    }

    private func loadKeyPair() -> Bool {
        guard let privData = UserDefaults.standard.data(forKey: kSavedPrivateKey),
              let pubData = UserDefaults.standard.data(forKey: kSavedPublicKey) else { return false }

        let privAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        let pubAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateWithData(privData as CFData, privAttrs as CFDictionary, &error) else {
            print("Failed to restore private key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
            return false
        }
        guard let pubKey = SecKeyCreateWithData(pubData as CFData, pubAttrs as CFDictionary, &error) else {
            print("Failed to restore public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
            return false
        }

        self.privateKey = privKey
        self.publicKey = pubKey
        return true
    }

    func savePinnedRoom() {
        let defaults = UserDefaults.standard
        defaults.set(roomId, forKey: kPinnedRoomId)
        defaults.set(role, forKey: kPinnedRole)
        defaults.set(serverHost, forKey: kPinnedServerHost)
        defaults.set(serverPort, forKey: kPinnedServerPort)
        defaults.set(peerUserId, forKey: kPinnedPeerUserId)
        // Save peer public key as Data
        if let peerPubKey = peerPublicKey {
            var error: Unmanaged<CFError>?
            if let peerData = SecKeyCopyExternalRepresentation(peerPubKey, &error) as Data? {
                defaults.set(peerData, forKey: kPinnedPeerPublicKey)
            }
        }
        saveKeyPair()
    }

    func loadPinnedRoom() -> Bool {
        let defaults = UserDefaults.standard
        guard let savedRoomId = defaults.string(forKey: kPinnedRoomId),
              let savedRole = defaults.string(forKey: kPinnedRole),
              let savedHost = defaults.string(forKey: kPinnedServerHost),
              let savedPort = defaults.string(forKey: kPinnedServerPort),
              !savedRoomId.isEmpty else { return false }

        guard loadKeyPair() else { return false }

        self.roomId = savedRoomId
        self.role = savedRole
        self.serverHost = savedHost
        self.serverPort = savedPort
        self.isPinned = true

        if let peerUid = defaults.string(forKey: kPinnedPeerUserId) {
            self.peerUserId = peerUid
        }
        if let peerPubData = defaults.data(forKey: kPinnedPeerPublicKey) {
            var error: Unmanaged<CFError>?
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            if let peerKey = SecKeyCreateWithData(peerPubData as CFData, attrs as CFDictionary, &error) {
                self.peerPublicKey = peerKey
            }
        }
        return true
    }

    func clearPinnedRoom() {
        let defaults = UserDefaults.standard
        for key in [kPinnedRoomId, kPinnedRole, kPinnedServerHost, kPinnedServerPort,
                    kPinnedPeerPublicKey, kPinnedPeerUserId, kSavedPrivateKey, kSavedPublicKey] {
            defaults.removeObject(forKey: key)
        }
        isPinned = false
        pinRequestPending = false
        pinRequestReceived = false
        peerIsOnline = false
    }

    // MARK: - Public Key Helper

    func getPublicKeyBase64() -> String? {
        guard let publicKey = publicKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { return nil }
        return publicKeyData.base64EncodedString()
    }

    // MARK: - WebSocket Setup

    private func setupWebSocket() {
        // Detach delegate before disconnecting so the old socket's .disconnected
        // event doesn't trigger scheduleReconnect() during an intentional reconnect.
        socket?.delegate = nil
        socket?.disconnect()

        let url = URL(string: serverAddress)!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }

    private func scheduleReconnect() {
        guard isChatOpen, !isUserLeft else { return }
        reconnectTimer?.invalidate()
        let delay = min(pow(2.0, Double(reconnectAttempts)), 15.0) // 1,2,4,8,15s
        reconnectAttempts = min(reconnectAttempts + 1, 4)
        isReconnecting = true
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isChatOpen, !self.isUserLeft else { return }
            self.joinRoom()
            self.setupWebSocket()
        }
    }

    func sendLogin() {
        guard let publicKey = publicKey else { return }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("Failed to get public key data: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return
        }

        let publicKeyBase64 = publicKeyData.base64EncodedString()
        let message = ["action": "login", "user_id": userId, "public_key": publicKeyBase64]
        sendJSON(message)
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
            // Include public key for pinned room rejoin
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
        if isPinned {
            // Pinned: send leave, hide rejoin card until Face ID unlock
            let message: [String: Any] = ["action": "leave_room", "room_id": roomId, "role": role, "user_id": userId]
            sendJSON(message)
            isChatOpen = false
            isPinned = false
            peerIsOnline = false
            roomId = ""
            role = ""
            messages = []
            typingContent = ""
            pinRequestPending = false
            pinRequestReceived = false
        } else {
            let message: [String: Any] = ["action": "leave_room", "room_id": roomId, "role": role, "user_id": userId]
            sendJSON(message)
            isChatOpen = false
            roomId = ""
            role = ""
            messages = []
            typingContent = ""
            peerPublicKey = nil
            peerUserId = nil
            pinRequestPending = false
            pinRequestReceived = false
        }
    }

    // MARK: - Pin Actions

    func requestPin() {
        let message: [String: Any] = ["action": "request_pin", "room_id": roomId, "role": role]
        sendJSON(message)
        pinRequestPending = true
    }

    func acceptPin() {
        let message: [String: Any] = ["action": "accept_pin", "room_id": roomId, "role": role]
        sendJSON(message)
        pinRequestReceived = false
    }

    func rejectPin() {
        let message: [String: Any] = ["action": "reject_pin", "room_id": roomId, "role": role]
        sendJSON(message)
        pinRequestReceived = false
    }

    func unpinRoom() {
        let message: [String: Any] = ["action": "unpin_room", "room_id": roomId, "role": role]
        sendJSON(message)
        clearPinnedRoom()
        leaveRoom()
    }

    // MARK: - Crypto

    private func generateKeyPair() {
        print("start to generateKeyPair...")
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            print("Failed to generate key pair: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return
        }

        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    private func encryptMessage(_ message: String) -> (String, String)? {
        guard let peerPublicKey = peerPublicKey else {
            print("Peer public key not available")
            return nil
        }

        // 生成随机AES密钥
        let aesKey = SymmetricKey(size: .bits256)
        let aesKeyData = aesKey.withUnsafeBytes { Data($0) }

        // 使用AES加密消息
        guard let messageData = message.data(using: .utf8) else {
            print("Failed to convert message to data")
            return nil
        }
        let encryptedMessage = try? AES.GCM.seal(messageData, using: aesKey).combined

        // 使用RSA加密AES密钥
        var error: Unmanaged<CFError>?
        guard let encryptedAESKey = SecKeyCreateEncryptedData(peerPublicKey,
                                                              .rsaEncryptionOAEPSHA256,
                                                              aesKeyData as CFData,
                                                              &error) as Data? else {
            print("AES key encryption failed: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return nil
        }

        return (encryptedAESKey.base64EncodedString(), encryptedMessage?.base64EncodedString() ?? "")
    }

    private func decryptMessage(encryptedAESKey: String, encryptedMessage: String) -> String? {
        guard let privateKey = privateKey else {
            print("Private key not available")
            return nil
        }

        guard let encryptedAESKeyData = Data(base64Encoded: encryptedAESKey),
              let encryptedMessageData = Data(base64Encoded: encryptedMessage) else {
            print("Failed to decode base64 encrypted data")
            return nil
        }

        // 解密AES密钥
        var error: Unmanaged<CFError>?
        guard let decryptedAESKeyData = SecKeyCreateDecryptedData(privateKey,
                                                                  .rsaEncryptionOAEPSHA256,
                                                                  encryptedAESKeyData as CFData,
                                                                  &error) as Data? else {
            print("AES key decryption failed: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return nil
        }

        let aesKey = SymmetricKey(data: decryptedAESKeyData)

        // 使用AES密钥解密消息
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedMessageData),
              let decryptedData = try? AES.GCM.open(sealedBox, using: aesKey) else {
            print("Message decryption failed")
            return nil
        }

        return String(data: decryptedData, encoding: .utf8)
    }

    func sendTyping(content: String) {
        // Skip typing in pinned rooms when peer is offline
        if isPinned && !peerIsOnline { return }

        guard let (encryptedAESKey, encryptedContent) = encryptMessage(content) else { return }

        let message = [
            "action": "typing",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encryptedAESKey,
            "encrypted_content": encryptedContent
        ]

        sendJSON(message)
    }

    private func wrapPayload(type: String, data: String) -> String {
        let obj: [String: String] = ["type": type, "data": data]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) { return s }
        return data
    }

    private func unwrapPayload(_ plaintext: String) -> (type: String, data: String) {
        if let d = plaintext.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String],
           let type = obj["type"], let data = obj["data"] {
            return (type, data)
        }
        return ("text", plaintext) // legacy fallback
    }

    func sendMessage(content: String) {
        let seq = nextSeq; nextSeq += 1
        let payload = wrapPayload(type: "text", data: content)
        guard let (encryptedAESKey, encryptedContent) = encryptMessage(payload) else { return }

        let message: [String: Any] = [
            "action": "send_message",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encryptedAESKey,
            "encrypted_content": encryptedContent,
            "seq": seq
        ]

        sendJSON(message)
        messages.append(Message(content: content, isFromMe: true, isTyping: false, seq: seq))
    }

    func sendImage(_ imageData: Data) {
        guard peerPublicKey != nil else { return }
        // After two base64 passes + JSON overhead the wire size is ~1.78x raw.
        // Server max_size is 10MB, so reject anything that would exceed that.
        guard imageData.count < 5 * 1024 * 1024 else {
            DispatchQueue.main.async {
                self.messages.append(Message(content: "Image too large to send (max ~5 MB).", isFromMe: false, isTyping: false, isSystem: true))
            }
            return
        }
        let seq = nextSeq; nextSeq += 1
        let base64 = imageData.base64EncodedString()
        let payload = wrapPayload(type: "image", data: base64)
        guard let encrypted = encryptMessage(payload) else { return }
        let message: [String: Any] = [
            "action": "send_message",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encrypted.0,
            "encrypted_content": encrypted.1,
            "seq": seq
        ]
        sendJSON(message)
        self.messages.append(Message(content: "", isFromMe: true, isTyping: false, imageData: imageData, seq: seq))
    }

    private func sendJSON(_ dictionary: [String: Any]) {
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

    func updateServerAddress(address: String, port: String) {
        self.serverHost = address
        self.serverPort = port
        #if DEBUG
        let scheme = useSSL ? "wss" : "ws"
        #else
        let scheme = "wss"
        #endif
        self.serverAddress = "\(scheme)://\(address):\(port)"
        print("Server set to \(serverAddress)")
        setupWebSocket()
    }

    func reportUser() {
        guard let peerUserId = peerUserId else { return }
        let message = [
            "action": "report_user",
            "reported_user_id": peerUserId
        ]
        sendJSON(message)
        if isPinned {
            unpinRoom()
        } else {
            leaveRoom()
        }
    }

    // MARK: - Heart Rate Mode

    var canUseHeartRateMode: Bool {
        peerPublicKey != nil && peerIsOnline
    }

    func startHeartRateMode() {
        guard HKHealthStore.isHealthDataAvailable() else {
            heartRateModeError = "Health data is not available on this device."
            return
        }
        let store = HKHealthStore()
        healthStore = store
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        store.requestAuthorization(toShare: nil, read: [heartRateType]) { [weak self] success, _ in
            guard let self = self else { return }
            guard success else {
                DispatchQueue.main.async {
                    self.heartRateModeError = "Please allow Health access in Settings to share your heart rate."
                }
                return
            }

            let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completionHandler, error in
                guard error == nil else { completionHandler(); return }
                self?.fetchLatestHeartRate(store: store)
                completionHandler()
            }
            self.hkObserverQuery = query
            store.execute(query)
            self.fetchLatestHeartRate(store: store)

            DispatchQueue.main.async {
                self.isHeartRateMode = true
                if WCSession.isSupported() && WCSession.default.isReachable {
                    WCSession.default.sendMessage(["action": "start_heart_rate"], replyHandler: nil, errorHandler: nil)
                } else if WCSession.isSupported() && WCSession.default.isPaired {
                    self.heartRateModeError = "Please open the Unspoken app on your Apple Watch for real-time heart rate."
                }
                self.heartRateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                    guard let self = self, let bpm = self.currentBPM else { return }
                    self.sendHeartRate(bpm: bpm)
                }
            }
        }
    }

    func stopHeartRateMode(notifyPeer: Bool = true) {
        guard isHeartRateMode else { return }
        isHeartRateMode = false
        heartRateTimer?.invalidate()
        heartRateTimer = nil
        endHeartRateBackgroundTask()
        currentBPM = nil
        if let query = hkObserverQuery {
            healthStore?.stop(query)
            hkObserverQuery = nil
        }
        if notifyPeer {
            sendHeartRate(bpm: -1)
        }
        if WCSession.isSupported() && WCSession.default.isReachable {
            WCSession.default.sendMessage(["action": "stop_heart_rate"], replyHandler: nil, errorHandler: nil)
        }
    }

    func stopPeerHeartRate() {
        hapticLoopActive = false
        peerBPM = nil
    }

    private func fetchLatestHeartRate(store: HKHealthStore) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: heartRateType, predicate: nil, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = Int(sample.quantity.doubleValue(for: HKUnit(from: "count/min")))
            DispatchQueue.main.async { self?.currentBPM = bpm }
        }
        store.execute(query)
    }

    func sendHeartRate(bpm: Int) {
        guard let (encryptedAESKey, encryptedContent) = encryptMessage("\(bpm)") else { return }
        let message: [String: Any] = [
            "action": "heart_rate",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encryptedAESKey,
            "encrypted_content": encryptedContent
        ]
        sendJSON(message)
    }

    func handleReceivedHeartRate(bpm: Int) {
        if bpm == -1 {
            stopPeerHeartRate()
            return
        }
        peerBPM = bpm
        guard !hapticLoopActive else { return }
        hapticLoopActive = true
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        heavy.prepare()
        medium.prepare()
        beatLoop(heavy: heavy, medium: medium)
    }

    private func beatLoop(heavy: UIImpactFeedbackGenerator, medium: UIImpactFeedbackGenerator) {
        guard hapticLoopActive, let bpm = peerBPM else {
            hapticLoopActive = false
            return
        }
        let interval = 60.0 / Double(bpm)
        let gap = 0.5 - 0.0021 * Double(bpm)
        heavy.impactOccurred()
        peerLubTick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            guard let self, self.hapticLoopActive else { return }
            medium.impactOccurred()
            self.peerDubTick += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - gap)) { [weak self] in
                self?.beatLoop(heavy: heavy, medium: medium)
            }
        }
    }
}

extension ChatViewModel: WebSocketDelegate {
    func didReceive(event: Starscream.WebSocketEvent, client: any Starscream.WebSocketClient) {
        switch event {
        case .connected(_):
            print("WebSocket connected")
            DispatchQueue.main.async { [weak self] in
                self?.reconnectAttempts = 0
                self?.reconnectTimer?.invalidate()
                self?.reconnectTimer = nil
                self?.isReconnecting = false
                self?.pendingAction?()
                self?.pendingAction = nil
            }
        case .disconnected(let reason, let code):
            print("WebSocket disconnected: \(reason) (\(code))")
            DispatchQueue.main.async { [weak self] in
                self?.scheduleReconnect()
            }
        case .text(let string):
            handleMessage(string)
        case .binary(_):
            break
        case .pong(_):
            break
        case .ping(_):
            break
        case .error(let error):
            print("WebSocket error: \(error?.localizedDescription ?? "Unknown error")")
            DispatchQueue.main.async { [weak self] in
                self?.scheduleReconnect()
            }
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            break
        case .peerClosed:
            DispatchQueue.main.async { [weak self] in
                self?.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }

        let action = json["action"] as? String ?? ""

        DispatchQueue.main.async {
            switch action {
            case "room_created", "room_joined":
                if let roomId = json["room_id"] as? String,
                   let role = json["role"] as? String {
                    self.roomId = roomId
                    self.role = role
                    self.isChatOpen = true
                }
                // Read pinned/peer_status fields
                if let pinned = json["pinned"] as? Bool {
                    self.isPinned = pinned
                }
                if let peerStatus = json["peer_status"] as? String {
                    self.peerIsOnline = (peerStatus == "online")
                }
                if let peerUserId = json["peer_user_id"] as? String,
                   let publicKeyBase64 = json["peer_public_key"] as? String,
                   let publicKeyData = Data(base64Encoded: publicKeyBase64) {
                    var error: Unmanaged<CFError>?
                    if let peerPublicKey = SecKeyCreateWithData(publicKeyData as CFData,
                                                                [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                                 kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                                                &error) {
                        self.peerPublicKey = peerPublicKey
                        self.peerUserId = peerUserId
                        // Only set online here if peer_status wasn't explicitly provided
                        // (pinned room rejoin always sends peer_status; normal join does not)
                        if (json["peer_status"] as? String) == nil {
                            self.peerIsOnline = true
                        }
                        print("Received and set peer public key")
                        if self.isPinned {
                            self.messages.append(Message(content: "Rejoined pinned room. Encrypted channel restored.", isFromMe: false, isTyping: false, isSystem: true))
                            if let pendingCount = json["pending_count"] as? Int, pendingCount > 0 {
                                self.messages.append(Message(content: "\(pendingCount)", isFromMe: false, isTyping: false, isPendingPlaceholder: true))
                            }
                        } else {
                            self.messages.append(Message(content: "Encrypted channel established, enjoy!", isFromMe: false, isTyping: false, isSystem: true))
                        }
                    } else {
                        print("Failed to create peer public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
                    }
                }
            case "user_joined":
                if let peerRole = json["peer_role"] as? String,
                   let peerUserId = json["peer_user_id"] as? String,
                   let publicKeyBase64 = json["peer_public_key"] as? String,
                   let publicKeyData = Data(base64Encoded: publicKeyBase64) {
                    var error: Unmanaged<CFError>?
                    if let peerPublicKey = SecKeyCreateWithData(publicKeyData as CFData,
                                                                [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                                 kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                                                &error) {
                        self.peerPublicKey = peerPublicKey
                        self.peerUserId = peerUserId
                        self.peerIsOnline = true
                        print("Received and set peer public key")
                        self.messages.append(Message(content: "\(peerRole.capitalized) joined, Encrypted channel established, enjoy!", isFromMe: false, isTyping: false, isSystem: true))
                    } else {
                        print("Failed to create peer public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
                    }
                }
            case "user_left":
                if let role = json["role"] as? String {
                    self.messages.append(Message(content: "\(role.capitalized) has left the room.", isFromMe: false, isTyping: false, isSystem: true))
                }
                self.peerIsOnline = false
                self.stopPeerHeartRate()
                self.stopHeartRateMode(notifyPeer: false)
            case "room_closed":
                self.stopPeerHeartRate()
                self.stopHeartRateMode(notifyPeer: false)
                self.messages.append(Message(content: "Host has left the room. The room is closed.", isFromMe: false, isTyping: false, isSystem: true))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.leaveRoom()
                }
            case "typing":
                if let encryptedAESKey = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                    self.typingContent = decryptedContent
                }
            case "heart_rate":
                if let encryptedAESKey = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent),
                   let bpm = Int(decryptedContent) {
                    self.handleReceivedHeartRate(bpm: bpm)
                }
            case "new_message":
                if let encryptedAESKey = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                    let (type, data) = self.unwrapPayload(decryptedContent)
                    if type == "image", let imgData = Data(base64Encoded: data) {
                        self.messages.append(Message(content: "", isFromMe: false, isTyping: false, imageData: imgData))
                    } else {
                        self.messages.append(Message(content: data, isFromMe: false, isTyping: false))
                    }
                }

            // MARK: - Pin protocol handlers
            case "pin_requested":
                self.pinRequestReceived = true
            case "pin_accepted":
                self.isPinned = true
                self.pinRequestPending = false
                // Update peer key/id if provided
                if let peerUserId = json["peer_user_id"] as? String {
                    self.peerUserId = peerUserId
                }
                if let publicKeyBase64 = json["peer_public_key"] as? String,
                   let publicKeyData = Data(base64Encoded: publicKeyBase64) {
                    var error: Unmanaged<CFError>?
                    if let peerKey = SecKeyCreateWithData(publicKeyData as CFData,
                                                          [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                           kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                                          &error) {
                        self.peerPublicKey = peerKey
                    }
                }
                self.savePinnedRoom()
                self.messages.append(Message(content: "Room pinned! This room will persist across sessions.", isFromMe: false, isTyping: false, isSystem: true))
            case "pin_rejected":
                self.pinRequestPending = false
                self.messages.append(Message(content: "Pin request was declined.", isFromMe: false, isTyping: false, isSystem: true))
            case "room_unpinned":
                self.clearPinnedRoom()
                self.stopPeerHeartRate()
                self.stopHeartRateMode(notifyPeer: false)
                self.messages.append(Message(content: "Room has been unpinned by peer.", isFromMe: false, isTyping: false, isSystem: true))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.isChatOpen = false
                    self.roomId = ""
                    self.role = ""
                    self.messages = []
                    self.peerPublicKey = nil
                    self.peerUserId = nil
                }
            case "peer_status":
                if let status = json["status"] as? String {
                    self.peerIsOnline = (status == "online")
                    let statusText = status == "online" ? "Peer is now online." : "Peer went offline."
                    self.messages.append(Message(content: statusText, isFromMe: false, isTyping: false, isSystem: true))
                    if status == "offline" {
                        self.typingContent = ""
                        self.stopPeerHeartRate()
                        self.stopHeartRateMode(notifyPeer: false)
                    }
                }
            case "pending_messages":
                if let msgs = json["messages"] as? [[String: Any]] {
                    self.messages.removeAll { $0.isPendingPlaceholder }
                    let isoFormatter = ISO8601DateFormatter()
                    for msg in msgs {
                        if let encryptedAESKey = msg["encrypted_aes_key"] as? String,
                           let encryptedContent = msg["encrypted_content"] as? String,
                           let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                            let timestamp = (msg["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
                            let (type, data) = self.unwrapPayload(decryptedContent)
                            if type == "image", let imgData = Data(base64Encoded: data) {
                                self.messages.append(Message(content: "", isFromMe: false, isTyping: false, timestamp: timestamp, imageData: imgData))
                            } else {
                                self.messages.append(Message(content: data, isFromMe: false, isTyping: false, timestamp: timestamp))
                            }
                        }
                    }
                }

            case "error":
                if let errorMessage = json["message"] as? String {
                    print("Error: \(errorMessage)")
                    // If pinned room not found, peer must have unpinned while we were offline
                    if self.isPinned && errorMessage.lowercased().contains("not found") {
                        self.clearPinnedRoom()
                        self.isChatOpen = false
                        self.roomId = ""
                        self.role = ""
                        self.peerPublicKey = nil
                        self.peerUserId = nil
                    }
                }
            case "blocked":
                if let errorMessage = json["message"] as? String {
                    self.messages.append(Message(content: errorMessage, isFromMe: false, isTyping: false, isSystem: true))
                }
            case "ack":
                if let seq = json["seq"] as? Int,
                   let idx = self.messages.firstIndex(where: { $0.seq == seq }) {
                    self.messages[idx].isAcked = true
                }
            case "login_failed":
                print("login failed")
            default:
                break
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText: String = ""
    @State private var showBlockedWordAlert: Bool = false
    @State private var showCopySuccessAlert: Bool = false
    @State private var showUnpinConfirm: Bool = false
    @State private var heartPulse: Bool = false
    @State private var bgHeartScale: CGFloat = 1.0
    @State private var showTimestamps: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var showImageSourceDialog: Bool = false
    @State private var showImagePicker: Bool = false
    @State private var imagePickerSource: UIImagePickerController.SourceType = .photoLibrary
    @State private var selectedImage: UIImage? = nil
    @State private var fullScreenImage: UIImage? = nil

    var canSendMessage: Bool {
        return viewModel.peerPublicKey != nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.4)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 0) {
                    chatHeader

                    ScreenshotProtected { chatMessages }

                    inputArea
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(isPresented: .constant(!viewModel.isChatOpen && !viewModel.messages.isEmpty)) {
            Alert(
                title: Text("Room Closed"),
                message: Text(viewModel.messages.last?.content ?? ""),
                dismissButton: .default(Text("OK")) {
                    viewModel.messages = []
                }
            )
        }
        .alert("Notice", isPresented: $showBlockedWordAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Message contains blocked words. Please modify and try again.")
        }
        .alert("Link Copied", isPresented: $showCopySuccessAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Room invitation link has been copied to clipboard.")
        }
        .alert("Pin Request", isPresented: $viewModel.pinRequestReceived) {
            Button("Accept") {
                viewModel.acceptPin()
            }
            Button("Decline", role: .cancel) {
                viewModel.rejectPin()
            }
        } message: {
            Text("Your peer wants to pin this room. Pinned rooms persist across sessions and support offline messaging. Accept?")
        }
        .alert("Heart Rate", isPresented: Binding(
            get: { viewModel.heartRateModeError != nil },
            set: { if !$0 { viewModel.heartRateModeError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.heartRateModeError = nil }
        } message: {
            Text(viewModel.heartRateModeError ?? "")
        }
        .confirmationDialog("Send Image", isPresented: $showImageSourceDialog) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") {
                    imagePickerSource = .camera
                    showImagePicker = true
                }
            }
            Button("Choose from Library") {
                imagePickerSource = .photoLibrary
                showImagePicker = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showImagePicker, onDismiss: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                isTextFieldFocused = true
            }
        }) {
            ImagePicker(sourceType: imagePickerSource) { image in
                selectedImage = image
                showImagePicker = false
            }
        }
        .onChange(of: selectedImage) { image in
            guard let image, let data = processImageForSending(image) else { return }
            viewModel.sendImage(data)
            selectedImage = nil
        }
        .sheet(item: Binding(
            get: { fullScreenImage.map { IdentifiableImage(image: $0) } },
            set: { fullScreenImage = $0?.image }
        )) { item in
            ScreenshotProtected {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: item.image)
                        .resizable()
                        .scaledToFit()
                }
            }
            .ignoresSafeArea()
        }
    }

    var chatHeader: some View {
        HStack {
            // Pin indicator
            if viewModel.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }

            if viewModel.isReconnecting {
                Text("Reconnecting...")
                    .font(.headline)
                    .foregroundColor(.yellow)
            } else {
                Text("Room: \(viewModel.roomId)")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            // Online status indicator for pinned rooms
            if viewModel.isPinned {
                Circle()
                    .fill(viewModel.peerIsOnline ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }

            Spacer()

            // Pin button (only when not pinned and peer is present)
            if !viewModel.isPinned && viewModel.peerPublicKey != nil {
                Button(action: {
                    viewModel.requestPin()
                }) {
                    Image(systemName: "pin")
                        .foregroundColor(viewModel.pinRequestPending ? .gray : .white)
                }
                .disabled(viewModel.pinRequestPending)
            }

            // Copy link button (host only, non-pinned)
            if viewModel.role == "host" && !viewModel.isPinned {
                Button(action: {
                    let url = "unspoken://\(viewModel.serverHost):\(viewModel.serverPort)/\(viewModel.roomId)"
                    UIPasteboard.general.string = url
                    showCopySuccessAlert = true
                }) {
                    Image(systemName: "link")
                        .foregroundColor(.white)
                }
            }

            // Heart rate button: show when peer online, self sending, or receiving peer HR
            if viewModel.canUseHeartRateMode || viewModel.isHeartRateMode || viewModel.peerBPM != nil {
                Button(action: {
                    if viewModel.isHeartRateMode {
                        viewModel.stopHeartRateMode()
                    } else {
                        viewModel.startHeartRateMode()
                    }
                }) {
                    HStack(spacing: 3) {
                        if let peerBPM = viewModel.peerBPM {
                            Text("\(peerBPM)")
                                .font(.caption.bold())
                                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.8))
                        }
                        Image(systemName: viewModel.isHeartRateMode || viewModel.peerBPM != nil ? "heart.fill" : "heart")
                            .foregroundColor(viewModel.isHeartRateMode ? .red : (viewModel.peerBPM != nil ? Color(red: 1.0, green: 0.6, blue: 0.8) : .white))
                            .scaleEffect(heartPulse ? 1.2 : 1.0)
                            .onChange(of: viewModel.isHeartRateMode) { active in
                                if active {
                                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                                        heartPulse = true
                                    }
                                } else {
                                    withAnimation { heartPulse = false }
                                }
                            }
                        if viewModel.isHeartRateMode, let bpm = viewModel.currentBPM {
                            Text("\(bpm)")
                                .font(.caption.bold())
                                .foregroundColor(.red)
                        }
                    }
                }
                .disabled(!viewModel.canUseHeartRateMode)
            }

            Spacer().frame(width: 12)

            if viewModel.isPinned {
                // Leave button (temporary, keeps pin)
                Button(action: {
                    viewModel.leaveRoom()
                }) {
                    Text("Leave")
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.8))
                        .cornerRadius(8)
                }
                // Unpin button (permanent)
                Button(action: {
                    showUnpinConfirm = true
                }) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                        .padding(6)
                }
            } else {
                Button(action: {
                    viewModel.leaveRoom()
                }) {
                    Text("Leave")
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.2))
        .alert("Unpin this room?", isPresented: $showUnpinConfirm) {
            Button("Unpin", role: .destructive) { viewModel.unpinRoom() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the room on both devices and the server, including any pending messages. This cannot be undone.")
        }
    }

    var chatMessages: some View {
        ZStack {
            // Background heartbeat animation (receiver side)
            ZStack {
                Image(systemName: "heart.fill")
                    .font(.system(size: 220))
                    .foregroundColor(.white)
                    .opacity(0.22)
                Image(systemName: "heart.fill")
                    .font(.system(size: 185))
                    .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.8))
                    .opacity(0.55)
            }
            .opacity(viewModel.peerBPM != nil ? 1 : 0)
            .scaleEffect(bgHeartScale)
            .animation(.easeInOut(duration: 0.6), value: viewModel.peerBPM != nil)
            .allowsHitTesting(false)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message, onReport: {
                            viewModel.reportUser()
                        }, showTimestamp: showTimestamps, onImageTap: { image in
                            fullScreenImage = image
                        })
                    }
                    if !viewModel.typingContent.isEmpty {
                        MessageView(
                            message: Message(
                                content: viewModel.typingContent,
                                isFromMe: false,
                                isTyping: true
                            )
                        ) {
                            viewModel.reportUser()
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 8)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { value in
                        guard abs(value.translation.height) < abs(value.translation.width) else { return }
                        if value.translation.width < 0 {
                            withAnimation(.easeInOut(duration: 0.2)) { showTimestamps = true }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeInOut(duration: 0.2)) { showTimestamps = false }
                    }
            )
            .onChange(of: viewModel.messages.count) { _ in
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.typingContent) { _ in
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        } // ZStack
        .onChange(of: viewModel.peerLubTick) { _ in
            withAnimation(.easeOut(duration: 0.08)) { bgHeartScale = 1.15 }
        }
        .onChange(of: viewModel.peerDubTick) { _ in
            withAnimation(.easeOut(duration: 0.06)) { bgHeartScale = 1.08 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.25)) { bgHeartScale = 1.0 }
            }
        }
        .onChange(of: viewModel.peerBPM) { newBPM in
            if newBPM == nil { bgHeartScale = 1.0 }
        }
    }

    var inputArea: some View {
        HStack(spacing: 10) {
            Button(action: { showImageSourceDialog = true }) {
                Image(systemName: "photo")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }
            .disabled(!canSendMessage)
            TextField(inputPlaceholder, text: $messageText)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.2))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .focused($isTextFieldFocused)
                .onChange(of: messageText) { newValue in
                    if canSendMessage {
                        viewModel.sendTyping(content: newValue)
                    }
                }
                .onSubmit {
                    if canSendMessage {
                        sendMessage()
                    }
                }
                .disabled(!canSendMessage)

            Button(action: clearMessage) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
            }
            .disabled(messageText.isEmpty || !canSendMessage)

            Button(action: sendMessage) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSendMessage)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.1))
    }

    private var inputPlaceholder: String {
        if !canSendMessage {
            return "Waiting for peer to join..."
        }
        if viewModel.isPinned && !viewModel.peerIsOnline {
            return "Message (peer offline, will be delivered later)"
        }
        return "Type a message"
    }

    //iOS	 app上架审核需要有这个功能
    func canSend(content: String) -> Bool {
        let blockedWords = ["badword1", "badword2", "fuck", "shit", "ass", "asshole", "bastard", "bitch", "damn", "dick", "douche", "fag", "faggot", "hell", "piss", "slut", "whore", "cunt", "crap", "jerk", "balls", "prick", "cock", "wanker", "retard", "moron", "damn", "bloody", "bollocks" ]
        for word in blockedWords {
            if content.lowercased().contains(word) {
                return false
            }
        }
        return true
    }

    private func sendMessage() {
        guard canSend(content: messageText) else {
            showBlockedWordAlert = true
            return
        }
        if canSendMessage && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.sendMessage(content: messageText)
            messageText = ""
            isTextFieldFocused = true
        }
    }

    private func clearMessage() {
        messageText = ""
    }
}

struct MessageView: View {
    let message: Message
    let onReport: () -> Void
    var showTimestamp: Bool = false
    var onImageTap: (UIImage) -> Void = { _ in }

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private static func formatTimestamp(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        return elapsed < 86400
            ? timeOnlyFormatter.string(from: date)
            : dateTimeFormatter.string(from: date)
    }

    var body: some View {
        Group {
            if message.isSystem {
                HStack {
                    Spacer()
                    Text(message.content)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                    Spacer()
                }
            } else if message.isPendingPlaceholder {
                HStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(.white)
                        let count = Int(message.content) ?? 0
                        Text(count == 1 ? "1 pending message" : "\(count) pending messages")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.purple.opacity(0.5))
                    .cornerRadius(10)
                    Spacer()
                }
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    if message.isFromMe {
                        Spacer()
                        if !message.isTyping {
                            if message.isAcked {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.blue)
                            } else {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .tint(.red)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                    if let imgData = message.imageData, let uiImage = UIImage(data: imgData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .cornerRadius(10)
                            .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                            .onTapGesture { onImageTap(uiImage) }
                            .contextMenu {
                                if !message.isFromMe {
                                    Button(role: .destructive, action: onReport) {
                                        Label("Report User", systemImage: "exclamationmark.triangle")
                                    }
                                }
                            }
                    } else {
                        Text(message.content)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(message.isFromMe ? Color.blue.opacity(message.isTyping ? 0.4 : 0.8) : Color.purple.opacity(message.isTyping ? 0.4 : 0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                            .contextMenu {
                                if !message.isFromMe && !message.isSystem {
                                    Button(role: .destructive, action: onReport) {
                                        Label("Report User", systemImage: "exclamationmark.triangle")
                                    }
                                }
                            }
                    }
                    if !message.isFromMe {
                        Spacer()
                    }
                    if showTimestamp, let ts = message.timestamp {
                        Text(Self.formatTimestamp(ts))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                            .fixedSize()
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - WCAdapter (NSObject required for WCSessionDelegate)
private class WCAdapter: NSObject, WCSessionDelegate {
    private let onBPM: (Int) -> Void
    init(onBPM: @escaping (Int) -> Void) { self.onBPM = onBPM }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let bpm = message["bpm"] as? Int else { return }
        onBPM(bpm)
    }
}

struct Message: Identifiable {
    let id = UUID()
    let content: String
    let isFromMe: Bool
    let isTyping: Bool
    let isSystem: Bool
    let isPendingPlaceholder: Bool
    let timestamp: Date?
    let imageData: Data?
    let seq: Int?
    var isAcked: Bool

    init(content: String, isFromMe: Bool, isTyping: Bool, isSystem: Bool = false, isPendingPlaceholder: Bool = false, timestamp: Date? = nil, imageData: Data? = nil, seq: Int? = nil, isAcked: Bool = false) {
        self.content = content
        self.isFromMe = isFromMe
        self.isTyping = isTyping
        self.isSystem = isSystem
        self.isPendingPlaceholder = isPendingPlaceholder
        self.timestamp = timestamp
        self.imageData = imageData
        self.seq = seq
        self.isAcked = isAcked
    }
}

// MARK: - ImagePicker

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        if sourceType == .camera && UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
                onImage(img)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - IdentifiableImage

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Image Processing

private func processImageForSending(_ image: UIImage) -> Data? {
    let maxDimension: CGFloat = 1200
    // image.size is in points; multiply by image.scale to get actual pixels.
    let pixelW = image.size.width * image.scale
    let pixelH = image.size.height * image.scale
    let ratio = min(maxDimension / pixelW, maxDimension / pixelH, 1.0)
    let newSize = CGSize(width: (pixelW * ratio).rounded(), height: (pixelH * ratio).rounded())

    // scale = 1.0 so renderer works in pixels directly (avoids screen-scale multiplication).
    // opaque = true strips alpha channel — HEIC doesn't support AlphaLast pixel format.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }

    guard let cgImage = resized.cgImage else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// MARK: - Screenshot Protection
// UITextField with isSecureTextEntry=true has a system-level CALayer that is
// excluded from screenshots. Embedding any view inside that layer inherits the
// same protection — content shows normally on screen but appears blank in screenshots.

// Subclass that never becomes first responder, so it won't intercept taps or
// show a keyboard, while still allowing touches to reach its subviews.
private final class PassthroughTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

fileprivate class SecureContainerView: UIView {
    private let secureField = PassthroughTextField()
    private weak var embeddedView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        secureField.isSecureTextEntry = true
        secureField.backgroundColor = .clear
        // isUserInteractionEnabled stays true (default) so touches propagate
        // to the embedded content inside secureField's subview hierarchy.
        addSubview(secureField)
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ view: UIView) {
        embeddedView = view
        guard let secureLayer = secureField.subviews.first else { return }
        secureLayer.addSubview(view)
    }

    // Use layoutSubviews to keep all frames in sync — more reliable than
    // Auto Layout against UITextField's internal subviews.
    override func layoutSubviews() {
        super.layoutSubviews()
        secureField.frame = bounds
        guard let secureLayer = secureField.subviews.first else { return }
        secureLayer.frame = bounds
        embeddedView?.frame = bounds
    }
}

fileprivate struct ScreenshotProtected<Content: View>: UIViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(content: content()) }

    func makeUIView(context: Context) -> SecureContainerView {
        let container = SecureContainerView()
        container.backgroundColor = .clear
        container.embed(context.coordinator.host.view)
        return container
    }

    func updateUIView(_ uiView: SecureContainerView, context: Context) {
        context.coordinator.host.rootView = content()
    }

    class Coordinator {
        let host: UIHostingController<Content>
        init(content: Content) {
            host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
        }
    }
}
