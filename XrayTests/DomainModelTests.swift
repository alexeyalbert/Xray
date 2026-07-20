import Foundation
import Testing
@testable import Xray

@Suite("Domain model compatibility")
struct DomainModelTests {
    @Test("Post round trips link metadata without shifting fields")
    func postRoundTripPreservesLinks() throws {
        let destination = try #require(URL(string: "https://example.com/article"))
        let postURL = try #require(URL(string: "https://x.com/example/status/42"))
        let profileURL = try #require(URL(string: "https://pbs.twimg.com/profile_images/avatar_normal.jpg"))
        let link = PostLink(
            url: destination,
            expanded_url: destination,
            display_url: "example.com/article"
        )
        let post = Post(
            id: 42,
            created_at: Date(timeIntervalSince1970: 1_700_000_000),
            full_text: "A post with a link",
            media: nil,
            links: [link],
            screen_name: "example",
            name: "Example",
            profile_image_url: profileURL,
            url: postURL,
            text_embedding: [],
            img_embedding: [],
            primary_topic: "software",
            secondary_topics: ["swift"]
        )

        let encoded = try JSONEncoder().encode(post)
        let decoded = try JSONDecoder().decode(Post.self, from: encoded)

        #expect(decoded.id == post.id)
        #expect(decoded.links.count == 1)
        #expect(decoded.links.first?.destination == destination)
        #expect(decoded.links.first?.displayName == "example.com/article")
        #expect(decoded.primary_topic == "software")
        #expect(decoded.secondary_topics == ["swift"])
    }

    @Test("HTML entities decode in imported text models")
    func htmlEntitiesDecodeAtModelBoundary() {
        #expect("Design &amp; Development".decodedHTMLText == "Design & Development")
        #expect("No entities".decodedHTMLText == "No entities")
    }

    @Test("Topic labels preserve product capitalization")
    func topicDisplayFormatting() {
        #expect(TopicDisplayFormatter.displayName(for: "swiftui development") == "SwiftUI Development")
        #expect(TopicDisplayFormatter.displayName(for: "  openai   api ") == "OpenAI API")
    }

    @Test("SQLite projections stay aligned with their canonical layouts")
    func sqliteProjectionLayoutsStayAligned() {
        let standardColumns = projectionColumns(SQLitePostRowDecoder.standardProjection)
        #expect(standardColumns.count == 16)
        #expect(standardColumns[SQLitePostRowDecoder.Layout.standard.links] == "links")
        #expect(standardColumns[SQLitePostRowDecoder.Layout.standard.bookmarkOrder!] == "bookmark_order")

        let rebuildColumns = projectionColumns(SQLitePostRowDecoder.schemaRebuildProjection)
        #expect(rebuildColumns.count == 19)
        #expect(rebuildColumns[SQLitePostRowDecoder.Layout.schemaRebuild.normalizedTextEmbedding!] == "text_embedding_normalized")
        #expect(rebuildColumns[SQLitePostRowDecoder.Layout.schemaRebuild.links] == "links")

        let unorderedColumns = projectionColumns(SQLitePostRowDecoder.projectionWithoutBookmarkOrdering)
        #expect(unorderedColumns.count == 14)
        #expect(unorderedColumns[SQLitePostRowDecoder.Layout.withoutBookmarkOrdering.links] == "links")
    }

    private func projectionColumns(_ projection: String) -> [String] {
        projection
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
