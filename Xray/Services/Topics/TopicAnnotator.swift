//
//  TopicAnnotator.swift
//  Xray
//
//  Created by Alexey Albert on 2025-08-08.
//

import Foundation
import OSLog

struct GeneratedTopics: Codable {
    var primary_topic: String
    var secondary_topics: [String]
}

struct TopicAnnotationBatchResult: Sendable {
    let posts: [Post]
    let persistentSkipCandidatePostIDs: Set<Int>
    let configurationError: String?
}

struct TopicAnnotationConfigurationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum TopicAnnotator {
    private enum TopicGenerationResult {
        case success(GeneratedTopics)
        case retryableFailure
        case persistentSkipCandidate
    }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Xray", category: "TopicAnnotator")
    private static let topicInstructions = """
    You are a topic classification assistant. Analyze social media posts containing text and optional images to identify relevant topics. Some posts' topics might not be obvious or evident from the text alone, so use the image content (if available) to inform your analysis (e.g. photography posts). In some cases, the image attached may simply be a reaction image or meme unrelated to the actual contents/topic/thesis of the post. Use your best judgement to determine when it is appropriate to consider an image with a post. If a post is primarily talking about a person, or is about some drama or discourse about a person, its fine to use the name of the person being addressed as a topic. Use proper capitalization for topics, including cases where the topic might include an acronym (e.g. 'GPU' or 'GPUs'), or simply due to the known capitalization style of the word (e.g. 'iPhone' or 'iOS'). Otherwise, for common nouns, just use title-case (e.g. 'Sci-Fi' or 'Machine Learning').

    Return ONLY a minified JSON object with this exact schema:
    {"primary_topic":"<word>","secondary_topics":["<topic>","<topic>"]}

    Requirements:
    - primary_topic: single word, no punctuation or hashtags
    - secondary_topics: array of 1-3 topics (1-3 words each), distinct from primary_topic
    - Output only valid JSON, no explanations or code blocks
    - Begin with '{' and end with '}'

    Example: {"primary_topic":"Technology","secondary_topics":["AI","Software"]}
    """
    private static let topicImageLimit = 8
    private static let topicTemperature = 0.1
    private static let topicTopP = 0.8

    private static let openAICache = NSCache<NSNumber, NSData>()

    static func clearCache() {
        openAICache.removeAllObjects()
    }

