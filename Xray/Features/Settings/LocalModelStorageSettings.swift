import SwiftUI

struct LocalModelStorageSettings: View {
    let manager: LocalEmbeddingModelManager

    var body: some View {
        SettingsSectionCard(
            "Downloaded Models",
            footer: "Deleted models can be downloaded again from onboarding"
        ) {
            SettingsValueRow(
                title: "Total Disk Usage",
                value: ByteCountFormatter.string(
                    fromByteCount: manager.totalInstalledSize,
                    countStyle: .file
                ),
                systemImage: "internaldrive"
            )

            ForEach(LocalEmbeddingModel.allCases) { model in
                Divider()
                LocalModelSettingsRow(model: model, manager: manager)
            }
        }
    }
}

private struct LocalModelSettingsRow: View {
    let model: LocalEmbeddingModel
    let manager: LocalEmbeddingModelManager

    @State private var isConfirmingDeletion = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model == .text ? "text.magnifyingglass" : "photo.badge.magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .installed = manager.state(for: model) {
                Button("Delete", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .buttonStyle(.bordered)
                .pointingHandOnHover()
                .confirmationDialog(
                    "Delete \(model.displayName)?",
                    isPresented: $isConfirmingDeletion
                ) {
                    Button("Delete Model", role: .destructive) {
                        Task { await manager.delete(model) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Xray will remove the downloaded model files. You can download them again by replaying onboarding.")
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var statusText: String {
        switch manager.state(for: model) {
        case .notInstalled:
            "Not downloaded"
        case let .downloading(progress):
            "Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))"
        case let .installed(size):
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        case let .failed(message):
            message
        }
    }
}
