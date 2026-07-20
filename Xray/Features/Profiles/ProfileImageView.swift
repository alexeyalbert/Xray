//
//  ProfileImageView.swift
//  Xray
//

import AppKit
import Kingfisher
import os
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
private typealias PlatformImage = NSImage
#else
private typealias PlatformImage = UIImage
#endif

private actor ProfileImageURLResolver {
    static let shared = ProfileImageURLResolver()

    private let webBearerToken = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    private let userByScreenNameQueryID = "IGgvgiOx4QZndDHuD3x9TQ"
    private var cache = BoundedLRUCache<String, URL>(capacity: 2_000)
    private var failedLookups = BoundedLRUCache<String, Bool>(capacity: 2_000)
    private var inFlightLookups: [String: Task<URL?, Never>] = [:]
    private let failedLookupTTL: TimeInterval = 10 * 60

    func currentProfileImageURL(for username: String) async -> URL? {
        let normalized = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        if let cached = cache.value(forKey: normalized) {
            return cached
        }
        if failedLookups.value(forKey: normalized) != nil { return nil }
        if let existingLookup = inFlightLookups[normalized] {
            return await existingLookup.value
        }

        let lookup = Task { [weak self] in
            await self?.fetchCurrentProfileImageURL(for: normalized)
        }
        inFlightLookups[normalized] = lookup
        let resolved = await lookup.value
        inFlightLookups[normalized] = nil

        if let resolved {
            cache.insert(resolved, forKey: normalized)
            failedLookups.removeValue(forKey: normalized)
            return resolved
        }

        failedLookups.insert(
            true,
            forKey: normalized,
            expiresAt: Date().addingTimeInterval(failedLookupTTL)
        )
        return nil
    }

    private func fetchCurrentProfileImageURL(for username: String) async -> URL? {
        if let apiURL = await fetchProfileImageURLFromXAPI(for: username) {
            return apiURL
        }

        guard let pageURL = URL(string: "https://x.com/\(username)/photo") else { return nil }
        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<400).contains(http.statusCode)
            else {
                return nil
            }

            if isRasterImageMIMEType(http.mimeType),
               PlatformImage(data: data) != nil {
                return http.url ?? pageURL
            }

            guard let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            if let url = extractProfileImageURL(from: html) {
                return url
            }
        } catch {
            return nil
        }

        return nil
    }

    private func fetchProfileImageURLFromXAPI(for username: String) async -> URL? {
        guard let guestToken = await fetchGuestToken(),
              let apiURL = userByScreenNameAPIURL(for: username)
        else {
            return nil
        }

        var request = URLRequest(url: apiURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(webBearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(guestToken, forHTTPHeaderField: "x-guest-token")
        request.setValue("yes", forHTTPHeaderField: "x-twitter-active-user")
        request.setValue("en", forHTTPHeaderField: "x-twitter-client-language")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let url = extractProfileImageURL(fromJSONData: data)
            else {
                return nil
            }
            return url
        } catch {
            return nil
        }
    }

    private func fetchGuestToken() async -> String? {
        guard let url = URL(string: "https://api.x.com/1.1/guest/activate.json") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(webBearerToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let guestToken = json["guest_token"] as? String
            else {
                return nil
            }
            return guestToken
        } catch {
            return nil
        }
    }

    private func userByScreenNameAPIURL(for username: String) -> URL? {
        var components = URLComponents(string: "https://api.x.com/graphql/\(userByScreenNameQueryID)/UserByScreenName")
        components?.queryItems = [
            URLQueryItem(name: "variables", value: jsonString([
                "screen_name": username
            ])),
            URLQueryItem(name: "features", value: jsonString([
                "hidden_profile_subscriptions_enabled": true,
                "profile_label_improvements_pcf_label_in_post_enabled": true,
                "responsive_web_profile_redirect_enabled": false,
                "rweb_tipjar_consumption_enabled": true,
                "verified_phone_label_enabled": false,
                "subscriptions_verification_info_is_identity_verified_enabled": true,
                "subscriptions_verification_info_verified_since_enabled": true,
                "highlights_tweets_tab_ui_enabled": true,
                "responsive_web_twitter_article_notes_tab_enabled": true,
                "subscriptions_feature_can_gift_premium": true,
                "creator_subscriptions_tweet_preview_api_enabled": true,
                "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
                "responsive_web_graphql_timeline_navigation_enabled": true
            ])),
            URLQueryItem(name: "fieldToggles", value: jsonString([
                "withPayments": false,
                "withAuxiliaryUserLabels": false
            ]))
        ]
        return components?.url
    }

    private func jsonString(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private func extractProfileImageURL(fromJSONData data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return firstProfileImageURL(in: json)
    }

    private func firstProfileImageURL(in value: Any) -> URL? {
        if let dictionary = value as? [String: Any] {
            if let avatar = dictionary["avatar"] as? [String: Any],
               let imageURL = avatar["image_url"] as? String,
               let url = normalizedProfileImageURL(from: imageURL) {
                return url
            }

            for key in ["profile_image_url_https", "profile_image_url", "image_url"] {
                if let imageURL = dictionary[key] as? String,
                   let url = normalizedProfileImageURL(from: imageURL) {
                    return url
                }
            }

            for nested in dictionary.values {
                if let url = firstProfileImageURL(in: nested) {
                    return url
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let url = firstProfileImageURL(in: nested) {
                    return url
                }
            }
        }

        return nil
    }

    private func normalizedProfileImageURL(from string: String) -> URL? {
        let upgraded = string
            .replacingOccurrences(of: "_normal.", with: "_400x400.")
            .replacingOccurrences(of: "_bigger.", with: "_400x400.")
            .replacingOccurrences(of: "_mini.", with: "_400x400.")
        guard let url = URL(string: upgraded),
              isUsableProfileImageURL(url)
        else {
            return nil
        }
        return url
    }

    private func extractProfileImageURL(from html: String) -> URL? {
        let decoded = html
            .replacingOccurrences(of: #"\\/"#, with: "/")
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\u002F"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/")
            .replacingOccurrences(of: #"\\u0026"#, with: "&")
            .replacingOccurrences(of: #"\u0026"#, with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")

        let patterns = [
            #"https://pbs\.twimg\.com/profile_images/[^"'<>\s\\]+"#,
            #"https://pbs\.twimg\.com/[^"'<>\s\\]+(?:jpg|jpeg|png|webp)[^"'<>\s\\]*"#,
            #"<img[^>]+src=["']([^"']+)["']"#
        ]

        var candidates: [URL] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
            let matches = regex.matches(in: decoded, range: range)
            for match in matches {
                let resultRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard let matchRange = Range(resultRange, in: decoded) else { continue }
                let candidate = String(decoded[matchRange])
                    .replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: candidate),
                      isUsableProfileImageURL(url),
                      !candidates.contains(url)
                else {
                    continue
                }
                candidates.append(url)
            }
        }

        return candidates.sorted { lhs, rhs in
            profileImageScore(lhs) > profileImageScore(rhs)
        }.first
    }

    private func profileImageScore(_ url: URL) -> Int {
        let value = url.absoluteString.lowercased()
        var score = 0
        if value.contains("/profile_images/") { score += 100 }
        if value.contains("_400x400") { score += 20 }
        if value.contains("_normal") { score -= 10 }
        if value.contains("default_profile") { score -= 50 }
        return score
    }

    private func isUsableProfileImageURL(_ url: URL) -> Bool {
        guard url.host?.hasSuffix("twimg.com") == true else { return false }
        let value = url.absoluteString.lowercased()
        guard !value.contains("/emoji/"),
              !value.contains("twemoji"),
              !value.hasSuffix(".svg")
        else {
            return false
        }
        return value.contains(".jpg")
            || value.contains(".jpeg")
            || value.contains(".png")
            || value.contains(".webp")
    }

    private func isRasterImageMIMEType(_ mimeType: String?) -> Bool {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg", "image/png", "image/webp":
            return true
        default:
            return false
        }
    }
}

struct ProfileImageView: View {
    let url: URL
    let username: String
    let shape: ProfileImageShape
    let size: CGFloat
    let squareCornerRadius: CGFloat

    @Environment(\.displayScale) private var displayScale
    @AppStorage(MediaViewerSettings.animateThumbnailAppearanceKey) private var animateThumbnailAppearance: Bool = true
    @State private var currentURL: URL?
    @State private var hasRevealedProfileImage = false
    @State private var loadAttempt = 0
    private let logger = Logger(subsystem: "com.alexeyalbert.Xray", category: "ProfileImageView")

    init(
        url: URL,
        username: String,
        shape: ProfileImageShape,
        size: CGFloat,
        squareCornerRadius: CGFloat = 10
    ) {
        self.url = url
        self.username = username
        self.shape = shape
        self.size = size
        self.squareCornerRadius = squareCornerRadius
        _currentURL = State(initialValue: nil)
    }

    private var clipShape: AvatarClipShape {
        AvatarClipShape(shape: shape, size: size, squareCornerRadius: squareCornerRadius)
    }

    private var profileRevealOpacity: Double {
        guard animateThumbnailAppearance else { return 1 }
        return hasRevealedProfileImage ? 1 : 0.01
    }

    private var profileRevealScale: CGFloat {
        guard animateThumbnailAppearance else { return 1 }
        return hasRevealedProfileImage ? 1 : 0.72
    }

    var body: some View {
        ZStack {
            placeholderView

            if let currentURL {
                KFImage(currentURL)
                    .onSuccess { _ in
                        revealProfileImage()
                    }
                    .onFailure { error in
                        logger.debug("Profile image load failed for @\(username, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        fallBackToStoredURLIfNeeded()
                    }
                    .setProcessor(DownsamplingImageProcessor(size: processorSize))
                    .scaleFactor(displayScale)
                    .backgroundDecode()
                    .fade(duration: 0.15)
                    .resizable()
                    .scaledToFill()
                    .opacity(profileRevealOpacity)
                    .scaleEffect(profileRevealScale)
                    .id("\(currentURL.absoluteString)-\(loadAttempt)")
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: hasRevealedProfileImage)
        .onAppear {
            guard currentURL != nil, !hasRevealedProfileImage else { return }
            loadAttempt += 1
        }
        .task(id: "\(url.absoluteString)-\(username)") {
            currentURL = nil
            hasRevealedProfileImage = false
            loadAttempt += 1
            await loadPreferredProfileImage()
        }
    }

    private var placeholderView: some View {
        Image(systemName: shape == .square ? "person.crop.square.fill" : "person.crop.circle.fill")
            .resizable()
            .scaledToFill()
            .foregroundStyle(.secondary)
    }

    private func revealProfileImage() {
        guard !hasRevealedProfileImage else { return }
        hasRevealedProfileImage = true
    }

    private var processorSize: CGSize {
        let pixelSize = max(size * displayScale, 1)
        return CGSize(width: pixelSize, height: pixelSize)
    }

    private func loadPreferredProfileImage() async {
        currentURL = url

        if isHighResolutionProfileImageURL(url) {
            return
        }

        let resolverTask = Task {
            await ProfileImageURLResolver.shared.currentProfileImageURL(for: username)
        }

        let quickResolution = await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                await resolverTask.value
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(350))
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }

        if let quickResolution {
            if quickResolution != url {
                logger.info("Resolved high-resolution profile image for @\(username, privacy: .public) from \(quickResolution.absoluteString, privacy: .public)")
            }
            currentURL = quickResolution
            return
        }

        if let preferredURL = await resolverTask.value {
            if preferredURL != url {
                logger.info("Resolved high-resolution profile image for @\(username, privacy: .public) from \(preferredURL.absoluteString, privacy: .public)")
            }
            currentURL = preferredURL
        }
    }

    private func isHighResolutionProfileImageURL(_ url: URL) -> Bool {
        guard url.host?.hasSuffix("twimg.com") == true,
              url.path.contains("/profile_images/")
        else {
            return false
        }

        let value = url.absoluteString.lowercased()
        return value.contains("_400x400.")
            || value.contains("_x96.")
            || value.contains("_200x200.")
            || value.contains("_reasonably_small.")
    }

    private func fallBackToStoredURLIfNeeded() {
        guard currentURL != url else { return }
        currentURL = url
    }
}

private struct AvatarClipShape: Shape {
    let shape: ProfileImageShape
    let size: CGFloat
    let squareCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle:
            return Circle().path(in: rect)
        case .square:
            return RoundedRectangle(cornerRadius: squareCornerRadius, style: .continuous).path(in: rect)
        }
    }
}

