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
        }
    }
}

struct RoomSelectionView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Binding var isRoomSelected: Bool
    @State private var inputRoomId: String = ""
    @State private var errorMessage: String?
    @State private var agreeToTerms = true
    @State private var serverAddress: String = "18.138.249.97"
    @State private var serverPort: String = "8765"
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
                        
                        VStack(spacing: 15) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Server")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundColor(.white)
                                    TextField("Address", text: $serverAddress)
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
                                    TextField("Port", text: $serverPort)
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
                            TextField("Room ID", text: $inputRoomId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: min(120, geometry.size.width * 0.3))
                                .keyboardType(.numberPad)
                            
                            Button(action: {
                                if agreeToTerms {
                                    withAnimation {
                                        isJoining = true
                                    }
                                    joinRoom(roomId: inputRoomId)
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
                        .foregroundColor(.white)
                        .padding(.horizontal)
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
        return agreeToTerms && inputRoomId.count >= 4 && inputRoomId.allSatisfy { $0.isNumber }
    }
    
    private var canCreate: Bool {
        return agreeToTerms
    }
    
    private func createRoom() {
        chatViewModel.role = "host"
        chatViewModel.createRoom() // 移到这里
        chatViewModel.updateServerAddress(address: serverAddress, port: serverPort)
        
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
        chatViewModel.joinRoom() // 移到这里
        chatViewModel.updateServerAddress(address: serverAddress, port: serverPort)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                isJoining = false
            }
        }
    }
}