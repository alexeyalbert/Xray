//
//  ArticleView.swift
//  Xray
//

import AppKit
import SwiftUI

struct ArticleEmbeddedMedia: Identifiable {
    let media: Media
    let caption: String?

    var id: URL { media.id }
}

struct ArticleView: View {
    let article: Article
    let isParentVisible: Bool
    let shouldAnimateMediaAppearance: Bool
    var isMediaInteractive: Bool = true
    var onMediaSelected: (Media) -> Void = { _ in }
    var dragContextForMedia: (Media) -> MediaSaveContext? = { _ in nil }
    var contextMenuContent: ((Media) -> AnyView)? = nil
    var onDebugUpdate: (MediaThumbnailDebugSnapshot) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    private var entityMapByKey: [Int: Article.EntityValue] {
        Dictionary(
            uniqueKeysWithValues: (article.content_state?.entityMap ?? []).compactMap { entry in
                guard let key = Int(entry.key) else { return nil }
                return (key, entry.value)
            }
        )
    }

    private var bodyBlocks: [Article.Block] {
        article.content_state?.blocks ?? []
    }

    private var mediaIDsReferencedInBlocks: Set<String> {
        Set(
            bodyBlocks
                .filter { $0.type.caseInsensitiveCompare("atomic") == .orderedSame }
                .flatMap { block in
                    block.entityRanges.compactMap { range in
                        entityMapByKey[range.key]
                    }
                }
                .filter { $0.type.caseInsensitiveCompare("MEDIA") == .orderedSame }
                .flatMap { $0.data.mediaItems ?? [] }
                .compactMap(\.mediaId)
        )
    }

    
    // MARK: Article Post View
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(article.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color(NSColor.textColor))

            if let coverMedia = article.cover_media?.asMedia,
               !mediaIDsReferencedInBlocks.contains(article.cover_media?.media_id ?? "") {
                articleMediaView(media: coverMedia, caption: nil)
            }

