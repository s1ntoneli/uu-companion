/*
 * uu伴侣 rendezvous + encrypted-frame relay.
 * Cloudflare Worker/Durable Object, MIT. No accounts, database, audio decoding
 * or knowledge of pair codes / session keys. One room per SHA-256 code digest.
 */
const ROOM_RE = /^\/v1\/rooms\/([0-9a-f]{64})$/;
const MAX_FRAME = 65536;
const REPLY = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "access-control-allow-origin": "*" };
function json(payload, status = 200) { return new Response(JSON.stringify(payload), { status, headers: REPLY }); }
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") {
      return json({ ok: true, service: "uu-relay", version: 1, noAccounts: true });
    }
    const matched = ROOM_RE.exec(url.pathname);
    if (!matched) return json({ error: "not_found" }, 404);
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return json({ error: "websocket_required" }, 426);
    const role = url.searchParams.get("role");
    if (role !== "sender" && role !== "receiver") return json({ error: "invalid_role" }, 400);
    return env.ROOMS.getByName(matched[1]).fetch(request);
  }
};
export class RelayRoom {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  async fetch(request) {
    const role = new URL(request.url).searchParams.get("role");
    if (role !== "sender" && role !== "receiver") return json({ error: "invalid_role" }, 400);
    if (this.ctx.getWebSockets(role).length > 0) return json({ error: "role_in_use" }, 409);
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role });
    const other = role === "sender" ? "receiver" : "sender";
    const online = this.ctx.getWebSockets(other).length !== 0;
    server.send(JSON.stringify({ type: "peer", online }));
    for (const peer of this.ctx.getWebSockets(other)) {
      try { peer.send(JSON.stringify({ type: "peer", online: true })); } catch {}
    }
    return new Response(null, { status: 101, webSocket: client });
  }
  webSocketMessage(socket, message) {
    const role = socket.deserializeAttachment()?.role;
    if (role !== "sender" && role !== "receiver") { socket.close(1008, "invalid_role"); return; }
    if (typeof message === "string") {
      if (message === "ping") { socket.send("pong"); return; }
      socket.close(1003, "encrypted_binary_only"); return;
    }
    if (!(message instanceof ArrayBuffer) || message.byteLength > MAX_FRAME || message.byteLength < 28) {
      socket.close(1009, "invalid_frame"); return;
    }
    const other = role === "sender" ? "receiver" : "sender";
    for (const peer of this.ctx.getWebSockets(other)) {
      try { peer.send(message); } catch {}
    }
  }
  webSocketClose(socket) { this.depart(socket); }
  webSocketError(socket) { this.depart(socket); }
  depart(socket) {
    const role = socket.deserializeAttachment()?.role;
    const other = role === "sender" ? "receiver" : "sender";
    for (const peer of this.ctx.getWebSockets(other)) {
      try { peer.send(JSON.stringify({ type: "peer", online: false })); } catch {}
    }
    try { socket.close(); } catch {}
  }
}
