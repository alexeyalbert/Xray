//
//  EmbeddingsManager.swift
//  Xray
//
//  Created by Alexey Albert on 2025-08-10.
//

import Foundation
import OSLog
import MLX
import MLXEmbeddings

private struct ImageEmbeddingRequest: Sendable {
    let data: Data
    let source: String
}

struct UnavailableImageMedia: Sendable {
    let media: Media
    let statusCode: Int
}

struct ImageEmbeddingBatchResult: Sendable {
    let embeddings: [(media: Media, embedding: [Float])]
    let unavailableMedia: [UnavailableImageMedia]
}

private actor ImageEmbeddingEngine {
    private let logger = Logger(subsystem: "com.alexeyalbert.Xray", category: "ImageEmbeddingEngine")
    private let modelIdentifier: @Sendable () -> String
    private let targetDimension: Int
    private var model: MLXEmbeddings?

    init(modelIdentifier: @escaping @Sendable () -> String, targetDimension: Int) {
        self.modelIdentifier = modelIdentifier
        self.targetDimension = targetDimension
    }

    func embed(_ request: ImageEmbeddingRequest) -> [Float]? {
        do {
            let model = try ensureModelLoaded()
            let started = Date()
            let array = try model.embedQwen3VL(
                imageData: request.data,
                normalized: true,
                dimensions: targetDimension
            )
            MLX.eval(array)
            let vector = fitToTargetDimension(array.asArray(Float.self))
            let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            logger.debug("[Embeddings] Image embed ok. dims=\(vector.count) in \(milliseconds) ms")
            validateEmbedding(vector, source: request.source)
            return vector
        } catch {
            logger.error("[Embeddings] Image embed failed: \(String(reflecting: error))")
            return nil
        }
    }

    func embed(text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            let model = try ensureModelLoaded()
            let started = Date()
            let array = try model.embedQwen3VL(
                text: trimmed,
                normalized: true,
                dimensions: targetDimension
            )
            MLX.eval(array)
            let vector = fitToTargetDimension(array.asArray(Float.self))
            let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            logger.debug("[Embeddings] Image-model text embed ok. dims=\(vector.count) in \(milliseconds) ms")
            validateEmbedding(vector, source: "image query: \(trimmed)")
            return vector
        } catch {
            logger.error("[Embeddings] Image-model text embed failed: \(String(reflecting: error))")
            return nil
        }
    }

    func embedBatch(_ requests: [ImageEmbeddingRequest]) -> [[Float]] {
        guard !requests.isEmpty else { return [] }

        do {
            let model = try ensureModelLoaded()
            let started = Date()
            let arrays = try model.embedQwen3VLBatch(
                requests.map { Qwen3VLEmbeddingInput(imageData: $0.data) },
                normalized: true,
                dimensions: targetDimension
            )
            MLX.eval(arrays)

            let vectors = zip(requests, arrays).map { request, array in
                let vector = fitToTargetDimension(array.asArray(Float.self))
                validateEmbedding(vector, source: request.source)
                return vector
            }
            let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            logger.debug("[Embeddings] Image batch embed ok. count=\(vectors.count) dims=\(self.targetDimension) in \(milliseconds) ms")
            return vectors
        } catch {
            logger.error("[Embeddings] Qwen3-VL image batch failed: \(String(reflecting: error))")
            return []
        }
    }

    func unload() {
        guard model != nil else { return }
        model = nil
        releaseGPUResources()
        logger.info("[Embeddings] Unloaded image embedding model and explicitly cleared GPU cache")
    }

    private func ensureModelLoaded() throws -> MLXEmbeddings {
        if let model { return model }

        Memory.cacheLimit = 512 * 1024 * 1024
        let modelIdentifier = modelIdentifier()
        logger.info("[Embeddings] Loading image model from: \(modelIdentifier, privacy: .public)")
        let loadedModel = try MLXEmbeddings.load(
            modelIdentifier,
            modelConfig: ["model_type": "qwen3_vl"]
        )
        model = loadedModel
        logger.info("[Embeddings] Image model loaded")
        return loadedModel
    }

    private func fitToTargetDimension(_ vector: [Float]) -> [Float] {
        if vector.count == targetDimension { return vector }
        if vector.count > targetDimension {
            logger.warning("[Embeddings] Truncating vector from \(vector.count) to \(self.targetDimension) dimensions")
            return Array(vector.prefix(targetDimension))
        }

        logger.warning("[Embeddings] Padding vector from \(vector.count) to \(self.targetDimension) dimensions with zeros")
        var fitted = vector
        fitted.append(contentsOf: Array(repeating: 0, count: targetDimension - vector.count))
        return fitted
    }

    private func validateEmbedding(_ embedding: [Float], source: String) {
        guard !embedding.isEmpty else {
            logger.error("[Embeddings] Empty image embedding generated for \(source, privacy: .public)")
            return
        }

        if embedding.contains(where: { $0.isNaN || $0.isInfinite }) {
            logger.error("[Embeddings] Invalid values (NaN/Inf) in image embedding for \(source, privacy: .public)")
        }

        let magnitude = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if abs(magnitude - 1) > 0.1 {
            logger.warning("[Embeddings] Image embedding magnitude \(magnitude, format: .fixed(precision: 3)) deviates significantly from 1.0 for \(source, privacy: .public)")
        }

        logger.debug("[Embeddings] Validated image embedding: dims=\(embedding.count), magnitude=\(magnitude, format: .fixed(precision: 3))")
    }

    private func releaseGPUResources() {
        let before = Memory.snapshot()
        logger.info("[Embeddings] Image embedding model pre-cleanup snapshot: active=\(before.activeMemory) cache=\(before.cacheMemory) peak=\(before.peakMemory)")
        Stream.defaultStream(Device.gpu).synchronize()
        Memory.cacheLimit = 0
        Memory.clearCache()
        Stream.defaultStream(Device.gpu).synchronize()
        let after = Memory.snapshot()
        logger.info("[Embeddings] Image embedding model post-cleanup snapshot: active=\(after.activeMemory) cache=\(after.cacheMemory) peak=\(after.peakMemory)")
    }
}

