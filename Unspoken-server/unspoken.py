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

# 确保存储目录存在
os.makedirs('data', exist_ok=True)
BLOCKED_USERS_FILE = 'data/blocked_users.json'

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

def log_message(direction, user_id, message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if direction == "SYSTEM":
        direction_symbol = "||"
    else:
        direction_symbol = ">>" if direction == "RECEIVED" else "<<"
    print(f"[{timestamp}] {direction_symbol} {user_id}: {message}")

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
                log_message("SYSTEM", "Server", f"User {user_id} logged in with public key")

            elif action == 'create_room':
                if not await check_available_user_in_data(data, websocket):
                    log_message("SYSTEM", "Server", f"Blocked user {user_id} attempted to create room")
                    continue
                global next_room_id
                room_id = str(next_room_id)
                next_room_id += 1
                rooms[room_id] = {'host': user_id, 'guest': None, 'messages': []}
                room_role_to_userid[f"{room_id}:host"] = user_id
                response = json.dumps({
                    'action': 'room_created',
                    'room_id': room_id,
                    'role': 'host'
                })
                await websocket.send(response)
                log_message("SENT", user_id, response)

            elif action == 'join_room':
                if not await check_available_user_in_data(data, websocket):
                    log_message("SYSTEM", "Server", f"Blocked user {user_id} attempted to join room")
                    continue
                room_id = data['room_id']
                if room_id in rooms and rooms[room_id]['guest'] is None:
                    rooms[room_id]['guest'] = user_id
                    room_role_to_userid[f"{room_id}:guest"] = user_id
                    # 给guest发送room_joined消息
                    response = json.dumps({
                        'action': 'room_joined',
                        'room_id': room_id,
                        'role': 'guest',
                        'peer_role': 'host',
                        'peer_user_id': rooms[room_id]['host'],
                        'peer_public_key': user_public_keys[rooms[room_id]['host']]
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
                user_id = data['user_id']
                if room_id in rooms and rooms[room_id][role] == user_id:
                    rooms[room_id][role] = None
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

            elif action == 'send_message':
                room_id = data['room_id']
                role = data['role']
                encrypted_aes_key = data['encrypted_aes_key']
                encrypted_content = data['encrypted_content']
                if room_id in rooms:
                    rooms[room_id]['messages'].append({'role': role, 'encrypted_aes_key': encrypted_aes_key, 'encrypted_content': encrypted_content})
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'new_message',
                            'room_id': room_id,
                            'role': role,
                            'encrypted_aes_key': encrypted_aes_key,
                            'encrypted_content': encrypted_content
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)

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
    HOST = "0.0.0.0"
    PORT = 8765
    SSL_CERT = "/etc/letsencrypt/live/unspoken.luy.li/fullchain.pem"
    SSL_KEY = "/etc/letsencrypt/live/unspoken.luy.li/privkey.pem"
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_context.load_cert_chain(certfile=SSL_CERT, keyfile=SSL_KEY)

    
    async def main():
        log_message("SYSTEM", "Server", f"Starting server at {HOST}:{PORT}")
        async with websockets.serve(handle_connection, HOST, PORT, ssl=ssl_context):
            await asyncio.Future()  # 运行直到被取消
    
    asyncio.run(main())