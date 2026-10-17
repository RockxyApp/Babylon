# Capture policy

Use this checklist before enabling Babylon in an application.

## Safe defaults

| Area | Default |
|---|---|
| Production activation | Disabled outside `DEBUG` |
| Network transport without token | Disabled |
| Frame protection | HKDF-SHA256 and AES-256-GCM |
| Request and response body budget | 50 MiB hard aggregate per package; policy may lower request and response limits independently |
| Pending transport queue | 50 items |
| Captured-data persistence | None |
| Credential headers and query items | Redacted by name |
| Capture selection | All URLSession traffic unless an immutable `CapturePolicy` is supplied |
| Omission metadata | Bounded, process-local reason and observed-byte counters; omitted body content is not retained |

## DEBUG capture policy

Pass a `CapturePolicy` to `Babylon.start(...)` from a `#if DEBUG` block. Each rule combines its
specified scheme, normalized host suffix, port, method, path prefix, and content type with AND.
Matching exclude rules win. If any include rules exist, one must match for a request to be captured.
Host suffixes match the exact host or a dot-separated subdomain, not arbitrary string endings.

Request facts are matched before a transaction package is built. Content-Type is only available after
the response starts, so those rules retain transaction metadata and omit the response body when the
type does not match. `metadataOnly` removes body bytes in both directions. Request and response byte
limits are independent, nonnegative, and clamped to the existing hard package limit. Omission records
contain only a short reason and a byte count; the in-memory diagnostic list is capped and is neither
serialized nor transmitted by protocol v1. Default credential header and query redaction cannot be
removed; application-specific redaction keys add to those defaults.

```swift
#if DEBUG
let policy = CapturePolicy(
    rules: [.init(action: .exclude, hostSuffixes: ["health.example.com"])],
    metadataOnly: true
)
Babylon.start(capturePolicy: policy)
#endif
```

## Application responsibilities

Before capture:

1. Use a synthetic or developer account.
2. Add application-specific header and query names to the redaction policy.
3. Keep the pairing token in local debug configuration.
4. Confirm the selected Rockxy instance is controlled by the developer.
5. Avoid workflows whose request or response bodies contain data that must not be inspected.

Before sharing diagnostics:

1. Remove captured bodies unless they are essential.
2. Remove URLs, identifiers, headers, runtime metadata, screenshots, and device details that identify a person or system.
3. Replace credentials with synthetic values.
4. Share only the minimum reproduction required.

Do not use Babylon for production monitoring, background telemetry, analytics collection, or traffic retention.
