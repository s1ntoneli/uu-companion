# uu Relay — open-source free rendezvous & encrypted media forwarding

Public endpoint: https://uu-companion-relay.auv1107.workers.dev/health

This Cloudflare Worker + Durable Object allows an accountless sender and receiver to establish outbound WebSockets. It relays only opaque encrypted frames (ChaChaPoly encrypted on client devices), never plaintext audio. One WebSocket per role per room, no persistent room database, hibernating sockets at idle.

## Self-host for free

1. Create your own Cloudflare account (free plan supported).
2. Create an API token with Workers Script Edit permissions; obtain your account ID.
3. Run from the repository root:
    CLOUDFLARE_ACCOUNT_ID=YOUR_ID CLOUDFLARE_API_TOKEN=YOUR_TOKEN python3 Relay/deploy.py
4. The script prints your own secure WSS endpoint. Set it on BOTH Macs via uu伴侣 menu → 发现 / 中继服务器….

No Node.js installation or user accounts are required for the server. The deployer uses only Python standard library, uploads the Worker module, applies the Durable Object SQLite migration for RelayRoom, and enables workers.dev. Never commit your Cloudflare credentials.

## Protocol for alternate self-hosted implementations

- WebSocket endpoint: /v1/rooms/{64-lowercase-hex}?role=sender|receiver
- Room ID is the domain-separated SHA-256 hash of a long random pairing code; server never receives the original code.
- Plain JSON metadata type peer with Boolean online signals remote peer availability.
- Binary WebSocket frames contain authenticated ciphertext only; the server forwards them unchanged to the other role.
- Text ping receives pong. Other plaintext and frames over 64KiB are rejected.
- Only one sender and receiver per room; no personal login or stored microphone content.

## Free quotas

Cloudflare Durable Objects Free currently provides 100,000 billable requests per day; incoming WebSocket messages are metered at a 20:1 request ratio. The Mac client coalesces PCM audio into approximately 50 ms encrypted packets to reduce per-message quota consumption. This public instance is best-effort and not guaranteed unlimited or permanently available.

The service can observe IP, connection metadata, traffic sizes and room hashes. A malicious or compromised relay may deny service or attempt replay. No independent security audit has been performed. This release uses relay transport for its Anywhere mode; ICE/P2P hole punching is not implemented.
