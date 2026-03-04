//
//  WatchContentView.swift
//  UnspokenWatch
//

import SwiftUI

#if os(watchOS)

struct WatchContentView: View {
    @EnvironmentObject var hrManager: HeartRateManager

    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hrManager.isSessionActive ? "heart.fill" : "heart")
                .font(.system(size: 40))
                .foregroundColor(hrManager.isSessionActive ? .red : .gray)
                .scaleEffect(isPulsing ? 1.2 : 1.0)
                .animation(
                    hrManager.isSessionActive
                        ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )
                .onChange(of: hrManager.isSessionActive) { active in
                    isPulsing = active
                }

            if let bpm = hrManager.currentBPM {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(bpm)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("BPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if hrManager.isSessionActive {
                Text("Measuring...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(action: {
                if hrManager.isSessionActive {
                    hrManager.stopSession()
                } else {
                    hrManager.startSession()
                }
            }) {
                Text(hrManager.isSessionActive ? "Stop" : "Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(hrManager.isSessionActive ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .onAppear {
            hrManager.requestAuthorization()
        }
    }
}

#endif // os(watchOS)
