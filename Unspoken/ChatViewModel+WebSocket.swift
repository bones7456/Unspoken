//
//  ChatViewModel+WebSocket.swift
//  Unspoken
//

import Foundation
import Starscream

extension ChatViewModel: WebSocketDelegate {
    func didReceive(event: Starscream.WebSocketEvent, client: any Starscream.WebSocketClient) {
        switch event {
        case .connected:
            print("WebSocket connected")
            DispatchQueue.main.async { [weak self] in
                self?.isSocketConnected = true
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
                self?.isSocketConnected = false
                self?.scheduleReconnect()
            }
        case .text(let string):
            handleMessage(string)
        case .error(let error):
            print("WebSocket error: \(error?.localizedDescription ?? "Unknown error")")
            DispatchQueue.main.async { [weak self] in
                self?.isSocketConnected = false
                self?.scheduleReconnect()
            }
        case .viabilityChanged(let isViable):
            if !isViable {
                DispatchQueue.main.async { [weak self] in
                    self?.isSocketConnected = false
                    self?.scheduleReconnect()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isReconnecting else { return }
                    self.reconnectAttempts = 0
                    self.scheduleReconnect()
                }
            }
        case .cancelled:
            DispatchQueue.main.async { [weak self] in
                self?.isSocketConnected = false
            }
        case .peerClosed:
            DispatchQueue.main.async { [weak self] in
                self?.isSocketConnected = false
                self?.scheduleReconnect()
            }
        default:
            break
        }
    }

    private func handleMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let action = json["action"] as? String ?? ""

        DispatchQueue.main.async {
            switch action {
            case "room_created", "room_joined":
                if let roomId = json["room_id"] as? String,
                   let role   = json["role"] as? String {
                    self.roomId = roomId
                    self.role   = role
                    if self.didShowDisconnectMessage {
                        self.addSystemMessage("Reconnected")
                        self.didShowDisconnectMessage = false
                    }
                    self.isChatOpen = true
                }
                if let pinned = json["pinned"] as? Bool {
                    self.isPinned = pinned
                }
                if let peerStatus = json["peer_status"] as? String {
                    self.peerIsOnline = (peerStatus == "online")
                }
                if let peerUserId      = json["peer_user_id"] as? String,
                   let publicKeyBase64 = json["peer_public_key"] as? String,
                   let publicKeyData   = Data(base64Encoded: publicKeyBase64) {
                    var error: Unmanaged<CFError>?
                    if let peerPublicKey = SecKeyCreateWithData(publicKeyData as CFData,
                                                                [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                                 kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                                                &error) {
                        self.peerPublicKey = peerPublicKey
                        self.peerUserId    = peerUserId
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
                        self.retryPendingMessages()
                    } else {
                        print("Failed to create peer public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
                    }
                }

            case "user_joined":
                if let peerRole        = json["peer_role"] as? String,
                   let peerUserId      = json["peer_user_id"] as? String,
                   let publicKeyBase64 = json["peer_public_key"] as? String,
                   let publicKeyData   = Data(base64Encoded: publicKeyBase64) {
                    var error: Unmanaged<CFError>?
                    if let peerPublicKey = SecKeyCreateWithData(publicKeyData as CFData,
                                                                [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                                 kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                                                &error) {
                        self.peerPublicKey = peerPublicKey
                        self.peerUserId    = peerUserId
                        self.peerIsOnline  = true
                        print("Received and set peer public key")
                        self.messages.append(Message(content: "\(peerRole.capitalized) joined, Encrypted channel established, enjoy!", isFromMe: false, isTyping: false, isSystem: true))
                        self.retryPendingMessages()
                    } else {
                        print("Failed to create peer public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.isChatOpen else { return }
                    self.leaveRoom()
                }

            case "typing":
                if let encryptedAESKey = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                    self.typingContent = decryptedContent
                }

            case "heart_rate":
                if let encryptedAESKey  = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent),
                   let bpm = Int(decryptedContent) {
                    self.handleReceivedHeartRate(bpm: bpm)
                }

            case "new_message":
                if let encryptedAESKey  = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                    let (type, data, quote) = self.unwrapPayload(decryptedContent)
                    if type == "image", let imgData = Data(base64Encoded: data) {
                        self.messages.append(Message(content: "", isFromMe: false, isTyping: false, imageData: imgData, quote: quote))
                    } else {
                        self.messages.append(Message(content: data, isFromMe: false, isTyping: false, quote: quote))
                    }
                }

            case "pin_requested":
                self.pinRequestReceived = true

            case "pin_accepted":
                self.isPinned = true
                self.pinRequestPending = false
                if let peerUserId = json["peer_user_id"] as? String {
                    self.peerUserId = peerUserId
                }
                if let publicKeyBase64 = json["peer_public_key"] as? String,
                   let publicKeyData   = Data(base64Encoded: publicKeyBase64) {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.isChatOpen else { return }
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

            case "pending_message":
                if let encryptedAESKey  = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                    self.messages.removeAll { $0.isPendingPlaceholder }
                    let isoFormatter = ISO8601DateFormatter()
                    let timestamp = (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
                    let (type, data, quote) = self.unwrapPayload(decryptedContent)
                    if type == "image", let imgData = Data(base64Encoded: data) {
                        self.messages.append(Message(content: "", isFromMe: false, isTyping: false, timestamp: timestamp, imageData: imgData, quote: quote))
                    } else {
                        self.messages.append(Message(content: data, isFromMe: false, isTyping: false, timestamp: timestamp, quote: quote))
                    }
                    if let remaining = json["pending_count"] as? Int, remaining > 0 {
                        self.messages.append(Message(content: "\(remaining)", isFromMe: false, isTyping: false, isPendingPlaceholder: true))
                    }
                    if let pendingMsgId = json["pending_msg_id"] {
                        self.sendJSON([
                            "action": "pending_ack",
                            "room_id": self.roomId,
                            "role": self.role,
                            "pending_msg_id": pendingMsgId
                        ])
                    }
                }

            case "error":
                if let errorMessage = json["message"] as? String {
                    print("Error: \(errorMessage)")
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
