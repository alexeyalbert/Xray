import Foundation

nonisolated struct Article: Codable, Sendable {
    let rest_id: String?
    let title: String
    let preview_text: String?
    let summary_text: String?
    let cover_media: MediaEntity?
    let media_entities: [MediaEntity]
    let content_state: ContentState?

    private enum CodingKeys: String, CodingKey {
        case rest_id, title, preview_text, summary_text, cover_media, media_entities, content_state
    }

    init(
        rest_id: String? = nil,
        title: String,
        preview_text: String? = nil,
        summary_text: String? = nil,
        cover_media: MediaEntity? = nil,
        media_entities: [MediaEntity] = [],
        content_state: ContentState? = nil
    ) {
        self.rest_id = rest_id
        self.title = title.decodedHTMLText
        self.preview_text = preview_text?.decodedHTMLText
        self.summary_text = summary_text?.decodedHTMLText
        self.cover_media = cover_media
        self.media_entities = media_entities
        self.content_state = content_state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rest_id = try container.decodeIfPresent(String.self, forKey: .rest_id)
        title = try container.decode(String.self, forKey: .title).decodedHTMLText
        preview_text = try container.decodeIfPresent(String.self, forKey: .preview_text)?.decodedHTMLText
        summary_text = try container.decodeIfPresent(String.self, forKey: .summary_text)?.decodedHTMLText
        cover_media = try container.decodeIfPresent(MediaEntity.self, forKey: .cover_media)
        media_entities = try container.decodeIfPresent([MediaEntity].self, forKey: .media_entities) ?? []
        content_state = try container.decodeIfPresent(ContentState.self, forKey: .content_state)
    }

    var searchableText: String {
        let body = bodyText
        return [title, body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var bodyText: String {
        if let blocks = content_state?.blocks, !blocks.isEmpty {
            let paragraphs = blocks.compactMap { block -> String? in
                guard block.type.lowercased() != "atomic" else { return nil }
                let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !paragraphs.isEmpty {
                return paragraphs.joined(separator: "\n\n")
            }
        }

        return preview_text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var allMedia: [Media] {
        var seen = Set<URL>()
        var items: [Media] = []

        if let cover = cover_media?.asMedia, seen.insert(cover.original).inserted {
            items.append(cover)
        }

        for entity in media_entities {
            guard let media = entity.asMedia, seen.insert(media.original).inserted else { continue }
            items.append(media)
        }

        return items
    }

    struct ContentState: Codable, Sendable {
        let blocks: [Block]
        let entityMap: [EntityMapEntry]
    }

    struct Block: Codable, Identifiable, Sendable {
        let key: String
        let text: String
        let type: String
        let data: BlockData?
        let entityRanges: [EntityRange]
        let inlineStyleRanges: [InlineStyleRange]

        var id: String { key }

        private enum CodingKeys: String, CodingKey {
            case key, text, type, data, entityRanges, inlineStyleRanges
        }

        init(
            key: String,
            text: String,
            type: String,
            data: BlockData? = nil,
            entityRanges: [EntityRange] = [],
            inlineStyleRanges: [InlineStyleRange] = []
        ) {
            self.key = key
            self.text = text.decodedHTMLText
            self.type = type
            self.data = data
            self.entityRanges = entityRanges
            self.inlineStyleRanges = inlineStyleRanges
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            text = try container.decode(String.self, forKey: .text).decodedHTMLText
            type = try container.decode(String.self, forKey: .type)
            data = try container.decodeIfPresent(BlockData.self, forKey: .data)
            entityRanges = try container.decodeIfPresent([EntityRange].self, forKey: .entityRanges) ?? []
            inlineStyleRanges = try container.decodeIfPresent([InlineStyleRange].self, forKey: .inlineStyleRanges) ?? []
        }
    }

    struct BlockData: Codable, Sendable {
        let mentions: [Mention]?
    }

    struct Mention: Codable, Sendable {
        let fromIndex: Int?
        let toIndex: Int?
        let text: String?

        private enum CodingKeys: String, CodingKey {
            case fromIndex, toIndex, text
        }

        init(fromIndex: Int? = nil, toIndex: Int? = nil, text: String? = nil) {
            self.fromIndex = fromIndex
            self.toIndex = toIndex
            self.text = text?.decodedHTMLText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fromIndex = try container.decodeIfPresent(Int.self, forKey: .fromIndex)
            toIndex = try container.decodeIfPresent(Int.self, forKey: .toIndex)
            text = try container.decodeIfPresent(String.self, forKey: .text)?.decodedHTMLText
        }
    }

    struct EntityRange: Codable, Sendable {
        let key: Int
        let offset: Int
        let length: Int
    }

    struct InlineStyleRange: Codable, Sendable {
        let offset: Int
        let length: Int
        let style: String
    }

    struct EntityMapEntry: Codable, Sendable, Identifiable {
        let key: String
        let value: EntityValue

        var id: String { key }
    }

    struct EntityValue: Codable, Sendable {
        let type: String
        let data: EntityData
    }

    struct EntityData: Codable, Sendable {
        let url: URL?
        let caption: String?
        let mediaItems: [EntityMediaItem]?
        let tweetId: String?

        private enum CodingKeys: String, CodingKey {
            case url, caption, mediaItems, tweetId
        }

        init(url: URL? = nil, caption: String? = nil, mediaItems: [EntityMediaItem]? = nil, tweetId: String? = nil) {
            self.url = url
            self.caption = caption?.decodedHTMLText
            self.mediaItems = mediaItems
            self.tweetId = tweetId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decodeIfPresent(URL.self, forKey: .url)
            caption = try container.decodeIfPresent(String.self, forKey: .caption)?.decodedHTMLText
            mediaItems = try container.decodeIfPresent([EntityMediaItem].self, forKey: .mediaItems)
            tweetId = try container.decodeIfPresent(String.self, forKey: .tweetId)
        }
    }

    struct EntityMediaItem: Codable, Sendable {
        let localMediaId: String?
        let mediaCategory: String?
        let mediaId: String?

        private enum CodingKeys: String, CodingKey {
            case localMediaId, mediaCategory, mediaId
            case media_id
        }

        init(localMediaId: String? = nil, mediaCategory: String? = nil, mediaId: String? = nil) {
            self.localMediaId = localMediaId
            self.mediaCategory = mediaCategory
            self.mediaId = mediaId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localMediaId = try? container.decode(String.self, forKey: .localMediaId)
            mediaCategory = try? container.decode(String.self, forKey: .mediaCategory)
            mediaId = (try? container.decode(String.self, forKey: .mediaId))
                ?? (try? container.decode(String.self, forKey: .media_id))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(localMediaId, forKey: .localMediaId)
            try container.encodeIfPresent(mediaCategory, forKey: .mediaCategory)
            try container.encodeIfPresent(mediaId, forKey: .mediaId)
        }
    }

    struct MediaEntity: Codable, Sendable {
        let media_id: String
        let media_info: MediaInfo

        var asMedia: Media? {
            guard let original = media_info.original_img_url else { return nil }
            let thumbnail = Article.buildSizedMediaURL(from: original, size: "small")
            return Media(
                type: "photo",
                thumbnail: thumbnail,
                original: original,
                width: media_info.original_img_width,
                height: media_info.original_img_height
            )
        }
    }

    struct MediaInfo: Codable, Sendable {
        let original_img_url: URL?
        let original_img_width: Double?
        let original_img_height: Double?
    }

    private static func buildSizedMediaURL(from url: URL, size: String) -> URL {
        let absolute = url.absoluteString
        let questionIndex = absolute.firstIndex(of: "?") ?? absolute.endIndex
        let path = String(absolute[..<questionIndex])
        let cleanURL = URL(string: path) ?? url
        let ext = cleanURL.pathExtension.isEmpty ? "jpg" : cleanURL.pathExtension
        let base = path.dropLast(cleanURL.pathExtension.isEmpty ? 0 : ext.count + 1)
        return URL(string: "\(base)?format=\(ext)&name=\(size)") ?? url
    }
}
