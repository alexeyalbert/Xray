import Foundation

nonisolated struct LinkCard: Codable, Sendable {
    let title: String?
    let description: String?
    let domain: String?
    let vanity_url: String?
    let image_url: URL?
    let image_alt: String?
    let image_width: Double?
    let image_height: Double?

    private enum CodingKeys: String, CodingKey {
        case title, description, domain, vanity_url, image_url, image_alt, image_width, image_height
    }

    init(
        title: String? = nil,
        description: String? = nil,
        domain: String? = nil,
        vanity_url: String? = nil,
        image_url: URL? = nil,
        image_alt: String? = nil,
        image_width: Double? = nil,
        image_height: Double? = nil
    ) {
        self.title = title?.decodedHTMLText
        self.description = description?.decodedHTMLText
        self.domain = domain?.decodedHTMLText
        self.vanity_url = vanity_url?.decodedHTMLText
        self.image_url = image_url
        self.image_alt = image_alt?.decodedHTMLText
        self.image_width = image_width
        self.image_height = image_height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)?.decodedHTMLText
        description = try container.decodeIfPresent(String.self, forKey: .description)?.decodedHTMLText
        domain = try container.decodeIfPresent(String.self, forKey: .domain)?.decodedHTMLText
        vanity_url = try container.decodeIfPresent(String.self, forKey: .vanity_url)?.decodedHTMLText
        image_url = try container.decodeIfPresent(URL.self, forKey: .image_url)
        image_alt = try container.decodeIfPresent(String.self, forKey: .image_alt)?.decodedHTMLText
        image_width = try container.decodeIfPresent(Double.self, forKey: .image_width)
        image_height = try container.decodeIfPresent(Double.self, forKey: .image_height)
    }

    var hasPreviewContent: Bool {
        [title, description, domain, vanity_url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { !$0.isEmpty } || image_url != nil
    }
}
