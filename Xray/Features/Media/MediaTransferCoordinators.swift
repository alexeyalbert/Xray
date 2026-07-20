//
//  MediaTransferCoordinators.swift
//  Xray
//

import AppKit
import AVKit
import Foundation
import UniformTypeIdentifiers

struct MediaSaveContext: Sendable, Equatable {
    let username: String
    let tweetID: String
    let scope: String
    let index: Int
}

struct MediaTransferDescriptor: Sendable, Equatable {
    let filename: String
    let contentType: UTType?
}

struct SelectedMediaItem: Identifiable, Equatable {
    let media: Media
    let saveContext: MediaSaveContext?
    
    var id: URL { media.id }
    
    static func == (lhs: SelectedMediaItem, rhs: SelectedMediaItem) -> Bool {
        lhs.media.id == rhs.media.id && lhs.saveContext == rhs.saveContext
    }
}

enum MediaSaveCoordinator {
    static func isDownloadableMedia(_ media: Media) -> Bool {
        guard let scheme = media.original.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
    
    static func isSaveableImageThumbnail(_ media: Media) -> Bool {
        !media.isPlayableVideo && isDownloadableMedia(media)
    }
    
    static func save(media: Media, context: MediaSaveContext?, onError: @escaping @MainActor (_ title: String, _ message: String) -> Void) async {
        guard let descriptor = transferDescriptor(for: media, context: context) else {
            await onError("Media Save Failed", "This media item can't be saved.")
            return
        }
        
        guard let destinationURL = await presentSavePanel(
            for: descriptor.filename,
            allowedContentType: descriptor.contentType
        ) else {
            return
        }
        
        guard let data = await SharedImagePipeline.mediaData(for: media.original) else {
            await onError(
                "Media Save Failed",
                "Xray couldn't download the original media from \(media.original.absoluteString)."
            )
            return
        }
        
        do {
            try data.write(to: destinationURL, options: [.atomic])
        } catch {
            await onError(
                "Media Save Failed",
                "Xray couldn't write the file to \(destinationURL.path): \(error.localizedDescription)"
            )
        }
    }
    
    static func transferDescriptor(for media: Media, context: MediaSaveContext?) -> MediaTransferDescriptor? {
        guard isDownloadableMedia(media) else { return nil }
        
        let fileExtension = preferredFileExtension(for: media.original)
        let contentType = UTType(filenameExtension: fileExtension)
        
        let fallbackScope: String
        if media.isAnimatedGIF {
            fallbackScope = "gif"
        } else if media.isVideo {
            fallbackScope = "video"
        } else {
            fallbackScope = "image"
        }
        
        let username = sanitizeFilenameComponent(context?.username ?? "unknown")
        let scope = sanitizeFilenameComponent(context?.scope ?? fallbackScope)
        let index = max(context?.index ?? 1, 1)
        
        let filename: String
        if let tweetID = context?.tweetID, !tweetID.isEmpty {
            filename = "xray_\(username)_tweet_\(tweetID)_\(scope)_\(index).\(fileExtension)"
        } else {
            filename = "xray_\(username)_\(scope)_\(index).\(fileExtension)"
        }
        
        return MediaTransferDescriptor(filename: filename, contentType: contentType)
    }
    
    @MainActor
    private static func presentSavePanel(for filename: String, allowedContentType: UTType?) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = filename
        panel.title = "Save Original Media"
        if let allowedContentType {
            panel.allowedContentTypes = [allowedContentType]
        }
        
        return panel.runModal() == .OK ? panel.url : nil
    }
    
    private static func preferredFileExtension(for url: URL) -> String {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let format = components.queryItems?.first(where: { $0.name == "format" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !format.isEmpty {
            return normalizedFileExtension(format)
        }
        
        if !url.pathExtension.isEmpty {
            return normalizedFileExtension(url.pathExtension)
        }
        
        return "jpg"
    }
    
    private static func normalizedFileExtension(_ ext: String) -> String {
        let cleaned = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cleaned {
        case "jpeg":
            return "jpg"
        default:
            return cleaned.isEmpty ? "jpg" : cleaned
        }
    }
    
    private static func sanitizeFilenameComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let collapsed = sanitized.replacingOccurrences(
            of: #"-{2,}"#,
            with: "-",
            options: .regularExpression
        )
        let finalValue = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return finalValue.isEmpty ? "unknown" : finalValue
    }
}

enum MediaPreviewCoordinator {
    private static let previewBundleIdentifier = "com.apple.Preview"
    private static let tempExportRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("XrayPreviewMedia", isDirectory: true)
    private static let sessionDirectoryURL: URL = {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: tempExportRootURL)

        let directoryURL = tempExportRootURL
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }()

    static func canOpen(_ media: Media) -> Bool {
        !media.isPlayableVideo && MediaSaveCoordinator.isDownloadableMedia(media)
    }

    static func open(media: Media, context: MediaSaveContext?) async throws {
        guard canOpen(media),
              let descriptor = MediaSaveCoordinator.transferDescriptor(for: media, context: context) else {
            throw previewError("This media item can't be opened in Preview.")
        }

        guard let data = await SharedImagePipeline.mediaData(for: media.original) else {
            throw previewError(
                "Xray couldn't download the original media from \(media.original.absoluteString)."
            )
        }

        let exportDirectoryURL = sessionDirectoryURL
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true)

