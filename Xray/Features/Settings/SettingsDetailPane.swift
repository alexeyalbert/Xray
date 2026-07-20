import SwiftUI

struct SettingsDetailPane: View {
    let category: SettingsCategory

    @Binding var useRoundedMediaCorners: Bool
    @Binding var animateThumbnailAppearance: Bool
    @Binding var animateExpandedMediaAppearance: Bool
    @Binding var animateExpandedMediaResize: Bool

    @Binding var selectedProvider: AIProvider
    @Binding var apiKey: String
    @Binding var savedFeedback: String
    @Binding var selectedEmbeddingProvider: EmbeddingProviderKind
    @Binding var textEmbeddingBatchSize: Int
    @Binding var remoteEmbeddingBaseURL: String
    @Binding var remoteEmbeddingModel: String
    @Binding var remoteEmbeddingAPIKey: String
    @Binding var remoteEmbeddingFeedback: String

    @Binding var preferredPortText: String
    @Binding var preferredPortFeedback: String

    @Binding var showPostContextDebugOptions: Bool
    @Binding var showTemporaryHidePostAction: Bool
    @Binding var showToolbarInfoButton: Bool

    let localModelManager: LocalEmbeddingModelManager
    let importState: ImportState
    let onSaveSettings: () -> Void
    let onSaveAPIKey: () -> Void
    let onSaveRemoteEmbeddingAPIKey: () -> Void
    let onSavePreferredPort: () -> Void
    let onRebuildDatabaseSchema: () -> Void
    let onResetDatabase: () -> Void

    var body: some View {
        switch category {
        case .general:
            GeneralSettingsPane(
                useRoundedMediaCorners: $useRoundedMediaCorners,
                animateThumbnailAppearance: $animateThumbnailAppearance,
                animateExpandedMediaAppearance: $animateExpandedMediaAppearance,
                animateExpandedMediaResize: $animateExpandedMediaResize
            )
        case .ai:
            AISettingsPane(
                selectedProvider: $selectedProvider,
                apiKey: $apiKey,
                savedFeedback: $savedFeedback,
                selectedEmbeddingProvider: $selectedEmbeddingProvider,
                textEmbeddingBatchSize: $textEmbeddingBatchSize,
                remoteEmbeddingBaseURL: $remoteEmbeddingBaseURL,
                remoteEmbeddingModel: $remoteEmbeddingModel,
                remoteEmbeddingAPIKey: $remoteEmbeddingAPIKey,
                remoteEmbeddingFeedback: $remoteEmbeddingFeedback,
                localModelManager: localModelManager,
                onSaveSettings: onSaveSettings,
                onSaveAPIKey: onSaveAPIKey,
                onSaveRemoteEmbeddingAPIKey: onSaveRemoteEmbeddingAPIKey
            )
        case .browserImport:
            BrowserImportSettingsPane(
                preferredPortText: $preferredPortText,
                preferredPortFeedback: $preferredPortFeedback,
                onSavePreferredPort: onSavePreferredPort
            )
        case .debug:
            DebugSettingsPane(
                showPostContextDebugOptions: $showPostContextDebugOptions,
                showTemporaryHidePostAction: $showTemporaryHidePostAction,
                showToolbarInfoButton: $showToolbarInfoButton,
                importState: importState,
                onRebuildDatabaseSchema: onRebuildDatabaseSchema,
                onResetDatabase: onResetDatabase
            )
        }
    }
}
