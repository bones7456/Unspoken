import asyncio
import websockets
import json
import uuid
import ssl
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
pinned_rooms = {}  # { room_id: { host_user_id, guest_user_id, host_public_key, guest_public_key } }
pending_messages = {}  # { room_id: { "for_host": [...], "for_guest": [...] } }

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
            pending_messages[room_id] = {"for_host": [], "for_guest": []}

_TRUNCATE_KEYS = {"encrypted_content", "encrypted_aes_key", "public_key", "peer_public_key", "host_public_key", "guest_public_key"}
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

async def handle_connection(websocket):
    user_id = None
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
                public_key_pem = data['public_key']
                user_public_keys[user_id] = public_key_pem
                client_version = data.get('client_version', 'unknown')
                log_message("SYSTEM", "Server", f"User {user_id} logged in (v{client_version})")

                # Notify peers in pinned rooms that this user is online
                for room_id, pin_info in pinned_rooms.items():
                    peer_user_id = None
                    if pin_info['host_user_id'] == user_id:
                        peer_user_id = pin_info['guest_user_id']
                    elif pin_info['guest_user_id'] == user_id:
                        peer_user_id = pin_info['host_user_id']
                    if peer_user_id and peer_user_id in connected_users:
                        try:
                            notification = json.dumps({
                                'action': 'peer_status',
                                'room_id': room_id,
                                'status': 'online'
                            })
                            await connected_users[peer_user_id].send(notification)
                            log_message("SENT", peer_user_id, notification)
                        except websockets.exceptions.ConnectionClosed:
                            pass

            elif action == 'create_room':
                if not await check_available_user_in_data(data, websocket):
                    log_message("SYSTEM", "Server", f"Blocked user {user_id} attempted to create room")
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

                # Pinned room rejoin
                if is_pinned(room_id):
                    pin_info = pinned_rooms[room_id]
                    # Determine which role this user has in the pinned room
                    rejoin_role = None
                    if pin_info['host_user_id'] == user_id:
                        rejoin_role = 'host'
                    elif pin_info['guest_user_id'] == user_id:
                        rejoin_role = 'guest'

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
                        peer_online = peer_user_id in connected_users and rooms[room_id][other_role] is not None

                        # Send room_joined to the rejoining user
                        queue_key_preview = f"for_{rejoin_role}"
                        pending_count = len(pending_messages.get(room_id, {}).get(queue_key_preview, []))
                        response = json.dumps({
                            'action': 'room_joined',
                            'room_id': room_id,
                            'role': rejoin_role,
                            'peer_role': other_role,
                            'peer_user_id': peer_user_id,
                            'peer_public_key': peer_public_key,
                            'pinned': True,
                            'peer_status': 'online' if peer_online else 'offline',
                            'pending_count': pending_count
                        })
                        await websocket.send(response)
                        log_message("SENT", user_id, response)

                        # Deliver pending messages one by one to avoid oversized frames
                        queue_key = f"for_{rejoin_role}"
                        if room_id in pending_messages and pending_messages[room_id][queue_key]:
                            pending = pending_messages[room_id][queue_key]
                            total = len(pending)
                            for i, msg in enumerate(pending):
                                remaining = total - i - 1
                                notification = json.dumps({
                                    'action': 'pending_message',
                                    'room_id': room_id,
                                    'encrypted_aes_key': msg['encrypted_aes_key'],
                                    'encrypted_content': msg['encrypted_content'],
                                    'timestamp': msg.get('timestamp'),
                                    'pending_count': remaining
                                })
                                await websocket.send(notification)
                            log_message("SENT", user_id, f"Delivered {total} pending messages individually")
                            pending_messages[room_id][queue_key] = []
                            save_pending_messages()

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
                            # Send peer_status online to peer
                            status_notification = json.dumps({
                                'action': 'peer_status',
                                'room_id': room_id,
                                'status': 'online'
                            })
                            await connected_users[peer_user_id].send(status_notification)
                            log_message("SENT", peer_user_id, status_notification)
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
                if room_id in rooms:
                    rooms[room_id]['messages'].append({'role': role, 'encrypted_aes_key': encrypted_aes_key, 'encrypted_content': encrypted_content})
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
                                pending_messages[room_id] = {"for_host": [], "for_guest": []}
                            pending_messages[room_id][queue_key].append({
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
                        pending_messages[room_id] = {"for_host": [], "for_guest": []}
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
                if is_pinned(room_id):
                    pin_info = pinned_rooms[room_id]
                    # Notify peer
                    other_role = 'guest' if role == 'host' else 'host'
                    peer_user_id = pin_info[f'{other_role}_user_id']
                    if peer_user_id and peer_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'room_unpinned',
                            'room_id': room_id
                        })
                        await connected_users[peer_user_id].send(notification)
                        log_message("SENT", peer_user_id, notification)

                    # Clean up
                    del pinned_rooms[room_id]
                    if room_id in pending_messages:
                        del pending_messages[room_id]
                    if room_id in rooms:
                        del rooms[room_id]
                    # Clean up role mappings
                    for r in ['host', 'guest']:
                        key = f"{room_id}:{r}"
                        if key in room_role_to_userid:
                            del room_role_to_userid[key]
                    save_pinned_rooms()
                    save_pending_messages()
                    log_message("SYSTEM", "Server", f"Room {room_id} unpinned")

            elif action == 'report_user':
                await handle_report_user(websocket, data)
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
        restore_pinned_rooms()
        mode = "ws" if ssl_context is None else "wss"
        log_message("SYSTEM", "Server", f"Loaded {len(pinned_rooms)} pinned rooms")
        log_message("SYSTEM", "Server", f"Starting server at {mode}://{HOST}:{PORT}")
        async with websockets.serve(handle_connection, HOST, PORT, ssl=ssl_context, max_size=10*1024*1024):
            await asyncio.Future()  # 运行直到被取消

    asyncio.run(main())