        let temporaryFileURL = exportDirectoryURL
            .appendingPathComponent(descriptor.filename, isDirectory: false)
        try data.write(to: temporaryFileURL, options: [.atomic])
        try await openInPreview(temporaryFileURL)
    }

    @MainActor
    private static func openInPreview(_ fileURL: URL) async throws {
        guard let previewApplicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: previewBundleIdentifier
        ) else {
            throw previewError("Xray couldn't find the Preview app.")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: previewApplicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func previewError(_ description: String) -> NSError {
        NSError(
            domain: "com.alexeyalbert.Xray.MediaPreview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

@MainActor
enum VideoFrameSaveCoordinator {
    static func saveCurrentFrame(
        player: AVPlayer?,
        media: Media,
        context: MediaSaveContext?
    ) async throws {
        guard media.isVideo,
              MediaSaveCoordinator.isDownloadableMedia(media),
              let asset = player?.currentItem?.asset,
              let requestedTime = player?.currentTime() else {
            throw frameSaveError("The current video frame isn't available yet.")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: requestedTime)

        let bitmap = NSBitmapImageRep(cgImage: frame.image)
        guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
            throw frameSaveError("Xray couldn't encode the current video frame as an image.")
        }

        guard let filename = suggestedFilename(for: media, context: context),
              let destinationURL = presentSavePanel(for: filename) else {
            return
        }

        do {
            try imageData.write(to: destinationURL, options: [.atomic])
        } catch {
            throw frameSaveError(
                "Xray couldn't write the image to \(destinationURL.path): \(error.localizedDescription)"
            )
        }
    }

    private static func suggestedFilename(for media: Media, context: MediaSaveContext?) -> String? {
        guard let descriptor = MediaSaveCoordinator.transferDescriptor(for: media, context: context) else {
            return nil
        }

        let basename = (descriptor.filename as NSString).deletingPathExtension
        return "\(basename)_frame.png"
    }

    private static func presentSavePanel(for filename: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = filename
        panel.title = "Save Current Video Frame"
        panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func frameSaveError(_ description: String) -> NSError {
        NSError(
            domain: "com.alexeyalbert.Xray.VideoFrameSave",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

enum MediaDragCoordinator {
    private static let tempExportRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("XrayDraggedMedia", isDirectory: true)
    private static let sessionDirectoryURL = tempExportRootURL
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    
    static func itemProvider(for media: Media, context: MediaSaveContext?) -> NSItemProvider? {
        guard let descriptor = MediaSaveCoordinator.transferDescriptor(for: media, context: context) else {
            return nil
        }
        
        let contentType = descriptor.contentType ?? .data
        let provider = NSItemProvider()
        provider.suggestedName = (descriptor.filename as NSString).deletingPathExtension
        
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 100)
            let exportTask = Task.detached(priority: .userInitiated) {
                do {
                    let exportedFileURL = try await exportTemporaryFile(
                        for: media,
                        descriptor: descriptor,
                        progress: progress
                    )
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: exportedFileURL)
                        completion(nil, false, CancellationError())
                        return
                    }
                    completion(exportedFileURL, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            
            progress.cancellationHandler = {
                exportTask.cancel()
            }
            
            return progress
        }
        
        provider.registerDataRepresentation(
            forTypeIdentifier: contentType.identifier,
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 100)
            let exportTask = Task.detached(priority: .userInitiated) {
                let data = await SharedImagePipeline.mediaData(for: media.original)
                guard !Task.isCancelled else {
                    completion(nil, CancellationError())
                    return
                }
                progress.completedUnitCount = 100
                completion(data, data == nil ? dragError(for: media.original) : nil)
            }
            
            progress.cancellationHandler = {
                exportTask.cancel()
            }
            
            return progress
        }
        
        return provider
    }
    
    private static func exportTemporaryFile(
        for media: Media,
        descriptor: MediaTransferDescriptor,
        progress: Progress
    ) async throws -> URL {
        progress.completedUnitCount = 5
        
        guard let data = await SharedImagePipeline.mediaData(for: media.original) else {
            throw dragError(for: media.original)
        }
        
        try FileManager.default.createDirectory(
            at: sessionDirectoryURL,
            withIntermediateDirectories: true
        )
        
        let exportDirectoryURL = sessionDirectoryURL
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectoryURL,
            withIntermediateDirectories: true
        )
        
        let destinationURL = exportDirectoryURL.appendingPathComponent(descriptor.filename, isDirectory: false)
        progress.completedUnitCount = 70
        try data.write(to: destinationURL, options: [.atomic])
        progress.completedUnitCount = 100
        return destinationURL
    }
    
    nonisolated private static func dragError(for url: URL) -> NSError {
        NSError(
            domain: "com.alexeyalbert.Xray.MediaDrag",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Xray couldn't prepare draggable media from \(url.absoluteString)."
            ]
        )
    }
}
