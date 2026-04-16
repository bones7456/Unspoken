//
//  ChatViewModel+Crypto.swift
//  Unspoken
//

import Foundation
import CryptoKit

extension ChatViewModel {

    // MARK: - UserDefaults keys
    static let kSavedPrivateKey = "savedPrivateKey"
    static let kSavedPublicKey  = "savedPublicKey"

    // MARK: - Key Generation & Persistence

    func generateKeyPair() {
        print("start to generateKeyPair...")
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let pubKey = SecKeyCopyPublicKey(privKey) else {
            print("Failed to generate key pair: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            return
        }
        self.privateKey = privKey
        self.publicKey = pubKey
    }

    func saveKeyPair() {
        guard let privateKey = privateKey, let publicKey = publicKey else { return }
        var error: Unmanaged<CFError>?
        if let privData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? {
            UserDefaults.standard.set(privData, forKey: ChatViewModel.kSavedPrivateKey)
        }
        if let pubData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? {
            UserDefaults.standard.set(pubData, forKey: ChatViewModel.kSavedPublicKey)
        }
    }

    func loadKeyPair() -> Bool {
        guard let privData = UserDefaults.standard.data(forKey: ChatViewModel.kSavedPrivateKey),
              let pubData  = UserDefaults.standard.data(forKey: ChatViewModel.kSavedPublicKey) else { return false }

        let privAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        let pubAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateWithData(privData as CFData, privAttrs as CFDictionary, &error) else {
            print("Failed to restore private key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
            return false
        }
        guard let pubKey = SecKeyCreateWithData(pubData as CFData, pubAttrs as CFDictionary, &error) else {
            print("Failed to restore public key: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
            return false
        }
        self.privateKey = privKey
        self.publicKey = pubKey
        return true
    }

    func getPublicKeyBase64() -> String? {
        guard let publicKey = publicKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Encryption / Decryption

    func encryptMessage(_ message: String) -> (String, String)? {
        guard let peerPublicKey = peerPublicKey else {
            print("Peer public key not available")
            return nil
        }
        let aesKey = SymmetricKey(size: .bits256)
        let aesKeyData = aesKey.withUnsafeBytes { Data($0) }

        guard let messageData = message.data(using: .utf8) else { return nil }
        let encryptedMessage = try? AES.GCM.seal(messageData, using: aesKey).combined

        var error: Unmanaged<CFError>?
        guard let encryptedAESKey = SecKeyCreateEncryptedData(peerPublicKey,
                                                              .rsaEncryptionOAEPSHA256,
                                                              aesKeyData as CFData,
                                                              &error) as Data? else {
            print("AES key encryption failed: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
            return nil
        }
        return (encryptedAESKey.base64EncodedString(), encryptedMessage?.base64EncodedString() ?? "")
    }

    func decryptMessage(encryptedAESKey: String, encryptedMessage: String) -> String? {
        guard let privateKey = privateKey else {
            print("Private key not available")
            return nil
        }
        guard let encryptedAESKeyData  = Data(base64Encoded: encryptedAESKey),
              let encryptedMessageData = Data(base64Encoded: encryptedMessage) else {
            print("Failed to decode base64 encrypted data")
            return nil
        }
        var error: Unmanaged<CFError>?
        guard let decryptedAESKeyData = SecKeyCreateDecryptedData(privateKey,
                                                                  .rsaEncryptionOAEPSHA256,
                                                                  encryptedAESKeyData as CFData,
                                                                  &error) as Data? else {
            print("AES key decryption failed: \(error?.takeRetainedValue().localizedDescription ?? "Unknown")")
            return nil
        }
        let aesKey = SymmetricKey(data: decryptedAESKeyData)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedMessageData),
              let decryptedData = try? AES.GCM.open(sealedBox, using: aesKey) else {
            print("Message decryption failed")
            return nil
        }
        return String(data: decryptedData, encoding: .utf8)
    }

    // MARK: - Payload Wrapping

    func wrapPayload(type: String, data: String, quote: QuoteContent? = nil) -> String {
        var obj: [String: Any] = ["type": type, "data": data]
        if let quote { obj["quote"] = quote.wireDict }
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) { return s }
        return data
    }

    func unwrapPayload(_ plaintext: String) -> (type: String, data: String, quote: QuoteContent?) {
        if let d   = plaintext.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let type = obj["type"] as? String,
           let data = obj["data"] as? String {
            let quote = (obj["quote"] as? [String: String]).flatMap(QuoteContent.from)
            return (type, data, quote)
        }
        return ("text", plaintext, nil)  // legacy fallback
    }
}
