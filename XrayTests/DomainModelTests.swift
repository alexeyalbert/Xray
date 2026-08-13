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

    @Test("Topic generation exposes only OpenRouter and OpenAI-compatible providers")
    func topicGenerationProviderChoices() {
        #expect(AIProvider.allCases == [.openrouter, .openAICompatible])
        #expect(AppSecretsKey.openRouterAPIKey.rawValue != AppSecretsKey.openAICompatibleTopicAPIKey.rawValue)
    }

    @Test("Topic generation stays unconfigured without credentials for remote OpenAI-compatible defaults")
    func topicGenerationRequiresCredentialsForRemoteCompatibleProvider() {
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: OpenAIManager.defaultCompatibleModel,
                baseURL: OpenAIManager.defaultCompatibleBaseURL,
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: OpenAIManager.defaultCompatibleModel,
                baseURL: OpenAIManager.defaultCompatibleBaseURL,
                apiKey: "sk-test"
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://localhost:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://127.0.0.1:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://100.64.1.5:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://100.127.255.255:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://[fd7a:115c:a1e0::1]:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://machine.tailnet.ts.net:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://192.168.1.10:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://10.0.0.5:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://172.16.0.1:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://studio.local:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://[fd12:3456:789a::1]:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://100.63.255.255:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://172.15.0.1:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "llama3",
                baseURL: "http://8.8.8.8:1234/v1",
                apiKey: nil
            )
        )
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: OpenAIManager.defaultCompatibleModel,
                baseURL: "https://api.openai.com/v1",
                apiKey: nil
            )
        )
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: "",
                baseURL: OpenAIManager.defaultCompatibleBaseURL,
                apiKey: "sk-test"
            )
        )
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openAICompatible,
                model: OpenAIManager.defaultCompatibleModel,
                baseURL: "not a URL",
                apiKey: "sk-test"
            )
        )
        #expect(
            !OpenAIManager.isTopicGenerationConfigured(
                provider: .openrouter,
                model: "",
                baseURL: "",
                apiKey: nil
            )
        )
        #expect(
            OpenAIManager.isTopicGenerationConfigured(
                provider: .openrouter,
                model: "",
                baseURL: "",
                apiKey: "sk-or-test"
            )
        )
    }

    @Test("OpenAI-compatible base URLs resolve to chat completions")
    func openAICompatibleChatCompletionsURLs() throws {
        #expect(
            try OpenAIManager.chatCompletionsEndpoint(from: "https://api.openai.com/v1")
                .absoluteString == "https://api.openai.com/v1/chat/completions"
        )
        #expect(
            try OpenAIManager.chatCompletionsEndpoint(from: "http://localhost:1234")
                .absoluteString == "http://localhost:1234/v1/chat/completions"
        )
        #expect(
            try OpenAIManager.chatCompletionsEndpoint(from: "https://example.com/custom/v1/chat/completions")
                .absoluteString == "https://example.com/custom/v1/chat/completions"
        )
        #expect(throws: URLError.self) {
            try OpenAIManager.chatCompletionsEndpoint(from: "not a URL")
        }
    }

    @Test("Concurrent topic requests determine persistence frequency for every provider")
    func topicPersistencePageSizes() {
        #expect(OpenAIManager.defaultTopicConcurrentRequests(for: .openrouter) == 100)
        #expect(OpenAIManager.defaultTopicConcurrentRequests(for: .openAICompatible) == 16)
        #expect(
            OpenAIManager.topicPersistencePageSize(for: .openAICompatible, concurrentRequests: 1) == 1
        )
        #expect(
            OpenAIManager.topicPersistencePageSize(for: .openAICompatible, concurrentRequests: 16) == 16
        )
        #expect(
            OpenAIManager.topicPersistencePageSize(for: .openAICompatible, concurrentRequests: 1000)
                == OpenAIManager.topicConcurrentRequestsRange.upperBound
        )
        #expect(
            OpenAIManager.topicPersistencePageSize(for: .openrouter, concurrentRequests: 1)
                == 1
        )
        #expect(
            OpenAIManager.topicPersistencePageSize(for: .openrouter, concurrentRequests: 100)
                == 100
        )
    }

    @Test("SQLite projections stay aligned with their canonical layouts")
    func sqliteProjectionLayoutsStayAligned() {
        let standardColumns = projectionColumns(SQLitePostRowDecoder.standardProjection)
        #expect(standardColumns.count == 16)
        #expect(standardColumns[SQLitePostRowDecoder.Layout.standard.links] == "links")
        #expect(standardColumns[SQLitePostRowDecoder.Layout.standard.bookmarkOrder!] == "bookmark_order")

        let rebuildColumns = projectionColumns(SQLitePostRowDecoder.schemaRebuildProjection)
        #expect(rebuildColumns.count == 20)
        #expect(rebuildColumns[SQLitePostRowDecoder.Layout.schemaRebuild.normalizedTextEmbedding!] == "text_embedding_normalized")
        #expect(rebuildColumns[SQLitePostRowDecoder.Layout.schemaRebuild.links] == "links")
        #expect(rebuildColumns[SQLitePostRowDecoder.Layout.schemaRebuild.topicAnnotationFailed!] == "topic_annotation_failed")

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
