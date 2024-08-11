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
    
    private var socket: WebSocket?
    private let userId: String
    private let recipientId: String
    
    init(userId: String, recipientId: String) {
        self.userId = userId
        self.recipientId = recipientId
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
    }
    
    func openChat() {
        let message = ["action": "open_chat", "recipient_id": recipientId]
        sendJSON(message)
        isChatOpen = true
    }
    
    func closeChat() {
        let message = ["action": "close_chat", "recipient_id": recipientId]
        sendJSON(message)
        isChatOpen = false
    }
    
    func sendTyping(content: String) {
        let message = ["action": "typing", "recipient_id": recipientId, "content": content]
        sendJSON(message)
    }
    
    func sendMessage(content: String) {
        let message = ["action": "send_message", "recipient_id": recipientId, "content": content]
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
        
        switch action {
        case "chat_opened":
            isChatOpen = true
        case "chat_closed":
            isChatOpen = false
        case "typing":
            typingContent = json["content"] as? String ?? ""
        case "new_message":
            if let content = json["content"] as? String {
                messages.append(Message(content: content, isFromMe: false, isTyping: false))
            }
        default:
            break
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var messageText: String = ""
    @State private var typingTask: DispatchWorkItem?
    
    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack {
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
        .onAppear {
            viewModel.openChat()
        }
        .onDisappear {
            viewModel.closeChat()
        }
    }
    
    private func sendMessage() {
        // guard !messageText.isEmpty else { return }
        viewModel.sendMessage(content: messageText)
        messageText = ""
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
}
