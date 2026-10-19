// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Immutable rules that decide which URLSession traffic Babylon retains.
///
/// A policy is evaluated once when a task is created. Rules are compiled before capture starts,
/// and default credential redaction remains active independently of capture selection.
public struct CapturePolicy: Sendable {
    public enum Action: Sendable {
        case include
        case exclude
    }

    public struct Rule: Sendable {
        public let action: Action
        public let schemes: Set<String>?
        public let hostSuffixes: Set<String>?
        public let ports: Set<Int>?
        public let methods: Set<String>?
        public let pathPrefixes: [String]?
        public let contentTypes: Set<String>?

        public init(
            action: Action,
            schemes: Set<String>? = nil,
            hostSuffixes: Set<String>? = nil,
            ports: Set<Int>? = nil,
            methods: Set<String>? = nil,
            pathPrefixes: [String]? = nil,
            contentTypes: Set<String>? = nil
        ) {
            self.action = action
            self.schemes = Self.normalized(schemes, maximumCount: 16, maximumBytes: 32) { $0.lowercased() }
            self.hostSuffixes = Self.normalized(hostSuffixes, maximumCount: 64, maximumBytes: 253) {
                $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            self.ports = ports.map { Set($0.filter { (1 ... 65535).contains($0) }.sorted().prefix(64)) }
            self.methods = Self.normalized(methods, maximumCount: 64, maximumBytes: 32) { $0.uppercased() }
            self.pathPrefixes = pathPrefixes.map {
                Array(Set($0.filter { $0.hasPrefix("/") && $0.utf8.count <= 2048 }).sorted().prefix(64))
            }
            self.contentTypes = Self.normalized(contentTypes, maximumCount: 64, maximumBytes: 128) {
                $0.split(separator: ";", maxSplits: 1).first.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                } ?? ""
            }
        }

        private static func normalized(
            _ values: Set<String>?,
            maximumCount: Int,
            maximumBytes: Int,
            transform: (String) -> String
        ) -> Set<String>? {
            guard let values else { return nil }
            return Set(values.sorted().prefix(maximumCount).compactMap { value in
                let normalized = transform(value)
                guard !normalized.isEmpty, normalized.utf8.count <= maximumBytes else { return nil }
                return normalized
            })
        }
    }

    public let rules: [Rule]
    public let metadataOnly: Bool
    public let maximumRequestBodyBytes: Int
    public let maximumResponseBodyBytes: Int
    private let compiledRules: [CompiledRule]
    private let responseRules: [CompiledRule]
    private let hasIncludeRules: Bool
    private let hasRequestIncludeRules: Bool

    public init(
        rules: [Rule] = [],
        metadataOnly: Bool = false,
        maximumRequestBodyBytes: Int = 50 * 1024 * 1024,
        maximumResponseBodyBytes: Int = 50 * 1024 * 1024
    ) {
        self.rules = Array(rules.prefix(128))
        self.metadataOnly = metadataOnly
        self.maximumRequestBodyBytes = min(max(0, maximumRequestBodyBytes), BabylonConstants.maximumBodySize)
        self.maximumResponseBodyBytes = min(max(0, maximumResponseBodyBytes), BabylonConstants.maximumBodySize)
        compiledRules = Array(rules.prefix(128)).map(CompiledRule.init)
        hasIncludeRules = rules.prefix(128).contains { $0.action == .include }
        hasRequestIncludeRules = rules.prefix(128).contains { $0.action == .include && $0.contentTypes == nil }
        responseRules = Array(rules.prefix(128).filter { $0.contentTypes != nil })
            .map(CompiledRule.init)
    }

