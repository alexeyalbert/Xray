//
//  PostLinkViews.swift
//  Xray
//

import AppKit
import Kingfisher
import SwiftUI

struct SolidTopicChipButtonStyle: ButtonStyle {
    let fill: AnyShapeStyle
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct PostBackgroundStyle: ViewModifier {
    private let cardShape = RoundedRectangle(cornerRadius: 20)
    
    func body(content: Content) -> some View {
        content.background(Color(NSColor.windowBackgroundColor), in: cardShape)
    }
}

struct LinkPreviewList: View {
    let links: [PostLink]
    let isInteractive: Bool
    let isParentVisible: Bool
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(links) { link in
                if isInteractive {
                    Button {
                        openURL(link.destination)
                    } label: {
                        LinkPreviewRow(link: link, isParentVisible: isParentVisible)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pointingHandOnHover()
                } else {
                    LinkPreviewRow(link: link, isParentVisible: isParentVisible)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

struct InlinePostText: View {
    let text: String
    let links: [PostLink]
    let isInteractive: Bool

    private var paragraphs: [String] {
        text.components(separatedBy: .newlines)
    }

    private var linksMissingFromText: [PostLink] {
        links.filter { !text.contains($0.displayName) }
    }

    private var shouldAppendMissingLinksToLastLine: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") || text.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                let isLastParagraph = index == paragraphs.count - 1
                FlowLayout(spacing: 4, rowSpacing: 2) {
                    ForEach(Array(words(in: paragraph).enumerated()), id: \.offset) { _, word in
                        if let link = link(for: word) {
                            InlineTextLink(label: word, link: link, isInteractive: isInteractive)
                        } else {
                            Text(word)
                                .lineLimit(1)
                                .foregroundStyle(Color(NSColor.textColor))
                        }
                    }

                    if isLastParagraph && shouldAppendMissingLinksToLastLine {
                        inlineMissingLinks
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if paragraphs.isEmpty {
                FlowLayout(spacing: 4, rowSpacing: 2) {
                    inlineMissingLinks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !shouldAppendMissingLinksToLastLine && !linksMissingFromText.isEmpty {
                FlowLayout(spacing: 4, rowSpacing: 2) {
                    inlineMissingLinks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inlineMissingLinks: some View {
        ForEach(linksMissingFromText) { link in
            InlineTextLink(label: link.displayName, link: link, isInteractive: isInteractive)
        }
    }

    private func link(for word: String) -> PostLink? {
        links.first { word.contains($0.displayName) }
    }

    private func words(in paragraph: String) -> [String] {
        paragraph
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}

private struct InlineTextLink: View {
    let label: String
    let link: PostLink
    let isInteractive: Bool
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        let text = Text(label)
            .lineLimit(2)
            .foregroundStyle(Color(NSColor.linkColor))
            .underline(isHovering)

        if isInteractive {
            Button {
                openURL(link.destination)
            } label: {
                text
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .pointingHandOnHover()
        } else {
            text
        }
    }
}

// MARK: Link Preview Row

private struct LinkPreviewRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let link: PostLink
    let isParentVisible: Bool
    
    var body: some View {
        if let card = link.card, card.hasPreviewContent {
            VStack(alignment: .leading, spacing: 0) {
                if let imageURL = card.image_url {
                    ZStack {
                        Color(NSColor.tertiarySystemFill)

                        if isParentVisible {
                            LinkPreviewImage(
                                primaryURL: imageURL,
                                destinationURL: link.destination
                            )
                        }
                    }
                    .aspectRatio(imageAspectRatio(for: card), contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 10
                        )
                    )
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText(for: card))
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Color(NSColor.textColor))
                    
                    if let description = descriptionText(for: card) {
                        Text(description)
                            .font(.system(size: 12))
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(Color(NSColor.secondaryLabelColor))
                        
                    }
                    
                    Text(domainText(for: card))
                        .font(.system(size: 11, weight: .regular))
                        .lineLimit(1)
                        .foregroundStyle(Color(NSColor.secondaryLabelColor))
                        .padding(.trailing, 5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.highlightColor).opacity(colorScheme == .dark ? 0.03 : 0.9),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(NSColor.secondarySystemFill), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        } else {
            InlineTextLink(label: link.displayName, link: link, isInteractive: true)
        }
    }
    
    private func titleText(for card: LinkCard) -> String {
        card.title?.nilIfEmpty ?? link.displayName
    }
    
    private func descriptionText(for card: LinkCard) -> String? {
        card.description?.nilIfEmpty
    }
    
    private func domainText(for card: LinkCard) -> String {
        card.vanity_url?.nilIfEmpty ?? card.domain?.nilIfEmpty ?? link.displayName
    }
    
    private func imageAspectRatio(for card: LinkCard) -> CGFloat {
        guard let width = card.image_width,
              let height = card.image_height,
              width > 0,
              height > 0 else {
            return 16.0 / 9.0
        }
        
        return CGFloat(width / height)
    }
}

private struct LinkPreviewImage: View {
    let primaryURL: URL
    let destinationURL: URL

    @State private var fallbackURL: URL?
    @State private var primaryLoadFailed = false

    private var displayedURL: URL {
        fallbackURL ?? primaryURL
    }

    var body: some View {
        GeometryReader { proxy in
            KFImage(displayedURL)
                .placeholder {
                    Color.clear
                }
                .onFailure { _ in
                    guard fallbackURL == nil else { return }
                    primaryLoadFailed = true
                }
                .setProcessor(SharedImagePipeline.thumbnailProcessor)
                .targetCache(SharedImagePipeline.thumbnailCache)
                .serialize(by: SharedImagePipeline.thumbnailCacheSerializer)
                .requestModifier(SharedImagePipeline.sharedRequestModifier)
                .backgroundDecode()
                .cancelOnDisappear(true)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipped()
        }
        .task(id: primaryLoadFailed) {
            guard primaryLoadFailed, fallbackURL == nil else { return }
            guard let resolvedURL = await SharedImagePipeline.linkPreviewFallbackImageURL(for: destinationURL),
                  resolvedURL != primaryURL else {
                return
            }
            fallbackURL = resolvedURL
        }
        .onDisappear {
            SharedImagePipeline.pruneThumbnailsFromMemory(
                for: [primaryURL, fallbackURL].compactMap { $0 }
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
