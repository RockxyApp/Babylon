# Quick start

## 1. Add the package

In Xcode, choose **File > Add Package Dependencies** and enter:

```text
https://github.com/RockxyApp/Babylon
```

Add the `Babylon` library to the application target.

## 2. Allow local discovery

Physical iOS devices require these host-app `Info.plist` values:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to send debug traffic to Rockxy.</string>
<key>NSBonjourServices</key>
<array>
    <string>_Rockxy._tcp</string>
</array>
```

The simulator connects to `localhost:10909` and does not require local-network permission.

## 3. Pair and start

Copy the current 64-character pairing token from Rockxy. Store it in developer-only configuration and never commit it.

```swift
import Babylon

#if DEBUG
Babylon.start(authToken: debugPairingToken)
#endif
```

An invalid token fails closed: capture transport is not started. Calling `Babylon.start()` without a token starts delegate-only capture and does not open Bonjour or TCP transport.

## 4. Stop capture

```swift
#if DEBUG
Babylon.stop()
#endif
```

Read [Capture policy](capture-policy.md) before inspecting applications that handle credentials or personal data.
