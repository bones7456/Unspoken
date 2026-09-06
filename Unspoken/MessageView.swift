//
//  MessageView.swift
//  Unspoken
//

import SwiftUI

struct MessageView: View {
    let message: Message
    @ObservedObject var voicePlayer: VoiceMessagePlayer
    let onReport: () -> Void
    var showReport: Bool = true
    var showTimestamp: Bool = false
    // The tapped image is looked up by message identity on the ContentView side (it needs the
    // whole conversation's images to page through), so nothing is handed back here.
    var onImageTap: () -> Void = {}
    var onQuote: () -> Void = {}

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/dd HH:mm"; return f
    }()

    private static func formatTimestamp(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        return elapsed < 86400
            ? timeOnlyFormatter.string(from: date)
            : dateTimeFormatter.string(from: date)
    }

    var body: some View {
        Group {
            if message.isSystem {
                HStack {
                    Spacer()
                    Text(message.content)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                    Spacer()
                }
            } else if message.isPendingPlaceholder {
                HStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(.white)
                        let count = Int(message.content) ?? 0
                        Text(count == 1 ? "1 pending message" : "\(count) pending messages")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.purple.opacity(0.5))
                    .cornerRadius(10)
                    Spacer()
                }
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    if message.isFromMe {
                        Spacer()
                        if !message.isTyping {
                            if message.isAcked {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.blue)
                            } else {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .tint(.red)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                    messageBubble
                    if !message.isFromMe { Spacer() }
                    if showTimestamp, let ts = message.timestamp {
                        Text(Self.formatTimestamp(ts))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                            .fixedSize()
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var bubbleColor: Color {
        message.isFromMe
            ? Color.blue.opacity(message.isTyping ? 0.4 : 0.8)
            : Color.purple.opacity(message.isTyping ? 0.4 : 0.8)
    }

    // Inline quote block shown at the top of a bubble
    @ViewBuilder
    private var quoteBlock: some View {
        Group {
            if let q = message.quote {
                switch q.type {
                case "image":
                    if let imgData = q.imageData, let uiImage = UIImage(data: imgData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipped()
                            .cornerRadius(4)
                    } else {
                        EmptyView()
                    }
                case "audio":
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill").font(.caption2)
                        Text(formatVoiceDuration(TimeInterval(q.text ?? "") ?? 0))
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
                default:
                    Text(q.text ?? "")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 3)
                .cornerRadius(1.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.15))
        .cornerRadius(6)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var sharedContextMenu: some View {
        if !message.isTyping {
            Button(action: onQuote) {
                Label("Quote", systemImage: "quote.bubble")
            }
        }
        if !message.isFromMe && showReport {
            Button(role: .destructive, action: onReport) {
                Label("Report User", systemImage: "exclamationmark.triangle")
            }
        }
    }

    // When Report is hidden (e.g. pinned rooms), Quote is the only menu action,
    // so long-press fires it directly instead of showing a single-item menu.
    @ViewBuilder
    private func withMessageInteraction<V: View>(_ content: V) -> some View {
        if showReport {
            content.contextMenu { sharedContextMenu }
        } else {
            content.onLongPressGesture {
                if !message.isTyping { onQuote() }
            }
        }
    }

    @ViewBuilder
    private var messageBubble: some View {
        let hasQuote = message.quote != nil

        if hasQuote {
            withMessageInteraction(
                VStack(alignment: .leading, spacing: 0) {
                    quoteBlock
                    if message.audioData != nil {
                        VoiceBubbleView(message: message, player: voicePlayer)
                    } else if let imgData = message.imageData, let uiImage = UIImage(data: imgData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200)
                            .cornerRadius(6)
                            .onTapGesture { onImageTap() }
                            .padding(6)
                    } else {
                        Text(message.content)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundColor(.white)
                    }
                }
                .background(bubbleColor)
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            )
        } else if message.audioData != nil {
            withMessageInteraction(
                VoiceBubbleView(message: message, player: voicePlayer)
                    .background(bubbleColor)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            )
        } else if let imgData = message.imageData, let uiImage = UIImage(data: imgData) {
            withMessageInteraction(
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                    .onTapGesture { onImageTap() }
            )
        } else {
            withMessageInteraction(
                Text(message.content)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(bubbleColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            )
        }
    }
}

// MARK: - VoiceBubbleView
// Inner content of a voice-message bubble (no background of its own — the caller supplies
// the bubble color). Tapping toggles playback via the shared VoiceMessagePlayer.
private struct VoiceBubbleView: View {
    let message: Message
    @ObservedObject var player: VoiceMessagePlayer

    private var isPlaying: Bool { player.playingId == message.id }
    private var duration: TimeInterval { message.audioDuration ?? 0 }

    var body: some View {
        // Track length scales gently with duration so a 2s clip and a 40s clip look different.
        // Kept long and slim: the bubble is only one text line tall, so width is what carries
        // the "this is a recording" read.
        let trackW = max(60, min(170, 45 + CGFloat(duration) * 4))
        // Sized to sit at the same height as a one-line text bubble — the layout is compact
        // everywhere else, and a voice message shouldn't tower over the words around it.
        HStack(spacing: 6) {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.35)).frame(width: trackW, height: 2.5)
                Capsule().fill(Color.white)
                    .frame(width: trackW * CGFloat(isPlaying ? player.progress : 0), height: 2.5)
            }
            Text(formatVoiceDuration(duration))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let data = message.audioData { player.toggle(id: message.id, data: data) }
        }
    }
}
