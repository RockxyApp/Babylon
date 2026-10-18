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

The SDK also sends transport lifecycle updates as ordinary authenticated `runtime` packages with `kind: "event"`, names such as `Babylon transport reconnecting`, and a `metadata.transportState` value of `reconnecting`, `reconnected`, `retryExhausted`, `draining`, or `drainCompleted`. Retry events include the bounded retry attempt and delay in milliseconds; a coarse `networkError` category is included when Network.framework supplies an error. They contain no endpoint, address, or pairing token. Events queued while disconnected are delivered only after a receiver becomes available again. `drainCompleted` is sent only after closing packages have been acknowledged; if the configured drain deadline expires first, no completion event is emitted.

TCP receive state accepts fragmented and coalesced frames. Inbound frames are authenticated before decoding; duplicate inbound message IDs are ignored. Decompressed inbound control envelopes are capped at 1 MiB. Rockxy separately caps the authenticated, decompressed capture envelope at 96 MiB before decoding its nested DTO, then enforces the 50 MiB aggregate body policy on decoded traffic.
