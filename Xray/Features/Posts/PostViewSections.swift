//
//  PostViewSections.swift
//  Xray
//

import AppKit
import SwiftUI
import DeterministicColorGen

struct PostAuthorHeader: View {
    let profileImageURL: URL
    let username: String
    let profileImageShape: ProfileImageShape
    let displayName: String
    let createdAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ProfileImageView(
                url: profileImageURL,
                username: username,
                shape: profileImageShape,
                size: 36
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 6) {
                    Text(displayName)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Color(NSColor.textColor))
                    Text(compactPostTimestamp(for: createdAt))
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.tertiary)
                }

                Text("@\(username)")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .layoutPriority(1)
        }
    }
}

struct PostMediaGallery: View {
    let media: [Media]
    let isParentVisible: Bool
    let shouldAnimateAppearance: Bool
    let isInteractive: Bool
    let dragContextForMedia: (Media) -> MediaSaveContext?
    let onMediaSelected: (Media) -> Void
    let contextMenuContent: (Media) -> AnyView
    let onDebugUpdate: (MediaThumbnailDebugSnapshot) -> Void

    var body: some View {
        ForEach(media) { media in
            MediaThumbnailView(
                media: media,
                cornerRadius: 10,
                isParentVisible: isParentVisible,
                shouldAnimateAppearance: shouldAnimateAppearance,
                isInteractive: isInteractive,
                dragContext: dragContextForMedia(media),
                onTap: {
                    onMediaSelected(media)
                },
                onDebugUpdate: onDebugUpdate
            )
            .contextMenu {
                contextMenuContent(media)
            }
            .pointingHandOnHover()
        }
    }
}

struct QuotedPostCard: View {
    let post: QuotedPost
    let isParentVisible: Bool
    let shouldAnimateMediaAppearance: Bool
    let isInteractive: Bool
    let dragContextForMedia: (Media) -> MediaSaveContext?
    let onMediaSelected: (Media) -> Void
    let contextMenuContent: (Media) -> AnyView
    let onDebugUpdate: (MediaThumbnailDebugSnapshot) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                ProfileImageView(
                    url: post.profile_image_url,
                    username: post.screen_name,
                    shape: post.profile_image_shape,
                    size: 30,
                    squareCornerRadius: 4
                )

                VStack(alignment: .leading, spacing: 0) {
                    Text(post.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(Color(NSColor.textColor))
                    Text("@\(post.screen_name)")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let createdAt = post.created_at {
                    Text(compactPostTimestamp(for: createdAt))
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                }
            }

            if !post.full_text.isEmpty {
                Text(post.full_text)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Color(NSColor.textColor))
            }

            if let media = post.media, !media.isEmpty {
                ForEach(media) { media in
                    MediaThumbnailView(
                        media: media,
                        cornerRadius: 5,
                        isParentVisible: isParentVisible,
                        shouldAnimateAppearance: shouldAnimateMediaAppearance,
                        isInteractive: isInteractive,
                        dragContext: dragContextForMedia(media),
                        onTap: {
                            onMediaSelected(media)
                        },
                        onDebugUpdate: onDebugUpdate
                    )
                    .contextMenu {
                        contextMenuContent(media)
                    }
                    .padding(-2)
                    .pointingHandOnHover()
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.highlightColor).opacity(colorScheme == .dark ? 0.03 : 0.9),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(NSColor.secondarySystemFill), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct PostTopicChips: View {
    let primaryTopic: String
    let secondaryTopics: [String]
    let isInteractive: Bool
    let onTopicSelected: (String, TopicSearchScope) -> Void

    var body: some View {
        HStack {
            if !primaryTopic.isEmpty || !secondaryTopics.isEmpty {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    if !primaryTopic.isEmpty {
                        let (background, foreground) = DeterministicColor.uiSet(primaryTopic)
                        PostTopicChip(
                            title: TopicDisplayFormatter.displayName(for: primaryTopic),
                            foregroundStyle: AnyShapeStyle(foreground),
                            fill: AnyShapeStyle(background),
                            isInteractive: isInteractive,
                            action: {
                                onTopicSelected(primaryTopic, .primary)
                            }
                        )
                    }

                    ForEach(secondaryTopics, id: \.self) { topic in
                        PostTopicChip(
                            title: TopicDisplayFormatter.displayName(for: topic),
                            foregroundStyle: AnyShapeStyle(Color(NSColor.secondaryLabelColor)),
                            fill: AnyShapeStyle(Color(NSColor.tertiarySystemFill)),
                            isInteractive: isInteractive,
                            action: {
                                onTopicSelected(topic, .secondary)
                            }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PostTopicChip: View {
    let title: String
    let foregroundStyle: AnyShapeStyle
    let fill: AnyShapeStyle
    let isInteractive: Bool
    let action: () -> Void

    var body: some View {
        let label = HStack(alignment: .center, spacing: 1) {
            Text(title)
                .lineLimit(1)
        }
        .foregroundStyle(foregroundStyle)
        .fontWeight(.medium)
        .fontDesign(.rounded)

        if isInteractive {
            Button(action: action) {
                label
            }
            .buttonStyle(SolidTopicChipButtonStyle(fill: fill))
            .pointingHandOnHover()
        } else {
            label
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
    }
}
