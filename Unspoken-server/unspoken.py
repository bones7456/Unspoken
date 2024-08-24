import asyncio
import websockets
import json
import uuid
import random
from datetime import datetime

next_room_id = 1000  # 从1000开始的房间号
connected_users = {} # 存储用户连接
rooms = {} # 存储房间信息

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

            elif action == 'create_room':
                global next_room_id
                room_id = str(next_room_id)
                next_room_id += 1
                rooms[room_id] = {'users': [user_id], 'messages': []}
                response = json.dumps({
                    'action': 'room_created',
                    'room_id': room_id,
                    'user_id': user_id
                })
                await websocket.send(response)
                log_message("SENT", user_id, response)

            elif action == 'join_room':
                room_id = data['room_id']
                if room_id in rooms:
                    rooms[room_id]['users'].append(user_id)
                    response = json.dumps({
                        'action': 'room_joined',
                        'room_id': room_id,
                        'user_id': user_id
                    })
                    await websocket.send(response)
                    log_message("SENT", user_id, response)
                    # 通知房间内的其他用户有新用户加入
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id != user_id and recipient_id in connected_users:
                            notification = json.dumps({
                                'action': 'user_joined',
                                'room_id': room_id,
                                'user_id': user_id
                            })
                            await connected_users[recipient_id].send(notification)
                            log_message("SENT", recipient_id, notification)

                else:
                    error_message = json.dumps({
                        'action': 'error',
                        'message': 'Room not found'
                    })
                    await websocket.send(error_message)
                    log_message("SENT", user_id, error_message)

            elif action == 'leave_room':
                room_id = data['room_id']
                if room_id in rooms and user_id in rooms[room_id]['users']:
                    rooms[room_id]['users'].remove(user_id)
                    # 通知房间内的其他用户有用户离开
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id in connected_users:
                            notification = json.dumps({
                                'action': 'user_left',
                                'room_id': room_id,
                                'user_id': user_id
                            })
                            await connected_users[recipient_id].send(notification)
                            log_message("SENT", recipient_id, notification)
                    # 如果离开的是 host，则关闭房间
                    if user_id == 'host':
                        for recipient_id in rooms[room_id]['users']:
                            if recipient_id in connected_users:
                                notification = json.dumps({
                                    'action': 'room_closed',
                                    'room_id': room_id
                                })
                                await connected_users[recipient_id].send(notification)
                                log_message("SENT", recipient_id, notification)
                        del rooms[room_id]

            elif action == 'typing':
                room_id = data['room_id']
                content = data['content']
                if room_id in rooms:
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id != user_id and recipient_id in connected_users:
                            notification = json.dumps({
                                'action': 'typing',
                                'room_id': room_id,
                                'by_user': user_id,
                                'content': content
                            })
                            await connected_users[recipient_id].send(notification)
                            log_message("SENT", recipient_id, notification)

            elif action == 'send_message':
                room_id = data['room_id']
                content = data['content']
                if room_id in rooms:
                    rooms[room_id]['messages'].append({'user_id': user_id, 'content': content})
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id != user_id and recipient_id in connected_users:
                            notification = json.dumps({
                                'action': 'new_message',
                                'room_id': room_id,
                                'by_user': user_id,
                                'content': content
                            })
                            await connected_users[recipient_id].send(notification)
                            log_message("SENT", recipient_id, notification)
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
    for room_id in list(rooms.keys()):
        if user_id in rooms[room_id]['users']:
            rooms[room_id]['users'].remove(user_id)
            # 通知房间内的其他用户有用户离开
            for recipient_id in rooms[room_id]['users']:
                if recipient_id in connected_users:
                    try:
                        notification = json.dumps({
                            'action': 'user_left',
                            'room_id': room_id,
                            'user_id': user_id
                        })
                        await connected_users[recipient_id].send(notification)
                        log_message("SENT", recipient_id, notification)
                    except websockets.exceptions.ConnectionClosed:
                        log_message("SYSTEM", "Server", f"Failed to notify user {recipient_id} about user {user_id} leaving")
            if not rooms[room_id]['users']:
                del rooms[room_id]
    log_message("SYSTEM", "Server", f"User {user_id} logged out")

if __name__ == '__main__':
    HOST = "0.0.0.0"
    PORT = 8765
    log_message("SYSTEM", "Server", f"Starting server at {HOST}:{PORT}")
    start_server = websockets.serve(handle_connection, HOST, PORT)

    asyncio.get_event_loop().run_until_complete(start_server)
    asyncio.get_event_loop().run_forever()