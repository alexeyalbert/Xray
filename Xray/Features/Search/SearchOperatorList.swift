import SwiftUI

struct SearchOperatorList: View {
    let highlightedOperatorID: String?
    let onSelect: (SearchOperator) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(SearchOperatorCatalog.all) { searchOperator in
                        SearchOperatorRow(
                            searchOperator: searchOperator,
                            isSuggested: highlightedOperatorID == searchOperator.id,
                            action: { onSelect(searchOperator) }
                        )
                        .id(searchOperator.id)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToHighlightedOperator(with: proxy)
            }
            .onChange(of: highlightedOperatorID) { _, _ in
                scrollToHighlightedOperator(with: proxy)
            }
        }
        .frame(maxHeight: 274)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func scrollToHighlightedOperator(with proxy: ScrollViewProxy) {
        guard let highlightedOperatorID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(highlightedOperatorID, anchor: .center)
        }
    }
}

private struct SearchOperatorRow: View {
    let searchOperator: SearchOperator
    let isSuggested: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var isHighlighted: Bool {
        isHovering || isSuggested
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(operatorPreview)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .lineLimit(1)
                    .frame(width: 55, alignment: .center)

                HStack(spacing: 8) {
                    Text(searchOperator.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(searchOperator.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(NSColor.secondaryLabelColor))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 5)
            .frame(height: 30)
            .background(
                isHighlighted ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var operatorPreview: String {
        switch searchOperator.token {
        case "\"…\"":
            return "\"…\""
        default:
            return searchOperator.token
        }
    }
}
