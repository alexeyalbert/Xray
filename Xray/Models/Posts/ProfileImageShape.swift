import Foundation

nonisolated enum ProfileImageShape: String, Codable, Sendable {
    case circle = "Circle"
    case square = "Square"
}

nonisolated func upgradedTwitterProfileImageURL(_ url: URL) -> URL {
    guard url.host?.hasSuffix("twimg.com") == true,
          url.path.contains("/profile_images/")
    else {
        return url
    }

    let upgraded = url.absoluteString
        .replacingOccurrences(of: "_normal.", with: "_400x400.")
        .replacingOccurrences(of: "_bigger.", with: "_400x400.")
        .replacingOccurrences(of: "_mini.", with: "_400x400.")

    return URL(string: upgraded) ?? url
}
