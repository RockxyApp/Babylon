# Architecture

Babylon is a client-side Swift framework. It does not import or link Rockxy code.

```text
Host app
  -> Babylon public API
  -> DEBUG-only URLSession runtime hooks or manual capture APIs
  -> bounded traffic and runtime packages
  -> authenticated encrypted protocol frames
  -> Bonjour/TCP or simulator localhost
  -> Rockxy receiver
```

## Capture

URLSession task factories and lifecycle callbacks are observed through Objective-C runtime hooks. Each task receives an associated opaque identifier used only to correlate response, body, completion, and WebSocket events. Original URLSession implementations are always called.

Runtime traces use a serial state store for session, trace, and step identifiers. Correlation stays in the encrypted capture package and does not add headers to real application requests.

## Memory

Request, response, and current WebSocket body data share a 50 MiB package budget. Oversized bodies are replaced with an omission marker. Deferred WebSocket frames and pending transport items are bounded. Captures are memory-only.

## Transport

Physical devices discover `_Rockxy._tcp` with Network.framework. Simulators connect to `localhost:10909`. Each JSON frame has an 8-byte big-endian length header. The payload is GZIP-compressed, encrypted with AES-256-GCM, authenticated with protocol metadata, and acknowledged by Rockxy.

See [Protocol v1](babylon-protocol-v1.md) for field-level details and [Security and privacy](security-and-privacy.md) for trust boundaries.
