import Foundation

private enum EmbeddingGenerationError: LocalizedError {
    case noEmbeddingsGenerated(pageStart: Int, pageCount: Int)
    case noRowsUpdated(pageStart: Int, pageCount: Int)
    case rowCountMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .noEmbeddingsGenerated(pageStart, pageCount):
            return "No embeddings were generated for posts \(pageStart)-\(pageStart + pageCount - 1)."
        case let .noRowsUpdated(pageStart, pageCount):
            return "Generated embeddings for posts \(pageStart)-\(pageStart + pageCount - 1), but SQLite did not persist any rows."
        case let .rowCountMismatch(expected, actual):
            return "SQLite persisted \(actual) of \(expected) generated text embeddings."
        }
    }
}

extension AppModel {
    func requestEmbeddingStop() {
        guard !importState.isEmbeddingStopRequested else { return }

        if importState.isTextEmbeddingGenerating {
            importState.isEmbeddingStopRequested = true
            importState.databaseImportStatus = "Stopping after the current text embedding batch is saved..."
            importState.textEmbeddingStatus = importState.databaseImportStatus
        } else if importState.isImageEmbeddingGenerating {
            importState.isEmbeddingStopRequested = true
            importState.databaseImportStatus = "Stopping after the current image embedding chunk is saved..."
            importState.imageEmbeddingStatus = importState.databaseImportStatus
        }
    }

