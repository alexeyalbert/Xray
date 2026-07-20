import Foundation

extension AppModel {
    func beginBrowserImportReceiver() {
        Task {
            if let existingReceiver = browserImportReceiver {
                existingReceiver.stop()
                await MainActor.run {
                    browserImportReceiver = nil
                }
            }

            let token = BrowserImportReceiverSettings.stableToken()
            let preferredPort = BrowserImportReceiverSettings.preferredPort()
            let receiver = BrowserImportReceiver(
                token: token,
                batchHandler: { [self] batchRequest in
                    try await sqliteManager.connect()
                    let result = try await sqliteManager.softImportBrowserPosts(
                        sessionID: batchRequest.sessionId,
                        batchSequence: batchRequest.batchSequence,
                        posts: batchRequest.posts
                    ) { _, _ in }
                    await refreshVisiblePostsFromDatabase()
                    return (insertedCount: result.insertedCount, skippedExistingCount: result.skippedExistingCount)
                },
                snapshotHandler: { [self] snapshot in
                    await MainActor.run {
                        importState.isBrowserImportReceiverRunning = snapshot.isListening
                        importState.browserImportReceiverStatus = snapshot.receiverStatus
                        if snapshot.isListening {
                            importState.browserImportReceiverError = nil
                        }
                        importState.browserImportActiveSessionID = snapshot.activeSessionId
                        importState.browserImportLastBatchAt = snapshot.lastBatchAt
                        importState.browserImportBatchesReceived = snapshot.batchesReceived
                        importState.browserImportAcceptedCount = snapshot.totalAcceptedCount
                        importState.browserImportInsertedCount = snapshot.totalInsertedCount
                        importState.browserImportSkippedExistingCount = snapshot.totalSkippedExistingCount
                        importState.browserImportCompleted = snapshot.completed
                    }
                    if snapshot.completed {
                        await refreshPendingEnrichmentWork()
                    }
                }
            )

            await MainActor.run {
                importState.isBrowserImportReceiverRunning = false
                importState.browserImportReceiverError = nil
                importState.browserImportReceiverStatus = "Starting browser import receiver..."
                importState.browserImportReceiverURL = ""
                importState.browserImportReceiverToken = token
                importState.isBrowserImportConnectionInfoPresented = false
                importState.browserImportActiveSessionID = nil
                importState.browserImportLastBatchAt = nil
                importState.browserImportBatchesReceived = 0
                importState.browserImportAcceptedCount = 0
                importState.browserImportInsertedCount = 0
                importState.browserImportSkippedExistingCount = 0
                importState.browserImportCompleted = false
            }

            do {
                let port = try await receiver.start(preferredPort: preferredPort)
                BrowserImportReceiverSettings.savePreferredPort(port)
                await MainActor.run {
                    browserImportReceiver = receiver
                    importState.isBrowserImportReceiverRunning = true
                    importState.browserImportReceiverStatus = "Receiver is listening for browser batches."
                    importState.browserImportReceiverURL = "http://localhost:\(port)"
                    importState.browserImportReceiverToken = receiver.currentToken()
                    importState.isBrowserImportConnectionInfoPresented = true
                }
            } catch {
                receiver.stop()
                await MainActor.run {
                    browserImportReceiver = nil
                    importState.isBrowserImportReceiverRunning = false
                    importState.browserImportReceiverStatus = "Receiver failed to start."
                    importState.browserImportReceiverError = error.localizedDescription
                    importState.browserImportReceiverURL = ""
                    importState.browserImportReceiverToken = ""
                    importState.isBrowserImportConnectionInfoPresented = false
                }
            }
        }
    }

    func endBrowserImportReceiver() {
        browserImportReceiver?.stop()
        browserImportReceiver = nil
        importState.isBrowserImportReceiverRunning = false
        importState.browserImportReceiverStatus = "Receiver is stopped."
        importState.browserImportReceiverError = nil
        importState.browserImportReceiverURL = ""
        importState.browserImportReceiverToken = ""
        importState.isBrowserImportConnectionInfoPresented = false
        importState.browserImportActiveSessionID = nil
        importState.browserImportCompleted = false
    }
}
