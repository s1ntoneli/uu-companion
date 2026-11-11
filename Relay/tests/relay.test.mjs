import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { RelayRoom } from '../worker.mjs';

class Socket {
  constructor() { this.sent = []; this.readyState = 1; this.attachment = null; }
  serializeAttachment(a) { this.attachment = a; }
  deserializeAttachment() { return this.attachment; }
  send(m) { if(this.readyState !== 1) throw new Error('socket closed'); this.sent.push(m); }
  close(code=1000,reason='') { this.readyState = 3; this.closeCode=code; this.closeReason=reason; }
}
// Node's standards Response rejects status 101; Cloudflare Workers accepts
// Response({status:101, webSocket}). Emulate just that runtime extension.
const NodeResponse = globalThis.Response;
globalThis.Response = class extends NodeResponse {
  constructor(body, options) {
    if (options?.status === 101) {
      super(null, {status:200});
      this._workerStatus = 101;
      this.webSocket = options.webSocket;
    } else {
      super(body, options);
    }
  }
  get status() { return this._workerStatus ?? super.status; }
};
globalThis.WebSocketPair = class {
  constructor() {
    this[0] = new Socket();
    this[1] = new Socket();
  }
};
const ctx = () => {
  const sockets = [];
  return {
    sockets,
    acceptWebSocket(socket, tags) { socket.tags = tags; sockets.push(socket); },
    getWebSockets(tag) { return sockets.filter(s => s.tags.includes(tag) && s.readyState === 1); },
  };
};
const req = (role, path='a'.repeat(64)) =>
  new Request('https://relay.example/v1/rooms/'+path+'?role='+role, {
    headers: { Upgrade: 'websocket' },
  });
function create() {
  const context=ctx();
  const room=new RelayRoom(context, {});
  return { context, room };
}
test('health endpoint requires no login and does not reveal keys', async () => {
  const res=await worker.fetch(new Request('https://relay.example/health'),{});
  assert.equal(res.status,200);
  assert.deepEqual(await res.json(),{ok:true,service:'uu-relay',version:1,noAccounts:true});
});
test('only exact 64-hex rooms and WebSocket upgrades are accepted', async () => {
  const env={ROOMS:{getByName:()=>({fetch:()=>new Response('ok')})}};
  assert.equal((await worker.fetch(new Request('https://relay.example/v1/rooms/short'),env)).status,404);
  assert.equal((await worker.fetch(new Request('https://relay.example/v1/rooms/'+'A'.repeat(64)),env)).status,404);
  assert.equal((await worker.fetch(new Request('https://relay.example/v1/rooms/'+'a'.repeat(64)),env)).status,426);
  assert.equal((await worker.fetch(req('unknown'),env)).status,400);
});
test('one sender & receiver pair with online notifications', async () => {
  const {context,room}=create();
  await room.fetch(req('sender'));
  await room.fetch(req('receiver'));
  const [sender,receiver]=context.sockets;
  assert.equal(JSON.parse(sender.sent.at(-1)).online,true);
  assert.equal(JSON.parse(receiver.sent[0]).online,true);
});
test('relay forwards only binary opaque data, never plaintext', async () => {
  const {context,room}=create();
  await room.fetch(req('sender'));
  await room.fetch(req('receiver'));
  const [sender,receiver]=context.sockets;
  const opaque=new Uint8Array(64).map((_,i)=>i).buffer;
  room.webSocketMessage(sender,opaque);
  assert.equal(receiver.sent.at(-1),opaque);
  room.webSocketMessage(sender,'plaintext microphone audio');
  assert.equal(sender.readyState,3);
  assert.equal(sender.closeCode,1003);
});
test('oversized encrypted frames are rejected',async()=>{
  const {context,room}=create();
  await room.fetch(req('sender'));
  room.webSocketMessage(context.sockets[0],new ArrayBuffer(65537));
  assert.equal(context.sockets[0].closeCode,1009);
});
test('reconnecting replaces a stale role without sending a false offline event',async()=>{
  const {context,room}=create();
  await room.fetch(req('sender'));
  await room.fetch(req('receiver'));
  const previous=context.sockets[0];
  const receiver=context.sockets[1];
  const n=receiver.sent.length;
  await room.fetch(req('sender'));
  const replacement=context.sockets[2];
  assert.equal(previous.readyState,3);
  assert.equal(replacement.readyState,1);
  room.webSocketClose(previous);
  assert.equal(receiver.sent.slice(n).every(s=>JSON.parse(s).online===true),true);
});
