//
//  Models.swift
//  Unspoken
//

import Foundation
import UIKit

// MARK: - QuoteContent

struct QuoteContent {
    let type: String      // "text", "image" — extensible for future types
    let text: String?     // populated when type == "text"
    let imageData: Data?  // populated when type == "image" (thumbnail)

    static func text(_ s: String) -> QuoteContent { QuoteContent(type: "text", text: s, imageData: nil) }
    static func image(_ d: Data) -> QuoteContent { QuoteContent(type: "image", text: nil, imageData: d) }

    // Serialize to wire dict — "data" field holds text or base64 depending on type
    var wireDict: [String: String] {
        ["type": type, "data": type == "image" ? (imageData?.base64EncodedString() ?? "") : (text ?? "")]
    }

    static func from(wireDict d: [String: String]) -> QuoteContent? {
        guard let type = d["type"], let data = d["data"] else { return nil }
        switch type {
        case "text":  return .text(data)
        case "image": return Data(base64Encoded: data).map { .image($0) }
        default:      return .text(data)   // forward-compatible: unknown types shown as text
        }
    }
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
    let seq: Int?
    var isAcked: Bool
    // At most one layer of quoting; quote holds a text snippet or image thumbnail
    let quote: QuoteContent?

    init(content: String, isFromMe: Bool, isTyping: Bool, isSystem: Bool = false, isPendingPlaceholder: Bool = false, timestamp: Date? = nil, imageData: Data? = nil, seq: Int? = nil, isAcked: Bool = false, quote: QuoteContent? = nil) {
        self.content = content
        self.isFromMe = isFromMe
        self.isTyping = isTyping
        self.isSystem = isSystem
        self.isPendingPlaceholder = isPendingPlaceholder
        self.timestamp = timestamp
        self.imageData = imageData
        self.seq = seq
        self.isAcked = isAcked
        self.quote = quote
    }
}
