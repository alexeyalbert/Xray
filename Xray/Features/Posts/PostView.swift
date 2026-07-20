//
//  PostView.swift
//  Xray
//

import AppKit
import Kingfisher
import os
import SwiftUI

struct PostView: View {
    @State private var post: Post
    @AppStorage(DebugSettings.showTemporaryHidePostActionKey)
    private var showTemporaryHidePostAction = false
    var isVisible: Bool = true
    var shouldAnimateMediaAppearance: Bool = true
    var isInteractive: Bool = true
    var searchDebugContext: SearchDebugContext? = nil
    var onTopicSelected: (String, TopicSearchScope) -> Void = { _, _ in }
    var onMediaSelected: (SelectedMediaItem) -> Void = { _ in }
    var onFindSimilarImages: (Media) -> Void = { _ in }
    var onPostTemporarilyHidden: (Int) -> Void = { _ in }
    var onPostDeleted: (Int) -> Void = { _ in }
    @State private var didPushPointingHandCursor: Bool = false
    @State private var showTopicEditor: Bool = false
    @State private var topicEditorPrimary: String = ""
    @State private var topicEditorSecondary: String = ""
    @State private var lastSearchQuery: String = ""
    @State private var alertTitle: String = "Notice"
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false
    @State private var debugSheet: DebugSheetPayload? = nil
    @State private var mediaThumbnailDebugSnapshots: [URL: MediaThumbnailDebugSnapshot] = [:]
    
    @Environment(\.openURL) private var openURL
    
    let logger = Logger(subsystem: "com.alexeyalbert.Xray", category: "PostView")
    
    init(
        Post initialPost: Post,
        isVisible: Bool = true,
        shouldAnimateMediaAppearance: Bool = true,
        isInteractive: Bool = true,
        searchDebugContext: SearchDebugContext? = nil,
        onTopicSelected: @escaping (String, TopicSearchScope) -> Void = { _, _ in },
        onMediaSelected: @escaping (SelectedMediaItem) -> Void = { _ in },
        onFindSimilarImages: @escaping (Media) -> Void = { _ in },
        onPostTemporarilyHidden: @escaping (Int) -> Void = { _ in },
        onPostDeleted: @escaping (Int) -> Void = { _ in }
    ) {
        _post = State(initialValue: initialPost)
        self.isVisible = isVisible
        self.shouldAnimateMediaAppearance = shouldAnimateMediaAppearance
        self.isInteractive = isInteractive
        self.searchDebugContext = searchDebugContext
        self.onTopicSelected = onTopicSelected
        self.onMediaSelected = onMediaSelected
        self.onFindSimilarImages = onFindSimilarImages
        self.onPostTemporarilyHidden = onPostTemporarilyHidden
        self.onPostDeleted = onPostDeleted
    }
    
