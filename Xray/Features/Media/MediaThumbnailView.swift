//
//  MediaThumbnailView.swift
//  Xray
//

import AppKit
import Kingfisher
import os
import SwiftUI

struct MediaThumbnailView: View {
    let media: Media
    let cornerRadius: CGFloat
    var isParentVisible: Bool = true
    var shouldAnimateAppearance: Bool = true
    var isInteractive: Bool = true
    var dragContext: MediaSaveContext? = nil
    let onTap: () -> Void
    var onDebugUpdate: (MediaThumbnailDebugSnapshot) -> Void = { _ in }

    @Environment(\.displayScale) private var displayScale
    @AppStorage(MediaViewerSettings.animateThumbnailAppearanceKey) private var animateThumbnailAppearance: Bool = true
    @State private var resolvedAspectRatio: CGFloat?
    @State private var hasLoadedThumbnailImage = false
    @State private var hasRevealedThumbnail = false
    @State private var animateCurrentReveal = false
    private let logger = Logger(subsystem: "com.alexeyalbert.Xray", category: "MediaThumbnailView")

    private var displayAspectRatio: CGFloat {
        resolvedAspectRatio ?? media.feedAspectRatio ?? (16.0 / 9.0)
    }

    private var thumbnailRevealOffset: CGFloat {
        guard hasLoadedThumbnailImage else { return 0 }
        guard animateThumbnailAppearance else { return 0 }
        return hasRevealedThumbnail ? 0 : 8
    }

    private var thumbnailRevealOpacity: Double {
        guard hasLoadedThumbnailImage else { return 0 }
        guard animateThumbnailAppearance else { return 1 }
        return hasRevealedThumbnail ? 1 : 0.01
    }

    private var thumbnailRevealBlur: CGFloat {
        guard hasLoadedThumbnailImage else { return 0 }
        guard animateThumbnailAppearance else { return 0 }
        return hasRevealedThumbnail ? 0 : 8
    }

