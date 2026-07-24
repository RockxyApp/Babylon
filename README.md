# Babylon

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2016%2B%20%7C%20macOS%2013%2B%20%7C%20tvOS%2016%2B%20%7C%20watchOS%2010%2B-lightgrey.svg)](https://github.com/RockxyApp/Babylon)
[![Website](https://img.shields.io/badge/rockxy.io-000?logo=safari&logoColor=fff)](https://rockxy.io)

Captures HTTP/HTTPS, WebSocket, gRPC, and runtime trace data from your app and sends it to [Rockxy](https://rockxy.io) for inspection. No proxy or certificate installation is required.

Babylon is the client SDK. [Rockxy](https://rockxy.io) is the macOS app that receives and inspects the traffic — get it at **[rockxy.io](https://rockxy.io)** ([source](https://github.com/RockxyApp/Rockxy)).

## Features

- **Automatic capture** -- hooks into URLSession at runtime via method swizzling. No code changes to your networking layer.
- **WebSocket inspection** -- captures send, receive, ping/pong, and close frames with timestamps.
- **gRPC support** -- log unary and streaming gRPC calls as inspectable traffic.
- **Manual logging API** -- record traffic from non-URLSession sources (C++ libraries, custom transports).
- **Runtime traces** -- correlate sessions, traces, steps, marks, events, and errors with captured traffic.
- **Header redaction** -- strip sensitive headers (auth tokens, API keys) before transmission.
- **Authenticated transport** -- encrypts each frame with AES-GCM using the pairing token stored by Rockxy.
- **Bonjour discovery** -- finds Rockxy on the local network automatically. Direct TCP fallback for simulators.
- **Zero third-party dependencies** -- uses Apple system frameworks and the system zlib module.
- **DEBUG-only safety** -- `Babylon.start()` is a no-op in non-DEBUG builds. No impact on production.
- **Cross-platform** -- iOS 16+, macOS 13+, tvOS 16+, watchOS 10+.

## How It Works

```
Your App (URLSession)
    |
    |  method swizzling (resume, didReceiveResponse, didReceiveData, didFinish)
    v
Babylon captures request + response + timing
    |
    |  length-prefixed, GZIP-compressed, AES-GCM-encrypted frames
    v
Rockxy macOS App (via Bonjour or localhost:10909)
```

Babylon swizzles URLSession's private connection class (`__NSCFURLSessionConnection`) to intercept traffic without requiring URLProtocol registration or proxy configuration.

## Rockxy

Babylon captures traffic; [Rockxy](https://rockxy.io) is the macOS app that displays it — request/response bodies, headers, timing, WebSocket frames, gRPC calls, and runtime traces, all inspectable on your desktop. No proxy, no certificate, no system settings to change.

- **Download:** [rockxy.io](https://rockxy.io)
- **Source:** [github.com/RockxyApp/Rockxy](https://github.com/RockxyApp/Rockxy)

Star both repos if Babylon saves you a proxy config.

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 16.0           |
| macOS    | 13.0           |
| tvOS     | 16.0           |
| watchOS  | 10.0           |
| Swift    | 5.9+           |
| Xcode    | 16+            |

## Documentation

- [Quick start](docs/quick-start.md)
- [Capture policy](docs/capture-policy.md)
- [Security and privacy](docs/security-and-privacy.md)
- [Architecture](docs/architecture.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Building and testing](docs/building.md)

## Installation

### Swift Package Manager (Xcode UI)

1. In Xcode, go to **File > Add Package Dependencies...**
2. Enter the repository URL:
   ```
   https://github.com/RockxyApp/Babylon
   ```
3. Select **Up to Next Major Version** with `1.0.0`.
4. Add `Babylon` to your app target.

### Swift Package Manager (Package.swift)

```swift
dependencies: [
    .package(url: "https://github.com/RockxyApp/Babylon", from: "1.0.0")
]
```

Then add `Babylon` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: ["Babylon"]
)
```

## Info.plist Configuration

On iOS 14+, Bonjour service discovery requires two Info.plist entries. Without these, Babylon cannot find Rockxy on your local network.

Add the following to your app's `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to send debug traffic to Rockxy.</string>

<key>NSBonjourServices</key>
<array>
    <string>_Rockxy._tcp</string>
</array>
```

> **Note:** Simulator builds connect directly to `localhost:10909` and do not require these entries.

## Usage

In Rockxy, open the Babylon pairing view and copy its pairing token. Pass that token when Babylon starts. The token is never sent over the network; both peers use it to derive the per-session encryption key.

Store the token in a local Debug `.xcconfig`, scheme environment variable, or another developer-only secret source. Do not commit a real pairing token to the app repository; the placeholders below are intentionally not usable credentials.

Always wrap Babylon calls in `#if DEBUG` to guarantee zero overhead in release builds. Babylon also contains internal non-DEBUG guards as a second safety boundary.

### SwiftUI

```swift
import SwiftUI
import Babylon

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Babylon.start(authToken: "<PAIRING_TOKEN_FROM_ROCKXY>")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### UIKit (Swift)

```swift
import UIKit
import Babylon

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG
        Babylon.start(authToken: "<PAIRING_TOKEN_FROM_ROCKXY>")
        #endif
        return true
    }
}
```

### UIKit (Objective-C)

```objc
@import Babylon;

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
#if DEBUG
    [Babylon startWithAuthToken:@"<PAIRING_TOKEN_FROM_ROCKXY>"
                       hostName:nil
  shouldCaptureWebSocketTraffic:YES];
#endif
    return YES;
}
```

### Target a Specific Rockxy Instance

If multiple Rockxy instances are running on your network, filter by hostname:

```swift
#if DEBUG
Babylon.start(
    authToken: "<PAIRING_TOKEN_FROM_ROCKXY>",
    hostName: "development-mac"
)
#endif
```

When `hostName` is set, Babylon only connects to an exact normalized Bonjour service name match. A missing or non-matching service name is rejected.

## Advanced Usage

<details>
<summary><strong>Runtime Tracing</strong></summary>

Group app work into a trace and add timeline events that Rockxy can show beside the related traffic:

```swift
let trace = Babylon.startTrace("Checkout")
trace.step("Load cart")
Babylon.mark("Cache warm")
Babylon.event("User selected plan", metadata: ["plan": "pro"])
trace.step("Submit order")
trace.finish()
```

Babylon carries correlation metadata inside its encrypted capture payload. It never adds headers to real outgoing requests.

</details>

<details>
<summary><strong>Manual Logging (non-URLSession traffic)</strong></summary>

Log traffic from networking libraries that don't use URLSession:

```swift
// Using Foundation types
Babylon.add(
    request: urlRequest,
    response: urlResponse,
    responseBody: data
)

// Log a failed request
Babylon.add(
    request: urlRequest,
    error: error
)

// Using Babylon model types directly
let request = Request(url: "https://api.example.com/v1/users", method: "GET", headers: [], body: nil)
let response = Response(statusCode: 200, headers: [Header(key: "Content-Type", value: "application/json")])
Babylon.add(request: request, response: response, responseBody: jsonData)
```

</details>

<details>
<summary><strong>gRPC Unary Calls</strong></summary>

```swift
Babylon.addGRPCUnary(
    path: "/myapp.UserService/GetUser",
    requestObject: requestProtoData,
    responseObject: responseProtoData,
    success: true,
    statusCode: 0,   // OK
    statusMessage: nil,
    startedAt: callStartDate,
    endedAt: callEndDate,
    HPACKHeadersRequest: [Header(key: "authorization", value: "Bearer ...")],
    HPACKHeadersResponse: []
)
```

</details>

<details>
<summary><strong>gRPC Streaming</strong></summary>

Use a stable UUID for all messages in the same stream:

```swift
let streamID = UUID()

// Send a message on the stream
Babylon.addGRPCStreaming(
    id: streamID,
    path: "/myapp.ChatService/StreamMessages",
    message: .data(protoData),
    success: true,
    statusCode: 0,
    statusMessage: nil,
    streamingType: .bidirectional,
    type: .send
)

// Receive a message on the same stream
Babylon.addGRPCStreaming(
    id: streamID,
    path: "/myapp.ChatService/StreamMessages",
    message: .data(responseProtoData),
    success: true,
    statusCode: 0,
    statusMessage: nil,
    streamingType: .bidirectional,
    type: .receive
)
```

Streaming types: `.client`, `.server`, `.bidirectional`

</details>

<details>
<summary><strong>BabylonDelegate (in-process inspection)</strong></summary>

Receive captured packages directly without Rockxy:

```swift
final class NetworkMonitor: BabylonDelegate {
    func babylonDidCapturePackage(_ package: TrafficPackage) {
        capturedPackageCount += 1
    }

    private(set) var capturedPackageCount = 0
}

// Register the delegate
let monitor = NetworkMonitor()
Babylon.setDelegate(monitor)
```

The delegate is called on the main thread and held weakly.

</details>

<details>
<summary><strong>Header Redaction</strong></summary>

Babylon redacts common credential, cookie, and token headers by default. Add application-specific header or query-item names before starting capture:

```swift
Babylon.setRedactedHeaders(["X-Company-Session"])
Babylon.setRedactedQueryItems(["temporary_credential"])
```

Matching is case-insensitive. Built-in sensitive names remain protected when custom names are added. Redacted values appear as `[REDACTED]` in Rockxy.

</details>

<details>
<summary><strong>Disable Transport Layer</strong></summary>

Capture traffic through the delegate only, without sending to Rockxy over the network:

```swift
Babylon.setEnableTransportLayer(false)
Babylon.setDelegate(myDelegate)
Babylon.start()
```

Call `setEnableTransportLayer` before `start()`.

</details>

<details>
<summary><strong>URLProtocol Filtering</strong></summary>

Some libraries (e.g., Firebase, custom caching layers) register URLProtocol subclasses that cause duplicate requests. Suppress them:

```swift
Babylon.setIgnoreProtocols([MyCustomURLProtocol.self])
```

</details>

## API Reference

| Method | Description |
|--------|-------------|
| `Babylon.start(authToken:hostName:shouldCaptureWebSocketTraffic:)` | Start capture with the Rockxy pairing token, optional exact hostname filter, and WebSocket toggle. |
| `Babylon.start(hostName:shouldCaptureWebSocketTraffic:)` | Start delegate-only capture. Network transport stays offline without a pairing token. |
| `Babylon.stop()` | Stop capturing and disconnect from Rockxy. |
| `Babylon.setDelegate(_:)` | Register a `BabylonDelegate` for in-process package delivery. |
| `Babylon.setIgnoreProtocols(_:)` | Suppress duplicates from specified URLProtocol subclasses. |
| `Babylon.setEnableTransportLayer(_:)` | Enable/disable network transport to Rockxy. |
| `Babylon.setIsRunningOniOSPlayground(_:)` | Bypass Info.plist checks in Swift Playgrounds. |
| `Babylon.setRedactedHeaders(_:)` | Redact specified header values before transmission. |
| `Babylon.setRedactedQueryItems(_:)` | Redact specified URL query-item values before transmission. |
| `Babylon.add(request:response:responseBody:)` | Manually log a completed HTTP transaction (Foundation types). |
| `Babylon.add(request:error:)` | Manually log a failed HTTP request. |
| `Babylon.add(request:response:responseBody:)` | Manually log a completed HTTP transaction (Babylon model types). |
| `Babylon.addGRPCUnary(...)` | Log a unary gRPC call. |
| `Babylon.addGRPCStreaming(...)` | Log a gRPC streaming message. |
| `Babylon.startTrace(_:)` | Start a runtime trace and its initial step. |
| `Babylon.mark(_:metadata:)` | Add an instant runtime mark. |
| `Babylon.event(_:metadata:)` | Add an application event to the active session. |
| `Babylon.error(_:error:metadata:)` | Add an error event to the active session. |

## Troubleshooting

**Rockxy doesn't see my app**

Confirm that you copied the current Rockxy pairing token into `Babylon.start(authToken:)`. Then check that your Info.plist includes both `NSLocalNetworkUsageDescription` and `NSBonjourServices` with `_Rockxy._tcp`. On first launch, iOS will show a local network permission dialog -- tap Allow.

**Traffic appears in Rockxy but response bodies are missing**

Response bodies larger than 50 MB are skipped to prevent memory issues in the host app. The request/response metadata still appears.

**Duplicate requests showing in Rockxy**

If your app uses a library that registers custom URLProtocol subclasses (Firebase Performance, etc.), call `Babylon.setIgnoreProtocols([TheProtocolClass.self])` to filter duplicates.

**WebSocket messages not captured**

Ensure you called `Babylon.start(shouldCaptureWebSocketTraffic: true)` (this is the default). WebSocket capture requires the app to use `URLSessionWebSocketTask`.

**Babylon.start() does nothing in my release build**

This is by design. `Babylon.start()` returns immediately in non-DEBUG configurations to prevent method swizzling in production.

**Simulator connects but physical device doesn't**

Simulators connect directly to `localhost:10909`. Physical devices use Bonjour, which requires both devices on the same network and the Info.plist entries described above.

**The host app reports a capture-related failure**

Stop Babylon, reproduce without capture, and file an issue with a symbolicated crash log if the failure only occurs while Babylon is active. Remove credentials, headers, URLs, request bodies, and device identifiers from diagnostics before sharing them.

## License

Babylon is released under the [Apache License 2.0](LICENSE).

---

Built for [Rockxy](https://rockxy.io) · [Download the app](https://rockxy.io) · [Rockxy on GitHub](https://github.com/RockxyApp/Rockxy)
