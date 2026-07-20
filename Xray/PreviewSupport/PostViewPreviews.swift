//
//  PostViewPreviews.swift
//  Xray
//

import Foundation
import SwiftUI

#Preview("Post") {
    PostViewPreviewCard(post: PostViewPreviewData.textOnlyPost)
}

#Preview("Quote Post") {
    PostViewPreviewCard(post: PostViewPreviewData.quotedPost)
}

#Preview("Article Post") {
    PostViewPreviewCard(post: PostViewPreviewData.articlePost)
}

#Preview("Link Card Post") {
    PostViewPreviewCard(post: PostViewPreviewData.linkCardPost)
}

#Preview("PostView Gallery") {
    PostViewPreviewList()
}

private struct PostViewPreviewCard: View {
    let post: Post
    
    var body: some View {
        ScrollView {
            PostView(Post: post, isInteractive: false)
                .frame(width: 360)
                .padding(18)
        }
        .frame(width: 430, height: 900)
        .background(.regularMaterial)
    }
}

private struct PostViewPreviewList: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(PostViewPreviewData.posts, id: \.id) { post in
                    PostView(Post: post, isInteractive: false)
                        .frame(width: 360)
                }
            }
            .padding(18)
        }
        .frame(width: 430, height: 900)
        .background(.regularMaterial)
    }
}

private enum PostViewPreviewData {
    static let posts: [Post] = [
        textOnlyPost,
        linkCardPost,
        articlePost,
        photoPost,
        multiPhotoPost,
        videoPost,
        quotedPost,
        quotedMediaPost,
        quoteOnlyMediaPost,
        topicHeavyPost,
        emptyTextMediaPost
    ]
    
    private static let now = Date()
    
    static var textOnlyPost: Post {
        post(
            id: 1001,
            createdAt: now.addingTimeInterval(-95),
            text: "A short text-only post for spacing, author metadata, timestamps, and topic chips.",
            author: "Mira Chen",
            username: "mira",
            topics: ("SwiftUI", ["Prototyping", "Canvas"])
        )
    }
    
    static var linkCardPost: Post {
        Post(
            id: 2073898178978754995,
            created_at: now.addingTimeInterval(-86_400),
            full_text: "Some of the nation’s rich are letting AI teach their kids",
            media: nil,
            links: [
                PostLink(
                    url: url("https://t.co/8EU2UVJMMa"),
                    expanded_url: url("https://www.theverge.com/ai-artificial-intelligence/961505/wealthy-ai-schools-alpha-forge-prep"),
                    display_url: "theverge.com/ai-artificial-…",
                    card: LinkCard(
                        title: "Some of the nation’s rich are letting AI teach their kids",
                        description: "Who wouldn’t want to pay $75,000 for their kid to learn about putting glue on pizza?",
                        domain: "www.theverge.com",
                        vanity_url: "theverge.com",
                        image_url: url("https://pbs.twimg.com/card_img/2073735790698323968/riUa4JIM?format=jpg&name=800x419"),
                        image_alt: "Photo collage of a pixelated student at a desk.",
                        image_width: 800,
                        image_height: 419
                    )
                )
            ],
            quoted_post: nil,
            screen_name: "verge",
            name: "The Verge",
            profile_image_url: url("https://pbs.twimg.com/profile_images/1569656103528448000/d0BzVIPL_normal.jpg"),
            profile_image_shape: .square,
            url: statusURL(username: "verge", id: 2073898178978754995),
            text_embedding: [],
            img_embedding: [],
            primary_topic: "AI Education",
            secondary_topics: ["The Verge", "Links", "School"]
        )
    }
    
    private static var photoPost: Post {
        post(
            id: 1002,
            createdAt: now.addingTimeInterval(-3_600),
            text: "Single image post with enough text to wrap onto multiple lines and show how the media aligns below it.",
            media: [photo(seed: "single-photo", width: 900, height: 540)],
            author: "Design Systems",
            username: "designsystems",
            profileShape: .square,
            topics: ("Design", ["Images"])
        )
    }
    
    private static var multiPhotoPost: Post {
        post(
            id: 1003,
            createdAt: now.addingTimeInterval(-18_000),
            text: "Multiple media attachments currently render as a vertical stack. This sample makes that behavior easy to tune in canvas.",
            media: [
                photo(seed: "multi-photo-a", width: 900, height: 500),
                photo(seed: "multi-photo-b", width: 900, height: 900)
            ],
            author: "Product Notes",
            username: "productnotes",
            topics: ("Media", ["Layout", "Attachments"])
        )
    }
    
