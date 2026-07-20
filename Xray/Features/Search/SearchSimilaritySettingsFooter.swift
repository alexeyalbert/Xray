import SwiftUI

struct SearchSimilaritySettingsFooter: View {
    @Binding var minimumEmbeddingSimilarity: Double
    @Binding var minimumImageEmbeddingSimilarity: Double

    var body: some View {
        VStack(alignment: .leading) {
            SimilarityThresholdControl(
                title: "Embedding Similarity Threshold",
                value: $minimumEmbeddingSimilarity,
                defaultValue: SQLiteManager.defaultMinimumEmbeddingSimilarity,
                resetHelp: "Reset Embedding Similarity",
                detail: "A higher threshold will keep only closer semantic matches"
            )

            Divider()
                .padding(.vertical, 2)

            SimilarityThresholdControl(
                title: "Image Similarity Threshold",
                value: $minimumImageEmbeddingSimilarity,
                defaultValue: SQLiteManager.defaultMinimumImageEmbeddingSimilarity,
                resetHelp: "Reset Image Similarity",
                detail: "Controls text-to-image matches from the vision model"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SimilarityThresholdControl: View {
    let title: LocalizedStringResource
    @Binding var value: Double
    let defaultValue: Double
    let resetHelp: LocalizedStringResource
    let detail: LocalizedStringResource

    @State private var isResetHovering = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isResetHovering ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(resetHelp))
                .onHover { isResetHovering = $0 }
            }

            TicklessSimilaritySlider(value: $value)
                .frame(height: 16)

            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
        }
    }
}
