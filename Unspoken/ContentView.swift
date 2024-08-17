//
//  ContentView.swift
//  Unspoken
//
//  Created by Luyang Li on 11/8/24.
//

import SwiftUI
import Starscream

class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var typingContent: String = ""
    @Published var isChatOpen: Bool = false
    @Published var roomId: String = ""
    
    private var socket: WebSocket?
    var userId: String
    
    init(userId: String = UUID().uuidString) {
        self.userId = userId
        setupWebSocket()
    }
    
    private func setupWebSocket() {
        let url = URL(string: "ws://13.229.116.205:8765")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }
    
    func sendLogin() {
        let message = ["action": "login", "user_id": userId]
        sendJSON(message)
        print("when sendLogin userId=\(userId), roomId=\(roomId)")
        if userId == "host" {
            createRoom()
        } else if !roomId.isEmpty {
            joinRoom()
        }
    }
    
    func createRoom() {
        let message = ["action": "create_room"]
        sendJSON(message)
    }
    
    func joinRoom() {
        let message = ["action": "join_room", "room_id": roomId]
        sendJSON(message)
        print("when joinRoom userId=\(userId), roomId=\(roomId)")
    }
    
    func leaveRoom() {
        let message = ["action": "leave_room", "room_id": roomId]
        sendJSON(message)
        isChatOpen = false
        roomId = ""
        //messages = []
    }
    
    func sendTyping(content: String) {
        let message = ["action": "typing", "room_id": roomId, "content": content]
        sendJSON(message)
    }
    
    func sendMessage(content: String) {
        let message = ["action": "send_message", "room_id": roomId, "content": content]
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
                if let roomId = json["room_id"] as? String {
                    self.roomId = roomId
                    self.isChatOpen = true
                }
            case "user_joined":
                self.messages.append(Message(content: "Guest has joined the room.", isFromMe: false, isTyping: false, isSystem: true))
            case "user_left":
                self.messages.append(Message(content: "Guest has left the room.", isFromMe: false, isTyping: false, isSystem: true))
            case "room_closed":
                self.messages.append(Message(content: "Host has left the room. The room is closed.", isFromMe: false, isTyping: false, isSystem: true))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.leaveRoom()
                    self.messages = []
                }
            case "typing":
                self.typingContent = json["content"] as? String ?? ""
            case "new_message":
                if let content = json["content"] as? String {
                    self.messages.append(Message(content: content, isFromMe: false, isTyping: false))
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
                .onChange(of: viewModel.messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.typingContent) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            
            HStack {
                TextField("Type a message", text: $messageText)
                    .focused($isTextFieldFocused)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: messageText) { oldValue, newValue in
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
