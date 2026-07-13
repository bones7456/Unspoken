# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Unspoken is an end-to-end encrypted anonymous chat app. This is a mono-repo containing:
- **Unspoken/** — iOS native client (SwiftUI, the primary project)
- **Unspoken-server/** — Python WebSocket server (~700 LOC, single file `unspoken.py`)
- **Unspoken-server-cf/** — Cloudflare Workers + Durable Objects server (TypeScript, protocol-compatible port of `unspoken.py`)
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

### Server (Python, original)
```bash
cd Unspoken-server
python3 unspoken.py
```
Requires `websockets` and `cryptography` packages. Listens on `0.0.0.0:8765` with TLS (cert paths hardcoded for production).

### Server (Cloudflare Workers + Durable Objects)
```bash
cd Unspoken-server-cf
npm install
npm run dev      # local dev at ws://localhost:8787
npm test         # protocol integration test (pass a URL to target another server)
npm run deploy   # deploy to Cloudflare (custom domain: un.luy.li, wss on port 443)
```
See "Cloudflare Server" section below for architecture.

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

### Cloudflare Server (`Unspoken-server-cf/`)

Protocol-compatible TypeScript port of `unspoken.py`. `unspoken.py` is the spec — all actions, response fields, and error strings must stay identical between the two.

- **Deliberately a single Durable Object instance** (`idFromName("main")`, see `src/index.ts`) so room ids stay server-generated and the iOS client needs no changes. This trades away per-room horizontal scaling — equivalent to the original single-VPS model, fine at this app's scale (~1,000 req/s soft limit per DO).
- **`src/server.ts`** — `UnspokenServer` DO class. Uses the WebSocket **Hibernation API** (`ctx.acceptWebSocket`), so DO memory is wiped whenever the object sleeps. Therefore no authoritative in-memory state exists:
  - Connection-scoped state (Python's `connected_users`/`rooms`/`room_role_to_userid`) lives in each socket's **attachment** `{userId, publicKey, rooms: [{roomId, role}]}` and is derived on demand by scanning `ctx.getWebSockets()`.
  - Durable state (Python's `data/*.json`) lives in DO **SQLite**: `blocked_users`, `pinned_rooms`, `pending_meta`/`pending_chunks`/`pending_counter`, `meta` (next_room_id).
- **Pending message chunking**: offline-queued messages (up to 5 MB base64 images) are split into 1,000,000-char rows in `pending_chunks` because SQLite rows cap at 2 MB; reassembled on delivery. Live relay never touches storage.
- **Non-pinned room lifetime == host socket lifetime** (room refs die with their attachments), which matches Python semantics exactly and needs no cleanup sweeps.
- **`test/protocol-test.mjs`** — integration test (17 steps, ~50 assertions) covering the full protocol including pin flow, stop-and-wait pending delivery, chunking, key-mismatch rejection, and report/block. Run it against both servers when changing either: `node test/protocol-test.mjs ws://localhost:8787` (wrangler dev) and `ws://localhost:8766` (`uv run unspoken.py --no-ssl --port 8766`).
- **Deploy**: `npm run deploy`. Custom domain `un.luy.li` (requires the `luy.li` zone on Cloudflare DNS). Client connects with Address=`un.luy.li`, Port=`443`, SSL on — note Cloudflare cannot serve port 8765.

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
- **Client:** RSA key pair + room metadata (roomId, role, server, peer key/id) saved to UserDefaults. Key pair is restored on launch (to keep server-side key consistency), but room metadata requires Face ID / Touch ID to unlock (see below). `RoomSelectionView` shows a "Rejoin Pinned Room" card only after biometric unlock.
- **UI:** Yellow pin icon + online indicator in chat header. Orange "Leave" (temporary) + red "Unpin" (permanent) buttons. Pin request shown as an alert with Accept/Decline. Input placeholder changes when peer is offline.

### Pinned room rejoin — public key validation (server)
When a client rejoins a pinned room (`join_room` on a pinned `room_id`), the server checks the submitted `public_key` against the one stored in `pinned_rooms.json` **before** assigning the room slot or sending `room_joined`:
- **Match (or no key sent):** rejoin proceeds normally.
- **Mismatch:** server responds with `error` ("Key mismatch: your key has changed…") and aborts the rejoin via `continue`.

Rationale: pending messages were encrypted with the stored key. Accepting a new key would make them permanently undecryptable. The client should unpin and start a fresh room if the key is lost.

`save_pinned_rooms()` is called in two places only:
1. `accept_pin` — room first pinned
2. `unpin_room` — room deleted from file

### Face ID / Biometric unlock
Pinned room metadata is protected by biometric authentication (`LocalAuthentication` framework):
- `ChatViewModel.init()` restores saved key pair from UserDefaults (falls back to generating new keys if none saved). Room metadata is NOT loaded at launch.
- `hasSavedPinnedRoom` does a lightweight UserDefaults check (reads only `pinnedRoomId` key) to determine if unlock is available
- Double-tapping the "Unspoken" title in `RoomSelectionView` triggers `unlockPinnedRoom()` when `hasSavedPinnedRoom && !isPinned` (no visible icon)
- `unlockPinnedRoom()` → `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` → on success, `loadPinnedRoom()` restores room metadata, sets `isPinned = true`, and the rejoin UI appears
- Fallback: if biometrics are unavailable (e.g. simulator, no enrolled Face ID), loads directly without auth
- `NSFaceIDUsageDescription` is set in `Info.plist` for the system permission dialog

## Heart Rate Feature

Requires Apple Watch (iPhone has no heart rate sensor; HealthKit is data aggregator only).

### Architecture

```
Watch HKWorkoutSession → HKLiveWorkoutBuilder callback (~1-5s)
    → WCSession.sendMessage(["bpm": X])
    → iPhone WCAdapter.didReceiveMessage → currentBPM updated
    → 3s Timer → sendHeartRate(bpm:) → encrypted WebSocket → peer
    → peer: handleReceivedHeartRate → beatLoop (Taptic Engine)
```

iPhone also runs `HKObserverQuery` as fallback (Watch→HealthKit background sync, every 5-10 min — much less real-time).

### Key State (ChatViewModel)
- `@Published var isHeartRateMode: Bool` — self is currently sending HR
- `@Published var currentBPM: Int?` — own current BPM (from Watch or HealthKit)
- `@Published var peerBPM: Int?` — peer's latest BPM (received via WebSocket)
- `@Published var heartRateModeError: String?` — shown as alert (HealthKit denied, Watch hint)
- `private var hapticLoopActive: Bool` — controls beatLoop lifecycle
- `private var wcAdapter: WCAdapter?` — NSObject wrapper for WCSessionDelegate (ChatViewModel can't inherit NSObject)

### Button display condition
`canUseHeartRateMode = peerPublicKey != nil && peerIsOnline`

Button shown when `canUseHeartRateMode || isHeartRateMode || peerBPM != nil`.
UI layout: `[peerBPM rose-pink] [heart icon] [myBPM red]`
- Peer BPM text and heart icon (receiving-only): `Color(red: 1.0, green: 0.6, blue: 0.8)` (custom rose pink)
- Own BPM text and heart icon (sending): `.red`
- Inactive heart (not sending, not receiving): `.white` outline

`peerIsOnline = true` is set in two places:
- `room_joined` handler: when `peer_public_key` is present (guest joins, host already in room)
- `user_joined` handler: when host receives guest joining
- `peer_status: online` response (pinned rooms)

`peerIsOnline = false` is set in `user_left` handler.

### Start flow (startHeartRateMode)
1. Check `HKHealthStore.isHealthDataAvailable()` → error if false
2. `requestAuthorization` for `.heartRate` → error alert if denied
3. Start `HKObserverQuery` + immediate `fetchLatestHeartRate`
4. On main thread: `isHeartRateMode = true`, schedule 3s timer
5. If Watch reachable: `sendMessage(["action": "start_heart_rate"])`
6. Else if Watch paired: set `heartRateModeError` prompt to open Watch app manually

### Stop flow (stopHeartRateMode(notifyPeer: Bool = true))
- Guard `isHeartRateMode` (no-op if already stopped)
- Set `isHeartRateMode = false`, invalidate timer, clear `currentBPM`, stop HKObserverQuery
- If `notifyPeer`: `sendHeartRate(bpm: -1)` to signal peer
- Always sends `stop_heart_rate` to Watch via WCSession if reachable

### stopPeerHeartRate() — clears received HR state
Sets `hapticLoopActive = false`, `peerBPM = nil` (stops beatLoop and clears peer display).

### sendHeartRate(bpm:)
Encrypts BPM string (or "-1") with peer public key and sends `heart_rate` WebSocket action.
No `canUseHeartRateMode` guard — relies on `encryptMessage` returning nil safely if peer key is gone.
BPM = -1 is the stop signal.

### handleReceivedHeartRate(bpm:)
- If bpm == -1: call `stopPeerHeartRate()`, return
- Else: set `peerBPM = bpm`; if `hapticLoopActive` already, loop reads latest value automatically
- First call: set `hapticLoopActive = true`, create heavy+medium generators, start `beatLoop`

### beatLoop (continuous haptic rhythm)
Recursive `DispatchQueue.asyncAfter` — reads `peerBPM` fresh each cycle:
```
interval = 60.0 / bpm
gap = 0.5 - 0.0021 * bpm   (lub-dub spacing)
heavy.impactOccurred()
→ after gap: medium.impactOccurred()
→ after (interval - gap): beatLoop recurses
```
Stops when `hapticLoopActive == false` or `peerBPM == nil`.

### Cleanup triggers (all call stopPeerHeartRate + stopHeartRateMode(notifyPeer: false))
- `user_left`: peer left non-pinned room
- `room_closed`: host left (guest receives this)
- `peer_status: offline`: peer disconnected from pinned room
- `room_unpinned`: peer force-unpinned

### leaveRoom() cleanup
Calls `stopHeartRateMode()` (notifyPeer: true — sends -1 to peer) then `stopPeerHeartRate()`.

### WCAdapter
`private class WCAdapter: NSObject, WCSessionDelegate` at bottom of ContentView.swift.
Receives `["bpm": X]` from Watch → calls closure → `currentBPM = bpm` on main thread.

### watchOS companion app (UnspokenWatch Watch App/)
- `HeartRateManager.swift`: `NSObject, ObservableObject`; uses `DelegateAdapter: NSObject` for HKWorkoutSession/HKLiveWorkoutBuilder/WCSession delegates
- Receives `start_heart_rate` / `stop_heart_rate` via WCSession → starts/stops `HKWorkoutSession`
- `HKLiveWorkoutBuilderDelegate.workoutBuilder(_:didCollectDataOf:)` → extracts BPM → `sendMessage(["bpm": X])`
- Build config: must NOT have `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` or `SWIFT_APPROACHABLE_CONCURRENCY = YES` (causes ObservableObject conformance failure)
- Requires HealthKit capability + `NSHealthShareUsageDescription` + `NSHealthUpdateUsageDescription` in Watch target

### Server relay (unspoken.py)
`heart_rate` action: same pattern as `typing` — direct relay to peer, no queuing.

## Conventions

- Always use English in git commit messages
- Max one pinned room per client at a time
- iOS client state persistence uses UserDefaults (not Keychain)
- Server persistence uses flat JSON files in `data/` directory
