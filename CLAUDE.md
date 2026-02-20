# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Unspoken is an end-to-end encrypted anonymous chat app. This is a mono-repo containing:
- **Unspoken/** — iOS native client (SwiftUI, the primary project)
- **Unspoken-server/** — Python WebSocket server
- **Unspoken-web/** — Web client (HTML/JS)

## Build & Run

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

## Architecture

The iOS app is ~850 LOC across two Swift files, following MVVM:

- **`ContentView.swift`** — Contains `ChatViewModel` (ObservableObject), `ContentView`, `MessageView`, and `Message` model. This is where all chat logic, WebSocket handling, and encryption live.
- **`UnspokenApp.swift`** — App entry point (`@main`) and `RoomSelectionView`. Handles URL scheme routing (`unspoken://host:port/room_id`).

**State flow:** `ChatViewModel` is created as `@StateObject` in `UnspokenApp` and passed via `@EnvironmentObject` to child views. Navigation switches between `RoomSelectionView` and `ContentView` based on `chatViewModel.isChatOpen`.

## Encryption

Hybrid encryption scheme:
- **RSA-2048** (Security framework / SecKey) for key exchange on room join
- **AES-256-GCM** (CryptoKit) for message encryption
- Public keys exchanged via WebSocket when peers join a room

## WebSocket Protocol

JSON-based protocol over WSS. Key actions: `login`, `create_room`, `join_room`, `send_message`, `typing`, `report_user`. See `TECHNICAL_DOCUMENTATION.md` for full protocol spec.

## Conventions

- Always use English in git commit messages