            if bodyBlocks.isEmpty {
                if let preview = article.preview_text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !preview.isEmpty {
                    Text(preview)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Color(NSColor.textColor))
                }
            } else {
                ForEach(bodyBlocks) { block in
                    ArticleBlockView(
                        article: article,
                        block: block,
                        entityMapByKey: entityMapByKey,
                        isParentVisible: isParentVisible,
                        shouldAnimateMediaAppearance: shouldAnimateMediaAppearance,
                        isMediaInteractive: isMediaInteractive,
                        onMediaSelected: onMediaSelected,
                        dragContextForMedia: dragContextForMedia,
                        contextMenuContent: contextMenuContent,
                        onDebugUpdate: onDebugUpdate
                    )
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.highlightColor).opacity(colorScheme == .dark ? 0.03 : 0.85), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(NSColor.tertiarySystemFill), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func articleMediaView(media: Media, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaThumbnailView(
                media: media,
                cornerRadius: 12,
                isParentVisible: isParentVisible,
                shouldAnimateAppearance: shouldAnimateMediaAppearance,
                isInteractive: isMediaInteractive,
                dragContext: dragContextForMedia(media),
                onTap: {
                    onMediaSelected(media)
                },
                onDebugUpdate: onDebugUpdate
            )
            .if(contextMenuContent != nil) { view in
                view.contextMenu {
                    if let contextMenuContent {
                        contextMenuContent(media)
                    }
                }
            }
            .if(isMediaInteractive) { view in
                view.pointingHandOnHover()
            }

            if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ArticleBlockView: View {
    let article: Article
    let block: Article.Block
    let entityMapByKey: [Int: Article.EntityValue]
    let isParentVisible: Bool
    let shouldAnimateMediaAppearance: Bool
    var isMediaInteractive: Bool = true
    var onMediaSelected: (Media) -> Void = { _ in }
    var dragContextForMedia: (Media) -> MediaSaveContext? = { _ in nil }
    var contextMenuContent: ((Media) -> AnyView)? = nil
    var onDebugUpdate: (MediaThumbnailDebugSnapshot) -> Void = { _ in }

    private var normalizedType: String {
        block.type.lowercased()
    }

    var body: some View {
        switch normalizedType {
        case "atomic":
            atomicContent
        case "unordered-list-item":
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(attributedText(for: block))
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            Text(attributedText(for: block))
                .font(font(for: normalizedType))
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .foregroundStyle(Color(NSColor.textColor))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var atomicContent: some View {
        if let range = block.entityRanges.first,
           let entity = entityMapByKey[range.key] {
            switch entity.type.uppercased() {
            case "DIVIDER":
                Divider()
                    .padding(.vertical, 4)
            case "MEDIA":
                let attachments = mediaAttachments(for: entity)
                if attachments.isEmpty {
                    EmptyView()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(attachments) { attachment in
                            VStack(alignment: .leading, spacing: 8) {
                                MediaThumbnailView(
                                    media: attachment.media,
                                    cornerRadius: 12,
                                    isParentVisible: isParentVisible,
                                    shouldAnimateAppearance: shouldAnimateMediaAppearance,
                                    isInteractive: isMediaInteractive,
                                    dragContext: dragContextForMedia(attachment.media),
                                    onTap: {
                                        onMediaSelected(attachment.media)
                                    },
                                    onDebugUpdate: onDebugUpdate
                                )
                                .if(contextMenuContent != nil) { view in
                                    view.contextMenu {
                                        if let contextMenuContent {
                                            contextMenuContent(attachment.media)
                                        }
                                    }
                                }
                                .if(isMediaInteractive) { view in
                                    view.pointingHandOnHover()
                                }

                                if let caption = attachment.caption,
                                   !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(caption)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            case "TWEET":
                if let tweetID = entity.data.tweetId,
                   let url = URL(string: "https://x.com/i/status/\(tweetID)") {
                    Link(destination: url) {
                        HStack(spacing: 8) {
                            Image(systemName: "quote.bubble")
                            Text("Embedded Post")
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                } else {
                    EmptyView()
                }
            default:
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    private func mediaAttachments(for entity: Article.EntityValue) -> [ArticleEmbeddedMedia] {
        let mediaIDs = entity.data.mediaItems?.compactMap(\.mediaId) ?? []
        guard !mediaIDs.isEmpty else { return [] }

        return mediaIDs.compactMap { mediaID in
            guard
                let mediaEntity = article.media_entities.first(where: { $0.media_id == mediaID }),
                let media = mediaEntity.asMedia
            else {
                return nil
            }

            return ArticleEmbeddedMedia(media: media, caption: entity.data.caption)
        }
    }

    private func attributedText(for block: Article.Block) -> AttributedString {
        let string = block.text
        let baseFont = nsFont(for: normalizedType)
        let attributed = NSMutableAttributedString(
            string: string,
            attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.textColor
            ]
        )

        for styleRange in block.inlineStyleRanges {
            guard let range = nsRange(for: styleRange.offset, length: styleRange.length, in: string) else { continue }
            switch styleRange.style.lowercased() {
            case "italic":
                let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                attributed.addAttribute(.font, value: italic, range: range)
            case "bold":
                let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                attributed.addAttribute(.font, value: bold, range: range)
            default:
                continue
            }
        }

        for entityRange in block.entityRanges {
            guard
                let entity = entityMapByKey[entityRange.key],
                entity.type.uppercased() == "LINK",
                let url = entity.data.url,
                let range = nsRange(for: entityRange.offset, length: entityRange.length, in: string)
            else {
                continue
            }

            attributed.addAttributes(
                [
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: range
            )
        }

        return (try? AttributedString(attributed, including: \.foundation)) ?? AttributedString(string)
    }

    private func font(for blockType: String) -> Font {
        switch blockType {
        case "header-one":
            return .title3.weight(.bold)
        case "header-two":
            return .headline.weight(.semibold)
        case "blockquote":
            return .body.italic()
        default:
            return .body
        }
    }

    private func nsFont(for blockType: String) -> NSFont {
        switch blockType {
        case "header-one":
            return NSFont.systemFont(ofSize: 19, weight: .bold)
        case "header-two":
            return NSFont.systemFont(ofSize: 15, weight: .semibold)
        default:
            return NSFont.systemFont(ofSize: 14)
        }
    }

    private func nsRange(for offset: Int, length: Int, in string: String) -> NSRange? {
        guard offset >= 0, length > 0 else { return nil }
        let nsString = string as NSString
        guard offset + length <= nsString.length else { return nil }
        return NSRange(location: offset, length: length)
    }
}

