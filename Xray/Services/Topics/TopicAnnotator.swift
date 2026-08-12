//
//  TopicAnnotator.swift
//  Xray
//
//  Created by Alexey Albert on 2025-08-08.
//

import Foundation
import OSLog
import OpenAI

struct GeneratedTopics: Codable {
    var primary_topic: String
    var secondary_topics: [String]
}

struct TopicAnnotationBatchResult: Sendable {
    let posts: [Post]
    let persistentSkipCandidatePostIDs: Set<Int>
}

enum TopicAnnotator {
    private enum TopicGenerationResult {
        case success(GeneratedTopics)
        case retryableFailure
        case persistentSkipCandidate
    }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Xray", category: "TopicAnnotator")
    private static let topicInstructions = """
    You are a topic classification assistant. Analyze social media posts containing text and optional images to identify relevant topics. Some posts' topics might not be obvious or evident from the text alone, so use the image content (if available) to inform your analysis (e.g. photography posts). In some cases, the image attached may simply be a reaction image or meme unrelated to the actual contents/topic/thesis of the post. Use your best judgement to determine when it is appropriate to consider an image with a post. If a post is primary talking about a person, or is about some drama or discourse about a person, its fine to use the name of the person being addressed as a topic.

    Return ONLY a minified JSON object with this exact schema:
    {"primary_topic":"<word>","secondary_topics":["<topic>","<topic>"]}

    Requirements:
    - primary_topic: single lowercase word, no punctuation or hashtags
    - secondary_topics: array of 1-3 lowercase topics (1-3 words each), distinct from primary_topic
    - Output only valid JSON, no explanations or code blocks
    - Begin with '{' and end with '}'

    Example: {"primary_topic":"technology","secondary_topics":["ai","software"]}
    """
    private static let topicImageLimit = 8
    private static let topicTemperature = 0.1
    private static let topicTopP = 0.8
    private static let topicMaxTokens = 160

    private static let concurrentBatch = 1000
    private static let openAICache = NSCache<NSNumber, NSData>()

