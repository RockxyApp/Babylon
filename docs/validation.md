# Validation cadence

Every pull request runs the macOS Swift Package suite in serial, strict SwiftLint and SwiftFormat checks, shared protocol fixture validation, iOS Debug/Release framework builds, and simulator compile gates for iOS 16, tvOS 16, and watchOS 10. The local macOS integration suite exercises real URLSession HTTP and WebSocket tasks; transport tests exercise the production framing codec and bounded ACK/retry lifecycle.

A scheduled weekly matrix on macOS runs four additional lanes: complete strict-concurrency diagnostics, AddressSanitizer over capture bounds/policy/WebSocket lifecycle and loopback tests, ThreadSanitizer over the same capture and lifecycle set, and a focused capture run wrapped in `/usr/bin/time -l` to record peak resident memory. The RSS run records the measurement without imposing an arbitrary machine-dependent threshold; use its history to establish a stable budget before turning it into a hard gate.

Release builds compile the private URLSession runtime hooks out: their installer and implementation are guarded by `#if DEBUG` in `NetworkInjector.swift` and `NetworkInjector+URLSession.swift`. The weekly strict-concurrency lane currently uses Swift 5 language mode with `-strict-concurrency=complete`; convert it to Swift 6 language mode after the dependency and source diagnostics are clean.

Platform simulator builds prove compilation only. Live URLSession/WebSocket behavior is exercised on macOS, where the private selectors under test are available; other platforms must report unavailable runtime selectors safely rather than infer behavior from a simulator build.
