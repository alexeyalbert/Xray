//
//  OpenAIManager.swift
//  Xray
//
//  Created by Alexey Albert on 2025-08-09.
//

import Foundation
import Network

enum AIProvider: String, CaseIterable {
    case openrouter = "OpenRouter"
    case openAICompatible = "OpenAI-Compatible API"

    var displayName: LocalizedStringResource {
        switch self {
        case .openrouter:
            "OpenRouter"
        case .openAICompatible:
            "OpenAI-Compatible API"
        }
    }
}

enum OpenAIManager {
    static let providerKey = "ai_provider"
    static let compatibleBaseURLKey = "topic_openai_compatible_base_url"
    static let compatibleModelKey = "topic_openai_compatible_model"
    private static let openRouterConcurrentRequestsKey = "topic_openrouter_concurrent_requests"
    private static let compatibleConcurrentRequestsKey = "topic_openai_compatible_concurrent_requests"
    private static let separatedTopicAPIKeysMigrationKey = "topic_separate_api_keys_migrated"

    static let defaultCompatibleBaseURL = "https://api.openai.com/v1"
    static let defaultCompatibleModel = "gpt-4.1-mini"
    static let defaultOpenRouterConcurrentRequests = 100
    static let defaultCompatibleConcurrentRequests = 16
    static let topicConcurrentRequestsRange = 1...128

    private static let openRouterAppName = "Xray"