    // Public entrypoint: annotate an array of posts. Optionally report progress (current, total)
    static func annotatePostsWithTopics(
        _ posts: [Post],
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> TopicAnnotationBatchResult {
        #if DEBUG
        logger.info("Starting topic annotation for \(posts.count) posts")
        #endif
        let total = posts.count
        guard total > 0 else {
            return TopicAnnotationBatchResult(posts: [], persistentSkipCandidatePostIDs: [])
        }
        guard let client = OpenAIManager.makeClient() else {
            logger.error("Topic annotation requires a saved API key")
            return TopicAnnotationBatchResult(posts: posts, persistentSkipCandidatePostIDs: [])
        }

        var results: [Post?] = Array(repeating: nil, count: total)
        var persistentSkipCandidatePostIDs = Set<Int>()
        var completed = 0

        for chunkStart in stride(from: 0, to: total, by: concurrentBatch) {
            let chunkEnd = min(chunkStart + concurrentBatch, total)
            await withTaskGroup(of: (Int, Post, Bool).self) { group in
                for i in chunkStart..<chunkEnd {
                    let post = posts[i]
                    #if DEBUG
                    logger.debug("Annotating post id=\(post.id) (\(i + 1)/\(total))")
                    #endif
                    group.addTask {
                        // Cache: skip network call if we have a stored result for this post
                        if let cached = openAICache.object(forKey: NSNumber(value: post.id)) as Data?,
                           let parsed = try? JSONDecoder().decode(GeneratedTopics.self, from: cached) {
                            return (i, Post(
                                id: post.id,
                                created_at: post.created_at,
                                full_text: post.full_text,
                                media: post.media,
                                article: post.article,
                                links: post.links,
                                quoted_post: post.quoted_post,
                                screen_name: post.screen_name,
                                name: post.name,
                                profile_image_url: post.profile_image_url,
                                profile_image_shape: post.profile_image_shape,
                                url: post.url,
                                text_embedding: post.text_embedding,
                                img_embedding: post.img_embedding,
                                primary_topic: parsed.primary_topic,
                                secondary_topics: parsed.secondary_topics,
                                bookmark_import_generation: post.bookmark_import_generation,
                                bookmark_order: post.bookmark_order
                            ), false)
                        }

                        let generationResult = await generateTopicsWithOpenAI(for: post, client: client)
                        guard case .success(let topics) = generationResult else {
                            if case .persistentSkipCandidate = generationResult {
                                return (i, post, true)
                            }
                            return (i, post, false)
                        }
                        if let data = try? JSONEncoder().encode(topics) {
                            openAICache.setObject(data as NSData, forKey: NSNumber(value: post.id))
                        }
                        return (i, Post(
                            id: post.id,
                            created_at: post.created_at,
                            full_text: post.full_text,
                            media: post.media,
                            article: post.article,
                            links: post.links,
                            quoted_post: post.quoted_post,
                            screen_name: post.screen_name,
                            name: post.name,
                            profile_image_url: post.profile_image_url,
                            profile_image_shape: post.profile_image_shape,
                            url: post.url,
                            text_embedding: post.text_embedding,
                            img_embedding: post.img_embedding,
                            primary_topic: topics.primary_topic,
                            secondary_topics: topics.secondary_topics,
                            bookmark_import_generation: post.bookmark_import_generation,
                            bookmark_order: post.bookmark_order
                        ), false)
                    }
                }

                for await (i, updated, persistentSkipCandidate) in group {
                    results[i] = updated
                    if persistentSkipCandidate {
                        persistentSkipCandidatePostIDs.insert(updated.id)
                    }
                    completed += 1
                    onProgress?(completed, total)
                }
            }
        }

        let annotated: [Post] = results.enumerated().map { (idx, maybe) in maybe ?? posts[idx] }
        #if DEBUG
        logger.info("Finished topic annotation. Updated: \(annotated.filter { !$0.primary_topic.isEmpty }.count)/\(total)")
        #endif
        return TopicAnnotationBatchResult(
            posts: annotated,
            persistentSkipCandidatePostIDs: persistentSkipCandidatePostIDs
        )
    }

    // MARK: - Private helpers

    private static func generateTopicsWithOpenAI(for post: Post, client: OpenAI) async -> TopicGenerationResult {
        let composed = "Text:\n\(post.analysisText)\n"
        var imageDataURLs: [String] = []
        let mediaItems = (post.analysisMedia ?? [])
            .filter { MediaImageProcessor.isVisualMedia($0) }
            .prefix(topicImageLimit)
        for media in mediaItems {
            if let dataURL = await compressedImageDataURL(from: MediaImageProcessor.smallImageURL(for: media)) {
                imageDataURLs.append(dataURL)
            }
        }

        let model = OpenAIManager.currentProvider == .openrouter
            ? "google/gemini-2.5-flash-lite"
            : "gpt-4.1-mini"
        let systemParam = ChatQuery.ChatCompletionMessageParam.SystemMessageParam(
            content: .textContent(topicInstructions)
        )
        var openAIUserParts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = [
            .text(.init(text: composed))
        ]
        openAIUserParts.append(contentsOf: imageDataURLs.map {
            .image(.init(imageUrl: .init(url: $0, detail: .low)))
        })
        let userParam = ChatQuery.ChatCompletionMessageParam.UserMessageParam(
            content: .contentParts(openAIUserParts)
        )
        let messages: [ChatQuery.ChatCompletionMessageParam] = [
            .system(systemParam),
            .user(userParam)
        ]
        let topicsSchema: JSONSchema = .schema(
            .type(.object),
            .properties([
                "primary_topic": .schema(.type(.string)),
                "secondary_topics": .schema(
                    .type(.array),
                    .items(.schema(.type(.string)))
                )
            ]),
            .required(["primary_topic", "secondary_topics"]),
        )

        let responseFormat: ChatQuery.ResponseFormat = .jsonSchema(
            .init(
                name: "Topics",
                description: "Topic classification result",
                schema: .jsonSchema(topicsSchema),
                strict: true
            )
        )
        let query = ChatQuery(
            messages: messages,
            model: model,
            maxCompletionTokens: topicMaxTokens,
            responseFormat: responseFormat,
            temperature: topicTemperature,
            topP: topicTopP
        )

        // If provider is OpenRouter, bypass the OpenAI client and call OpenRouter directly
        if OpenAIManager.currentProvider == .openrouter, let headers = OpenAIManager.openRouterHTTPHeaders() {
            // Fast path via OpenRouter REST with tuned params and retry/backoff
            enum ORMessageContent: Encodable {
                case text(String)
                case parts([ORContentPart])

                func encode(to encoder: Encoder) throws {
                    switch self {
                    case .text(let value):
                        var container = encoder.singleValueContainer()
                        try container.encode(value)
                    case .parts(let value):
                        var container = encoder.singleValueContainer()
                        try container.encode(value)
                    }
                }
            }
            struct ORContentPart: Encodable {
                let type: String
                let text: String?
                let image_url: ORImageURL?

                static func text(_ value: String) -> ORContentPart {
                    ORContentPart(type: "text", text: value, image_url: nil)
                }

                static func imageURL(_ value: String) -> ORContentPart {
                    ORContentPart(type: "image_url", text: nil, image_url: ORImageURL(url: value))
                }
            }
            struct ORImageURL: Encodable { let url: String }
            struct ORMessage: Encodable { let role: String; let content: ORMessageContent }
            struct ORProvider: Encodable {
                let sort: String?
                let zdr: Bool
            }
            struct ORResponseFormat: Encodable { let type: String }
            struct ORGenerationConfig: Encodable { let media_resolution: String }
            struct ORBody: Encodable {
                let model: String
                let messages: [ORMessage]
                let temperature: Double
                let top_p: Double
                let max_tokens: Int
                let response_format: ORResponseFormat
                let provider: ORProvider
                let generation_config: ORGenerationConfig
            }
            var userParts: [ORContentPart] = [.text(composed)]
            userParts.append(contentsOf: imageDataURLs.map { .imageURL($0) })

            let body = ORBody(
                model: String(describing: model),
                messages: [
                    ORMessage(role: "system", content: .text(topicInstructions)),
                    ORMessage(role: "user", content: .parts(userParts))
                ],
                temperature: topicTemperature,
                top_p: topicTopP,
                max_tokens: topicMaxTokens,
                response_format: .init(type: "json_object"),
                provider: .init(sort: "throughput", zdr: true),
                generation_config: .init(media_resolution: "MEDIA_RESOLUTION_LOW")
            )

            let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            var attempt = 0
            let maxAttempts = 3
            var backoff: Double = 0.4
            while attempt < maxAttempts {
                attempt += 1
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                    request.httpBody = try JSONEncoder().encode(body)

                    let (respData, resp) = try await URLSession.shared.data(for: request)
                    guard let http = resp as? HTTPURLResponse else {
                        logOpenRouterResponseFailure(
                            "Received a non-HTTP response",
                            postID: post.id,
                            attempt: attempt,
                            response: resp,
                            data: respData
                        )
                        return .retryableFailure
                    }
                    if isRetryableHTTPStatus(http.statusCode) {
                        logOpenRouterResponseFailure(
                            "Received a retryable HTTP error",
                            postID: post.id,
                            attempt: attempt,
                            response: http,
                            data: respData
                        )
                        // Backoff and retry
                        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                        let delay = retryAfter ?? backoff
                        #if DEBUG
                        logger.debug("[OpenRouter] HTTP \(http.statusCode). Retrying in \(delay, privacy: .public)s (attempt \(attempt)/\(maxAttempts))")
                        #endif
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        backoff *= 2
                        continue
                    }
                    if http.statusCode < 200 || http.statusCode >= 300 {
                        logOpenRouterResponseFailure(
                            "Received a non-success HTTP response",
                            postID: post.id,
                            attempt: attempt,
                            response: http,
                            data: respData
                        )
                        return isPersistentTopicFailureCode(http.statusCode)
                            ? .persistentSkipCandidate
                            : .retryableFailure
                    }

                    if let providerError = openRouterError(from: respData) {
                        let codeDescription = providerError.code.map(String.init) ?? "unknown"
                        logger.error(
                            "[OpenRouter] Provider rejected topic request post=\(post.id) code=\(codeDescription, privacy: .public) message=\(providerError.message, privacy: .public)"
                        )
                        logOpenRouterResponseFailure(
                            "Provider returned an error envelope (code: \(codeDescription), message: \(providerError.message))",
                            postID: post.id,
                            attempt: attempt,
                            response: http,
                            data: respData
                        )
                        guard let code = providerError.code else {
                            return .retryableFailure
                        }
                        return isPersistentTopicFailureCode(code)
                            ? .persistentSkipCandidate
                            : .retryableFailure
                    }

                    // Parse minimal shape from OpenRouter response
                    struct ORChoiceMessage: Decodable { let role: String; let content: String }
                    struct ORChoice: Decodable { let message: ORChoiceMessage }
                    struct ORResponse: Decodable { let choices: [ORChoice] }
                    let decoded: ORResponse
                    do {
                        decoded = try JSONDecoder().decode(ORResponse.self, from: respData)
                    } catch {
                        logOpenRouterResponseFailure(
                            "Failed to decode response envelope: \(String(describing: error))",
                            postID: post.id,
                            attempt: attempt,
                            response: http,
                            data: respData
                        )
                        return .retryableFailure
                    }
                    let raw = decoded.choices.first?.message.content ?? ""
                    guard let topics = parseTopics(from: raw) else {
                        logOpenRouterResponseFailure(
                            "Failed to parse topics from response content",
                            postID: post.id,
                            attempt: attempt,
                            response: http,
                            data: respData
                        )
                        return .retryableFailure
                    }
                    return .success(topics)
                } catch {
                    if attempt >= maxAttempts {
                        logger.error("[OpenRouter] request failed for post id=\(post.id) after retries: \(String(describing: error), privacy: .public)")
                        return .retryableFailure
                    }
                    #if DEBUG
                    logger.debug("[OpenRouter] transient error: \(String(describing: error), privacy: .public). Retrying (attempt \(attempt + 1)/\(maxAttempts))")
                    #endif
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    backoff *= 2
                }
            }
            return .retryableFailure
        }

        // Default: use OpenAI client (OpenAI provider)
        do {
            let result = try await client.chats(query: query)
            let raw = result.choices.first?.message.content ?? ""
            guard let topics = parseTopics(from: raw) else {
                return .retryableFailure
            }
            return .success(topics)
        } catch {
            logger.error("Topic generation failed for post id=\(post.id): \(String(describing: error), privacy: .public)")
            return .retryableFailure
        }
    }

