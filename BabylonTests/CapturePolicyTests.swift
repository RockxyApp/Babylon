import Foundation
import Testing
@testable import Babylon

@Suite(.serialized)
struct CapturePolicyTests {
    @Test("Policy normalizes URL facts and applies include and exclude rules")
    func normalizedRuleMatching() throws {
        let policy = CapturePolicy(rules: [
            .init(
                action: .include,
                schemes: ["HTTPS"],
                hostSuffixes: ["Example.COM"],
                ports: [443],
                methods: ["get"],
                pathPrefixes: ["/api"]
            ),
            .init(action: .exclude, pathPrefixes: ["/api/private"])
        ])
        let includedURL = try #require(URL(string: "https://v1.example.com/api/items"))
        let excludedURL = try #require(URL(string: "https://example.com/api/private/key"))
        let suffixURL = try #require(URL(string: "https://notexample.com/api/items"))
        let schemeURL = try #require(URL(string: "http://example.com/api/items"))
        #expect(policy.decision(for: URLRequest(url: includedURL)).included)
        #expect(!policy.decision(for: URLRequest(url: excludedURL)).included)
        #expect(!policy.decision(for: URLRequest(url: suffixURL)).included)
        #expect(!policy.decision(for: URLRequest(url: schemeURL)).included)
    }

    @Test("An excluded task is never materialized as a traffic package")
    func excludedTaskSkipsPackageCreation() throws {
        let babylon = Babylon.shared
        Babylon.stop()
        Babylon.setEnableTransportLayer(false)
        Babylon.start(capturePolicy: CapturePolicy(rules: [
            .init(action: .exclude, hostSuffixes: ["example.com"], pathPrefixes: ["/private"])
        ]))
        defer {
            Babylon.stop()
            babylon.queue.sync {}
            Babylon.setEnableTransportLayer(true)
        }
        let url = try #require(URL(string: "https://example.com/private"))
        let request = URLRequest(url: url)
        let decision = babylon.injectorSessionWillCreateTask(request: request).capturePolicyDecision
        let task = URLSession.shared.dataTask(with: url)
        babylon.injectorSessionDidCreateTask(
            task: task,
            correlationContext: nil,
            capturePolicyDecision: decision
        )
        babylon.injectorSessionDidCallResume(task: task)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        babylon.injectorSessionDidReceiveResponse(dataTask: task, response: response)

        #expect(babylon.trafficPackageForTesting(task) == nil)
        #expect(babylon.captureOmissions.contains { $0.reason == "rule" })
    }

    @Test("Metadata-only policy drops request and response bodies and records bounded omissions")
    func metadataOnlyDropsBodies() throws {
        let body = Data("sensitive-body".utf8)
        let requestURL = try #require(URL(string: "https://example.com"))
        let request = URLRequest(url: requestURL)
        var bodyRequest = request
        bodyRequest.httpBody = body
        let package = try TrafficPackage(
            id: "metadata-only",
            request: #require(Request(bodyRequest))
        )
        package.configureCaptureLimits(
            requestBytes: 10,
            responseBytes: 10,
            metadataOnly: true,
            policy: CapturePolicy(metadataOnly: true),
            request: bodyRequest
        )
        package.appendResponseData(body)

        #expect(package.request.body == nil)
        #expect(package.responseBodyData.isEmpty)
        #expect(package.requestBodyOmission?.observedBytes == body.count)
        #expect(package.responseBodyOmission?.observedBytes == body.count)
        #expect(package.requestBodyOmission?.reason == "bodyLimit")
    }