    static var currentProvider: AIProvider {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: providerKey) else {
                return .openAICompatible
            }
            if rawValue == "OpenAI" {
                return .openAICompatible
            }
            return AIProvider(rawValue: rawValue) ?? .openAICompatible
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }

    static var compatibleBaseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: compatibleBaseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultCompatibleBaseURL : stored
        }
        set {
            UserDefaults.standard.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: compatibleBaseURLKey
            )
        }
    }

    static var compatibleModel: String {
        get {
            let stored = UserDefaults.standard.string(forKey: compatibleModelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultCompatibleModel : stored
        }
        set {
            UserDefaults.standard.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: compatibleModelKey
            )
        }
    }

    static func defaultTopicConcurrentRequests(for provider: AIProvider) -> Int {
        switch provider {
        case .openrouter:
            defaultOpenRouterConcurrentRequests
        case .openAICompatible:
            defaultCompatibleConcurrentRequests
        }
    }

    static func topicConcurrentRequests(for provider: AIProvider) -> Int {
        let defaults = UserDefaults.standard
        let key: String
        switch provider {
        case .openrouter:
            key = openRouterConcurrentRequestsKey
        case .openAICompatible:
            key = compatibleConcurrentRequestsKey
        }

        let stored: Int
        if defaults.object(forKey: key) != nil {
            stored = defaults.integer(forKey: key)
        } else {
            stored = defaultTopicConcurrentRequests(for: provider)
        }
        return min(
            max(stored, topicConcurrentRequestsRange.lowerBound),
            topicConcurrentRequestsRange.upperBound
        )
    }

    static func setTopicConcurrentRequests(_ value: Int, for provider: AIProvider) {
        let key = switch provider {
        case .openrouter: openRouterConcurrentRequestsKey
        case .openAICompatible: compatibleConcurrentRequestsKey
        }
        UserDefaults.standard.set(
            min(
                max(value, topicConcurrentRequestsRange.lowerBound),
                topicConcurrentRequestsRange.upperBound
            ),
            forKey: key
        )
    }

    static var topicConcurrentRequests: Int {
        topicConcurrentRequests(for: currentProvider)
    }

    static func topicPersistencePageSize(for provider: AIProvider, concurrentRequests: Int) -> Int {
        switch provider {
        case .openrouter, .openAICompatible:
            min(
                max(concurrentRequests, topicConcurrentRequestsRange.lowerBound),
                topicConcurrentRequestsRange.upperBound
            )
        }
    }

    static func currentAPIKey() -> String? {
        migrateTopicAPIKeysIfNeeded()
        return apiKey(for: currentProvider)
    }

    static func apiKey(for provider: AIProvider) -> String? {
        let account: String
        switch provider {
        case .openrouter:
            account = AppSecretsKey.openRouterAPIKey.rawValue
        case .openAICompatible:
            account = AppSecretsKey.openAICompatibleTopicAPIKey.rawValue
        }

        return KeychainHelper.readString(for: account)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func migrateTopicAPIKeysIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: separatedTopicAPIKeysMigrationKey) else {
            return
        }
        defer { UserDefaults.standard.set(true, forKey: separatedTopicAPIKeysMigrationKey) }

        guard
            currentProvider == .openAICompatible,
            apiKey(for: .openAICompatible) == nil,
            let legacyKey = apiKey(for: .openrouter)
        else {
            return
        }
        _ = KeychainHelper.saveString(
            legacyKey,
            for: AppSecretsKey.openAICompatibleTopicAPIKey.rawValue
        )
    }

    static var isTopicGenerationConfigured: Bool {
        isTopicGenerationConfigured(
            provider: currentProvider,
            model: compatibleModel,
            baseURL: compatibleBaseURL,
            apiKey: currentAPIKey()
        )
    }

    static func isTopicGenerationConfigured(
        provider: AIProvider,
        model: String,
        baseURL: String,
        apiKey: String?
    ) -> Bool {
        switch provider {
        case .openrouter:
            apiKey != nil
        case .openAICompatible:
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (try? chatCompletionsEndpoint(from: baseURL)) != nil
                && (apiKey != nil || compatibleEndpointAllowsMissingAPIKey(baseURL))
        }
    }

    static var topicModel: String {
        switch currentProvider {
        case .openrouter:
            "google/gemini-2.5-flash-lite"
        case .openAICompatible:
            compatibleModel
        }
    }

    static func topicHTTPHeaders() -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let key = currentAPIKey() {
            headers["Authorization"] = "Bearer \(key)"
        }
        if currentProvider == .openrouter {
            headers["X-Title"] = openRouterAppName
        }
        return headers
    }

    static func chatCompletionsEndpoint(from baseURLString: String) throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host != nil
        else {
            throw URLError(.badURL)
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "chat/completions" || path.hasSuffix("/chat/completions") {
            components.path = "/" + path
        } else if path.isEmpty {
            components.path = "/v1/chat/completions"
        } else {
            components.path = "/" + path + "/chat/completions"
        }

        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    /// Local OpenAI-compatible servers often omit auth. Remote hosts such as
    /// `api.openai.com` still require a key; the default base URL is remote.
    /// Private LAN, link-local, Tailscale, and `.local` / `*.ts.net` names
    /// are treated like local hosts.
    private static func compatibleEndpointAllowsMissingAPIKey(_ baseURLString: String) -> Bool {
        guard
            let endpoint = try? chatCompletionsEndpoint(from: baseURLString),
            let host = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.host
        else {
            return false
        }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost"
            || normalized.hasSuffix(".local")
            || normalized.hasSuffix(".ts.net")
        {
            return true
        }
        if let ipv4 = IPv4Address(normalized) {
            return ipv4AllowsMissingAPIKey(ipv4)
        }
        if let ipv6 = IPv6Address(normalized) {
            return ipv6AllowsMissingAPIKey(ipv6)
        }
        return false
    }

    private static func ipv4AllowsMissingAPIKey(_ address: IPv4Address) -> Bool {
        if address.isLoopback || address.isLinkLocal {
            return true
        }
        let octets = [UInt8](address.rawValue)
        guard octets.count == 4 else { return false }
        // RFC 1918
        if octets[0] == 10 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        // Tailscale CGNAT: `100.64.0.0/10`
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func ipv6AllowsMissingAPIKey(_ address: IPv6Address) -> Bool {
        if address.isLoopback || address.isLinkLocal {
            return true
        }
        let octets = [UInt8](address.rawValue)
        guard let first = octets.first else { return false }
        // Unique local addresses `fc00::/7`, including Tailscale `fd7a:115c:a1e0::/48`
        return first & 0xfe == 0xfc
    }

}
