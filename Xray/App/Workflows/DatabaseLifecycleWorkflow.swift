import Foundation

extension AppModel {
    func refreshVisiblePostsFromDatabase(pageSize: Int = 100) async {
        do {
            try await sqliteManager.connect()
            let total = try await sqliteManager.getPostCount()
            let firstPage = try await fetchFirstPostsPage(pageSize: pageSize)

            await MainActor.run {
                importState.posts = firstPage
                importState.allPostsLoaded = firstPage.count < pageSize || firstPage.count >= total
                importState.isLoading = false
            }
        } catch {
            await MainActor.run {
                if importState.databaseImportError == nil {
                    importState.databaseImportError = "Refresh error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func fetchFirstPostsPage(pageSize: Int) async throws -> [Post] {
        let posts = try await sqliteManager.fetchHomePosts(limit: pageSize)
        return await preparePostsForDisplay(posts)
    }

    private func fetchNextPostsPage(pageSize: Int, after last: Post?) async throws -> [Post] {
        let posts = try await sqliteManager.fetchHomePosts(limit: pageSize, after: last)
        return await preparePostsForDisplay(posts)
    }

    private func preparePostsForDisplay(_ posts: [Post]) async -> [Post] {
        let preparation = await preparePostsForStableMediaLayout(posts)
        for post in preparation.updatedPosts {
            try? await sqliteManager.updateMediaMetadata(for: post)
        }
        return preparation.posts
    }

    func loadInitialPostsFromDatabase() {
        Task { [self] in
            do {
                try await sqliteManager.connect()
                let total = try await sqliteManager.getPostCount()
                if total > 0 {
                    await MainActor.run {
                        importState.isLoading = true
                        importState.databaseImportStatus = "Loading saved bookmarks..."
                    }
                    let pageSize = 100
                    let firstPage = try await fetchFirstPostsPage(pageSize: pageSize)
                    await MainActor.run {
                        importState.posts = firstPage
                        importState.isLoading = false
                        importState.allPostsLoaded = firstPage.count < pageSize
                    }
                    let paginationState = importState
                    paginationState.loadMorePosts = { [weak self, weak paginationState] in
                        guard let self, let importState = paginationState else { return }
                        Task {
                            guard !importState.isLoading, !importState.allPostsLoaded else { return }
                            await MainActor.run { importState.isLoading = true }
                            do {
                                // Keyset pagination: pick the last post currently loaded and ask for older
                                let last = importState.posts?.last
                                let nextPage = try await self.fetchNextPostsPage(pageSize: pageSize, after: last)
                                await MainActor.run {
                                    if importState.posts == nil {
                                        importState.posts = nextPage
                                    } else {
                                        importState.posts?.append(contentsOf: nextPage)
                                    }
                                    importState.isLoading = false
                                    importState.allPostsLoaded = nextPage.count < pageSize
                                }
                            } catch {
                                await MainActor.run {
                                    importState.isLoading = false
                                    importState.loadError = error.localizedDescription
                                }
                            }
                        }
                    }
                }
                await refreshPendingEnrichmentWork()
            } catch {
                await MainActor.run {
                    importState.loadError = error.localizedDescription
                    importState.isLoading = false
                }
            }
        }
    }

    // MARK: - Reset database and UI

    func rebuildDatabaseSchemaPreservingData() async {
        await MainActor.run {
            importState.clearEnrichmentPresentationState()
            importState.isDatabaseImporting = true
            importState.databaseImportStatus = "Preparing database schema rebuild..."
            importState.databaseImportProgress = 0
            importState.databaseImportError = nil
            importState.databaseImportCompleted = false
        }

        do {
            let restoredCount = try await sqliteManager.rebuildDatabaseSchemaPreservingPosts { [self] progress, status in
                await MainActor.run {
                    importState.databaseImportProgress = progress
                    importState.databaseImportStatus = status
                }
            }

            await refreshVisiblePostsFromDatabase()

            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportCompleted = true
                importState.databaseImportProgress = 1.0
                importState.databaseImportStatus = "Database schema rebuild complete. Restored \(restoredCount) posts."
            }
            await refreshPendingEnrichmentWork()
        } catch {
            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportError = "Schema rebuild failed: \(error.localizedDescription)"
            }
        }
    }

    func resetDatabaseAndUI() async {
        await MainActor.run {
            importState.clearEnrichmentPresentationState()
            importState.isDatabaseImporting = true
            importState.databaseImportStatus = "Resetting database..."
            importState.databaseImportProgress = 0
            importState.databaseImportError = nil
            importState.databaseImportCompleted = false
        }
        do {
            try await sqliteManager.resetDatabase()
            await MainActor.run {
                importState.posts = []
                importState.allPostsLoaded = true
                importState.isLoading = false
                importState.isDatabaseImporting = false
                importState.databaseImportCompleted = true
                importState.databaseImportProgress = 1.0
                importState.databaseImportStatus = "Database reset."
            }
        } catch {
            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportError = "Reset failed: \(error.localizedDescription)"
            }
        }
        await refreshPendingEnrichmentWork()
    }
}