    private static func openRouterError(from data: Data) -> (message: String, code: Int?)? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            return nil
        }

        let message = error["message"] as? String ?? String(describing: error)
        let code: Int?
        if let number = error["code"] as? NSNumber {
            code = number.intValue
        } else if let string = error["code"] as? String {
            code = Int(string)
        } else {
            code = nil
        }
        return (message, code)
    }

    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 409
            || statusCode == 425
            || statusCode == 429
            || (500...599).contains(statusCode)
    }

    private static func isPersistentTopicFailureCode(_ statusCode: Int) -> Bool {
        // These request-level client errors can be content-specific and deterministic.
        // Authentication, quota, model access, and server errors deliberately remain
        // unresolved so a systemic configuration/outage cannot skip the whole archive.
        statusCode == 400 || statusCode == 413 || statusCode == 422
    }

    private static func logOpenRouterResponseFailure(
        _ reason: String,
        postID: Int,
        attempt: Int,
        response: URLResponse,
        data: Data
    ) {
        let responseType = String(describing: type(of: response))
        let url = response.url?.absoluteString ?? "<none>"
        let mimeType = response.mimeType ?? "<none>"
        let textEncoding = response.textEncodingName ?? "<none>"
        let suggestedFilename = response.suggestedFilename ?? "<none>"
        let body: String
        let bodyEncoding: String
        if let utf8Body = String(data: data, encoding: .utf8) {
            body = utf8Body
            bodyEncoding = "UTF-8"
        } else {
            body = data.base64EncodedString()
            bodyEncoding = "base64 (response was not valid UTF-8)"
        }

        var lines = [
            "Reason: \(reason)",
            "Post ID: \(postID)",
            "Attempt: \(attempt)",
            "Response type: \(responseType)",
            "URL: \(url)"
        ]
        if let http = response as? HTTPURLResponse {
            lines.append("HTTP status: \(http.statusCode)")
            let headers = http.allHeaderFields
                .map { (String(describing: $0.key), String(describing: $0.value)) }
                .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            lines.append("Headers:")
            if headers.isEmpty {
                lines.append("<none>")
            } else {
                lines.append(contentsOf: headers.map { "\($0): \($1)" })
            }
        }
        lines.append(contentsOf: [
            "MIME type: \(mimeType)",
            "Text encoding: \(textEncoding)",
            "Expected content length: \(response.expectedContentLength)",
            "Suggested filename: \(suggestedFilename)",
            "Body bytes: \(data.count)",
            "Body encoding in this log: \(bodyEncoding)",
            "Body:",
            body
        ])

        // Unified logging can truncate large messages, so emit the complete diagnostic in
        // small, individually labeled chunks. The post/attempt labels keep concurrent
        // topic-generation failures attributable even when their messages interleave.
        let diagnostic = lines.joined(separator: "\n")
        let chunks = diagnostic.chunked(maxCharacterCount: 800)
        for (index, chunk) in chunks.enumerated() {
            logger.error(
                "[OpenRouter] Raw failure response post=\(postID) attempt=\(attempt) chunk=\(index + 1)/\(chunks.count):\n\(chunk, privacy: .public)"
            )
        }
    }

    private static func compressedImageDataURL(from url: URL) async -> String? {
        guard let dataURL = await MediaImageProcessor.processedImageDataURL(from: url) else {
            #if DEBUG
            logger.debug("Failed to fetch image for topic annotation: \(url.absoluteString, privacy: .public)")
            #endif
            return nil
        }
        return dataURL
    }

    private static func parseTopics(from text: String) -> GeneratedTopics? {
        func extractJSONCandidate(from text: String) -> String? {
            let pattern = #"\{[\s\S]*?\}"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for m in matches {
                if let r = Range(m.range, in: text) {
                    let candidate = String(text[r])
                    if candidate.contains("\"primary_topic\"") && candidate.contains("\"secondary_topics\"") {
                        return candidate
                    }
                }
            }
            return nil
        }
        guard let jsonText = extractJSONCandidate(from: text) else { return nil }
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(GeneratedTopics.self, from: data) else { return nil }

        let primary = parsed.primary_topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var secondary = Array(Set(parsed.secondary_topics.map { $0
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() }))
        secondary.removeAll { $0 == primary || $0.isEmpty }
        secondary = Array(secondary.prefix(3))
        return GeneratedTopics(primary_topic: primary, secondary_topics: secondary)
    }

}

private extension String {
    func chunked(maxCharacterCount: Int) -> [String] {
        guard !isEmpty else { return [""] }
        var chunks: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: maxCharacterCount, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[start..<end]))
            start = end
        }
        return chunks
    }
}
