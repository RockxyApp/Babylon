# Capture policy

Use this checklist before enabling Babylon in an application.

## Safe defaults

| Area | Default |
|---|---|
| Production activation | Disabled outside `DEBUG` |
| Network transport without token | Disabled |
| Frame protection | HKDF-SHA256 and AES-256-GCM |
| Request and response body budget | 50 MiB aggregate per package |
| Pending transport queue | 50 items |
| Captured-data persistence | None |
| Credential headers and query items | Redacted by name |

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
