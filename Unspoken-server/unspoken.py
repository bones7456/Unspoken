# /// script
# dependencies = [
#   "websockets",
#   "cryptography",
# ]
# ///

import asyncio
import websockets
import json
import time
import uuid
import ssl
import base64
from datetime import datetime
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes
import os

next_room_id = 1000  # 从1000开始的房间号
connected_users = {} # 存储用户连接
rooms = {} # 存储房间信息
user_public_keys = {}  # 存储用户公钥
room_role_to_userid = {}  # 存储 room+role 和 userid 的对应关系
# { room_id: { host_user_id, guest_user_id, host_public_key, guest_public_key,
#              unpinned_by?, destroy_after? } }
# unpinned_by/destroy_after are only present while a room is "dying" — see is_dying().
pinned_rooms = {}
pending_messages = {}  # { room_id: { "for_host": [...], "for_guest": [...] } }

# How long an unpinned room survives read-only so the other side can still read the last
# messages (and drain its pending queue) before everything is destroyed. Overridable for tests.
UNPIN_GRACE_SECONDS = int(os.environ.get('UNSPOKEN_UNPIN_GRACE_SECONDS', 7 * 24 * 3600))
PURGE_INTERVAL_SECONDS = 600

# Speed test ('speedtest' action): the client's Speed Test screen measures latency and
# throughput by bouncing opaque payloads off the server. It never touches rooms, keys or
# storage — payloads are echoed, absorbed, or generated and immediately forgotten.
SPEEDTEST_MAX_PAYLOAD = 256 * 1024          # per message, in characters
SPEEDTEST_MAX_BYTES_PER_CONN = 16 * 1024 * 1024   # up+down budget for one connection

# 确保存储目录存在
os.makedirs('data', exist_ok=True)
BLOCKED_USERS_FILE = 'data/blocked_users.json'
PINNED_ROOMS_FILE = 'data/pinned_rooms.json'
PENDING_MESSAGES_FILE = 'data/pending_messages.json'