    private static var videoPost: Post {
        post(
            id: 1004,
            createdAt: now.addingTimeInterval(-86_400),
            text: "Video post placeholder for the play affordance and thumbnail treatment.",
            media: [video(seed: "video-thumb")],
            author: "Field Camera",
            username: "fieldcam",
            topics: ("Video", ["Playback", "Preview"])
        )
    }
    
    static var quotedPost: Post {
        post(
            id: 1005,
            createdAt: now.addingTimeInterval(-172_800),
            text: "Main post text above a quoted post. Useful for adjusting the nested card spacing and tap target.",
            quotedPost: quote(
                id: 2001,
                text: "Quoted text-only content with a different author and timestamp.",
                author: "Ari Patel",
                username: "aripatel"
            ),
            author: "Nora Reed",
            username: "norareed",
            topics: ("Quotes", ["Conversation"])
        )
    }
    
    static var articlePost: Post {
        post(
            id: 1010,
            createdAt: now.addingTimeInterval(-259_200),
            text: "An article post preview that exercises the article card, rich text blocks, embedded media, and the surrounding post chrome.",
            article: article(
                title: "Designing Native Mac Interfaces Without Losing Density",
                previewText: "A practical walkthrough of balancing hierarchy, scanning, and information density in a content-heavy desktop app.",
                coverSeed: "article-cover",
                bodyMediaSeed: "article-body-media"
            ),
            author: "Desktop Notes",
            username: "desktopnotes",
            topics: ("Articles", ["Rich Text", "Embedded Media"])
        )
    }
    
    private static var quotedMediaPost: Post {
        post(
            id: 1006,
            createdAt: now.addingTimeInterval(-604_800),
            text: "Quote with media inside the nested post.",
            quotedPost: quote(
                id: 2002,
                text: "A quoted post that includes a photo attachment.",
                media: [photo(seed: "quoted-media", width: 800, height: 450)],
                author: "Studio Lab",
                username: "studiolab",
                profileShape: .square
            ),
            author: "Jay Morgan",
            username: "jaymorgan",
            topics: ("References", ["Nested Media"])
        )
    }
    
    private static var quoteOnlyMediaPost: Post {
        post(
            id: 1007,
            createdAt: now.addingTimeInterval(-1_209_600),
            text: "",
            quotedPost: quote(
                id: 2003,
                text: "The original tweet has media, while the quoting post adds no extra text.",
                media: [photo(seed: "quote-only-media", width: 900, height: 506)],
                author: "Original Media",
                username: "originalmedia"
            ),
            author: "Quote Only",
            username: "quoteonly",
            topics: ("Quotes", ["Media", "Empty Text"])
        )
    }
    
    private static var topicHeavyPost: Post {
        post(
            id: 1008,
            createdAt: now.addingTimeInterval(-2_678_400),
            text: "Topic-heavy sample for wrapping chips across rows and checking color contrast in both appearances.",
            author: "Xray Business",
            username: "xraybiz",
            profileShape: .square,
            topics: ("Machine Learning", ["Embeddings", "Search", "Classification", "Apple Platforms", "Local Models"])
        )
    }
    
    private static var emptyTextMediaPost: Post {
        post(
            id: 1009,
            createdAt: now.addingTimeInterval(-31_536_000),
            text: "",
            media: [photo(seed: "empty-text", width: 900, height: 600)],
            author: "Image Only",
            username: "imageonly",
            topics: ("Photography", [])
        )
    }
    
    private static func post(
        id: Int,
        createdAt: Date,
        text: String,
        media: [Media]? = nil,
        article: Article? = nil,
        quotedPost: QuotedPost? = nil,
        author: String,
        username: String,
        profileShape: ProfileImageShape = .circle,
        topics: (primary: String, secondary: [String])
    ) -> Post {
        Post(
            id: id,
            created_at: createdAt,
            full_text: text,
            media: media,
            article: article,
            quoted_post: quotedPost,
            screen_name: username,
            name: author,
            profile_image_url: imageURL(seed: "avatar-\(username)", width: 160, height: 160),
            profile_image_shape: profileShape,
            url: statusURL(username: username, id: id),
            text_embedding: [],
            img_embedding: [],
            primary_topic: topics.primary,
            secondary_topics: topics.secondary
        )
    }
    
