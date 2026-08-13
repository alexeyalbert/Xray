import SwiftUI

struct AISettingsPane: View {
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

    let localModelManager: LocalEmbeddingModelManager
    let onSaveSettings: () -> Void
    let onSaveOpenRouterAPIKey: () -> Void
    let onSaveCompatibleTopicAPIKey: () -> Void
    let onSaveRemoteEmbeddingAPIKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TopicGenerationProviderSettings(
                selectedProvider: $selectedProvider,
                openRouterAPIKey: $openRouterAPIKey,
                openRouterSavedFeedback: openRouterSavedFeedback,
                compatibleAPIKey: $compatibleTopicAPIKey,
                compatibleSavedFeedback: compatibleTopicSavedFeedback,
                compatibleBaseURL: $compatibleTopicBaseURL,
                compatibleModel: $compatibleTopicModel,
                concurrentRequests: $topicConcurrentRequests,
                onSaveSettings: onSaveSettings,
                onSaveOpenRouterAPIKey: onSaveOpenRouterAPIKey,
                onSaveCompatibleAPIKey: onSaveCompatibleTopicAPIKey
            )

            TextEmbeddingSettings(
                selectedEmbeddingProvider: $selectedEmbeddingProvider,
                textEmbeddingBatchSize: $textEmbeddingBatchSize,
                remoteEmbeddingBaseURL: $remoteEmbeddingBaseURL,
                remoteEmbeddingModel: $remoteEmbeddingModel,
                remoteEmbeddingAPIKey: $remoteEmbeddingAPIKey,
                remoteEmbeddingFeedback: remoteEmbeddingFeedback,
                onSaveSettings: onSaveSettings,
                onSaveRemoteEmbeddingAPIKey: onSaveRemoteEmbeddingAPIKey
            )

            LocalModelStorageSettings(manager: localModelManager)
        }
    }
}

private struct TopicGenerationProviderSettings: View {
    @Binding var selectedProvider: AIProvider
    @Binding var openRouterAPIKey: String
    let openRouterSavedFeedback: String
    @Binding var compatibleAPIKey: String
    let compatibleSavedFeedback: String
    @Binding var compatibleBaseURL: String
    @Binding var compatibleModel: String
    @Binding var concurrentRequests: Int
    let onSaveSettings: () -> Void
    let onSaveOpenRouterAPIKey: () -> Void
    let onSaveCompatibleAPIKey: () -> Void

    var body: some View {
        SettingsSectionCard("Topic Generation Provider") {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: selectedProvider) { _, newProvider in
                concurrentRequests = OpenAIManager.topicConcurrentRequests(for: newProvider)
                onSaveSettings()
            }
            .padding(.bottom, 10)

            if selectedProvider == .openAICompatible {
                OpenAICompatibleTopicFields(
                    baseURL: $compatibleBaseURL,
                    model: $compatibleModel,
                    onSaveSettings: onSaveSettings
                )

                Divider()
                    .padding(.vertical, 10)

                TopicAPIKeyField(
                    apiKey: $compatibleAPIKey,
                    savedFeedback: compatibleSavedFeedback,
                    onSaveAPIKey: onSaveCompatibleAPIKey
                )
            } else {
                TopicAPIKeyField(
                    apiKey: $openRouterAPIKey,
                    savedFeedback: openRouterSavedFeedback,
                    onSaveAPIKey: onSaveOpenRouterAPIKey
                )
            }

            Divider()
                .padding(.vertical, 10)

            TopicGenerationConcurrentRequestsSetting(
                concurrentRequests: $concurrentRequests,
                onSaveSettings: onSaveSettings
            )
        }
    }
}

private struct TopicAPIKeyField: View {
    @Binding var apiKey: String
    let savedFeedback: String
    let onSaveAPIKey: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SecureField("API Key", text: $apiKey)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)

            Button("Save", action: onSaveAPIKey)
                .buttonStyle(.borderedProminent)
        }

        if !savedFeedback.isEmpty {
            Text(savedFeedback)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OpenAICompatibleTopicFields: View {
    @Binding var baseURL: String
    @Binding var model: String
    let onSaveSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Base URL")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("https://api.openai.com/v1", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: baseURL) { _, _ in onSaveSettings() }
        }

        Divider()
            .padding(.vertical, 10)

        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("gpt-4.1-mini", text: $model)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model) { _, _ in onSaveSettings() }
        }
    }
}

