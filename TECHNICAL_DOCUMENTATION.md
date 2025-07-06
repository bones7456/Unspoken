
# Unspoken 技术文档

## 1. 简介

本文档旨在为开发者提供 Unspoken 即时通讯软件客户端与服务器交互的技术细节。

Unspoken 采用客户端-服务器架构。客户端（iOS/Web）通过 WebSocket 与服务器建立安全连接，并进行实时消息交换。服务器负责处理用户登录、房间创建与管理、消息路由以及用户举报等核心逻辑。

## 2. 通信协议

客户端与服务器之间使用安全的 WebSocket (WSS) 协议进行全双工通信。所有传输的数据均为 JSON 格式。

## 3. 消息格式

所有消息都遵循统一的、扁平化的 JSON 结构。`action` 字段用于标识消息类型，所有相关参数与 `action` 在同一层级。

**通用消息结构:**

```json
{
  "action": "some_action",
  "key1": "value1",
  "key2": "value2"
}
```

## 4. 核心交互流程

### 4.1. 消息流转图

下图展示了两位用户（A 和 B）从创建房间到交换消息的典型流程：

```ascii
+---------+                                +--------+                                +---------+
| Client A|                                | Server |                                | Client B|
+---------+                                +--------+                                +---------+
     |                                          |                                          |
     |-----------(1) login(user_id_A)----------->|                                          |
     |                                          |                                          |
     |--------(2) create_room(user_id_A)-------->|                                          |
     |                                          |                                          |
     |<--------(3) room_created(room_id)---------|                                          |
     |                                          |                                          |
     |                                          |<-----------(4) login(user_id_B)------------|
     |                                          |                                          |
     |                                          |<---------(5) join_room(room_id)-----------|
     |                                          |                                          |
     |                                          |---------(6) room_joined(room_id)--------->|
     |                                          |                                          |
     |<--------(7) user_joined(user_id_B)--------|                                          |
     |                                          |                                          |
     |-------------(8) typing(start)------------>|                                          |
     |                                          |                                          |
     |                                          |-------------(9) typing(start)------------>|
     |                                          |                                          |
     |----------(10) send_message(msg1)--------->|                                          |
     |                                          |                                          |
     |                                          |----------(11) new_message(msg1)----------->|
     |                                          |                                          |
     |                                          |<------------(12) typing(start)------------|
     |                                          |                                          |
     |<------------(13) typing(start)------------|                                          |
     |                                          |                                          |
     |                                          |<---------(14) send_message(msg2)----------|
     |                                          |                                          |
     |<----------(15) new_message(msg2)----------|                                          |
     |                                          |                                          |
     |-----------(16) leave_room---------------->|                                          |
     |                                          |                                          |
     |                                          |-----------(17) user_left----------------->|
     |                                          |                                          |
```

### 4.2. 流程详解

1.  **用户 A 登录**: 用户 A 连接到 WebSocket 服务器，并发送 `login` 动作，提供其 `user_id` 和公钥。
2.  **用户 A 创建房间**: 用户 A 发送 `create_room` 动作。
3.  **房间创建成功**: 服务器创建一个新房间，将用户 A 设置为 `host`，并向用户 A 返回 `room_created` 消息，其中包含 `room_id`。
4.  **用户 B 登录**: 用户 B 连接到 WebSocket 服务器，并发送 `login` 动作。
5.  **用户 B 加入房间**: 用户 B 发送 `join_room` 动作，并提供从用户 A 处（通过线下方式）获取的 `room_id`。
6.  **成功加入房间**: 服务器将用户 B 添加为房间的 `guest`，并向用户 B 发送 `room_joined` 消息，其中包含房间信息以及用户 A 的公钥。
7.  **通知用户 A**: 服务器向用户 A 发送 `user_joined` 消息，通知其用户 B 已加入房间，并提供用户 B 的公钥。此时，双方可以开始加密通信。
8.  **用户 A 正在输入**: 用户 A 在输入框输入内容时，发送 `typing` 动作。
9.  **服务器转发输入状态**: 服务器将 `typing` 状态转发给用户 B。
10. **用户 A 发送消息**: 用户 A 发送 `send_message` 动作，消息内容使用双方协商的对称密钥加密。
11. **服务器转发消息**: 服务器收到消息后，将其转发给用户 B (`new_message`)。
12. **用户 B 正在输入**: 用户 B 回复前，发送 `typing` 动作。
13. **服务器转发输入状态**: 服务器将 `typing` 状态转发给用户 A。
14. **用户 B 发送消息**: 用户 B 回复消息。
15. **服务器转发消息**: 服务器将消息转发给用户 A。
16. **用户 A 离开房间**: 用户 A 发送 `leave_room` 动作。
17. **通知用户 B**: 服务器通知用户 B，对方已离开 (`user_left`)。如果离开的是 `host`，房间将被关闭 (`room_closed`)。

## 5. 服务端核心数据结构

服务器在内存中维护以下几个核心数据结构来管理整个系统的状态：

-   `connected_users`: 一个字典，用于存储当前所有在线用户的连接实例。
    -   **键**: `user_id` (String)
    -   **值**: WebSocket 连接对象

-   `rooms`: 一个字典，存储所有活跃的聊天房间信息。
    -   **键**: `room_id` (String)
    -   **值**: 一个包含房间详情的字典:
        -   `host`: `user_id` (String) - 房间创建者的用户 ID。
        -   `guest`: `user_id` (String) - 加入房间的访客的用户 ID，可能为 `None`。
        -   `messages`: 一个列表，存储房间内的消息记录。

-   `user_public_keys`: 一个字典，存储已登录用户的公钥。
    -   **键**: `user_id` (String)
    -   **值**: 用户的 RSA 公钥 (PEM 格式字符串)

-   `room_role_to_userid`: 一个字典，用于快速通过房间和角色定位用户。
    -   **键**: `f"{room_id}:{role}"` (String) - 例如 "1001:host"。
    -   **值**: `user_id` (String)

## 6. 客户端 -> 服务器 Actions

| Action | 描述 | 消息体参数 |
| :--- | :--- | :--- |
| `login` | 用户登录并注册连接 | `user_id`, `public_key` |
| `create_room` | 请求创建一个新的聊天房间 | `user_id` |
| `join_room` | 加入一个已存在的房间 | `user_id`, `room_id` |
| `leave_room` | 离开当前房间 | `user_id`, `room_id`, `role` |
| `typing` | 通知对方自己正在输入 | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `send_message` | 发送一条消息到房间 | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `report_user` | 举报某个用户 | `reported_user_id` |

## 7. 服务器 -> 客户端 Actions

| Action | 描述 | 消息体参数 |
| :--- | :--- | :--- |
| `room_created` | 通知用户房间已成功创建 | `room_id`, `role` |
| `room_joined` | 通知用户已成功加入房间 | `room_id`, `role`, `peer_role`, `peer_user_id`, `peer_public_key` |
| `user_joined` | 通知房间内的用户有新成员加入 | `room_id`, `role`, `peer_role`, `peer_user_id`, `peer_public_key` |
| `user_left` | 通知房间内的用户有成员离开 | `room_id`, `role` |
| `room_closed` | 通知用户房间已被关闭（通常因为 host 离开） | `room_id` |
| `new_message` | 收到一条新消息 | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `typing` | 对方正在输入 | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `error` | 操作失败或发生错误 | `message` |
| `login_failed` | 登录失败（例如，账户被封禁） | `message` |
| `blocked` | 当前用户被封禁 | `message` |
