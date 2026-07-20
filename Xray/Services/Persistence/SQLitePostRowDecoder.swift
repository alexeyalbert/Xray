import Foundation
import SQLite

/// Owns the positional contract shared by SQLite post projections and row decoding.
///
/// Keeping the projection and layout together prevents a newly inserted column from
/// silently shifting every field that follows it in one query path.
nonisolated struct SQLitePostRowDecoder {
    struct Layout {
        let id: Int
        let createdAt: Int
        let fullText: Int
        let media: Int
        let article: Int
        let screenName: Int
        let name: Int
        let profileImageURL: Int
        let profileImageShape: Int
        let url: Int
        let primaryTopic: Int
        let secondaryTopics: Int
        let quotedPost: Int
        let textEmbedding: Int?
        let normalizedTextEmbedding: Int?
        let imageEmbedding: Int?
        let bookmarkImportGeneration: Int?
        let bookmarkOrder: Int?
        let links: Int

        static let standard = Layout(
            id: 0,
            createdAt: 1,
            fullText: 2,
            media: 3,
            article: 4,
            screenName: 5,
            name: 6,
            profileImageURL: 7,
            profileImageShape: 8,
            url: 9,
            primaryTopic: 10,
            secondaryTopics: 11,
            quotedPost: 12,
            textEmbedding: nil,
            normalizedTextEmbedding: nil,
            imageEmbedding: nil,
            bookmarkImportGeneration: 13,
            bookmarkOrder: 14,
            links: 15
        )

        static let schemaRebuild = Layout(
            id: 0,
            createdAt: 1,
            fullText: 2,
            media: 3,
            article: 4,
            screenName: 5,
            name: 6,
            profileImageURL: 7,
            profileImageShape: 8,
            url: 9,
            primaryTopic: 10,
            secondaryTopics: 11,
            quotedPost: 12,
            textEmbedding: 13,
            normalizedTextEmbedding: 14,
            imageEmbedding: 15,
            bookmarkImportGeneration: 16,
            bookmarkOrder: 17,
            links: 18
        )

        static let withoutBookmarkOrdering = Layout(
            id: 0,
            createdAt: 1,
            fullText: 2,
            media: 3,
            article: 4,
            screenName: 5,
            name: 6,
            profileImageURL: 7,
            profileImageShape: 8,
            url: 9,
            primaryTopic: 10,
            secondaryTopics: 11,
            quotedPost: 12,
            textEmbedding: nil,
            normalizedTextEmbedding: nil,
            imageEmbedding: nil,
            bookmarkImportGeneration: nil,
            bookmarkOrder: nil,
            links: 13
        )
    }

    struct DecodedPost {
        let post: Post
        let normalizedTextEmbedding: [Float]
    }

    static let standardProjection = """
    id, created_at, full_text, media, article, screen_name, name, profile_image_url, profile_image_shape, url,
           primary_topic, secondary_topics, quoted_post, bookmark_import_generation, bookmark_order, links
    """

    static let schemaRebuildProjection = """
    id, created_at, full_text, media, article, screen_name, name, profile_image_url, profile_image_shape, url,
           primary_topic, secondary_topics, quoted_post, text_embedding, text_embedding_normalized, img_embedding,
           bookmark_import_generation, bookmark_order, links
    """

    static let projectionWithoutBookmarkOrdering = """
    id, created_at, full_text, media, article, screen_name, name, profile_image_url, profile_image_shape, url,
           primary_topic, secondary_topics, quoted_post, links
    """

    func decode(_ row: [Binding?], layout: Layout = .standard) -> DecodedPost {
        let textEmbedding = layout.textEmbedding.flatMap { floats(from: row[$0]) } ?? []
        let normalizedTextEmbedding = layout.normalizedTextEmbedding.flatMap { floats(from: row[$0]) } ?? []
        let imageEmbedding = layout.imageEmbedding.flatMap { floats(from: row[$0]) } ?? []

        let post = Post(
            id: Int(row[layout.id] as! Int64),
            created_at: Date(timeIntervalSince1970: row[layout.createdAt] as! Double),
            full_text: row[layout.fullText] as! String,
            media: decodeJSON(row[layout.media] as? String, as: [Media].self),
            article: decodeJSON(row[layout.article] as? String, as: Article.self),
            links: decodeJSON(row[layout.links] as? String, as: [PostLink].self) ?? [],
            quoted_post: decodeJSON(row[layout.quotedPost] as? String, as: QuotedPost.self),
            screen_name: row[layout.screenName] as! String,
            name: row[layout.name] as! String,
            profile_image_url: url(from: row[layout.profileImageURL]),
            profile_image_shape: ProfileImageShape(rawValue: (row[layout.profileImageShape] as? String) ?? "") ?? .circle,
            url: url(from: row[layout.url]),
            text_embedding: textEmbedding,
            img_embedding: imageEmbedding,
            primary_topic: (row[layout.primaryTopic] as? String) ?? "",
            secondary_topics: decodeJSON(row[layout.secondaryTopics] as? String, as: [String].self) ?? [],
            bookmark_import_generation: layout.bookmarkImportGeneration.flatMap { int64(from: row[$0]) },
            bookmark_order: layout.bookmarkOrder.flatMap { int(from: row[$0]) }
        )

        return DecodedPost(post: post, normalizedTextEmbedding: normalizedTextEmbedding)
    }

    private func decodeJSON<Value: Decodable>(_ text: String?, as type: Value.Type) -> Value? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func floats(from value: Binding?) -> [Float]? {
        guard let blob = value as? Blob else { return nil }
        let data = Data(blob.bytes)
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }

        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        floats.withUnsafeMutableBytes { destination in
            _ = data.copyBytes(to: destination)
        }
        return floats
    }

    private func int64(from value: Binding?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }

    private func int(from value: Binding?) -> Int? {
        if let value = value as? Int64 { return Int(value) }
        return value as? Int
    }

    private func url(from value: Binding?) -> URL {
        URL(string: value as! String) ?? URL(string: "https://invalid.local/")!
    }
}
