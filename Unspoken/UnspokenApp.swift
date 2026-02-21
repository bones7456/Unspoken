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

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.6)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .edgesIgnoringSafeArea(.all)

                ScrollView {
                    VStack(spacing: 30) {
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
                                    chatViewModel.clearPinnedRoom()
                                }) {
                                    Text("Forget Pinned Room")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            .padding()
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(15)
                            .frame(maxWidth: min(300, geometry.size.width * 0.8))
                        }

                        if !chatViewModel.isPinned {
                            VStack(spacing: 15) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Server")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                    HStack {
                                        Image(systemName: "server.rack")
                                            .foregroundColor(.white)
                                        TextField("Address", text: $chatViewModel.serverHost)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                    }
                                }

                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Port")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                    HStack {
                                        Image(systemName: "network")
                                            .foregroundColor(.white)
                                        TextField("Port", text: $chatViewModel.serverPort)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                            .keyboardType(.numberPad)
                                    }
                                }
                            }
                            .frame(maxWidth: min(300, geometry.size.width * 0.8))
                            .padding()
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(15)

                            HStack {
                                TextField("Room ID", text: $chatViewModel.roomId)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(width: min(120, geometry.size.width * 0.3))
                                    .keyboardType(.numberPad)

                                Button(action: {
                                    if agreeToTerms {
                                        withAnimation {
                                            isJoining = true
                                        }
                                        joinRoom(roomId: chatViewModel.roomId)
                                    } else {
                                        errorMessage = "Please agree to the terms before proceeding."
                                    }
                                }) {
                                    Text("Join Room")
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .padding()
                                        .frame(height: 40)
                                        .background(canJoin ? Color.green.opacity(0.8) : Color.gray.opacity(0.5))
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.white, lineWidth: 2)
                                        )
                                }
                                .disabled(!canJoin)
                                .scaleEffect(isJoining ? 0.9 : 1.0)
                            }

                            Button(action: {
                                if agreeToTerms {
                                    withAnimation {
                                        isCreating = true
                                    }
                                    createRoom()
                                } else {
                                    errorMessage = "Please agree to the terms before proceeding."
                                }
                            }) {
                                Text("Create Room")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .padding()
                                    .frame(width: min(200, geometry.size.width * 0.5), height: 50)
                                    .background(canCreate ? Color.blue.opacity(0.8) : Color.gray.opacity(0.5))
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white, lineWidth: 2)
                                    )
                            }
                            .disabled(!canCreate)
                            .scaleEffect(isCreating ? 0.9 : 1.0)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .padding()
                                .background(Color.white.opacity(0.8))
                                .cornerRadius(10)
                        }

                        HStack {
                            Toggle("", isOn: $agreeToTerms)
                                .labelsHidden()
                                .scaleEffect(0.8)

                            Text("By clicking Create or Join, you agree to our ")
                            + Text("[EULA](http://unspoken.luy.li/EULA.html)")
                                .foregroundColor(.yellow)
                            + Text(" and ")
                            + Text("[Privacy Policy](http://unspoken.luy.li/Privacy.html)")
                                .foregroundColor(.yellow)
                        }
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .padding(.top, 4)

                        Text("To report inappropriate activity, please contact us at: bones7456+unspoken@gmail.com")
                            .font(.footnote)
                            .foregroundColor(.gray)
                            .padding(.top, 4)
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
