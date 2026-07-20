//
//  MediaView.swift
//  Xray
//

import AppKit
import AVKit
import Kingfisher
import os
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct MediaView: View {
    let media: Media
    let saveContext: MediaSaveContext?
    var onClose: () -> Void = {}
    @AppStorage(MediaViewerSettings.roundedCornersKey) private var useRoundedCorners: Bool = true
    @AppStorage(MediaViewerSettings.animateExpandedMediaAppearanceKey) private var animateExpandedMediaAppearance: Bool = true
    @AppStorage(MediaViewerSettings.animateExpandedMediaResizeKey) private var animateExpandedMediaResize: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var targetSize: CGSize? = nil
    @State private var imageBaseSize: CGSize? = nil
    @State private var didLoadExpandedThumbnail = false
    @State private var didLoadImage = false
    @State private var imageLoadFailure: String?
    @State private var hasRevealedExpandedMedia = false
    @State private var isOpeningInPreview = false
    @State private var videoPlayer: AVPlayer?
    @State private var isSavingVideoFrame = false
    @State private var alertTitle: String = "Notice"
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false
    private let logger = Logger(subsystem: "com.alexeyalbert.Xray", category: "MediaView")
    private let expandedCornerRadius: CGFloat = 10
    private let mediaLift: CGFloat = -8

    init(media: Media, saveContext: MediaSaveContext? = nil, onClose: @escaping () -> Void = {}) {
        self.media = media
        self.saveContext = saveContext
        self.onClose = onClose
    }

    private struct ViewerBounds {
        let maxWidth: CGFloat
        let maxHeight: CGFloat
    }
    
    private func computeTargetSize(for imageSize: CGSize) -> CGSize {
        let bounds = viewerBounds()
        let scale = min(
            bounds.maxWidth / max(imageSize.width, 1),
            bounds.maxHeight / max(imageSize.height, 1),
            1
        )
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func computeTargetSize(forAspectRatio aspectRatio: CGFloat) -> CGSize {
        let sanitizedAspectRatio = max(aspectRatio, 0.01)
        let bounds = viewerBounds()

        let widthFromMaxHeight = bounds.maxHeight * sanitizedAspectRatio
        if widthFromMaxHeight <= bounds.maxWidth {
            return CGSize(width: widthFromMaxHeight, height: bounds.maxHeight)
        }

        let heightFromMaxWidth = bounds.maxWidth / sanitizedAspectRatio
        return CGSize(width: bounds.maxWidth, height: heightFromMaxWidth)
    }

    private func viewerBounds() -> ViewerBounds {
#if os(macOS)
        // Save panels can temporarily become the app's main/key window. Keep
        // viewer sizing anchored to the app content window instead.
        let windowSize = viewerHostWindow()?.contentLayoutRect.size
        ?? NSScreen.main?.visibleFrame.size
        ?? CGSize(width: 1440, height: 900)
#else
        let screenSize = UIScreen.main.bounds.size
#endif
        return ViewerBounds(
            maxWidth: (
                {
#if os(macOS)
                    windowSize.width
#else
                    screenSize.width
#endif
                }()
            ) * 0.85,
            maxHeight: (
                {
#if os(macOS)
                    windowSize.height
#else
                    screenSize.height
#endif
                }()
            ) * 0.85
        )
    }
    
#if os(macOS)
    private func viewerHostWindow() -> NSWindow? {
        if let mainWindow = NSApp.mainWindow, !(mainWindow is NSPanel) {
            return mainWindow
        }

        if let keyWindow = NSApp.keyWindow, !(keyWindow is NSPanel) {
            return keyWindow
        }

        return NSApp.windows
            .filter { $0.isVisible && !($0 is NSPanel) }
            .max { lhs, rhs in
                let lhsArea = lhs.contentLayoutRect.width * lhs.contentLayoutRect.height
                let rhsArea = rhs.contentLayoutRect.width * rhs.contentLayoutRect.height
                return lhsArea < rhsArea
            }
    }

    private func currentWindowContentSize() -> CGSize {
        viewerHostWindow()?.contentLayoutRect.size
        ?? NSScreen.main?.visibleFrame.size
        ?? CGSize(width: 1440, height: 900)
    }
#endif
    
    var body: some View {
        mediaSurface
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(4)
                    }
                    .buttonBorderShape(.circle)
                    .compatibleGlassCircleButton()

                    if MediaSaveCoordinator.isDownloadableMedia(media) {
                        Button {
                            Task { await saveExpandedMedia() }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                                .padding(4)
                        }
                        .buttonBorderShape(.circle)
                        .compatibleGlassCircleButton()
                        .help("Save to Files")

                        if media.isVideo {
                            Button {
                                Task { await saveCurrentVideoFrame() }
                            } label: {
                                Image(systemName: "photo.badge.arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(4)
                            }
                            .buttonBorderShape(.circle)
                            .compatibleGlassCircleButton()
                            .disabled(videoPlayer == nil || isSavingVideoFrame)
                            .help("Save Current Video Frame")
                        }

                        if MediaPreviewCoordinator.canOpen(media) {
                            Button {
                                Task { await openExpandedMediaInPreview() }
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(4)
                            }
                            .buttonBorderShape(.circle)
                            .compatibleGlassCircleButton()
                            .disabled(isOpeningInPreview)
                            .help("Open in Preview")
                        }
                    }
                }
                .offset(x: 43, y: 6)
            }
            .offset(y: mediaLift)
        .animation(animateExpandedMediaAppearance ? .easeOut(duration: 0.25) : nil, value: hasRevealedExpandedMedia)
        .animation(animateExpandedMediaResize ? .easeOut(duration: 0.2) : nil, value: targetSize)
        .transaction { transaction in
            guard !animateExpandedMediaAppearance, !animateExpandedMediaResize else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear {
            applyInitialViewerSize()
        }
        .onChange(of: media.id, initial: true) { _, _ in
            imageBaseSize = mediaSize
            targetSize = nil
            hasRevealedExpandedMedia = false
            didLoadExpandedThumbnail = false
            didLoadImage = false
            imageLoadFailure = nil
            videoPlayer = nil
            isSavingVideoFrame = false
            applyInitialViewerSize()
            scheduleExpandedMediaReveal()
        }
        // When the window resizes, recompute the target size using known image base size if available
#if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let resizedWindow = notification.object as? NSWindow,
                  resizedWindow === viewerHostWindow() else {
                return
            }

            if let base = imageBaseSize {
                targetSize = computeTargetSize(for: base)
            } else if let aspectRatio = media.feedAspectRatio {
                targetSize = computeTargetSize(forAspectRatio: aspectRatio)
            } else {
                let bounds = viewerBounds()
                targetSize = CGSize(width: bounds.maxWidth * 0.6, height: bounds.maxHeight * 0.6)
            }
        }
#endif
        .task(id: media.id) {
            guard media.isPlayableVideo else { return }

            do {
                if let videoSize = try await videoDisplaySize(for: media.original) {
                    self.imageBaseSize = videoSize
                    self.targetSize = computeTargetSize(for: videoSize)
                }
            } catch {
                let _ = logger.debug("Failed to pre-measure video size for \(media.original, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var mediaSurface: some View {
        mediaContent
            .frame(width: viewerSize.width, height: viewerSize.height)
            .background {
                mediaBackdrop
            }
            .clipShape(RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous))
            .overlay {
                if activeCornerRadius > 0 {
                    RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.18), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.28), radius: 30, y: 18)
            .offset(y: expandedMediaRevealOffset)
            .opacity(expandedMediaRevealOpacity)
            .blur(radius: expandedMediaRevealBlur)
            .contentShape(RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous))
            .onDrag {
                MediaDragCoordinator.itemProvider(for: media, context: saveContext) ?? NSItemProvider()
            }
    }

    private var viewerSize: CGSize {
        if let targetSize, targetSize.width > 0, targetSize.height > 0 {
            return targetSize
        }

        if let aspectRatio = media.feedAspectRatio {
            return computeTargetSize(forAspectRatio: aspectRatio)
        }

        let bounds = viewerBounds()
        return CGSize(width: bounds.maxWidth * 0.6, height: bounds.maxHeight * 0.6)
    }

    private var mediaSize: CGSize? {
        guard let width = media.width,
              let height = media.height,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private var activeCornerRadius: CGFloat {
        useRoundedCorners ? expandedCornerRadius : 0
    }

    private var expandedMediaRevealOffset: CGFloat {
        guard animateExpandedMediaAppearance else { return 0 }
        return hasRevealedExpandedMedia ? 0 : 8
    }

    private var expandedMediaRevealOpacity: Double {
        guard animateExpandedMediaAppearance else { return 1 }
        return hasRevealedExpandedMedia ? 1 : 0.01
    }

    private var expandedMediaRevealBlur: CGFloat {
        guard animateExpandedMediaAppearance else { return 0 }
        return hasRevealedExpandedMedia ? 0 : 6
    }

    private var mediaBackdrop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? .black.opacity(0.34) : .white.opacity(0.42))

            RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.18 : 0.32),
                            .clear
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 360
                    )
                )
                .blur(radius: 18)
        }
    }

    private func saveExpandedMedia() async {
        await MediaSaveCoordinator.save(media: media, context: saveContext) { title, message in
            alertTitle = title
            alertMessage = message
            showAlert = true
        }
    }

    @MainActor
    private func openExpandedMediaInPreview() async {
        guard !isOpeningInPreview else { return }
        isOpeningInPreview = true
        defer { isOpeningInPreview = false }

        do {
            try await MediaPreviewCoordinator.open(media: media, context: saveContext)
        } catch {
            alertTitle = "Media Preview Failed"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    @MainActor
    private func saveCurrentVideoFrame() async {
        guard !isSavingVideoFrame else { return }
        isSavingVideoFrame = true
        defer { isSavingVideoFrame = false }

        do {
            try await VideoFrameSaveCoordinator.saveCurrentFrame(
                player: videoPlayer,
                media: media,
                context: saveContext
            )
        } catch {
            alertTitle = "Video Frame Save Failed"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        if media.isPlayableVideo {
            ZStack {
                posterThumbnail

                FullscreenVideoView(
                    url: media.original,
                    loops: media.isAnimatedGIF,
                    onPlayerChange: { videoPlayer = $0 }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ZStack {
                if !didLoadExpandedThumbnail && !didLoadImage && imageLoadFailure == nil {
                    ShimmerPlaceholderView(cornerRadius: activeCornerRadius, includeBackgroundFill: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                posterThumbnail

                if imageLoadFailure != nil {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 30))
                        Text("Couldn’t load image")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                KFImage(media.original)
                    .onSuccess { result in
                        didLoadImage = true
                        imageLoadFailure = nil

                        let size = result.image.size
                        if size.width > 0, size.height > 0 {
                            imageBaseSize = size
                            targetSize = computeTargetSize(for: size)
                        }
                        scheduleExpandedMediaReveal()
                    }
                    .onFailure { error in
                        guard !error.isTaskCancelled else { return }
                        imageLoadFailure = error.localizedDescription
                        let _ = logger.error("Failed to load full-size image: \(media.original, privacy: .public) — error: \(error.localizedDescription, privacy: .public)")
                    }
                    .retry(maxCount: 2, interval: .seconds(1))
                    .backgroundDecode()
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous))
                    .opacity(didLoadImage ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var posterThumbnail: some View {
        KFImage(media.thumbnail)
            .onSuccess { _ in
                didLoadExpandedThumbnail = true
            }
            .onFailure { _ in
                didLoadExpandedThumbnail = false
            }
            .targetCache(SharedImagePipeline.thumbnailCache)
            .serialize(by: SharedImagePipeline.thumbnailCacheSerializer)
            .requestModifier(SharedImagePipeline.sharedRequestModifier)
            .backgroundDecode()
            .cancelOnDisappear(true)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: activeCornerRadius, style: .continuous))
            .opacity(didLoadImage ? 0 : 1)
    }

    private func scheduleExpandedMediaReveal() {
        guard animateExpandedMediaAppearance else {
            hasRevealedExpandedMedia = true
            return
        }

        guard !hasRevealedExpandedMedia else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                hasRevealedExpandedMedia = true
            }
        }
    }

    private func applyInitialViewerSize() {
        if let mediaSize {
            imageBaseSize = mediaSize
            targetSize = computeTargetSize(for: mediaSize)
            return
        }

        if let aspectRatio = media.feedAspectRatio {
            targetSize = computeTargetSize(forAspectRatio: aspectRatio)
            return
        }

        targetSize = nil
    }
}

