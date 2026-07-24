# Security and privacy

Babylon is a debug capture SDK. It can observe URLs, headers, bodies, timing, errors, WebSocket frames, gRPC payloads, runtime metadata, project identity, and device identity. Treat a capture session with the same care as application logs containing customer data.

## Activation boundary

- Runtime hooks activate only after `Babylon.start()` in a `DEBUG` build.
- Host applications should also wrap imports and calls in `#if DEBUG`.
- A start call without a token is delegate-only and does not start network discovery or TCP.
- `Babylon.stop()` disconnects transport and clears in-flight capture state.

## Transport boundary

Rockxy generates a 32-byte random value represented as 64 lowercase hexadecimal characters. Babylon uses that token as HKDF-SHA256 input and encrypts every frame with AES-256-GCM. The token is not serialized or transmitted.

The outer frame exposes ciphertext length, delivery timing, protocol version, sequence number, and opaque per-activation identifiers. Captured URLs, headers, bodies, runtime metadata, project identity, and device identity are inside the authenticated encrypted payload.

Bonjour hostname filtering selects a receiver but is not authentication. Pairing-token authentication is the trust boundary.

## Data handling

- Babylon does not write captures to local files, preferences, databases, or logs.
- HTTP and WebSocket body capture is limited to a shared 50 MiB budget per traffic package.
- Pending transport queues are bounded; old pending work is dropped when limits are reached.
- Memory warnings clear in-flight capture state.
- OSLog messages contain operational failures, not captured values or pairing tokens.

The `BabylonDelegate` receives captured packages on the main thread. The host application controls what happens to those packages after delivery.

## Redaction

The default policy redacts common authorization, proxy authorization, API key, cookie, and token headers. It also redacts common credential-bearing URL query items. Applications can add names with:

```swift
Babylon.setRedactedHeaders(["X-Company-Session"])
Babylon.setRedactedQueryItems(["temporary_credential"])
```

Built-in sensitive names cannot be removed. Redaction is name-based and case-insensitive.

Babylon does not attempt automatic body redaction because payload formats and schemas are application-specific. Avoid capture against real accounts, disable body-producing requests, or use synthetic environments when bodies can contain sensitive data. Runtime event names, error descriptions, and metadata are caller-provided and should not contain secrets.

## App privacy declarations

The bundled privacy manifest describes Babylon's non-debug production behavior: capture cannot activate. A host application that distributes a debug or internal build with capture enabled is responsible for its own privacy disclosures, access controls, retention, and deletion policy.

Report security issues through the repository Security tab as described in [SECURITY.md](../SECURITY.md).
