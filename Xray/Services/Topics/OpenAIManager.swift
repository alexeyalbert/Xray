//
//  OpenAIManager.swift
//  Xray
//
//  Created by Alexey Albert on 2025-08-09.
//

import Foundation
#if canImport(OpenAI)
import OpenAI
#endif

enum AIProvider: String, CaseIterable {
    case openai = "OpenAI"
    case openrouter = "OpenRouter"
    
    var baseURL: String? {
        switch self {
        case .openai:
            return nil // Uses default OpenAI URL
        case .openrouter:
            return "https://openrouter.ai/api/v1"
        }
    }
}

enum OpenAIManager {
    static let providerKey = "ai_provider"
    private static let openRouterAppName = "Xray"
    
    static var currentProvider: AIProvider {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: providerKey),
                  let provider = AIProvider(rawValue: rawValue) else {
                return .openai
            }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
        }
    }
    
    /// Build OpenRouter auth headers with the app attribution baked in.
    /// HTTP-Referer is intentionally omitted until Xray has a public app URL.
    static func openRouterHTTPHeaders() -> [String: String]? {
        guard let key = currentAPIKey() else { return nil }
        return [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json",
            "X-Title": openRouterAppName
        ]
    }

    static func currentAPIKey() -> String? {
        KeychainHelper.readString(for: AppSecretsKey.openAIAPIKey.rawValue)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

#if canImport(OpenAI)
    static func makeClient() -> OpenAI? {
        guard let key = currentAPIKey() else { return nil }
        
        switch currentProvider {
        case .openai:
            // Use default OpenAI configuration with relaxed parsing
            let configuration = OpenAI.Configuration(
                token: key,
                parsingOptions: .relaxed
            )
            return OpenAI(configuration: configuration)
            
        case .openrouter:
            return makeOpenRouterClient()
        }
    }
    
    /// Create a client for OpenRouter.
    static func makeOpenRouterClient() -> OpenAI? {
        guard let key = currentAPIKey() else {
            #if DEBUG
            print("OpenRouter client creation failed: API key missing")
            #endif
            return nil 
        }
        
        #if DEBUG
        print("Configuring OpenRouter client")
        #endif
        
        // Configure for OpenRouter using host and scheme (path will be handled automatically)
        let configuration = OpenAI.Configuration(
            token: key,
            host: "openrouter.ai",
            scheme: "https",
            parsingOptions: .relaxed
        )
        
        return OpenAI(configuration: configuration)
    }
#endif
}