    private enum MessageContent: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .parts(let value):
                try container.encode(value)
            }
        }
    }

    private struct ContentPart: Encodable {
        let type: String
        let text: String?
        let imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        static func text(_ value: String) -> ContentPart {
            ContentPart(type: "text", text: value, imageURL: nil)
        }

        static func imageURL(_ value: String) -> ContentPart {
            ContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: value, detail: "low"))
        }
    }

    private struct ImageURL: Encodable {
        let url: String
        let detail: String
    }

    private struct Message: Encodable {
        let role: String
        let content: MessageContent
    }

    private struct OpenRouterProviderPreferences: Encodable {
        let sort: String
        let zdr: Bool
    }

    private struct ResponseFormat: Encodable {
        let type: String
    }

    private struct GenerationConfig: Encodable {
        let mediaResolution: String

        enum CodingKeys: String, CodingKey {
            case mediaResolution = "media_resolution"
        }
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let topP: Double
        let responseFormat: ResponseFormat?
        let provider: OpenRouterProviderPreferences?
        let generationConfig: GenerationConfig?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case topP = "top_p"
            case responseFormat = "response_format"
            case provider
            case generationConfig = "generation_config"
        }
    }

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
            return TopicAnnotationBatchResult(
                posts: [],
                persistentSkipCandidatePostIDs: [],
                configurationError: nil
            )
        }
        guard OpenAIManager.isTopicGenerationConfigured else {
            logger.error("Topic annotation provider is not fully configured")
            return TopicAnnotationBatchResult(
                posts: posts,
                persistentSkipCandidatePostIDs: [],
                configurationError: "The topic annotation provider is not fully configured."
            )
        }

        let concurrentRequests = OpenAIManager.topicConcurrentRequests

        var results: [Post?] = Array(repeating: nil, count: total)
        var persistentSkipCandidatePostIDs = Set<Int>()
        var completed = 0

        for chunkStart in stride(from: 0, to: total, by: concurrentRequests) {
            let chunkEnd = min(chunkStart + concurrentRequests, total)
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

                        let generationResult = await generateTopics(for: post)
                        switch generationResult {
                        case .success(let topics):
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
                        case .persistentSkipCandidate:
                            return (i, post, true)
                        case .retryableFailure:
                            return (i, post, false)
                        }
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
            persistentSkipCandidatePostIDs: persistentSkipCandidatePostIDs,
            configurationError: nil
        )
    }

    // MARK: - Private helpers

    private static func generateTopics(for post: Post) async -> TopicGenerationResult {
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

        let provider = OpenAIManager.currentProvider
        let providerLabel = provider.rawValue
        let endpoint: URL
        switch provider {
        case .openrouter:
            endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .openAICompatible:
            do {
                endpoint = try OpenAIManager.chatCompletionsEndpoint(from: OpenAIManager.compatibleBaseURL)
            } catch {
                logger.error("[OpenAI-Compatible API] Invalid base URL: \(OpenAIManager.compatibleBaseURL, privacy: .public)")
                return .retryableFailure
            }
        }

        var userParts: [ContentPart] = [.text(composed)]
        userParts.append(contentsOf: imageDataURLs.map { .imageURL($0) })
        let userContent: MessageContent = imageDataURLs.isEmpty ? .text(composed) : .parts(userParts)
        let isOpenRouter = provider == .openrouter
        let body = ChatCompletionRequest(
            model: OpenAIManager.topicModel,
            messages: [
                Message(role: "system", content: .text(topicInstructions)),
                Message(role: "user", content: userContent)
            ],
            temperature: topicTemperature,
            topP: topicTopP,
            responseFormat: isOpenRouter ? ResponseFormat(type: "json_object") : nil,
            provider: isOpenRouter ? OpenRouterProviderPreferences(sort: "throughput", zdr: true) : nil,
            generationConfig: isOpenRouter ? GenerationConfig(mediaResolution: "MEDIA_RESOLUTION_LOW") : nil
        )

        var attempt = 0
        let maxAttempts = 3
        var backoff: Double = 0.4
        while attempt < maxAttempts {
            attempt += 1
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 120
                for (name, value) in OpenAIManager.topicHTTPHeaders() {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.httpBody = try JSONEncoder().encode(body)

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    logRemoteResponseFailure(
                        "Received a non-HTTP response",
                        provider: providerLabel,
                        postID: post.id,
                        attempt: attempt,
                        response: response,
                        data: responseData
                    )
                    return .retryableFailure
                }

                if isRetryableHTTPStatus(http.statusCode) {
                    logRemoteResponseFailure(
                        "Received a retryable HTTP error",
                        provider: providerLabel,
                        postID: post.id,
                        attempt: attempt,
                        response: http,
                        data: responseData
                    )
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let delay = retryAfter ?? backoff
                    #if DEBUG
                    logger.debug("[\(providerLabel, privacy: .public)] HTTP \(http.statusCode). Retrying in \(delay, privacy: .public)s (attempt \(attempt)/\(maxAttempts))")
                    #endif
                    try? await Task.sleep(for: .seconds(delay))
                    backoff *= 2
                    continue
                }

                guard (200..<300).contains(http.statusCode) else {
                    logRemoteResponseFailure(
                        "Received a non-success HTTP response",
                        provider: providerLabel,
                        postID: post.id,
                        attempt: attempt,
                        response: http,
                        data: responseData
                    )
                    return isPersistentTopicFailureCode(http.statusCode)
                        ? .persistentSkipCandidate
                        : .retryableFailure
                }

                if let providerError = providerError(from: responseData) {
                    let codeDescription = providerError.code.map(String.init) ?? "unknown"
                    logger.error(
                        "[\(providerLabel, privacy: .public)] Provider rejected topic request post=\(post.id) code=\(codeDescription, privacy: .public) message=\(providerError.message, privacy: .public)"
                    )
                    logRemoteResponseFailure(
                        "Provider returned an error envelope (code: \(codeDescription), message: \(providerError.message))",
                        provider: providerLabel,
                        postID: post.id,
                        attempt: attempt,
                        response: http,
                        data: responseData
                    )
                    guard let code = providerError.code else {
                        return .retryableFailure
                    }
                    return isPersistentTopicFailureCode(code)
                        ? .persistentSkipCandidate
                        : .retryableFailure
                }

                struct ChoiceMessage: Decodable { let content: String? }
                struct Choice: Decodable { let message: ChoiceMessage }
                struct ChatCompletionResponse: Decodable { let choices: [Choice] }

                let decoded: ChatCompletionResponse
                do {
                    decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: responseData)
                } catch {
                    logRemoteResponseFailure(
                        "Failed to decode response envelope: \(String(describing: error))",
                        provider: providerLabel,
                        postID: post.id,
                        attempt: attempt,
                        response: http,
                        data: responseData
                    )
                    return .retryableFailure
                }

                let raw = decoded.choices.first?.message.content ?? ""
                guard let topics = parseTopics(from: raw) else {
                    logRemoteResponseFailure(
                        "Failed to parse topics from response content",
                        provider: providerLabel,
                        postID: post.id,
                        attempt: attempt,
                        response: http,
                        data: responseData
                    )
                    return .retryableFailure
                }
                return .success(topics)
            } catch {
                if Task.isCancelled {
                    return .retryableFailure
                }
                if attempt >= maxAttempts {
                    logger.error("[\(providerLabel, privacy: .public)] request failed for post id=\(post.id) after retries: \(String(describing: error), privacy: .public)")
                    return .retryableFailure
                }
                #if DEBUG
                logger.debug("[\(providerLabel, privacy: .public)] transient error: \(String(describing: error), privacy: .public). Retrying (attempt \(attempt + 1)/\(maxAttempts))")
                #endif
                try? await Task.sleep(for: .seconds(backoff))
                backoff *= 2
            }
        }
        return .retryableFailure
    }

    private static func providerError(from data: Data) -> (message: String, code: Int?)? {
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

    static func isPersistentTopicFailureCode(_ statusCode: Int) -> Bool {
        // Payload-too-large is typically content-specific for this post.
        // Generic 400/422 are not: OpenAI-compatible servers commonly use them
        // for unsupported request fields or multimodal shapes, which would
        // otherwise skip the entire archive. Authentication, quota, model
        // access, and server errors also stay retryable so a systemic
        // configuration/outage cannot mark every post as unavailable.
        statusCode == 413
    }

    private static func logRemoteResponseFailure(
        _ reason: String,
        provider: String,
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
                "[\(provider, privacy: .public)] Raw failure response post=\(postID) attempt=\(attempt) chunk=\(index + 1)/\(chunks.count):\n\(chunk, privacy: .public)"
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

    static func parseTopics(from text: String) -> GeneratedTopics? {
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
        let normalizedPrimary = primary.lowercased()
        var seenSecondaryTopics = Set<String>()
        let secondary = parsed.secondary_topics.compactMap { topic -> String? in
            let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.lowercased()
            guard !trimmed.isEmpty,
                  normalized != normalizedPrimary,
                  seenSecondaryTopics.insert(normalized).inserted else {
                return nil
            }
            return trimmed
        }
        let limitedSecondary = Array(secondary.prefix(3))
        return GeneratedTopics(primary_topic: primary, secondary_topics: limitedSecondary)
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
