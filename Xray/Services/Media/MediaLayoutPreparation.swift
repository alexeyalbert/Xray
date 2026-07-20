import CoreGraphics
import Foundation

struct StableMediaLayoutPreparation: Sendable {
    let posts: [Post]
    let updatedPosts: [Post]
}

func preparePostsForStableMediaLayout(_ posts: [Post]) async -> StableMediaLayoutPreparation {
    var prepared = posts
    var updated: [Post] = []
    let batchSize = 16

    var startIndex = posts.startIndex
    while startIndex < posts.endIndex {
        let endIndex = posts.index(startIndex, offsetBy: batchSize, limitedBy: posts.endIndex) ?? posts.endIndex
        let batch = posts[startIndex..<endIndex]

        await withTaskGroup(of: (Int, Post, Bool).self) { group in
            for index in batch.indices {
                let post = posts[index]
                group.addTask {
                    let result = await postWithResolvedMediaDimensions(post)
                    return (index, result.post, result.didUpdate)
                }
            }

            for await result in group {
                prepared[result.0] = result.1
                if result.2 {
                    updated.append(result.1)
                }
            }
        }

        startIndex = endIndex
    }

    return StableMediaLayoutPreparation(posts: prepared, updatedPosts: updated)
}

private func postWithResolvedMediaDimensions(_ post: Post) async -> (post: Post, didUpdate: Bool) {
    async let mediaResult = mediaWithResolvedDimensions(post.media)
    async let quotedResult = quotedPostWithResolvedMediaDimensions(post.quoted_post)

    let resolvedMedia = await mediaResult
    let resolvedQuoted = await quotedResult
    let didUpdate = resolvedMedia.didUpdate || resolvedQuoted.didUpdate

    guard didUpdate else {
        return (post, false)
    }

    return (
        Post(
            id: post.id,
            created_at: post.created_at,
            full_text: post.full_text,
            media: resolvedMedia.media,
            article: post.article,
            links: post.links,
            quoted_post: resolvedQuoted.quotedPost,
            screen_name: post.screen_name,
            name: post.name,
            profile_image_url: post.profile_image_url,
            profile_image_shape: post.profile_image_shape,
            url: post.url,
            text_embedding: post.text_embedding,
            img_embedding: post.img_embedding,
            primary_topic: post.primary_topic,
            secondary_topics: post.secondary_topics,
            bookmark_import_generation: post.bookmark_import_generation,
            bookmark_order: post.bookmark_order
        ),
        true
    )
}

private func quotedPostWithResolvedMediaDimensions(_ quotedPost: QuotedPost?) async -> (quotedPost: QuotedPost?, didUpdate: Bool) {
    guard let quotedPost else {
        return (nil, false)
    }

    let resolved = await mediaWithResolvedDimensions(quotedPost.media)
    guard resolved.didUpdate else {
        return (quotedPost, false)
    }

    return (
        QuotedPost(
            id: quotedPost.id,
            created_at: quotedPost.created_at,
            full_text: quotedPost.full_text,
            media: resolved.media,
            screen_name: quotedPost.screen_name,
            name: quotedPost.name,
            profile_image_url: quotedPost.profile_image_url,
            profile_image_shape: quotedPost.profile_image_shape,
            url: quotedPost.url
        ),
        true
    )
}

private func mediaWithResolvedDimensions(_ media: [Media]?) async -> (media: [Media]?, didUpdate: Bool) {
    guard let media else {
        return (nil, false)
    }

    var resolved: [Media] = []
    var didUpdate = false
    resolved.reserveCapacity(media.count)

    for item in media {
        if item.hasDimensions {
            resolved.append(item)
            continue
        }

        if let size = await MediaDimensionResolver.shared.dimensions(for: item) {
            resolved.append(item.withDimensions(width: Double(size.width), height: Double(size.height)))
            didUpdate = true
        } else {
            resolved.append(item)
        }
    }

    return (resolved, didUpdate)
}

private actor MediaDimensionResolver {
    static let shared = MediaDimensionResolver()

    private var cache = BoundedLRUCache<URL, CGSize>(capacity: 5_000)

    func dimensions(for media: Media) async -> CGSize? {
        if let width = media.width,
           let height = media.height,
           width > 0,
           height > 0 {
            return CGSize(width: width, height: height)
        }

        if let cached = cache.value(forKey: media.thumbnail) {
            return cached
        }

        if let size = await Self.fetchImageDimensions(from: media.thumbnail) {
            cache.insert(size, forKey: media.thumbnail)
            return size
        }

        guard media.thumbnail != media.original,
              !media.isPlayableVideo,
              let size = await Self.fetchImageDimensions(from: media.original)
        else {
            return nil
        }

        cache.insert(size, forKey: media.thumbnail)
        return size
    }

    private static func fetchImageDimensions(from url: URL) async -> CGSize? {
        await SharedImagePipeline.imageDimensions(for: url)
    }
}
