import SwiftUI

struct BrowserImportSettingsPane: View {
    @Binding var preferredPortText: String
    @Binding var preferredPortFeedback: String
    let onSavePreferredPort: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(
                "Receiver Preferences",
                footer: "Leave the port blank to let Xray choose an available localhost port automatically."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferred Port")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 10) {
                        TextField("49152-65535", text: $preferredPortText)
                            .textFieldStyle(.roundedBorder)

                        Button("Save", action: onSavePreferredPort)
                            .buttonStyle(.borderedProminent)
                    }

                    if !preferredPortFeedback.isEmpty {
                        Text(preferredPortFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                SettingsValueRow(
                    title: "Security Token",
                    value: "Generated automatically and stored in Keychain",
                    systemImage: "lock.shield"
                )
            }
        }
    }
}
