# ``Babylon``

Capture application network traffic and runtime timeline events for inspection in Rockxy.

## Overview

Babylon observes URLSession traffic in debug builds, captures bounded request and response data, and sends authenticated encrypted frames to a paired Rockxy instance. Capture, encoding, and pending transport data share a finite in-memory budget; when that budget is exhausted, Babylon omits new diagnostic data while allowing the application's original network request to proceed. It can also deliver packages to an in-process ``BabylonDelegate`` without opening a network connection.

Wrap activation in `#if DEBUG`, obtain a pairing token from Rockxy, and start Babylon during application initialization:

```swift
#if DEBUG
Babylon.start(authToken: debugPairingToken)
#endif
```

Call ``Babylon/stop()`` when capture is no longer needed. Babylon does not activate runtime hooks in non-debug builds.

For asynchronous work, scope requests to their trace so overlapping workflows keep their own context:

```swift
let checkout = Babylon.startTrace("Checkout")
await checkout.withStep("Load Cart") {
    await loadCart()
}
```

Structured child tasks inherit the scope. For detached tasks and callbacks, capture ``BabylonTrace/correlationContext``
and pass it with ``Babylon/withTraceContext(_:operation:)``. Existing unscoped calls continue to infer context while
exactly one trace is active; when multiple traces overlap, Babylon leaves the context unset instead of guessing.

## Topics

### Lifecycle

- ``Babylon/start(authToken:hostName:shouldCaptureWebSocketTraffic:capturePolicy:)``
- ``Babylon/start(hostName:shouldCaptureWebSocketTraffic:capturePolicy:)``
- ``CapturePolicy``
- ``Babylon/stop()``

### Capture configuration

- ``Babylon/setDelegate(_:)``
- ``Babylon/setEnableTransportLayer(_:)``
- ``Babylon/setIgnoreProtocols(_:)``
- ``Babylon/setRedactedHeaders(_:)``
- ``Babylon/setRedactedQueryItems(_:)``

### Runtime timeline

- ``Babylon/startTrace(_:metadata:)``
- ``Babylon/withTrace(_:operation:)``
- ``Babylon/withTraceContext(_:operation:)``
- ``Babylon/currentCorrelationContext``
- ``BabylonTrace/correlationContext``
- ``BabylonTrace/withStep(_:metadata:operation:)``
- ``Babylon/mark(_:metadata:)``
- ``Babylon/event(_:metadata:)``
- ``Babylon/error(_:error:metadata:)``
