//
//  KeychainHelper.swift
//  Xray
//
//  Created by Alexey Albert on 2025-08-09.
//

import Foundation
import Security

enum KeychainHelper {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "Xray"
    }

    @discardableResult
    static func saveString(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, for: account)
    }

    static func readString(for account: String) -> String? {
        guard let data = read(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private

    @discardableResult
    private static func save(_ data: Data, for account: String) -> Bool {
        // Try update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }

        // If not found, add
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }

        return false
    }

    private static func read(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }
}

enum AppSecretsKey: String {
    case openAIAPIKey = "openai_api_key"
    case remoteEmbeddingAPIKey = "remote_embedding_api_key"
}

enum BrowserImportReceiverSettings {
    private static let portDefaultsKey = "browser_import_receiver_port"
    private static let tokenAccount = "browser_import_receiver_token"
    private static let portRange = 49152...65535

    static func preferredPort() -> UInt16? {
        let stored = UserDefaults.standard.integer(forKey: portDefaultsKey)
        guard portRange.contains(stored) else { return nil }
        return UInt16(stored)
    }

    static func savePreferredPort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: portDefaultsKey)
    }

    static func clearPreferredPort() {
        UserDefaults.standard.removeObject(forKey: portDefaultsKey)
    }

    static func stableToken() -> String {
        if let existing = KeychainHelper.readString(for: tokenAccount), !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = KeychainHelper.saveString(generated, for: tokenAccount)
        return generated
    }
}

enum MediaViewerSettings {
    static let roundedCornersKey = "media_viewer_rounded_corners"
    static let animateThumbnailAppearanceKey = "media_viewer_animate_thumbnail_appearance"
    static let animateExpandedMediaAppearanceKey = "media_viewer_animate_expanded_media_appearance"
    static let animateExpandedMediaResizeKey = "media_viewer_animate_expanded_media_resize"
}

enum DebugSettings {
    static let showPostContextDebugOptionsKey = "debug_show_post_context_options"
    static let showTemporaryHidePostActionKey = "debug_show_temporary_hide_post_action"
    static let showToolbarInfoButtonKey = "debug_show_toolbar_info_button"

    static var showPostContextDebugOptions: Bool {
        get { UserDefaults.standard.bool(forKey: showPostContextDebugOptionsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showPostContextDebugOptionsKey) }
    }

    static var showTemporaryHidePostAction: Bool {
        get { UserDefaults.standard.bool(forKey: showTemporaryHidePostActionKey) }
        set { UserDefaults.standard.set(newValue, forKey: showTemporaryHidePostActionKey) }
    }

    static var showToolbarInfoButton: Bool {
        get { UserDefaults.standard.bool(forKey: showToolbarInfoButtonKey) }
        set { UserDefaults.standard.set(newValue, forKey: showToolbarInfoButtonKey) }
    }

}

enum EmbeddingProviderKind: String, CaseIterable {
    case local = "Local"
    case openAICompatible = "OpenAI-Compatible API"
}

enum EmbeddingProviderSettings {
    static let remoteProviderEnabled = false
    static let providerKey = "embedding_provider"
    static let remoteBaseURLKey = "embedding_remote_base_url"
    static let remoteModelKey = "embedding_remote_model"
    static let batchSizeKey = "embedding_batch_size"

    static let defaultRemoteBaseURL = "http://localhost:1234/v1"
    static let defaultRemoteModel = "text-embedding-qwen3-embedding-0.6b"
    static let defaultBatchSize = 16
    static let batchSizeRange = 1...128

    static var provider: EmbeddingProviderKind {
        get {
            guard remoteProviderEnabled else { return .local }
            guard let rawValue = UserDefaults.standard.string(forKey: providerKey),
                  let provider = EmbeddingProviderKind(rawValue: rawValue) else {
                return .local
            }
            return provider
        }
        set {
            let provider = remoteProviderEnabled ? newValue : .local
            UserDefaults.standard.set(provider.rawValue, forKey: providerKey)
        }
    }

    static var remoteBaseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: remoteBaseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultRemoteBaseURL : stored
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: remoteBaseURLKey)
        }
    }

    static var remoteModel: String {
        get {
            let stored = UserDefaults.standard.string(forKey: remoteModelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultRemoteModel : stored
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: remoteModelKey)
        }
    }

    static var batchSize: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: batchSizeKey)
            return batchSizeRange.contains(stored) ? stored : defaultBatchSize
        }
        set {
            UserDefaults.standard.set(
                min(max(newValue, batchSizeRange.lowerBound), batchSizeRange.upperBound),
                forKey: batchSizeKey
            )
        }
    }

    static var remoteAPIKey: String? {
        KeychainHelper.readString(for: AppSecretsKey.remoteEmbeddingAPIKey.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
