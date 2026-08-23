# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Unspoken is an end-to-end encrypted anonymous chat app. This is a mono-repo containing:
- **Unspoken/** — iOS native client (SwiftUI, the primary project)
- **Unspoken-server/** — Python WebSocket server (~800 LOC, single file `unspoken.py`)
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

### iOS client (~4,000 LOC across 14 Swift files, MVVM)

`ChatViewModel` (ObservableObject) is the single view model. It lives in `ChatViewModel.swift` (core state, message send, room lifecycle) and is split by concern into extensions:
- **`ChatViewModel.swift`** — `@Published` state, `init`, key management, `sendMessage`/`sendImage`/voice send, `retryPendingMessages`, `leaveRoom`.
- **`ChatViewModel+WebSocket.swift`** — `WebSocketDelegate`; `handleMessage` dispatches every server response in one big `switch`.
- **`ChatViewModel+Crypto.swift`** — RSA/AES helpers, `wrapPayload`/`unwrapPayload`, key persistence.
- **`ChatViewModel+PinRoom.swift`** — pin/unpin flow, pinned-room UserDefaults persistence, Face ID unlock.
- **`ChatViewModel+HeartRate.swift`** — heart rate capture/relay/haptics (see "Heart Rate Feature").

Views, models, and utilities:
- **`UnspokenApp.swift`** — `@main`, `RoomSelectionView`, URL-scheme routing (`unspoken://host:port/room_id`), pinned-room rejoin UI.
- **`ContentView.swift`** — chat screen: header, message list, input area (text/image/voice), all alerts via one `AppAlert` enum.
- **`MessageView.swift`** — message bubble rendering (text / image / `VoiceBubbleView`) + quote block.
- **`Models.swift`** — `Message` and `QuoteContent` value types.
- **`VoiceChat.swift`** — voice capture + playback (see "Voice Feature").
- **`ImagePicker.swift`**, **`MemeSearchView.swift`** — image sources; `ScreenshotProtected.swift` — screenshot blocking; **`WCAdapter.swift`** — `WCSessionDelegate` wrapper feeding Watch BPM to `ChatViewModel`.
- **`SpeedTest.swift`**, **`SpeedTestView.swift`** — the "Speed Test" connection check on the selection screen (see "Speed Test").

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
- **Grace-period unpin** is ported (see "Grace-period unpin" below): `pinned_rooms` carries the
  extra `unpinned_by`/`destroy_after` columns (added by an `ALTER TABLE` migration for DOs created
  before the port), and Python's 10-minute purge loop becomes a DO **alarm** armed at the earliest
  `destroy_after`. `UNSPOKEN_UNPIN_GRACE_SECONDS` is read as a Worker var — unset in production
  (7 days); the test suite runs `wrangler dev --var UNSPOKEN_UNPIN_GRACE_SECONDS:3` to exercise expiry.
- **`test/protocol-test.mjs`** — integration test (25 steps, ~79 assertions) covering the full protocol including pin flow, stop-and-wait pending delivery, chunking, key-mismatch rejection, report/block, grace-period unpin, and the `speedtest` action. Run it against both servers when changing either: `node test/protocol-test.mjs ws://localhost:8787` (wrangler dev) and `ws://localhost:8766` (`uv run unspoken.py --no-ssl --port 8766`).
- **Deploy**: `npm run deploy`. Custom domain `un.luy.li` (requires the `luy.li` zone on Cloudflare DNS). Client connects with Address=`un.luy.li`, Port=`443`, SSL on — note Cloudflare cannot serve port 8765.

## Encryption

Hybrid encryption scheme:
- **RSA-2048** (Security framework / SecKey) for key exchange on room join
- **AES-256-GCM** (CryptoKit) for message encryption
- Public keys exchanged via WebSocket when peers join a room
- For pinned rooms, RSA key pairs are persisted to UserDefaults so the same keys are used across app restarts

## WebSocket Protocol

JSON-based protocol over WSS. `Unspoken-server/unspoken.py` is the spec — its single
`handle_connection` dispatch loop is the authoritative list of actions and response fields,
and `Unspoken-server-cf/test/protocol-test.mjs` pins the observable behaviour of both servers.

**Core actions:** `login`, `create_room`, `join_room`, `send_message`, `typing`, `heart_rate`, `pending_ack`, `report_user`, `leave_room`, `speedtest`

**Pin actions:** `request_pin`, `accept_pin`, `reject_pin`, `unpin_room`

**Server-only responses:** `room_created`, `room_joined`, `user_joined`, `user_left`, `room_closed`, `new_message`, `ack`, `pin_requested`, `pin_accepted`, `pin_rejected`, `room_unpinned`, `peer_status`, `pending_message` (singular — one per `pending_ack`), `speedtest_result`, `error`, `failed`, `login_failed`, `blocked`

**Encrypted message payload types** (the `type` field inside the AES-GCM plaintext wrapped by `wrapPayload`/`unwrapPayload`, carried by `send_message`/`new_message`/`pending_message`): `text`, `image`, `audio` (voice message). The server never inspects these — it relays/queues the opaque ciphertext — so voice needed **no server change**. `voice_stream`/`voice_end` are **retired** (live walkie-talkie, removed); the client only ignores them on receive. See "Voice Feature".

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

`save_pinned_rooms()` is called in three places only:
1. `accept_pin` — room first pinned
2. `unpin_room` with `grace` — room marked dying (`unpinned_by` + `destroy_after` persisted)
3. `destroy_room()` — room erased (immediate unpin, or grace period expired)

### Grace-period unpin (dying rooms)
`unpin_room` takes an opt-in `grace` flag. Without it the room is destroyed immediately (what the
report flow and "erase now" rely on). With it the room is not destroyed but marked **dying**:
`unpinned_by` + `destroy_after` are persisted, and the room stays **read-only** for
`UNSPOKEN_UNPIN_GRACE_SECONDS` (7 days by default) so the other side can still read the last
messages and drain its pending queue.

While a room is dying:
- The unpinner cannot rejoin — `error` "You unpinned this room."
- The survivor can rejoin; `room_joined` carries `unpinned: true` + `grace_until`, still reports
  `pending_count` and drains the queue, and `peer_status` is always `offline`.
- `send_message` into it is **dropped but still acked**, so the client never stalls.
- A plain `unpin_room` (no `grace`) from the survivor erases it at once, notifying nobody.
- Expiry destroys it: Python sweeps every 10 min (`purge_expired_rooms_loop`) plus on startup;
  the CF server arms a **Durable Object alarm** at the earliest `destroy_after` instead. Both also
  purge lazily at the top of `join_room`, so an expired room answers "Room not found".

**Client side — farewell state (`ChatViewModel.enterFarewell`)**
A room ending no longer closes the chat screen; the conversation stays on screen read-only.
`FarewellReason` is `.unpinnedByPeer` or `.hostClosed`; `enterFarewell(reason:roomAlive:graceUntil:draining:)`
clears `peerPublicKey` (shuts the sending gate — receiving still works, decryption uses our own
private key), stops heart rate and voice, and appends the reason as a system line.
- `roomAlive: true` (dying room) keeps the socket up so a pending queue can still drain;
  `farewellDraining` arms a **20s** timeout, since an undecryptable message is never acked.
- `roomAlive: false` (room really gone) also freezes reconnect/rejoin and drops the pending placeholder.
Entered from `room_closed`, `room_unpinned`, a rejoin into a dying room (`unpinned` + `grace_until`
on `room_joined`), and a "room not found" error. `ContentView` swaps the input bar for a farewell bar.

### Face ID / Biometric unlock
Pinned room metadata is protected by biometric authentication (`LocalAuthentication` framework):
- `ChatViewModel.init()` restores saved key pair from UserDefaults (falls back to generating new keys if none saved). Room metadata is NOT loaded at launch.
- `hasSavedPinnedRoom` does a lightweight UserDefaults check (reads only `pinnedRoomId` key) to determine if unlock is available
- Double-tapping the "Unspoken" title in `RoomSelectionView` triggers `unlockPinnedRoom()` when `hasSavedPinnedRoom && !isPinned` (no visible icon)
- `unlockPinnedRoom()` → `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` → on success, `loadPinnedRoom()` restores room metadata, sets `isPinned = true`, and the rejoin UI appears
- Fallback: if biometrics are unavailable (e.g. simulator, no enrolled Face ID), loads directly without auth
- `NSFaceIDUsageDescription` is set as `INFOPLIST_KEY_NSFaceIDUsageDescription` in the Xcode build settings (`project.pbxproj`), not in `Unspoken/Info.plist` — the target uses `GENERATE_INFOPLIST_FILE = YES`. Same for `NSHealthShareUsageDescription`/`NSHealthUpdateUsageDescription`; only Camera/Microphone/HealthUpdate live in the checked-in `Info.plist`.

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

`peerIsOnline` is set in one shared block in `ChatViewModel+WebSocket.swift` that handles
`room_joined`/`user_joined` alike, via two branches:
- If the response carries `peer_status` (pinned rooms): `peerIsOnline = (peer_status == "online")`.
- Otherwise (non-pinned join, where presence is implied by the peer key): `peerIsOnline = true`.

`peerIsOnline = false` is set in the `user_left` handler, and in `leaveRoom()`/`enterFarewell()`.

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
gap = max(0.05, 0.5 - 0.0021 * bpm)   (lub-dub spacing, floored so fast rates stay audible)
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
`class WCAdapter: NSObject, WCSessionDelegate` in its own file `Unspoken/WCAdapter.swift`.
Receives `["bpm": X]` from Watch → calls closure → `currentBPM = bpm` on main thread.

### watchOS companion app (UnspokenWatch Watch App/)
- `HeartRateManager.swift`: `NSObject, ObservableObject`; uses `DelegateAdapter: NSObject` for HKWorkoutSession/HKLiveWorkoutBuilder/WCSession delegates
- Receives `start_heart_rate` / `stop_heart_rate` via WCSession → starts/stops `HKWorkoutSession`
- `HKLiveWorkoutBuilderDelegate.workoutBuilder(_:didCollectDataOf:)` → extracts BPM → `sendMessage(["bpm": X])`
- Build config: must NOT have `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` or `SWIFT_APPROACHABLE_CONCURRENCY = YES` (causes ObservableObject conformance failure)
- Requires HealthKit capability + `NSHealthShareUsageDescription` + `NSHealthUpdateUsageDescription` in Watch target

### Server relay (unspoken.py)
`heart_rate` action: same pattern as `typing` — direct relay to peer, no queuing.

## Voice Feature

Push-to-talk (hold the mic button in the input bar) records **one voice message per hold**.
The whole hold is encoded to a single `type: "audio"` payload and sent via `send_message`
**with `seq`** — relayed straight through to an online peer, or queued by the server (pinned
room) and delivered when the peer returns. Either way it renders as a **playable voice bubble**.

Live walkie-talkie streaming (`voice_stream`/`voice_end`) was **removed** after it tested badly
in the field: quality over a real mobile link never justified the complexity. Both servers still
relay whatever the payload is, so nothing server-side changed then or now; the client simply
never sends those types any more, and **ignores them on receive** (`new_message` for a peer
still on an older build, `pending_message` for fragments an older build left in a queue — those
are still `pending_ack`ed so the stop-and-wait queue can drain).

- **Peer online or pinned room → mic button shown**; the message is delivered live or queued.
- **Peer offline + non-pinned → button hidden** (`canUseVoice = peerPublicKey != nil && (peerIsOnline || isPinned)`) — the server would drop it with nowhere to queue it.
- **A peer going offline mid-hold in a pinned room does not abort the recording** — on release it is simply queued (`peer_status: offline` deliberately leaves the capture running).

### Files
- **`Unspoken/VoiceChat.swift`** — four classes + two free helpers (`voiceDurationOf`, `formatVoiceDuration`):
  - `VoiceAudioSession` — process-wide, **reference-counted** owner of the `AVAudioSession`. Capture and playback must never configure the session themselves: they overlap (a received voice message can still be playing when the user starts a new hold), so a `.playback` switch would drop the mic off the route mid-recording and a `setActive(false)` on PTT release would cut a playing bubble short. One `.playAndRecord` + `.defaultToSpeaker` + `.allowBluetooth` + `.mixWithOthers` config is installed by the first `acquire()` and only deactivated when the last holder `release()`s. (`VoiceCapture` releases synchronously in `stop()`, before its async flush, so a quick re-press can't race the release.)
  - `PCMRingBuffer` — fixed-capacity (~2s) mono float ring, the hand-off from the mic tap to the encoder queue. The tap thread is real-time, so it only memcpys into preallocated storage under a short `os_unfair_lock` (priority-donating); multi-channel input is downmixed to mono on the way in so both sides stay a straight memcpy. Overflow drops the oldest samples rather than blocking the tap.
  - `VoiceCapture` — `AVAudioEngine` input tap → `PCMRingBuffer` → AAC/m4a (32 kbps mono). **No encoding or file I/O ever happens on the tap thread**: a `DispatchSourceTimer` on the private `ioQueue` drains the ring ~10x/s and writes to the `AVAudioFile`. `stop(completion:)` flushes the recording and delivers `onFileComplete(data, duration)` on main **before** `completion`.
  - `VoiceMessagePlayer: ObservableObject` — plays one voice-message bubble at a time; `@Published playingId`/`progress` observed by `MessageView`.
- **`Unspoken/Info.plist`** — `NSMicrophoneUsageDescription`.
- **`Models.swift`** — `Message.audioData`/`audioDuration`; `QuoteContent.audio(duration)` (wire `type:"audio"`, data = seconds string).
- **`MessageView.swift`** — `VoiceBubbleView` (play/pause + duration + progress track scaled by duration); takes the shared `VoiceMessagePlayer`. Quote block + compose-time quote preview show `[Voice]`.

### Key state (ChatViewModel)
- `@Published isTalking` — self recording (drives the button state and the "Recording — release to send" banner)
- `@Published voiceError` — mic denied etc., surfaced via the shared `AppAlert` (`.voice` case)
- `talkRequested` (private) — guards the async mic-permission race: the PTT `DragGesture(minimumDistance: 0)` calls `startTalking()` on `.onChanged` and `stopTalking()` on `.onEnded`; if released before the permission callback returns, the callback tears the capture down instead of recording.

### Send / receive (ChatViewModel.swift)
- `startTalking()` — guarded on `peerIsOnline || isPinned`, wires `onFileComplete`, requests mic.
- `stopTalking()` → `voiceCapture.stop`; the bubble is appended by `sendVoiceMessage`, which the flush calls.
- `sendVoiceMessage(data:duration:)` — 5 MB guard, `seq`, appends own bubble. `retryPendingMessages` has an `audio` branch (resent on reconnect like images).
- `abortVoiceCapture()` — tear down mid-hold **without** emitting, for when there is no longer anywhere to send it.

### Cleanup triggers
`user_left`, `room_closed` / `enterFarewell`, `leaveRoom` → `abortVoiceCapture()` (+ `voiceMessagePlayer.stop()` in `leaveRoom`). `peer_status: offline` deliberately does **not** abort — see above.

### Cross-client note
`Unspoken-web` does not yet play `audio` (its fallback renders base64 as text) — voice is iOS↔iOS only for now.

## Speed Test

A "Speed Test" button on `RoomSelectionView` opens `SpeedTestView`, which runs one connection
check against the server configured in the fields above it and answers a non-technical
question: *will this connection be good enough to chat on?*

### Protocol: the `speedtest` action (both servers)
Deliberately stateless — no room, no peer, no persistence, nothing encrypted. The server just
bounces opaque payloads so the client can time them:

```
→ {"action":"speedtest", "seq":N, "mode":"echo"|"upload"|"download", "payload":"…", "size":N}
← {"action":"speedtest_result", "seq":N, "size":<chars received>, "payload":"…"}
```
- `echo` returns the payload (a round trip: a text message, a voice segment)
- `upload` absorbs it and answers with `size` only (sending a photo)
- `download` ignores `payload` and generates `size` characters (receiving a photo)

Guards, identical in `unspoken.py` and `server.ts`: login required (an unauthenticated
`speedtest` is silently ignored), 256 KB per message (`error` "Speed test payload too large."),
and a 16 MB up+down budget per connection (`error` "Speed test quota exceeded."). `payload` is
in both servers' log-truncation key sets. Payload filler is random on both ends so a
compressing transport can't fake the numbers.

### Client (`SpeedTest.swift`)
`SpeedTestRunner` opens **its own** WebSocket (never `ChatViewModel`'s, so a live chat is
untouched) and runs three steps on a private queue, publishing `phase`/`progress` to the sheet:
1. **messages** — 6 sequential 96-char echoes; median / best / jitter, first sample dropped as warm-up.
2. **sendingPhoto** / 3. **receivingPhoto** — 64 KB chunks, 4 in flight, until 3 s or 1 MB per
   direction. Throughput is timed from the *first* arrival and excludes that chunk, so a fast
   link isn't scored on its round-trip latency. Whole run costs ~2.1 MB.

There is no voice step: with live walkie-talkie gone, a voice message is just a small upload, so
the voice line on the result screen is **derived** from `uploadKBps` (`voiceWireKBPerSecond`, 32 kbps
AAC + base64) and graded against its own length rather than measured separately.
`SpeedTestReport` holds only raw measurements; every sentence and grade shown is derived from
them there (`plainFindings`, `headline`, `grade`), so wording and numbers can't drift apart.
The overall grade is the **worst** of latency / speed (voice is left out — it is derived from the
same upload speed and is never the binding limit). A first probe that times out is
reported as "this server is running an older version that has no speed test" — the one case
where a pre-`speedtest` server is distinguishable from a dead one.

## Conventions

- Always use English in git commit messages
- Max one pinned room per client at a time
- iOS client state persistence uses UserDefaults (not Keychain)
- Server persistence uses flat JSON files in `data/` directory