enum EmbeddingsManager {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Xray", category: "EmbeddingsManager")

    private static let mebibyte = 1024 * 1024
    private static let normalTextCacheLimit = 256 * mebibyte
    private static let shortBatchTextCacheLimit = 512 * mebibyte
    private static let longBatchTextCacheLimit = 128 * mebibyte
    private static let memoryPressureTextCacheLimit = 64 * mebibyte
    private static let shortTextCharacterLimit = 1_024
    private static let longTextCharacterThreshold = 4_096
    private static let cachePolicyLock = NSLock()
    private static var memoryPressureConstrained = false
    private static let memoryPressureSource: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue(label: "com.alexeyalbert.Xray.embedding-memory-pressure")
        )
        source.setEventHandler {
            cachePolicyLock.lock()
            memoryPressureConstrained = true
            cachePolicyLock.unlock()

            applyTextCacheLimit(memoryPressureTextCacheLimit, clearExistingCache: true)
            logger.warning("[Embeddings] Memory pressure detected; reduced MLX cache limit to 64 MiB and cleared cached buffers")
        }
        source.resume()
        return source
    }()

    nonisolated static let targetDimension: Int = 1024
    nonisolated static let imageTargetDimension: Int = 1024
    static var textEmbeddingBatchSize: Int { EmbeddingProviderSettings.batchSize }
    nonisolated static let imageEmbeddingModelVersion = "qwen3-vl-embedding-2b-8bit-1024d-v1"

    private static var textModelIdentifier: String {
        LocalEmbeddingModelStore.modelIdentifier(for: .text)
    }
    private static var imageModelIdentifier: String {
        LocalEmbeddingModelStore.modelIdentifier(for: .image)
    }

    private static var sharedTextEmbeddings: MLXEmbeddings?
    private static var imageEngine = ImageEmbeddingEngine(
        modelIdentifier: { imageModelIdentifier },
        targetDimension: imageTargetDimension
    )

    // MARK: - Public API

    /// Compute an embedding for a single text using the Qwen3 text embedding model.
    static func embed(text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        logger.debug("[Embeddings] Start text embed, length=\(trimmed.count)")
        let started = Date()
        let result: [Float]?
        switch EmbeddingProviderSettings.provider {
        case .local:
            await imageEngine.unload()
            result = await embedUsingQwen3(texts: [trimmed]).first
        case .openAICompatible:
            result = await embedUsingOpenAICompatibleAPI(texts: [trimmed]).first
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.debug("[Embeddings] Done text embed in \(ms) ms, vector? \(result != nil)")

        if let embedding = result {
            validateEmbedding(embedding, source: "text", text: trimmed)
        }

        return result
    }

    /// Compute embeddings for a batch of texts using the Qwen3 text embedding model.
    static func embedBatch(texts: [String]) async -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        logger.debug("[Embeddings] Start batch text embed, count=\(texts.count), configuredBatchSize=\(textEmbeddingBatchSize)")
        let started = Date()
        let out: [[Float]]
        switch EmbeddingProviderSettings.provider {
        case .local:
            await imageEngine.unload()
            out = await embedUsingQwen3(texts: texts)
        case .openAICompatible:
            out = await embedUsingOpenAICompatibleAPI(texts: texts)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.debug("[Embeddings] Done batch text embed in \(ms) ms, ok=\(out.count == texts.count)")

        for (i, embedding) in out.enumerated() {
            let text = i < texts.count ? texts[i] : "unknown"
            validateEmbedding(embedding, source: "batch_text_\(i)", text: text)
        }

        return out
    }

    /// Compute a Qwen3-VL image embedding for one media item.
    static func embedImage(from media: Media) async -> [Float]? {
        guard let data = await MediaImageProcessor.embeddingImageData(for: media) else {
            logger.warning("[Embeddings] Image preprocessing failed for \(media.original.absoluteString, privacy: .public)")
            return nil
        }

        unloadTextModel()
        return await imageEngine.embed(
            ImageEmbeddingRequest(data: data, source: media.original.absoluteString)
        )
    }

    /// Embed a typed query in the same Qwen3-VL space as stored image vectors.
    static func embedImageQuery(text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        unloadTextModel()
        return await imageEngine.embed(text: trimmed)
    }

    /// Compute Qwen3-VL embeddings for individual media items. Callers should keep
    /// chunks small; the 2B vision model groups equal-length image prompts internally.
    static func embedImageBatch(from mediaItems: [Media]) async -> ImageEmbeddingBatchResult {
        let visualMedia = mediaItems.filter { MediaImageProcessor.isImageSearchMedia($0) }
        guard !visualMedia.isEmpty else {
            return ImageEmbeddingBatchResult(embeddings: [], unavailableMedia: [])
        }

        var prepared: [(media: Media, data: Data)] = []
        var unavailableMedia: [UnavailableImageMedia] = []
        prepared.reserveCapacity(visualMedia.count)
        for media in visualMedia {
            switch await MediaImageProcessor.embeddingImageDataResult(for: media) {
            case .success(let data):
                prepared.append((media, data))
            case .unavailable(let statusCode):
                unavailableMedia.append(UnavailableImageMedia(media: media, statusCode: statusCode))
                logger.warning("[Embeddings] Image is permanently unavailable (HTTP \(statusCode)) for \(media.original.absoluteString, privacy: .public)")
            case .retryableFailure:
                logger.warning("[Embeddings] Image download failed for \(media.original.absoluteString, privacy: .public)")
            }
        }
        guard !prepared.isEmpty else {
            return ImageEmbeddingBatchResult(embeddings: [], unavailableMedia: unavailableMedia)
        }

        unloadTextModel()
        let vectors = await imageEngine.embedBatch(
            prepared.map {
                ImageEmbeddingRequest(
                    data: $0.data,
                    source: $0.media.original.absoluteString
                )
            }
        )
        guard vectors.count == prepared.count else {
            return ImageEmbeddingBatchResult(embeddings: [], unavailableMedia: unavailableMedia)
        }
        let embeddings = zip(prepared, vectors).map { item, vector in
            (media: item.media, embedding: vector)
        }
        return ImageEmbeddingBatchResult(embeddings: embeddings, unavailableMedia: unavailableMedia)
    }

    // MARK: - MLX text path

    private static func ensureTextModelLoaded() throws -> MLXEmbeddings {
        if let model = sharedTextEmbeddings { return model }

        _ = memoryPressureSource
        applyTextCacheLimit(effectiveTextCacheLimit(normalTextCacheLimit), clearExistingCache: false)
        logger.info("[Embeddings] Loading text model from: \(textModelIdentifier, privacy: .public)")
        let model = try MLXEmbeddings.load(textModelIdentifier, modelConfig: ["model_type": "qwen3"])
        sharedTextEmbeddings = model
        logger.info("[Embeddings] Text model loaded")
        return model
    }

    private static func embedUsingQwen3(texts: [String]) async -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        do {
            let model = try ensureTextModelLoaded()
            configureTextCache(for: texts)
            let arrays = model.embedBatch(
                texts,
                normalized: true,
                batchSize: textEmbeddingBatchSize,
                dimensions: targetDimension
            )
            var out: [[Float]] = []
            out.reserveCapacity(arrays.count)
            for (i, arr) in arrays.enumerated() {
                out.append(fitToTargetDimension(arr.asArray(Float.self), to: targetDimension))
                if i % 8 == 0 { await Task.yield() }
            }
            return out
        } catch {
            logger.error("Qwen3 text embeddings failed: \(String(reflecting: error))")
            return []
        }
    }

    // MARK: - OpenAI-compatible text path

    private struct RemoteEmbeddingRequest: Encodable {
        let model: String
        let input: [String]
        let encodingFormat: String

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case encodingFormat = "encoding_format"
        }
    }

    private struct RemoteEmbeddingResponse: Decodable {
        struct EmbeddingItem: Decodable {
            let index: Int
            let embedding: [Float]
        }

        let data: [EmbeddingItem]
    }

    private static func embedUsingOpenAICompatibleAPI(texts: [String]) async -> [[Float]] {
        let trimmedTexts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmedTexts.isEmpty else { return [] }

        do {
            let endpoint = try remoteEmbeddingsEndpoint(from: EmbeddingProviderSettings.remoteBaseURL)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey = EmbeddingProviderSettings.remoteAPIKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let body = RemoteEmbeddingRequest(
                model: EmbeddingProviderSettings.remoteModel,
                input: trimmedTexts,
                encodingFormat: "float"
            )
            request.httpBody = try JSONEncoder().encode(body)

            logger.debug("[Embeddings] Requesting remote embeddings from \(endpoint.absoluteString, privacy: .public), count=\(trimmedTexts.count)")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logger.error("[Embeddings] Remote embeddings returned a non-HTTP response")
                return []
            }
            guard (200..<300).contains(http.statusCode) else {
                let preview = String(data: data.prefix(800), encoding: .utf8) ?? ""
                logger.error("[Embeddings] Remote embeddings HTTP \(http.statusCode). Body: \(preview, privacy: .public)")
                return []
            }

            let decoded = try JSONDecoder().decode(RemoteEmbeddingResponse.self, from: data)
            let sorted = decoded.data.sorted { $0.index < $1.index }
            guard sorted.count == trimmedTexts.count else {
                logger.error("[Embeddings] Remote embeddings count mismatch. expected=\(trimmedTexts.count) actual=\(sorted.count)")
                return []
            }

            return sorted.map { item in
                fitToTargetDimension(l2Normalize(item.embedding), to: targetDimension)
            }
        } catch {
            logger.error("[Embeddings] Remote embeddings failed: \(String(reflecting: error), privacy: .public)")
            return []
        }
    }

    private static func remoteEmbeddingsEndpoint(from baseURLString: String) throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            throw URLError(.badURL)
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/v1/embeddings"
        } else if path.hasSuffix("embeddings") {
            components.path = "/" + path
        } else {
            components.path = "/" + path + "/embeddings"
        }

        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    // MARK: - Helpers

    private static func l2Normalize(_ v: [Float]) -> [Float] {
        let sumSquares = v.reduce(0.0) { $0 + Double($1) * Double($1) }
        let norm = max(1e-12, sqrt(sumSquares))
        if norm == 0 { return v }
        return v.map { $0 / Float(norm) }
    }

    private static func fitToTargetDimension(_ v: [Float], to target: Int) -> [Float] {
        if v.count == target { return v }
        if v.count > target {
            logger.warning("[Embeddings] Truncating vector from \(v.count) to \(target) dimensions")
            return Array(v.prefix(target))
        }

        logger.warning("[Embeddings] Padding vector from \(v.count) to \(target) dimensions with zeros")
        var out = v
        out.append(contentsOf: Array(repeating: 0.0, count: target - v.count))
        return out
    }

    // MARK: - Validation

    private static func validateEmbedding(_ embedding: [Float], source: String, text: String? = nil, url: String? = nil) {
        guard !embedding.isEmpty else {
            logger.error("[Embeddings] Empty embedding generated for \(source)")
            return
        }

        let hasInvalidValues = embedding.contains { $0.isNaN || $0.isInfinite }
        if hasInvalidValues {
            logger.error("[Embeddings] Invalid values (NaN/Inf) in embedding for \(source)")
        }

        let magnitude = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        let magnitudeDeviation = abs(magnitude - 1.0)
        if magnitudeDeviation > 0.1 {
            logger.warning("[Embeddings] Embedding magnitude \(magnitude, format: .fixed(precision: 3)) deviates significantly from 1.0 for \(source)")
        }

        logger.debug("[Embeddings] Validated \(source) embedding: dims=\(embedding.count), magnitude=\(magnitude, format: .fixed(precision: 3))")
    }

    private static func memorySnapshotSummary() -> String {
        let snapshot = Memory.snapshot()
        return "active=\(snapshot.activeMemory) cache=\(snapshot.cacheMemory) peak=\(snapshot.peakMemory)"
    }

    private static func configureTextCache(for texts: [String]) {
        let longestTextLength = texts.lazy.map(\.count).max() ?? 0
        let shortBatchMinimumCount = max(2, min(textEmbeddingBatchSize, 8))

        let requestedLimit: Int
        let policyName: String
        if longestTextLength > longTextCharacterThreshold {
            requestedLimit = longBatchTextCacheLimit
            policyName = "long-text"
        } else if texts.count >= shortBatchMinimumCount,
                  longestTextLength <= shortTextCharacterLimit {
            requestedLimit = shortBatchTextCacheLimit
            policyName = "short-batch"
        } else {
            requestedLimit = normalTextCacheLimit
            policyName = "normal"
        }

        let effectiveLimit = effectiveTextCacheLimit(requestedLimit)
        applyTextCacheLimit(
            effectiveLimit,
            clearExistingCache: Memory.snapshot().cacheMemory > effectiveLimit
        )
        logger.debug("[Embeddings] Text cache policy=\(policyName, privacy: .public) limitMiB=\(effectiveLimit / mebibyte) count=\(texts.count) longestCharacters=\(longestTextLength)")
    }

    private static func effectiveTextCacheLimit(_ requestedLimit: Int) -> Int {
        cachePolicyLock.lock()
        defer { cachePolicyLock.unlock() }
        return memoryPressureConstrained
            ? min(requestedLimit, memoryPressureTextCacheLimit)
            : requestedLimit
    }

    private static func applyTextCacheLimit(_ limit: Int, clearExistingCache: Bool) {
        Memory.cacheLimit = limit
        if clearExistingCache {
            Memory.clearCache()
        }
    }

    private static func releaseGPUResources(for modelName: String) {
        logger.info("[Embeddings] \(modelName, privacy: .public) pre-cleanup snapshot: \(memorySnapshotSummary(), privacy: .public)")
        Stream.defaultStream(Device.gpu).synchronize()
        Memory.cacheLimit = 0
        Memory.clearCache()
        Stream.defaultStream(Device.gpu).synchronize()
        logger.info("[Embeddings] \(modelName, privacy: .public) post-cleanup snapshot: \(memorySnapshotSummary(), privacy: .public)")
    }

    // MARK: - Unload

    static func unloadTextModel() {
        if sharedTextEmbeddings != nil {
            sharedTextEmbeddings = nil
            releaseGPUResources(for: "Text embedding model")
            cachePolicyLock.lock()
            memoryPressureConstrained = false
            cachePolicyLock.unlock()
            logger.info("[Embeddings] Unloaded text embedding model and explicitly cleared GPU cache")
        }
    }

    static func unloadImageModel() async {
        await imageEngine.unload()
    }

    static func unloadAll() async {
        unloadTextModel()
        await unloadImageModel()
    }
}
