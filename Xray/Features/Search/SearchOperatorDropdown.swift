import SwiftUI

/// A custom dropdown "apron" that appears below the search field when it is
/// focused, offering an intuitive way to discover and insert search operators.
struct SearchOperatorDropdown: View {
    @Binding var searchText: String
    @Binding var selection: TextSelection?
    let searchMode: SearchMode
    /// Called after an operator is inserted so the caller can re-focus the field.
    var onInsert: () -> Void

    @AppStorage(SQLiteManager.minimumEmbeddingSimilarityDefaultsKey)
    private var minimumEmbeddingSimilarity = SQLiteManager.defaultMinimumEmbeddingSimilarity
    @AppStorage(SQLiteManager.minimumImageEmbeddingSimilarityDefaultsKey)
    private var minimumImageEmbeddingSimilarity = SQLiteManager.defaultMinimumImageEmbeddingSimilarity

    private var currentToken: String {
        guard let last = searchText.split(separator: " ", omittingEmptySubsequences: false).last else {
            return ""
        }
        return String(last)
    }

    private var highlightedOperatorID: String? {
        SearchOperatorCatalog.matchingOperator(for: currentToken)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchOperatorList(
                highlightedOperatorID: highlightedOperatorID,
                onSelect: apply
            )

            SearchSimilaritySettingsFooter(
                minimumEmbeddingSimilarity: $minimumEmbeddingSimilarity,
                minimumImageEmbeddingSimilarity: $minimumImageEmbeddingSimilarity
            )
        }
        .frame(width: 460)
        .shadow(radius: 18, y: 10)
    }

    private func apply(_ searchOperator: SearchOperator) {
        var text = searchText
        let trailing = currentToken

        let canReplaceTrailing = !trailing.isEmpty && (
            searchOperator.insert.lowercased().hasPrefix(trailing.lowercased())
            || searchOperator.token.lowercased().hasPrefix(trailing.lowercased())
        )

        if canReplaceTrailing {
            text.removeLast(trailing.count)
            text += searchOperator.insert
        } else {
            if !text.isEmpty && !text.hasSuffix(" ") {
                text += " "
            }
            text += searchOperator.insert
        }

        searchText = text
        onInsert()

        // The inserted token always ends at the end of the string, so place
        // the caret relative to the end (for example, between paired quotes).
        let caretOffset = max(0, searchOperator.caretFromEnd)
        let finalText = text
        DispatchQueue.main.async {
            guard caretOffset <= finalText.count else {
                selection = TextSelection(insertionPoint: finalText.endIndex)
                return
            }
            let caretIndex = finalText.index(finalText.endIndex, offsetBy: -caretOffset)
            selection = TextSelection(insertionPoint: caretIndex)
        }
    }
}

#Preview("Search Operator Dropdown") {
    @Previewable @State var searchText = "emb:graphic design"
    @Previewable @State var selection: TextSelection? = nil

    ZStack(alignment: .top) {
        Rectangle()
            .fill(.thinMaterial)
            .ignoresSafeArea()

        SearchOperatorDropdown(
            searchText: $searchText,
            selection: $selection,
            searchMode: .hybrid,
            onInsert: {}
        )
        .padding(.top, 24)
    }
    .frame(width: 900, height: 700)
}
