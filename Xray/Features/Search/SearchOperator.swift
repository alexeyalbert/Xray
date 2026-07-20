import Foundation

struct SearchOperator: Identifiable {
    /// Text shown in the leading badge.
    let token: String
    /// Text actually inserted into the query.
    let insert: String
    let title: String
    let detail: String
    /// Whether the operator expects a value typed immediately after it.
    let expectsValue: Bool
    /// Number of characters from the end of the inserted text where the caret
    /// should land (0 = end). Used to drop the caret inside paired quotes.
    var caretFromEnd: Int = 0

    var id: String { token + title }
}

enum SearchOperatorCatalog {
    static let all: [SearchOperator] = [
        SearchOperator(token: "\"…\"", insert: "\"\"", title: "Exact phrase", detail: "Match the quoted text exactly.", expectsValue: true, caretFromEnd: 1),
        SearchOperator(token: "`…`", insert: "``", title: "Grouped search", detail: "Search multi-word phrases or group field values.", expectsValue: true, caretFromEnd: 1),
        SearchOperator(token: "&&", insert: " && ", title: "Boolean AND", detail: "Require both sides using normal search rules.", expectsValue: false),
        SearchOperator(token: "||", insert: " || ", title: "Boolean OR", detail: "Return results matching either side.", expectsValue: false),
        SearchOperator(token: "--", insert: "--", title: "Exclude term", detail: "Filter out a word, user, name, or topic.", expectsValue: true),
        SearchOperator(token: "id:", insert: "id:", title: "Post ID", detail: "Jump to one exact post ID.", expectsValue: true),
        SearchOperator(token: "user:", insert: "user:", title: "Username", detail: "Match an exact @username.", expectsValue: true),
        SearchOperator(token: "name:", insert: "name:", title: "Display name", detail: "Match text inside the display name.", expectsValue: true),
        SearchOperator(token: "topic:", insert: "topic:", title: "Any topic", detail: "Match primary or secondary topic exactly.", expectsValue: true),
        SearchOperator(token: "p_topic:", insert: "p_topic:", title: "Primary topic", detail: "Match the primary topic exactly.", expectsValue: true),
        SearchOperator(token: "s_topic:", insert: "s_topic:", title: "Secondary topic", detail: "Match a secondary topic exactly.", expectsValue: true),
        SearchOperator(token: "!NULL", insert: "!NULL", title: "Missing field", detail: "Find posts where a common field is empty.", expectsValue: false),
        SearchOperator(token: "emb:", insert: "emb:", title: "Embedding query", detail: "Steer semantic ranking with a separate idea.", expectsValue: true),
        SearchOperator(token: "--emb:", insert: "--emb:", title: "Exclude semantic", detail: "Drop posts similar to an idea.", expectsValue: true),
        SearchOperator(token: "img:", insert: "img:", title: "Image query", detail: "Steer visual ranking with a text description.", expectsValue: true),
        SearchOperator(token: "--img:", insert: "--img:", title: "Exclude visual", detail: "Drop posts with images similar to a description.", expectsValue: true),
    ]

    static func matchingOperator(for currentToken: String) -> SearchOperator? {
        let token = currentToken.lowercased()
        guard !token.isEmpty else { return nil }

        return all
            .filter { searchOperator in
                let insertToken = searchOperator.insert.trimmingCharacters(in: .whitespaces).lowercased()
                guard !insertToken.isEmpty else { return false }

                if insertToken.first?.isLetter == true {
                    return token.hasPrefix(insertToken)
                }

                return insertToken.hasPrefix(token) || token.hasPrefix(insertToken)
            }
            .max { lhs, rhs in
                let lhsToken = lhs.insert.trimmingCharacters(in: .whitespaces)
                let rhsToken = rhs.insert.trimmingCharacters(in: .whitespaces)
                return lhsToken.count < rhsToken.count
            }
    }
}

extension String {
    var looksLikeSearchOperator: Bool {
        SearchOperatorCatalog.matchingOperator(for: self) != nil
    }
}
