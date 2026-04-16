//
//  MessageView.swift
//  Unspoken
//

import SwiftUI

struct MessageView: View {
    let message: Message
    let onReport: () -> Void
    var showTimestamp: Bool = false
    var onImageTap: (UIImage) -> Void = { _ in }
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
    private var messageBubble: some View {
        let hasQuote = message.quote != nil
        let sharedContextMenu = Group {
            if !message.isTyping {
                Button(action: onQuote) {
                    Label("Quote", systemImage: "quote.bubble")
                }
            }
            if !message.isFromMe {
                Button(role: .destructive, action: onReport) {
                    Label("Report User", systemImage: "exclamationmark.triangle")
                }
            }
        }

        if hasQuote {
            VStack(alignment: .leading, spacing: 0) {
                quoteBlock
                if let imgData = message.imageData, let uiImage = UIImage(data: imgData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)
                        .cornerRadius(6)
                        .onTapGesture { onImageTap(uiImage) }
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
            .contextMenu { sharedContextMenu }
        } else if let imgData = message.imageData, let uiImage = UIImage(data: imgData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220)
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                .onTapGesture { onImageTap(uiImage) }
                .contextMenu { sharedContextMenu }
        } else {
            Text(message.content)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(bubbleColor)
                .foregroundColor(.white)
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                .contextMenu { sharedContextMenu }
        }
    }
}
