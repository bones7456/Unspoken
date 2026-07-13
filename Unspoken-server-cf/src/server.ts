// UnspokenServer — Durable Object port of Unspoken-server/unspoken.py.
//
// One DO instance ("main") hosts the whole server, mirroring the original
// single-process design so room ids stay server-generated and the iOS client
// needs no changes. Protocol messages are byte-compatible with unspoken.py.
//
// State model (survives hibernation):
//   - Connection-scoped state lives in each WebSocket's attachment:
//       { userId, publicKey, rooms: [{roomId, role}] }
//     The Python globals connected_users / rooms / room_role_to_userid are
//     derived on demand by scanning live sockets' attachments.
//   - Durable state lives in SQLite: blocked_users, pinned_rooms, pending
//     message queues (chunked to stay under the 2 MB row limit), counters.

type Role = "host" | "guest";

interface RoomRef {
  roomId: string;
  role: Role;
}

interface Attachment {
  userId: string | null;
  publicKey: string;
  rooms: RoomRef[];
}

interface PinRow extends Record<string, SqlStorageValue> {
  room_id: string;
  host_user_id: string;
  guest_user_id: string;
  host_public_key: string;
  guest_public_key: string;
}

const EMPTY_ATTACHMENT: Attachment = { userId: null, publicKey: "", rooms: [] };

const MAX_PENDING_BYTES = 5 * 1024 * 1024; // 5 MB, same as unspoken.py
const PENDING_CHUNK_CHARS = 1_000_000; // 1 MB per SQLite row (2 MB row limit)
const MAX_PUBLIC_KEY_LEN = 8192;

const TRUNCATE_KEYS = new Set([
  "encrypted_content",
  "encrypted_aes_key",
  "public_key",
  "peer_public_key",
  "host_public_key",
  "guest_public_key",
]);
const TRUNCATE_LEN = 16;

function otherRole(role: Role): Role {
  return role === "host" ? "guest" : "host";
}

function formatLogPayload(message: string): string {
  try {
    const data = JSON.parse(message);
    const parts: string[] = [];
    for (const [k, v] of Object.entries(data)) {
      if (TRUNCATE_KEYS.has(k) && typeof v === "string" && v.length > TRUNCATE_LEN) {
        parts.push(`${k}=${v.slice(0, TRUNCATE_LEN)}…(${v.length}B)`);
      } else {
        parts.push(`${k}=${JSON.stringify(v)}`);
      }
    }
    return "{" + parts.join(", ") + "}";
  } catch {
    return message;
  }
}

function logMessage(direction: "RECEIVED" | "SENT" | "SYSTEM", userId: string, message: string): void {
  const timestamp = new Date().toISOString().slice(0, 19).replace("T", " ");
  if (direction === "SYSTEM") {
    console.log(`[${timestamp}] || ${userId}: ${message}`);
  } else {
    const symbol = direction === "RECEIVED" ? ">>" : "<<";
    console.log(`[${timestamp}] ${symbol} ${userId}: ${formatLogPayload(message)}`);
  }
}

function utcTimestamp(): string {
  // Matches Python's datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
  return new Date().toISOString().slice(0, 19) + "Z";
}

