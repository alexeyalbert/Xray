import Foundation

struct BrowserImportStartRequest: Codable, Sendable {
    let sessionId: String
    let clientName: String?
    let startedAtMillis: Int64?
}

struct BrowserImportBatchRequest: Codable, Sendable {
    let sessionId: String
    let batchSequence: Int
    let sentAtMillis: Int64
    let posts: [Post]
}

struct BrowserImportCompleteRequest: Codable, Sendable {
    let sessionId: String
    let sentAtMillis: Int64?
    let capturedCount: Int?
    let ackedCount: Int?
}

struct BrowserImportBatchResponse: Codable, Sendable {
    let success: Bool
    let sessionId: String
    let batchSequence: Int
    let acceptedCount: Int
    let insertedCount: Int
    let skippedExistingCount: Int
    let totalAcceptedCount: Int
    let totalInsertedCount: Int
    let totalSkippedExistingCount: Int
    let batchesReceived: Int
    let message: String?
}

struct BrowserImportStatusResponse: Codable, Sendable {
    let success: Bool
    let receiverStatus: String
    let activeSessionId: String?
    let batchesReceived: Int
    let totalAcceptedCount: Int
    let totalInsertedCount: Int
    let totalSkippedExistingCount: Int
    let completed: Bool
    let lastBatchAtMillis: Int64?
}

struct BrowserImportStartResponse: Codable, Sendable {
    let success: Bool
    let receiverStatus: String
    let sessionId: String
    let activeSessionId: String?
    let message: String?
}

struct BrowserImportCompleteResponse: Codable, Sendable {
    let success: Bool
    let receiverStatus: String
    let sessionId: String
    let batchesReceived: Int
    let totalAcceptedCount: Int
    let totalInsertedCount: Int
    let totalSkippedExistingCount: Int
    let message: String?
}

struct BrowserImportSnapshot: Sendable {
    let isListening: Bool
    let receiverStatus: String
    let activeSessionId: String?
    let batchesReceived: Int
    let totalAcceptedCount: Int
    let totalInsertedCount: Int
    let totalSkippedExistingCount: Int
    let completed: Bool
    let lastBatchAt: Date?
}

struct ErrorPayload: Codable, Sendable {
    let success: Bool
    let message: String
}

struct EmptyPayload: Codable {}
