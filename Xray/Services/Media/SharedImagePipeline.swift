import Foundation
import ImageIO
import Kingfisher
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ImageCacheDebugSnapshot: Sendable {
    let cacheType: CacheType
    let diskFileURL: URL?
    let diskFileBytes: Int64?
}

enum ImageDataFetchResult: Sendable {
    case success(Data)
    case unavailable(statusCode: Int)
    case retryableFailure
}

private actor ImageMetadataParser {
    static let shared = ImageMetadataParser()

    func dimensions(from data: Data) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            width > 0,
            height > 0
        else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}

private actor LinkPreviewImageResolver {
    static let shared = LinkPreviewImageResolver()

    private var resolvedURLs = BoundedLRUCache<URL, URL>(capacity: 2_000)
    private var unresolvedURLs = BoundedLRUCache<URL, Bool>(capacity: 2_000)
    private let unresolvedURLTTL: TimeInterval = 10 * 60

    func resolveImageURL(for pageURL: URL) async -> URL? {
        if let resolvedURL = resolvedURLs.value(forKey: pageURL) {
            return resolvedURL
        }
        guard unresolvedURLs.value(forKey: pageURL) == nil else { return nil }

        guard let resolvedURL = await fetchImageURL(for: pageURL) else {
            unresolvedURLs.insert(
                true,
                forKey: pageURL,
                expiresAt: Date().addingTimeInterval(unresolvedURLTTL)
            )
            return nil
        }

        resolvedURLs.insert(resolvedURL, forKey: pageURL)
        unresolvedURLs.removeValue(forKey: pageURL)
        return resolvedURL
    }

    private func fetchImageURL(for pageURL: URL) async -> URL? {
        guard pageURL.scheme == "http" || pageURL.scheme == "https" else {
            return nil
        }

        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<400).contains(http.statusCode),
                !data.isEmpty,
                data.count <= 2 * 1024 * 1024,
                let html = String(data: data, encoding: .utf8),
                let rawImageURL = Self.openGraphImageURL(in: html)?.replacingOccurrences(of: "&amp;", with: "&"),
                let imageURL = URL(string: rawImageURL, relativeTo: pageURL)?.absoluteURL,
                imageURL.scheme == "http" || imageURL.scheme == "https"
            else {
                return nil
            }

            return imageURL
        } catch {
            return nil
        }
    }

    nonisolated private static func openGraphImageURL(in html: String) -> String? {
        let metaPattern = #"<meta\b[^>]*>"#
        let attributePattern = #"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#

        guard
            let metaRegex = try? NSRegularExpression(pattern: metaPattern, options: .caseInsensitive),
            let attributeRegex = try? NSRegularExpression(pattern: attributePattern, options: .caseInsensitive)
        else {
            return nil
        }

        let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let preferredKeys = ["og:image", "twitter:image", "twitter:image:src"]
        var valuesByKey: [String: String] = [:]

        for metaMatch in metaRegex.matches(in: html, range: htmlRange) {
            guard let metaTagRange = Range(metaMatch.range, in: html) else { continue }
            let tag = String(html[metaTagRange])
            let tagRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            var attributes: [String: String] = [:]

            for match in attributeRegex.matches(in: tag, range: tagRange) {
                guard
                    let keyRange = Range(match.range(at: 1), in: tag),
                    let valueRange = (2...4)
                        .lazy
                        .compactMap({ Range(match.range(at: $0), in: tag) })
                        .first
                else {
                    continue
                }

                attributes[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
            }

            guard
                let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                preferredKeys.contains(key),
                let content = attributes["content"],
                !content.isEmpty
            else {
                continue
            }

            valuesByKey[key] = content
        }

        return preferredKeys.lazy.compactMap { valuesByKey[$0] }.first
    }
}