export class UnspokenServer implements DurableObject {
  private ctx: DurableObjectState;
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, _env: unknown) {
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    ctx.blockConcurrencyWhile(async () => {
      this.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS blocked_users (
          user_id TEXT PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS pinned_rooms (
          room_id TEXT PRIMARY KEY,
          host_user_id TEXT NOT NULL,
          guest_user_id TEXT NOT NULL,
          host_public_key TEXT NOT NULL,
          guest_public_key TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pending_meta (
          room_id TEXT NOT NULL,
          msg_id INTEGER NOT NULL,
          queue TEXT NOT NULL,
          role TEXT NOT NULL,
          encrypted_aes_key TEXT NOT NULL,
          timestamp TEXT NOT NULL,
          chunk_count INTEGER NOT NULL,
          PRIMARY KEY (room_id, msg_id)
        );
        CREATE TABLE IF NOT EXISTS pending_chunks (
          room_id TEXT NOT NULL,
          msg_id INTEGER NOT NULL,
          chunk_idx INTEGER NOT NULL,
          data TEXT NOT NULL,
          PRIMARY KEY (room_id, msg_id, chunk_idx)
        );
        CREATE TABLE IF NOT EXISTS pending_counter (
          room_id TEXT PRIMARY KEY,
          next_id INTEGER NOT NULL
        );
      `);
    });
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(EMPTY_ATTACHMENT);
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---- attachment helpers (the Python global dicts, derived on demand) ----

  private att(ws: WebSocket): Attachment {
    return (ws.deserializeAttachment() as Attachment | null) ?? { ...EMPTY_ATTACHMENT, rooms: [] };
  }

  private setAtt(ws: WebSocket, a: Attachment): void {
    ws.serializeAttachment(a);
  }

  private socketOfUser(userId: string): WebSocket | null {
    for (const ws of this.ctx.getWebSockets()) {
      if (this.att(ws).userId === userId) return ws;
    }
    return null;
  }

  /** Occupant of a room slot — replaces rooms[room_id][role] + connected_users lookup. */
  private occupant(roomId: string, role: Role): WebSocket | null {
    for (const ws of this.ctx.getWebSockets()) {
      if (this.att(ws).rooms.some((r) => r.roomId === roomId && r.role === role)) return ws;
    }
    return null;
  }

  /** Python `room_id in rooms`: any occupied slot, or a pinned room (always present). */
  private roomExists(roomId: string): boolean {
    if (this.isPinned(roomId)) return true;
    for (const ws of this.ctx.getWebSockets()) {
      if (this.att(ws).rooms.some((r) => r.roomId === roomId)) return true;
    }
    return false;
  }

  private addRoomRef(ws: WebSocket, roomId: string, role: Role): void {
    const a = this.att(ws);
    a.rooms = a.rooms.filter((r) => r.roomId !== roomId);
    a.rooms.push({ roomId, role });
    this.setAtt(ws, a);
  }

  private removeRoomRef(ws: WebSocket, roomId: string): void {
    const a = this.att(ws);
    a.rooms = a.rooms.filter((r) => r.roomId !== roomId);
    this.setAtt(ws, a);
  }

  // ---- SQLite helpers ----

  private isBlocked(userId: string): boolean {
    return this.sql.exec("SELECT 1 FROM blocked_users WHERE user_id = ?", userId).toArray().length > 0;
  }

  private isPinned(roomId: string): boolean {
    return this.getPin(roomId) !== null;
  }

  private getPin(roomId: string): PinRow | null {
    const rows = this.sql.exec<PinRow>("SELECT * FROM pinned_rooms WHERE room_id = ?", roomId).toArray();
    return rows.length > 0 ? rows[0] : null;
  }

  private nextRoomId(): string {
    const rows = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'next_room_id'").toArray();
    const n = rows.length > 0 ? parseInt(rows[0].value, 10) : 1000; // 从1000开始的房间号
    this.sql.exec(
      "INSERT INTO meta (key, value) VALUES ('next_room_id', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      String(n + 1)
    );
    return String(n);
  }

  private pendingCount(roomId: string, queue: string): number {
    return Number(
      this.sql
        .exec<{ c: number }>("SELECT COUNT(*) AS c FROM pending_meta WHERE room_id = ? AND queue = ?", roomId, queue)
        .one().c
    );
  }

  private queuePendingMessage(roomId: string, queue: string, role: Role, encryptedAesKey: string, encryptedContent: string): void {
    const counter = this.sql
      .exec<{ next_id: number }>("SELECT next_id FROM pending_counter WHERE room_id = ?", roomId)
      .toArray();
    const msgId = counter.length > 0 ? Number(counter[0].next_id) : 0;
    this.sql.exec(
      "INSERT INTO pending_counter (room_id, next_id) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET next_id = excluded.next_id",
      roomId,
      msgId + 1
    );
    const chunkCount = Math.max(1, Math.ceil(encryptedContent.length / PENDING_CHUNK_CHARS));
    this.sql.exec(
      "INSERT INTO pending_meta (room_id, msg_id, queue, role, encrypted_aes_key, timestamp, chunk_count) VALUES (?, ?, ?, ?, ?, ?, ?)",
      roomId,
      msgId,
      queue,
      role,
      encryptedAesKey,
      utcTimestamp(),
      chunkCount
    );
    for (let i = 0; i < chunkCount; i++) {
      this.sql.exec(
        "INSERT INTO pending_chunks (room_id, msg_id, chunk_idx, data) VALUES (?, ?, ?, ?)",
        roomId,
        msgId,
        i,
        encryptedContent.slice(i * PENDING_CHUNK_CHARS, (i + 1) * PENDING_CHUNK_CHARS)
      );
    }
  }

  /** Stop-and-wait delivery: send only the queue head; pending_ack triggers the next. */
  private sendNextPending(ws: WebSocket, userId: string, roomId: string, role: Role): void {
    const queue = `for_${role}`;
    const rows = this.sql
      .exec<{ msg_id: number; encrypted_aes_key: string; timestamp: string }>(
        "SELECT msg_id, encrypted_aes_key, timestamp FROM pending_meta WHERE room_id = ? AND queue = ? ORDER BY msg_id LIMIT 1",
        roomId,
        queue
      )
      .toArray();
    if (rows.length === 0) return;
    const msg = rows[0];
    const content = this.sql
      .exec<{ data: string }>(
        "SELECT data FROM pending_chunks WHERE room_id = ? AND msg_id = ? ORDER BY chunk_idx",
        roomId,
        msg.msg_id
      )
      .toArray()
      .map((r) => r.data)
      .join("");
    const remaining = this.pendingCount(roomId, queue) - 1;
    this.send(ws, userId, {
      action: "pending_message",
      room_id: roomId,
      pending_msg_id: Number(msg.msg_id),
      encrypted_aes_key: msg.encrypted_aes_key,
      encrypted_content: content,
      timestamp: msg.timestamp,
      pending_count: remaining,
    });
    logMessage("SYSTEM", "Server", `Delivered pending msg ${msg.msg_id} (${remaining} remaining)`);
  }

  private deletePendingQueues(roomId: string): void {
    this.sql.exec("DELETE FROM pending_meta WHERE room_id = ?", roomId);
    this.sql.exec("DELETE FROM pending_chunks WHERE room_id = ?", roomId);
    this.sql.exec("DELETE FROM pending_counter WHERE room_id = ?", roomId);
  }

  // ---- send helper ----

  private send(ws: WebSocket, logUserId: string | null, obj: Record<string, unknown>): void {
    const s = JSON.stringify(obj);
    try {
      ws.send(s);
      logMessage("SENT", logUserId ?? "Unknown", s);
    } catch (e) {
      logMessage("SYSTEM", "Server", `Failed to send to ${logUserId}: ${e}`);
    }
  }

  /** Python check_available_user_in_data: requires user_id present and not blocked. */
  private checkAvailableUser(data: Record<string, unknown>, ws: WebSocket): boolean {
    const uid = data.user_id;
    if (typeof uid === "string" && !this.isBlocked(uid)) return true;
    this.send(ws, this.att(ws).userId, {
      action: "failed",
      message: "Your account has been blocked due to violations.",
    });
    return false;
  }

  // ---- hibernation handlers ----

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    const a = this.att(ws);
    logMessage("RECEIVED", a.userId ?? "Unknown", message);

    let data: Record<string, unknown>;
    try {
      data = JSON.parse(message);
    } catch {
      // Python: JSONDecodeError ends the connection handler (cleanup in finally)
      logMessage("SYSTEM", "Server", `Invalid JSON received from user ${a.userId}`);
      this.cleanupSocket(ws);
      ws.close(1003, "Invalid JSON");
      return;
    }

    try {
      this.dispatch(ws, data);
    } catch (e) {
      logMessage("SYSTEM", "Server", `An error occurred for user ${this.att(ws).userId}: ${e}`);
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    this.cleanupSocket(ws);
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    logMessage("SYSTEM", "Server", `Connection error: ${error}`);
    this.cleanupSocket(ws);
  }

  // ---- action dispatch (port of the Python handle_connection loop) ----

  private dispatch(ws: WebSocket, data: Record<string, unknown>): void {
    const action = data.action;
    switch (action) {
      case "login":
        this.handleLogin(ws, data);
        break;
      case "create_room":
        this.handleCreateRoom(ws, data);
        break;
      case "join_room":
        this.handleJoinRoom(ws, data);
        break;
      case "leave_room":
        this.handleLeaveRoom(ws, data);
        break;
      case "typing":
      case "heart_rate":
        this.handleRelay(ws, data, action);
        break;
      case "send_message":
        this.handleSendMessage(ws, data);
        break;
      case "request_pin":
        this.handlePinRelay(ws, data, "pin_requested");
        break;
      case "reject_pin":
        this.handlePinRelay(ws, data, "pin_rejected");
        break;
      case "accept_pin":
        this.handleAcceptPin(ws, data);
        break;
      case "unpin_room":
        this.handleUnpinRoom(ws, data);
        break;
      case "pending_ack":
        this.handlePendingAck(ws, data);
        break;
      case "report_user":
        this.handleReportUser(ws, data);
        break;
      default:
        break;
    }
  }

  private handleLogin(ws: WebSocket, data: Record<string, unknown>): void {
    const userId = data.user_id as string;
    if (this.isBlocked(userId)) {
      this.send(ws, userId, {
        action: "login_failed",
        message: "Your account has been blocked due to violations.",
      });
      logMessage("SYSTEM", "Server", `Blocked user ${userId} attempted to login`);
      return;
    }
    const a = this.att(ws);
    a.userId = userId; // Python sets connected_users before the key-size check
    const publicKeyPem = (data.public_key as string) ?? "";
    if (publicKeyPem.length > MAX_PUBLIC_KEY_LEN) {
      this.setAtt(ws, a);
      logMessage("SYSTEM", "Server", `User ${userId} sent oversized public key (${publicKeyPem.length}B), rejected`);
      return;
    }
    a.publicKey = publicKeyPem;
    this.setAtt(ws, a);
    const clientVersion = (data.client_version as string) ?? "unknown";
    logMessage("SYSTEM", "Server", `User ${userId} logged in (v${clientVersion})`);
  }

  private handleCreateRoom(ws: WebSocket, data: Record<string, unknown>): void {
    if (!this.checkAvailableUser(data, ws)) {
      logMessage("SYSTEM", "Server", `Blocked user ${this.att(ws).userId} attempted to create room`);
      return;
    }
    const userId = this.att(ws).userId;
    if (!userId) return; // client always logs in first
    let hostedRooms = 0;
    for (const other of this.ctx.getWebSockets()) {
      const oa = this.att(other);
      if (oa.userId === userId) hostedRooms += oa.rooms.filter((r) => r.role === "host").length;
    }
    if (hostedRooms >= 3) {
      this.send(ws, userId, { action: "error", message: "Too many active rooms. Please close existing rooms first." });
      return;
    }
    const roomId = this.nextRoomId();
    this.addRoomRef(ws, roomId, "host");
    this.send(ws, userId, { action: "room_created", room_id: roomId, role: "host", pinned: false });
  }

  private handleJoinRoom(ws: WebSocket, data: Record<string, unknown>): void {
    if (!this.checkAvailableUser(data, ws)) {
      logMessage("SYSTEM", "Server", `Blocked user ${this.att(ws).userId} attempted to join room`);
      return;
    }
    const roomId = data.room_id as string;
    const userId = this.att(ws).userId;
    const pin = this.getPin(roomId);

    if (pin) {
      let rejoinRole: Role | null = null;
      if (pin.host_user_id === userId) rejoinRole = "host";
      else if (pin.guest_user_id === userId) rejoinRole = "guest";

      if (rejoinRole) {
        // Reject rejoin if client presents a different public key — pending
        // messages were encrypted with the stored key and would be undecryptable.
        if ("public_key" in data) {
          const storedKey = rejoinRole === "host" ? pin.host_public_key : pin.guest_public_key;
          if (storedKey && data.public_key !== storedKey) {
            this.send(ws, userId, {
              action: "error",
              message:
                "Key mismatch: your key has changed and no longer matches this pinned room. Please unpin and start a new room.",
            });
            return;
          }
        }

        this.addRoomRef(ws, roomId, rejoinRole);

        const peerRole = otherRole(rejoinRole);
        const peerUserId = peerRole === "host" ? pin.host_user_id : pin.guest_user_id;
        const peerPublicKey = peerRole === "host" ? pin.host_public_key : pin.guest_public_key;
        const peerSocket = this.occupant(roomId, peerRole);
        const pendingCount = this.pendingCount(roomId, `for_${rejoinRole}`);

        this.send(ws, userId, {
          action: "room_joined",
          room_id: roomId,
          role: rejoinRole,
          peer_role: peerRole,
          peer_user_id: peerUserId,
          peer_public_key: peerPublicKey,
          pinned: true,
          peer_status: peerSocket ? "online" : "offline",
          pending_count: pendingCount,
        });

        this.sendNextPending(ws, userId!, roomId, rejoinRole);

        if (peerSocket) {
          const rejoinerStoredKey = rejoinRole === "host" ? pin.host_public_key : pin.guest_public_key;
          this.send(peerSocket, peerUserId, {
            action: "user_joined",
            room_id: roomId,
            role: peerRole,
            peer_role: rejoinRole,
            peer_user_id: userId,
            peer_public_key: rejoinerStoredKey,
          });
        }
      } else {
        this.send(ws, userId, { action: "error", message: "Room is pinned and you are not a member" });
      }
      return;
    }

    // Normal join (non-pinned room, guest slot empty)
    const hostSocket = this.occupant(roomId, "host");
    const guestSocket = this.occupant(roomId, "guest");
    if (hostSocket && !guestSocket) {
      this.addRoomRef(ws, roomId, "guest");
      const hostAtt = this.att(hostSocket);
      this.send(ws, userId, {
        action: "room_joined",
        room_id: roomId,
        role: "guest",
        peer_role: "host",
        peer_user_id: hostAtt.userId,
        peer_public_key: hostAtt.publicKey,
        pinned: false,
      });
      this.send(hostSocket, hostAtt.userId, {
        action: "user_joined",
        room_id: roomId,
        role: "host",
        peer_role: "guest",
        peer_user_id: userId,
        peer_public_key: this.att(ws).publicKey,
      });
    } else {
      this.send(ws, userId, { action: "error", message: "Room not found or already full" });
    }
  }

  private handleLeaveRoom(ws: WebSocket, data: Record<string, unknown>): void {
    const roomId = data.room_id as string;
    const role = data.role as Role;
    const leaveUserId = (data.user_id as string) ?? this.att(ws).userId;

    const occupied = this.occupant(roomId, role);
    if (!occupied || this.att(occupied).userId !== leaveUserId) return;

    this.removeRoomRef(occupied, roomId);
    const peerSocket = this.occupant(roomId, otherRole(role));

    if (this.isPinned(roomId)) {
      // Pinned room: only clear slot, notify peer of offline status
      if (peerSocket) {
        this.send(peerSocket, this.att(peerSocket).userId, { action: "peer_status", room_id: roomId, status: "offline" });
      }
    } else {
      if (peerSocket) {
        this.send(peerSocket, this.att(peerSocket).userId, { action: "user_left", room_id: roomId, role });
      }
      // 如果离开的是 host，则关闭房间
      if (role === "host" && peerSocket) {
        this.send(peerSocket, this.att(peerSocket).userId, { action: "room_closed", room_id: roomId });
        this.removeRoomRef(peerSocket, roomId);
      }
    }
  }

  /** typing / heart_rate: direct relay to the peer, no queuing. */
  private handleRelay(ws: WebSocket, data: Record<string, unknown>, action: "typing" | "heart_rate"): void {
    const roomId = data.room_id as string;
    const role = data.role as Role;
    const peerSocket = this.occupant(roomId, otherRole(role));
    if (peerSocket) {
      this.send(peerSocket, this.att(peerSocket).userId, {
        action,
        room_id: roomId,
        role,
        encrypted_aes_key: data.encrypted_aes_key,
        encrypted_content: data.encrypted_content,
      });
    }
  }

  private handleSendMessage(ws: WebSocket, data: Record<string, unknown>): void {
    const seq = data.seq;
    const roomId = data.room_id as string;
    const role = data.role as Role;
    const encryptedAesKey = data.encrypted_aes_key as string;
    const encryptedContent = data.encrypted_content as string;

    if (this.roomExists(roomId)) {
      const peerSocket = this.occupant(roomId, otherRole(role));
      if (peerSocket) {
        // Peer is online, deliver immediately
        this.send(peerSocket, this.att(peerSocket).userId, {
          action: "new_message",
          room_id: roomId,
          role,
          encrypted_aes_key: encryptedAesKey,
          encrypted_content: encryptedContent,
        });
      } else if (this.isPinned(roomId)) {
        // Peer is offline, queue message for pinned room
        const msgSize = new TextEncoder().encode(encryptedContent).length;
        if (msgSize > MAX_PENDING_BYTES) {
          this.send(ws, this.att(ws).userId, {
            action: "error",
            message: "Message too large to queue for offline peer (max 5 MB).",
          });
        } else {
          this.queuePendingMessage(roomId, `for_${otherRole(role)}`, role, encryptedAesKey, encryptedContent);
          logMessage("SYSTEM", "Server", `Queued message for offline peer in pinned room ${roomId}`);
        }
      }
    }
    if (seq !== undefined && seq !== null) {
      this.send(ws, this.att(ws).userId, { action: "ack", seq });
    }
  }

  private handlePinRelay(ws: WebSocket, data: Record<string, unknown>, notifyAction: "pin_requested" | "pin_rejected"): void {
    const roomId = data.room_id as string;
    const role = data.role as Role;
    const peerSocket = this.occupant(roomId, otherRole(role));
    if (peerSocket) {
      this.send(peerSocket, this.att(peerSocket).userId, { action: notifyAction, room_id: roomId });
    }
  }

  private handleAcceptPin(ws: WebSocket, data: Record<string, unknown>): void {
    const roomId = data.room_id as string;
    const hostSocket = this.occupant(roomId, "host");
    const guestSocket = this.occupant(roomId, "guest");
    if (!hostSocket || !guestSocket) return;

    const hostAtt = this.att(hostSocket);
    const guestAtt = this.att(guestSocket);
    if (!hostAtt.userId || !guestAtt.userId) return;

    this.sql.exec(
      "INSERT INTO pinned_rooms (room_id, host_user_id, guest_user_id, host_public_key, guest_public_key) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET host_user_id = excluded.host_user_id, guest_user_id = excluded.guest_user_id, host_public_key = excluded.host_public_key, guest_public_key = excluded.guest_public_key",
      roomId,
      hostAtt.userId,
      guestAtt.userId,
      hostAtt.publicKey,
      guestAtt.publicKey
    );
    // Init pending message queues (fresh, like Python's pending_messages[room_id] = {...})
    this.deletePendingQueues(roomId);
    this.sql.exec("INSERT INTO pending_counter (room_id, next_id) VALUES (?, 0)", roomId);
    logMessage("SYSTEM", "Server", `Room ${roomId} pinned`);

    for (const [sock, att, peerAtt] of [
      [hostSocket, hostAtt, guestAtt],
      [guestSocket, guestAtt, hostAtt],
    ] as const) {
      this.send(sock, att.userId, {
        action: "pin_accepted",
        room_id: roomId,
        peer_public_key: peerAtt.publicKey,
        peer_user_id: peerAtt.userId,
      });
    }
  }

  private handleUnpinRoom(ws: WebSocket, data: Record<string, unknown>): void {
    const roomId = data.room_id as string;
    const role = data.role as Role;
    const pin = this.getPin(roomId);
    if (!pin) return;

    // Notify peer (by user id — Python notifies any connected peer, in the room or not)
    const peerUserId = otherRole(role) === "host" ? pin.host_user_id : pin.guest_user_id;
    const peerSocket = peerUserId ? this.socketOfUser(peerUserId) : null;
    if (peerSocket) {
      this.send(peerSocket, peerUserId, { action: "room_unpinned", room_id: roomId });
    }

    // Clean up
    this.sql.exec("DELETE FROM pinned_rooms WHERE room_id = ?", roomId);
    this.deletePendingQueues(roomId);
    for (const sock of this.ctx.getWebSockets()) {
      if (this.att(sock).rooms.some((r) => r.roomId === roomId)) this.removeRoomRef(sock, roomId);
    }
    logMessage("SYSTEM", "Server", `Room ${roomId} unpinned`);
  }

  private handlePendingAck(ws: WebSocket, data: Record<string, unknown>): void {
    const roomId = data.room_id as string;
    const role = data.role as Role;
    const pendingMsgId = data.pending_msg_id as number;
    const userId = this.att(ws).userId;

    const occupied = this.occupant(roomId, role);
    if (!occupied || this.att(occupied).userId !== userId) {
      logMessage("SYSTEM", "Server", `Unauthorized pending_ack from ${userId} for room ${roomId} role ${role}`);
      return;
    }

    const queue = `for_${role}`;
    const existing = this.sql
      .exec("SELECT 1 FROM pending_meta WHERE room_id = ? AND msg_id = ? AND queue = ?", roomId, pendingMsgId, queue)
      .toArray();
    if (existing.length > 0) {
      this.sql.exec("DELETE FROM pending_meta WHERE room_id = ? AND msg_id = ?", roomId, pendingMsgId);
      this.sql.exec("DELETE FROM pending_chunks WHERE room_id = ? AND msg_id = ?", roomId, pendingMsgId);
      logMessage("SYSTEM", "Server", `Deleted pending msg ${pendingMsgId} for ${role} in room ${roomId}`);
      // Stop-and-wait: deliver the next queued message, if any
      this.sendNextPending(ws, userId!, roomId, role);
    }
  }

  private handleReportUser(ws: WebSocket, data: Record<string, unknown>): void {
    const reportedId = data.reported_user_id as string | undefined;
    const a = this.att(ws);
    const inSameRoom =
      !!reportedId &&
      a.rooms.some((r) => {
        const peer = this.occupant(r.roomId, otherRole(r.role));
        return peer !== null && this.att(peer).userId === reportedId;
      });
    if (!inSameRoom) {
      logMessage("SYSTEM", "Server", `User ${a.userId} attempted to report ${reportedId} but they are not in the same room`);
      return;
    }
    if (reportedId && !this.isBlocked(reportedId)) {
      this.sql.exec("INSERT INTO blocked_users (user_id) VALUES (?)", reportedId);
      // 如果被举报用户在线，强制其断开连接
      const reportedSocket = this.socketOfUser(reportedId);
      if (reportedSocket) {
        this.send(reportedSocket, reportedId, {
          action: "blocked",
          message: "Your account has been blocked due to violations.",
        });
        reportedSocket.close(1000, "Blocked");
      }
    }
  }

  /** Port of Python cleanup_user: runs on disconnect for each room this socket occupies. */
  private cleanupSocket(ws: WebSocket): void {
    const a = this.att(ws);
    if (!a.userId) {
      return;
    }
    for (const { roomId, role } of a.rooms) {
      const peerSocket = this.occupant(roomId, otherRole(role));
      if (this.isPinned(roomId)) {
        // Pinned room: only clear slot, send peer_status offline
        if (peerSocket) {
          this.send(peerSocket, this.att(peerSocket).userId, { action: "peer_status", room_id: roomId, status: "offline" });
        }
      } else {
        if (peerSocket) {
          this.send(peerSocket, this.att(peerSocket).userId, { action: "user_left", room_id: roomId, role });
        }
        if (role === "host" && peerSocket) {
          this.send(peerSocket, this.att(peerSocket).userId, { action: "room_closed", room_id: roomId });
          this.removeRoomRef(peerSocket, roomId);
        }
      }
    }
    logMessage("SYSTEM", "Server", `User ${a.userId} logged out`);
    // Idempotency: a socket can surface both close and error events
    this.setAtt(ws, { userId: null, publicKey: "", rooms: [] });
  }
}
