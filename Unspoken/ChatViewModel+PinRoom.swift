//
//  ChatViewModel+PinRoom.swift
//  Unspoken
//

import Foundation
import LocalAuthentication
import UIKit

extension ChatViewModel {

    // MARK: - UserDefaults keys (private to this file)
    fileprivate static let kPinnedRoomId       = "pinnedRoomId"
    fileprivate static let kPinnedRole         = "pinnedRole"
    fileprivate static let kPinnedServerHost   = "pinnedServerHost"
    fileprivate static let kPinnedServerPort   = "pinnedServerPort"
    fileprivate static let kPinnedPeerPublicKey = "pinnedPeerPublicKey"
    fileprivate static let kPinnedPeerUserId   = "pinnedPeerUserId"

    // MARK: - Biometric Unlock

    /// Whether there is a saved pinned room in UserDefaults (checked without loading keys)
    var hasSavedPinnedRoom: Bool {
        guard let saved = UserDefaults.standard.string(forKey: ChatViewModel.kPinnedRoomId) else { return false }
        return !saved.isEmpty
    }

    /// Authenticate with Face ID / Touch ID, then load pinned room data
    func unlockPinnedRoom() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            print("Biometrics unavailable: \(error?.localizedDescription ?? "Unknown")")
            _ = loadPinnedRoom()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock your pinned room") { success, authError in
            DispatchQueue.main.async {
                if success {
                    if self.loadPinnedRoom() {
                        print("Pinned room unlocked via biometrics: \(self.roomId)")
                    }
                } else {
                    print("Biometric auth failed: \(authError?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }

    // MARK: - Persistence

    func savePinnedRoom() {
        let defaults = UserDefaults.standard
        defaults.set(roomId,      forKey: ChatViewModel.kPinnedRoomId)
        defaults.set(role,        forKey: ChatViewModel.kPinnedRole)
        defaults.set(serverHost,  forKey: ChatViewModel.kPinnedServerHost)
        defaults.set(serverPort,  forKey: ChatViewModel.kPinnedServerPort)
        defaults.set(peerUserId,  forKey: ChatViewModel.kPinnedPeerUserId)
        if let peerPubKey = peerPublicKey {
            var error: Unmanaged<CFError>?
            if let peerData = SecKeyCopyExternalRepresentation(peerPubKey, &error) as Data? {
                defaults.set(peerData, forKey: ChatViewModel.kPinnedPeerPublicKey)
            }
        }
        saveKeyPair()
    }

    func loadPinnedRoom() -> Bool {
        let defaults = UserDefaults.standard
        guard let savedRoomId = defaults.string(forKey: ChatViewModel.kPinnedRoomId),
              let savedRole   = defaults.string(forKey: ChatViewModel.kPinnedRole),
              let savedHost   = defaults.string(forKey: ChatViewModel.kPinnedServerHost),
              let savedPort   = defaults.string(forKey: ChatViewModel.kPinnedServerPort),
              !savedRoomId.isEmpty else { return false }

        guard loadKeyPair() else { return false }

        self.roomId     = savedRoomId
        self.role       = savedRole
        self.serverHost = savedHost
        self.serverPort = savedPort
        self.isPinned   = true

        if let peerUid = defaults.string(forKey: ChatViewModel.kPinnedPeerUserId) {
            self.peerUserId = peerUid
        }
        if let peerPubData = defaults.data(forKey: ChatViewModel.kPinnedPeerPublicKey) {
            var error: Unmanaged<CFError>?
            let attrs: [String: Any] = [
                kSecAttrKeyType  as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            if let peerKey = SecKeyCreateWithData(peerPubData as CFData, attrs as CFDictionary, &error) {
                self.peerPublicKey = peerKey
            }
        }
        return true
    }

    func clearPinnedRoom() {
        let defaults = UserDefaults.standard
        for key in [ChatViewModel.kPinnedRoomId, ChatViewModel.kPinnedRole,
                    ChatViewModel.kPinnedServerHost, ChatViewModel.kPinnedServerPort,
                    ChatViewModel.kPinnedPeerPublicKey, ChatViewModel.kPinnedPeerUserId,
                    ChatViewModel.kSavedPrivateKey, ChatViewModel.kSavedPublicKey] {
            defaults.removeObject(forKey: key)
        }
        isPinned           = false
        pinRequestPending  = false
        pinRequestReceived = false
        peerIsOnline       = false
        peerPublicKey      = nil
        peerUserId         = nil
    }

    // MARK: - Pin Actions

    func requestPin() {
        sendJSON(["action": "request_pin", "room_id": roomId, "role": role])
        pinRequestPending = true
    }

    func acceptPin() {
        sendJSON(["action": "accept_pin", "room_id": roomId, "role": role])
        pinRequestReceived = false
    }

    func rejectPin() {
        sendJSON(["action": "reject_pin", "room_id": roomId, "role": role])
        pinRequestReceived = false
    }

    func unpinRoom() {
        sendJSON(["action": "unpin_room", "room_id": roomId, "role": role])
        clearPinnedRoom()
        leaveRoom()
    }
}
