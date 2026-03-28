//
//  UnspokenApp.swift
//  Unspoken
//
//  Created by Luyang Li on 11/8/24.
//

import SwiftUI

@main
struct UnspokenApp: App {
    @StateObject private var chatViewModel = ChatViewModel()
    @State private var isRoomSelected = false

    var body: some Scene {
        WindowGroup {
            NavigationView {
                if chatViewModel.isChatOpen {
                    ContentView()
                        .environmentObject(chatViewModel)
                } else {
                    RoomSelectionView(isRoomSelected: $isRoomSelected)
                        .environmentObject(chatViewModel)
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .onOpenURL { url in
                handleURL(url)
            }
        }
    }

    private func handleURL(_ url: URL) {
        // unspoken://host:port/room_id
        guard let scheme = url.scheme, scheme == "unspoken",
              let host = url.host,
              !url.path.isEmpty else {
            return
        }

        let port = url.port ?? 8765
        let roomId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !roomId.isEmpty else { return }

        // Update viewModel properties which will be reflected in RoomSelectionView
        chatViewModel.serverHost = host
        chatViewModel.serverPort = String(port)
        chatViewModel.roomId = roomId
        chatViewModel.role = "guest"

        chatViewModel.updateServerAddress(address: host, port: String(port))
        chatViewModel.joinRoom()
    }
}

struct RoomSelectionView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Binding var isRoomSelected: Bool
    @State private var errorMessage: String?
    @State private var agreeToTerms = true
    @State private var isJoining = false
    @State private var isCreating = false
    @State private var showForgetConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.6)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .edgesIgnoringSafeArea(.all)

                ScrollView {
                    VStack(spacing: 24) {
                        Text("Unspoken")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.2), radius: 2, x: 2, y: 2)
                            .onTapGesture(count: 2) {
                                if chatViewModel.hasSavedPinnedRoom && !chatViewModel.isPinned {
                                    chatViewModel.unlockPinnedRoom()
                                }
                            }

                        // Pinned room rejoin section (shown after Face ID unlock)
                        if chatViewModel.isPinned {
                            VStack(spacing: 15) {
                                HStack {
                                    Image(systemName: "pin.fill")
                                        .foregroundColor(.yellow)
                                    Text("Pinned Room: \(chatViewModel.roomId)")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                }

                                Button(action: {
                                    rejoinPinnedRoom()
                                }) {
                                    Text("Rejoin Pinned Room")
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .padding()
                                        .frame(width: min(250, geometry.size.width * 0.6), height: 50)
                                        .background(Color.green.opacity(0.8))
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.white, lineWidth: 2)
                                        )
                                }

                                Button(action: {
                                    showForgetConfirmation = true
                                }) {
                                    Text("Forget Pinned Room")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .alert("Forget Pinned Room?", isPresented: $showForgetConfirmation) {
                                    Button("Forget", role: .destructive) {
                                        chatViewModel.clearPinnedRoom()
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("This will remove all saved room data from this device. You won't be able to rejoin the pinned room.")
                                }
                            }
                            .padding()
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(15)
                            .frame(maxWidth: min(300, geometry.size.width * 0.8))
                        }

