import SwiftUI

struct SettingsView: View {
    static let modalSize = CGSize(width: 800, height: 530)

    let importState: ImportState
    let onRebuildDatabaseSchema: () -> Void
    let onResetDatabase: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(MediaViewerSettings.roundedCornersKey) private var useRoundedMediaCorners: Bool = true
    @AppStorage(MediaViewerSettings.animateThumbnailAppearanceKey) private var animateThumbnailAppearance: Bool = true
    @AppStorage(MediaViewerSettings.animateExpandedMediaAppearanceKey) private var animateExpandedMediaAppearance: Bool = true
    @AppStorage(MediaViewerSettings.animateExpandedMediaResizeKey) private var animateExpandedMediaResize: Bool = true
    @AppStorage(DebugSettings.showPostContextDebugOptionsKey) private var showPostContextDebugOptions: Bool = false
    @AppStorage(DebugSettings.showTemporaryHidePostActionKey) private var showTemporaryHidePostAction: Bool = false
    @AppStorage(DebugSettings.showToolbarInfoButtonKey) private var showToolbarInfoButton: Bool = false

    @State private var apiKey = ""
    @State private var savedFeedback = ""
    @State private var selectedProvider: AIProvider = .openai
    @State private var selectedEmbeddingProvider: EmbeddingProviderKind = .local
    @State private var localModelManager = LocalEmbeddingModelManager()
    @State private var textEmbeddingBatchSize = EmbeddingProviderSettings.defaultBatchSize
    @State private var remoteEmbeddingBaseURL = EmbeddingProviderSettings.defaultRemoteBaseURL
    @State private var remoteEmbeddingModel = EmbeddingProviderSettings.defaultRemoteModel
    @State private var remoteEmbeddingAPIKey = ""
    @State private var remoteEmbeddingFeedback = ""
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var preferredPortText = ""
    @State private var preferredPortFeedback = ""

    private var currentCategory: SettingsCategory {
        selectedCategory ?? .general
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selectedCategory)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                SettingsDetailPane(
                    category: currentCategory,
                    useRoundedMediaCorners: $useRoundedMediaCorners,
                    animateThumbnailAppearance: $animateThumbnailAppearance,
                    animateExpandedMediaAppearance: $animateExpandedMediaAppearance,
                    animateExpandedMediaResize: $animateExpandedMediaResize,
                    selectedProvider: $selectedProvider,
                    apiKey: $apiKey,
                    savedFeedback: $savedFeedback,
                    selectedEmbeddingProvider: $selectedEmbeddingProvider,
                    textEmbeddingBatchSize: $textEmbeddingBatchSize,
                    remoteEmbeddingBaseURL: $remoteEmbeddingBaseURL,
                    remoteEmbeddingModel: $remoteEmbeddingModel,
                    remoteEmbeddingAPIKey: $remoteEmbeddingAPIKey,
                    remoteEmbeddingFeedback: $remoteEmbeddingFeedback,
                    preferredPortText: $preferredPortText,
                    preferredPortFeedback: $preferredPortFeedback,
                    showPostContextDebugOptions: $showPostContextDebugOptions,
                    showTemporaryHidePostAction: $showTemporaryHidePostAction,
                    showToolbarInfoButton: $showToolbarInfoButton,
                    localModelManager: localModelManager,
                    importState: importState,
                    onSaveSettings: saveSettings,
                    onSaveAPIKey: saveAPIKey,
                    onSaveRemoteEmbeddingAPIKey: saveRemoteEmbeddingAPIKey,
                    onSavePreferredPort: savePreferredPort,
                    onRebuildDatabaseSchema: onRebuildDatabaseSchema,
                    onResetDatabase: onResetDatabase
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 35)
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear { loadSettings() }
        .task { localModelManager.refresh() }
        .overlay(alignment: .topTrailing) {
            SettingsCloseButton(action: { dismiss() })
                .padding(14)
        }
    }

    private func loadAPIKey() {
        apiKey = KeychainHelper.readString(for: AppSecretsKey.openAIAPIKey.rawValue) ?? ""
    }

    private func loadSettings() {
        loadAPIKey()
        selectedProvider = OpenAIManager.currentProvider
        selectedEmbeddingProvider = EmbeddingProviderSettings.provider
        textEmbeddingBatchSize = EmbeddingProviderSettings.batchSize
        remoteEmbeddingBaseURL = EmbeddingProviderSettings.remoteBaseURL
        remoteEmbeddingModel = EmbeddingProviderSettings.remoteModel
        remoteEmbeddingAPIKey = KeychainHelper.readString(for: AppSecretsKey.remoteEmbeddingAPIKey.rawValue) ?? ""
        preferredPortText = BrowserImportReceiverSettings.preferredPort().map(String.init) ?? ""
    }

    private func saveSettings() {
        OpenAIManager.currentProvider = selectedProvider
        EmbeddingProviderSettings.provider = selectedEmbeddingProvider
        EmbeddingProviderSettings.batchSize = textEmbeddingBatchSize
        EmbeddingProviderSettings.remoteBaseURL = remoteEmbeddingBaseURL
        EmbeddingProviderSettings.remoteModel = remoteEmbeddingModel
    }

    private func saveAPIKey() {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = KeychainHelper.delete(for: AppSecretsKey.openAIAPIKey.rawValue)
            savedFeedback = "Removed key"
        } else if KeychainHelper.saveString(apiKey, for: AppSecretsKey.openAIAPIKey.rawValue) {
            savedFeedback = "Saved"
        } else {
            savedFeedback = "Save failed"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedFeedback = "" }
    }

    private func saveRemoteEmbeddingAPIKey() {
        let trimmed = remoteEmbeddingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = KeychainHelper.delete(for: AppSecretsKey.remoteEmbeddingAPIKey.rawValue)
            remoteEmbeddingFeedback = "Removed key"
        } else if KeychainHelper.saveString(trimmed, for: AppSecretsKey.remoteEmbeddingAPIKey.rawValue) {
            remoteEmbeddingFeedback = "Saved"
        } else {
            remoteEmbeddingFeedback = "Save failed"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { remoteEmbeddingFeedback = "" }
    }

    private func savePreferredPort() {
        let trimmed = preferredPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            BrowserImportReceiverSettings.clearPreferredPort()
            preferredPortFeedback = "Using automatic port"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { preferredPortFeedback = "" }
            return
        }

        guard let port = UInt16(trimmed), (49152...65535).contains(Int(port)) else {
            preferredPortFeedback = "Use a port from 49152 to 65535"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { preferredPortFeedback = "" }
            return
        }

        BrowserImportReceiverSettings.savePreferredPort(port)
        preferredPortText = String(port)
        preferredPortFeedback = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { preferredPortFeedback = "" }
    }
}

private struct SettingsCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .padding(4)
        }
        .buttonBorderShape(.circle)
        .compatibleGlassCircleButton()
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

#Preview {
    SettingsView(
        importState: ImportState(),
        onRebuildDatabaseSchema: {},
        onResetDatabase: {}
    )
    .frame(width: SettingsView.modalSize.width, height: SettingsView.modalSize.height)
}
