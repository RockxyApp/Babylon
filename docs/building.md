# Building and testing

Requirements:

- Xcode 16 or newer
- Swift 5.9 or newer
- SwiftFormat
- SwiftLint

Run the release checks from the repository root:

```bash
./scripts/public-release-audit.sh
swiftformat --lint .
swiftlint lint --strict
swift test --no-parallel
xcodebuild -project Babylon.xcodeproj -scheme Babylon -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Babylon.xcodeproj -scheme Babylon -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

`./scripts/ci.sh` runs the same release-surface audit, lint, package tests, and both iOS configurations.

Babylon has no third-party package dependencies. Do not add a dependency without first considering the API, binary size, security, and downstream package impact.
