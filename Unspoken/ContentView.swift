//
//  ContentView.swift
//  Unspoken
//

import SwiftUI

// MARK: - IdentifiableImage

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - AppAlert
// Single source of truth for all alerts on ContentView. Stacking multiple
// `.alert` modifiers caused orphaned presentation contexts that froze the UI.
private enum AppAlert: Identifiable {
    case blockedWord
    case copySuccess
    case pinRequest
    case heartRate(String)
    case unpinConfirm

    var id: String {
        switch self {
        case .blockedWord:  return "blockedWord"
        case .copySuccess:  return "copySuccess"
        case .pinRequest:   return "pinRequest"
        case .heartRate:    return "heartRate"
        case .unpinConfirm: return "unpinConfirm"
        }
    }
}

// MARK: - New Line menu action
// UIMenuController (deprecated iOS 16 but still works) adds "New Line" to the
// text-selection popup. The action is forwarded via NotificationCenter so the
// UIKit responder chain doesn't need direct access to SwiftUI state.

private extension Notification.Name {
    static let insertNewLine = Notification.Name("Unspoken.insertNewLine")
}

extension UIResponder {
    @objc func unspokenInsertNewLine(_ sender: Any?) {
        NotificationCenter.default.post(name: .insertNewLine, object: nil)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText: String = ""
    @State private var activeAlert: AppAlert?
    @State private var heartPulse: Bool = false
    @State private var bgHeartScale: CGFloat = 1.0
    @State private var showTimestamps: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var showImageSourceDialog: Bool = false
    @State private var showImagePicker: Bool = false
    @State private var imagePickerSource: UIImagePickerController.SourceType = .photoLibrary
    @State private var selectedImage: UIImage? = nil
    @State private var fullScreenImageItem: IdentifiableImage? = nil
    @State private var showMemeSearch: Bool = false
    @State private var quotedMessage: Message? = nil
    @State private var typingDebounceTimer: Timer?
    @State private var insertingNewLine: Bool = false

    var canSendMessage: Bool { viewModel.peerPublicKey != nil }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.4)]),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 0) {
                    chatHeader
                    ScreenshotProtected { chatMessages }
                    inputArea
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(item: $activeAlert) { alert -> Alert in
            switch alert {
            case .blockedWord:
                return Alert(
                    title: Text("Notice"),
                    message: Text("Message contains blocked words. Please modify and try again."),
                    dismissButton: .default(Text("OK"))
                )
            case .copySuccess:
                return Alert(
                    title: Text("Link Copied"),
                    message: Text("Room invitation link has been copied to clipboard."),
                    dismissButton: .default(Text("OK"))
                )
            case .pinRequest:
                return Alert(
                    title: Text("Pin Request"),
                    message: Text("Your peer wants to pin this room. Pinned rooms persist across sessions and support offline messaging. Accept?"),
                    primaryButton: .default(Text("Accept")) { viewModel.acceptPin() },
                    secondaryButton: .cancel(Text("Decline")) { viewModel.rejectPin() }
                )
            case .heartRate(let msg):
                return Alert(
                    title: Text("Heart Rate"),
                    message: Text(msg),
                    dismissButton: .default(Text("OK")) { viewModel.heartRateModeError = nil }
                )
            case .unpinConfirm:
                return Alert(
                    title: Text("Unpin this room?"),
                    message: Text("This will permanently delete the room on both devices and the server, including any pending messages. This cannot be undone."),
                    primaryButton: .destructive(Text("Unpin")) { viewModel.unpinRoom() },
                    secondaryButton: .cancel()
                )
            }
        }
        .onChange(of: viewModel.pinRequestReceived) { newValue in
            if newValue && activeAlert == nil { activeAlert = .pinRequest }
        }
        .onChange(of: viewModel.heartRateModeError) { newValue in
            if let msg = newValue, activeAlert == nil { activeAlert = .heartRate(msg) }
        }
        .confirmationDialog("Send Image", isPresented: $showImageSourceDialog) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { imagePickerSource = .camera; showImagePicker = true }
            }
            Button("Choose from Library") { imagePickerSource = .photoLibrary; showImagePicker = true }
            Button("Send Meme") { showMemeSearch = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showImagePicker, onDismiss: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isTextFieldFocused = true }
        }) {
            ImagePicker(sourceType: imagePickerSource) { image in
                selectedImage = image
                showImagePicker = false
            }
        }
        .onChange(of: selectedImage) { image in
            guard let image else { return }
            selectedImage = nil
            let captured = quotedMessage
            quotedMessage = nil
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = processImageForSending(image) else { return }
                DispatchQueue.main.async { viewModel.sendImage(data, quotedMessage: captured) }
            }
        }
        .sheet(isPresented: $showMemeSearch) {
            let captured = quotedMessage
            MemeSearchView { image in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let data = processImageForSending(image) else { return }
                    DispatchQueue.main.async {
                        viewModel.sendImage(data, quotedMessage: captured)
                        quotedMessage = nil
                    }
                }
            }
        }
        .sheet(item: $fullScreenImageItem) { item in
            ScreenshotProtected {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: item.image).resizable().scaledToFit()
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Chat Header

    var chatHeader: some View {
        HStack {
            if viewModel.isPinned {
                Image(systemName: "pin.fill").foregroundColor(.yellow).font(.caption)
            }
            if viewModel.isReconnecting {
                Text("Reconnecting...").font(.headline).foregroundColor(.yellow)
            } else {
                Text("Room: \(viewModel.roomId)").font(.headline).foregroundColor(.white)
            }
            if viewModel.isPinned {
                Circle()
                    .fill(viewModel.peerIsOnline ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }
            Spacer()

            if !viewModel.isPinned && viewModel.peerPublicKey != nil {
                Button(action: { viewModel.requestPin() }) {
                    Image(systemName: "pin")
                        .foregroundColor(viewModel.pinRequestPending ? .gray : .white)
                }
                .disabled(viewModel.pinRequestPending)
            }

            if viewModel.role == "host" && !viewModel.isPinned {
                Button(action: {
                    let url = "unspoken://\(viewModel.serverHost):\(viewModel.serverPort)/\(viewModel.roomId)"
                    UIPasteboard.general.string = url
                    activeAlert = .copySuccess
                }) {
                    Image(systemName: "link").foregroundColor(.white)
                }
            }

            if viewModel.canUseHeartRateMode || viewModel.isHeartRateMode || viewModel.peerBPM != nil {
                Button(action: {
                    if viewModel.isHeartRateMode { viewModel.stopHeartRateMode() }
                    else { viewModel.startHeartRateMode() }
                }) {
                    HStack(spacing: 3) {
                        if let peerBPM = viewModel.peerBPM {
                            Text("\(peerBPM)").font(.caption.bold())
                                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.8))
                        }
                        Image(systemName: viewModel.isHeartRateMode || viewModel.peerBPM != nil ? "heart.fill" : "heart")
                            .foregroundColor(viewModel.isHeartRateMode ? .red : (viewModel.peerBPM != nil ? Color(red: 1.0, green: 0.6, blue: 0.8) : .white))
                            .scaleEffect(heartPulse ? 1.2 : 1.0)
                            .onChange(of: viewModel.isHeartRateMode) { active in
                                if active {
                                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { heartPulse = true }
                                } else {
                                    withAnimation { heartPulse = false }
                                }
                            }
                        if viewModel.isHeartRateMode, let bpm = viewModel.currentBPM {
                            Text("\(bpm)").font(.caption.bold()).foregroundColor(.red)
                        }
                    }
                }
                .disabled(!viewModel.canUseHeartRateMode)
            }

            Spacer().frame(width: 12)

            if viewModel.isPinned {
                Button(action: { viewModel.leaveRoom() }) {
                    Text("Leave").foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.orange.opacity(0.8)).cornerRadius(8)
                }
                Button(action: { activeAlert = .unpinConfirm }) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                        .padding(6)
                }
            } else {
                Button(action: { viewModel.leaveRoom() }) {
                    Text("Leave").foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.red.opacity(0.8)).cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.2))
    }

    // MARK: - Chat Messages

    var chatMessages: some View {
        ZStack {
            // Background heartbeat animation (receiver side)
            ZStack {
                Image(systemName: "heart.fill").font(.system(size: 220)).foregroundColor(.white).opacity(0.22)
                Image(systemName: "heart.fill").font(.system(size: 185))
                    .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.8)).opacity(0.55)
            }
            .opacity(viewModel.peerBPM != nil ? 1 : 0)
            .scaleEffect(bgHeartScale)
            .animation(.easeInOut(duration: 0.6), value: viewModel.peerBPM != nil)
            .allowsHitTesting(false)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.messages) { message in
                            MessageView(message: message, onReport: {
                                viewModel.reportUser()
                            }, showReport: !viewModel.isPinned, showTimestamp: showTimestamps, onImageTap: { image in
                                fullScreenImageItem = IdentifiableImage(image: image)
                            }, onQuote: {
                                quotedMessage = message
                                isTextFieldFocused = true
                            })
                        }
                        if !viewModel.typingContent.isEmpty {
                            MessageView(
                                message: Message(content: viewModel.typingContent, isFromMe: false, isTyping: true),
                                onReport: { viewModel.reportUser() },
                                showReport: !viewModel.isPinned
                            )
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
                        .onEnded { _ in withAnimation(.easeInOut(duration: 0.2)) { showTimestamps = false } }
                )
                .onChange(of: viewModel.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: viewModel.typingContent) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
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
        .simultaneousGesture(TapGesture().onEnded { isTextFieldFocused = false })
        .onAppear {
            UIMenuController.shared.menuItems = [
                UIMenuItem(title: "New Line", action: #selector(UIResponder.unspokenInsertNewLine(_:)))
            ]
        }
        .onDisappear {
            UIMenuController.shared.menuItems = nil
        }
    }

    // MARK: - Input Area

    var inputArea: some View {
        VStack(spacing: 0) {
            // Quote preview bar
            if let quoted = quotedMessage {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 3, height: 36)
                        .cornerRadius(1.5)
                    if let imgData = quoted.imageData, let uiImage = UIImage(data: imgData) {
                        Image(uiImage: uiImage)
                            .resizable().scaledToFill()
                            .frame(width: 36, height: 36).clipped().cornerRadius(4)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quoted.isFromMe ? "You" : "Peer")
                            .font(.caption.bold()).foregroundColor(.white.opacity(0.85))
                        if quoted.imageData != nil {
                            Text("[Image]").font(.caption).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        } else {
                            Text(quoted.content).font(.caption).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(action: { quotedMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption.bold()).foregroundColor(.white.opacity(0.6)).padding(6)
                    }
                }
                .frame(height: 50)
                .padding(.horizontal, 15)
                .background(Color.white.opacity(0.08))
            }

            HStack(spacing: 6) {
                Button(action: { showImageSourceDialog = true }) {
                    Image(systemName: "photo").foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.2)).clipShape(Circle())
                }
                .disabled(!canSendMessage)

                Group {
                    if #available(iOS 16, *) {
                        TextField(inputPlaceholder, text: $messageText, axis: .vertical)
                            .lineLimit(1...2)
                    } else {
                        TextField(inputPlaceholder, text: $messageText)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.white.opacity(0.2)).cornerRadius(18)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.3), lineWidth: 1))
                .focused($isTextFieldFocused)
                .onChange(of: messageText) { newValue in
                    if newValue.hasSuffix("\n") {
                        if insertingNewLine {
                            // \n came from the "New Line" toolbar button — keep it
                            insertingNewLine = false
                        } else {
                            // \n came from the Return key — strip and send
                            messageText = String(newValue.dropLast())
                            if canSendMessage { sendMessage() }
                            return
                        }
                    }
                    guard canSendMessage else { return }
                    typingDebounceTimer?.invalidate()
                    typingDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                        viewModel.sendTyping(content: newValue)
                    }
                }
                .onSubmit { if canSendMessage { sendMessage() } }
                .disabled(!canSendMessage)
                .onReceive(NotificationCenter.default.publisher(for: .insertNewLine)) { _ in
                    guard canSendMessage else { return }
                    insertingNewLine = true
                    messageText += "\n"
                }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill").foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue).clipShape(Circle())
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSendMessage)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.1))
    }

    private var inputPlaceholder: String {
        if !canSendMessage { return "Waiting for peer to join..." }
        if viewModel.isPinned && !viewModel.peerIsOnline { return "Message (peer offline, will be delivered later)" }
        return "Type a message"
    }

    // iOS app store review requirement
    func canSend(content: String) -> Bool {
        let blockedWords = ["badword1", "badword2", "fuck", "shit", "ass", "asshole", "bastard", "bitch", "damn", "dick", "douche", "fag", "faggot", "hell", "piss", "slut", "whore", "cunt", "crap", "jerk", "balls", "prick", "cock", "wanker", "retard", "moron", "bloody", "bollocks"]
        for word in blockedWords where content.lowercased().contains(word) { return false }
        return true
    }

    private func sendMessage() {
        guard canSend(content: messageText) else { activeAlert = .blockedWord; return }
        if canSendMessage && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.sendMessage(content: messageText, quotedMessage: quotedMessage)
            messageText = ""
            quotedMessage = nil
            isTextFieldFocused = true
        }
    }

    private func clearMessage() { messageText = "" }
}
