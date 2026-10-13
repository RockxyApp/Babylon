# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Swift Package Index configuration for hosted DocC documentation and live compatibility badges

### Fixed
- Capture on iOS 27 and macOS 27: the system's loading connection no longer has a `task` getter, so every response, body, and completion was dropped and nothing reached Rockxy. The task is now read from the connection's stored reference when the getter is missing.
- Request bodies set with `httpBody` are captured again after the task starts; URLSession moves them into a stream on `currentRequest`, so the body now comes from `originalRequest`.

## [1.0.0] - 2026-07-24

### Added
- Automatic HTTP/HTTPS and WebSocket capture for URLSession-based applications
- Manual HTTP, gRPC unary, and gRPC streaming capture APIs
- Runtime sessions, traces, steps, marks, events, and error timeline events
- Pairing-token transport using HKDF-SHA256, AES-256-GCM, GZIP, and length-prefixed frames
- Bonjour discovery for physical devices and direct localhost transport for simulators
- In-process capture delivery through `BabylonDelegate`
- Header and query-item redaction with secure defaults
- Swift Package Manager and Xcode project distribution
- Apache License 2.0, public contribution and security policies, CI, and release checks

### Changed
- Capture activation and runtime hooks are inert outside `DEBUG` builds
- Correlation metadata stays inside encrypted capture payloads and never mutates outbound requests
- HTTP and WebSocket bodies share a 50 MiB capture budget, and pending transport queues are bounded
- Hostname matching, authentication, identifier validation, replay handling, and connection teardown fail closed
- Captured payloads remain memory-only and diagnostic logging excludes captured content

[Unreleased]: https://github.com/RockxyApp/Babylon/compare/1.0.0...HEAD
[1.0.0]: https://github.com/RockxyApp/Babylon/releases/tag/1.0.0