    func decision(for request: URLRequest) -> CapturePolicyDecision {
        guard let url = request.url else { return .excluded(reason: .invalidURL) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let method = (request.httpMethod ?? "GET").uppercased()
        let contentType = request.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let facts = CapturePolicyFacts(
            scheme: url.scheme?.lowercased() ?? "",
            host: url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "",
            port: components?.port ?? url.port ?? defaultPort(for: url.scheme),
            method: method,
            path: url.path.isEmpty ? "/" : url.path,
            contentType: contentType
        )
        var matchesAllowRule = false
        for rule in compiledRules {
            guard rule.matches(facts, includingContentType: false) else {
                continue
            }
            if rule.contentTypes != nil {
                if rule.action == .include {
                    matchesAllowRule = true
                }
                continue
            }
            if rule.action == .exclude {
                return .excluded(reason: .rule)
            }
            matchesAllowRule = true
        }
        return !hasRequestIncludeRules || matchesAllowRule ? .included : .excluded(reason: .rule)
    }

    private func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http", "ws": 80
        case "https", "wss": 443
        default: nil
        }
    }

    func responseDecision(for response: URLResponse, request: URLRequest) -> CapturePolicyDecision {
        guard !responseRules.isEmpty else { return .included }
        guard let http = response as? HTTPURLResponse else {
            return .excluded(reason: .rule)
        }
        guard let value = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1)
            .first.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) else {
            return .excluded(reason: .rule)
        }
        let requestFacts = facts(for: request)
        var matchedInclude = false
        for rule in compiledRules where rule.matches(requestFacts, includingContentType: false) {
            guard let contentTypes = rule.contentTypes else {
                if rule.action == .exclude {
                    return .excluded(reason: .rule)
                }
                matchedInclude = true
                continue
            }
            guard contentTypes.contains(value) else { continue }
            if rule.action == .exclude {
                return .excluded(reason: .rule)
            }
            matchedInclude = true
        }
        guard !hasIncludeRules || matchedInclude else {
            return .excluded(reason: .rule)
        }
        return .included
    }

    private func facts(for request: URLRequest) -> CapturePolicyFacts {
        guard let url = request.url else {
            return CapturePolicyFacts(
                scheme: "",
                host: "",
                port: nil,
                method: (request.httpMethod ?? "GET").uppercased(),
                path: "/",
                contentType: nil
            )
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return CapturePolicyFacts(
            scheme: url.scheme?.lowercased() ?? "",
            host: url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "",
            port: components?.port ?? url.port ?? defaultPort(for: url.scheme),
            method: (request.httpMethod ?? "GET").uppercased(),
            path: url.path.isEmpty ? "/" : url.path,
            contentType: nil
        )
    }
}

struct CapturePolicyDecision: Sendable {
    enum OmissionReason: String, Sendable {
        case rule
        case invalidURL
        case bodyLimit
    }

    let included: Bool
    let reason: OmissionReason?

    static let included = CapturePolicyDecision(included: true, reason: nil)

    static func excluded(reason: OmissionReason) -> CapturePolicyDecision {
        CapturePolicyDecision(included: false, reason: reason)
    }
}

public struct CaptureOmission: Codable, Equatable, Sendable {
    public let reason: String
    public let observedBytes: Int
    public let originalBytes: Int?

    public init(reason: String, observedBytes: Int, originalBytes: Int? = nil) {
        self.reason = String(reason.prefix(128))
        self.observedBytes = Self.boundedBytes(observedBytes)
        self.originalBytes = originalBytes.map(Self.boundedBytes)
    }

    init(reason: CapturePolicyDecision.OmissionReason, observedBytes: Int, originalBytes: Int? = nil) {
        self.init(reason: reason.rawValue, observedBytes: observedBytes, originalBytes: originalBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case observedBytes
        case originalBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reason = try String(values.decode(String.self, forKey: .reason).prefix(128))
        observedBytes = try Self.boundedBytes(values.decode(Int.self, forKey: .observedBytes))
        originalBytes = try values.decodeIfPresent(Int.self, forKey: .originalBytes).map(Self.boundedBytes)
    }

    private static func boundedBytes(_ value: Int) -> Int {
        min(max(0, value), BabylonConstants.maximumBodySize * 1024)
    }
}

private struct CapturePolicyFacts {
    let scheme: String
    let host: String
    let port: Int?
    let method: String
    let path: String
    let contentType: String?
}

private struct CompiledRule: Sendable {
    let action: CapturePolicy.Action
    let schemes: Set<String>?
    let hostSuffixes: Set<String>?
    let ports: Set<Int>?
    let methods: Set<String>?
    let pathPrefixes: [String]?
    let contentTypes: Set<String>?

    init(_ rule: CapturePolicy.Rule) {
        action = rule.action
        schemes = rule.schemes
        hostSuffixes = rule.hostSuffixes
        ports = rule.ports
        methods = rule.methods
        pathPrefixes = rule.pathPrefixes
        contentTypes = rule.contentTypes
    }

    func matches(_ facts: CapturePolicyFacts, includingContentType: Bool) -> Bool {
        if let schemes, !schemes.contains(facts.scheme) {
            return false
        }
        if let hostSuffixes, !hostSuffixes.contains(where: { facts.host == $0 || facts.host.hasSuffix("." + $0) }) {
            return false
        }
        if let ports, facts.port.map(ports.contains) != true {
            return false
        }
        if let methods, !methods.contains(facts.method) {
            return false
        }
        if let pathPrefixes,
           !pathPrefixes
           .contains(where: { facts.path == $0 || facts.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
            return false
        }
        if includingContentType, let contentTypes, facts.contentType.map(contentTypes.contains) != true {
            return false
        }
        return true
    }
}
