import SwiftUI

struct GeneralSettingsPane: View {
    @Binding var useRoundedMediaCorners: Bool
    @Binding var animateThumbnailAppearance: Bool
    @Binding var animateExpandedMediaAppearance: Bool
    @Binding var animateExpandedMediaResize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard("Media Viewer") {
                SettingsToggleRow("Use rounded corners for expanded media", isOn: $useRoundedMediaCorners)
                SettingsToggleRow("Animate media thumbnails as they appear", isOn: $animateThumbnailAppearance)
                SettingsToggleRow("Animate expanded media as it loads", isOn: $animateExpandedMediaAppearance)
                SettingsToggleRow(
                    "Smoothly resize expanded media to fit the window",
                    isOn: $animateExpandedMediaResize,
                    showsDivider: false
                )
            }
        }
    }
}
