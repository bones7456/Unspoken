# Unspoken — Everything is understood in Unspoken

Unspoken is an end-to-end encrypted, anonymous one-on-one chat app for iOS. It goes beyond traditional messaging by letting you see what the other person is typing in real-time — hesitations, edits, and all.

## Features

- **Real-time typing display** — see what the other person is typing as they type it, in a live preview bubble
- **End-to-end encryption** — RSA-2048 for key exchange, AES-256-GCM for messages; the server never sees plaintext
- **Anonymous** — no account, no phone number, no email required
- **Pinned rooms** — make a room persistent across app restarts and server restarts; messages queue for offline peers and deliver on reconnect
- **Endings that don't cut mid-sentence** — unpinning doesn't yank the room away: it stays readable for 7 days so the other person can finish reading the last messages
- **Image & meme sharing** — send photos from your camera roll or search for memes by keyword
- **Push-to-talk voice** — hold the mic button to talk, release to send. If your peer is offline in a pinned room the voice message simply waits for them
- **Heart rate sharing** — share your live heart rate with your peer via Apple Watch; they feel it as a haptic lub-dub rhythm
- **Connection check** — a Speed Test on the start screen rehearses a whole conversation against the server and tells you in plain words how it will feel: how fast messages land, how long a photo or a voice message takes to send
- **Screenshot protection** — chat content is blocked from screenshots and screen recordings
- **Auto-reconnect** — seamlessly reconnects on Wi-Fi/cellular switching or any other interruption

## How It Works

1. One person creates a room and shares the room link
2. The other person joins via the link
3. Keys are exchanged — an encrypted channel is established
4. Start chatting; what you type appears live on the other person's screen
5. Press Send to commit a message, or just clear it — your choice

## Architecture

```
iOS client (SwiftUI)  ←—— WSS ——→  Python server  ←—— WSS ——→  iOS client (SwiftUI)
```

- **iOS client** — SwiftUI, [Starscream](https://github.com/daltoniam/Starscream) for WebSocket, CryptoKit + Security framework for encryption
- **Server** — single-file Python (~800 LOC), `asyncio` + `websockets`, flat JSON file persistence
- **watchOS companion** — HKWorkoutSession for real-time heart rate, WatchConnectivity to relay BPM to iPhone

## Getting Started

### Use the hosted app

Download Unspoken on the App Store and connect to the default server. The hosted version is a paid app — it supports ongoing server costs and development.

### Self-host

If you prefer to run your own server:

```bash
cd Unspoken-server
pip install websockets cryptography
python3 unspoken.py --no-ssl   # for local development
```

For production, place a TLS certificate at the paths in `unspoken.py` (Let's Encrypt works well) and run without `--no-ssl`.

### Build the iOS client

```bash
open Unspoken.xcodeproj
```

Requires Xcode 15+, iOS 15.0+ deployment target. The only dependency is Starscream, managed via Swift Package Manager.

To point the client at your own server, enter your server address and port on the connection screen, or use the URL scheme:

```
unspoken://your-host:8765/room_id
```

## License

MIT — you are free to use, modify, and redistribute this code, including for commercial purposes, as long as the copyright notice is retained.

The source code is open so that anyone can verify there are no backdoors or hidden data collection. If you have the technical ability, you are encouraged to build and host your own instance. If you'd rather use a ready-made solution, the App Store version connects to a hosted server maintained by the author.
