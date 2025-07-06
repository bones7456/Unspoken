
# Unspoken Technical Documentation

## 1. Introduction

This document provides developers with technical details about the client-server interaction in the Unspoken instant messaging software.

Unspoken adopts a client-server architecture. Clients (iOS/Web) establish secure connections with the server through WebSocket and perform real-time message exchange. The server is responsible for handling core logic including user login, room creation and management, message routing, and user reporting.

## 2. Communication Protocol

The client and server communicate using secure WebSocket (WSS) protocol for full-duplex communication. All transmitted data is in JSON format.

## 3. Message Format

All messages follow a unified, flattened JSON structure. The `action` field identifies the message type, and all related parameters are at the same level as `action`.

**General Message Structure:**

```json
{
  "action": "some_action",
  "key1": "value1",
  "key2": "value2"
}
```

## 4. Core Interaction Flow

### 4.1. Message Flow Diagram

The following diagram illustrates the typical flow of two users (A and B) from creating a room to exchanging messages:

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

### 4.2. Flow Explanation

1.  **User A Login**: User A connects to the WebSocket server and sends a `login` action, providing their `user_id` and public key.
2.  **User A Creates Room**: User A sends a `create_room` action.
3.  **Room Creation Success**: The server creates a new room, sets User A as the `host`, and returns a `room_created` message to User A containing the `room_id`.
4.  **User B Login**: User B connects to the WebSocket server and sends a `login` action.
5.  **User B Joins Room**: User B sends a `join_room` action with the `room_id` obtained from User A (through offline means).
6.  **Successfully Joined Room**: The server adds User B as the room's `guest` and sends a `room_joined` message to User B containing room information and User A's public key.
7.  **Notify User A**: The server sends a `user_joined` message to User A, notifying them that User B has joined the room and providing User B's public key. At this point, both parties can begin encrypted communication.
8.  **User A Typing**: When User A types content in the input field, they send a `typing` action.
9.  **Server Forwards Typing Status**: The server forwards the `typing` status to User B.
10. **User A Sends Message**: User A sends a `send_message` action with the message content encrypted using the negotiated symmetric key.
11. **Server Forwards Message**: Upon receiving the message, the server forwards it to User B (`new_message`).
12. **User B Typing**: Before replying, User B sends a `typing` action.
13. **Server Forwards Typing Status**: The server forwards the `typing` status to User A.
14. **User B Sends Message**: User B sends a reply message.
15. **Server Forwards Message**: The server forwards the message to User A.
16. **User A Leaves Room**: User A sends a `leave_room` action.
17. **Notify User B**: The server notifies User B that the other party has left (`user_left`). If the `host` leaves, the room will be closed (`room_closed`).

## 5. Server Core Data Structures

The server maintains the following core data structures in memory to manage the entire system state:

-   `connected_users`: A dictionary storing connection instances for all currently online users.
    -   **Key**: `user_id` (String)
    -   **Value**: WebSocket connection object

-   `rooms`: A dictionary storing information about all active chat rooms.
    -   **Key**: `room_id` (String)
    -   **Value**: A dictionary containing room details:
        -   `host`: `user_id` (String) - The user ID of the room creator.
        -   `guest`: `user_id` (String) - The user ID of the guest joining the room, may be `None`.
        -   `messages`: A list storing message records within the room.

-   `user_public_keys`: A dictionary storing public keys of logged-in users.
    -   **Key**: `user_id` (String)
    -   **Value**: User's RSA public key (PEM format string)

-   `room_role_to_userid`: A dictionary for quickly locating users by room and role.
    -   **Key**: `f"{room_id}:{role}"` (String) - e.g., "1001:host".
    -   **Value**: `user_id` (String)

## 6. Client -> Server Actions

| Action | Description | Message Body Parameters |
| :--- | :--- | :--- |
| `login` | User login and connection registration | `user_id`, `public_key` |
| `create_room` | Request to create a new chat room | `user_id` |
| `join_room` | Join an existing room | `user_id`, `room_id` |
| `leave_room` | Leave the current room | `user_id`, `room_id`, `role` |
| `typing` | Notify the other party that you are typing | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `send_message` | Send a message to the room | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `report_user` | Report a user | `reported_user_id` |

## 7. Server -> Client Actions

| Action | Description | Message Body Parameters |
| :--- | :--- | :--- |
| `room_created` | Notify user that room has been successfully created | `room_id`, `role` |
| `room_joined` | Notify user that they have successfully joined the room | `room_id`, `role`, `peer_role`, `peer_user_id`, `peer_public_key` |
| `user_joined` | Notify room users that a new member has joined | `room_id`, `role`, `peer_role`, `peer_user_id`, `peer_public_key` |
| `user_left` | Notify room users that a member has left | `room_id`, `role` |
| `room_closed` | Notify user that the room has been closed (usually because host left) | `room_id` |
| `new_message` | Received a new message | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `typing` | The other party is typing | `room_id`, `role`, `encrypted_aes_key`, `encrypted_content` |
| `error` | Operation failed or error occurred | `message` |
| `login_failed` | Login failed (e.g., account banned) | `message` |
| `blocked` | Current user is banned | `message` |
