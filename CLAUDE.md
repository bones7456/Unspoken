# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Unspoken is an end-to-end encrypted anonymous chat app. This is a mono-repo containing:
- **Unspoken/** — iOS native client (SwiftUI, the primary project)
- **Unspoken-server/** — Python WebSocket server (~600 LOC, single file `unspoken.py`)
- **Unspoken-web/** — Web client (HTML/JS)

## Build & Run

### iOS client
The iOS app uses a standard Xcode project (no CocoaPods/Carthage). Single SPM dependency: **Starscream** (WebSocket client).

```bash
# Open in Xcode
open Unspoken.xcodeproj

# Build from command line
xcodebuild -project Unspoken.xcodeproj -scheme Unspoken -sdk iphonesimulator build
```

- **Deployment target:** iOS 15.0+
- **Bundle ID:** `Senob.Unspoken`
- **No test targets exist** currently

### Server
```bash
cd Unspoken-server
python3 unspoken.py
```
Requires `websockets` and `cryptography` packages. Listens on `0.0.0.0:8765` with TLS (cert paths hardcoded for production).

## Architecture

### iOS client (~1200 LOC across two Swift files, MVVM)

- **`ContentView.swift`** — Contains `ChatViewModel` (ObservableObject), `ContentView`, `MessageView`, and `Message` model. All chat logic, WebSocket handling, encryption, and pin room persistence live here.
- **`UnspokenApp.swift`** — App entry point (`@main`) and `RoomSelectionView`. Handles URL scheme routing (`unspoken://host:port/room_id`) and pinned room rejoin UI.

**State flow:** `ChatViewModel` is created as `@StateObject` in `UnspokenApp` and passed via `@EnvironmentObject` to child views. Navigation switches between `RoomSelectionView` and `ContentView` based on `chatViewModel.isChatOpen`.

### Server (single file `unspoken.py`)

- Global dicts: `connected_users`, `rooms`, `user_public_keys`, `room_role_to_userid`, `pinned_rooms`, `pending_messages`
- `handle_connection()` dispatches all WebSocket actions in a single async for-loop
- `cleanup_user()` handles disconnect cleanup (pinned rooms survive, non-pinned rooms get deleted)
- Persistence files in `data/`: `blocked_users.json`, `pinned_rooms.json`, `pending_messages.json`

## Encryption

Hybrid encryption scheme:
- **RSA-2048** (Security framework / SecKey) for key exchange on room join
- **AES-256-GCM** (CryptoKit) for message encryption
- Public keys exchanged via WebSocket when peers join a room
- For pinned rooms, RSA key pairs are persisted to UserDefaults so the same keys are used across app restarts

## WebSocket Protocol

JSON-based protocol over WSS. See `TECHNICAL_DOCUMENTATION.md` for full protocol spec.

**Core actions:** `login`, `create_room`, `join_room`, `send_message`, `typing`, `report_user`, `leave_room`

**Pin actions:** `request_pin`, `accept_pin`, `reject_pin`, `unpin_room`

**Server-only responses:** `room_created`, `room_joined`, `user_joined`, `user_left`, `room_closed`, `new_message`, `pin_requested`, `pin_accepted`, `pin_rejected`, `room_unpinned`, `peer_status`, `pending_messages`, `error`, `blocked`

## Pin Room Feature

Pinning makes a room persistent — surviving server restarts, app restarts, and offline periods. Requires double consent (one user requests, the other accepts). Max one pinned room per client.

**Key behaviors:**
- **Server:** Pinned rooms are saved to `data/pinned_rooms.json`. When a peer is offline, messages queue to `data/pending_messages.json` and deliver on rejoin. `cleanup_user` / `leave_room` only clear the user's slot (room survives). On startup, `restore_pinned_rooms()` rehydrates all state from disk.
- **Client:** RSA key pair + room metadata (roomId, role, server, peer key/id) saved to UserDefaults. `ChatViewModel.init()` restores pinned state on launch. `RoomSelectionView` shows a "Rejoin Pinned Room" card when pinned (hides create/join UI).
- **UI:** Yellow pin icon + online indicator in chat header. Orange "Leave" (temporary) + red "Unpin" (permanent) buttons. Pin request shown as an alert with Accept/Decline. Input placeholder changes when peer is offline.

## Conventions

- Always use English in git commit messages
- Max one pinned room per client at a time
- iOS client state persistence uses UserDefaults (not Keychain)
- Server persistence uses flat JSON files in `data/` directory
