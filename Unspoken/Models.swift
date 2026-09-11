//
//  Models.swift
//  Unspoken
//

import Foundation
import UIKit

// MARK: - QuoteContent

struct QuoteContent {
    let type: String      // "text", "image", "audio" — extensible for future types
    let text: String?     // populated when type == "text"; for "audio" holds duration seconds as string
    let imageData: Data?  // populated when type == "image" (thumbnail)

    static func text(_ s: String) -> QuoteContent { QuoteContent(type: "text", text: s, imageData: nil) }
    static func image(_ d: Data) -> QuoteContent { QuoteContent(type: "image", text: nil, imageData: d) }
    static func audio(_ duration: TimeInterval) -> QuoteContent { QuoteContent(type: "audio", text: String(Int(duration.rounded())), imageData: nil) }

    // Serialize to wire dict — "data" field holds text/duration or base64 depending on type
    var wireDict: [String: String] {
        ["type": type, "data": type == "image" ? (imageData?.base64EncodedString() ?? "") : (text ?? "")]
    }

    static func from(wireDict d: [String: String]) -> QuoteContent? {
        guard let type = d["type"], let data = d["data"] else { return nil }
        switch type {
        case "text":  return .text(data)
        case "image": return Data(base64Encoded: data).map { .image($0) }
        case "audio": return QuoteContent(type: "audio", text: data, imageData: nil)
        default:      return .text(data)   // forward-compatible: unknown types shown as text
        }
    }
}

// MARK: - TranscriptState

/// Where a voice message is in the on-device transcription flow (see VoiceTranscription.swift).
/// Lives only in memory: a transcript is never sent to the peer, never written to UserDefaults,
/// and dies with the room, exactly like the message it belongs to.
enum TranscriptState: Equatable {
    case none                       // never asked for
    case needsDownload(Locale)      // language model not installed yet — needs the user's consent
    case downloading(fraction: Double, elapsed: Int)   // fraction is 0 when unreported
    case running
    case done(String)
    case empty                      // recognised fine, but there was nothing to say
    case failed(String)
}

// MARK: - Message

struct Message: Identifiable {
    let id = UUID()
    let content: String
    let isFromMe: Bool
    let isTyping: Bool
    let isSystem: Bool
    let isPendingPlaceholder: Bool
    let timestamp: Date?
    let imageData: Data?
    // Populated for a voice message (type == "audio"): the AAC/m4a bytes and its duration.
    let audioData: Data?
    let audioDuration: TimeInterval?
    let seq: Int?
    var isAcked: Bool
    // Voice-message transcription (iOS 26+), for both directions. `transcriptExpanded` is kept
    // apart from `transcript` so collapsing the panel doesn't throw away text we already have.
    var transcript: TranscriptState = .none
    var transcriptExpanded: Bool = false
    // At most one layer of quoting; quote holds a text snippet, image thumbnail, or voice duration
    let quote: QuoteContent?

    init(content: String, isFromMe: Bool, isTyping: Bool, isSystem: Bool = false, isPendingPlaceholder: Bool = false, timestamp: Date? = nil, imageData: Data? = nil, audioData: Data? = nil, audioDuration: TimeInterval? = nil, seq: Int? = nil, isAcked: Bool = false, quote: QuoteContent? = nil) {
        self.content = content
        self.isFromMe = isFromMe
        self.isTyping = isTyping
        self.isSystem = isSystem
        self.isPendingPlaceholder = isPendingPlaceholder
        self.timestamp = timestamp
        self.imageData = imageData
        self.audioData = audioData
        self.audioDuration = audioDuration
        self.seq = seq
        self.isAcked = isAcked
        self.quote = quote
    }
}
