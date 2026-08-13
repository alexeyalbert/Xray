import SwiftUI

struct SettingsDetailPane: View {
    let category: SettingsCategory

    @Binding var useRoundedMediaCorners: Bool
    @Binding var animateThumbnailAppearance: Bool
    @Binding var animateExpandedMediaAppearance: Bool
    @Binding var animateExpandedMediaResize: Bool

    @Binding var selectedProvider: AIProvider
    @Binding var openRouterAPIKey: String
    @Binding var openRouterSavedFeedback: String
    @Binding var compatibleTopicAPIKey: String
    @Binding var compatibleTopicSavedFeedback: String
    @Binding var compatibleTopicBaseURL: String
    @Binding var compatibleTopicModel: String
    @Binding var topicConcurrentRequests: Int
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
    let onSaveOpenRouterAPIKey: () -> Void
    let onSaveCompatibleTopicAPIKey: () -> Void
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
                openRouterAPIKey: $openRouterAPIKey,
                openRouterSavedFeedback: $openRouterSavedFeedback,
                compatibleTopicAPIKey: $compatibleTopicAPIKey,
                compatibleTopicSavedFeedback: $compatibleTopicSavedFeedback,
                compatibleTopicBaseURL: $compatibleTopicBaseURL,
                compatibleTopicModel: $compatibleTopicModel,
                topicConcurrentRequests: $topicConcurrentRequests,
                selectedEmbeddingProvider: $selectedEmbeddingProvider,
                textEmbeddingBatchSize: $textEmbeddingBatchSize,
                remoteEmbeddingBaseURL: $remoteEmbeddingBaseURL,
                remoteEmbeddingModel: $remoteEmbeddingModel,
                remoteEmbeddingAPIKey: $remoteEmbeddingAPIKey,
                remoteEmbeddingFeedback: $remoteEmbeddingFeedback,
                localModelManager: localModelManager,
                onSaveSettings: onSaveSettings,
                onSaveOpenRouterAPIKey: onSaveOpenRouterAPIKey,
                onSaveCompatibleTopicAPIKey: onSaveCompatibleTopicAPIKey,
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
