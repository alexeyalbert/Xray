import Foundation

nonisolated struct PostLink: Codable, Identifiable, Sendable {
    let url: URL
    let expanded_url: URL?
    let display_url: String?
    let card: LinkCard?

    private enum CodingKeys: String, CodingKey {
        case url, expanded_url, display_url, card
    }

    init(url: URL, expanded_url: URL? = nil, display_url: String? = nil, card: LinkCard? = nil) {
        self.url = url
        self.expanded_url = expanded_url
        self.display_url = display_url?.decodedHTMLText
        self.card = card
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        expanded_url = try container.decodeIfPresent(URL.self, forKey: .expanded_url)
        display_url = try container.decodeIfPresent(String.self, forKey: .display_url)?.decodedHTMLText
        card = try container.decodeIfPresent(LinkCard.self, forKey: .card)
    }

    var id: String {
        (expanded_url ?? url).absoluteString
    }

    var destination: URL {
        expanded_url ?? url
    }

    var displayName: String {
        if let domain = card?.domain, !domain.isEmpty {
            return domain
        }
        if let display_url, !display_url.isEmpty {
            return display_url
        }
        return destination.host ?? destination.absoluteString
    }

    func pointsToQuotedPost(_ quotedPost: QuotedPost) -> Bool {
        if destination == quotedPost.url {
            return true
        }

        guard let host = destination.host?.lowercased(),
              host == "x.com" || host == "www.x.com" ||
              host == "twitter.com" || host == "www.twitter.com" ||
              host == "mobile.twitter.com" else {
            return false
        }

        let pathComponents = destination.pathComponents
        guard let statusIndex = pathComponents.lastIndex(of: "status"),
              pathComponents.indices.contains(statusIndex + 1) else {
            return false
        }

        return pathComponents[statusIndex + 1] == String(quotedPost.id)
    }
}
