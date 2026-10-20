# Babylon protocol v1

Babylon discovers Rockxy through `_Rockxy._tcp`. Simulators connect directly to `localhost:10909`.

Every TCP frame uses an unsigned 64-bit big-endian length followed by that many bytes of `SecureFrame` JSON. Receivers must reject a declared frame length above 72 MiB (75,497,472 bytes) before buffering its payload. Babylon applies a 50 MiB aggregate captured-body budget to each traffic package; the frame headroom covers compression and the outer JSON/base64 expansion.

```text
[8-byte UInt64 big-endian length][SecureFrame JSON]
```

`SecureFrame` contains:

- `protocolVersion`: `1`
- `messageID`: a unique UUID string
- `sessionID`: a fresh identifier for each `Babylon.start`
- `clientID`: an opaque UUID generated for each Babylon activation
- `sequence`: a monotonically increasing unsigned 64-bit integer
- `compression`: `gzip`
- `nonce`, `ciphertext`, `tag`: JSON base64-encoded `Data` fields from AES-256-GCM

`messageID`, `sessionID`, and `clientID` are non-empty UTF-8 strings capped at 128, 128, and 512 bytes respectively. They cannot contain `:`, ASCII control bytes, or DEL; this keeps the HKDF info and AAD delimiters unambiguous.

The encrypted plaintext is one JSON `PayloadEnvelope`:

```text
{ messageType, sentAt, content }
```

`messageType` is `connection`, `traffic`, `websocket`, `runtime`, `heartbeat`, `ack`, or `error`. `content` is the JSON-encoded DTO as a base64 `Data` field. The complete envelope is GZIP-compressed exactly once before encryption.

## Key derivation and authentication

Babylon derives a 32-byte AES key using HKDF-SHA256:

```text
input key material = UTF-8 auth token
salt               = UTF-8 "rockxy-babylon-v1"
info               = UTF-8 "clientID:sessionID"
```

AES-GCM additional authenticated data is the canonical UTF-8 string:

```text
1:clientID:sessionID:messageID:sequence
```

The authentication token is key material only. It is never included in a connection payload or `SecureFrame`. An empty token is invalid: network delivery stays disabled and unauthenticated packages are not retained. There is no plaintext or legacy wire fallback.

## Delivery and receive handling

The connection metadata message is the first encrypted message on a ready connection. Sent frames are retained under both a 50-frame count limit and a 72 MiB aggregate byte limit until an authenticated ACK names their `messageID`. Missing ACKs are retried twice after cancellable two-second timeouts. Stop, restart, and memory warnings invalidate retries and clear retained frames.

The SDK also sends transport lifecycle updates as ordinary authenticated `runtime` packages with `kind: "event"`, names such as `Babylon transport reconnecting`, and a `metadata.transportState` value of `reconnecting`, `reconnected`, `retryExhausted`, `draining`, or `drainCompleted`. Retry events include the bounded retry attempt and delay in milliseconds; a coarse `networkError` category is included when Network.framework supplies an error. They contain no endpoint, address, or pairing token. Events queued while disconnected are delivered only after a receiver becomes available again. `drainCompleted` is sent only after every selected closing package has been acknowledged; a package that cannot be encoded or retained, exhausts its acknowledgement retries, or remains unacknowledged at the configured deadline prevents the completion event.

TCP receive state accepts fragmented and coalesced frames. Inbound frames are authenticated before decoding; duplicate inbound message IDs are ignored. Decompressed inbound control envelopes are capped at 1 MiB. Rockxy separately caps the authenticated, decompressed capture envelope at 96 MiB before decoding its nested DTO, then enforces the 50 MiB aggregate body policy on decoded traffic.

## WebSocket capture

WebSocket hook installation is process-wide, while whether callbacks record frames follows the current `Babylon.start` session setting. WebSocket payload capture is limited to 10 MiB per frame to match Rockxy's receiver. Before the HTTP upgrade transaction is available, frames are retained in order with per-task and aggregate count, byte, and shared-memory limits; stop, task completion/failure, and memory pressure release deferred state.

WebSocket DTO `messageType` values include `ping`, `pong`, `send`, `receive`, `sendCloseMessage`, `receiveCloseMessage`, and `abnormalTermination`. Older SDKs may emit `pingPong`. Close packages may also include `closeCode`, `closeOrigin` (`local` or `remote`), and `abnormal`; readers should ignore unknown optional fields and message types.

## gRPC traffic payload

Typed gRPC captures remain inside the authenticated `traffic` DTO. `packageType` is `grpc`; the optional `grpcCapture` object has its own `schemaVersion` (currently `1`) so receivers can reject unsupported typed details while retaining the surrounding traffic record. It carries the endpoint, authority, service and method names, one of `unary`, `clientStreaming`, `serverStreaming`, or `bidirectionalStreaming`, separate request/response metadata and trailers, status and compression labels, and an ordered list of directional messages. Each message records its sequence, timestamp, compression flag, observed byte count, and optional opaque protobuf bytes. Message count is capped at 1,024, each message at 10 MiB, and total retained body bytes at the existing 50 MiB per-traffic-package budget. `omitted` marks a message whose bytes were intentionally not retained. Legacy gRPC packages without `grpcCapture` remain readable through their HTTP-shaped fields.

## URLSession task timing payload

Babylon may attach `urlSessionTiming` to a traffic package when its fail-soft macOS URLSession runtime hook can observe the task's metrics-ready event. The observer reads a snapshot from Foundation's task metrics and calls the original runtime method unchanged; it never replaces or proxies the application's URLSession delegate. The hook is private and can be absent on an OS release, in which case the field is omitted.

`urlSessionTiming.schemaVersion` is currently `1`. It preserves the ordered transaction list produced for redirects, bounded to eight entries and 8 KiB of encoded timing data. `omittedTransactionCount` reports any truncated tail. Phase durations are optional seconds: absent means Foundation did not report both endpoints, while `0` means both endpoints were measured at the same instant. The DTO includes task and fetch duration; DNS, TCP connect, TLS, request, server wait, and response transfer durations; negotiated protocol, connection reuse, proxy use, and resource-fetch type. It contains no request URL, headers, or body data. Older readers ignore the optional field; newer readers must remain compatible with packages that omit it.
