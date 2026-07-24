# Contributing to Babylon

Thanks for helping improve Babylon. Changes should keep the framework safe to embed in a host app and compatible with the Rockxy wire protocol.

## Development setup

Requirements:

- Xcode 16 or newer
- Swift 5.9 or newer
- SwiftFormat
- SwiftLint

Run the local checks before opening a pull request:

```bash
./scripts/public-release-audit.sh
swiftformat .
swiftlint lint --strict
swift test --no-parallel
xcodebuild -project Babylon.xcodeproj -scheme Babylon -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Pull requests

- Keep changes focused and include regression tests.
- Use Conventional Commit titles, such as `fix: cap response bodies during capture`.
- Update `CHANGELOG.md` under `[Unreleased]` for user-visible behavior.
- Do not add third-party dependencies.
- Do not log or persist captured headers, bodies, or runtime metadata.
- Do not add machine-specific paths, signing-team values, credentials, or user-specific Xcode data.
- Keep public API additions minimal and document why they must be public.
- Preserve existing copyright and SPDX headers.

By contributing, you agree that your contribution is licensed under Apache License 2.0.
