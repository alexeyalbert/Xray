import Foundation

nonisolated struct QuotedPost: Codable, Sendable {
    let id: Int
    let created_at: Date?
    let full_text: String
    let media: [Media]?
    let screen_name: String
    let name: String
    let profile_image_url: URL
    let profile_image_shape: ProfileImageShape
    let url: URL

    enum CodingKeys: String, CodingKey {
        case id, created_at, full_text, media, screen_name, name, profile_image_url, profile_image_shape, url
    }

    init(id: Int,
         created_at: Date?,
         full_text: String,
         media: [Media]?,
         screen_name: String,
         name: String,
         profile_image_url: URL,
         profile_image_shape: ProfileImageShape = .circle,
         url: URL) {
        self.id = id
        self.created_at = created_at
        self.full_text = full_text.decodedHTMLText
        self.media = media
        self.screen_name = screen_name
        self.name = name
        self.profile_image_url = upgradedTwitterProfileImageURL(profile_image_url)
        self.profile_image_shape = profile_image_shape
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Post.decodeCanonicalID(from: container, idKey: .id, urlKey: .url)
        created_at = try container.decodeIfPresent(Date.self, forKey: .created_at)
        full_text = try container.decode(String.self, forKey: .full_text).decodedHTMLText
        media = try container.decodeIfPresent([Media].self, forKey: .media)
        screen_name = try container.decode(String.self, forKey: .screen_name)
        name = try container.decode(String.self, forKey: .name)
        profile_image_url = upgradedTwitterProfileImageURL(try container.decode(URL.self, forKey: .profile_image_url))
        profile_image_shape = try container.decodeIfPresent(ProfileImageShape.self, forKey: .profile_image_shape) ?? .circle
        url = try container.decode(URL.self, forKey: .url)
    }
}
