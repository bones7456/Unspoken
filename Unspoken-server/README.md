# Unspoken Server

The WebSocket server behind the [Unspoken](https://github.com/bones7456/Unspoken) chat app.

It is a pure relay: every message body is encrypted end-to-end by the clients, so the server
routes ciphertext it cannot read and never stores a chat history. A single file, `unspoken.py`.

## Features

- Room-based one-on-one chat over WebSocket (server-generated room ids, host + guest)
- Public key exchange on join, so peers can establish their encrypted channel
- Live relay of typing previews and heart rate
- **Pinned rooms** — a room survives disconnects and server restarts, persisted to disk
- **Offline queue** — messages for an offline peer in a pinned room are queued and delivered
  stop-and-wait on reconnect (one per client `pending_ack`), up to 5 MB each
- **Grace-period unpin** — unpinning with `grace` keeps the room read-only for 7 days so the
  other side can still read the last messages, then destroys it
- **Report & block** — a reported user is disconnected and barred from logging back in
- Automatic cleanup: non-pinned rooms disappear with their host's connection

## Requirements

- Python 3.7+
- `websockets`
- `cryptography`

## Installation

```bash
git clone git@github.com:bones7456/Unspoken.git
cd Unspoken/Unspoken-server
pip install websockets cryptography
```

## Usage

```bash
python3 unspoken.py --no-ssl          # local development, plain ws://
python3 unspoken.py --no-ssl --port 8766
python3 unspoken.py                   # production, wss:// on 8765
```

The server listens on `0.0.0.0:8765` by default.

Without `--no-ssl` it loads a TLS certificate from the hardcoded Let's Encrypt paths near the
bottom of `unspoken.py` (`SSL_CERT` / `SSL_KEY`) — edit those to match your own domain.

## Configuration

| Where | Setting | Default |
| :--- | :--- | :--- |
| `--port` | Listening port | `8765` |
| `--no-ssl` | Serve plain `ws://` instead of `wss://` | off |
| `HOST` in `unspoken.py` | Bind address | `0.0.0.0` |
| `SSL_CERT` / `SSL_KEY` in `unspoken.py` | TLS certificate paths | Let's Encrypt live paths |
| `UNSPOKEN_UNPIN_GRACE_SECONDS` (env) | How long an unpinned room stays readable | `604800` (7 days) |

## Data

Persistent state is written as flat JSON under `data/`, created on first run:

- `pinned_rooms.json` — pinned rooms, their members and public keys
- `pending_messages.json` — queued messages for offline peers
- `blocked_users.json` — reported user ids

Deleting these files resets the server; live (non-pinned) rooms are never written to disk.

## Protocol

JSON messages over WebSocket, each identified by an `action` field. `unspoken.py` is the spec:
the single `handle_connection` dispatch loop is the authoritative list of actions and response
fields.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you
would like to change.