private struct TopicGenerationConcurrentRequestsSetting: View {
    @Binding var concurrentRequests: Int
    let onSaveSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Concurrent Requests")
                    .font(.subheadline.weight(.medium))

                Text("Maximum simultaneous topic annotation requests")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Concurrent Requests", value: $concurrentRequests, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .accessibilityLabel("Concurrent topic annotation requests")
                .accessibilityValue("\(concurrentRequests) concurrent requests")
                .onChange(of: concurrentRequests) { _, newValue in
                    concurrentRequests = min(
                        max(newValue, OpenAIManager.topicConcurrentRequestsRange.lowerBound),
                        OpenAIManager.topicConcurrentRequestsRange.upperBound
                    )
                    onSaveSettings()
                }
        }
        .padding(.vertical, 8)
    }
}

private struct TextEmbeddingSettings: View {
    @Binding var selectedEmbeddingProvider: EmbeddingProviderKind
    @Binding var textEmbeddingBatchSize: Int
    @Binding var remoteEmbeddingBaseURL: String
    @Binding var remoteEmbeddingModel: String
    @Binding var remoteEmbeddingAPIKey: String
    let remoteEmbeddingFeedback: String
    let onSaveSettings: () -> Void
    let onSaveRemoteEmbeddingAPIKey: () -> Void

    var body: some View {
        SettingsSectionCard("Text Embeddings") {
            if EmbeddingProviderSettings.remoteProviderEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Text Embedding Provider", selection: $selectedEmbeddingProvider) {
                        ForEach(EmbeddingProviderKind.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: selectedEmbeddingProvider) { _, _ in onSaveSettings() }
                }

                Divider()
                    .padding(.vertical, 10)
            }

            TextEmbeddingBatchSizeSetting(
                batchSize: $textEmbeddingBatchSize,
                onSaveSettings: onSaveSettings
            )

            if EmbeddingProviderSettings.remoteProviderEnabled,
               selectedEmbeddingProvider == .openAICompatible {
                RemoteEmbeddingSettings(
                    baseURL: $remoteEmbeddingBaseURL,
                    model: $remoteEmbeddingModel,
                    apiKey: $remoteEmbeddingAPIKey,
                    feedback: remoteEmbeddingFeedback,
                    onSaveSettings: onSaveSettings,
                    onSaveAPIKey: onSaveRemoteEmbeddingAPIKey
                )
            }
        }
    }
}

private struct TextEmbeddingBatchSizeSetting: View {
    @Binding var batchSize: Int
    let onSaveSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Batch Size")
                    .font(.subheadline.weight(.medium))

                Text("Posts processed per text embedding request")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Batch Size", value: $batchSize, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .accessibilityLabel("Text embedding batch size")
                .accessibilityValue("\(batchSize) posts")
                .onChange(of: batchSize) { _, newValue in
                    batchSize = min(
                        max(newValue, EmbeddingProviderSettings.batchSizeRange.lowerBound),
                        EmbeddingProviderSettings.batchSizeRange.upperBound
                    )
                    onSaveSettings()
                }
        }
        .padding(.vertical, 8)
    }
}

private struct RemoteEmbeddingSettings: View {
    @Binding var baseURL: String
    @Binding var model: String
    @Binding var apiKey: String
    let feedback: String
    let onSaveSettings: () -> Void
    let onSaveAPIKey: () -> Void

    var body: some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Base URL")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("http://localhost:1234/v1", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: baseURL) { _, _ in onSaveSettings() }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Qwen/Qwen3-Embedding-0.6B", text: $model)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model) { _, _ in onSaveSettings() }
        }

        Divider()

        HStack(alignment: .center, spacing: 10) {
            SecureField("API Key", text: $apiKey)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)

            Button("Save", action: onSaveAPIKey)
                .buttonStyle(.borderedProminent)
        }

        if !feedback.isEmpty {
            Text(feedback)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
