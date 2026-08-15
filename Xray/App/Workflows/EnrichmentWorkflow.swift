import Foundation

extension AppModel {
    // Process all posts in the database with the configured API provider and upsert topics
    func processMissingTopics() async {
        guard !importState.isDatabaseImporting else { return }
        importState.isDatabaseImporting = true
        importState.clearEnrichmentPresentationState()
        importState.databaseImportStatus = "Preparing to annotate topics..."
        importState.databaseImportError = nil
        importState.databaseImportCompleted = false
        importState.isTopicAnnotating = true
        importState.topicStatus = "Preparing topic annotation..."

        do {
            try await sqliteManager.connect()
            var topicCounts = try await sqliteManager.getTopicAnnotationCounts()
            let total = topicCounts.total
            var annotatedCount = topicCounts.annotated
            var completedCount = topicCounts.completed
            let initialMissingCount = topicCounts.missing

            await MainActor.run {
                let progress = total == 0 ? 1.0 : Double(completedCount) / Double(max(total, 1))
                importState.isDatabaseImporting = true
                importState.databaseImportProgress = progress
                importState.databaseImportStatus = initialMissingCount == 0
                    ? "All topic processing is already resolved."
                    : "Resuming topic annotation. \(completedCount) of \(total) already resolved."
                importState.databaseImportError = nil
                importState.databaseImportCompleted = false
                importState.isTopicAnnotating = true
                importState.topicProgress = progress
                importState.topicStatus = "\(completedCount) of \(total) posts complete. \(initialMissingCount) remaining."
                importState.topicError = nil
                importState.topicCompleted = false
            }

            // Persist after every configured app-side batch so completed work
            // survives long-running jobs regardless of provider.
            let pageSize = OpenAIManager.topicPersistencePageSize(
                for: OpenAIManager.currentProvider,
                concurrentRequests: OpenAIManager.topicConcurrentRequests
            )
            let maxAnnotationPasses = 4
            var updatedThisRun = 0
            var annotationPass = 0
            var consecutivePassesWithoutProgress = 0
            var persistentSkipCandidateAttempts: [Int: Int] = [:]

            while annotationPass < maxAnnotationPasses {
                annotationPass += 1
                let completedAtPassStart = completedCount
                var beforeCreatedAt: Date? = nil
                var beforeId: Int? = nil

                while true {
                    let page = try await sqliteManager.fetchPostsMissingTopics(
                        limit: pageSize,
                        beforeCreatedAt: beforeCreatedAt,
                        beforeId: beforeId
                    )
                    if page.isEmpty { break }

                    let toAnnotate = page
                    if !toAnnotate.isEmpty {
                        let batchResult = await TopicAnnotator.annotatePostsWithTopics(
                            toAnnotate,
                            onProgress: { [self] current, totalInPage in
                                Task { @MainActor in
                                    // Reflect per-page progress into overall persisted-topic progress.
                                    let pageFraction = Double(current) / Double(max(totalInPage, 1))
                                    let already = Double(completedCount) / Double(max(total, 1))
                                    let progress = min(1.0, already + pageFraction * (Double(toAnnotate.count) / Double(max(total, 1))))
                                    importState.topicProgress = progress
                                    importState.databaseImportProgress = progress
                                }
                            }
                        )
                        if let configurationError = batchResult.configurationError {
                            throw TopicAnnotationConfigurationError(message: configurationError)
                        }
                        for postID in batchResult.persistentSkipCandidatePostIDs {
                            persistentSkipCandidateAttempts[postID, default: 0] += 1
                        }

                        let successfullyAnnotated = batchResult.posts.filter {
                            !$0.primary_topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        let topicUpdates = successfullyAnnotated.map {
                            SQLiteManager.TopicUpdate(
                                postID: $0.id,
                                primaryTopic: $0.primary_topic,
                                secondaryTopics: $0.secondary_topics
                            )
                        }
                        try await sqliteManager.updateMissingTopics(topicUpdates)

                        let previousAnnotatedCount = annotatedCount
                        topicCounts = try await sqliteManager.getTopicAnnotationCounts()
                        annotatedCount = topicCounts.annotated
                        completedCount = topicCounts.completed
                        updatedThisRun += max(0, annotatedCount - previousAnnotatedCount)

                        // Update in-memory posts, if loaded in UI
                        if var current = importState.posts, !current.isEmpty {
                            let updates: [Int: Post] = Dictionary(uniqueKeysWithValues: successfullyAnnotated.map { ($0.id, $0) })
                            current = current.map { updates[$0.id] ?? $0 }
                            await MainActor.run {
                                importState.posts = current
                            }
                        }

                        await MainActor.run {
                            let progress = min(1.0, total == 0 ? 1.0 : Double(completedCount) / Double(max(total, 1)))
                            importState.topicProgress = progress
                            importState.databaseImportProgress = progress
                            importState.topicStatus = "\(completedCount) of \(total) posts complete. \(topicCounts.missing) remaining."
                        }
                    }

                    // Advance keyset pagination cursor
                    if let last = page.last {
                        beforeCreatedAt = last.created_at
                        beforeId = last.id
                    } else {
                        break
                    }

                    // Stop if we've reached the end
                    if page.count < pageSize { break }
                }

                let terminalPostIDs = Set(persistentSkipCandidateAttempts.compactMap { postID, attempts in
                    attempts >= 2 ? postID : nil
                })
                if !terminalPostIDs.isEmpty {
                    try await sqliteManager.markTopicAnnotationUnavailable(postIDs: terminalPostIDs)
                    for postID in terminalPostIDs {
                        persistentSkipCandidateAttempts.removeValue(forKey: postID)
                    }
                }

                topicCounts = try await sqliteManager.getTopicAnnotationCounts()
                annotatedCount = topicCounts.annotated
                completedCount = topicCounts.completed
                guard topicCounts.missing > 0 else { break }

                if completedCount == completedAtPassStart {
                    consecutivePassesWithoutProgress += 1
                } else {
                    consecutivePassesWithoutProgress = 0
                }
                guard consecutivePassesWithoutProgress < 2,
                      annotationPass < maxAnnotationPasses else { break }

                await MainActor.run {
                    importState.topicStatus = "Retrying \(topicCounts.missing) posts still missing topics..."
                }
                try? await Task.sleep(for: .seconds(annotationPass))
            }

            let finalCounts = try await sqliteManager.getTopicAnnotationCounts()
            let finalProgress = finalCounts.total == 0 ? 1.0 : Double(finalCounts.completed) / Double(max(finalCounts.total, 1))
            var finalStatus = "Annotated topics for \(finalCounts.annotated) of \(finalCounts.total) posts."
            if finalCounts.unavailable > 0 {
                finalStatus += " Skipped \(finalCounts.unavailable) posts with persistent provider errors."
            }
            if finalCounts.missing > 0 {
                finalStatus += " \(finalCounts.missing) still missing topics."
            }

            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportCompleted = true
                importState.databaseImportStatus = "Topic processing complete. Updated \(updatedThisRun) posts."
                importState.databaseImportProgress = finalProgress
                importState.isTopicAnnotating = false
                importState.topicCompleted = true
                importState.topicProgress = finalProgress
                importState.topicStatus = finalStatus
            }
        } catch {
            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportError = "Topic processing failed: \(error.localizedDescription)"
                importState.isTopicAnnotating = false
                importState.topicError = error.localizedDescription
            }
        }
        await refreshPendingEnrichmentWork()
    }

    func refreshPendingEnrichmentWork() async {
        do {
            try await sqliteManager.connect()
            let hasPendingTopics: Bool
            if OpenAIManager.isTopicGenerationConfigured {
                hasPendingTopics = try await sqliteManager.getTopicAnnotationCounts().missing > 0
            } else {
                hasPendingTopics = false
            }
            let text = try await sqliteManager.getTextEmbeddingProgressCounts()
            let images = try await sqliteManager.getImageEmbeddingProgressSnapshot()
            await MainActor.run {
                importState.hasPendingEnrichmentWork = hasPendingTopics
                    || text.remaining > 0
                    || images.remaining > 0
            }
        } catch {
            print("[Enrichment] Could not inspect remaining work: \(error.localizedDescription)")
        }
    }

    func processRemainingEnrichments() async {
        guard !importState.isDatabaseImporting, !importState.isEnrichmentQueueRunning else { return }
        await MainActor.run { importState.isEnrichmentQueueRunning = true }

        if OpenAIManager.isTopicGenerationConfigured {
            await processMissingTopics()
        }
        await processAllPostsEmbeddings()
        await processAllPostsImageEmbeddings()

        // Reload the current feed window, then recreate its complete view hierarchy once the
        // enrichment queue finishes so every visible card reads the newly persisted topics.
        let loadedPostCount = await MainActor.run { importState.posts?.count ?? 0 }
        await refreshVisiblePostsFromDatabase(pageSize: max(100, loadedPostCount))

        await MainActor.run {
            importState.windowContentRevision &+= 1
            importState.isEnrichmentQueueRunning = false
        }
        await refreshPendingEnrichmentWork()
    }
}