enum SharedImagePipeline {
    private static let sessionCachePrefix = "com.alexeyalbert.Xray.PostThumbnailSession"
    private static let sessionCacheRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("XrayPostThumbnailCaches", isDirectory: true)
    private static let sessionCacheName = "\(sessionCachePrefix).\(UUID().uuidString.lowercased())"

    private static let cache: ImageCache = {
        purgePreviousSessionCaches()

        let cache: ImageCache
        do {
            cache = try ImageCache(name: sessionCacheName, cacheDirectoryURL: sessionCacheRootURL)
        } catch {
            let fallbackRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("XrayPostThumbnailFallbackCaches", isDirectory: true)
            cache = try! ImageCache(name: sessionCacheName, cacheDirectoryURL: fallbackRootURL)
        }

        cache.memoryStorage.config.totalCostLimit = 256 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 512
        cache.memoryStorage.config.expiration = .seconds(90)
        cache.memoryStorage.config.cleanInterval = 15
        cache.diskStorage.config.sizeLimit = 512 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(2)
        return cache
    }()

    private static let requestModifier = AnyModifier { request in
        var request = request
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static let sourcePreservingCacheSerializer: any CacheSerializer = {
        var serializer = DefaultCacheSerializer.default
        serializer.preferCacheOriginalData = true
        return serializer
    }()

    private static let metadataSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    static var thumbnailCache: ImageCache { cache }
    static var thumbnailCacheSerializer: any CacheSerializer { sourcePreservingCacheSerializer }
    static var sharedRequestModifier: AnyModifier { requestModifier }

    // Bounded-size downsampling processor. Full-size thumbnails are the dominant cost:
    // they fill the memory cache (only ~16 fit) and each miss re-decodes a large image on
    // the main thread. Downsampling to a fixed longest-side caps per-image memory and decode
    // cost. A single fixed size keeps the processor identifier (and thus the cache key) stable
    // across mounts so isThumbnailCached() checks the right key.
    private static let downsamplingThumbnailProcessor = DownsamplingImageProcessor(
        size: CGSize(width: 800, height: 800)
    )

    static var thumbnailProcessor: any ImageProcessor {
        downsamplingThumbnailProcessor
    }

    static var thumbnailProcessorIdentifier: String { thumbnailProcessor.identifier }

    static func configureKingfisherCaching() {
        _ = cache

        ImageCache.default.memoryStorage.config.totalCostLimit = 64 * 1024 * 1024
        ImageCache.default.memoryStorage.config.countLimit = 200
        ImageCache.default.memoryStorage.config.expiration = .seconds(120)
        ImageCache.default.memoryStorage.config.cleanInterval = 30
        ImageCache.default.diskStorage.config.sizeLimit = 256 * 1024 * 1024
        ImageCache.default.diskStorage.config.expiration = .days(7)
        ImageCache.default.cleanExpiredMemoryCache()

        KingfisherManager.shared.defaultOptions = [
            .memoryCacheExpiration(.seconds(120)),
            .diskCacheExpiration(.days(7)),
            .requestModifier(requestModifier)
        ]
    }

    static func imageDimensions(for url: URL) async -> CGSize? {
        guard url.scheme == "http" || url.scheme == "https" else {
            return nil
        }

        guard let data = await fetchData(for: url) else { return nil }
        return await ImageMetadataParser.shared.dimensions(from: data)
    }

    static func mediaData(for url: URL) async -> Data? {
        guard url.scheme == "http" || url.scheme == "https" else {
            return nil
        }

        return await fetchData(for: url)
    }

    static func imageData(for url: URL) async -> Data? {
        await mediaData(for: url)
    }

    static func imageDataResult(for url: URL) async -> ImageDataFetchResult {
        guard url.scheme == "http" || url.scheme == "https" else {
            return .retryableFailure
        }

        return await fetchDataResult(for: url)
    }

    static func linkPreviewFallbackImageURL(for pageURL: URL) async -> URL? {
        await LinkPreviewImageResolver.shared.resolveImageURL(for: pageURL)
    }

    static func isThumbnailCached(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        return cache.imageCachedType(
            forKey: url.cacheKey,
            processorIdentifier: thumbnailProcessorIdentifier
        ).cached
    }

    static func pruneThumbnailFromMemory(for url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else {
            return
        }

        cache.removeImage(
            forKey: url.cacheKey,
            processorIdentifier: thumbnailProcessorIdentifier,
            fromMemory: true,
            fromDisk: false,
            callbackQueue: .untouch,
            completionHandler: nil
        )
        cache.removeImage(
            forKey: url.cacheKey,
            fromMemory: true,
            fromDisk: false,
            callbackQueue: .untouch,
            completionHandler: nil
        )
    }

    static func pruneThumbnailsFromMemory(for urls: some Sequence<URL>) {
        var didPrune = false
        for url in urls {
            guard url.scheme == "http" || url.scheme == "https" else {
                continue
            }
            didPrune = true
            cache.removeImage(
                forKey: url.cacheKey,
                processorIdentifier: thumbnailProcessorIdentifier,
                fromMemory: true,
                fromDisk: false,
                callbackQueue: .untouch,
                completionHandler: nil
            )
            cache.removeImage(
                forKey: url.cacheKey,
                fromMemory: true,
                fromDisk: false,
                callbackQueue: .untouch,
                completionHandler: nil
            )
        }

        if didPrune {
            cache.cleanExpiredMemoryCache()
        }
    }

    private static func fetchData(for url: URL) async -> Data? {
        guard case .success(let data) = await fetchDataResult(for: url) else {
            return nil
        }
        return data
    }

    private static func fetchDataResult(for url: URL) async -> ImageDataFetchResult {
        let request = configuredRequest(for: url)

        do {
            let (data, response) = try await metadataSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .retryableFailure
            }
            if http.statusCode == 404 || http.statusCode == 410 {
                return .unavailable(statusCode: http.statusCode)
            }
            guard (200..<400).contains(http.statusCode), !data.isEmpty else {
                return .retryableFailure
            }

            return .success(data)
        } catch {
            return .retryableFailure
        }
    }