                        if !chatViewModel.isPinned {
                            let cardWidth = min(geometry.size.width - 48, 340.0)

                            // Server settings card
                            VStack(spacing: 0) {
                                serverField(icon: "server.rack", label: "Server",
                                            placeholder: "Address", text: $chatViewModel.serverHost)
                                Divider().background(Color.white.opacity(0.25)).padding(.leading, 44)
                                serverField(icon: "network", label: "Port",
                                            placeholder: "Port", text: $chatViewModel.serverPort,
                                            keyboard: .numberPad)
                                #if DEBUG
                                Divider().background(Color.white.opacity(0.25)).padding(.leading, 44)
                                HStack(spacing: 12) {
                                    Image(systemName: "lock")
                                        .frame(width: 20)
                                        .foregroundColor(.white.opacity(0.7))
                                    Text("Use SSL (wss://)")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                    Spacer()
                                    Toggle("", isOn: $chatViewModel.useSSL)
                                        .labelsHidden()
                                        .toggleStyle(SwitchToggleStyle(tint: .green))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                #endif
                            }
                            .background(Color.white.opacity(0.18))
                            .cornerRadius(14)
                            .frame(width: cardWidth)

                            // Room ID + Join
                            HStack(spacing: 10) {
                                TextField("Room ID", text: $chatViewModel.roomId)
                                    .keyboardType(.numberPad)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 12)
                                    .background(Color.white.opacity(0.9))
                                    .cornerRadius(10)
                                    .frame(maxWidth: .infinity, minHeight: 44)

                                Button(action: {
                                    if agreeToTerms {
                                        withAnimation { isJoining = true }
                                        joinRoom(roomId: chatViewModel.roomId)
                                    } else {
                                        errorMessage = "Please agree to the terms before proceeding."
                                    }
                                }) {
                                    Text("Join Room")
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .frame(width: 110, height: 44)
                                        .background(canJoin ? Color.green.opacity(0.8) : Color.gray.opacity(0.5))
                                        .cornerRadius(10)
                                }
                                .disabled(!canJoin)
                                .scaleEffect(isJoining ? 0.93 : 1.0)
                            }
                            .frame(width: cardWidth)

                            // Create Room
                            Button(action: {
                                if agreeToTerms {
                                    withAnimation { isCreating = true }
                                    createRoom()
                                } else {
                                    errorMessage = "Please agree to the terms before proceeding."
                                }
                            }) {
                                Text("Create Room")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .frame(width: cardWidth, height: 50)
                                    .background(canCreate ? Color.blue.opacity(0.85) : Color.gray.opacity(0.5))
                                    .cornerRadius(12)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.4), lineWidth: 1))
                            }
                            .disabled(!canCreate)
                            .scaleEffect(isCreating ? 0.97 : 1.0)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .padding()
                                .background(Color.white.opacity(0.8))
                                .cornerRadius(10)
                        }

                        // EULA
                        HStack(alignment: .center, spacing: 10) {
                            Toggle("", isOn: $agreeToTerms)
                                .labelsHidden()
                                .scaleEffect(0.85)
                                .frame(width: 44, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("By clicking Create or Join, you agree to our")
                                    .foregroundColor(.white.opacity(0.75))
                                HStack(spacing: 4) {
                                    Link("EULA", destination: URL(string: "http://unspoken.luy.li/EULA.html")!)
                                        .foregroundColor(.yellow)
                                    Text("and").foregroundColor(.white.opacity(0.75))
                                    Link("Privacy Policy", destination: URL(string: "http://unspoken.luy.li/Privacy.html")!)
                                        .foregroundColor(.yellow)
                                }
                            }
                            .font(.footnote)
                        }
                        .frame(maxWidth: min(geometry.size.width - 48, 340), alignment: .leading)
                        .padding(.top, 4)

                        VStack(spacing: 2) {
                            Text("To report inappropriate activity, please contact:")
                            Text(verbatim: "bones7456+unspoken@gmail.com")
                        }
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                    }
                    .padding()
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
        .onReceive(chatViewModel.$isChatOpen) { isChatOpen in
            if isChatOpen {
                isRoomSelected = true
            }
        }
    }

    @ViewBuilder
    private func serverField(icon: String, label: String, placeholder: String,
                             text: Binding<String>,
                             keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .padding(.leading, 32) // align with text field (icon width + spacing)
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundColor(.white.opacity(0.7))
                TextField(placeholder, text: text)
                    .keyboardType(keyboard)
                    .foregroundColor(.primary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color.white.opacity(0.9))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var canJoin: Bool {
        return agreeToTerms && chatViewModel.roomId.count >= 4 && chatViewModel.roomId.allSatisfy { $0.isNumber }
    }

    private var canCreate: Bool {
        return agreeToTerms
    }

    private func createRoom() {
        chatViewModel.role = "host"
        chatViewModel.updateServerAddress(address: chatViewModel.serverHost, port: chatViewModel.serverPort)
        chatViewModel.createRoom()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                isCreating = false
            }
        }
    }

    private func joinRoom(roomId: String) {
        guard !roomId.isEmpty else {
            errorMessage = "Room ID cannot be empty"
            return
        }

        chatViewModel.role = "guest"
        chatViewModel.roomId = roomId
        chatViewModel.updateServerAddress(address: chatViewModel.serverHost, port: chatViewModel.serverPort)
        chatViewModel.joinRoom()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                isJoining = false
            }
        }
    }

    private func rejoinPinnedRoom() {
        chatViewModel.updateServerAddress(address: chatViewModel.serverHost, port: chatViewModel.serverPort)
        chatViewModel.joinRoom()
    }
}
