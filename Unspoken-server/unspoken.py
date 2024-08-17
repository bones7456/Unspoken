import asyncio
import websockets
import json
import uuid
import random

# 在文件开头添加这个变量
next_room_id = 1000  # 从1000开始的房间号
# 存储用户连接
connected_users = {}
# 存储房间信息
rooms = {}

async def handle_connection(websocket, path):
    user_id = None
    try:
        async for message in websocket:
            print(message)
            data = json.loads(message)
            action = data.get('action')

            if action == 'login':
                user_id = data['user_id']
                connected_users[user_id] = websocket
                print(f"User {user_id} logged in")

            elif action == 'create_room':
                global next_room_id
                room_id = str(next_room_id)
                next_room_id += 1
                rooms[room_id] = {'users': [user_id], 'messages': []}
                await websocket.send(json.dumps({
                    'action': 'room_created',
                    'room_id': room_id,
                    'user_id': user_id
                }))

            elif action == 'join_room':
                room_id = data['room_id']
                if room_id in rooms:
                    rooms[room_id]['users'].append(user_id)
                    await websocket.send(json.dumps({
                        'action': 'room_joined',
                        'room_id': room_id,
                        'user_id': user_id
                    }))
                    # 通知房间内的其他用户有新用户加入
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id != user_id and recipient_id in connected_users:
                            await connected_users[recipient_id].send(json.dumps({
                                'action': 'user_joined',
                                'room_id': room_id,
                                'user_id': user_id
                            }))
                else:
                    await websocket.send(json.dumps({
                        'action': 'error',
                        'message': 'Room not found'
                    }))

            elif action == 'leave_room':
                room_id = data['room_id']
                if room_id in rooms and user_id in rooms[room_id]['users']:
                    rooms[room_id]['users'].remove(user_id)
                    # 通知房间内的其他用户有用户离开
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id in connected_users:
                            await connected_users[recipient_id].send(json.dumps({
                                'action': 'user_left',
                                'room_id': room_id,
                                'user_id': user_id
                            }))
                    # 如果离开的是 host，则关闭房间
                    if user_id == 'host':
                        for recipient_id in rooms[room_id]['users']:
                            if recipient_id in connected_users:
                                await connected_users[recipient_id].send(json.dumps({
                                    'action': 'room_closed',
                                    'room_id': room_id
                                }))
                        del rooms[room_id]

            elif action == 'typing':
                room_id = data['room_id']
                content = data['content']
                if room_id in rooms:
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id != user_id and recipient_id in connected_users:
                            await connected_users[recipient_id].send(json.dumps({
                                'action': 'typing',
                                'room_id': room_id,
                                'by_user': user_id,
                                'content': content
                            }))

            elif action == 'send_message':
                room_id = data['room_id']
                content = data['content']
                if room_id in rooms:
                    rooms[room_id]['messages'].append({'user_id': user_id, 'content': content})
                    for recipient_id in rooms[room_id]['users']:
                        if recipient_id != user_id and recipient_id in connected_users:
                            await connected_users[recipient_id].send(json.dumps({
                                'action': 'new_message',
                                'room_id': room_id,
                                'by_user': user_id,
                                'content': content
                            }))

    finally:
        if user_id:
            del connected_users[user_id]
            for room_id in list(rooms.keys()):
                if user_id in rooms[room_id]['users']:
                    rooms[room_id]['users'].remove(user_id)
                    if not rooms[room_id]['users']:
                        del rooms[room_id]
            print(f"User {user_id} logged out")

if __name__ == '__main__':
    HOST = "0.0.0.0"
    PORT = 8765
    print(f"start server at {HOST}:{PORT}")
    start_server = websockets.serve(handle_connection, HOST, PORT)

    asyncio.get_event_loop().run_until_complete(start_server)
    asyncio.get_event_loop().run_forever()