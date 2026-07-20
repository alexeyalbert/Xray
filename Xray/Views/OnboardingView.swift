//
//  OnboardingView.swift
//  Xray
//

import SwiftUI

enum OnboardingSettings {
    static let completedKey = "onboarding_completed_v1"

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }
}

private enum OnboardingStage: Int, CaseIterable {
    case intro
    case models
    case userscriptManager
    case userscriptInstall
    case openRouter
    case ready
}

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var stage: OnboardingStage = .intro
    @State private var modelManager = LocalEmbeddingModelManager()

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    switch stage {
                    case .intro:
                        IntroStep(onContinue: advance)
                    case .models:
                        ModelSetupStep(
                            manager: modelManager,
                            onBack: goBack,
                            onContinue: advance,
                            onSkipAll: complete
                        )
                    case .userscriptManager:
                        UserscriptManagerStep(
                            onBack: goBack,
                            onContinue: advance,
                            onSkipAll: complete
                        )
                    case .userscriptInstall:
                        UserscriptInstallStep(
                            onBack: goBack,
                            onContinue: advance,
                            onSkipAll: complete
                        )
                    case .openRouter:
                        OpenRouterSetupStep(
                            onBack: goBack,
                            onContinue: advance,
                            onSkipAll: complete
                        )
                    case .ready:
                        ReadyStep(onBack: goBack, onComplete: complete)
                    }
                }
                .frame(maxHeight: .infinity)

                OnboardingPageIndicator(
                    stages: OnboardingStage.allCases,
                    currentStage: stage
                )
                .padding(.bottom, 14)
            }
        }
        .frame(width: 1000, height: 554)
    }

    private func advance() {
        guard let next = OnboardingStage(rawValue: stage.rawValue + 1) else {
            complete()
            return
        }
        stage = next
    }

    private func goBack() {
        guard let previous = OnboardingStage(rawValue: stage.rawValue - 1) else { return }
        stage = previous
    }

    private func complete() {
        OnboardingSettings.hasCompleted = true
        onComplete()
    }
}

private struct IntroStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 34) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Welcome to Xray")
                        .font(.largeTitle)
                        .padding(.bottom, 22)

                    Text("Never lose a tweet you bookmarked again, with an app made to cover every edge case")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 28)

                    VStack(alignment: .leading, spacing: 14) {
                        IntroFeatureRow(
                            systemImage: "tag",
                            text: "**Topic** tagging, for easy high-level categorization"
                        )
                        IntroFeatureRow(
                            systemImage: "brain",
                            text: "**Text** and **image** embeddings for semantic meaning"
                        )
                        IntroFeatureRow(
                            systemImage: "eye.slash",
                            text: "**Free** and entirely **on-device** if you choose to opt out of topic tagging via direct (not proxied) ZDR OpenRouter API calls."
                        )
                    }

                    Text("Xray is [open-source](https://github.com/alexeyalbert/xray) and able to be easily inspected.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 30)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                Image("OnboardingProductPlaceholder")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 430, height: 350)
                    //.shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button(action: onContinue) {
                    HStack(spacing: 8) {
                        Text("Continue")
                        Image(systemName: "return")
                    }
                    .frame(minWidth: 118)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .pointingHandOnHover()
            }
        }
        .frame(maxWidth: 900, maxHeight: .infinity)
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 30)
    }
}

private struct IntroFeatureRow: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tertiary)
                .frame(width: 24)

            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingPageIndicator: View {
    let stages: [OnboardingStage]
    let currentStage: OnboardingStage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(stages, id: \.rawValue) { stage in
                Circle()
                    .fill(stage == currentStage ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: stage == currentStage ? 7 : 6, height: stage == currentStage ? 7 : 6)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue("Page \(currentStage.rawValue + 1) of \(stages.count)")
    }
}

