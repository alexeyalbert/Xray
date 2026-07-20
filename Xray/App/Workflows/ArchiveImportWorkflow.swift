import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    func openJSONFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Select a JSON Archive to Soft Import"
        if panel.runModal() == .OK, let url = panel.url {
            importState.importURL = url
            loadArchiveForSoftImport(from: url)
        }
    }

    // Annotate posts with topics before saving using helper
    private func annotatePostsWithTopics(_ posts: [Post]) async -> [Post] {
        await TopicAnnotator.annotatePostsWithTopics(posts) { [self] current, total in
            Task { @MainActor in
                importState.databaseImportStatus = "Annotating topics (\(current)/\(total))..."
                importState.databaseImportProgress = Double(current) / Double(max(total, 1))
            }
        }
    }

    private func loadArchiveForSoftImport(from url: URL) {
        guard !importState.isDatabaseImporting else { return }
        importState.clearEnrichmentPresentationState()
        importState.posts = nil
        importState.loadError = nil
        importState.isLoading = true
        importState.isDatabaseImporting = false
        importState.databaseImportProgress = 0.0
        importState.databaseImportStatus = ""
        importState.databaseImportError = nil
        importState.databaseImportCompleted = false

        Task {
            do {
                // First, decode the JSON
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                // Custom date format: "yyyy-MM-dd HH:mm:ss Z"
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
                decoder.dateDecodingStrategy = .formatted(formatter)
                let decoded = try decoder.decode([Post].self, from: data)

                await MainActor.run {
                    importState.isLoading = false
                    importState.isDatabaseImporting = true
                    importState.databaseImportStatus = "Connecting to database for soft import..."
                }

                try await softImportPostsToDatabase(decoded)

            } catch {
                await MainActor.run {
                    importState.loadError = error.localizedDescription
                    importState.isLoading = false
                    importState.isDatabaseImporting = false
                    importState.databaseImportError = error.localizedDescription
                }
            }
        }
    }

    private func softImportPostsToDatabase(_ posts: [Post]) async throws {
        do {
            // Connect to database
            try await sqliteManager.connect()
            await MainActor.run {
                importState.databaseImportStatus = "Soft-importing \(posts.count) posts into database..."
                importState.databaseImportProgress = 0.0
            }

            let bookmarkImportGeneration = try await sqliteManager.beginBookmarkImportGeneration()
            let result = try await sqliteManager.softImportPosts(posts, bookmarkImportGeneration: bookmarkImportGeneration) { [self] currentBatch, totalBatches in
                let progress = Double(currentBatch) / Double(totalBatches)
                Task { @MainActor in
                    importState.databaseImportProgress = progress
                    importState.databaseImportStatus = "Soft-imported batch \(currentBatch) of \(totalBatches)"
                }
            }
            let finalStatus = "Soft import complete. Added \(result.insertedCount) new posts and skipped \(result.skippedExistingCount) existing posts."

            // Get final count for verification
            let finalCount = try await sqliteManager.getPostCount()
            await refreshVisiblePostsFromDatabase()

            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportCompleted = true
                importState.databaseImportProgress = 1.0
                importState.databaseImportStatus = "\(finalStatus) Total posts in database: \(finalCount)"
            }
            await refreshPendingEnrichmentWork()

        } catch {
            await MainActor.run {
                importState.isDatabaseImporting = false
                importState.databaseImportError = "Soft import error: \(error.localizedDescription)"
            }
            throw error
        }
    }
}
