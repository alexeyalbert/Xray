import Foundation

@Observable
class ImportState {
    var importURL: URL?
    var posts: [Post]? = nil
    var loadError: String? = nil
    var isLoading: Bool = false
    var allPostsLoaded: Bool = false
    var loadMorePosts: (() -> Void)? = nil
    
    // Database import progress
    var isDatabaseImporting: Bool = false
    var databaseImportProgress: Double = 0.0
    var databaseImportStatus: String = ""
    var databaseImportError: String? = nil
    var databaseImportCompleted: Bool = false

    // Topic annotation progress
    var isTopicAnnotating: Bool = false
    var topicProgress: Double = 0.0
    var topicStatus: String = ""
    var topicError: String? = nil
    var topicCompleted: Bool = false

    // Text embeddings progress
    var isTextEmbeddingGenerating: Bool = false
    var textEmbeddingProgress: Double = 0.0
    var textEmbeddingStatus: String = ""
    var textEmbeddingError: String? = nil
    var textEmbeddingCompleted: Bool = false

    // Image embeddings progress
    var isImageEmbeddingGenerating: Bool = false
    var imageEmbeddingProgress: Double = 0.0
    var imageEmbeddingStatus: String = ""
    var imageEmbeddingError: String? = nil
    var imageEmbeddingCompleted: Bool = false
    var isEmbeddingStopRequested: Bool = false
    var hasPendingEnrichmentWork: Bool = false
    var isEnrichmentQueueRunning: Bool = false

    func clearEnrichmentPresentationState() {
        isTopicAnnotating = false
        topicError = nil
        topicCompleted = false
        isTextEmbeddingGenerating = false
        textEmbeddingError = nil
        textEmbeddingCompleted = false
        isImageEmbeddingGenerating = false
        imageEmbeddingError = nil
        imageEmbeddingCompleted = false
        isEmbeddingStopRequested = false
    }

    // Browser import receiver status
    var isBrowserImportReceiverRunning: Bool = false
    var browserImportReceiverStatus: String = "Receiver is stopped."
    var browserImportReceiverError: String? = nil
    var browserImportReceiverURL: String = ""
    var browserImportReceiverToken: String = ""
    var browserImportActiveSessionID: String? = nil
    var browserImportLastBatchAt: Date? = nil
    var browserImportBatchesReceived: Int = 0
    var browserImportAcceptedCount: Int = 0
    var browserImportInsertedCount: Int = 0
    var browserImportSkippedExistingCount: Int = 0
    var browserImportCompleted: Bool = false

    // Search mode selection for menu commands
    var searchMode: SearchMode = .hybrid
}
