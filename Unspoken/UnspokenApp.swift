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
        }
    }
}

struct RoomSelectionView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @Binding var isRoomSelected: Bool
    @State private var inputRoomId: String = ""
    @State private var showingRoomInput = false
    @State private var errorMessage: String?
    @State private var agreeToTerms = true
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Unspoken")
                .font(.largeTitle)
                .padding()
            
            Button(action: {
                if agreeToTerms {
                    createRoom()
                } else {
                    errorMessage = "Please agree to the terms before proceeding."
                }
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
                if agreeToTerms {
                    showingRoomInput = true
                } else {
                    errorMessage = "Please agree to the terms before proceeding."
                }
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
            
            HStack {
                Toggle("", isOn: $agreeToTerms).labelsHidden().scaleEffect(0.6)
                
                Text("By clicking Create or Join,\nyou agree to our ")
                + Text("[EULA](http://unspoken.luy.li/EULA.html)")
                    .foregroundColor(.blue)
                + Text(" and ")
                + Text("[Privacy Policy](http://unspoken.luy.li/Privacy.html)")
                    .foregroundColor(.blue)
            }
            .font(.footnote)
            .padding(.horizontal)
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