private struct ModelSetupStep: View {
    let manager: LocalEmbeddingModelManager
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkipAll: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Download Embedding Models",
            description: "Semantic text and image search requires local models to be downloaded. You can download either model now, skip this step, or manage them later in Settings.",
            onBack: onBack,
            onContinue: onContinue,
            onSkipAll: onSkipAll,
            continueTitle: "Continue"
        ) {
            VStack(spacing: 12) {
                ForEach(LocalEmbeddingModel.allCases) { model in
                    ModelDownloadRow(model: model, manager: manager)
                }

                Button {
                    Task { await manager.downloadMissingModels() }
                } label: {
                    Label("Download Missing Models", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(manager.isDownloading)
                .pointingHandOnHover()
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ModelDownloadRow: View {
    let model: LocalEmbeddingModel
    let manager: LocalEmbeddingModelManager

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model == .text ? "text.magnifyingglass" : "photo.badge.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayName)
                    .font(.headline)
                Text(model.repositoryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case let .downloading(progress) = manager.state(for: model) {
                    ProgressView(value: progress)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if case let .failed(message) = manager.state(for: model) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            ModelStateAction(model: model, manager: manager)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct ModelStateAction: View {
    let model: LocalEmbeddingModel
    let manager: LocalEmbeddingModelManager

    var body: some View {
        switch manager.state(for: model) {
        case .notInstalled, .failed:
            Button("Download") {
                Task { await manager.download(model) }
            }
            .buttonStyle(.bordered)
            .disabled(manager.isDownloading)
            .pointingHandOnHover()
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case let .installed(size):
            VStack(alignment: .trailing, spacing: 3) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UserscriptManager: Identifiable {
    let id: String
    let name: LocalizedStringResource
    let imageName: String
    let compatibility: LocalizedStringResource
    let isRecommended: Bool
    let isOpenSource: Bool
    let url: URL
}

private struct UserscriptManagerStep: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkipAll: () -> Void

    private let managers = [
        UserscriptManager(
            id: "violentmonkey",
            name: "Violentmonkey",
            imageName: "ViolentmonkeyIcon",
            compatibility: "Compatible with Chrome, Firefox, and Microsoft Edge.",
            isRecommended: true,
            isOpenSource: true,
            url: URL(string: "https://violentmonkey.github.io/")!
        ),
        UserscriptManager(
            id: "tampermonkey",
            name: "Tampermonkey",
            imageName: "TampermonkeyIcon",
            compatibility: "Compatible with Chrome, Microsoft Edge, Firefox, Safari, and Opera.",
            isRecommended: false,
            isOpenSource: false,
            url: URL(string: "https://www.tampermonkey.net/")!
        ),
        UserscriptManager(
            id: "greasemonkey",
            name: "Greasemonkey",
            imageName: "GreasemonkeyIcon",
            compatibility: "Compatible with Firefox on desktop and Android.",
            isRecommended: false,
            isOpenSource: true,
            url: URL(string: "https://addons.mozilla.org/en-US/firefox/addon/greasemonkey/")!
        )
    ]

    var body: some View {
        OnboardingStepLayout(
            title: "Choose a userscript manager",
            description: "Xray uses a userscript to capture your X bookmarks and sends them directly to the app's local import receiver via a local HTTP server. The userscript also has an option to export a JSON archive instead.",
            onBack: onBack,
            onContinue: onContinue,
            onSkipAll: onSkipAll,
            continueTitle: "I Have a Manager"
        ) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(managers) { manager in
                    UserscriptManagerCard(manager: manager)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct UserscriptManagerCard: View {
    let manager: UserscriptManager

    var body: some View {
        Link(destination: manager.url) {
            VStack(spacing: 8) {
                Spacer(minLength: 0)

                Image(manager.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)

                Text(manager.name)
                    .font(.headline)

                if manager.isRecommended {
                    Text("Recommended")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Text(manager.compatibility)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                UserscriptSourceStatus(isOpenSource: manager.isOpenSource)
            }
            .padding(12)
            .frame(width: 210, height: 250)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}

private struct UserscriptSourceStatus: View {
    let isOpenSource: Bool

    var body: some View {
        if isOpenSource {
            Label("Open source", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Label("Closed source", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct UserscriptInstallStep: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkipAll: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Install the Xray userscript",
            description: "Once the script is published, Xray will open its installation page in your default browser here.",
            onBack: onBack,
            onContinue: onContinue,
            onSkipAll: onSkipAll,
            continueTitle: "Continue"
        ) {
            VStack(spacing: 18) {
                Image(systemName: "safari.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text("Userscript link coming soon")
                    .font(.title2.weight(.semibold))

                Text("The checked-in userscript is not hosted at a stable public URL yet. This button is intentionally a placeholder until the script is published.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                Button("Open Userscript in Default Browser") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
}

private struct OpenRouterSetupStep: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkipAll: () -> Void

    @State private var apiKey = ""
    @State private var feedback = ""

    var body: some View {
        OnboardingStepLayout(
            title: "Set up topic generation",
            description: "OpenRouter is optional. When enabled, Xray uses it to generate topics for posts. Your key is stored in the macOS Keychain, and all calls are made directly to OpenRouter, with Zero Data Retention enabled for every API call.\nA archive of ~32,000 posts costs about $2.80 USD to tag with topics.",
            onBack: onBack,
            onContinue: saveAndContinue,
            onSkipAll: onSkipAll,
            continueTitle: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Skip This Step" : "Save and Continue"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                    Label("Create or View an OpenRouter API Key", systemImage: "arrow.up.right.square")
                }
                .pointingHandOnHover()

                VStack(alignment: .leading, spacing: 7) {
                    Text("OpenRouter API Key")
                        .font(.headline)
                    SecureField("sk-or-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                }

                if !feedback.isEmpty {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Label(
                    "Topic generation sends post text and available public media URLs to OpenRouter. Local embeddings remain on your Mac.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .onAppear {
                apiKey = OpenAIManager.currentAPIKey() ?? ""
            }
        }
    }

    private func saveAndContinue() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onContinue()
            return
        }

        guard KeychainHelper.saveString(trimmed, for: AppSecretsKey.openAIAPIKey.rawValue) else {
            feedback = "The API key could not be saved to Keychain."
            return
        }

        OpenAIManager.currentProvider = .openrouter
        onContinue()
    }
}

private struct ReadyStep: View {
    let onBack: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(.green)

            Text("Xray is ready")
                .font(.largeTitle.weight(.bold))

            Text("You can revisit this setup at any time from Xray → Replay Onboarding.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointingHandOnHover()

                Button("Start Using Xray", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .pointingHandOnHover()
            }
        }
        .padding(40)
    }
}

private struct OnboardingStepLayout<Content: View>: View {
    let title: String
    let description: String
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkipAll: () -> Void
    let continueTitle: String
    let showsBackButton: Bool
    @ViewBuilder let content: Content

    init(
        title: String,
        description: String,
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        onSkipAll: @escaping () -> Void,
        continueTitle: String,
        showsBackButton: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.onBack = onBack
        self.onContinue = onContinue
        self.onSkipAll = onSkipAll
        self.continueTitle = continueTitle
        self.showsBackButton = showsBackButton
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button("Skip Onboarding", action: onSkipAll)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .pointingHandOnHover()
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(description)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)

            ScrollView {
                content
                    .padding(1)
            }

            HStack {
                if showsBackButton {
                    Button("Back", action: onBack)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .pointingHandOnHover()
                }

                Spacer()

                Button(continueTitle, action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .pointingHandOnHover()
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: 860, maxHeight: 544)
        .padding(30)
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .frame(width: 1000, height: 700)
}
