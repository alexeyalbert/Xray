import CoreGraphics
import Foundation

nonisolated struct Media: Codable, Identifiable, Sendable {
    let type: String
    let thumbnail: URL
    let original: URL
    let width: Double?
    let height: Double?
    var id: URL { original }

    var isVideo: Bool {
        type.lowercased().contains("video")
    }

    var isAnimatedGIF: Bool {
        type.lowercased().contains("gif")
    }

    var isPlayableVideo: Bool {
        isVideo || isAnimatedGIF
    }

    var feedAspectRatio: CGFloat? {
        guard let width,
              let height,
              width > 0,
              height > 0
        else {
            return nil
        }

        return CGFloat(width / height)
    }

    var hasDimensions: Bool {
        feedAspectRatio != nil
    }

    func withDimensions(width: Double, height: Double) -> Media {
        Media(type: type, thumbnail: thumbnail, original: original, width: width, height: height)
    }

    enum CodingKeys: String, CodingKey {
        case type, thumbnail, original, width, height
    }

    init(type: String, thumbnail: URL, original: URL, width: Double? = nil, height: Double? = nil) {
        self.type = type
        self.thumbnail = thumbnail
        self.original = original
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        let rawThumb = try container.decode(URL.self, forKey: .thumbnail)
        // Replace the last 5 characters with "small" as requested (e.g., ...name=thumb -> ...name=small)
        let smallThumb: URL = {
            let s = rawThumb.absoluteString
            guard s.count >= 5 else { return rawThumb }
            let replaced = s.dropLast(5) + "small"
            return URL(string: String(replaced)) ?? rawThumb
        }()
        self.thumbnail = smallThumb
        self.original = try container.decode(URL.self, forKey: .original)
        self.width = try container.decodeIfPresent(Double.self, forKey: .width)
        self.height = try container.decodeIfPresent(Double.self, forKey: .height)
    }
}
