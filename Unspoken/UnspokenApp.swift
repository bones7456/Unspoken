//
//  UnspokenApp.swift
//  Unspoken
//
//  Created by Luyang Li on 11/8/24.
//

import SwiftUI

@main
struct UnspokenApp: App {
    @StateObject private var chatViewModel = ChatViewModel(userId: UUID().uuidString)
    @State private var isRoomSelected = false
    
    var body: some Scene {
        WindowGroup {
            if isRoomSelected {
                NavigationView {
                    ContentView()
                        .environmentObject(chatViewModel)
                }
            } else {
                RoomSelectionView(isRoomSelected: $isRoomSelected)
                    .environmentObject(chatViewModel)
            }
        }
    }
}

struct RoomSelectionView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Binding var isRoomSelected: Bool
    @State private var inputRoomId: String = ""
    @State private var showingRoomInput = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Chat App")
                .font(.largeTitle)
                .padding()
            
            Button(action: {
                createRoom()
            }) {
                Text("Create Room")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(width: 200, height: 50)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            
            Button(action: {
                showingRoomInput = true
            }) {
                Text("Join Room")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(width: 200, height: 50)
                    .background(Color.green)
                    .cornerRadius(10)
            }
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .sheet(isPresented: $showingRoomInput) {
            VStack {
                TextField("Enter Room ID", text: $inputRoomId)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                
                Button("Join") {
                    joinRoom(roomId: inputRoomId)
                }
                .padding()
            }
        }
        .onReceive(chatViewModel.$isChatOpen) { isChatOpen in
            if isChatOpen {
                isRoomSelected = true
            }
        }
    }
    
    private func createRoom() {
        chatViewModel.userId = "host"
        chatViewModel.sendLogin()
    }
    
    private func joinRoom(roomId: String) {
        guard !roomId.isEmpty else {
            errorMessage = "Room ID cannot be empty"
            return
        }
        
        chatViewModel.userId = "guest"
        chatViewModel.roomId = roomId
        chatViewModel.sendLogin()
        showingRoomInput = false
    }
}
