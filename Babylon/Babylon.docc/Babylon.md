# ``Babylon``

Capture application network traffic and runtime timeline events for inspection in Rockxy.

## Overview

Babylon observes URLSession traffic in debug builds, captures bounded request and response data, and sends authenticated encrypted frames to a paired Rockxy instance. It can also deliver packages to an in-process ``BabylonDelegate`` without opening a network connection.

Wrap activation in `#if DEBUG`, obtain a pairing token from Rockxy, and start Babylon during application initialization:

```swift
#if DEBUG
Babylon.start(authToken: debugPairingToken)
#endif
```

Call ``Babylon/stop()`` when capture is no longer needed. Babylon does not activate runtime hooks in non-debug builds.

## Topics

### Lifecycle

- ``Babylon/start(authToken:hostName:shouldCaptureWebSocketTraffic:)``
- ``Babylon/start(hostName:shouldCaptureWebSocketTraffic:)``
- ``Babylon/stop()``

### Capture configuration

- ``Babylon/setDelegate(_:)``
- ``Babylon/setEnableTransportLayer(_:)``
- ``Babylon/setIgnoreProtocols(_:)``
- ``Babylon/setRedactedHeaders(_:)``
- ``Babylon/setRedactedQueryItems(_:)``

### Runtime timeline

- ``Babylon/startTrace(_:metadata:)``
- ``Babylon/mark(_:metadata:)``
- ``Babylon/event(_:metadata:)``
- ``Babylon/error(_:error:metadata:)``
