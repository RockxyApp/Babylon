# Troubleshooting

## Rockxy does not show the app

- Confirm the current Rockxy pairing token is exactly 64 lowercase hexadecimal characters.
- On a physical iOS device, confirm local-network permission is allowed and both required `Info.plist` keys are present.
- Confirm the device and Mac are on the same reachable network.
- Remove `hostName` temporarily to test discovery without name filtering.
- On a simulator, confirm Rockxy is listening on `localhost:10909`.

## Capture works through the delegate but not Rockxy

Delegate-only capture proves the runtime hook is active. Recheck the pairing token, Rockxy receiver state, local-network permission, and hostname filter. A missing or invalid token intentionally leaves network transport offline.

## A body is missing

Babylon replaces body data when the package's request, response, and current WebSocket data exceed the 50 MiB aggregate budget. Request streams and upload files are not synchronously consumed by task hooks.

## A request is duplicated

A custom `URLProtocol` can generate a second observable request. Register the protocol class before capture:

```swift
Babylon.setIgnoreProtocols([ApplicationURLProtocol.self])
```

## A WebSocket frame is missing

Confirm WebSocket capture is enabled and the app uses `URLSessionWebSocketTask`. Deferred frames are bounded, so frames may be dropped before the upgrade response if the pending limit or body budget is exceeded.

## A release build captures nothing

This is expected. Babylon runtime activation is compiled behind `DEBUG` checks. Keep explicit `#if DEBUG` guards in the host application as well.

When filing an issue, include the Babylon version, Apple platform version, Xcode version, and a minimal synthetic reproduction. Remove captured data and machine-specific details from diagnostics.