    private static func quote(
        id: Int,
        text: String,
        media: [Media]? = nil,
        author: String,
        username: String,
        profileShape: ProfileImageShape = .circle
    ) -> QuotedPost {
        QuotedPost(
            id: id,
            created_at: now.addingTimeInterval(-7_200),
            full_text: text,
            media: media,
            screen_name: username,
            name: author,
            profile_image_url: imageURL(seed: "avatar-quote-\(username)", width: 120, height: 120),
            profile_image_shape: profileShape,
            url: statusURL(username: username, id: id)
        )
    }
    
    private static func article(
        title: String,
        previewText: String,
        coverSeed: String,
        bodyMediaSeed: String
    ) -> Article {
        let coverMediaID = "cover-media"
        let bodyMediaID = "body-media"
        
        return Article(
            rest_id: "article-preview-1",
            title: title,
            preview_text: previewText,
            summary_text: "Preview-only summary text for the PostView canvas.",
            cover_media: mediaEntity(id: coverMediaID, seed: coverSeed, width: 1200, height: 675),
            media_entities: [
                mediaEntity(id: bodyMediaID, seed: bodyMediaSeed, width: 1200, height: 800)
            ],
            content_state: Article.ContentState(
                blocks: [
                    Article.Block(
                        key: "intro",
                        text: "Desktop interfaces can feel dense without feeling crowded when the layout makes hierarchy obvious and interaction costs stay low.",
                        type: "unstyled",
                        data: nil,
                        entityRanges: [],
                        inlineStyleRanges: [
                            Article.InlineStyleRange(offset: 0, length: 18, style: "BOLD")
                        ]
                    ),
                    Article.Block(
                        key: "media",
                        text: " ",
                        type: "atomic",
                        data: nil,
                        entityRanges: [
                            Article.EntityRange(key: 0, offset: 0, length: 1)
                        ],
                        inlineStyleRanges: []
                    ),
                    Article.Block(
                        key: "detail",
                        text: "That usually means giving title, body, and attachments distinct surfaces instead of asking one card style to do everything.",
                        type: "unstyled",
                        data: nil,
                        entityRanges: [],
                        inlineStyleRanges: [
                            Article.InlineStyleRange(offset: 58, length: 22, style: "ITALIC")
                        ]
                    )
                ],
                entityMap: [
                    Article.EntityMapEntry(
                        key: "0",
                        value: Article.EntityValue(
                            type: "MEDIA",
                            data: Article.EntityData(
                                url: nil,
                                caption: "Embedded article image for preview tuning.",
                                mediaItems: [
                                    Article.EntityMediaItem(localMediaId: nil, mediaCategory: "IMAGE", mediaId: bodyMediaID)
                                ],
                                tweetId: nil
                            )
                        )
                    )
                ]
            )
        )
    }
    
    private static func photo(seed: String, width: Int, height: Int) -> Media {
        Media(
            type: "photo",
            thumbnail: imageURL(seed: seed, width: width, height: height),
            original: imageURL(seed: "\(seed)-original", width: width * 2, height: height * 2)
        )
    }
    
    private static func video(seed: String) -> Media {
        Media(
            type: "video",
            thumbnail: imageURL(seed: seed, width: 900, height: 506),
            original: url("https://example.com/preview-video.mp4")
        )
    }
    
    private static func imageURL(seed: String, width: Int, height: Int) -> URL {
        url("https://picsum.photos/seed/\(seed)/\(width)/\(height)")
    }
    
    private static func mediaEntity(id: String, seed: String, width: Int, height: Int) -> Article.MediaEntity {
        Article.MediaEntity(
            media_id: id,
            media_info: Article.MediaInfo(
                original_img_url: imageURL(seed: seed, width: width, height: height),
                original_img_width: Double(width),
                original_img_height: Double(height)
            )
        )
    }
    
    private static func statusURL(username: String, id: Int) -> URL {
        url("https://x.com/\(username)/status/\(id)")
    }
    
    private static func url(_ value: String) -> URL {
        URL(string: value) ?? URL(fileURLWithPath: "/dev/null")
    }
}