    // Process all posts to compute and store text embeddings.
    func processAllPostsEmbeddings() async {
        guard !importState.isDatabaseImporting else { return }
        await MainActor.run {
            importState.clearEnrichmentPresentationState()
            importState.isDatabaseImporting = true
            importState.databaseImportStatus = "Preparing to generate text embeddings..."
            importState.databaseImportError = nil
            importState.databaseImportCompleted = false

            importState.isTextEmbeddingGenerating = true
            importState.textEmbeddingStatus = "Preparing text embeddings..."
            importState.textEmbeddingError = nil
            importState.textEmbeddingCompleted = false
        }

        do {
            try await sqliteManager.connect()
            let initialCounts = try await sqliteManager.getTextEmbeddingProgressCounts()
            let total = initialCounts.total
            var completed = initialCounts.completed
            let batchSize = EmbeddingsManager.textEmbeddingBatchSize
            var processed = 0

            await MainActor.run {
                let progress = total == 0 ? 1.0 : Double(completed) / Double(total)
                let status = "\(completed) of \(total) eligible posts complete. \(initialCounts.remaining) remaining."
                importState.databaseImportProgress = progress
                importState.databaseImportStatus = status
                importState.textEmbeddingProgress = progress
                importState.textEmbeddingStatus = status
            }

            var beforeCreatedAt: Date? = nil
            var beforeId: Int? = nil

            while true {
                if importState.isEmbeddingStopRequested { break }

                let page = try await sqliteManager.fetchPostsMissingTextEmbeddings(limit: batchSize, beforeCreatedAt: beforeCreatedAt, beforeId: beforeId)
                if page.isEmpty { break }

                let indicesAndTexts: [(Int, String)] = page.enumerated().compactMap { index, post in
                    let text = post.analysisText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : (index, text)
                }
                let vectors = await EmbeddingsManager.embedBatch(texts: indicesAndTexts.map { $0.1 })

                var pairs: [(id: Int, embedding: [Float])] = []
                pairs.reserveCapacity(vectors.count)
                for (j, vector) in vectors.enumerated() {
                    guard j < indicesAndTexts.count else { break }
                    pairs.append((id: page[indicesAndTexts[j].0].id, embedding: vector))
                    if j % 16 == 0 { await Task.yield() }
                }

                guard !pairs.isEmpty else {
                    throw EmbeddingGenerationError.noEmbeddingsGenerated(pageStart: processed + 1, pageCount: page.count)
                }

                // Update DB
                let savedCount = try await sqliteManager.updateTextEmbeddings(pairs)
                guard savedCount != 0 else {
                    throw EmbeddingGenerationError.noRowsUpdated(pageStart: processed + 1, pageCount: page.count)
                }
                guard savedCount == pairs.count else {
                    throw EmbeddingGenerationError.rowCountMismatch(expected: pairs.count, actual: savedCount)
                }

                processed += savedCount
                completed += savedCount
                await MainActor.run {
                    let progress = total == 0 ? 1.0 : min(1.0, Double(completed) / Double(total))
                    importState.databaseImportProgress = progress
                    importState.databaseImportStatus = "\(completed) of \(total) eligible posts complete. \(max(0, total - completed)) remaining."
                    importState.textEmbeddingProgress = progress
                    importState.textEmbeddingStatus = importState.databaseImportStatus
                }

                // Advance keyset cursor based on last of the fetched page from general fetch to maintain order
                if let last = page.last {
                    beforeCreatedAt = last.created_at
                    beforeId = last.id
                }

                if page.count < batchSize { break }
            }

            let wasStopped = importState.isEmbeddingStopRequested
            if wasStopped {
                await MainActor.run {
                    importState.databaseImportStatus = "Unloading the text embedding model..."
                    importState.textEmbeddingStatus = importState.databaseImportStatus
                }
            }
            EmbeddingsManager.unloadTextModel()

            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportCompleted = !wasStopped
                importState.databaseImportStatus = wasStopped
                    ? "Text embedding stopped safely: \(completed) of \(total) eligible posts complete; \(max(0, total - completed)) remaining. Updated \(processed) this run."
                    : "Text embedding pass finished: \(completed) of \(total) eligible posts complete; \(max(0, total - completed)) remaining. Updated \(processed) this run."
                importState.databaseImportProgress = total == 0 ? 1.0 : Double(completed) / Double(total)

                importState.isTextEmbeddingGenerating = false
                importState.textEmbeddingCompleted = !wasStopped
                importState.textEmbeddingProgress = importState.databaseImportProgress
                importState.textEmbeddingStatus = importState.databaseImportStatus
                importState.isEmbeddingStopRequested = false
            }
        } catch {
            EmbeddingsManager.unloadTextModel()
            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportError = "Embedding generation failed: \(error.localizedDescription)"

                importState.isTextEmbeddingGenerating = false
                importState.textEmbeddingError = error.localizedDescription
                importState.isEmbeddingStopRequested = false
            }
        }
        await refreshPendingEnrichmentWork()
    }

    func processAllPostsImageEmbeddings() async {
        guard !importState.isDatabaseImporting else { return }
        await MainActor.run {
            importState.clearEnrichmentPresentationState()
            importState.isDatabaseImporting = true
            importState.databaseImportStatus = "Preparing to generate image embeddings..."
            importState.databaseImportError = nil
            importState.databaseImportCompleted = false

            importState.isImageEmbeddingGenerating = true
            importState.imageEmbeddingStatus = "Preparing image embeddings..."
            importState.imageEmbeddingError = nil
            importState.imageEmbeddingCompleted = false
        }

        do {
            try await sqliteManager.connect()
            let initialSnapshot = try await sqliteManager.getImageEmbeddingProgressSnapshot()
            let total = initialSnapshot.total
            var completedPostIDs = initialSnapshot.completedPostIDs
            let pageSize = 50
            var savedImages = 0
            var unavailableImages = 0

            await MainActor.run {
                let progress = total == 0 ? 1.0 : Double(completedPostIDs.count) / Double(total)
                let status = "\(completedPostIDs.count) of \(total) eligible posts complete. \(initialSnapshot.remaining) remaining."
                importState.databaseImportProgress = progress
                importState.databaseImportStatus = status
                importState.imageEmbeddingProgress = progress
                importState.imageEmbeddingStatus = status
            }

            var beforeCreatedAt: Date? = nil
            var beforeId: Int? = nil

            embeddingPages: while true {
                if importState.isEmbeddingStopRequested { break }

                let page = try await sqliteManager.fetchPostsMissingImageEmbeddings(limit: pageSize, beforeCreatedAt: beforeCreatedAt, beforeId: beforeId)
                if page.isEmpty { break }

                let resolvedURLs = try await sqliteManager.resolvedImageEmbeddingURLs(for: page.map(\.id))
                var mediaByURL: [URL: Media] = [:]
                var ownerPostIDsByURL: [URL: Set<Int>] = [:]
                for post in page {
                    let existing = resolvedURLs[post.id] ?? []
                    for media in (post.analysisMedia ?? []).filter({ MediaImageProcessor.isImageSearchMedia($0) }) {
                        guard !existing.contains(media.original.absoluteString) else { continue }
                        mediaByURL[media.original] = media
                        ownerPostIDsByURL[media.original, default: []].insert(post.id)
                    }
                }

                let pendingMedia = Array(mediaByURL.values)
                for chunkStart in stride(from: 0, to: pendingMedia.count, by: 4) {
                    if importState.isEmbeddingStopRequested { break }

                    let chunkEnd = min(chunkStart + 4, pendingMedia.count)
                    let result = await EmbeddingsManager.embedImageBatch(from: Array(pendingMedia[chunkStart..<chunkEnd]))
                    let updates = result.embeddings.flatMap { result in
                        (ownerPostIDsByURL[result.media.original] ?? []).map { postID in
                            SQLiteManager.ImageEmbeddingUpdate(
                                postID: postID,
                                mediaURL: result.media.original,
                                embedding: result.embedding
                            )
                        }
                    }
                    let unavailableUpdates = result.unavailableMedia.flatMap { unavailable in
                        (ownerPostIDsByURL[unavailable.media.original] ?? []).map { postID in
                            SQLiteManager.UnavailableImageEmbeddingUpdate(
                                postID: postID,
                                mediaURL: unavailable.media.original,
                                statusCode: unavailable.statusCode
                            )
                        }
                    }
                    try await sqliteManager.updateImageEmbeddings(updates)
                    try await sqliteManager.updateUnavailableImageEmbeddings(unavailableUpdates)
                    savedImages += updates.count
                    unavailableImages += unavailableUpdates.count
                    await Task.yield()

                    if importState.isEmbeddingStopRequested { break }
                }

                let expectedURLsByPostID = Dictionary(uniqueKeysWithValues: page.compactMap { post -> (Int, Set<String>)? in
                    let urls = Set(
                        (post.analysisMedia ?? [])
                            .filter(MediaImageProcessor.isImageSearchMedia)
                            .map { $0.original.absoluteString }
                    )
                    return urls.isEmpty ? nil : (post.id, urls)
                })
                let finalResolvedURLs = try await sqliteManager.resolvedImageEmbeddingURLs(for: Array(expectedURLsByPostID.keys))
                for (postID, expectedURLs) in expectedURLsByPostID
                    where expectedURLs.isSubset(of: finalResolvedURLs[postID] ?? []) {
                    completedPostIDs.insert(postID)
                }

                await MainActor.run {
                    let progress = total == 0 ? 1.0 : min(1.0, Double(completedPostIDs.count) / Double(total))
                    importState.databaseImportProgress = progress
                    importState.databaseImportStatus = "\(completedPostIDs.count) of \(total) eligible posts complete. \(max(0, total - completedPostIDs.count)) remaining."
                    importState.imageEmbeddingProgress = progress
                    importState.imageEmbeddingStatus = importState.databaseImportStatus
                }

                if importState.isEmbeddingStopRequested { break embeddingPages }

                if let last = page.last {
                    beforeCreatedAt = last.created_at
                    beforeId = last.id
                }

                if page.count < pageSize { break }
            }

            let wasStopped = importState.isEmbeddingStopRequested
            if wasStopped {
                await MainActor.run {
                    importState.databaseImportStatus = "Unloading the image embedding model..."
                    importState.imageEmbeddingStatus = importState.databaseImportStatus
                }
            }
            await EmbeddingsManager.unloadImageModel()

            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportCompleted = !wasStopped
                importState.databaseImportStatus = wasStopped
                    ? "Image embedding stopped safely: \(completedPostIDs.count) of \(total) eligible posts complete; \(max(0, total - completedPostIDs.count)) remaining. Saved \(savedImages) images and skipped \(unavailableImages) unavailable images this run."
                    : "Image embedding pass finished: \(completedPostIDs.count) of \(total) eligible posts complete; \(max(0, total - completedPostIDs.count)) remaining. Saved \(savedImages) images and skipped \(unavailableImages) unavailable images this run."
                importState.databaseImportProgress = total == 0 ? 1.0 : Double(completedPostIDs.count) / Double(total)

                importState.isImageEmbeddingGenerating = false
                importState.imageEmbeddingCompleted = !wasStopped
                importState.imageEmbeddingProgress = importState.databaseImportProgress
                importState.imageEmbeddingStatus = importState.databaseImportStatus
                importState.isEmbeddingStopRequested = false
            }
        } catch {
            await EmbeddingsManager.unloadImageModel()
            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportError = "Image embedding generation failed: \(error.localizedDescription)"

                importState.isImageEmbeddingGenerating = false
                importState.imageEmbeddingError = error.localizedDescription
                importState.isEmbeddingStopRequested = false
            }
        }
        await refreshPendingEnrichmentWork()
    }
}
