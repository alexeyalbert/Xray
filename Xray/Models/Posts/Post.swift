import Foundation

nonisolated struct Post: Codable, CustomStringConvertible, Sendable {
    let id: Int
    let created_at: Date
    let full_text: String
    let media: [Media]?
    let article: Article?
    let links: [PostLink]
    let quoted_post: QuotedPost?
    let screen_name: String
    let name: String
    let profile_image_url: URL
    let profile_image_shape: ProfileImageShape
    let url: URL
    let text_embedding: [Float]
    let img_embedding: [Float]
    let primary_topic: String
    let secondary_topics: [String]
    let bookmark_import_generation: Int64?
    let bookmark_order: Int?

    /// Every image URL rendered as feed-card thumbnail content. Used to prune
    /// decoded images without touching the disk cache when a card moves away.
    var thumbnailCacheURLs: [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []

        func append(_ url: URL?) {
            guard let url, seen.insert(url).inserted else { return }
            urls.append(url)
        }

        media?.forEach { append($0.thumbnail) }
        article?.allMedia.forEach { append($0.thumbnail) }
        quoted_post?.media?.forEach { append($0.thumbnail) }
        links.forEach { append($0.card?.image_url) }
        return urls
    }
    
    init(id: Int,
         created_at: Date,
         full_text: String,
         media: [Media]?,
         article: Article? = nil,
         links: [PostLink] = [],
         quoted_post: QuotedPost? = nil,
         screen_name: String,
         name: String,
         profile_image_url: URL,
         profile_image_shape: ProfileImageShape = .circle,
         url: URL,
         text_embedding: [Float],
         img_embedding: [Float],
         primary_topic: String,
         secondary_topics: [String],
         bookmark_import_generation: Int64? = nil,
         bookmark_order: Int? = nil) {
        self.id = id
        self.created_at = created_at
        self.full_text = full_text.decodedHTMLText
        self.media = media
        self.article = article
        self.links = links
        self.quoted_post = quoted_post
        self.screen_name = screen_name
        self.name = name
        self.profile_image_url = upgradedTwitterProfileImageURL(profile_image_url)
        self.profile_image_shape = profile_image_shape
        self.url = url
        self.text_embedding = text_embedding
        self.img_embedding = img_embedding
        self.primary_topic = primary_topic
        self.secondary_topics = secondary_topics
        self.bookmark_import_generation = bookmark_import_generation
        self.bookmark_order = bookmark_order
    }
    
    enum CodingKeys: String, CodingKey {
        case id, created_at, full_text, media, article, links, quoted_post, screen_name, name, profile_image_url, profile_image_shape
        case url
        case embedding, text_embedding, img_embedding, primary_topic, secondary_topics
        case bookmark_import_generation, bookmark_order
        case metadata
    }

    private enum MetadataKeys: String, CodingKey {
        case core
        case article
        case card
        case legacy
        case quoted_status_result
    }

    private enum ArticleWrapperKeys: String, CodingKey {
        case article_results
    }

    private enum ArticleResultsKeys: String, CodingKey {
        case result
    }

    private enum ResultWrapperKeys: String, CodingKey {
        case result
    }

    private enum TweetResultKeys: String, CodingKey {
        case rest_id, core, legacy
    }

    private enum CoreKeys: String, CodingKey {
        case user_results
    }

    private enum UserResultsKeys: String, CodingKey {
        case result
    }

    private enum UserResultKeys: String, CodingKey {
        case core, avatar, professional, verification, profile_image_shape
    }

    private enum UserCoreKeys: String, CodingKey {
        case name, screen_name
    }

    private enum AvatarKeys: String, CodingKey {
        case image_url
    }

    private enum ProfessionalKeys: String, CodingKey {
        case professional_type
    }

    private enum VerificationKeys: String, CodingKey {
        case verified_type
    }

    private enum LegacyKeys: String, CodingKey {
        case created_at, full_text, entities, extended_entities
    }

    private enum EntitiesKeys: String, CodingKey {
        case media, urls
    }

    private enum CardKeys: String, CodingKey {
        case legacy
    }

    private enum CardLegacyKeys: String, CodingKey {
        case binding_values, url
    }

    private enum TwitterMediaKeys: String, CodingKey {
        case type, media_url_https
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try Post.decodeCanonicalID(from: container, idKey: .id, urlKey: .url)
        self.created_at = try container.decode(Date.self, forKey: .created_at)
        let originalFullText = (try? container.decode(String.self, forKey: .full_text)) ?? ""
        let article = (try? container.decode(Article.self, forKey: .article)) ?? Post.decodeArticle(from: container)
        let links = (try? container.decode([PostLink].self, forKey: .links)) ?? Post.decodeLinks(from: container)
        let cleanedFullText = Post.cleanText(originalFullText, links: links)
        self.full_text = cleanedFullText.isEmpty ? (article?.searchableText ?? "") : cleanedFullText
        self.media = try? container.decode([Media].self, forKey: .media)
        self.article = article
        self.links = links
        self.quoted_post = (try? container.decode(QuotedPost.self, forKey: .quoted_post)) ?? Post.decodeQuotedPost(from: container)
        self.screen_name = try container.decode(String.self, forKey: .screen_name)
        self.name = try container.decode(String.self, forKey: .name)
        self.profile_image_url = upgradedTwitterProfileImageURL(try container.decode(URL.self, forKey: .profile_image_url))
        self.profile_image_shape = (try? container.decode(ProfileImageShape.self, forKey: .profile_image_shape))
            ?? Post.decodeProfileImageShape(from: container)
            ?? .circle
        self.url = try container.decode(URL.self, forKey: .url)
        self.text_embedding = (try? container.decode([Float].self, forKey: .text_embedding))
            ?? (try? container.decode([Float].self, forKey: .embedding))
            ?? []
        self.img_embedding = (try? container.decode([Float].self, forKey: .img_embedding)) ?? []
        self.primary_topic = (try? container.decode(String.self, forKey: .primary_topic)) ?? ""
        self.secondary_topics = (try? container.decode([String].self, forKey: .secondary_topics)) ?? []
        self.bookmark_import_generation = try? container.decode(Int64.self, forKey: .bookmark_import_generation)
        self.bookmark_order = try? container.decode(Int.self, forKey: .bookmark_order)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(created_at, forKey: .created_at)
        try container.encode(full_text, forKey: .full_text)
        try container.encodeIfPresent(media, forKey: .media)
        try container.encodeIfPresent(article, forKey: .article)
        if !links.isEmpty {
            try container.encode(links, forKey: .links)
        }
        try container.encodeIfPresent(quoted_post, forKey: .quoted_post)
        try container.encode(screen_name, forKey: .screen_name)
        try container.encode(name, forKey: .name)
        try container.encode(profile_image_url, forKey: .profile_image_url)
        try container.encode(profile_image_shape, forKey: .profile_image_shape)
        try container.encode(url, forKey: .url)
        try container.encode(text_embedding, forKey: .text_embedding)
        try container.encode(img_embedding, forKey: .img_embedding)
        try container.encode(primary_topic, forKey: .primary_topic)
        try container.encode(secondary_topics, forKey: .secondary_topics)
        try container.encodeIfPresent(bookmark_import_generation, forKey: .bookmark_import_generation)
        try container.encodeIfPresent(bookmark_order, forKey: .bookmark_order)
    }

    var analysisText: String {
        var sections: [String] = []

        if let displayText {
            sections.append(displayText)
        }

        if let articleText = article?.searchableText.trimmingCharacters(in: .whitespacesAndNewlines),
           !articleText.isEmpty {
            sections.append("Article by @\(screen_name): \(articleText)")
        }

        let linkText = links.compactMap { link -> String? in
            let card = link.card
            let pieces = [
                card?.title,
                card?.description,
                card?.domain ?? link.display_url,
                link.expanded_url?.absoluteString ?? link.url.absoluteString
            ]
            let text = pieces
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
        if !linkText.isEmpty {
            sections.append(linkText)
        }

        if let quoted = quoted_post {
            sections.append("Quoted post by @\(quoted.screen_name): \(quoted.full_text)")
        }

        return sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var analysisMedia: [Media]? {
        var seen = Set<URL>()
        let combined = (media ?? []) + (article?.allMedia ?? []) + (quoted_post?.media ?? [])
        let deduped = combined.filter { seen.insert($0.original).inserted }
        return deduped.isEmpty ? nil : deduped
    }

    var displayText: String? {
        let trimmed = full_text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let articleText = article?.searchableText.trimmingCharacters(in: .whitespacesAndNewlines),
           !articleText.isEmpty,
           trimmed == articleText {
            return nil
        }
        return trimmed
    }

    private static func cleanText(_ text: String, links: [PostLink] = []) -> String {
        var decoded = text.decodedHTMLText
        for link in links where !(link.card?.hasPreviewContent ?? false) {
            decoded = decoded.replacingOccurrences(
                of: link.url.absoluteString,
                with: link.displayName
            )
        }

        return decoded
            .replacingOccurrences(of: "\\S*t\\.co\\S*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeLinks(from container: KeyedDecodingContainer<CodingKeys>) -> [PostLink] {
        let card = decodeLinkCard(from: container)
        var links: [PostLink] = []

        if
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata),
            let legacy = try? metadata.nestedContainer(keyedBy: LegacyKeys.self, forKey: .legacy),
            let entities = try? legacy.nestedContainer(keyedBy: EntitiesKeys.self, forKey: .entities),
            let urlEntities = try? entities.decode([TwitterURLEntity].self, forKey: .urls)
        {
            links = urlEntities.compactMap { entity in
                guard let url = URL(string: entity.url) else { return nil }
                let expanded = entity.expanded_url.flatMap(URL.init(string:))
                return PostLink(url: url, expanded_url: expanded, display_url: entity.display_url, card: card)
            }
        }

        if
            links.isEmpty,
            let card,
            let cardURL = decodeCardURL(from: container)
        {
            links = [PostLink(url: cardURL, expanded_url: nil, display_url: card.vanity_url ?? card.domain, card: card)]
        }

        var seen = Set<String>()
        return links.filter { seen.insert($0.id).inserted }
    }

    private static func decodeCardURL(from container: KeyedDecodingContainer<CodingKeys>) -> URL? {
        guard
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata),
            let card = try? metadata.nestedContainer(keyedBy: CardKeys.self, forKey: .card),
            let legacy = try? card.nestedContainer(keyedBy: CardLegacyKeys.self, forKey: .legacy),
            let rawURL = try? legacy.decode(String.self, forKey: .url)
        else {
            return nil
        }
        return URL(string: rawURL)
    }

    private static func decodeLinkCard(from container: KeyedDecodingContainer<CodingKeys>) -> LinkCard? {
        guard
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata),
            let cardContainer = try? metadata.nestedContainer(keyedBy: CardKeys.self, forKey: .card),
            let legacy = try? cardContainer.nestedContainer(keyedBy: CardLegacyKeys.self, forKey: .legacy),
            let bindings = try? legacy.decode([CardBinding].self, forKey: .binding_values)
        else {
            return nil
        }

        var strings: [String: String] = [:]
        var images: [String: CardImageValue] = [:]
        for binding in bindings {
            if
                let value = binding.value.string_value?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            {
                strings[binding.key] = value
            }
            if let image = binding.value.image_value {
                images[binding.key] = image
            }
        }
        let preferredImage = images["summary_photo_image_large"]
            ?? images["photo_image_full_size_large"]
            ?? images["summary_photo_image"]
            ?? images["photo_image_full_size"]
            ?? images["thumbnail_image_large"]
            ?? images["thumbnail_image"]
            ?? images["summary_photo_image_original"]
            ?? images["photo_image_full_size_original"]

        let linkCard = LinkCard(
            title: strings["title"],
            description: strings["description"],
            domain: strings["domain"],
            vanity_url: strings["vanity_url"],
            image_url: preferredImage?.url,
            image_alt: strings["summary_photo_image_alt_text"] ?? strings["photo_image_full_size_alt_text"] ?? preferredImage?.alt,
            image_width: preferredImage?.width,
            image_height: preferredImage?.height
        )
        return linkCard.hasPreviewContent ? linkCard : nil
    }

    private struct TwitterURLEntity: Decodable {
        let url: String
        let expanded_url: String?
        let display_url: String?
    }

    private struct CardBinding: Decodable {
        let key: String
        let value: CardBindingValue
    }

    private struct CardBindingValue: Decodable {
        let string_value: String?
        let image_value: CardImageValue?
    }

    private struct CardImageValue: Decodable {
        let alt: String?
        let height: Double?
        let url: URL?
        let width: Double?
    }

    static func decodeID<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> Int {
        if let idInt = try? container.decode(Int.self, forKey: key) {
            return idInt
        }

        if let idString = try? container.decode(String.self, forKey: key), let idInt = Int(idString) {
            return idInt
        }

        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "ID was not an int or string convertible to int"
        )
    }

    static func decodeCanonicalID<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        idKey: K,
        urlKey: K
    ) throws -> Int {
        if
            let url = try? container.decode(URL.self, forKey: urlKey),
            let idFromURL = decodeStatusID(from: url)
        {
            return idFromURL
        }

        return try decodeID(from: container, forKey: idKey)
    }

    private static func decodeStatusID(from url: URL) -> Int? {
        let components = url.pathComponents
        guard let statusIndex = components.lastIndex(of: "status"), statusIndex + 1 < components.count else {
            return nil
        }

        return Int(components[statusIndex + 1])
    }

    private static func decodeArticle(from container: KeyedDecodingContainer<CodingKeys>) -> Article? {
        guard
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata),
            let articleWrapper = try? metadata.nestedContainer(keyedBy: ArticleWrapperKeys.self, forKey: .article),
            let articleResults = try? articleWrapper.nestedContainer(keyedBy: ArticleResultsKeys.self, forKey: .article_results)
        else {
            return nil
        }

        return try? articleResults.decode(Article.self, forKey: .result)
    }

    private static func decodeQuotedPost(from container: KeyedDecodingContainer<CodingKeys>) -> QuotedPost? {
        guard
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata),
            let quotedWrapper = try? metadata.nestedContainer(keyedBy: ResultWrapperKeys.self, forKey: .quoted_status_result),
            let quoted = try? quotedWrapper.nestedContainer(keyedBy: TweetResultKeys.self, forKey: .result),
            let idString = try? quoted.decode(String.self, forKey: .rest_id),
            let id = Int(idString),
            let legacy = try? quoted.nestedContainer(keyedBy: LegacyKeys.self, forKey: .legacy),
            let rawText = try? legacy.decode(String.self, forKey: .full_text),
            let core = try? quoted.nestedContainer(keyedBy: CoreKeys.self, forKey: .core),
            let userResults = try? core.nestedContainer(keyedBy: UserResultsKeys.self, forKey: .user_results),
            let user = try? userResults.nestedContainer(keyedBy: UserResultKeys.self, forKey: .result),
            let userCore = try? user.nestedContainer(keyedBy: UserCoreKeys.self, forKey: .core),
            let name = try? userCore.decode(String.self, forKey: .name),
            let screenName = try? userCore.decode(String.self, forKey: .screen_name),
            let avatar = try? user.nestedContainer(keyedBy: AvatarKeys.self, forKey: .avatar),
            let profileImageURL = try? avatar.decode(URL.self, forKey: .image_url)
        else {
            return nil
        }

        let media = decodeTwitterMedia(from: legacy)
        let createdAt = decodeTwitterDate((try? legacy.decode(String.self, forKey: .created_at)) ?? "")
        let url = URL(string: "https://twitter.com/\(screenName)/status/\(idString)") ?? URL(string: "https://invalid.local/")!
        return QuotedPost(
            id: id,
            created_at: createdAt,
            full_text: cleanText(rawText),
            media: media,
            screen_name: screenName,
            name: name,
            profile_image_url: upgradedTwitterProfileImageURL(profileImageURL),
            profile_image_shape: decodeProfileImageShape(from: user) ?? .circle,
            url: url
        )
    }

    private static func decodeProfileImageShape(from container: KeyedDecodingContainer<CodingKeys>) -> ProfileImageShape? {
        guard
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .metadata),
            let coreWrapper = try? metadata.nestedContainer(keyedBy: CoreKeys.self, forKey: .core),
            let userResults = try? coreWrapper.nestedContainer(keyedBy: UserResultsKeys.self, forKey: .user_results),
            let user = try? userResults.nestedContainer(keyedBy: UserResultKeys.self, forKey: .result)
        else {
            return nil
        }

        return decodeProfileImageShape(from: user)
    }

    private static func decodeProfileImageShape(from user: KeyedDecodingContainer<UserResultKeys>) -> ProfileImageShape? {
        if let explicitShape = try? user.decode(ProfileImageShape.self, forKey: .profile_image_shape) {
            return explicitShape
        }

        let professionalType = (try? user
            .nestedContainer(keyedBy: ProfessionalKeys.self, forKey: .professional)
            .decode(String.self, forKey: .professional_type))?
            .lowercased()
        if professionalType == "business" {
            return .square
        }

        let verifiedType = (try? user
            .nestedContainer(keyedBy: VerificationKeys.self, forKey: .verification)
            .decode(String.self, forKey: .verified_type))?
            .lowercased()
        if verifiedType == "business" {
            return .square
        }

        return nil
    }

    private static func decodeTwitterDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: value)
    }

    private static func decodeTwitterMedia(from legacy: KeyedDecodingContainer<LegacyKeys>) -> [Media]? {
        let mediaItems: [TwitterMedia]
        if
            let extended = try? legacy.nestedContainer(keyedBy: EntitiesKeys.self, forKey: .extended_entities),
            let extendedMedia = try? extended.decode([TwitterMedia].self, forKey: .media) {
            mediaItems = extendedMedia
        } else if
            let entities = try? legacy.nestedContainer(keyedBy: EntitiesKeys.self, forKey: .entities),
            let entityMedia = try? entities.decode([TwitterMedia].self, forKey: .media) {
            mediaItems = entityMedia
        } else {
            return nil
        }

        let converted = mediaItems.compactMap { $0.asMedia }
        return converted.isEmpty ? nil : converted
    }

    private struct TwitterMedia: Decodable {
        let type: String
        let media_url_https: URL
        let sizes: Sizes?
        let video_info: VideoInfo?

        var asMedia: Media? {
            let absolute = media_url_https.absoluteString
            let questionIndex = absolute.firstIndex(of: "?") ?? absolute.endIndex
            let path = String(absolute[..<questionIndex])
            let url = URL(string: path) ?? media_url_https
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let base = path.dropLast(url.pathExtension.isEmpty ? 0 : ext.count + 1)

            let thumbnail = URL(string: "\(base)?format=\(ext)&name=small") ?? media_url_https

            if type.lowercased().contains("video") || type.lowercased().contains("animated_gif") {
                guard let videoURL = video_info?.bestMP4VariantURL else {
                    return Media(type: type, thumbnail: thumbnail, original: media_url_https, width: displaySize?.w, height: displaySize?.h)
                }
                return Media(type: type, thumbnail: thumbnail, original: videoURL, width: displaySize?.w, height: displaySize?.h)
            }

            guard
                let original = URL(string: "\(base)?format=\(ext)&name=orig")
            else {
                return nil
            }
            return Media(type: type, thumbnail: thumbnail, original: original, width: displaySize?.w, height: displaySize?.h)
        }

        private var displaySize: Size? {
            sizes?.large ?? sizes?.medium ?? sizes?.small ?? sizes?.thumb
        }

        struct Sizes: Decodable {
            let large: Size?
            let medium: Size?
            let small: Size?
            let thumb: Size?
        }

        struct Size: Decodable {
            let w: Double
            let h: Double
        }

        struct VideoInfo: Decodable {
            let variants: [Variant]

            var bestMP4VariantURL: URL? {
                variants
                    .filter { $0.content_type == "video/mp4" }
                    .sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
                    .first?
                    .url
            }
        }

        struct Variant: Decodable {
            let bitrate: Int?
            let content_type: String
            let url: URL
        }
    }
    
    var description: String {
        """
        Post(
            id: \(id),
            created_at: \(created_at),
            full_text: \(full_text),
            media: \(media, default: ""),
            article: \(String(describing: article?.title)),
            screen_name: \(screen_name),
            name: \(name), 
            profile_image_url: \(profile_image_url),
            profile_image_shape: \(profile_image_shape.rawValue),
            url: \(url),
            text_embedding: \(text_embedding),
            img_embedding: \(img_embedding),
            primary_topic: \(primary_topic),
            secondary_topics: \(secondary_topics)
        )
        """
    }
}