    static func cacheDebugSnapshot(
        in cache: ImageCache = SharedImagePipeline.cache,
        for url: URL,
        processorIdentifier: String = DefaultImageProcessor.default.identifier
    ) -> ImageCacheDebugSnapshot? {
        guard url.scheme == "http" || url.scheme == "https" else {
            return nil
        }

        let cacheKey = url.cacheKey
        let cacheType = cache.imageCachedType(forKey: cacheKey, processorIdentifier: processorIdentifier)
        let diskFileURL = cache.cacheFileURLIfOnDisk(forKey: cacheKey, processorIdentifier: processorIdentifier)
        let diskFileBytes = diskFileURL.flatMap(fileSizeBytes(for:))
        return ImageCacheDebugSnapshot(cacheType: cacheType, diskFileURL: diskFileURL, diskFileBytes: diskFileBytes)
    }

    nonisolated private static func fileSizeBytes(for url: URL) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let number = attributes[.size] as? NSNumber {
                return number.int64Value
            }
            if let intValue = attributes[.size] as? Int64 {
                return intValue
            }
            if let intValue = attributes[.size] as? Int {
                return Int64(intValue)
            }
        } catch {
            return nil
        }

        return nil
    }

    private static func configuredRequest(for url: URL) -> URLRequest {
        requestModifier.modified(for: URLRequest(url: url)) ?? URLRequest(url: url)
    }

    private static func purgePreviousSessionCaches() {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: sessionCacheRootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let cacheDirectories = try fileManager.contentsOfDirectory(
                at: sessionCacheRootURL,
                includingPropertiesForKeys: nil
            )

            for directoryURL in cacheDirectories where directoryURL.lastPathComponent.hasPrefix(sessionCachePrefix) {
                try? fileManager.removeItem(at: directoryURL)
            }
        } catch {
            return
        }
    }
}
