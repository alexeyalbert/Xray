import Foundation

actor BrowserImportSessionStore {
    private let token: String
    private var isListening = false
    private var receiverStatus = "Receiver is stopped."
    private var activeSessionId: String?
    private var batchesReceived = 0
    private var totalAcceptedCount = 0
    private var totalInsertedCount = 0
    private var totalSkippedExistingCount = 0
    private var completed = false
    private var lastBatchAt: Date?
    private var processedBatchAcks: [Int: BrowserImportBatchResponse] = [:]

    init(token: String) {
        self.token = token
    }

    func setListening(_ listening: Bool, status: String) {
        isListening = listening
        receiverStatus = status
    }

    func validate(token candidate: String?) -> Bool {
        candidate == token
    }

    func snapshot() -> BrowserImportSnapshot {
        BrowserImportSnapshot(
            isListening: isListening,
            receiverStatus: receiverStatus,
            activeSessionId: activeSessionId,
            batchesReceived: batchesReceived,
            totalAcceptedCount: totalAcceptedCount,
            totalInsertedCount: totalInsertedCount,
            totalSkippedExistingCount: totalSkippedExistingCount,
            completed: completed,
            lastBatchAt: lastBatchAt
        )
    }

    func startSession(request: BrowserImportStartRequest) -> BrowserImportStartResponse {
        if let activeSessionId, activeSessionId != request.sessionId, !completed, batchesReceived > 0 {
            return BrowserImportStartResponse(
                success: false,
                receiverStatus: receiverStatus,
                sessionId: request.sessionId,
                activeSessionId: activeSessionId,
                message: "A different browser session is already active."
            )
        }

        if activeSessionId != request.sessionId {
            activeSessionId = request.sessionId
            batchesReceived = 0
            totalAcceptedCount = 0
            totalInsertedCount = 0
            totalSkippedExistingCount = 0
            completed = false
            lastBatchAt = nil
            processedBatchAcks = [:]
        }

        receiverStatus = "Listening for browser batches."
        return BrowserImportStartResponse(
            success: true,
            receiverStatus: receiverStatus,
            sessionId: request.sessionId,
            activeSessionId: activeSessionId,
            message: "Browser session registered."
        )
    }

    func existingAck(for request: BrowserImportBatchRequest) -> BrowserImportBatchResponse? {
        guard activeSessionId == request.sessionId else {
            return nil
        }
        return processedBatchAcks[request.batchSequence]
    }

    func ensureSession(for request: BrowserImportBatchRequest) -> String? {
        if let activeSessionId, activeSessionId != request.sessionId, !completed, batchesReceived > 0 {
            return "A different browser session is already active."
        }

        if activeSessionId == nil || activeSessionId == request.sessionId {
            activeSessionId = request.sessionId
            completed = false
            return nil
        }

        return nil
    }

    func recordBatchAck(
        for request: BrowserImportBatchRequest,
        insertedCount: Int,
        skippedExistingCount: Int
    ) -> BrowserImportBatchResponse {
        batchesReceived += 1
        totalAcceptedCount += request.posts.count
        totalInsertedCount += insertedCount
        totalSkippedExistingCount += skippedExistingCount
        lastBatchAt = Date()
        receiverStatus = "Receiving browser batches."

        let response = BrowserImportBatchResponse(
            success: true,
            sessionId: request.sessionId,
            batchSequence: request.batchSequence,
            acceptedCount: request.posts.count,
            insertedCount: insertedCount,
            skippedExistingCount: skippedExistingCount,
            totalAcceptedCount: totalAcceptedCount,
            totalInsertedCount: totalInsertedCount,
            totalSkippedExistingCount: totalSkippedExistingCount,
            batchesReceived: batchesReceived,
            message: nil
        )
        processedBatchAcks[request.batchSequence] = response
        return response
    }

    func failBatch(for request: BrowserImportBatchRequest, message: String) -> BrowserImportBatchResponse {
        BrowserImportBatchResponse(
            success: false,
            sessionId: request.sessionId,
            batchSequence: request.batchSequence,
            acceptedCount: request.posts.count,
            insertedCount: 0,
            skippedExistingCount: 0,
            totalAcceptedCount: totalAcceptedCount,
            totalInsertedCount: totalInsertedCount,
            totalSkippedExistingCount: totalSkippedExistingCount,
            batchesReceived: batchesReceived,
            message: message
        )
    }

    func completeSession(request: BrowserImportCompleteRequest) -> BrowserImportCompleteResponse {
        if let activeSessionId, activeSessionId != request.sessionId {
            return BrowserImportCompleteResponse(
                success: false,
                receiverStatus: receiverStatus,
                sessionId: request.sessionId,
                batchesReceived: batchesReceived,
                totalAcceptedCount: totalAcceptedCount,
                totalInsertedCount: totalInsertedCount,
                totalSkippedExistingCount: totalSkippedExistingCount,
                message: "That browser session is not active on this receiver."
            )
        }

        activeSessionId = request.sessionId
        completed = true
        receiverStatus = "Browser session completed."
        return BrowserImportCompleteResponse(
            success: true,
            receiverStatus: receiverStatus,
            sessionId: request.sessionId,
            batchesReceived: batchesReceived,
            totalAcceptedCount: totalAcceptedCount,
            totalInsertedCount: totalInsertedCount,
            totalSkippedExistingCount: totalSkippedExistingCount,
            message: "Browser session marked complete."
        )
    }
}
