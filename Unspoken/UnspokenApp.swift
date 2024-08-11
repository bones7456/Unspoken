//
//  UnspokenApp.swift
//  Unspoken
//
//  Created by Luyang Li on 11/8/24.
//

import SwiftUI

struct UserSelectionView: View {
    @Binding var selectedUserId: String?
    
    var body: some View {
        VStack {
            Text("Select:")
                .font(.title)
                .padding()
            
            HStack(spacing: 50) {
                Button(action: {
                    selectedUserId = "x"
                }) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 100, height: 100)
                        .overlay(Text("X").foregroundColor(.white))
                }
                
                Button(action: {
                    selectedUserId = "bones"
                }) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 100, height: 100)
                        .overlay(Text("Y").foregroundColor(.white))
                }
            }
        }
    }
}

@main
struct UnspokenApp: App {
    @State private var selectedUserId: String?
    
    var body: some Scene {
        WindowGroup {
            if let userId = selectedUserId {
                ContentView(viewModel: ChatViewModel(userId: userId, recipientId: userId == "x" ? "bones" : "x"))
            } else {
                UserSelectionView(selectedUserId: $selectedUserId)
            }
        }
    }
}
