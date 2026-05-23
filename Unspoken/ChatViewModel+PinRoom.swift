//
//  ChatViewModel+PinRoom.swift
//  Unspoken
//

import Foundation
import LocalAuthentication

struct PinnedRoomEntry: Codable, Identifiable, Equatable {
    let roomId: String
    let role: String
    let serverHost: String
    let serverPort: String
    let peerUserId: String?
    let peerPublicKey: Data?

    var id: String { roomId }
}

extension ChatViewModel {

    // MARK: - UserDefaults keys
    fileprivate static let kPinnedRoomsList = "pinnedRoomsList"

    // Legacy single-slot keys (kept for one-time migration only)
    fileprivate static let kLegacyPinnedRoomId        = "pinnedRoomId"
    fileprivate static let kLegacyPinnedRole          = "pinnedRole"
    fileprivate static let kLegacyPinnedServerHost    = "pinnedServerHost"
    fileprivate static let kLegacyPinnedServerPort    = "pinnedServerPort"
    fileprivate static let kLegacyPinnedPeerPublicKey = "pinnedPeerPublicKey"
    fileprivate static let kLegacyPinnedPeerUserId    = "pinnedPeerUserId"

    // MARK: - Storage

    /// Read the raw list from UserDefaults (does not touch published state).
    func readPinnedRoomsFromStorage() -> [PinnedRoomEntry] {
        guard let data = UserDefaults.standard.data(forKey: ChatViewModel.kPinnedRoomsList),
              let entries = try? JSONDecoder().decode([PinnedRoomEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Write to UserDefaults. Only refreshes the published list when the user is unlocked,
    /// so locked sessions never see pinned-room metadata in memory.
    private func writePinnedRoomsToStorage(_ entries: [PinnedRoomEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: ChatViewModel.kPinnedRoomsList)
        }
        if isPinnedListUnlocked {
            DispatchQueue.main.async {
                self.pinnedRoomEntries = entries
            }
        }
    }

    /// Whether there is any saved pinned room (cheap check, no JSON decode needed for hint UI).
    var hasSavedPinnedRoom: Bool {
        guard let data = UserDefaults.standard.data(forKey: ChatViewModel.kPinnedRoomsList) else {
            return false
        }
        // Quick non-empty check via JSON length; empty array encodes as "[]" (2 bytes)
        return data.count > 2
    }

    // MARK: - Biometric Unlock

    /// Authenticate with Face ID / Touch ID, then expose the pinned rooms list to the UI.
    func unlockPinnedRoom() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            print("Biometrics unavailable: \(error?.localizedDescription ?? "Unknown")")
            revealPinnedRoomsList()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock your pinned rooms") { success, authError in
            DispatchQueue.main.async {
                if success {
                    self.revealPinnedRoomsList()
                    print("Pinned rooms list unlocked")
                } else {
                    print("Biometric auth failed: \(authError?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }

    /// Populate the published list and flip the unlock flag. Caller must be on main thread.
    private func revealPinnedRoomsList() {
        self.pinnedRoomEntries = readPinnedRoomsFromStorage()
        self.isPinnedListUnlocked = true
    }

    // MARK: - Per-room actions

    /// Load a specific entry into ViewModel state, ready for joinRoom().
    func loadPinnedRoom(_ entry: PinnedRoomEntry) -> Bool {
        guard loadKeyPair() else { return false }
        self.roomId     = entry.roomId
        self.role       = entry.role
        self.serverHost = entry.serverHost
        self.serverPort = entry.serverPort
        self.isPinned   = true
        self.peerUserId = entry.peerUserId
        if let peerPubData = entry.peerPublicKey {
            var error: Unmanaged<CFError>?
            let attrs: [String: Any] = [
                kSecAttrKeyType  as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            if let peerKey = SecKeyCreateWithData(peerPubData as CFData, attrs as CFDictionary, &error) {
                self.peerPublicKey = peerKey
            }
        } else {
            self.peerPublicKey = nil
        }
        return true
    }

    /// Persist the current room as a pinned entry (append or replace if roomId already exists).
    func savePinnedRoom() {
        var peerKeyData: Data?
        if let peerPubKey = peerPublicKey {
            var error: Unmanaged<CFError>?
            peerKeyData = SecKeyCopyExternalRepresentation(peerPubKey, &error) as Data?
        }
        let entry = PinnedRoomEntry(
            roomId: roomId,
            role: role,
            serverHost: serverHost,
            serverPort: serverPort,
            peerUserId: peerUserId,
            peerPublicKey: peerKeyData
        )
        var entries = readPinnedRoomsFromStorage()
        entries.removeAll { $0.roomId == entry.roomId }
        entries.append(entry)
        writePinnedRoomsToStorage(entries)
        saveKeyPair()
    }

    /// Remove the current room from the pinned list and reset current-room in-memory state.
    func clearPinnedRoom() {
        removePinnedRoomFromStorage(roomId: roomId)
        isPinned           = false
        pinRequestPending  = false
        pinRequestReceived = false
        peerIsOnline       = false
        peerPublicKey      = nil
        peerUserId         = nil
    }

    /// Remove a specific entry from the list (used for peer-initiated unpins of other rooms,
    /// or per-row "Forget" from the selection screen). Does not touch current-room state.
    func removePinnedRoomFromStorage(roomId: String) {
        var entries = readPinnedRoomsFromStorage()
        entries.removeAll { $0.roomId == roomId }
        writePinnedRoomsToStorage(entries)
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: ChatViewModel.kSavedPrivateKey)
            UserDefaults.standard.removeObject(forKey: ChatViewModel.kSavedPublicKey)
        }
    }

    // MARK: - Migration

    /// Migrate the legacy single-slot format into the list. Safe to call on every launch.
    func migrateLegacyPinnedRoomIfNeeded() {
        let defaults = UserDefaults.standard
        guard let oldRoomId = defaults.string(forKey: ChatViewModel.kLegacyPinnedRoomId),
              !oldRoomId.isEmpty,
              let oldRole = defaults.string(forKey: ChatViewModel.kLegacyPinnedRole),
              let oldHost = defaults.string(forKey: ChatViewModel.kLegacyPinnedServerHost),
              let oldPort = defaults.string(forKey: ChatViewModel.kLegacyPinnedServerPort) else {
            return
        }

        var entries = readPinnedRoomsFromStorage()
        if !entries.contains(where: { $0.roomId == oldRoomId }) {
            let entry = PinnedRoomEntry(
                roomId: oldRoomId,
                role: oldRole,
                serverHost: oldHost,
                serverPort: oldPort,
                peerUserId: defaults.string(forKey: ChatViewModel.kLegacyPinnedPeerUserId),
                peerPublicKey: defaults.data(forKey: ChatViewModel.kLegacyPinnedPeerPublicKey)
            )
            entries.append(entry)
            writePinnedRoomsToStorage(entries)
            print("Migrated legacy pinned room \(oldRoomId) into list")
        }

        for k in [ChatViewModel.kLegacyPinnedRoomId, ChatViewModel.kLegacyPinnedRole,
                  ChatViewModel.kLegacyPinnedServerHost, ChatViewModel.kLegacyPinnedServerPort,
                  ChatViewModel.kLegacyPinnedPeerPublicKey, ChatViewModel.kLegacyPinnedPeerUserId] {
            defaults.removeObject(forKey: k)
        }
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