# 加载被封禁用户列表
def load_blocked_users():
    try:
        with open(BLOCKED_USERS_FILE, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        return []

# 保存被封禁用户列表
def save_blocked_users(blocked_users):
    with open(BLOCKED_USERS_FILE, 'w') as f:
        json.dump(blocked_users, f)

def load_pinned_rooms():
    global pinned_rooms
    try:
        with open(PINNED_ROOMS_FILE, 'r') as f:
            pinned_rooms = json.load(f)
    except FileNotFoundError:
        pinned_rooms = {}

def save_pinned_rooms():
    with open(PINNED_ROOMS_FILE, 'w') as f:
        json.dump(pinned_rooms, f)

def load_pending_messages():
    global pending_messages
    try:
        with open(PENDING_MESSAGES_FILE, 'r') as f:
            pending_messages = json.load(f)
    except FileNotFoundError:
        pending_messages = {}

def save_pending_messages():
    with open(PENDING_MESSAGES_FILE, 'w') as f:
        json.dump(pending_messages, f)

def is_pinned(room_id):
    return room_id in pinned_rooms

def is_dying(room_id):
    """True for a room unpinned with grace: kept read-only until destroy_after passes."""
    return pinned_rooms.get(room_id, {}).get('destroy_after') is not None

def iso_utc(ts):
    return datetime.utcfromtimestamp(ts).strftime('%Y-%m-%dT%H:%M:%SZ')

def destroy_room(room_id):
    """Erase every trace of a room: pinned entry, pending queue, live room, role mappings."""
    pinned_rooms.pop(room_id, None)
    pending_messages.pop(room_id, None)
    rooms.pop(room_id, None)
    for r in ('host', 'guest'):
        room_role_to_userid.pop(f"{room_id}:{r}", None)
    save_pinned_rooms()
    save_pending_messages()

def purge_room_if_expired(room_id):
    """Destroy a dying room whose grace period has run out. Returns True if it was destroyed."""
    info = pinned_rooms.get(room_id)
    if info and info.get('destroy_after') is not None and info['destroy_after'] <= time.time():
        destroy_room(room_id)
        log_message("SYSTEM", "Server", f"Room {room_id} grace period expired, destroyed")
        return True
    return False

def purge_expired_rooms():
    for room_id in list(pinned_rooms.keys()):
        purge_room_if_expired(room_id)

async def purge_expired_rooms_loop():
    while True:
        await asyncio.sleep(PURGE_INTERVAL_SECONDS)
        purge_expired_rooms()

def restore_pinned_rooms():
    """On startup, restore pinned rooms into the rooms dict."""
    global next_room_id
    for room_id, info in pinned_rooms.items():
        if room_id not in rooms:
            rooms[room_id] = {
                'host': None,
                'guest': None,
                'messages': [],
                'pinned': True
            }
        # Restore public keys
        if info.get('host_public_key'):
            user_public_keys[info['host_user_id']] = info['host_public_key']
        if info.get('guest_public_key'):
            user_public_keys[info['guest_user_id']] = info['guest_public_key']
        # Ensure next_room_id is above any pinned room
        try:
            rid = int(room_id)
            if rid >= next_room_id:
                next_room_id = rid + 1
        except ValueError:
            pass
    # Also ensure pending_messages has entries for all pinned rooms
    for room_id in pinned_rooms:
        if room_id not in pending_messages:
            pending_messages[room_id] = {"for_host": [], "for_guest": [], "next_id": 0}
        # Migrate existing messages that predate pending_msg_id
        entry = pending_messages[room_id]
        if "next_id" not in entry:
            entry["next_id"] = 0
        for queue_key in ("for_host", "for_guest"):
            for msg in entry.get(queue_key, []):
                if "pending_msg_id" not in msg:
                    msg["pending_msg_id"] = entry["next_id"]
                    entry["next_id"] += 1
    save_pending_messages()

async def send_next_pending(websocket, user_id, room_id, role):
    """Send the head of the user's pending queue (stop-and-wait: next one goes out on ack)."""
    queue_key = f"for_{role}"
    queue = pending_messages.get(room_id, {}).get(queue_key, [])
    if not queue:
        return
    msg = queue[0]
    notification = json.dumps({
        'action': 'pending_message',
        'room_id': room_id,
        'pending_msg_id': msg['pending_msg_id'],
        'encrypted_aes_key': msg['encrypted_aes_key'],
        'encrypted_content': msg['encrypted_content'],
        'timestamp': msg.get('timestamp'),
        'pending_count': len(queue) - 1
    })
    await websocket.send(notification)
    log_message("SENT", user_id, f"Delivered pending msg {msg['pending_msg_id']} ({len(queue) - 1} remaining)")

_TRUNCATE_KEYS = {"encrypted_content", "encrypted_aes_key", "public_key", "peer_public_key", "host_public_key", "guest_public_key", "payload"}
_TRUNCATE_LEN = 16

def _format_log_payload(message):
    """Format a JSON message string for logging, truncating large fields."""
    try:
        data = json.loads(message)
        parts = []
        for k, v in data.items():
            if k in _TRUNCATE_KEYS and isinstance(v, str) and len(v) > _TRUNCATE_LEN:
                parts.append(f"{k}={v[:_TRUNCATE_LEN]}…({len(v)}B)")
            else:
                parts.append(f"{k}={json.dumps(v, ensure_ascii=False)}")
        return "{" + ", ".join(parts) + "}"
    except (json.JSONDecodeError, AttributeError):
        return message

def log_message(direction, user_id, message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if direction == "SYSTEM":
        print(f"[{timestamp}] || {user_id}: {message}")
    else:
        symbol = ">>" if direction == "RECEIVED" else "<<"
        print(f"[{timestamp}] {symbol} {user_id}: {_format_log_payload(message)}")

async def check_available_user_in_data(data, websocket):
    if 'user_id' in data and data['user_id'] not in load_blocked_users():
        return True
    response = json.dumps({
        'action': 'failed',
        'message': 'Your account has been blocked due to violations.'
    })
    await websocket.send(response)
    return False

def speedtest_payload(n):
    """n characters of incompressible filler, so a compressing transport can't fake the result."""
    raw = base64.b64encode(os.urandom(n * 3 // 4 + 3)).decode('ascii')   # 3 bytes -> 4 chars
    return raw[:n]

async def handle_connection(websocket):
    user_id = None
    speedtest_bytes = 0   # per-connection speed-test budget, see SPEEDTEST_MAX_BYTES_PER_CONN
    try:
        async for message in websocket:
            log_message("RECEIVED", user_id or "Unknown", message)
            data = json.loads(message)
            action = data.get('action')

            if action == 'login':
                user_id = data['user_id']
                # 检查用户是否被封禁
                if user_id in load_blocked_users():
                    response = json.dumps({
                        'action': 'login_failed',
                        'message': 'Your account has been blocked due to violations.'
                    })
                    await websocket.send(response)
                    log_message("SYSTEM", "Server", f"Blocked user {user_id} attempted to login")
                    continue

                connected_users[user_id] = websocket
                public_key_pem = data.get('public_key', '')
                if len(public_key_pem) > 8192:
                    log_message("SYSTEM", "Server", f"User {user_id} sent oversized public key ({len(public_key_pem)}B), rejected")
                    continue
                user_public_keys[user_id] = public_key_pem
                client_version = data.get('client_version', 'unknown')
                log_message("SYSTEM", "Server", f"User {user_id} logged in (v{client_version})")

            elif action == 'create_room':
                if not await check_available_user_in_data(data, websocket):
                    log_message("SYSTEM", "Server", f"Blocked user {user_id} attempted to create room")
                    continue
                user_room_count = sum(1 for r in rooms.values() if r.get('host') == user_id)
                if user_room_count >= 3:
                    error_message = json.dumps({'action': 'error', 'message': 'Too many active rooms. Please close existing rooms first.'})
                    await websocket.send(error_message)
                    log_message("SENT", user_id, error_message)
                    continue
                global next_room_id
                room_id = str(next_room_id)
                next_room_id += 1
                rooms[room_id] = {'host': user_id, 'guest': None, 'messages': [], 'pinned': False}
                room_role_to_userid[f"{room_id}:host"] = user_id
                response = json.dumps({
                    'action': 'room_created',
                    'room_id': room_id,
                    'role': 'host',
                    'pinned': False
                })
                await websocket.send(response)
                log_message("SENT", user_id, response)

            elif action == 'join_room':
                if not await check_available_user_in_data(data, websocket):
                    log_message("SYSTEM", "Server", f"Blocked user {user_id} attempted to join room")
                    continue
                room_id = data['room_id']
                # A dying room whose grace period elapsed is destroyed here, so the rejoin
                # falls through to the regular "Room not found" answer below.
                purge_room_if_expired(room_id)

                # Pinned room rejoin
                if is_pinned(room_id):
                    pin_info = pinned_rooms[room_id]
                    # Determine which role this user has in the pinned room
                    rejoin_role = None
                    if pin_info['host_user_id'] == user_id:
                        rejoin_role = 'host'
                    elif pin_info['guest_user_id'] == user_id:
                        rejoin_role = 'guest'

                    if rejoin_role and rejoin_role == pin_info.get('unpinned_by'):
                        # The side that unpinned it doesn't get to come back during the grace period.
                        error_message = json.dumps({
                            'action': 'error',
                            'message': 'You unpinned this room.'
                        })
                        await websocket.send(error_message)
                        log_message("SENT", user_id, error_message)
                        continue

                    if rejoin_role:
                        # Reject rejoin if client presents a different public key —
                        # pending messages were encrypted with the stored key and would be undecryptable.
                        if 'public_key' in data:
                            stored_key = pin_info.get(f'{rejoin_role}_public_key', '')
                            if stored_key and data['public_key'] != stored_key:
                                error_message = json.dumps({
                                    'action': 'error',
                                    'message': 'Key mismatch: your key has changed and no longer matches this pinned room. Please unpin and start a new room.'
                                })
                                await websocket.send(error_message)
                                log_message("SENT", user_id, error_message)
                                continue

                        # Assign user back into room slot
                        if room_id not in rooms:
                            rooms[room_id] = {'host': None, 'guest': None, 'messages': [], 'pinned': True}
                        rooms[room_id][rejoin_role] = user_id
                        room_role_to_userid[f"{room_id}:{rejoin_role}"] = user_id

                        other_role = 'guest' if rejoin_role == 'host' else 'host'
                        peer_user_id = pin_info[f'{other_role}_user_id']
                        peer_public_key = pin_info[f'{other_role}_public_key']
                        dying = is_dying(room_id)
                        # A dying room's peer unpinned and is never coming back: always offline.
                        peer_online = (not dying) and peer_user_id in connected_users and rooms[room_id][other_role] is not None

                        # Send room_joined to the rejoining user
                        queue_key_preview = f"for_{rejoin_role}"
                        pending_count = len(pending_messages.get(room_id, {}).get(queue_key_preview, []))
                        payload = {
                            'action': 'room_joined',
                            'room_id': room_id,
                            'role': rejoin_role,
                            'peer_role': other_role,
                            'peer_user_id': peer_user_id,
                            'peer_public_key': peer_public_key,
                            'pinned': True,
                            'peer_status': 'online' if peer_online else 'offline',
                            'pending_count': pending_count
                        }
                        if dying:
                            payload['unpinned'] = True
                            payload['grace_until'] = iso_utc(pin_info['destroy_after'])
                        response = json.dumps(payload)
                        await websocket.send(response)
                        log_message("SENT", user_id, response)

                        # Deliver pending messages stop-and-wait: send only the first;
                        # each pending_ack deletes it and triggers the next one.
                        await send_next_pending(websocket, user_id, room_id, rejoin_role)

                        # If peer is online in this room, notify them
                        if peer_online and peer_user_id in connected_users:
                            # Send user_joined to peer
                            notification = json.dumps({
                                'action': 'user_joined',
                                'room_id': room_id,
                                'role': other_role,
                                'peer_role': rejoin_role,
                                'peer_user_id': user_id,
                                'peer_public_key': pin_info[f'{rejoin_role}_public_key']
                            })
                            await connected_users[peer_user_id].send(notification)
                            log_message("SENT", peer_user_id, notification)
                    else:
                        error_message = json.dumps({
                            'action': 'error',
                            'message': 'Room is pinned and you are not a member'
                        })
                        await websocket.send(error_message)
                        log_message("SENT", user_id, error_message)

                elif room_id in rooms and rooms[room_id]['guest'] is None:
                    # Normal join (non-pinned room, guest slot empty)
                    rooms[room_id]['guest'] = user_id
                    room_role_to_userid[f"{room_id}:guest"] = user_id
                    # 给guest发送room_joined消息
                    response = json.dumps({
                        'action': 'room_joined',
                        'room_id': room_id,
                        'role': 'guest',
                        'peer_role': 'host',
                        'peer_user_id': rooms[room_id]['host'],
                        'peer_public_key': user_public_keys[rooms[room_id]['host']],
                        'pinned': False
                    })
                    await websocket.send(response)
                    log_message("SENT", user_id, response)
                    # 通知房间内的host有新用户加入
                    host_id = rooms[room_id]['host']
                    if host_id in connected_users:
                        notification = json.dumps({
                            'action': 'user_joined',
                            'room_id': room_id,
                            'role': 'host',
                            'peer_role': 'guest',
                            'peer_user_id': user_id,
                            'peer_public_key': user_public_keys[user_id]
                        })
                        await connected_users[host_id].send(notification)
                        log_message("SENT", host_id, notification)
                else:
                    error_message = json.dumps({
                        'action': 'error',
                        'message': 'Room not found or already full'
                    })
                    await websocket.send(error_message)
                    log_message("SENT", user_id, error_message)

            elif action == 'leave_room':
                room_id = data['room_id']
                role = data['role']
                leave_user_id = data.get('user_id', user_id)

                if room_id in rooms and rooms[room_id][role] == leave_user_id:
                    if is_pinned(room_id):
                        # Pinned room: only clear slot, notify peer of offline status
                        rooms[room_id][role] = None
                        if f"{room_id}:{role}" in room_role_to_userid:
                            del room_role_to_userid[f"{room_id}:{role}"]
                        other_role = 'guest' if role == 'host' else 'host'
                        other_user_id = rooms[room_id][other_role]
                        if other_user_id and other_user_id in connected_users:
                            notification = json.dumps({
                                'action': 'peer_status',
                                'room_id': room_id,
                                'status': 'offline'
                            })
                            await connected_users[other_user_id].send(notification)
                            log_message("SENT", other_user_id, notification)
                    else:
                        # Non-pinned: existing behavior
                        rooms[room_id][role] = None
                        if f"{room_id}:{role}" in room_role_to_userid:
                            del room_role_to_userid[f"{room_id}:{role}"]
                        # 通知房间内的其他用户有用户离开
                        other_role = 'guest' if role == 'host' else 'host'
                        other_user_id = rooms[room_id][other_role]
                        if other_user_id and other_user_id in connected_users:
                            notification = json.dumps({
                                'action': 'user_left',
                                'room_id': room_id,
                                'role': role
                            })
                            await connected_users[other_user_id].send(notification)
                            log_message("SENT", other_user_id, notification)
                        # 如果离开的是 host，则关闭房间
                        if role == 'host':
                            if other_user_id and other_user_id in connected_users:
                                notification = json.dumps({
                                    'action': 'room_closed',
                                    'room_id': room_id
                                })
                                await connected_users[other_user_id].send(notification)
                                log_message("SENT", other_user_id, notification)
                            del rooms[room_id]
                            if f"{room_id}:guest" in room_role_to_userid:
                                del room_role_to_userid[f"{room_id}:guest"]

            elif action == 'typing':
                room_id = data['room_id']
                role = data['role']
                encrypted_aes_key = data['encrypted_aes_key']
                encrypted_content = data['encrypted_content']
                if room_id in rooms:
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'typing',
                            'room_id': room_id,
                            'role': role,
                            'encrypted_aes_key': encrypted_aes_key,
                            'encrypted_content': encrypted_content
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)

            elif action == 'heart_rate':
                room_id = data['room_id']
                role = data['role']
                encrypted_aes_key = data['encrypted_aes_key']
                encrypted_content = data['encrypted_content']
                if room_id in rooms:
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'heart_rate',
                            'room_id': room_id,
                            'role': role,
                            'encrypted_aes_key': encrypted_aes_key,
                            'encrypted_content': encrypted_content
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)

            elif action == 'send_message':
                seq = data.get('seq')
                room_id = data['room_id']
                role = data['role']
                encrypted_aes_key = data['encrypted_aes_key']
                encrypted_content = data['encrypted_content']
                # A dying room is read-only: drop silently (still acked below) rather than
                # queueing for a peer who unpinned and will never come back.
                if room_id in rooms and not is_dying(room_id):
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        # Peer is online, deliver immediately
                        notification = json.dumps({
                            'action': 'new_message',
                            'room_id': room_id,
                            'role': role,
                            'encrypted_aes_key': encrypted_aes_key,
                            'encrypted_content': encrypted_content
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)
                    elif is_pinned(room_id):
                        # Peer is offline, queue message for pinned room
                        MAX_PENDING_BYTES = 5 * 1024 * 1024  # 5 MB
                        msg_size = len(encrypted_content.encode('utf-8'))
                        if msg_size > MAX_PENDING_BYTES:
                            error_message = json.dumps({
                                'action': 'error',
                                'message': 'Message too large to queue for offline peer (max 5 MB).'
                            })
                            await websocket.send(error_message)
                            log_message("SENT", user_id, error_message)
                        else:
                            queue_key = f"for_{other_role}"
                            if room_id not in pending_messages:
                                pending_messages[room_id] = {"for_host": [], "for_guest": [], "next_id": 0}
                            msg_id = pending_messages[room_id].get("next_id", 0)
                            pending_messages[room_id]["next_id"] = msg_id + 1
                            pending_messages[room_id][queue_key].append({
                                'pending_msg_id': msg_id,
                                'role': role,
                                'encrypted_aes_key': encrypted_aes_key,
                                'encrypted_content': encrypted_content,
                                'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
                            })
                            save_pending_messages()
                            log_message("SYSTEM", "Server", f"Queued message for offline peer in pinned room {room_id}")
                if seq is not None:
                    ack = json.dumps({'action': 'ack', 'seq': seq})
                    await websocket.send(ack)

            elif action == 'request_pin':
                room_id = data['room_id']
                role = data['role']
                if room_id in rooms:
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'pin_requested',
                            'room_id': room_id
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)

            elif action == 'accept_pin':
                room_id = data['room_id']
                role = data['role']
                if room_id in rooms:
                    room = rooms[room_id]
                    host_uid = room['host']
                    guest_uid = room['guest']
                    if host_uid and guest_uid:
                        # Create pinned room entry
                        pinned_rooms[room_id] = {
                            'host_user_id': host_uid,
                            'guest_user_id': guest_uid,
                            'host_public_key': user_public_keys.get(host_uid, ''),
                            'guest_public_key': user_public_keys.get(guest_uid, '')
                        }
                        room['pinned'] = True
                        # Init pending message queues
                        pending_messages[room_id] = {"for_host": [], "for_guest": [], "next_id": 0}
                        save_pinned_rooms()
                        save_pending_messages()
                        log_message("SYSTEM", "Server", f"Room {room_id} pinned")

                        # Notify both users
                        for uid, uid_role in [(host_uid, 'host'), (guest_uid, 'guest')]:
                            if uid in connected_users:
                                other = 'guest' if uid_role == 'host' else 'host'
                                peer_uid = guest_uid if uid_role == 'host' else host_uid
                                notification = json.dumps({
                                    'action': 'pin_accepted',
                                    'room_id': room_id,
                                    'peer_public_key': user_public_keys.get(peer_uid, ''),
                                    'peer_user_id': peer_uid
                                })
                                await connected_users[uid].send(notification)
                                log_message("SENT", uid, notification)

            elif action == 'reject_pin':
                room_id = data['room_id']
                role = data['role']
                if room_id in rooms:
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'pin_rejected',
                            'room_id': room_id
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)

            elif action == 'unpin_room':
                room_id = data['room_id']
                role = data['role']
                # 'grace' is opt-in: an unpin without it destroys everything immediately, which
                # keeps the report flow (and older clients) on the original semantics.
                grace = bool(data.get('grace'))
                if is_pinned(room_id):
                    pin_info = pinned_rooms[room_id]
                    other_role = 'guest' if role == 'host' else 'host'
                    peer_user_id = pin_info[f'{other_role}_user_id']
                    already_dying = is_dying(room_id)

                    if grace and not already_dying:
                        # Keep the room alive read-only so the peer can still read the last
                        # messages and drain its pending queue before it is destroyed.
                        destroy_after = time.time() + UNPIN_GRACE_SECONDS
                        pin_info['unpinned_by'] = role
                        pin_info['destroy_after'] = destroy_after
                        # The unpinner is no longer an occupant of the room.
                        if room_id in rooms and rooms[room_id].get(role) == user_id:
                            rooms[room_id][role] = None
                        room_role_to_userid.pop(f"{room_id}:{role}", None)
                        save_pinned_rooms()
                        if peer_user_id and peer_user_id in connected_users:
                            notification = json.dumps({
                                'action': 'room_unpinned',
                                'room_id': room_id,
                                'grace_until': iso_utc(destroy_after)
                            })
                            await connected_users[peer_user_id].send(notification)
                            log_message("SENT", peer_user_id, notification)
                        log_message("SYSTEM", "Server", f"Room {room_id} unpinned by {role}, grace until {iso_utc(destroy_after)}")
                    else:
                        # Immediate destroy. When the room was already dying this is the
                        # surviving peer closing it — the unpinner is gone, nobody to notify.
                        if not already_dying and peer_user_id and peer_user_id in connected_users:
                            notification = json.dumps({
                                'action': 'room_unpinned',
                                'room_id': room_id
                            })
                            await connected_users[peer_user_id].send(notification)
                            log_message("SENT", peer_user_id, notification)
                        destroy_room(room_id)
                        log_message("SYSTEM", "Server", f"Room {room_id} unpinned")

            elif action == 'pending_ack':
                room_id = data['room_id']
                role = data['role']
                pending_msg_id = data['pending_msg_id']
                if room_role_to_userid.get(f"{room_id}:{role}") != user_id:
                    log_message("SYSTEM", "Server", f"Unauthorized pending_ack from {user_id} for room {room_id} role {role}")
                    continue
                queue_key = f"for_{role}"
                if room_id in pending_messages and queue_key in pending_messages[room_id]:
                    before = len(pending_messages[room_id][queue_key])
                    pending_messages[room_id][queue_key] = [
                        m for m in pending_messages[room_id][queue_key]
                        if m['pending_msg_id'] != pending_msg_id
                    ]
                    if len(pending_messages[room_id][queue_key]) < before:
                        save_pending_messages()
                        log_message("SYSTEM", "Server", f"Deleted pending msg {pending_msg_id} for {role} in room {room_id}")
                        # Stop-and-wait: deliver the next queued message, if any
                        await send_next_pending(websocket, user_id, room_id, role)

            elif action == 'report_user':
                reported_id = data.get('reported_user_id')
                in_same_room = reported_id and any(
                    (r.get('host') == user_id and r.get('guest') == reported_id) or
                    (r.get('guest') == user_id and r.get('host') == reported_id)
                    for r in rooms.values()
                )
                if in_same_room:
                    await handle_report_user(websocket, data)
                else:
                    log_message("SYSTEM", "Server", f"User {user_id} attempted to report {reported_id} but they are not in the same room")

            elif action == 'speedtest':
                # Latency / throughput probe for the client's Speed Test screen. Deliberately
                # stateless: no room, no peer, nothing persisted. Three modes mirror what a
                # chat actually does — 'echo' round-trips a message (text, voice segment),
                # 'upload' absorbs one (sending a photo), 'download' generates one (receiving).
                if not user_id:
                    continue  # must log in first
                seq = data.get('seq')
                mode = data.get('mode', 'echo')
                payload = data.get('payload') or ''
                want = max(0, int(data.get('size') or 0))
                up_bytes = len(payload)
                down_bytes = up_bytes if mode == 'echo' else (want if mode == 'download' else 0)
                if up_bytes > SPEEDTEST_MAX_PAYLOAD or want > SPEEDTEST_MAX_PAYLOAD:
                    response = json.dumps({'action': 'error', 'message': 'Speed test payload too large.'})
                    await websocket.send(response)
                    log_message("SENT", user_id, response)
                    continue
                speedtest_bytes += up_bytes + down_bytes
                if speedtest_bytes > SPEEDTEST_MAX_BYTES_PER_CONN:
                    response = json.dumps({'action': 'error', 'message': 'Speed test quota exceeded.'})
                    await websocket.send(response)
                    log_message("SENT", user_id, response)
                    continue
                result = {'action': 'speedtest_result', 'seq': seq, 'size': up_bytes}
                if mode == 'echo':
                    result['payload'] = payload
                elif mode == 'download':
                    result['payload'] = speedtest_payload(down_bytes)
                response = json.dumps(result)
                await websocket.send(response)
                log_message("SENT", user_id, response)

    except websockets.exceptions.ConnectionClosedError:
        log_message("SYSTEM", "Server", f"Connection closed for user {user_id}")
    except websockets.exceptions.ConnectionClosedOK:
        log_message("SYSTEM", "Server", f"Connection closed normally for user {user_id}")
    except json.JSONDecodeError:
        log_message("SYSTEM", "Server", f"Invalid JSON received from user {user_id}")
    except Exception as e:
        log_message("SYSTEM", "Server", f"An error occurred for user {user_id}: {str(e)}")
    finally:
        if user_id:
            await cleanup_user(user_id)

async def cleanup_user(user_id):
    if user_id in connected_users:
        del connected_users[user_id]
    for room_id, room_info in list(rooms.items()):
        for role in ['host', 'guest']:
            if room_info[role] == user_id:
                if is_pinned(room_id):
                    # Pinned room: only clear slot, send peer_status offline
                    room_info[role] = None
                    if f"{room_id}:{role}" in room_role_to_userid:
                        del room_role_to_userid[f"{room_id}:{role}"]
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = room_info[other_role]
                    if other_user_id and other_user_id in connected_users:
                        try:
                            notification = json.dumps({
                                'action': 'peer_status',
                                'room_id': room_id,
                                'status': 'offline'
                            })
                            await connected_users[other_user_id].send(notification)
                            log_message("SENT", other_user_id, notification)
                        except websockets.exceptions.ConnectionClosed:
                            log_message("SYSTEM", "Server", f"Failed to notify user {other_user_id} about user {user_id} going offline")
                else:
                    # Non-pinned: existing behavior
                    room_info[role] = None
                    if f"{room_id}:{role}" in room_role_to_userid:
                        del room_role_to_userid[f"{room_id}:{role}"]
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = room_info[other_role]
                    if other_user_id and other_user_id in connected_users:
                        try:
                            notification = json.dumps({
                                'action': 'user_left',
                                'room_id': room_id,
                                'role': role
                            })
                            await connected_users[other_user_id].send(notification)
                            log_message("SENT", other_user_id, notification)
                        except websockets.exceptions.ConnectionClosed:
                            log_message("SYSTEM", "Server", f"Failed to notify user {other_user_id} about user {user_id} leaving")
                    if role == 'host':
                        if other_user_id and other_user_id in connected_users:
                            notification = json.dumps({
                                'action': 'room_closed',
                                'room_id': room_id
                            })
                            await connected_users[other_user_id].send(notification)
                            log_message("SENT", other_user_id, notification)
                        del rooms[room_id]
                        if f"{room_id}:guest" in room_role_to_userid:
                            del room_role_to_userid[f"{room_id}:guest"]
                break
    log_message("SYSTEM", "Server", f"User {user_id} logged out")

async def handle_report_user(websocket, message):
    reported_user_id = message.get('reported_user_id')
    if reported_user_id and reported_user_id not in load_blocked_users():
        blocked_users = load_blocked_users()
        blocked_users.append(reported_user_id)
        save_blocked_users(blocked_users)
        # 如果被举报用户在线，强制其断开连接
        if reported_user_id in connected_users:
            client = connected_users[reported_user_id]
            await client.send(json.dumps({
                'action': 'blocked',
                'message': 'Your account has been blocked due to violations.'
            }))
            await client.close()
            del connected_users[reported_user_id]

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-ssl', action='store_true', help='Disable TLS (for local development)')
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()

    HOST = "0.0.0.0"
    PORT = args.port

    if args.no_ssl:
        ssl_context = None
    else:
        SSL_CERT = "/etc/letsencrypt/live/unspoken.luy.li/fullchain.pem"
        SSL_KEY = "/etc/letsencrypt/live/unspoken.luy.li/privkey.pem"
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(certfile=SSL_CERT, keyfile=SSL_KEY)

    async def main():
        # Load persistence on startup
        load_pinned_rooms()
        load_pending_messages()
        purge_expired_rooms()   # drop rooms whose grace period elapsed while we were down
        restore_pinned_rooms()
        mode = "ws" if ssl_context is None else "wss"
        log_message("SYSTEM", "Server", f"Loaded {len(pinned_rooms)} pinned rooms")
        log_message("SYSTEM", "Server", f"Starting server at {mode}://{HOST}:{PORT}")
        purge_task = asyncio.create_task(purge_expired_rooms_loop())
        try:
            async with websockets.serve(handle_connection, HOST, PORT, ssl=ssl_context, max_size=10*1024*1024):
                await asyncio.Future()  # 运行直到被取消
        finally:
            purge_task.cancel()

    asyncio.run(main())
