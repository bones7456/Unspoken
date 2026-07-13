#!/usr/bin/env node
// Protocol integration test for the Unspoken server.
// Works against both the Durable Objects server (wrangler dev / production)
// and the original Python server (python3 unspoken.py --no-ssl), to prove parity.
//
// Usage: node test/protocol-test.mjs [ws://localhost:8787]

const SERVER_URL = process.argv[2] ?? "ws://localhost:8787";
const EXPECT_TIMEOUT_MS = 5000;

const run = Math.random().toString(36).slice(2, 8);
const uid = (name) => `test_${name}_${run}`;

const PEM_A = "-----BEGIN PUBLIC KEY-----\n" + "A".repeat(360) + "\n-----END PUBLIC KEY-----";
const PEM_B = "-----BEGIN PUBLIC KEY-----\n" + "B".repeat(360) + "\n-----END PUBLIC KEY-----";

let passed = 0;
let stepNo = 0;

function step(desc) {
  stepNo++;
  console.log(`\n[${stepNo}] ${desc}`);
}

function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(`ASSERT ${label}: expected ${e}, got ${a}`);
  }
  console.log(`    ok: ${label} = ${e.length > 60 ? e.slice(0, 60) + "…" : e}`);
  passed++;
}

class Client {
  constructor(name) {
    this.name = name;
    this.inbox = [];
    this.waiters = [];
    this.closed = false;
  }