    var body: some View {
        ZStack {
            if media.isAnimatedGIF {
                if isParentVisible {
                    LoopingInlineVideoView(url: media.original, aspectRatio: displayAspectRatio)
                        .offset(y: thumbnailRevealOffset)
                        .opacity(thumbnailRevealOpacity)
                        .blur(radius: thumbnailRevealBlur)
                        .onAppear {
                            hasLoadedThumbnailImage = true
                            revealThumbnail(animate: shouldAnimateAppearance)
                        }
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(NSColor.tertiarySystemFill))
                }
            } else {
                GeometryReader { proxy in
                    let displayPixelSize = thumbnailDisplayPixelSize(in: proxy.size)
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(NSColor.tertiarySystemFill))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if isParentVisible {
                            KFImage(media.thumbnail)
                                .placeholder {
                                    Color.clear
                                }
                                .onSuccess { result in
                                    hasLoadedThumbnailImage = true
                                    revealThumbnail(animate: shouldAnimateAppearance)
                                    reportThumbnailSuccess(
                                        result,
                                        processorSize: displayPixelSize,
                                        processorIdentifier: SharedImagePipeline.thumbnailProcessorIdentifier
                                    )
                                }
                                .onFailure { error in
                                    hasLoadedThumbnailImage = false
                                    let _ = logger.error("Failed to load media thumbnail: \(self.media.thumbnail, privacy: .public) — error: \(error.localizedDescription, privacy: .public)")
                                    reportThumbnailFailure(
                                        error,
                                        processorSize: displayPixelSize,
                                        processorIdentifier: SharedImagePipeline.thumbnailProcessorIdentifier
                                    )
                                }
                                .setProcessor(SharedImagePipeline.thumbnailProcessor)
                                .targetCache(SharedImagePipeline.thumbnailCache)
                                .serialize(by: SharedImagePipeline.thumbnailCacheSerializer)
                                .requestModifier(SharedImagePipeline.sharedRequestModifier)
                                .backgroundDecode()
                                .cancelOnDisappear(true)
                                .fade(duration: 0.12)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .offset(y: thumbnailRevealOffset)
                                .opacity(thumbnailRevealOpacity)
                                .blur(radius: thumbnailRevealBlur)
                        }
                    }
                }
            }

            if media.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .cheapableCircleGlass()
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            }
        }
        .aspectRatio(displayAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .animation(
            animateThumbnailAppearance && animateCurrentReveal
                ? .spring(response: 0.32, dampingFraction: 0.86)
                : nil,
            value: hasRevealedThumbnail
        )
        .if(isInteractive) { view in
            view.onTapGesture { onTap() }
        }
        .onDrag {
            MediaDragCoordinator.itemProvider(for: media, context: dragContext) ?? NSItemProvider()
        }
        .onChange(of: media.id, initial: true) { _, _ in
            if SharedImagePipeline.isThumbnailCached(media.thumbnail) {
                hasLoadedThumbnailImage = true
                hasRevealedThumbnail = true
                animateCurrentReveal = false
                return
            }
            hasLoadedThumbnailImage = false
            animateCurrentReveal = false
            hasRevealedThumbnail = false
        }
        .task(id: "\(media.id.absoluteString)-\(isParentVisible)") {
            guard isParentVisible else { return }

            if media.isPlayableVideo {
                if let size = try? await videoDisplaySize(for: media.original),
                   size.width > 0,
                   size.height > 0,
                   !Task.isCancelled {
                    resolvedAspectRatio = size.width / size.height
                } else {
                    resolvedAspectRatio = nil
                }
                return
            }

            guard media.feedAspectRatio == nil else {
                resolvedAspectRatio = nil
                return
            }

            if let size = await SharedImagePipeline.imageDimensions(for: media.thumbnail),
               size.width > 0,
               size.height > 0,
               !Task.isCancelled {
                resolvedAspectRatio = size.width / size.height
                return
            }

            guard media.thumbnail != media.original,
                  !media.isPlayableVideo,
                  let size = await SharedImagePipeline.imageDimensions(for: media.original),
                  size.width > 0,
                  size.height > 0,
                  !Task.isCancelled
            else {
                return
            }
            resolvedAspectRatio = size.width / size.height
        }
    }

    private func thumbnailDisplayPixelSize(in availableSize: CGSize) -> CGSize {
        let fallbackWidth: CGFloat = 640
        let fallbackHeight = fallbackWidth / max(displayAspectRatio, 0.1)
        let width = max((availableSize.width > 0 ? availableSize.width : fallbackWidth) * displayScale, 1)
        let height = max((availableSize.height > 0 ? availableSize.height : fallbackHeight) * displayScale, 1)
        return CGSize(width: width, height: height)
    }

    private func revealThumbnail(animate: Bool) {
        guard !hasRevealedThumbnail else { return }
        animateCurrentReveal = animate
        hasRevealedThumbnail = true
    }

    private func reportThumbnailSuccess(
        _ result: RetrieveImageResult,
        processorSize: CGSize,
        processorIdentifier: String
    ) {
        onDebugUpdate(
            MediaThumbnailDebugSnapshot(
                mediaID: media.id,
                renderedURL: media.thumbnail,
                cacheType: result.cacheType,
                sourceURL: result.source.url,
                originalSourceURL: result.originalSource.url,
                processorIdentifier: processorIdentifier,
                requestedPixelSize: processorSize,
                failureDescription: nil,
                updatedAt: Date()
            )
        )
    }

    private func reportThumbnailFailure(
        _ error: KingfisherError,
        processorSize: CGSize,
        processorIdentifier: String
    ) {
        onDebugUpdate(
            MediaThumbnailDebugSnapshot(
                mediaID: media.id,
                renderedURL: media.thumbnail,
                cacheType: nil,
                sourceURL: media.thumbnail,
                originalSourceURL: media.thumbnail,
                processorIdentifier: processorIdentifier,
                requestedPixelSize: processorSize,
                failureDescription: error.localizedDescription,
                updatedAt: Date()
            )
        )
    }
}

struct MediaThumbnailDebugSnapshot {
    let mediaID: URL
    let renderedURL: URL
    let cacheType: CacheType?
    let sourceURL: URL?
    let originalSourceURL: URL?
    let processorIdentifier: String
    let requestedPixelSize: CGSize
    let failureDescription: String?
    let updatedAt: Date
}
