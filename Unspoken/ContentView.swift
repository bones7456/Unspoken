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
    @Published var serverAddress: String = "ws://unspoken.luy.li:8765"
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
        let message = ["action": "login", "user_id": userId]
        sendJSON(message)
    }
    
    func createRoom() {
        let message = ["action": "create_room"]
        sendJSON(message)
    }
    
    func joinRoom() {
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
        
        sendPublicKey()
    }
    
    private func sendPublicKey() {
        guard let publicKey = publicKey else { return }
        
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("Failed to get public key data: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return
        }
        
        let publicKeyBase64 = publicKeyData.base64EncodedString()
        
        let message = [
            "action": "exchange_public_key",
            "user_id": userId,
            "public_key": publicKeyBase64
        ]
        
        sendJSON(message)
    }
    
    private func requestPeerPublicKey() {
        guard let peerUserId = peerUserId else {
            print("Peer user ID not available")
            return
        }
        
        let message = [
            "action": "request_public_key",
            "requested_user_id": peerUserId
        ]
        
        sendJSON(message)
    }
    
    private func encryptMessage(_ message: String) -> String? {
        guard let peerPublicKey = peerPublicKey else {
            print("Peer public key not available")
            return nil
        }
        
        guard let messageData = message.data(using: .utf8) else {
            print("Failed to convert message to data")
            return nil
        }
        
        var error: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(peerPublicKey,
                                                            .rsaEncryptionOAEPSHA256,
                                                            messageData as CFData,
                                                            &error) as Data? else {
            print("Encryption failed: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return nil
        }
        
        return encryptedData.base64EncodedString()
    }
    
    private func decryptMessage(_ encryptedMessage: String) -> String? {
        guard let privateKey = privateKey else {
            print("Private key not available")
            return nil
        }
        
        guard let encryptedData = Data(base64Encoded: encryptedMessage) else {
            print("Failed to decode base64 encrypted message")
            return nil
        }
        
        var error: Unmanaged<CFError>?
        guard let decryptedData = SecKeyCreateDecryptedData(privateKey,
                                                            .rsaEncryptionOAEPSHA256,
                                                            encryptedData as CFData,
                                                            &error) as Data? else {
            print("Decryption failed: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return nil
        }
        
        return String(data: decryptedData, encoding: .utf8)
    }
    
    func sendTyping(content: String) {
        guard let encryptedContent = encryptMessage(content) else { return }
        
        let message = [
            "action": "typing",
            "room_id": roomId,
            "role": role,
            "encrypted_content": encryptedContent
        ]
        
        sendJSON(message)
    }
    
    func sendMessage(content: String) {
        guard let encryptedContent = encryptMessage(content) else { return }
        
        let message = [
            "action": "send_message",
            "room_id": roomId,
            "role": role,
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
            sendLogin()
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
                    if role == "guest" {
                        self.sendPublicKey()  // Guest 加入房间后发送公钥
                    }
                }
            case "user_joined":
                if let role = json["role"] as? String,
                   let joinedUserId = json["user_id"] as? String {
                    self.messages.append(Message(content: "Guest has joined the room.", isFromMe: false, isTyping: false, isSystem: true))
                    self.peerUserId = joinedUserId
                    if self.role == "host" {
                        self.sendPublicKey()  // Host 发送公钥给新加入的 Guest
                    }
                }
            case "public_key_exchange", "public_key_response":
                if let userId = json["user_id"] as? String,
                   let publicKeyBase64 = json["public_key"] as? String,
                   let publicKeyData = Data(base64Encoded: publicKeyBase64) {
                    var error: Unmanaged<CFError>?
                    if let peerPublicKey = SecKeyCreateWithData(publicKeyData as CFData,
                                                                [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                                 kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                                                &error) {
                        self.peerPublicKey = peerPublicKey
                        print("Received and set peer public key")
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
                if let role = json["role"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedContent) {
                    self.typingContent = decryptedContent
                }
            case "new_message":
                if let role = json["role"] as? String,
                   let encryptedContent = json["encrypted_content"] as? String,
                   let decryptedContent = self.decryptMessage(encryptedContent) {
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
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack {
                        ForEach(viewModel.messages) { message in
                            if message.isSystem {
                                Text(message.content)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.vertical, 4)
                            } else {
                                MessageView(message: message)
                            }
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
            
            HStack {
                TextField("Type a message", text: $messageText)
                    .focused($isTextFieldFocused)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: messageText) { newValue in
                        viewModel.sendTyping(content: newValue)
                    }.onSubmit {
                        sendMessage()
                    }
                Button("Send") {
                    sendMessage()
                }
            }.padding()
        }
        .navigationBarItems(leading: Text("Room: \(viewModel.roomId)"))
        .navigationBarItems(trailing: Button("Leave") {
            viewModel.leaveRoom()
        })
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
    
    private func sendMessage() {
        //guard !messageText.isEmpty else { return }
        viewModel.sendMessage(content: messageText)
        messageText = ""
        isTextFieldFocused = true // 发送消息后保持输入框焦点
    }
}

struct MessageView: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.isFromMe {
                Spacer()
            }
            Text(message.content)
                .padding()
                .background(message.isFromMe ? Color.green.opacity(message.isTyping ? 0.4 : 1) : Color.blue.opacity(message.isTyping ? 0.4 : 1))
                .foregroundColor(.white)
                .cornerRadius(8)
            if !message.isFromMe {
                Spacer()
            }
        }.padding(.horizontal)
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
