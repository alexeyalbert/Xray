import SwiftUI

struct DebugSettingsPane: View {
    @Binding var showPostContextDebugOptions: Bool
    @Binding var showTemporaryHidePostAction: Bool
    @Binding var showToolbarInfoButton: Bool
    let importState: ImportState
    let onRebuildDatabaseSchema: () -> Void
    let onResetDatabase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ToolbarDebugSettings(isInfoButtonEnabled: $showToolbarInfoButton)
            PostContextDebugSettings(
                areDiagnosticActionsEnabled: $showPostContextDebugOptions,
                isTemporaryHideActionEnabled: $showTemporaryHidePostAction
            )
            DatabaseMaintenanceSettings(
                importState: importState,
                onRebuildDatabaseSchema: onRebuildDatabaseSchema,
                onResetDatabase: onResetDatabase
            )
        }
    }
}

private struct ToolbarDebugSettings: View {
    @Binding var isInfoButtonEnabled: Bool

    var body: some View {
        SettingsSectionCard(
            "Toolbar",
            footer: "Shows the diagnostic popover for current search, import, database, and enrichment status."
        ) {
            SettingsToggleRow("Show toolbar info button", isOn: $isInfoButtonEnabled, showsDivider: false)
        }
    }
}

private struct PostContextDebugSettings: View {
    @Binding var areDiagnosticActionsEnabled: Bool
    @Binding var isTemporaryHideActionEnabled: Bool

    var body: some View {
        SettingsSectionCard(
            "Post Context Menu",
            footer: "The temporary hide action only removes a post from the current window. Hidden posts return when the window or app is reopened."
        ) {
            SettingsToggleRow("Show post debug context actions", isOn: $areDiagnosticActionsEnabled)
            SettingsToggleRow(
                "Show temporary hide-post action",
                isOn: $isTemporaryHideActionEnabled,
                showsDivider: false
            )
        }
    }
}

private struct DatabaseMaintenanceSettings: View {
    let importState: ImportState
    let onRebuildDatabaseSchema: () -> Void
    let onResetDatabase: () -> Void

    @State private var isConfirmingSchemaRebuild = false
    @State private var isConfirmingDatabaseReset = false
    @State private var showsMaintenanceStatus = false

    var body: some View {
        SettingsSectionCard(
            "Database Maintenance",
            footer: "These tools operate on Xray's local SQLite database. Downloaded models and app settings are not affected."
        ) {
            DatabaseMaintenanceRow(
                title: "Rebuild Database Schema",
                description: "Creates a temporary backup, rebuilds the database using the current schema, and restores your posts. Use this to repair schema or migration problems without intentionally erasing your library.",
                buttonTitle: "Rebuild…",
                systemImage: "arrow.triangle.2.circlepath",
                isDisabled: importState.isDatabaseImporting,
                action: { isConfirmingSchemaRebuild = true }
            )

            Divider()
                .padding(.vertical, 8)

            DatabaseMaintenanceRow(
                title: "Reset Database",
                description: "Permanently deletes all imported posts, topics, and stored embeddings, then creates a new empty database. Use this only when you want to start over.",
                buttonTitle: "Reset…",
                systemImage: "trash",
                role: .destructive,
                isDisabled: importState.isDatabaseImporting,
                action: { isConfirmingDatabaseReset = true }
            )

            if showsMaintenanceStatus {
                Divider()
                    .padding(.vertical, 8)

                DatabaseMaintenanceStatus(importState: importState)
            }
        }
        .confirmationDialog(
            "Rebuild the database schema?",
            isPresented: $isConfirmingSchemaRebuild
        ) {
            Button("Rebuild Database Schema") {
                showsMaintenanceStatus = true
                onRebuildDatabaseSchema()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Xray will back up the current database, recreate its schema, and restore your posts. Keep Xray open until the rebuild finishes.")
        }
        .confirmationDialog(
            "Reset the database?",
            isPresented: $isConfirmingDatabaseReset
        ) {
            Button("Reset Database", role: .destructive) {
                showsMaintenanceStatus = true
                onResetDatabase()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every imported post, topic, and stored embedding. This action cannot be undone.")
        }
    }
}

private struct DatabaseMaintenanceRow: View {
    let title: LocalizedStringResource
    let description: LocalizedStringResource
    let buttonTitle: LocalizedStringResource
    let systemImage: String
    var role: ButtonRole?
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .foregroundStyle(role == .destructive ? Color.red : Color.secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(buttonTitle, role: role, action: action)
                .buttonStyle(.bordered)
                .disabled(isDisabled)
                .pointingHandOnHover()
        }
        .padding(.vertical, 6)
    }
}

private struct DatabaseMaintenanceStatus: View {
    let importState: ImportState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if importState.isDatabaseImporting {
                ProgressView(value: importState.databaseImportProgress)
            }

            if let error = importState.databaseImportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if !importState.databaseImportStatus.isEmpty {
                Label(
                    importState.databaseImportStatus,
                    systemImage: importState.isDatabaseImporting ? "clock" : "checkmark.circle.fill"
                )
                .foregroundStyle(importState.isDatabaseImporting ? Color.secondary : Color.green)
            }
        }
        .font(.footnote)
    }
}
