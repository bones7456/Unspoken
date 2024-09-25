//
//  ContentView.swift
//  Unspoken
//
//  Created by Luyang Li on 11/8/24.
//

import SwiftUI
import Starscream
import CryptoKit

class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var typingContent: String = ""
    @Published var isChatOpen: Bool = false
    @Published var roomId: String = ""
    @Published var serverAddress: String = "ws://18.138.249.97:8765"
    @Published var role: String = ""
    
    private var socket: WebSocket?
    private var userId: String
    
    private var privateKey: SecKey?
    private var publicKey: SecKey?
    private var peerPublicKey: SecKey?
    
    private var peerUserId: String?
    
    init() {
        self.userId = UUID().uuidString
        setupWebSocket()
        generateKeyPair()
    }
    
    private func setupWebSocket() {
        socket?.disconnect()
        
        let url = URL(string: serverAddress)!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }
    
    func sendLogin() {
        guard let publicKey = publicKey else { return }
        
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("Failed to get public key data: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return
        }
        
        let publicKeyBase64 = publicKeyData.base64EncodedString()
        
        let message = [
            "action": "login",
            "user_id": userId,
            "public_key": publicKeyBase64
        ]
        
        sendJSON(message)
    }
    
    func createRoom() {
        sendLogin()
        let message = ["action": "create_room"]
        sendJSON(message)
    }
    
    func joinRoom() {
        sendLogin()
        let message = ["action": "join_room", "room_id": roomId]
        sendJSON(message)
    }
    
    func leaveRoom() {
        let message = ["action": "leave_room", "room_id": roomId, "role": role]
        sendJSON(message)
        isChatOpen = false
        roomId = ""
        role = ""
    }
    
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
        print("privateKey: \(privateKey);publicKey: \(publicKey)")
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
    
    func sendMessage(content: String) {
        guard let (encryptedAESKey, encryptedContent) = encryptMessage(content) else { return }
        
        let message = [
            "action": "send_message",
            "room_id": roomId,
            "role": role,
            "encrypted_aes_key": encryptedAESKey,
            "encrypted_content": encryptedContent
        ]
        
        sendJSON(message)
        messages.append(Message(content: content, isFromMe: true, isTyping: false))
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
        print("Server set to \(address):\(port)")
        self.serverAddress = "ws://\(address):\(port)"
        setupWebSocket()
        generateKeyPair()
    }
}

extension ChatViewModel: WebSocketDelegate {
    func didReceive(event: Starscream.WebSocketEvent, client: any Starscream.WebSocketClient) {
        switch event {
        case .connected(_):
            print("WebSocket connected")
            //sendLogin()
        case .disconnected(_, _):
            print("WebSocket disconnected")
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
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            break
        case .peerClosed:
            break
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
                        print("Received and set peer public key")
                        self.messages.append(Message(content: "Encrypted channel established, enjoy!", isFromMe: false, isTyping: false, isSystem: true))
                    } else {
                        print("Failed to create peer public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
                    }
                }
            case "user_joined":
                if let role = json["role"] as? String,
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
                        print("Received and set peer public key")
                        self.messages.append(Message(content: "\(role.capitalized) joined, Encrypted channel established, enjoy!", isFromMe: false, isTyping: false, isSystem: true))
                    } else {
                        print("Failed to create peer public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
                    }
                }
            case "user_left":
                if let role = json["role"] as? String {
                    self.messages.append(Message(content: "\(role.capitalized) has left the room.", isFromMe: false, isTyping: false, isSystem: true))
                }
            case "room_closed":
                self.messages.append(Message(content: "Host has left the room. The room is closed.", isFromMe: false, isTyping: false, isSystem: true))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.leaveRoom()
                    self.messages = []
                }
            case "typing":
                if let encryptedAESKey = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                    self.typingContent = decryptedContent
                }
            case "new_message":
                if let encryptedAESKey = json["encrypted_aes_key"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedAESKey: encryptedAESKey, encryptedMessage: encryptedContent) {
                    self.messages.append(Message(content: decryptedContent, isFromMe: false, isTyping: false))
                }
            case "error":
                if let errorMessage = json["message"] as? String {
                    print("Error: \(errorMessage)")
                    // You might want to show this error to the user
                }
            default:
                break
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.4)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                chatHeader
                
                chatMessages
                
                inputArea
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
    }
    
    var chatHeader: some View {
        HStack {
            Text("Room: \(viewModel.roomId)")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
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
        .padding()
        .background(Color.black.opacity(0.2))
    }
    
    var chatMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message)
                    }
                    if !viewModel.typingContent.isEmpty {
                        MessageView(
                            message: Message(
                                content: viewModel.typingContent,
                                isFromMe: false,
                                isTyping: true
                            )
                        )
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 8)
            }
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
    }
    
    var inputArea: some View {
        HStack(spacing: 10) {
            TextField("Type a message", text: $messageText)
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
                    viewModel.sendTyping(content: newValue)
                }
                .onSubmit {
                    sendMessage()
                }
            
            Button(action: clearMessage) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
            }
            .disabled(messageText.isEmpty)
            
            Button(action: sendMessage) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.1))
    }
    
    private func sendMessage() {
        //guard !messageText.isEmpty else { return }
        viewModel.sendMessage(content: messageText)
        messageText = ""
        isTextFieldFocused = true // 发送消息后保持输入框焦点
    }
    
    private func clearMessage() {
        messageText = ""
    }
}

struct MessageView: View {
    let message: Message
    
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
            } else {
                HStack {
                    if message.isFromMe {
                        Spacer()
                    }
                    Text(message.content)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(message.isFromMe ? Color.blue.opacity(message.isTyping ? 0.4 : 0.8) : Color.purple.opacity(message.isTyping ? 0.4 : 0.8))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                    if !message.isFromMe {
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}

struct Message: Identifiable {
    let id = UUID()
    let content: String
    let isFromMe: Bool
    let isTyping: Bool
    let isSystem: Bool
    
    init(content: String, isFromMe: Bool, isTyping: Bool, isSystem: Bool = false) {
        self.content = content
        self.isFromMe = isFromMe
        self.isTyping = isTyping
        self.isSystem = isSystem
    }
}