    @Test("Omission metadata is serialized with observed and completed original sizes")
    func omissionMetadataIsSerialized() throws {
        let body = Data("sensitive-body".utf8)
        let url = try #require(URL(string: "https://example.com"))
        var request = URLRequest(url: url)
        request.httpBody = body
        let package = try TrafficPackage(id: "omission-metadata", request: #require(Request(request)))
        package.configureCaptureLimits(
            requestBytes: 0,
            responseBytes: 0,
            metadataOnly: true,
            policy: CapturePolicy(metadataOnly: true),
            request: request
        )
        package.appendResponseData(body)
        package.updateDidComplete(nil)

        let data = try #require(package.toData())
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requestOmission = try #require(value["requestBodyOmission"] as? [String: Any])
        let responseOmission = try #require(value["responseBodyOmission"] as? [String: Any])
        #expect(requestOmission["reason"] as? String == "bodyLimit")
        #expect(requestOmission["observedBytes"] as? Int == body.count)
        #expect(requestOmission["originalBytes"] as? Int == body.count)
        #expect(responseOmission["observedBytes"] as? Int == body.count)
        #expect(responseOmission["originalBytes"] as? Int == body.count)
        #expect(value["request"] as? [String: Any] != nil)
    }

    @Test("Request and response body limits are independent and hard capped")
    func independentBodyLimits() throws {
        let url = try #require(URL(string: "https://example.com"))
        var request = URLRequest(url: url)
        request.httpBody = Data("req".utf8)
        let package = try TrafficPackage(id: "limits", request: #require(Request(request)))
        package.configureCaptureLimits(
            requestBytes: 2,
            responseBytes: 5,
            metadataOnly: false,
            policy: CapturePolicy(maximumRequestBodyBytes: 2, maximumResponseBodyBytes: 5),
            request: request
        )
        #expect(package.request.body == nil)
        package.appendResponseData(Data("12345".utf8))
        #expect(package.responseBodyData == Data("12345".utf8))
        package.appendResponseData(Data("6".utf8))
        #expect(package.responseBodyData == Data("<Skip Large Body>".utf8))
        #expect(package.responseBodyOmission?.observedBytes == 6)

        let capped = CapturePolicy(maximumRequestBodyBytes: Int.max, maximumResponseBodyBytes: -1)
        #expect(capped.maximumRequestBodyBytes == BabylonConstants.maximumBodySize)
        #expect(capped.maximumResponseBodyBytes == 0)

        let streamedRequest = URLRequest(url: url)
        let streamed = try TrafficPackage(id: "streamed", request: #require(Request(streamedRequest)))
        streamed.configureCaptureLimits(
            requestBytes: 2,
            responseBytes: 10,
            metadataOnly: false,
            policy: CapturePolicy(maximumRequestBodyBytes: 2),
            request: streamedRequest,
            observedRequestBodyBytes: 3
        )
        #expect(streamed.request.body == nil)
        #expect(streamed.requestBodyOmission?.observedBytes == 3)
    }

    @Test("Content type filters omit response data while retaining metadata")
    func responseContentTypeFilter() throws {
        let url = try #require(URL(string: "https://example.com/api"))
        let request = URLRequest(url: url)
        let policy = CapturePolicy(rules: [
            .init(action: .include, hostSuffixes: ["example.com"], contentTypes: ["application/json"])
        ])
        #expect(policy.decision(for: request).included)
        let package = try TrafficPackage(id: "content-type", request: #require(Request(request)))
        package.configureCaptureLimits(
            requestBytes: 100,
            responseBytes: 100,
            metadataOnly: false,
            policy: policy,
            request: request
        )
        package.appendResponseData(Data("body".utf8))
        let responseValue = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )
        let response = try #require(responseValue)
        package.updateResponse(response)

        #expect(package.response?.statusCode == 200)
        #expect(package.responseBodyData.isEmpty)
        #expect(package.responseBodyOmission?.reason == "rule")
    }

    @Test("Content type allowlists omit responses without HTTP content type metadata")
    func responseContentTypeFilterFailsClosedWithoutHTTPMetadata() throws {
        let url = try #require(URL(string: "ftp://example.com/archive"))
        let policy = CapturePolicy(rules: [
            .init(action: .include, hostSuffixes: ["example.com"], contentTypes: ["application/json"])
        ])
        let decision = policy.responseDecision(for: URLResponse(
            url: url,
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        ), request: URLRequest(url: url))
        #expect(!decision.included)
        #expect(decision.reason == .rule)
    }

    @Test("Policy rule and omission diagnostics are bounded")
    func policyDiagnosticsAreBounded() {
        let policy = CapturePolicy(rules: Array(repeating: .init(action: .exclude), count: 256))
        #expect(policy.rules.count == 128)
        let boundedRule = CapturePolicy.Rule(
            action: .exclude,
            hostSuffixes: Set((0 ..< 100).map { "h\($0).example.com" }),
            ports: Set(1 ... 100)
        )
        #expect(boundedRule.hostSuffixes?.count == 64)
        #expect(boundedRule.ports?.count == 64)
        let omission = CaptureOmission(reason: .bodyLimit, observedBytes: Int.max)
        #expect(omission.observedBytes == BabylonConstants.maximumBodySize * 1024)
    }

    @Test("Precompiled maximum-size policy remains responsive across repeated decisions")
    func maximumPolicySetEvaluationRemainsBounded() throws {
        let rules = (0 ..< 128).map { index in
            CapturePolicy.Rule(
                action: .exclude,
                hostSuffixes: ["blocked-\(index).example.test"],
                pathPrefixes: ["/private"]
            )
        }
        let policy = CapturePolicy(rules: rules)
        let request = try URLRequest(url: #require(URL(string: "https://public.example.test/items")))
        let started = ContinuousClock.now

        for _ in 0 ..< 5000 {
            #expect(policy.decision(for: request).included)
        }

        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test("Custom redaction rules preserve default credentials")
    func defaultRedactionCannotBeWeakened() throws {
        let request = Request(
            url: "https://example.com/path?token=secret",
            method: "GET",
            headers: [Header(key: "Authorization", value: "secret")],
            body: nil
        )
        let components = try #require(URLComponents(string: request.url))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(query["token"] == "[REDACTED]")
        #expect(request.headers.first { $0.key == "Authorization" }?.value == "[REDACTED]")
    }
}
