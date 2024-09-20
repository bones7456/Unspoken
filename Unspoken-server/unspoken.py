import asyncio
import websockets
import json
import uuid
from datetime import datetime
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes

next_room_id = 1000  # 从1000开始的房间号
connected_users = {} # 存储用户连接
rooms = {} # 存储房间信息
user_public_keys = {}  # 存储用户公钥
room_role_to_userid = {}  # 存储 room+role 和 userid 的对应关系

def log_message(direction, user_id, message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if direction == "SYSTEM":
        direction_symbol = "||"
    else:
        direction_symbol = ">>" if direction == "RECEIVED" else "<<"
    print(f"[{timestamp}] {direction_symbol} {user_id}: {message}")

async def handle_connection(websocket, path):
    user_id = None
    try:
        async for message in websocket:
            log_message("RECEIVED", user_id or "Unknown", message)
            data = json.loads(message)
            action = data.get('action')

            if action == 'login':
                user_id = data['user_id']
                connected_users[user_id] = websocket
                log_message("SYSTEM", "Server", f"User {user_id} logged in")

            elif action == 'exchange_public_key':
                user_id = data['user_id']
                public_key_pem = data['public_key']
                user_public_keys[user_id] = public_key_pem
                log_message("SYSTEM", "Server", f"Received public key from user {user_id}")

            elif action == 'request_public_key':
                requested_user_id = data['requested_user_id']
                if requested_user_id in user_public_keys:
                    response = json.dumps({
                        'action': 'public_key_response',
                        'user_id': requested_user_id,
                        'public_key': user_public_keys[requested_user_id]
                    })
                    await websocket.send(response)
                    log_message("SENT", user_id, response)
                else:
                    error_message = json.dumps({
                        'action': 'error',
                        'message': 'Public key not found'
                    })
                    await websocket.send(error_message)
                    log_message("SENT", user_id, error_message)

            elif action == 'create_room':
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
                room_id = data['room_id']
                if room_id in rooms and rooms[room_id]['guest'] is None:
                    rooms[room_id]['guest'] = user_id
                    room_role_to_userid[f"{room_id}:guest"] = user_id
                    response = json.dumps({
                        'action': 'room_joined',
                        'room_id': room_id,
                        'role': 'guest'
                    })
                    await websocket.send(response)
                    log_message("SENT", user_id, response)
                    # 通知房间内的其他用户有新用户加入
                    host_id = rooms[room_id]['host']
                    if host_id in connected_users:
                        notification = json.dumps({
                            'action': 'user_joined',
                            'room_id': room_id,
                            'role': 'guest',
                            'user_id': user_id  # 添加这一行
                        })
                        await connected_users[host_id].send(notification)
                        log_message("SENT", host_id, notification)
                        
                        # 发送 host 的公钥给 guest
                        if host_id in user_public_keys:
                            host_key_message = json.dumps({
                                'action': 'public_key_exchange',
                                'user_id': host_id,
                                'public_key': user_public_keys[host_id]
                            })
                            await websocket.send(host_key_message)
                            log_message("SENT", user_id, host_key_message)
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
                encrypted_content = data['encrypted_content']
                if room_id in rooms:
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'typing',
                            'room_id': room_id,
                            'role': role,
                            'encrypted_content': encrypted_content
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)

            elif action == 'send_message':
                room_id = data['room_id']
                role = data['role']
                encrypted_content = data['encrypted_content']
                if room_id in rooms:
                    rooms[room_id]['messages'].append({'role': role, 'encrypted_content': encrypted_content})
                    other_role = 'guest' if role == 'host' else 'host'
                    other_user_id = rooms[room_id][other_role]
                    if other_user_id and other_user_id in connected_users:
                        notification = json.dumps({
                            'action': 'new_message',
                            'room_id': room_id,
                            'role': role,
                            'encrypted_content': encrypted_content
                        })
                        await connected_users[other_user_id].send(notification)
                        log_message("SENT", other_user_id, notification)
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

if __name__ == '__main__':
    HOST = "0.0.0.0"
    PORT = 8765
    log_message("SYSTEM", "Server", f"Starting server at {HOST}:{PORT}")
    start_server = websockets.serve(handle_connection, HOST, PORT)

    asyncio.get_event_loop().run_until_complete(start_server)
    asyncio.get_event_loop().run_forever()