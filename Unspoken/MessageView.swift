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
    // Voice-message transcription (iOS 26+). One callback rather than four: the bubble knows
    // which button was pressed, the view model knows what to do about it.
    var onTranscriptAction: (TranscriptAction) -> Void = { _ in }
    /// Localized name of the language transcription currently runs in, shown on the chip.
    var transcriptLocaleName: String = ""

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
                        VoiceBubbleView(message: message, player: voicePlayer,
                                        onTranscriptAction: onTranscriptAction,
                                        transcriptLocaleName: transcriptLocaleName)
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
                VoiceBubbleView(message: message, player: voicePlayer,
                                        onTranscriptAction: onTranscriptAction,
                                        transcriptLocaleName: transcriptLocaleName)
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

// MARK: - Transcription

/// Which transcript control the user pressed inside a voice bubble.
enum TranscriptAction {
    case toggle          // the captions button — open/close the panel
    case retry           // after a failure
    case download        // consent to fetch the language model
    case pickLanguage    // open the language picker
}

// MARK: - VoiceBubbleView
// Inner content of a voice-message bubble (no background of its own — the caller supplies
// the bubble color). Tapping toggles playback via the shared VoiceMessagePlayer; the captions
// button opens the on-device transcript panel underneath.
private struct VoiceBubbleView: View {
    let message: Message
    @ObservedObject var player: VoiceMessagePlayer
    var onTranscriptAction: (TranscriptAction) -> Void = { _ in }
    var transcriptLocaleName: String = ""

    private var isPlaying: Bool { player.playingId == message.id }
    private var duration: TimeInterval { message.audioDuration ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            playerRow
            if message.transcriptExpanded {
                // The rule is inside the width-capped stack on purpose: a bare `Divider()` in the
                // outer VStack takes the full proposed width and stretches the whole bubble.
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(height: 0.5)
                    transcriptPanel
                }
                .frame(maxWidth: 240, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: message.transcriptExpanded)
    }

    private var playerRow: some View {
        // Track length scales gently with duration so a 2s clip and a 40s clip look different.
        // Kept long and slim: the bubble is only one text line tall, so width is what carries
        // the "this is a recording" read.
        let trackW = max(60, min(170, 45 + CGFloat(duration) * 4))
        // Sized to sit at the same height as a one-line text bubble — the layout is compact
        // everywhere else, and a voice message shouldn't tower over the words around it.
        return HStack(spacing: 6) {
            // Playback keeps its own hit area so the captions button beside it isn't swallowed
            // by the bubble-wide tap gesture.
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
            .contentShape(Rectangle())
            .onTapGesture {
                if let data = message.audioData { player.toggle(id: message.id, data: data) }
            }

            // Transcription is iOS 26+ only; on older systems the button simply isn't there,
            // so the panel can never be opened.
            if #available(iOS 26.0, *) {
                Button {
                    onTranscriptAction(.toggle)
                } label: {
                    Image(systemName: message.transcriptExpanded ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(message.transcriptExpanded ? 1.0 : 0.65))
                        .padding(.leading, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.transcript {
            case .none, .running:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).tint(.white)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

            case .needsDownload(let locale):
                // The one place this feature touches the network, so it says so plainly —
                // an app sold on privacy shouldn't start a download without explaining it.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download the offline model for \(ChatViewModel.transcriptLocaleName(locale))?")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text("iOS downloads the speech model from Apple — your recording is never uploaded. It takes a couple of minutes, happens once per language, and the model is shared with the system rather than stored in Unspoken.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.75))
                    HStack(spacing: 12) {
                        Button("Download") { onTranscriptAction(.download) }
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Button("Change language") { onTranscriptAction(.pickLanguage) }
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

            case .downloading(let fraction, let elapsed):
                // A real bar when the installer reports progress, a spinner when it doesn't —
                // see downloadAssets. The elapsed clock is always shown, so a stalled percentage
                // still visibly ticks rather than reading as a hung UI.
                VStack(alignment: .leading, spacing: 4) {
                    if fraction > 0 {
                        ProgressView(value: fraction)
                            .tint(.white)
                            .frame(maxWidth: 200)
                        Text("Downloading model… \(Int(fraction * 100))%  ·  \(formatVoiceDuration(TimeInterval(elapsed)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white.opacity(0.85))
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6).tint(.white)
                            Text("Downloading model… \(formatVoiceDuration(TimeInterval(elapsed)))")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.white)
                        }
                    }
                    Text("One-time download, around a minute. You can keep chatting — it carries on in the background.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.75))
                }

            case .done(let text):
                Text(text)
                    .font(.callout)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                languageChip

            case .empty:
                // An empty result is far more often the wrong language than actual silence —
                // the engine is told the language up front and cannot detect it — so the copy
                // points straight at the chip underneath rather than leaving a dead end.
                Text("Nothing recognised. If that's the wrong language, change it below.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                languageChip

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Retry") { onTranscriptAction(.retry) }
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Button("Change language") { onTranscriptAction(.pickLanguage) }
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // The only hint that the language is a choice — and the fix when a transcript comes back
    // as gibberish because the peer was speaking something else.
    private var languageChip: some View {
        Button {
            onTranscriptAction(.pickLanguage)
        } label: {
            HStack(spacing: 3) {
                Text(transcriptLocaleName)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .font(.caption2)
            .foregroundColor(.white.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