  async connect() {
    this.ws = new WebSocket(SERVER_URL);
    this.ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      this.inbox.push(msg);
      for (const w of this.waiters) w();
    });
    this.ws.addEventListener("close", () => {
      this.closed = true;
      for (const w of this.waiters) w();
    });
    await new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", () => reject(new Error(`${this.name}: connect failed`)), { once: true });
    });
  }

  send(obj) {
    this.ws.send(JSON.stringify(obj));
  }

  /** Wait for the first inbox message with the given action (FIFO per action). */
  expect(action, timeoutMs = EXPECT_TIMEOUT_MS) {
    return new Promise((resolve, reject) => {
      const scan = () => {
        const i = this.inbox.findIndex((m) => m.action === action);
        if (i >= 0) {
          const [msg] = this.inbox.splice(i, 1);
          cleanup();
          resolve(msg);
          return true;
        }
        return false;
      };
      const timer = setTimeout(() => {
        cleanup();
        reject(
          new Error(
            `${this.name}: timed out waiting for '${action}'. Inbox: ${JSON.stringify(this.inbox.map((m) => m.action))}`
          )
        );
      }, timeoutMs);
      const waiter = () => scan();
      const cleanup = () => {
        clearTimeout(timer);
        this.waiters = this.waiters.filter((w) => w !== waiter);
      };
      if (!scan()) this.waiters.push(waiter);
    });
  }

  /** Assert no message with the given action arrives within the window. */
  async expectNone(action, windowMs = 800) {
    await new Promise((r) => setTimeout(r, windowMs));
    const found = this.inbox.find((m) => m.action === action);
    if (found) throw new Error(`${this.name}: unexpected '${action}': ${JSON.stringify(found).slice(0, 200)}`);
    console.log(`    ok: ${this.name} received no '${action}'`);
    passed++;
  }

  waitClosed(timeoutMs = EXPECT_TIMEOUT_MS) {
    if (this.closed) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.name}: not closed`)), timeoutMs);
      this.ws.addEventListener(
        "close",
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true }
      );
    });
  }

  close() {
    if (!this.closed) this.ws.close();
  }
}

async function connectAndLogin(name, userId, publicKey) {
  const c = new Client(name);
  await c.connect();
  c.send({ action: "login", user_id: userId, public_key: publicKey, client_version: "test" });
  return c;
}

async function main() {
  console.log(`Testing against ${SERVER_URL}`);
  const userA = uid("a");
  const userB = uid("b");
  const userC = uid("c");
  const userD = uid("d");

  // --- basic room lifecycle ---
  step("A logs in and creates a room");
  const a = await connectAndLogin("A", userA, PEM_A);
  a.send({ action: "create_room", user_id: userA });
  const created = await a.expect("room_created");
  eq(created.role, "host", "room_created.role");
  eq(created.pinned, false, "room_created.pinned");
  const roomId = created.room_id;
  console.log(`    room_id = ${roomId}`);

  step("B joins the room; both sides learn peer keys");
  let b = await connectAndLogin("B", userB, PEM_B);
  b.send({ action: "join_room", room_id: roomId, user_id: userB });
  const joined = await b.expect("room_joined");
  eq(joined.role, "guest", "room_joined.role");
  eq(joined.peer_role, "host", "room_joined.peer_role");
  eq(joined.peer_user_id, userA, "room_joined.peer_user_id");
  eq(joined.peer_public_key, PEM_A, "room_joined.peer_public_key");
  eq(joined.pinned, false, "room_joined.pinned");
  const aJoined = await a.expect("user_joined");
  eq(aJoined.peer_user_id, userB, "user_joined.peer_user_id");
  eq(aJoined.peer_public_key, PEM_B, "user_joined.peer_public_key");

  step("Join a full/nonexistent room fails");
  const c0 = await connectAndLogin("C0", userC, "PEM_C");
  c0.send({ action: "join_room", room_id: roomId, user_id: userC });
  eq((await c0.expect("error")).message, "Room not found or already full", "full room error");
  c0.send({ action: "join_room", room_id: "999999", user_id: userC });
  eq((await c0.expect("error")).message, "Room not found or already full", "missing room error");
  c0.close();

  step("A sends a message with seq; B receives, A gets ack");
  a.send({ action: "send_message", room_id: roomId, role: "host", encrypted_aes_key: "k1", encrypted_content: "c1", seq: 1 });
  const nm = await b.expect("new_message");
  eq(nm.role, "host", "new_message.role");
  eq(nm.encrypted_content, "c1", "new_message.encrypted_content");
  eq((await a.expect("ack")).seq, 1, "ack.seq");

  step("typing and heart_rate relay");
  b.send({ action: "typing", room_id: roomId, role: "guest", encrypted_aes_key: "k2", encrypted_content: "t" });
  eq((await a.expect("typing")).encrypted_content, "t", "typing relayed");
  b.send({ action: "heart_rate", room_id: roomId, role: "guest", encrypted_aes_key: "k3", encrypted_content: "72" });
  eq((await a.expect("heart_rate")).encrypted_content, "72", "heart_rate relayed");

  // --- pin flow ---
  step("Pin request rejected, then requested again and accepted");
  a.send({ action: "request_pin", room_id: roomId, role: "host" });
  await b.expect("pin_requested");
  passed++;
  b.send({ action: "reject_pin", room_id: roomId, role: "guest" });
  await a.expect("pin_rejected");
  passed++;
  a.send({ action: "request_pin", room_id: roomId, role: "host" });
  await b.expect("pin_requested");
  b.send({ action: "accept_pin", room_id: roomId, role: "guest" });
  const pinA = await a.expect("pin_accepted");
  eq(pinA.peer_user_id, userB, "pin_accepted(A).peer_user_id");
  eq(pinA.peer_public_key, PEM_B, "pin_accepted(A).peer_public_key");
  const pinB = await b.expect("pin_accepted");
  eq(pinB.peer_user_id, userA, "pin_accepted(B).peer_user_id");

  step("B disconnects; A sees peer_status offline (pinned room)");
  b.close();
  eq((await a.expect("peer_status")).status, "offline", "peer_status.status");

  // --- offline queue ---
  step("A queues messages for offline B: small, 2.5MB (chunked), >5MB rejected");
  a.send({ action: "send_message", room_id: roomId, role: "host", encrypted_aes_key: "pk0", encrypted_content: "pending-small", seq: 2 });
  eq((await a.expect("ack")).seq, 2, "ack.seq for queued small");
  const big = "X".repeat(2_500_000) + "END";
  a.send({ action: "send_message", room_id: roomId, role: "host", encrypted_aes_key: "pk1", encrypted_content: big, seq: 3 });
  eq((await a.expect("ack")).seq, 3, "ack.seq for queued big");
  const tooBig = "Y".repeat(5 * 1024 * 1024 + 1);
  a.send({ action: "send_message", room_id: roomId, role: "host", encrypted_aes_key: "pk2", encrypted_content: tooBig, seq: 4 });
  eq((await a.expect("error")).message, "Message too large to queue for offline peer (max 5 MB).", "oversize error");
  eq((await a.expect("ack")).seq, 4, "ack.seq still sent after oversize");

  step("Rejoin with wrong key is rejected");
  const bWrong = await connectAndLogin("B-wrong", userB, "WRONG_KEY");
  bWrong.send({ action: "join_room", room_id: roomId, user_id: userB, public_key: "WRONG_KEY" });
  const mismatch = await bWrong.expect("error");
  eq(
    mismatch.message,
    "Key mismatch: your key has changed and no longer matches this pinned room. Please unpin and start a new room.",
    "key mismatch error"
  );
  bWrong.close();

  step("Non-member cannot join the pinned room");
  const c1 = await connectAndLogin("C1", userC, "PEM_C");
  c1.send({ action: "join_room", room_id: roomId, user_id: userC });
  eq((await c1.expect("error")).message, "Room is pinned and you are not a member", "non-member error");
  c1.close();

  step("B rejoins with correct key; gets pending_count=2 and stop-and-wait delivery");
  b = await connectAndLogin("B", userB, PEM_B);
  b.send({ action: "join_room", room_id: roomId, user_id: userB, public_key: PEM_B });
  const rejoin = await b.expect("room_joined");
  eq(rejoin.pinned, true, "rejoin.pinned");
  eq(rejoin.peer_status, "online", "rejoin.peer_status");
  eq(rejoin.pending_count, 2, "rejoin.pending_count");
  eq(rejoin.peer_public_key, PEM_A, "rejoin.peer_public_key");
  await a.expect("user_joined");
  passed++;

  const p0 = await b.expect("pending_message");
  eq(p0.encrypted_content, "pending-small", "pending[0].content");
  eq(p0.pending_count, 1, "pending[0].pending_count");
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(p0.timestamp)) {
    throw new Error(`bad pending timestamp: ${p0.timestamp}`);
  }
  console.log(`    ok: pending timestamp format (${p0.timestamp})`);
  passed++;

  step("pending_ack delivers the next (chunked 2.5MB) message intact");
  b.send({ action: "pending_ack", room_id: roomId, role: "guest", pending_msg_id: p0.pending_msg_id });
  const p1 = await b.expect("pending_message", 15000);
  eq(p1.encrypted_content.length, big.length, "pending[1].content length");
  eq(p1.encrypted_content === big, true, "pending[1].content identical");
  eq(p1.pending_count, 0, "pending[1].pending_count");
  b.send({ action: "pending_ack", room_id: roomId, role: "guest", pending_msg_id: p1.pending_msg_id });
  await b.expectNone("pending_message");

  step("B leaves pinned room (slot only); A sees peer_status offline");
  b.send({ action: "leave_room", room_id: roomId, role: "guest", user_id: userB });
  eq((await a.expect("peer_status")).status, "offline", "leave pinned → peer_status");

  step("A unpins; B (connected, outside room) receives room_unpinned");
  a.send({ action: "unpin_room", room_id: roomId, role: "host" });
  eq((await b.expect("room_unpinned")).room_id, roomId, "room_unpinned.room_id");
  b.close();

  // --- non-pinned room closes when host leaves ---
  step("Host leaving a non-pinned room closes it for the guest");
  a.send({ action: "create_room", user_id: userA });
  const room2 = (await a.expect("room_created")).room_id;
  const c = await connectAndLogin("C", userC, "PEM_C");
  c.send({ action: "join_room", room_id: room2, user_id: userC });
  await c.expect("room_joined");
  await a.expect("user_joined");
  a.send({ action: "leave_room", room_id: room2, role: "host", user_id: userA });
  await c.expect("user_left");
  await c.expect("room_closed");
  passed += 2;
  console.log("    ok: user_left + room_closed");

  // --- report / block ---
  step("C reports D; D is blocked, disconnected, and cannot log back in");
  c.send({ action: "create_room", user_id: userC });
  const room3 = (await c.expect("room_created")).room_id;
  const d = await connectAndLogin("D", userD, "PEM_D");
  d.send({ action: "join_room", room_id: room3, user_id: userD });
  await d.expect("room_joined");
  await c.expect("user_joined");
  c.send({ action: "report_user", reported_user_id: userD, user_id: userC });
  eq((await d.expect("blocked")).message, "Your account has been blocked due to violations.", "blocked message");
  await d.waitClosed();
  console.log("    ok: D disconnected");
  passed++;
  await c.expect("user_left"); // D's disconnect cleans up the room
  passed++;

  const d2 = await connectAndLogin("D2", userD, "PEM_D");
  eq((await d2.expect("login_failed")).message, "Your account has been blocked due to violations.", "login_failed");
  d2.send({ action: "create_room", user_id: userD });
  eq((await d2.expect("failed")).message, "Your account has been blocked due to violations.", "create_room failed");
  d2.close();

  step("Room limit: a 4th hosted room is rejected");
  const e = await connectAndLogin("E", uid("e"), "PEM_E");
  for (let i = 0; i < 3; i++) {
    e.send({ action: "create_room", user_id: uid("e") });
    await e.expect("room_created");
  }
  e.send({ action: "create_room", user_id: uid("e") });
  eq((await e.expect("error")).message, "Too many active rooms. Please close existing rooms first.", "room limit error");
  e.close();

  a.close();
  c.close();
  console.log(`\nAll steps passed (${passed} assertions).`);
  process.exit(0);
}

main().catch((err) => {
  console.error(`\nFAILED: ${err.message}`);
  process.exit(1);
});