    var body: some View {
        VStack {
            PostAuthorHeader(
                profileImageURL: post.profile_image_url,
                username: post.screen_name,
                profileImageShape: post.profile_image_shape,
                displayName: post.name,
                createdAt: post.created_at
            )
            let visibleLinks = post.links.filter { link in
                guard let quotedPost = post.quoted_post else { return true }
                return !link.pointsToQuotedPost(quotedPost)
            }
            let inlineLinks = visibleLinks.filter { !($0.card?.hasPreviewContent ?? false) }
            let previewLinks = visibleLinks.filter { $0.card?.hasPreviewContent ?? false }
            if let displayText = post.displayText {
                InlinePostText(
                    text: displayText,
                    links: inlineLinks,
                    isInteractive: isInteractive
                )
                .padding(.horizontal, 5)
                .padding(.top, 2)
            } else if !inlineLinks.isEmpty {
                InlinePostText(
                    text: "",
                    links: inlineLinks,
                    isInteractive: isInteractive
                )
                .padding(.horizontal, 5)
                .padding(.top, 2)
            }
            if !previewLinks.isEmpty {
                LinkPreviewList(
                    links: previewLinks,
                    isInteractive: isInteractive,
                    isParentVisible: isVisible
                )
            }
            if let article = post.article {
                ArticleView(
                    article: article,
                    isParentVisible: isVisible,
                    shouldAnimateMediaAppearance: shouldAnimateMediaAppearance,
                    isMediaInteractive: false,
                    onMediaSelected: { media in
                        onMediaSelected(mediaSelectionItem(for: media))
                    },
                    dragContextForMedia: mediaSaveContext(for:),
                    contextMenuContent: imageContextMenuView(for:),
                    onDebugUpdate: { snapshot in
                        mediaThumbnailDebugSnapshots[snapshot.mediaID] = snapshot
                    }
                )
            }
            if let media = post.media, !media.isEmpty {
                PostMediaGallery(
                    media: media,
                    isParentVisible: isVisible,
                    shouldAnimateAppearance: shouldAnimateMediaAppearance,
                    isInteractive: isInteractive,
                    dragContextForMedia: mediaSaveContext(for:),
                    onMediaSelected: { media in
                        onMediaSelected(mediaSelectionItem(for: media))
                    },
                    contextMenuContent: imageContextMenuView(for:),
                    onDebugUpdate: { snapshot in
                        mediaThumbnailDebugSnapshots[snapshot.mediaID] = snapshot
                    }
                )
            }
            if let quotedPost = post.quoted_post {
                QuotedPostCard(
                    post: quotedPost,
                    isParentVisible: isVisible,
                    shouldAnimateMediaAppearance: shouldAnimateMediaAppearance,
                    isInteractive: isInteractive,
                    dragContextForMedia: mediaSaveContext(for:),
                    onMediaSelected: { media in
                        onMediaSelected(mediaSelectionItem(for: media))
                    },
                    contextMenuContent: imageContextMenuView(for:),
                    onDebugUpdate: { snapshot in
                        mediaThumbnailDebugSnapshots[snapshot.mediaID] = snapshot
                    }
                )
            }
            PostTopicChips(
                primaryTopic: post.primary_topic,
                secondaryTopics: post.secondary_topics,
                isInteractive: isInteractive,
                onTopicSelected: onTopicSelected
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .clipped(antialiased: true)
        .modifier(PostBackgroundStyle())
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .if(post.article != nil && isInteractive) { view in
            view
                .onTapGesture {
                    openURL(post.url)
                }
                .onHover { isHovering in
                    if isHovering {
                        guard !didPushPointingHandCursor else { return }
                        NSCursor.pointingHand.push()
                        didPushPointingHandCursor = true
                    } else {
                        guard didPushPointingHandCursor else { return }
                        NSCursor.pop()
                        didPushPointingHandCursor = false
                    }
                }
        }
        .if(isInteractive) { view in
            view.contextMenu {
                postContextMenuContent()
            }
        }
        .sheet(isPresented: $showTopicEditor) {
            topicEditorSheet
        }
        .sheet(item: $debugSheet) { payload in
            debugSheetView(payload: payload)
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }
}


extension PostView {
    private var topicEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Stored Topics")
                .font(.title3.weight(.semibold))
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Primary Topic")
                    .font(.headline)
                TextField("Primary topic", text: $topicEditorPrimary)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Secondary Topics")
                    .font(.headline)
                Text("Use commas or new lines to separate topics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $topicEditorSecondary)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                    }
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    showTopicEditor = false
                }
                Button("Save") {
                    Task { await saveEditedTopics() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
    
    @MainActor
    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
    
    @MainActor
    private func presentDebugSheet(title: String, body: String) {
        debugSheet = DebugSheetPayload(title: title, body: body)
    }
    
    @MainActor
    private func updateTopicsLocally(primaryTopic: String, secondaryTopics: [String]) {
        post = Xray.Post(
            id: post.id,
            created_at: post.created_at,
            full_text: post.full_text,
            media: post.media,
            article: post.article,
            quoted_post: post.quoted_post,
            screen_name: post.screen_name,
            name: post.name,
            profile_image_url: post.profile_image_url,
            profile_image_shape: post.profile_image_shape,
            url: post.url,
            text_embedding: post.text_embedding,
            img_embedding: post.img_embedding,
            primary_topic: primaryTopic,
            secondary_topics: secondaryTopics
        )
    }
    
    @MainActor
    private func openTopicEditor() {
        topicEditorPrimary = post.primary_topic
        topicEditorSecondary = post.secondary_topics.joined(separator: ", ")
        showTopicEditor = true
    }
    
    private func clearStoredTopics() async {
        do {
            try await sqliteManager.clearTopics(forPostID: post.id)
            updateTopicsLocally(primaryTopic: "", secondaryTopics: [])
        } catch {
            presentAlert(title: "Topic Reset Failed", message: error.localizedDescription)
        }
    }
    
    private func deletePostFromDatabase() async {
        do {
            try await sqliteManager.deletePost(forPostID: post.id)
            await MainActor.run {
                onPostDeleted(post.id)
            }
        } catch {
            presentAlert(title: "Delete Failed", message: error.localizedDescription)
        }
    }
    
    private func saveEditedTopics() async {
        let primary = topicEditorPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = parseSecondaryTopics(topicEditorSecondary)
        
        do {
            try await sqliteManager.updateTopics(forPostID: post.id, primaryTopic: primary, secondaryTopics: secondary)
            updateTopicsLocally(primaryTopic: primary, secondaryTopics: secondary)
            showTopicEditor = false
        } catch {
            presentAlert(title: "Topic Save Failed", message: error.localizedDescription)
        }
    }
    
    private func parseSecondaryTopics(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
    
    private func currentSearchQuery() -> String? {
        if let searchDebugContext {
            guard let query = searchDebugContext.query?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return nil
            }
            return query
        }
        // Best-effort: read last query stored in UserDefaults by ContentView
        let q = UserDefaults.standard.string(forKey: "LastSearchQuery")
        return q?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? q : nil
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        if n == 0 { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        var i = 0
        while i < n {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
            i += 1
        }
        let denom = max(1e-12, sqrt(na) * sqrt(nb))
        return dot / denom
    }
    
    private func l2Normalize(_ v: [Float]) -> [Float] {
        let s = v.reduce(0.0) { $0 + Double($1) * Double($1) }
        let n = max(1e-12, sqrt(s))
        return v.map { $0 / Float(n) }
    }
    
    private func compareEmbeddingWithCurrentSearch() async {
        guard let q = currentSearchQuery() else {
            presentAlert(title: "Embedding Similarity", message: "No active search query.")
            return
        }
        lastSearchQuery = q
        let qVec = await EmbeddingsManager.embed(text: q) ?? []
        guard !qVec.isEmpty else {
            presentAlert(title: "Embedding Similarity", message: "Failed to embed search query.")
            return
        }
        do {
            if let pVec = try await sqliteManager.fetchTextEmbedding(for: post.id) {
                let sim = cosineSimilarity(l2Normalize(qVec), l2Normalize(pVec))
                presentAlert(title: "Embedding Similarity", message: String(format: "Similarity with '%@': %.4f", q, sim))
            } else {
                presentAlert(title: "Embedding Similarity", message: "Post has no stored embedding.")
            }
        } catch {
            presentAlert(title: "Embedding Similarity", message: "Compare failed: \(error.localizedDescription)")
        }
    }
    
    private func showRawSQLiteRow() async {
        do {
            let explanation = try await sqliteManager.fetchRawPostDebugRow(postID: post.id)
            presentDebugSheet(title: explanation.title, body: explanation.body)
        } catch {
            presentAlert(title: "SQLite Row Failed", message: error.localizedDescription)
        }
    }
    
    private func showSearchExplanation() async {
        guard let context = searchDebugContext else {
            presentAlert(title: "Search Debug", message: "This option is only available while viewing search results.")
            return
        }
        
        do {
            let explanation: SQLiteManager.SearchDebugExplanation
            if let referenceMedia = context.similarImageMedia {
                explanation = try await sqliteManager.explainWhySimilarImageSearchResultContains(
                    postID: post.id,
                    referenceMedia: referenceMedia
                )
            } else if let query = context.query, let mode = context.mode {
                explanation = try await sqliteManager.explainWhySearchResultContains(
                    postID: post.id,
                    query: query,
                    mode: mode
                )
            } else {
                presentAlert(title: "Search Debug", message: "The active search context is incomplete.")
                return
            }
            presentDebugSheet(title: explanation.title, body: explanation.body)
        } catch {
            presentAlert(title: "Search Debug Failed", message: error.localizedDescription)
        }
    }
    
    private func showPostDebugInspector() async {
        do {
            let storedEmbeddingDimensions = try await sqliteManager.fetchStoredEmbeddingDimensions(for: post.id)
            presentDebugSheet(
                title: "Post Debug Info",
                body: buildPostDebugReport(storedEmbeddingDimensions: storedEmbeddingDimensions)
            )
        } catch {
            presentAlert(title: "Post Debug Info Failed", message: error.localizedDescription)
        }
    }
    
    private func buildPostDebugReport(storedEmbeddingDimensions: (text: Int?, normalizedText: Int?, image: Int?)) -> String {
        var sections: [String] = []
        let storedTextDims = storedEmbeddingDimensions.text.map(String.init) ?? "nil"
        let storedNormalizedTextDims = storedEmbeddingDimensions.normalizedText.map(String.init) ?? "nil"
        let storedImageDims = storedEmbeddingDimensions.image.map(String.init) ?? "nil"
        
        sections.append(
            [
                "POST",
                "id: \(post.id)",
                "author: @\(post.screen_name) (\(post.name))",
                "created_at: \(post.created_at.formatted(date: .abbreviated, time: .standard))",
                "url: \(post.url.absoluteString)",
                "profile_image_shape: \(post.profile_image_shape.rawValue)",
                "text_chars: \(post.full_text.count)",
                "text_embedding_dims: \(storedTextDims)",
                "text_embedding_normalized_dims: \(storedNormalizedTextDims)",
                "img_embedding_dims: \(storedImageDims)",
                "text_embedding_dims_in_memory: \(post.text_embedding.count)",
                "img_embedding_dims_in_memory: \(post.img_embedding.count)",
                "primary_topic: \(post.primary_topic.isEmpty ? "<empty>" : post.primary_topic)",
                "secondary_topics: \(post.secondary_topics.isEmpty ? "[]" : post.secondary_topics.joined(separator: ", "))",
                "bookmark_import_generation: \(post.bookmark_import_generation?.description ?? "nil")",
                "bookmark_order: \(post.bookmark_order?.description ?? "nil")",
                "media_count: \(post.media?.count ?? 0)",
                "quoted_post: \(post.quoted_post != nil ? "yes" : "no")",
                "analysis_media_count: \(post.analysisMedia?.count ?? 0)"
            ].joined(separator: "\n")
        )
        
        sections.append(mediaDebugSection(title: "POST MEDIA", mediaItems: post.media))
        
        if let quotedPost = post.quoted_post {
            sections.append(
                [
                    "QUOTED POST",
                    "id: \(quotedPost.id)",
                    "author: @\(quotedPost.screen_name) (\(quotedPost.name))",
                    "created_at: \(quotedPost.created_at?.formatted(date: .abbreviated, time: .standard) ?? "nil")",
                    "url: \(quotedPost.url.absoluteString)",
                    "profile_image_shape: \(quotedPost.profile_image_shape.rawValue)",
                    "text_chars: \(quotedPost.full_text.count)",
                    "media_count: \(quotedPost.media?.count ?? 0)"
                ].joined(separator: "\n")
            )
            sections.append(mediaDebugSection(title: "QUOTED MEDIA", mediaItems: quotedPost.media))
        }
        
        return sections
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    
    private func mediaDebugSection(title: String, mediaItems: [Media]?) -> String {
        guard let mediaItems else {
            return "\(title)\ncount: 0"
        }
        guard !mediaItems.isEmpty else {
            return "\(title)\ncount: 0"
        }
        
        var lines = ["\(title)", "count: \(mediaItems.count)"]
        for (index, media) in mediaItems.enumerated() {
            lines.append("")
            lines.append(contentsOf: mediaDebugLines(for: media, label: "\(title.lowercased().replacingOccurrences(of: " ", with: "_"))[\(index)]"))
        }
        return lines.joined(separator: "\n")
    }
    
    private func mediaDebugLines(for media: Media, label: String) -> [String] {
        let thumbnailRuntime = mediaThumbnailDebugSnapshots[media.id]
        let renderedProcessorIdentifier = thumbnailRuntime?.processorIdentifier ?? DefaultImageProcessor.default.identifier
        
        let renderedThumbnailCache = SharedImagePipeline.cacheDebugSnapshot(
            in: SharedImagePipeline.thumbnailCache,
            for: media.thumbnail,
            processorIdentifier: renderedProcessorIdentifier
        )
        let originalThumbnailCache = SharedImagePipeline.cacheDebugSnapshot(
            in: SharedImagePipeline.thumbnailCache,
            for: media.thumbnail
        )
        let detailCache = SharedImagePipeline.cacheDebugSnapshot(
            in: ImageCache.default,
            for: media.original
        )
        let metadataThumbnailCache = SharedImagePipeline.cacheDebugSnapshot(for: media.thumbnail)
        let metadataOriginalCache = media.thumbnail == media.original
        ? metadataThumbnailCache
        : SharedImagePipeline.cacheDebugSnapshot(for: media.original)
        
        var lines = [
            "[\(label)]",
            "type: \(media.type)",
            "is_video: \(yesNo(media.isVideo))",
            "is_animated_gif: \(yesNo(media.isAnimatedGIF))",
            "is_playable_video: \(yesNo(media.isPlayableVideo))",
            "stored_dimensions: \(storedDimensionsDescription(for: media))",
            "feed_aspect_ratio: \(feedAspectRatioDescription(for: media))",
            "feed_rendition_url: \(media.thumbnail.absoluteString)",
            "feed_rendition_quality: \(qualityDescription(for: media.thumbnail))",
            "detail_rendition_url: \(media.original.absoluteString)",
            "detail_rendition_quality: \(qualityDescription(for: media.original))"
        ]
        
        if let thumbnailRuntime {
            lines.append("feed_last_load: \(lastLoadDescription(for: thumbnailRuntime))")
            lines.append("feed_requested_pixels: \(pixelSizeDescription(thumbnailRuntime.requestedPixelSize))")
            lines.append("feed_processor_identifier: \(thumbnailRuntime.processorIdentifier)")
            if let sourceURL = thumbnailRuntime.sourceURL {
                lines.append("feed_loaded_from_source: \(sourceURL.absoluteString)")
            }
            if let originalSourceURL = thumbnailRuntime.originalSourceURL,
               originalSourceURL != thumbnailRuntime.sourceURL {
                lines.append("feed_original_source: \(originalSourceURL.absoluteString)")
            }
            if let failureDescription = thumbnailRuntime.failureDescription {
                lines.append("feed_last_error: \(failureDescription)")
            }
        } else {
            lines.append("feed_last_load: not observed in this session")
        }
        
        lines.append("feed_render_cache_now: \(cacheSnapshotSummary(renderedThumbnailCache))")
        if renderedProcessorIdentifier != DefaultImageProcessor.default.identifier {
            lines.append("feed_original_cache_now: \(cacheSnapshotSummary(originalThumbnailCache))")
        }
        lines.append("detail_cache_now: \(cacheSnapshotSummary(detailCache))")
        lines.append("metadata_thumbnail_cache: \(cacheSnapshotSummary(metadataThumbnailCache))")
        if media.original != media.thumbnail {
            lines.append("metadata_detail_cache: \(cacheSnapshotSummary(metadataOriginalCache))")
        }
        
        return lines
    }
    
    private func lastLoadDescription(for snapshot: MediaThumbnailDebugSnapshot) -> String {
        let time = snapshot.updatedAt.formatted(date: .omitted, time: .standard)
        if let failureDescription = snapshot.failureDescription {
            return "failed at \(time) (\(failureDescription))"
        }
        
        guard let cacheType = snapshot.cacheType else {
            return "unknown at \(time)"
        }
        
        return "\(loadOriginDescription(cacheType)) at \(time)"
    }
    
    private func loadOriginDescription(_ cacheType: CacheType) -> String {
        switch cacheType {
        case .none:
            return "fetched from network"
        case .memory:
            return "loaded from memory cache"
        case .disk:
            return "loaded from disk cache"
        }
    }
    
    private func cacheSnapshotSummary(_ snapshot: ImageCacheDebugSnapshot?) -> String {
        guard let snapshot else { return "n/a" }
        
        let base: String = {
            switch snapshot.cacheType {
            case .none:
                return "not cached"
            case .memory:
                return "memory"
            case .disk:
                return "disk"
            }
        }()
        
        if let bytes = snapshot.diskFileBytes {
            return "\(base) (disk copy: \(byteCountDescription(bytes)))"
        }
        if snapshot.diskFileURL != nil {
            return "\(base) (disk copy present)"
        }
        return base
    }
    
    private func qualityDescription(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.pathExtension.isEmpty ? "unlabeled" : "ext=\(url.pathExtension.lowercased())"
        }
        
        var parts: [String] = []
        if let name = components.queryItems?.first(where: { $0.name == "name" })?.value, !name.isEmpty {
            parts.append("name=\(name)")
        }
        if let format = components.queryItems?.first(where: { $0.name == "format" })?.value, !format.isEmpty {
            parts.append("format=\(format)")
        }
        if parts.isEmpty, !url.pathExtension.isEmpty {
            parts.append("ext=\(url.pathExtension.lowercased())")
        }
        
        return parts.isEmpty ? "unlabeled" : parts.joined(separator: ", ")
    }
    
    private func storedDimensionsDescription(for media: Media) -> String {
        guard let width = media.width, let height = media.height else {
            return "unknown"
        }
        return "\(Int(width.rounded()))x\(Int(height.rounded()))"
    }
    
    private func feedAspectRatioDescription(for media: Media) -> String {
        guard let ratio = media.feedAspectRatio else {
            return "unknown"
        }
        return String(format: "%.3f", ratio)
    }
    
    private func pixelSizeDescription(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
    
    private func byteCountDescription(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func postContextMenuContent(saveImageMedia: Media? = nil) -> PostContextMenuContent {
        PostContextMenuContent(
            saveImageAction: saveImageMedia.map { media in
                {
                    let saveContext = mediaSaveContext(for: media)
                    Task {
                        await MediaSaveCoordinator.save(media: media, context: saveContext) { title, message in
                            presentAlert(title: title, message: message)
                        }
                    }
                }
            },
            findSimilarImagesAction: saveImageMedia.map { media in
                { onFindSimilarImages(media) }
            },
            viewInBrowserAction: {
                openURL(post.url)
            },
            temporarilyHidePostAction: showTemporaryHidePostAction ? {
                onPostTemporarilyHidden(post.id)
            } : nil,
            showRawSQLiteRowAction: DebugSettings.showPostContextDebugOptions ? {
                Task { await showRawSQLiteRow() }
            } : nil,
            showSearchExplanationAction: searchDebugContext != nil ? {
                Task { await showSearchExplanation() }
            } : nil,
            compareEmbeddingAction: DebugSettings.showPostContextDebugOptions ? {
                Task { await compareEmbeddingWithCurrentSearch() }
            } : nil,
            showPostDebugAction: DebugSettings.showPostContextDebugOptions ? {
                Task { await showPostDebugInspector() }
            } : nil,
            editTopicsAction: {
                openTopicEditor()
            },
            deletePostAction: {
                Task { await deletePostFromDatabase() }
            },
            resetTopicsAction: {
                Task { await clearStoredTopics() }
            },
            isResetTopicsDisabled: post.primary_topic.isEmpty && post.secondary_topics.isEmpty
        )
    }
    
    private func imageContextMenuView(for media: Media) -> AnyView {
        AnyView(postContextMenuContent(saveImageMedia: MediaSaveCoordinator.isSaveableImageThumbnail(media) ? media : nil))
    }
    
    private func mediaSelectionItem(for media: Media) -> SelectedMediaItem {
        SelectedMediaItem(media: media, saveContext: mediaSaveContext(for: media))
    }
    
    private func mediaSaveContext(for media: Media) -> MediaSaveContext? {
        if let mediaIndex = post.media?.firstIndex(where: { $0.id == media.id }) {
            return MediaSaveContext(
                username: post.screen_name,
                tweetID: String(post.id),
                scope: media.isPlayableVideo ? "video" : "image",
                index: mediaIndex + 1
            )
        }
        
        if let quotedPost = post.quoted_post,
           let mediaIndex = quotedPost.media?.firstIndex(where: { $0.id == media.id }) {
            return MediaSaveContext(
                username: quotedPost.screen_name,
                tweetID: String(quotedPost.id),
                scope: media.isPlayableVideo ? "quoted-video" : "quoted-image",
                index: mediaIndex + 1
            )
        }
        
        if let mediaIndex = post.article?.allMedia.firstIndex(where: { $0.id == media.id }) {
            return MediaSaveContext(
                username: post.screen_name,
                tweetID: String(post.id),
                scope: media.isPlayableVideo ? "article-video" : "article-image",
                index: mediaIndex + 1
            )
        }
        
        return nil
    }
    
    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
    
    @ViewBuilder
    private func debugSheetView(payload: DebugSheetPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(payload.title)
                .font(.title3.weight(.semibold))
            
            ScrollView {
                Text(payload.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            
            HStack {
                Spacer()
                Button("Close") {
                    debugSheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct DebugSheetPayload: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}
