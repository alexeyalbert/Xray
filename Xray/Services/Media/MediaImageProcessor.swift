//
//  MediaImageProcessor.swift
//  Xray
//
//  Created by Alexey Albert on 2026-05-16.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum MediaImageProcessor {
    enum EmbeddingImageDataResult: Sendable {
        case success(Data)
        case unavailable(statusCode: Int)
        case retryableFailure
    }

    static let maxTopicImages = 8

    private static let targetShortestSide: CGFloat = 200
    private static let jpegQuality: CGFloat = 0.25

    nonisolated static func isVisualMedia(_ media: Media) -> Bool {
        let type = media.type.lowercased()
        return type.contains("photo") || type.contains("image") || type.contains("video") || type.contains("gif")
    }

    nonisolated static func isImageSearchMedia(_ media: Media) -> Bool {
        isVisualMedia(media)
    }

    static func smallImageURL(for media: Media) -> URL {
        let source = media.isPlayableVideo ? media.thumbnail : media.original
        guard var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            return source
        }

        var queryItems = components.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.name == "name" }) {
            queryItems[index].value = "small"
        } else {
            queryItems.append(URLQueryItem(name: "name", value: "small"))
        }
        components.queryItems = queryItems
        return components.url ?? source
    }

    static func processedJPEGData(for media: Media) async -> Data? {
        await processedJPEGData(from: smallImageURL(for: media))
    }

    /// Fetches image bytes for vision embedding without applying an extra lossy resize.
    /// Qwen3-VL owns its model-specific resize and patch alignment during preprocessing.
    static func embeddingImageData(for media: Media) async -> Data? {
        guard case .success(let data) = await embeddingImageDataResult(for: media) else {
            return nil
        }
        return data
    }

    static func embeddingImageDataResult(for media: Media) async -> EmbeddingImageDataResult {
        let source = smallImageURL(for: media)
        switch await SharedImagePipeline.imageDataResult(for: source) {
        case .success(let data):
            return .success(data)
        case .unavailable(let statusCode) where media.isPlayableVideo || source == media.original:
            return .unavailable(statusCode: statusCode)
        case .unavailable, .retryableFailure:
            break
        }

        // Video and GIF originals are playable files, not image-model input. Their
        // poster thumbnail is the only source that should be retried or embedded.
        guard !media.isPlayableVideo else { return .retryableFailure }
        guard source != media.original else { return .retryableFailure }
        switch await SharedImagePipeline.imageDataResult(for: media.original) {
        case .success(let data):
            return .success(data)
        case .unavailable(let statusCode):
            return .unavailable(statusCode: statusCode)
        case .retryableFailure:
            return .retryableFailure
        }
    }

    static func processedJPEGData(from url: URL) async -> Data? {
        guard let data = await SharedImagePipeline.imageData(for: url) else {
            return nil
        }
        return downsampledJPEGData(from: data)
    }

    static func processedImageDataURL(from url: URL) async -> String? {
        guard let jpegData = await processedJPEGData(from: url) else {
            return nil
        }
        return jpegDataDataURL(jpegData)
    }

    static func jpegDataDataURL(_ jpegData: Data) -> String {
        "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }

    static func contactSheetJPEGData(from imageDataItems: [Data]) -> Data? {
        guard !imageDataItems.isEmpty else { return nil }
        guard imageDataItems.count > 1 else { return imageDataItems.first }

        let images = imageDataItems.compactMap { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard !images.isEmpty else { return nil }
        guard images.count > 1 else { return imageDataItems.first }

        let columns = Int(ceil(sqrt(Double(images.count))))
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let maxCellSide = images
            .map { max($0.width, $0.height) }
            .max() ?? Int(targetShortestSide)
        let cellSize = max(1, maxCellSide)
        let width = columns * cellSize
        let height = rows * cellSize

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            let cellRect = CGRect(
                x: column * cellSize,
                y: height - ((row + 1) * cellSize),
                width: cellSize,
                height: cellSize
            ).insetBy(dx: 2, dy: 2)
            context.draw(image, in: aspectFitRect(imageSize: CGSize(width: image.width, height: image.height), in: cellRect))
        }

        guard let sheet = context.makeImage() else { return nil }
        return jpegData(from: sheet)
    }

    private static func downsampledJPEGData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let shortestSide = min(pixelWidth, pixelHeight)
        let longestSide = max(pixelWidth, pixelHeight)
        guard shortestSide > 0, longestSide > 0 else {
            return nil
        }

        let scale = min(1, targetShortestSide / shortestSide)
        let targetLongestSide = max(1, Int((longestSide * scale).rounded()))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetLongestSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return jpegData(from: image)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let jpegOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(destination, image, jpegOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}
