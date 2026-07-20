//
//  SQLiteManager.swift
//  Xray
//
//  Created by Alexey Albert on 2025-08-17.
//

import Foundation
import Accelerate
import SQLite

actor SQLiteManager {
    static let minimumEmbeddingSimilarityDefaultsKey = "Search.MinimumEmbeddingSimilarity"
    static let defaultMinimumEmbeddingSimilarity = 0.75
    static let minimumImageEmbeddingSimilarityDefaultsKey = "Search.MinimumImageEmbeddingSimilarity"
    static let defaultMinimumImageEmbeddingSimilarity = 0.35

    private enum NullSearchField: String, Hashable, CaseIterable {
        case fullText
        case media
        case article
        case quotedPost
        case primaryTopic
        case secondaryTopics
    }

    struct SoftImportResult {
        let insertedCount: Int
        let skippedExistingCount: Int

        var processedCount: Int {
            insertedCount + skippedExistingCount
        }
    }

    struct TopicAnnotationCounts: Sendable {
        let total: Int
        let annotated: Int

        var missing: Int {
            max(0, total - annotated)
        }
    }

    struct TopicUpdate: Sendable {
        let postID: Int
        let primaryTopic: String
        let secondaryTopics: [String]
    }

    struct EmbeddingProgressCounts: Sendable {
        let total: Int
        let completed: Int

        var remaining: Int {
            max(0, total - completed)
        }
    }

    struct ImageEmbeddingProgressSnapshot: Sendable {
        let total: Int
        let completedPostIDs: Set<Int>

        var completed: Int {
            completedPostIDs.count
        }

        var remaining: Int {
            max(0, total - completed)
        }
    }

    struct SearchDebugExplanation: Sendable {
        let title: String
        let body: String
    }

    struct SearchDiagnosticOperation: Sendable, Identifiable {
        let id: UUID
        let method: String
        let query: String
        let resultCount: Int
        let duration: TimeInterval
        let detail: String
    }

    struct SearchDiagnostics: Sendable {
        let query: String
        let mode: String
        let totalResultCount: Int
        let totalDuration: TimeInterval
        let minimumEmbeddingSimilarity: Double
        let minimumImageEmbeddingSimilarity: Double
        let plan: [String]
        let countsByMethod: [(method: String, count: Int)]
        let operations: [SearchDiagnosticOperation]
    }

    struct SearchExecutionResult: Sendable {
        let posts: [Post]
        let diagnostics: SearchDiagnostics
    }

    struct ImageEmbeddingUpdate: Sendable {
        let postID: Int
        let mediaURL: URL
        let embedding: [Float]
    }

    struct UnavailableImageEmbeddingUpdate: Sendable {
        let postID: Int
        let mediaURL: URL
        let statusCode: Int
    }

    final class SearchDiagnosticsCollector {
        var operations: [SearchDiagnosticOperation] = []
        var postIDsByMethod: [String: Set<Int>] = [:]

        func record(
            method: String,
            query: String,
            posts: [Post],
            duration: TimeInterval,
            detail: String
        ) {
            operations.append(SearchDiagnosticOperation(
                id: UUID(),
                method: method,
                query: query,
                resultCount: posts.count,
                duration: duration,
                detail: detail
            ))
            postIDsByMethod[method, default: []].formUnion(posts.map(\.id))
        }
    }

    private var db: Connection!
    private var isDatabaseReady = false
    private let dbFileName: String = "xray.sqlite3"
    private var browserImportGenerations: [String: Int64] = [:]
    private let browserImportOrderStride = 1_000_000
    private let postRowDecoder = SQLitePostRowDecoder()
    private var textEmbeddingIndex: TextEmbeddingSearchIndex?
    
    // Minimum cosine similarity required for embedding search results.
    // Dork filters can bypass it when needed.
    private var minimumEmbeddingSimilarity: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.minimumEmbeddingSimilarityDefaultsKey) != nil else {
            return Self.defaultMinimumEmbeddingSimilarity
        }

        let storedValue = defaults.double(forKey: Self.minimumEmbeddingSimilarityDefaultsKey)
        return min(max(storedValue, 0), 1)
    }
    private var minimumImageEmbeddingSimilarity: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.minimumImageEmbeddingSimilarityDefaultsKey) != nil else {
            return Self.defaultMinimumImageEmbeddingSimilarity
        }

        let storedValue = defaults.double(forKey: Self.minimumImageEmbeddingSimilarityDefaultsKey)
        return min(max(storedValue, 0), 1)
    }
    private let normalizedEmbeddingTolerance: Double = 0.01

    private struct TextEmbeddingSearchIndex {
        let ids: [Int]
        let vectors: [Float]
        let dimension: Int
        let loadedAt: Date
        let normalizedRepairCount: Int
        let skippedInvalidCount: Int
        let skippedDimensionCount: Int
    }

    private struct SchemaRebuildPost {
        let post: Post
        let normalizedTextEmbedding: [Float]
    }

    private struct VectorMatch {
        let id: Int
        let similarity: Double
    }

    private struct SimilarImageSearchMatch {
        let post: Post
        let similarity: Double
        let matchingMediaURL: String
    }

    private struct TopKMatches {
        let limit: Int
        private(set) var storage: [VectorMatch] = []

        init(limit: Int) {
            self.limit = max(0, limit)
            storage.reserveCapacity(min(max(0, limit), 512))
        }

        mutating func insert(_ match: VectorMatch) {
            guard limit > 0 else { return }
            if storage.count < limit {
                storage.append(match)
                siftUp(storage.count - 1)
            } else if let weakest = storage.first, match.similarity > weakest.similarity {
                storage[0] = match
                siftDown(0)
            }
        }

        func sortedDescending() -> [VectorMatch] {
            storage.sorted { $0.similarity > $1.similarity }
        }

        private mutating func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard storage[child].similarity < storage[parent].similarity else { break }
                storage.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(_ index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var weakest = parent

                if left < storage.count, storage[left].similarity < storage[weakest].similarity {
                    weakest = left
                }
                if right < storage.count, storage[right].similarity < storage[weakest].similarity {
                    weakest = right
                }
                guard weakest != parent else { break }
                storage.swapAt(parent, weakest)
                parent = weakest
            }
        }
    }

    private struct DorkedSearchQuery {
        var searchText: String
        var embeddingSearchText: String
        var excludedEmbeddingSearchText: [String]
        var imageEmbeddingSearchText: String
        var excludedImageEmbeddingSearchText: [String]
        var excludedSearchTerms: [String]
        var matchesNullValues: Bool
        var nullFields: Set<NullSearchField>
        var excludedNullFields: Set<NullSearchField>
        var postIDs: [Int]
        var excludedPostIDs: [Int]
        var usernames: [String]
        var excludedUsernames: [String]
        var displayNames: [String]
        var excludedDisplayNames: [String]
        var topics: [String]
        var excludedTopics: [String]
        var primaryTopics: [String]
        var excludedPrimaryTopics: [String]
        var secondaryTopics: [String]
        var excludedSecondaryTopics: [String]
        var exactPhrases: [String]
        var excludedExactPhrases: [String]

        var hasHardFilters: Bool {
            matchesNullValues ||
            !nullFields.isEmpty ||
            !excludedNullFields.isEmpty ||
            !postIDs.isEmpty ||
            !excludedPostIDs.isEmpty ||
            !usernames.isEmpty ||
            !excludedUsernames.isEmpty ||
            !displayNames.isEmpty ||
            !excludedDisplayNames.isEmpty ||
            !topics.isEmpty ||
            !excludedTopics.isEmpty ||
            !primaryTopics.isEmpty ||
            !excludedPrimaryTopics.isEmpty ||
            !secondaryTopics.isEmpty ||
            !excludedSecondaryTopics.isEmpty ||
            !exactPhrases.isEmpty ||
            !excludedExactPhrases.isEmpty ||
            !excludedSearchTerms.isEmpty ||
            !excludedEmbeddingSearchText.isEmpty ||
            !excludedImageEmbeddingSearchText.isEmpty
        }

        var hasAnySearchText: Bool {
            !searchText.isEmpty || !embeddingSearchText.isEmpty || !imageEmbeddingSearchText.isEmpty
        }
    }

    private struct BooleanSearchExpression {
        /// OR groups, each containing AND operands.
        let groups: [[String]]
    }
    
    // MARK: - Setup

    func connect() async throws {
        if db == nil {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = appSupport.appendingPathComponent("Xray", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(dbFileName).path
            db = try Connection(path)
            isDatabaseReady = false
            try db.execute("PRAGMA journal_mode=WAL;")
            try db.execute("PRAGMA synchronous=NORMAL;")
            print("[VectorSearch] Using CPU-based vector search for optimal accuracy")
        }

        guard !isDatabaseReady else { return }
        try ensureDatabaseReady()
        isDatabaseReady = true
    }

    private func ensureDatabaseReady() throws {
        // Core table
        let createPostsSQL = """
            CREATE TABLE IF NOT EXISTS Posts (
                id INTEGER PRIMARY KEY,
                created_at REAL NOT NULL,
                full_text TEXT NOT NULL,
                media TEXT,
                article TEXT,
                links TEXT,
                quoted_post TEXT,
                screen_name TEXT NOT NULL,
                name TEXT NOT NULL,
                profile_image_url TEXT NOT NULL,
                profile_image_shape TEXT NOT NULL DEFAULT 'Circle',
                url TEXT NOT NULL,
                text_embedding BLOB,
                text_embedding_normalized BLOB,
                img_embedding BLOB,
                primary_topic TEXT,
                secondary_topics TEXT,
                secondary_topics_text TEXT,
                bookmark_import_generation INTEGER,
                bookmark_order INTEGER
            );
            """
        try db.execute(createPostsSQL)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS AppMetadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
        try migrateEmbeddingColumns()
        try prepareImageEmbeddingStorage()
        try migrateBookmarkOrderColumns()
        try? db.execute("ALTER TABLE Posts ADD COLUMN quoted_post TEXT;")
        try? db.execute("ALTER TABLE Posts ADD COLUMN article TEXT;")
        try? db.execute("ALTER TABLE Posts ADD COLUMN links TEXT;")
        try? db.execute("ALTER TABLE Posts ADD COLUMN profile_image_shape TEXT NOT NULL DEFAULT 'Circle';")
        try db.execute("CREATE INDEX IF NOT EXISTS posts_created_at_id_desc_idx ON Posts (created_at DESC, id DESC);")
        try db.execute("CREATE INDEX IF NOT EXISTS posts_bookmark_order_idx ON Posts (bookmark_import_generation DESC, bookmark_order ASC, created_at DESC, id DESC);")

        // Maintain secondary_topics_text from JSON array in secondary_topics
        let trigInsert = """
            CREATE TRIGGER IF NOT EXISTS posts_topics_text_ai
            AFTER INSERT ON Posts
            BEGIN
                UPDATE Posts
                SET secondary_topics_text = (
                    CASE
                        WHEN json_valid(new.secondary_topics)
                        THEN (
                            SELECT trim(group_concat(value, ' '))
                            FROM json_each(new.secondary_topics)
                        )
                        ELSE NULL
                    END
                )
                WHERE id = new.id;
            END;
            """
        let trigUpdate = """
            CREATE TRIGGER IF NOT EXISTS posts_topics_text_au
            AFTER UPDATE OF secondary_topics ON Posts
            BEGIN
                UPDATE Posts
                SET secondary_topics_text = (
                    CASE
                        WHEN json_valid(new.secondary_topics)
                        THEN (
                            SELECT trim(group_concat(value, ' '))
                            FROM json_each(new.secondary_topics)
                        )
                        ELSE NULL
                    END
                )
                WHERE id = new.id;
            END;
            """
        try db.execute(trigInsert)
        try db.execute(trigUpdate)

        // FTS5 index for keyword/topic search
        let createFTS = """
            CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts USING fts5(
                full_text,
                primary_topic,
                secondary_topics_text,
                content='Posts',
                content_rowid='id'
            );
            """
        try db.execute(createFTS)
        let ftsAI = """
            CREATE TRIGGER IF NOT EXISTS posts_fts_ai AFTER INSERT ON Posts BEGIN
                INSERT INTO posts_fts(rowid, full_text, primary_topic, secondary_topics_text)
                VALUES (new.id, new.full_text, new.primary_topic, new.secondary_topics_text);
            END;
            """
        let ftsAD = """
            CREATE TRIGGER IF NOT EXISTS posts_fts_ad AFTER DELETE ON Posts BEGIN
                INSERT INTO posts_fts(posts_fts, rowid, full_text, primary_topic, secondary_topics_text)
                VALUES('delete', old.id, old.full_text, old.primary_topic, old.secondary_topics_text);
            END;
            """
        let ftsAU = """
            CREATE TRIGGER IF NOT EXISTS posts_fts_au AFTER UPDATE ON Posts BEGIN
                INSERT INTO posts_fts(posts_fts, rowid, full_text, primary_topic, secondary_topics_text)
                VALUES('delete', old.id, old.full_text, old.primary_topic, old.secondary_topics_text);
                INSERT INTO posts_fts(rowid, full_text, primary_topic, secondary_topics_text)
                VALUES (new.id, new.full_text, new.primary_topic, new.secondary_topics_text);
            END;
            """
        try db.execute(ftsAI)
        try db.execute(ftsAD)
        try db.execute(ftsAU)
        try migrateStoredHTMLEntitiesIfNeeded()

        // No virtual tables needed - using CPU-based vector search for maximum accuracy
        print("[VectorSearch] CPU-based vector search ready")
    }

    // MARK: - Utilities

    private func floatsToData(_ floats: [Float]) -> Data? {
        guard !floats.isEmpty else { return nil }
        var copy = floats
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    private func dataToFloats(_ data: Data?) -> [Float] {
        guard let data, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
        _ = data.copyBytes(to: dst)
        }

        return out
    }

    private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        if let data = try? JSONEncoder().encode(value) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func decodeJSON<T: Decodable>(_ text: String?, as type: T.Type) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func floatsToBlob(_ floats: [Float]) -> Blob? {
        guard !floats.isEmpty else { return nil }
        
        // Validate input before storage
        let hasInvalidValues = floats.contains { $0.isNaN || $0.isInfinite }
        if hasInvalidValues {
            print("[SQLiteManager] Warning: Invalid values (NaN/Inf) in embedding before storage")
        }
        
        var copy = floats
        let data = Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
        return Blob(bytes: [UInt8](data))
    }

    private func normalizedTextEmbedding(_ embedding: [Float]) -> [Float] {
        guard !embedding.isEmpty, !embedding.contains(where: { $0.isNaN || $0.isInfinite }) else {
            return []
        }
        guard vectorMagnitude(embedding) > 1e-12 else {
            return []
        }
        return l2NormalizeVec(embedding)
    }

    private func postColumnNames() throws -> Set<String> {
        var columns = Set<String>()
        for row in try db.prepare("PRAGMA table_info(Posts);") {
            if let name = row[1] as? String {
                columns.insert(name)
            }
        }
        return columns
    }

    private func migrateEmbeddingColumns() throws {
        var columns = try postColumnNames()
        if !columns.contains("text_embedding") {
            try db.execute("ALTER TABLE Posts ADD COLUMN text_embedding BLOB;")
            columns.insert("text_embedding")
        }

        if !columns.contains("text_embedding_normalized") {
            try db.execute("ALTER TABLE Posts ADD COLUMN text_embedding_normalized BLOB;")
            columns.insert("text_embedding_normalized")
        }

        if !columns.contains("img_embedding") {
            try db.execute("ALTER TABLE Posts ADD COLUMN img_embedding BLOB;")
            columns.insert("img_embedding")
        }

        if columns.contains("embedding") {
            try db.execute("UPDATE Posts SET text_embedding = COALESCE(text_embedding, embedding) WHERE text_embedding IS NULL;")
            try? db.execute("ALTER TABLE Posts DROP COLUMN embedding;")
        }
    }

    private func prepareImageEmbeddingStorage() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS ImageEmbeddings (
            post_id INTEGER NOT NULL,
            media_url TEXT NOT NULL,
            embedding BLOB NOT NULL,
            model_version TEXT NOT NULL,
            PRIMARY KEY (post_id, media_url)
        );
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS image_embeddings_model_post_idx ON ImageEmbeddings (model_version, post_id);")
        try db.execute("CREATE INDEX IF NOT EXISTS image_embeddings_model_url_idx ON ImageEmbeddings (model_version, media_url);")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS UnavailableImageEmbeddings (
            post_id INTEGER NOT NULL,
            media_url TEXT NOT NULL,
            http_status INTEGER NOT NULL,
            detected_at REAL NOT NULL,
            PRIMARY KEY (post_id, media_url)
        );
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS unavailable_image_embeddings_post_idx ON UnavailableImageEmbeddings (post_id);")
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS image_embeddings_posts_ad
        AFTER DELETE ON Posts
        BEGIN
            DELETE FROM ImageEmbeddings WHERE post_id = old.id;
        END;
        """)
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS image_embeddings_posts_media_au
        AFTER UPDATE OF media, article, quoted_post ON Posts
        WHEN ifnull(old.media, '') != ifnull(new.media, '')
          OR ifnull(old.article, '') != ifnull(new.article, '')
          OR ifnull(old.quoted_post, '') != ifnull(new.quoted_post, '')
        BEGIN
            DELETE FROM ImageEmbeddings WHERE post_id = new.id;
        END;
        """)
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS unavailable_image_embeddings_posts_ad
        AFTER DELETE ON Posts
        BEGIN
            DELETE FROM UnavailableImageEmbeddings WHERE post_id = old.id;
        END;
        """)
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS unavailable_image_embeddings_posts_media_au
        AFTER UPDATE OF media, article, quoted_post ON Posts
        WHEN ifnull(old.media, '') != ifnull(new.media, '')
          OR ifnull(old.article, '') != ifnull(new.article, '')
          OR ifnull(old.quoted_post, '') != ifnull(new.quoted_post, '')
        BEGIN
            DELETE FROM UnavailableImageEmbeddings WHERE post_id = new.id;
        END;
        """)

        let metadataKey = "image_embedding_model_version"
        let readVersion = try db.prepare("SELECT value FROM AppMetadata WHERE key = ? LIMIT 1;")
        let storedVersion = try readVersion.scalar(metadataKey) as? String
        guard storedVersion != EmbeddingsManager.imageEmbeddingModelVersion else { return }

        try db.transaction {
            try db.run("DELETE FROM ImageEmbeddings;")
            try db.run("UPDATE Posts SET img_embedding = NULL;")
            try db.run(
                "INSERT INTO AppMetadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                metadataKey,
                EmbeddingsManager.imageEmbeddingModelVersion
            )
        }
        print("[ImageSearch] Prepared storage for \(EmbeddingsManager.imageEmbeddingModelVersion)")
    }

    private func migrateBookmarkOrderColumns() throws {
        var columns = try postColumnNames()
        if !columns.contains("bookmark_import_generation") {
            try db.execute("ALTER TABLE Posts ADD COLUMN bookmark_import_generation INTEGER;")
            columns.insert("bookmark_import_generation")
        }

        if !columns.contains("bookmark_order") {
            try db.execute("ALTER TABLE Posts ADD COLUMN bookmark_order INTEGER;")
            columns.insert("bookmark_order")
        }

        let rows = try db.prepare("""
            SELECT id
            FROM Posts
            WHERE bookmark_import_generation IS NULL OR bookmark_order IS NULL
            ORDER BY created_at DESC, id DESC;
            """)
        let update = try db.prepare("""
            UPDATE Posts
            SET bookmark_import_generation = COALESCE(bookmark_import_generation, 0),
                bookmark_order = COALESCE(bookmark_order, ?)
            WHERE id = ?;
            """)

        var order = 0
        try db.transaction {
            for row in rows {
                guard let id = row[0] as? Int64 else { continue }
                try update.run(order, id)
                order += 1
            }
        }
    }

    private func metadataValue(for key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM AppMetadata WHERE key = ? LIMIT 1;")
        for row in try stmt.run(key) {
            return row[0] as? String
        }
        return nil
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        let stmt = try db.prepare("""
        INSERT INTO AppMetadata (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
        try stmt.run(key, value)
    }

    private func migrateStoredHTMLEntitiesIfNeeded() throws {
        let migrationKey = "decode_html_entities_v1"
        guard try metadataValue(for: migrationKey) != "complete" else { return }

        let rows = try db.prepare("""
        SELECT id, full_text, article, links, quoted_post
        FROM Posts
        WHERE full_text LIKE '%&%;%'
           OR article LIKE '%&%;%'
           OR links LIKE '%&%;%'
           OR quoted_post LIKE '%&%;%';
        """)
        let update = try db.prepare("""
        UPDATE Posts
        SET full_text = ?,
            article = ?,
            links = ?,
            quoted_post = ?,
            text_embedding = NULL,
            text_embedding_normalized = NULL
        WHERE id = ?;
        """)

        var repairedCount = 0
        try db.transaction {
            for row in rows {
                guard let id = row[0] as? Int64 else { continue }
                let fullText = (row[1] as? String) ?? ""
                let articleJSON = row[2] as? String
                let linksJSON = row[3] as? String
                let quotedJSON = row[4] as? String

                let decodedFullText = fullText.decodedHTMLText
                let decodedArticleJSON = decodeHTMLEntitiesInJSON(articleJSON, as: Article.self)
                let decodedLinksJSON = decodeHTMLEntitiesInLinksJSON(linksJSON)
                let decodedQuotedJSON = decodeHTMLEntitiesInJSON(quotedJSON, as: QuotedPost.self)

                guard decodedFullText != fullText ||
                        decodedArticleJSON != articleJSON ||
                        decodedLinksJSON != linksJSON ||
                        decodedQuotedJSON != quotedJSON
                else {
                    continue
                }

                try update.run(decodedFullText, decodedArticleJSON, decodedLinksJSON, decodedQuotedJSON, id)
                repairedCount += 1
            }

            try setMetadataValue("complete", for: migrationKey)
        }

        if repairedCount > 0 {
            invalidateTextEmbeddingIndex()
            print("[SQLiteManager] Decoded HTML entities in \(repairedCount) stored posts")
        }
    }

    private func decodeHTMLEntitiesInJSON<T: Codable>(_ text: String?, as type: T.Type) -> String? {
        guard let text else { return nil }
        guard text.containsHTMLTextEntity else { return text }
        guard let decoded = decodeJSON(text, as: type) else { return text }
        return encodeJSON(decoded) ?? text
    }

    private func decodeHTMLEntitiesInLinksJSON(_ text: String?) -> String? {
        guard let text else { return nil }
        guard text.containsHTMLTextEntity else { return text }
        guard let decoded = decodeJSON(text, as: [PostLink].self) else { return text }
        return encodeJSON(decoded.isEmpty ? nil : decoded) ?? text
    }

    func beginBookmarkImportGeneration() async throws -> Int64 {
        try await connect()
        return try nextBookmarkImportGeneration()
    }

    private func nextBookmarkImportGeneration() throws -> Int64 {
        let stmt = try db.prepare("SELECT COALESCE(MAX(bookmark_import_generation), 0) + 1 FROM Posts;")
        for row in try stmt.run() {
            if let value = row[0] as? Int64 {
                return value
            }
            if let value = row[0] as? Int {
                return Int64(value)
            }
        }
        return 1
    }

    // MARK: - Basic ops

    func disconnect() {}

    private func invalidateTextEmbeddingIndex() {
        textEmbeddingIndex = nil
    }

    /// Releases the CPU-side exact-search index without changing stored embeddings.
    /// The next semantic search lazily rebuilds it from SQLite.
    func releaseTextEmbeddingIndex() {
        guard let index = textEmbeddingIndex else { return }
        let estimatedBytes = index.vectors.count * MemoryLayout<Float>.stride
            + index.ids.count * MemoryLayout<Int>.stride
        textEmbeddingIndex = nil
        print("[VectorSearch] Released text embedding index rows=\(index.ids.count) estimated_bytes=\(estimatedBytes)")
    }

    private func databaseFileURLs() throws -> (main: URL, wal: URL, shm: URL) {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Xray", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let main = dir.appendingPathComponent(dbFileName)
        return (
            main: main,
            wal: dir.appendingPathComponent(dbFileName + "-wal"),
            shm: dir.appendingPathComponent(dbFileName + "-shm")
        )
    }

    /// Completely delete the SQLite database file (and WAL/SHM), then recreate an empty schema
    func resetDatabase() async throws {
        invalidateTextEmbeddingIndex()
        // Drop current connection
        db = nil
        isDatabaseReady = false
        let fm = FileManager.default
        let urls = try databaseFileURLs()
        for url in [urls.main, urls.wal, urls.shm] {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        // Reconnect and recreate schema
        try await connect()
        invalidateTextEmbeddingIndex()
    }

    func rebuildDatabaseSchemaPreservingPosts(onProgress: ((Double, String) async -> Void)? = nil) async throws -> Int {
        try await connect()
        await onProgress?(0.05, "Snapshotting current posts...")
        let snapshot = try fetchAllPostsForSchemaRebuild()
        await onProgress?(0.20, "Preparing database backup...")

        let fm = FileManager.default
        let urls = try databaseFileURLs()
        let backupDir = fm.temporaryDirectory.appendingPathComponent("XraySchemaRebuild-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let databaseFiles = [urls.main, urls.wal, urls.shm]
        var backups: [(source: URL, backup: URL)] = []
        for source in databaseFiles where fm.fileExists(atPath: source.path) {
            let backup = backupDir.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: backup)
            backups.append((source: source, backup: backup))
        }

        func removeDatabaseFiles() {
            for url in databaseFiles where fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }

        do {
            await onProgress?(0.35, "Recreating database schema...")
            db = nil
            isDatabaseReady = false
            invalidateTextEmbeddingIndex()
            removeDatabaseFiles()

            try await connect()

            if !snapshot.isEmpty {
                await onProgress?(0.45, "Restoring \(snapshot.count) posts...")
                try await insertPosts(snapshot.map(\.post), batchSize: 100) { currentBatch, totalBatches in
                    let fraction = Double(currentBatch) / Double(max(totalBatches, 1))
                    Task {
                        await onProgress?(0.45 + min(0.50, fraction * 0.50), "Restoring posts (\(currentBatch)/\(totalBatches))...")
                    }
                }
                try restoreNormalizedTextEmbeddings(snapshot)
            }

            invalidateTextEmbeddingIndex()
            try? fm.removeItem(at: backupDir)
            await onProgress?(1.0, "Database schema rebuild complete. Restored \(snapshot.count) posts.")
            return snapshot.count
        } catch {
            db = nil
            isDatabaseReady = false
            invalidateTextEmbeddingIndex()
            removeDatabaseFiles()

            for item in backups {
                try? fm.copyItem(at: item.backup, to: item.source)
            }
            try? fm.removeItem(at: backupDir)
            try? await connect()
            throw error
        }
    }

    func postExists(id: Int) async throws -> Bool {
        try await connect()
        let stmt = try db.prepare("SELECT 1 FROM Posts WHERE id = ? LIMIT 1;")
        for row in try stmt.run(Int64(id)) { _ = row; return true }
        return false
    }
    
    func getPostCount() async throws -> Int {
        try await connect()
        let stmt = try db.prepare("SELECT COUNT(*) FROM Posts;")
        for row in try stmt.run() {
            if let n = row[0] as? Int64 { return Int(n) }
        }
            return 0
        }

    func getTopicAnnotationCounts() async throws -> TopicAnnotationCounts {
        try await connect()
        let stmt = try db.prepare("""
        SELECT
            COUNT(*) AS total_count,
            SUM(CASE WHEN primary_topic IS NOT NULL AND trim(primary_topic) != '' THEN 1 ELSE 0 END) AS annotated_count
        FROM Posts;
        """)

        for row in try stmt.run() {
            let total: Int
            if let value = row[0] as? Int64 {
                total = Int(value)
            } else if let value = row[0] as? Int {
                total = value
            } else {
                total = 0
            }

            let annotated: Int
            if let value = row[1] as? Int64 {
                annotated = Int(value)
            } else if let value = row[1] as? Int {
                annotated = value
            } else {
                annotated = 0
            }

            return TopicAnnotationCounts(total: total, annotated: annotated)
        }

        return TopicAnnotationCounts(total: 0, annotated: 0)
    }

    func clearTopics(forPostID postID: Int) async throws {
        try await connect()
        let stmt = try db.prepare("""
            UPDATE Posts
            SET primary_topic = '',
                secondary_topics = '[]'
            WHERE id = ?;
            """)
        try stmt.run(Int64(postID))
    }

    func updateTopics(forPostID postID: Int, primaryTopic: String, secondaryTopics: [String]) async throws {
        try await connect()
        let stmt = try db.prepare("""
            UPDATE Posts
            SET primary_topic = ?,
                secondary_topics = ?
            WHERE id = ?;
            """)
        let secondaryJSON = encodeJSON(secondaryTopics) ?? "[]"
        try stmt.run(primaryTopic, secondaryJSON, Int64(postID))
    }

    func updateMissingTopics(_ updates: [TopicUpdate]) async throws {
        guard !updates.isEmpty else { return }
        try await connect()
        try db.transaction {
            let stmt = try db.prepare("""
                UPDATE Posts
                SET primary_topic = ?,
                    secondary_topics = ?
                WHERE id = ?
                  AND trim(coalesce(primary_topic, '')) = '';
                """)
            for update in updates {
                let secondaryJSON = encodeJSON(update.secondaryTopics) ?? "[]"
                try stmt.run(update.primaryTopic, secondaryJSON, Int64(update.postID))
            }
        }
    }

    func deletePost(forPostID postID: Int) async throws {
        try await connect()
        try db.transaction {
            try db.run("DELETE FROM ImageEmbeddings WHERE post_id = ?;", Int64(postID))
            try db.run("DELETE FROM Posts WHERE id = ?;", Int64(postID))
        }
        invalidateTextEmbeddingIndex()
    }

    func updateMediaMetadata(for post: Post) async throws {
        try await connect()
        let stmt = try db.prepare("""
            UPDATE Posts
            SET media = ?,
                article = ?,
                links = ?,
                quoted_post = ?
            WHERE id = ?;
            """)
        try stmt.run(encodeJSON(post.media), encodeJSON(post.article), encodeJSON(post.links.isEmpty ? nil : post.links), encodeJSON(post.quoted_post), Int64(post.id))
    }
        
    // MARK: - Inserts

    func insertPosts(
        _ posts: [Post],
        batchSize: Int = 50,
        bookmarkImportGeneration: Int64? = nil,
        bookmarkOrderOffset: Int = 0,
        onProgress: @escaping (Int, Int) -> Void
        ) async throws {
        guard !posts.isEmpty else { return }
        try await connect()
        let totalBatches = (posts.count + batchSize - 1) / batchSize
        var currentBatch = 0

        for start in stride(from: 0, to: posts.count, by: batchSize) {
            let end = min(start + batchSize, posts.count)
            let batch = Array(posts[start..<end])
            try db.transaction {
        let sql = """
                INSERT INTO Posts (
                    id, created_at, full_text, media, article, links, quoted_post, screen_name, name, profile_image_url, profile_image_shape, url,
                    text_embedding, text_embedding_normalized, img_embedding, primary_topic, secondary_topics,
                    bookmark_import_generation, bookmark_order
                ) VALUES (
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                )
                ON CONFLICT(id) DO UPDATE SET
                    created_at=excluded.created_at,
                    full_text=excluded.full_text,
                    media=excluded.media,
                    article=excluded.article,
                    links=excluded.links,
                    quoted_post=excluded.quoted_post,
                    screen_name=excluded.screen_name,
                    name=excluded.name,
                    profile_image_url=excluded.profile_image_url,
                    profile_image_shape=excluded.profile_image_shape,
                    url=excluded.url,
                    text_embedding=CASE
                        WHEN ifnull(excluded.quoted_post, '') != ifnull(Posts.quoted_post, '') THEN excluded.text_embedding
                        ELSE COALESCE(excluded.text_embedding, Posts.text_embedding)
                    END,
                    text_embedding_normalized=CASE
                        WHEN ifnull(excluded.quoted_post, '') != ifnull(Posts.quoted_post, '') THEN excluded.text_embedding_normalized
                        ELSE COALESCE(excluded.text_embedding_normalized, Posts.text_embedding_normalized)
                    END,
                    img_embedding=CASE
                        WHEN ifnull(excluded.quoted_post, '') != ifnull(Posts.quoted_post, '') THEN excluded.img_embedding
                        ELSE COALESCE(excluded.img_embedding, Posts.img_embedding)
                    END,
                    primary_topic=excluded.primary_topic,
                    secondary_topics=excluded.secondary_topics,
                    bookmark_import_generation=COALESCE(excluded.bookmark_import_generation, Posts.bookmark_import_generation),
                    bookmark_order=COALESCE(excluded.bookmark_order, Posts.bookmark_order);
                """
                let stmt = try db.prepare(sql)
                for (index, p) in batch.enumerated() {
                    let mediaJSON = encodeJSON(p.media)
                    let articleJSON = encodeJSON(p.article)
                    let linksJSON = encodeJSON(p.links.isEmpty ? nil : p.links)
                    let quotedJSON = encodeJSON(p.quoted_post)
                    let secJSON = encodeJSON(p.secondary_topics)
                    let effectiveGeneration = bookmarkImportGeneration ?? p.bookmark_import_generation
                    let effectiveOrder = bookmarkImportGeneration == nil ? p.bookmark_order : bookmarkOrderOffset + start + index
                    try stmt.run(
                        Int64(p.id),
                        p.created_at.timeIntervalSince1970,
                        p.full_text,
                        mediaJSON,
                        articleJSON,
                        linksJSON,
                        quotedJSON,
                        p.screen_name,
                        p.name,
                        p.profile_image_url.absoluteString,
                        p.profile_image_shape.rawValue,
                        p.url.absoluteString,
                        floatsToBlob(p.text_embedding),
                        floatsToBlob(normalizedTextEmbedding(p.text_embedding)),
                        floatsToBlob(p.img_embedding),
                        p.primary_topic,
                        secJSON,
                        effectiveGeneration,
                        effectiveOrder
                    )
                    // Embeddings stored in main table for CPU-based vector search
                }
            }
            currentBatch += 1
            let batchNumber = currentBatch
            await MainActor.run { onProgress(batchNumber, totalBatches) }
        }
        invalidateTextEmbeddingIndex()
    }

    func softImportPosts(
        _ posts: [Post],
        batchSize: Int = 50,
        bookmarkImportGeneration: Int64? = nil,
        bookmarkOrderOffset: Int = 0,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> SoftImportResult {
        guard !posts.isEmpty else {
            return SoftImportResult(insertedCount: 0, skippedExistingCount: 0)
        }
        try await connect()

        let totalBatches = (posts.count + batchSize - 1) / batchSize
        var currentBatch = 0
        var insertedCount = 0
        var skippedExistingCount = 0

        for start in stride(from: 0, to: posts.count, by: batchSize) {
            let end = min(start + batchSize, posts.count)
            let batch = Array(posts[start..<end])
            let orderedBatch = batch.enumerated().map { index, post in
                (post: post, order: bookmarkOrderOffset + start + index)
            }
            let batchIds = batch.map(\.id)
            let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ", ")
            let existingSQL = "SELECT id FROM Posts WHERE id IN (\(placeholders));"
            let existingStmt = try db.prepare(existingSQL)

            var existingIds = Set<Int>()
            for row in try existingStmt.run(batchIds.map(Int64.init)) {
                existingIds.insert(Int(row[0] as! Int64))
            }

            let postsToInsert = orderedBatch.filter { !existingIds.contains($0.post.id) }
            let postsToRefreshOrder = orderedBatch.filter { existingIds.contains($0.post.id) }
            skippedExistingCount += existingIds.count

            if bookmarkImportGeneration != nil, !postsToRefreshOrder.isEmpty {
                try db.transaction {
                    let updateOrderStmt = try db.prepare("""
                        UPDATE Posts
                        SET bookmark_import_generation = ?,
                            bookmark_order = ?
                        WHERE id = ?;
                        """)
                    for item in postsToRefreshOrder {
                        try updateOrderStmt.run(bookmarkImportGeneration, item.order, Int64(item.post.id))
                    }
                }
            }

            if !postsToInsert.isEmpty {
                try db.transaction {
                    let sql = """
                    INSERT INTO Posts (
                        id, created_at, full_text, media, article, links, quoted_post, screen_name, name, profile_image_url, profile_image_shape, url,
                        text_embedding, text_embedding_normalized, img_embedding, primary_topic, secondary_topics,
                        bookmark_import_generation, bookmark_order
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    );
                    """
                    let stmt = try db.prepare(sql)
                    for item in postsToInsert {
                        let p = item.post
                        let mediaJSON = encodeJSON(p.media)
                        let articleJSON = encodeJSON(p.article)
                        let linksJSON = encodeJSON(p.links.isEmpty ? nil : p.links)
                        let quotedJSON = encodeJSON(p.quoted_post)
                        let secJSON = encodeJSON(p.secondary_topics)
                        let effectiveGeneration = bookmarkImportGeneration ?? p.bookmark_import_generation
                        let effectiveOrder = bookmarkImportGeneration == nil ? p.bookmark_order : item.order
                        try stmt.run(
                            Int64(p.id),
                            p.created_at.timeIntervalSince1970,
                            p.full_text,
                            mediaJSON,
                            articleJSON,
                            linksJSON,
                            quotedJSON,
                            p.screen_name,
                            p.name,
                            p.profile_image_url.absoluteString,
                            p.profile_image_shape.rawValue,
                            p.url.absoluteString,
                            floatsToBlob(p.text_embedding),
                            floatsToBlob(normalizedTextEmbedding(p.text_embedding)),
                            floatsToBlob(p.img_embedding),
                            p.primary_topic,
                            secJSON,
                            effectiveGeneration,
                            effectiveOrder
                        )
                    }
                }
                insertedCount += postsToInsert.count
            }

            currentBatch += 1
            let batchNumber = currentBatch
            await MainActor.run { onProgress(batchNumber, totalBatches) }
        }

        if insertedCount > 0 {
            invalidateTextEmbeddingIndex()
        }

        return SoftImportResult(
            insertedCount: insertedCount,
            skippedExistingCount: skippedExistingCount
        )
    }

    func softImportBrowserPosts(
        sessionID: String,
        batchSequence: Int,
        posts: [Post],
        batchSize: Int = 50,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> SoftImportResult {
        try await connect()
        let generation: Int64
        if let existingGeneration = browserImportGenerations[sessionID] {
            generation = existingGeneration
        } else {
            generation = try nextBookmarkImportGeneration()
            browserImportGenerations[sessionID] = generation
        }

        let orderOffset = max(0, batchSequence - 1) * browserImportOrderStride
        return try await softImportPosts(
            posts,
            batchSize: batchSize,
            bookmarkImportGeneration: generation,
            bookmarkOrderOffset: orderOffset,
            onProgress: onProgress
        )
    }

    // MARK: - Reads

    private func fetchAllPostsForSchemaRebuild() throws -> [SchemaRebuildPost] {
        let sql = """
        SELECT \(SQLitePostRowDecoder.schemaRebuildProjection)
        FROM Posts
        ORDER BY COALESCE(bookmark_import_generation, 0) DESC,
                 COALESCE(bookmark_order, 9223372036854775807) ASC,
                 created_at DESC,
                 id DESC;
        """

        var posts: [SchemaRebuildPost] = []
        for row in try db.prepare(sql) {
            let decoded = postRowDecoder.decode(row, layout: .schemaRebuild)

            posts.append(SchemaRebuildPost(
                post: decoded.post,
                normalizedTextEmbedding: decoded.normalizedTextEmbedding
            ))
        }
        return posts
    }

    private func restoreNormalizedTextEmbeddings(_ snapshot: [SchemaRebuildPost]) throws {
        let stored = snapshot.filter { !$0.normalizedTextEmbedding.isEmpty }
        guard !stored.isEmpty else { return }

        try db.transaction {
            let stmt = try db.prepare("UPDATE Posts SET text_embedding_normalized = ? WHERE id = ?;")
            for item in stored {
                try stmt.run(floatsToBlob(item.normalizedTextEmbedding), Int64(item.post.id))
            }
        }
    }

    func fetchHomePosts(limit: Int, after post: Post? = nil) async throws -> [Post] {
        guard limit > 0 else { return [] }
        try await connect()

        var args: [Binding?] = []
        var whereSQL = ""
        if
            let post,
            let generation = post.bookmark_import_generation,
            let order = post.bookmark_order
        {
            whereSQL = """
            WHERE (
                COALESCE(bookmark_import_generation, 0) < ? OR
                (
                    COALESCE(bookmark_import_generation, 0) = ? AND
                    (
                        COALESCE(bookmark_order, 9223372036854775807) > ? OR
                        (
                            COALESCE(bookmark_order, 9223372036854775807) = ? AND
                            (created_at < ? OR (created_at = ? AND id < ?))
                        )
                    )
                )
            )
            """
            args.append(generation)
            args.append(generation)
            args.append(order)
            args.append(order)
            args.append(post.created_at.timeIntervalSince1970)
            args.append(post.created_at.timeIntervalSince1970)
            args.append(Int64(post.id))
        } else if let post {
            whereSQL = "WHERE (created_at < ? OR (created_at = ? AND id < ?))"
            args.append(post.created_at.timeIntervalSince1970)
            args.append(post.created_at.timeIntervalSince1970)
            args.append(Int64(post.id))
        }

        let sql = """
        SELECT \(SQLitePostRowDecoder.standardProjection)
            FROM Posts
        \(whereSQL)
        ORDER BY COALESCE(bookmark_import_generation, 0) DESC,
                 COALESCE(bookmark_order, 9223372036854775807) ASC,
                 created_at DESC,
                 id DESC
        LIMIT \(limit);
        """
        let stmt = try db.prepare(sql)
        var out: [Post] = []
        for row in try stmt.run(args) {
            out.append(postRowDecoder.decode(row).post)
        }
        return out
    }

    func fetchPosts(limit: Int, beforeCreatedAt: Date? = nil, beforeId: Int? = nil) async throws -> [Post] {
        guard limit > 0 else { return [] }
        try await connect()
        var args: [Binding?] = []
        var whereSQL = ""
        if let bDate = beforeCreatedAt, let bId = beforeId {
            whereSQL = "WHERE (created_at < ? OR (created_at = ? AND id < ?))"
            args.append(bDate.timeIntervalSince1970)
            args.append(bDate.timeIntervalSince1970)
            args.append(Int64(bId))
        }
        let sql = """
        SELECT \(SQLitePostRowDecoder.standardProjection)
            FROM Posts
        \(whereSQL)
        ORDER BY created_at DESC, id DESC
        LIMIT \(limit);
        """
        let stmt = try db.prepare(sql)
        var out: [Post] = []
        for row in try stmt.run(args) {
            out.append(postRowDecoder.decode(row).post)
        }
        return out
    }

    // MARK: - Dorked search

    func searchPosts(query: String, mode: SearchMode, limit: Int = 100, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        try await searchPosts(query: query, mode: mode, limit: limit, diagnostics: nil, onProgress: onProgress)
    }

    func searchPostsWithDiagnostics(query: String, mode: SearchMode, limit: Int = 100, onProgress: (([Post]) async -> Void)? = nil) async throws -> SearchExecutionResult {
        try Task.checkCancellation()
        let startedAt = Date()
        let collector = SearchDiagnosticsCollector()
        let posts = try await searchPosts(query: query, mode: mode, limit: limit, diagnostics: collector, onProgress: onProgress)
        try Task.checkCancellation()
        let counts = collector.postIDsByMethod
            .map { (method: $0.key, count: $0.value.count) }
            .sorted { $0.method.localizedCaseInsensitiveCompare($1.method) == .orderedAscending }
        let diagnostics = SearchDiagnostics(
            query: query,
            mode: mode.rawValue,
            totalResultCount: posts.count,
            totalDuration: Date().timeIntervalSince(startedAt),
            minimumEmbeddingSimilarity: minimumEmbeddingSimilarity,
            minimumImageEmbeddingSimilarity: minimumImageEmbeddingSimilarity,
            plan: diagnosticPlan(for: query, mode: mode),
            countsByMethod: counts,
            operations: collector.operations
        )
        return SearchExecutionResult(posts: posts, diagnostics: diagnostics)
    }

    private func searchPosts(query: String, mode: SearchMode, limit: Int, diagnostics: SearchDiagnosticsCollector?, onProgress: (([Post]) async -> Void)?) async throws -> [Post] {
        try Task.checkCancellation()
        if let booleanExpression = parseBooleanSearchExpression(query) {
            return try await searchPosts(matching: booleanExpression, mode: mode, limit: limit, diagnostics: diagnostics, onProgress: onProgress)
        }

        return try await searchPostsWithoutBoolean(query: query, mode: mode, limit: limit, diagnostics: diagnostics, onProgress: onProgress)
    }

    private func searchPostsWithoutBoolean(query: String, mode: SearchMode, limit: Int = 100, diagnostics: SearchDiagnosticsCollector? = nil, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        let parsed = parseDorkedSearchQuery(query)
        guard limit > 0 else { return [] }
        let excludedEmbeddingIDs = try await excludedEmbeddingPostIDs(for: parsed, diagnostics: diagnostics)
        let excludedImageEmbeddingIDs = try await excludedImageEmbeddingPostIDs(for: parsed, diagnostics: diagnostics)

        func applyParsedFilters(to posts: [Post]) -> [Post] {
            posts.filter { post in
                (excludedEmbeddingIDs.isEmpty || !excludedEmbeddingIDs.contains(post.id)) &&
                (excludedImageEmbeddingIDs.isEmpty || !excludedImageEmbeddingIDs.contains(post.id)) &&
                (!parsed.hasHardFilters || postMatches(post, parsed: parsed))
            }
        }

        if parsed.hasHardFilters && !parsed.hasAnySearchText {
            print("[Search] Dork-only query detected; using SQL filters and skipping vector search")
            let startedAt = Date()
            let hasSemanticExclusions = !excludedEmbeddingIDs.isEmpty || !excludedImageEmbeddingIDs.isEmpty
            let fetched = try await fetchPosts(matching: parsed, limit: hasSemanticExclusions ? Int.max : limit, onProgress: nil)
            let filtered = Array(applyParsedFilters(to: fetched).prefix(limit))
            diagnostics?.record(method: "SQL filters", query: query, posts: filtered, duration: Date().timeIntervalSince(startedAt), detail: "Dork-only query; vector and text ranking skipped")
            await onProgress?(filtered)
            return filtered
        }

        let candidateLimit = parsed.hasHardFilters ? Int.max : limit
        let progress: (([Post]) async -> Void)? = onProgress.map { handler in
            { posts in
                let visiblePosts = applyParsedFilters(to: posts)
                await handler(Array(visiblePosts.prefix(limit)))
            }
        }

        let results: [Post]
        switch mode {
        case .keyword:
            results = try await searchPosts(query: parsed.searchText, limit: candidateLimit, diagnostics: diagnostics, onProgress: progress)
        case .embedding:
            let minimumSimilarity = parsed.hasHardFilters ? -1.0 : nil
            if !parsed.imageEmbeddingSearchText.isEmpty {
                results = try await searchPostsByImageVector(
                    query: parsed.imageEmbeddingSearchText,
                    limit: candidateLimit,
                    minimumSimilarity: minimumSimilarity,
                    diagnostics: diagnostics,
                    onProgress: progress
                )
            } else {
                let embeddingQuery = parsed.embeddingSearchText.isEmpty ? parsed.searchText : parsed.embeddingSearchText
                results = try await searchPostsByVector(query: embeddingQuery, limit: candidateLimit, minimumSimilarity: minimumSimilarity, diagnostics: diagnostics, onProgress: progress)
            }
        case .hybrid:
            let hybridQuery = parsed.embeddingSearchText.isEmpty ? parsed.searchText : parsed.embeddingSearchText
            let imageQuery = parsed.imageEmbeddingSearchText.isEmpty ? parsed.searchText : parsed.imageEmbeddingSearchText
            results = try await searchPostsHybridWeighted(
                query: hybridQuery,
                keywordQuery: parsed.searchText,
                imageQuery: imageQuery,
                limit: candidateLimit,
                minimumEmbeddingSimilarity: parsed.hasHardFilters ? -1.0 : nil,
                minimumImageEmbeddingSimilarity: parsed.hasHardFilters ? -1.0 : nil,
                diagnostics: diagnostics,
                onProgress: progress
            )
        }

        guard parsed.hasHardFilters || !excludedEmbeddingIDs.isEmpty else { return Array(results.prefix(limit)) }
        return Array(applyParsedFilters(to: results).prefix(limit))
    }

    private func searchPosts(matching expression: BooleanSearchExpression, mode: SearchMode, limit: Int, diagnostics: SearchDiagnosticsCollector?, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        guard limit > 0 else { return [] }

        var merged: [Post] = []
        var seenIDs: Set<Int> = []

        for group in expression.groups {
            try Task.checkCancellation()
            let groupResults = try await searchPosts(matchingAll: group, mode: mode, diagnostics: diagnostics)
            for post in groupResults where !seenIDs.contains(post.id) {
                seenIDs.insert(post.id)
                merged.append(post)
                if merged.count >= limit {
                    let limited = Array(merged.prefix(limit))
                    await onProgress?(limited)
                    return limited
                }
            }

            await onProgress?(Array(merged.prefix(limit)))
        }

        return Array(merged.prefix(limit))
    }

    private func searchPosts(matchingAll operands: [String], mode: SearchMode, diagnostics: SearchDiagnosticsCollector?) async throws -> [Post] {
        guard let first = operands.first else { return [] }

        var rankedResults = try await searchPostsWithoutBoolean(query: first, mode: mode, limit: Int.max, diagnostics: diagnostics)
        for operand in operands.dropFirst() {
            try Task.checkCancellation()
            let operandResults = try await searchPostsWithoutBoolean(query: operand, mode: mode, limit: Int.max, diagnostics: diagnostics)
            let matchingIDs = Set(operandResults.map(\.id))
            rankedResults = rankedResults.filter { matchingIDs.contains($0.id) }
            if rankedResults.isEmpty { break }
        }

        return rankedResults
    }

    private func excludedEmbeddingPostIDs(for parsed: DorkedSearchQuery, diagnostics: SearchDiagnosticsCollector? = nil) async throws -> Set<Int> {
        guard !parsed.excludedEmbeddingSearchText.isEmpty else { return [] }

        var excludedIDs: Set<Int> = []
        for query in parsed.excludedEmbeddingSearchText {
            let startedAt = Date()
            let matches = try await searchPostsByVectorScored(query: query, limit: Int.max)
            for (post, _) in matches {
                excludedIDs.insert(post.id)
            }
            diagnostics?.record(method: "Excluded embedding", query: query, posts: matches.map(\.0), duration: Date().timeIntervalSince(startedAt), detail: "Candidates removed after semantic matching")
        }

        return excludedIDs
    }

    private func excludedImageEmbeddingPostIDs(for parsed: DorkedSearchQuery, diagnostics: SearchDiagnosticsCollector? = nil) async throws -> Set<Int> {
        guard !parsed.excludedImageEmbeddingSearchText.isEmpty else { return [] }

        var excludedIDs: Set<Int> = []
        for query in parsed.excludedImageEmbeddingSearchText {
            let startedAt = Date()
            let matches = try await searchPostsByImageVectorScored(query: query, limit: Int.max)
            for (post, _) in matches {
                excludedIDs.insert(post.id)
            }
            diagnostics?.record(method: "Excluded image embedding", query: query, posts: matches.map(\.0), duration: Date().timeIntervalSince(startedAt), detail: "Candidates removed after cross-modal image matching")
        }

        return excludedIDs
    }

    private func parseBooleanSearchExpression(_ query: String) -> BooleanSearchExpression? {
        let characters = Array(query)
        var groups: [[String]] = []
        var currentGroup: [String] = []
        var currentOperand = ""
        var index = 0
        var isInsideQuote = false
        var foundBooleanOperator = false

        func finishOperand() -> Bool {
            let operand = currentOperand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !operand.isEmpty else { return false }
            currentGroup.append(operand)
            currentOperand = ""
            return true
        }

        func finishGroup() -> Bool {
            guard finishOperand(), !currentGroup.isEmpty else { return false }
            groups.append(currentGroup)
            currentGroup = []
            return true
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                isInsideQuote.toggle()
                currentOperand.append(character)
                index += 1
                continue
            }

            if !isInsideQuote,
               index + 1 < characters.count,
               characters[index] == "&",
               characters[index + 1] == "&" {
                guard finishOperand() else { return nil }
                foundBooleanOperator = true
                index += 2
                continue
            }

            if !isInsideQuote,
               index + 1 < characters.count,
               characters[index] == "|",
               characters[index + 1] == "|" {
                guard finishGroup() else { return nil }
                foundBooleanOperator = true
                index += 2
                continue
            }

            currentOperand.append(character)
            index += 1
        }

        guard foundBooleanOperator, finishGroup() else { return nil }
        return BooleanSearchExpression(groups: groups)
    }

    private func diagnosticPlan(for query: String, mode: SearchMode) -> [String] {
        var lines = ["Mode: \(mode.rawValue)"]
        if let expression = parseBooleanSearchExpression(query) {
            lines.append("Boolean plan: \(expression.groups.count) OR group\(expression.groups.count == 1 ? "" : "s")")
            for (groupIndex, group) in expression.groups.enumerated() {
                lines.append("Group \(groupIndex + 1) (AND): \(group.joined(separator: "  &&  "))")
            }
        }

        let operands = parseBooleanSearchExpression(query)?.groups.flatMap { $0 } ?? [query]
        for (index, operand) in operands.enumerated() {
            let parsed = parseDorkedSearchQuery(operand)
            let prefix = operands.count == 1 ? "" : "Operand \(index + 1) — "
            if !parsed.searchText.isEmpty {
                lines.append("\(prefix)keyword query: \(parsed.searchText)")
            }
            if !parsed.embeddingSearchText.isEmpty {
                lines.append("\(prefix)embedding override: \(parsed.embeddingSearchText)")
            } else if mode != .keyword, !parsed.searchText.isEmpty {
                lines.append("\(prefix)embedding query: \(parsed.searchText)")
            }
            if !parsed.excludedEmbeddingSearchText.isEmpty {
                lines.append("\(prefix)excluded embeddings: \(parsed.excludedEmbeddingSearchText.joined(separator: " | "))")
            }
            if !parsed.imageEmbeddingSearchText.isEmpty {
                lines.append("\(prefix)image embedding override: \(parsed.imageEmbeddingSearchText)")
            } else if mode == .hybrid, !parsed.searchText.isEmpty {
                lines.append("\(prefix)image embedding query: \(parsed.searchText)")
            }
            if !parsed.excludedImageEmbeddingSearchText.isEmpty {
                lines.append("\(prefix)excluded image embeddings: \(parsed.excludedImageEmbeddingSearchText.joined(separator: " | "))")
            }

            var filters: [String] = []
            if parsed.matchesNullValues { filters.append("!NULL") }
            if !parsed.postIDs.isEmpty { filters.append("ids=\(parsed.postIDs.map(String.init).joined(separator: ","))") }
            if !parsed.excludedPostIDs.isEmpty { filters.append("excluded ids=\(parsed.excludedPostIDs.map(String.init).joined(separator: ","))") }
            if !parsed.usernames.isEmpty { filters.append("users=\(parsed.usernames.joined(separator: ","))") }
            if !parsed.excludedUsernames.isEmpty { filters.append("excluded users=\(parsed.excludedUsernames.joined(separator: ","))") }
            if !parsed.displayNames.isEmpty { filters.append("names=\(parsed.displayNames.joined(separator: ","))") }
            if !parsed.topics.isEmpty { filters.append("topics=\(parsed.topics.joined(separator: ","))") }
            if !parsed.primaryTopics.isEmpty { filters.append("primary topics=\(parsed.primaryTopics.joined(separator: ","))") }
            if !parsed.secondaryTopics.isEmpty { filters.append("secondary topics=\(parsed.secondaryTopics.joined(separator: ","))") }
            if !parsed.exactPhrases.isEmpty { filters.append("exact phrases=\(parsed.exactPhrases.joined(separator: " | "))") }
            if !parsed.excludedSearchTerms.isEmpty { filters.append("excluded terms=\(parsed.excludedSearchTerms.joined(separator: ","))") }
            if parsed.hasHardFilters {
                lines.append("\(prefix)filters: \(filters.isEmpty ? "field/null exclusions" : filters.joined(separator: "; "))")
            }
        }
        return lines
    }

    private func parseDorkedSearchQuery(_ query: String) -> DorkedSearchQuery {
        var searchTerms: [String] = []
        var embeddingSearchTerms: [String] = []
        var excludedEmbeddingSearchTerms: [String] = []
        var imageEmbeddingSearchTerms: [String] = []
        var excludedImageEmbeddingSearchTerms: [String] = []
        var excludedSearchTerms: [String] = []
        var matchesNullValues = false
        var nullFields: Set<NullSearchField> = []
        var excludedNullFields: Set<NullSearchField> = []
        var postIDs: [Int] = []
        var excludedPostIDs: [Int] = []
        var usernames: [String] = []
        var excludedUsernames: [String] = []
        var displayNames: [String] = []
        var excludedDisplayNames: [String] = []
        var topics: [String] = []
        var excludedTopics: [String] = []
        var primaryTopics: [String] = []
        var excludedPrimaryTopics: [String] = []
        var secondaryTopics: [String] = []
        var excludedSecondaryTopics: [String] = []
        var exactPhrases: [String] = []
        var excludedExactPhrases: [String] = []

        let characters = Array(query)
        var index = 0

        func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
        }

        func isGroupingDelimiter(_ character: Character) -> Bool {
            character == "\"" || character == "`"
        }

        func readGroupedValue(delimiter: Character) -> String {
            index += 1
            var value = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == delimiter { break }
                value.append(character)
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func readUnquotedValue() -> String {
            var value = ""
            while index < characters.count, !characters[index].isWhitespace {
                value.append(characters[index])
                index += 1
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while index < characters.count {
            skipWhitespace()
            guard index < characters.count else { break }

            let isExcluded = index + 1 < characters.count && characters[index] == "-" && characters[index + 1] == "-"
            if isExcluded {
                index += 2
                skipWhitespace()
                guard index < characters.count else { break }
            }

            if isGroupingDelimiter(characters[index]) {
                let delimiter = characters[index]
                let phrase = readGroupedValue(delimiter: characters[index])
                if !phrase.isEmpty {
                    if isExcluded {
                        if delimiter == "`" {
                            excludedSearchTerms.append(phrase)
                        } else {
                            excludedExactPhrases.append(phrase)
                        }
                    } else {
                        if delimiter == "`" {
                            searchTerms.append(phrase)
                        } else {
                            exactPhrases.append(phrase)
                        }
                    }
                }
                continue
            }

            let start = index
            var key = ""
            while index < characters.count, !characters[index].isWhitespace, characters[index] != ":" {
                key.append(characters[index])
                index += 1
            }

            if index < characters.count, characters[index] == ":" {
                index += 1
                skipWhitespace()
                let value = index < characters.count && isGroupingDelimiter(characters[index])
                    ? readGroupedValue(delimiter: characters[index])
                    : readUnquotedValue()
                if addDorkFilter(
                    key: key,
                    value: value,
                    isExcluded: isExcluded,
                    embeddingSearchTerms: &embeddingSearchTerms,
                    excludedEmbeddingSearchTerms: &excludedEmbeddingSearchTerms,
                    imageEmbeddingSearchTerms: &imageEmbeddingSearchTerms,
                    excludedImageEmbeddingSearchTerms: &excludedImageEmbeddingSearchTerms,
                    matchesNullValues: &matchesNullValues,
                    nullFields: &nullFields,
                    excludedNullFields: &excludedNullFields,
                    postIDs: &postIDs,
                    excludedPostIDs: &excludedPostIDs,
                    usernames: &usernames,
                    excludedUsernames: &excludedUsernames,
                    displayNames: &displayNames,
                    excludedDisplayNames: &excludedDisplayNames,
                    topics: &topics,
                    excludedTopics: &excludedTopics,
                    primaryTopics: &primaryTopics,
                    excludedPrimaryTopics: &excludedPrimaryTopics,
                    secondaryTopics: &secondaryTopics,
                    excludedSecondaryTopics: &excludedSecondaryTopics
                ) {
                    continue
                }
            }

            index = start
            let term = readUnquotedValue()
            if isNullSearchToken(term) {
                if isExcluded {
                    // `--!NULL` is not currently a meaningful top-level filter, so treat it as a literal term.
                    excludedSearchTerms.append(term)
                } else {
                    matchesNullValues = true
                }
            } else {
                if isExcluded {
                    excludedSearchTerms.append(term)
                } else {
                    searchTerms.append(term)
                }
            }
        }

        return DorkedSearchQuery(
            searchText: searchTerms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            embeddingSearchText: embeddingSearchTerms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            excludedEmbeddingSearchText: excludedEmbeddingSearchTerms,
            imageEmbeddingSearchText: imageEmbeddingSearchTerms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            excludedImageEmbeddingSearchText: excludedImageEmbeddingSearchTerms,
            excludedSearchTerms: excludedSearchTerms,
            matchesNullValues: matchesNullValues,
            nullFields: nullFields,
            excludedNullFields: excludedNullFields,
            postIDs: postIDs,
            excludedPostIDs: excludedPostIDs,
            usernames: usernames,
            excludedUsernames: excludedUsernames,
            displayNames: displayNames,
            excludedDisplayNames: excludedDisplayNames,
            topics: topics,
            excludedTopics: excludedTopics,
            primaryTopics: primaryTopics,
            excludedPrimaryTopics: excludedPrimaryTopics,
            secondaryTopics: secondaryTopics,
            excludedSecondaryTopics: excludedSecondaryTopics,
            exactPhrases: exactPhrases,
            excludedExactPhrases: excludedExactPhrases
        )
    }

    private func addDorkFilter(
        key: String,
        value: String,
        isExcluded: Bool,
        embeddingSearchTerms: inout [String],
        excludedEmbeddingSearchTerms: inout [String],
        imageEmbeddingSearchTerms: inout [String],
        excludedImageEmbeddingSearchTerms: inout [String],
        matchesNullValues: inout Bool,
        nullFields: inout Set<NullSearchField>,
        excludedNullFields: inout Set<NullSearchField>,
        postIDs: inout [Int],
        excludedPostIDs: inout [Int],
        usernames: inout [String],
        excludedUsernames: inout [String],
        displayNames: inout [String],
        excludedDisplayNames: inout [String],
        topics: inout [String],
        excludedTopics: inout [String],
        primaryTopics: inout [String],
        excludedPrimaryTopics: inout [String],
        secondaryTopics: inout [String],
        excludedSecondaryTopics: inout [String]
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if isEmbeddingSearchKey(key) {
            if isExcluded {
                excludedEmbeddingSearchTerms.append(trimmed)
            } else {
                embeddingSearchTerms.append(trimmed)
            }
            return true
        }

        if isImageEmbeddingSearchKey(key) {
            if isExcluded {
                excludedImageEmbeddingSearchTerms.append(trimmed)
            } else {
                imageEmbeddingSearchTerms.append(trimmed)
            }
            return true
        }

        if isNullSearchToken(trimmed), let nullField = nullSearchField(for: key) {
            if isExcluded {
                excludedNullFields.insert(nullField)
            } else {
                nullFields.insert(nullField)
            }
            return true
        }

        switch key {
        case "id", "post_id", "tweet_id":
            guard let postID = Int(trimmed) else { return false }
            if isExcluded {
                excludedPostIDs.append(postID)
            } else {
                postIDs.append(postID)
            }
        case "null":
            guard isNullSearchToken(trimmed) else { return false }
            matchesNullValues = true
        case "user", "username":
            if isExcluded {
                excludedUsernames.append(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
            } else {
                usernames.append(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
            }
        case "name", "display", "display_name":
            if isExcluded {
                excludedDisplayNames.append(trimmed)
            } else {
                displayNames.append(trimmed)
            }
        case "topic", "topics":
            if isExcluded {
                excludedTopics.append(trimmed)
            } else {
                topics.append(trimmed)
            }
        case "p_topic", "primary_topic", "primary":
            if isExcluded {
                excludedPrimaryTopics.append(trimmed)
            } else {
                primaryTopics.append(trimmed)
            }
        case "s_topic", "secondary_topic", "secondary":
            if isExcluded {
                excludedSecondaryTopics.append(trimmed)
            } else {
                secondaryTopics.append(trimmed)
            }
        default:
            return false
        }

        return true
    }

    private func isEmbeddingSearchKey(_ key: String) -> Bool {
        switch key.lowercased() {
        case "emb", "embedding":
            return true
        default:
            return false
        }
    }

    private func isImageEmbeddingSearchKey(_ key: String) -> Bool {
        switch key.lowercased() {
        case "img", "image", "img_emb", "image_embedding":
            return true
        default:
            return false
        }
    }

    private func fetchPosts(matching parsed: DorkedSearchQuery, limit: Int, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        try await connect()
        var clauses: [String] = []
        var args: [Binding?] = []

        appendDorkSQLFilters(for: parsed, clauses: &clauses, args: &args)
        appendFreeTextSQLFilters(for: parsed.searchText, excludedTerms: parsed.excludedSearchTerms, clauses: &clauses, args: &args)
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
        SELECT \(SQLitePostRowDecoder.standardProjection)
            FROM Posts
        \(whereSQL)
        ORDER BY created_at DESC, id DESC
        LIMIT \(limit);
        """

        var out: [Post] = []
        let stmt = try db.prepare(sql)
        for row in try stmt.run(args) {
            if out.count.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            out.append(postRowDecoder.decode(row).post)

            if out.count % 25 == 0 {
                try Task.checkCancellation()
                await onProgress?(out)
            }
        }

        try Task.checkCancellation()
        await onProgress?(out)
        return out
    }

    private func appendDorkSQLFilters(for parsed: DorkedSearchQuery, clauses: inout [String], args: inout [Binding?]) {
        if parsed.matchesNullValues {
            clauses.append(anyNullSQLClause())
        }

        for field in parsed.nullFields.sorted(by: { $0.rawValue < $1.rawValue }) {
            clauses.append(nullSQLClause(for: field))
        }
        for field in parsed.excludedNullFields.sorted(by: { $0.rawValue < $1.rawValue }) {
            clauses.append("NOT (\(nullSQLClause(for: field)))")
        }

        if !parsed.postIDs.isEmpty {
            clauses.append("(" + Array(repeating: "id = ?", count: parsed.postIDs.count).joined(separator: " OR ") + ")")
            args.append(contentsOf: parsed.postIDs.map { Int64($0) })
        }
        if !parsed.excludedPostIDs.isEmpty {
            clauses.append("NOT (" + Array(repeating: "id = ?", count: parsed.excludedPostIDs.count).joined(separator: " OR ") + ")")
            args.append(contentsOf: parsed.excludedPostIDs.map { Int64($0) })
        }

        if !parsed.usernames.isEmpty {
            clauses.append("(" + Array(repeating: "lower(screen_name) = ?", count: parsed.usernames.count).joined(separator: " OR ") + ")")
            args.append(contentsOf: parsed.usernames.map { $0.lowercased() })
        }
        if !parsed.excludedUsernames.isEmpty {
            clauses.append("NOT (" + Array(repeating: "lower(screen_name) = ?", count: parsed.excludedUsernames.count).joined(separator: " OR ") + ")")
            args.append(contentsOf: parsed.excludedUsernames.map { $0.lowercased() })
        }

        appendLikeGroup(column: "name", values: parsed.displayNames, clauses: &clauses, args: &args)
        appendLikeGroup(column: "name", values: parsed.excludedDisplayNames, negated: true, clauses: &clauses, args: &args)
        appendAnyTopicExactMatchGroup(values: parsed.topics, clauses: &clauses, args: &args)
        appendAnyTopicExactMatchGroup(values: parsed.excludedTopics, negated: true, clauses: &clauses, args: &args)
        appendExactMatchGroup(column: "primary_topic", values: parsed.primaryTopics, clauses: &clauses, args: &args)
        appendExactMatchGroup(column: "primary_topic", values: parsed.excludedPrimaryTopics, negated: true, clauses: &clauses, args: &args)
        appendSecondaryTopicExactMatchGroup(values: parsed.secondaryTopics, clauses: &clauses, args: &args)
        appendSecondaryTopicExactMatchGroup(values: parsed.excludedSecondaryTopics, negated: true, clauses: &clauses, args: &args)
        for phrase in parsed.exactPhrases {
            clauses.append("full_text LIKE ? ESCAPE '\\'")
            args.append("%\(escapeLikePattern(phrase))%")
        }
        for phrase in parsed.excludedExactPhrases {
            clauses.append("NOT (full_text LIKE ? ESCAPE '\\')")
            args.append("%\(escapeLikePattern(phrase))%")
        }
    }

    private func appendFreeTextSQLFilters(for searchText: String, excludedTerms: [String] = [], clauses: inout [String], args: inout [Binding?]) {
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for term in terms {
            appendFreeTextTermSQLFilter(term: term, negated: false, clauses: &clauses, args: &args)
        }
        for term in excludedTerms {
            appendFreeTextTermSQLFilter(term: term, negated: true, clauses: &clauses, args: &args)
        }
    }

    private func appendFreeTextTermSQLFilter(term: String, negated: Bool, clauses: inout [String], args: inout [Binding?]) {
        let prefix = negated ? "NOT " : ""
        clauses.append("""
        \(prefix)(
            full_text LIKE ? ESCAPE '\\' OR
            name LIKE ? ESCAPE '\\' OR
            screen_name LIKE ? ESCAPE '\\' OR
            lower(primary_topic) = ? OR
            EXISTS (
                SELECT 1
                FROM json_each(coalesce(secondary_topics, '[]'))
                WHERE lower(json_each.value) = ?
            )
        )
        """)
        let like = "%\(escapeLikePattern(term))%"
        let exact = term.lowercased()
        args.append(contentsOf: [like, like, like, exact, exact])
    }

    private func appendLikeGroup(column: String, values: [String], negated: Bool = false, clauses: inout [String], args: inout [Binding?]) {
        guard !values.isEmpty else { return }
        let group = "(" + Array(repeating: "\(column) LIKE ? ESCAPE '\\'", count: values.count).joined(separator: " OR ") + ")"
        clauses.append(negated ? "NOT \(group)" : group)
        args.append(contentsOf: values.map { "%\(escapeLikePattern($0))%" })
    }

    private func appendExactMatchGroup(column: String, values: [String], negated: Bool = false, clauses: inout [String], args: inout [Binding?]) {
        guard !values.isEmpty else { return }
        let group = "(" + Array(repeating: "lower(\(column)) = ?", count: values.count).joined(separator: " OR ") + ")"
        clauses.append(negated ? "NOT \(group)" : group)
        args.append(contentsOf: values.map { $0.lowercased() })
    }

    private func appendAnyTopicExactMatchGroup(values: [String], negated: Bool = false, clauses: inout [String], args: inout [Binding?]) {
        guard !values.isEmpty else { return }
        let group = "(" + Array(repeating: """
        (
            lower(primary_topic) = ? OR
            EXISTS (
                SELECT 1
                FROM json_each(coalesce(secondary_topics, '[]'))
                WHERE lower(json_each.value) = ?
            )
        )
        """, count: values.count).joined(separator: " OR ") + ")"
        clauses.append(negated ? "NOT \(group)" : group)
        args.append(contentsOf: values.flatMap { value -> [Binding?] in
            let exact = value.lowercased()
            return [exact, exact]
        })
    }

    private func appendSecondaryTopicExactMatchGroup(values: [String], negated: Bool = false, clauses: inout [String], args: inout [Binding?]) {
        guard !values.isEmpty else { return }
        let group = "(" + Array(repeating: """
        EXISTS (
            SELECT 1
            FROM json_each(coalesce(secondary_topics, '[]'))
            WHERE lower(json_each.value) = ?
        )
        """, count: values.count).joined(separator: " OR ") + ")"
        clauses.append(negated ? "NOT \(group)" : group)
        args.append(contentsOf: values.map { $0.lowercased() })
    }

    private func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func isNullSearchToken(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "!NULL"
    }

    private func nullSearchField(for key: String) -> NullSearchField? {
        switch key.lowercased() {
        case "full_text", "text":
            return .fullText
        case "media":
            return .media
        case "article":
            return .article
        case "quoted_post", "quote", "quoted":
            return .quotedPost
        case "primary_topic", "p_topic", "primary":
            return .primaryTopic
        case "secondary_topics", "secondary_topic", "s_topic", "secondary":
            return .secondaryTopics
        default:
            return nil
        }
    }

    private func anyNullSQLClause() -> String {
        """
        (
            \(nullSQLClause(for: .fullText)) OR
            \(nullSQLClause(for: .media)) OR
            \(nullSQLClause(for: .article)) OR
            \(nullSQLClause(for: .quotedPost)) OR
            \(nullSQLClause(for: .primaryTopic)) OR
            \(nullSQLClause(for: .secondaryTopics))
        )
        """
    }

    private func nullSQLClause(for field: NullSearchField) -> String {
        switch field {
        case .fullText:
            return "trim(full_text) = ''"
        case .media:
            return "(media IS NULL OR trim(media) = '' OR trim(media) = '[]')"
        case .article:
            return "(article IS NULL OR trim(article) = '')"
        case .quotedPost:
            return "(quoted_post IS NULL OR trim(quoted_post) = '')"
        case .primaryTopic:
            return "trim(primary_topic) = ''"
        case .secondaryTopics:
            return "(secondary_topics IS NULL OR trim(secondary_topics) = '' OR trim(secondary_topics) = '[]')"
        }
    }

    private func postMatches(_ post: Post, parsed: DorkedSearchQuery) -> Bool {
        if parsed.matchesNullValues, !postHasNullSearchMatch(post) {
            return false
        }

        if !parsed.nullFields.allSatisfy({ postHasNullSearchMatch(post, field: $0) }) {
            return false
        }
        if parsed.excludedNullFields.contains(where: { postHasNullSearchMatch(post, field: $0) }) {
            return false
        }

        if !parsed.postIDs.isEmpty, !parsed.postIDs.contains(post.id) {
            return false
        }
        if parsed.excludedPostIDs.contains(post.id) {
            return false
        }

        if !parsed.usernames.isEmpty {
            let username = post.screen_name.lowercased()
            if !parsed.usernames.contains(where: { username == $0.lowercased() }) { return false }
        }
        if !parsed.excludedUsernames.isEmpty {
            let username = post.screen_name.lowercased()
            if parsed.excludedUsernames.contains(where: { username == $0.lowercased() }) { return false }
        }

        if !parsed.displayNames.isEmpty, !parsed.displayNames.contains(where: { contains(post.name, phrase: $0) }) {
            return false
        }
        if parsed.excludedDisplayNames.contains(where: { contains(post.name, phrase: $0) }) {
            return false
        }

        if !parsed.topics.isEmpty, !parsed.topics.contains(where: { postMatchesAnyTopic(post, topic: $0) }) {
            return false
        }
        if parsed.excludedTopics.contains(where: { postMatchesAnyTopic(post, topic: $0) }) {
            return false
        }

        if !parsed.primaryTopics.isEmpty, !parsed.primaryTopics.contains(where: { exactTopicMatch(post.primary_topic, topic: $0) }) {
            return false
        }
        if parsed.excludedPrimaryTopics.contains(where: { exactTopicMatch(post.primary_topic, topic: $0) }) {
            return false
        }

        if !parsed.secondaryTopics.isEmpty,
           !parsed.secondaryTopics.contains(where: { topic in
               post.secondary_topics.contains(where: { exactTopicMatch($0, topic: topic) })
           }) {
            return false
        }
        if parsed.excludedSecondaryTopics.contains(where: { topic in
            post.secondary_topics.contains(where: { exactTopicMatch($0, topic: topic) })
        }) {
            return false
        }

        if !parsed.exactPhrases.isEmpty, !parsed.exactPhrases.allSatisfy({ contains(post.full_text, phrase: $0) }) {
            return false
        }
        if parsed.excludedExactPhrases.contains(where: { contains(post.full_text, phrase: $0) }) {
            return false
        }

        if parsed.excludedSearchTerms.contains(where: { postMatchesFreeTextTerm(post, term: $0) }) {
            return false
        }

        return true
    }

    private func postMatchesFreeTextTerm(_ post: Post, term: String) -> Bool {
        contains(post.full_text, phrase: term) ||
        contains(post.name, phrase: term) ||
        contains(post.screen_name, phrase: term) ||
        exactTopicMatch(post.primary_topic, topic: term) ||
        post.secondary_topics.contains(where: { exactTopicMatch($0, topic: term) })
    }

    private func postMatchesAnyTopic(_ post: Post, topic: String) -> Bool {
        exactTopicMatch(post.primary_topic, topic: topic) ||
        post.secondary_topics.contains(where: { exactTopicMatch($0, topic: topic) })
    }

    private func postHasNullSearchMatch(_ post: Post) -> Bool {
        NullSearchField.allCases.contains { postHasNullSearchMatch(post, field: $0) }
    }

    private func postHasNullSearchMatch(_ post: Post, field: NullSearchField) -> Bool {
        switch field {
        case .fullText:
            return post.full_text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .media:
            return post.media?.isEmpty ?? true
        case .article:
            return post.article == nil
        case .quotedPost:
            return post.quoted_post == nil
        case .primaryTopic:
            return post.primary_topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .secondaryTopics:
            return post.secondary_topics.isEmpty
        }
    }

    private func contains(_ text: String, phrase: String) -> Bool {
        text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func exactTopicMatch(_ lhs: String, topic rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    func fetchRawPostDebugRow(postID: Int) async throws -> SearchDebugExplanation {
        try await connect()
        let columns = try db.prepare("PRAGMA table_info(Posts);").map { row in
            row[1] as? String ?? ""
        }.filter { !$0.isEmpty }

        guard !columns.isEmpty else {
            return SearchDebugExplanation(title: "SQLite Row", body: "No table metadata found for Posts.")
        }

        let sql = "SELECT * FROM Posts WHERE id = ? LIMIT 1;"
        let stmt = try db.prepare(sql)
        guard let row = try stmt.run(Int64(postID)).makeIterator().next() else {
            return SearchDebugExplanation(title: "SQLite Row", body: "No row found for post ID \(postID).")
        }

        var lines: [String] = []
        lines.append("Posts.id = \(postID)")
        lines.append("")
        for (index, column) in columns.enumerated() where index < row.count {
            lines.append("\(column): \(debugString(for: row[index]))")
        }

        return SearchDebugExplanation(title: "SQLite Row", body: lines.joined(separator: "\n"))
    }

    func explainWhySimilarImageSearchResultContains(postID: Int, referenceMedia: Media) async throws -> SearchDebugExplanation {
        let matches = try await searchPostsBySimilarImageScored(media: referenceMedia, limit: Int.max)
        let matchIndex = matches.firstIndex(where: { $0.post.id == postID })

        var lines: [String] = []
        lines.append("Mode: similar image")
        lines.append("Reference image: \(referenceMedia.original.absoluteString)")
        lines.append("Image embedding model: \(EmbeddingsManager.imageEmbeddingModelVersion)")
        lines.append("Minimum similarity: \(formatDebugDouble(minimumImageEmbeddingSimilarity))")

        if let matchIndex {
            let match = matches[matchIndex]
            lines.append("Final rank: \(matchIndex + 1) of \(matches.count)")
            lines.append("")
            lines.append("Best image match")
            lines.append("- post image: \(match.matchingMediaURL)")
            lines.append("- cosine similarity: \(formatDebugDouble(match.similarity))")
            lines.append("- aggregation: strongest qualifying image")
            lines.append("- tie-breaker: post ID descending")
        } else {
            lines.append("Final rank: post is not present in the current result set")
            lines.append("")
            lines.append("No stored image for this post met the active similarity threshold.")
        }

        return SearchDebugExplanation(
            title: "Debug Similar Image Ranking",
            body: lines.joined(separator: "\n")
        )
    }

    func explainWhySearchResultContains(postID: Int, query: String, mode: SearchMode) async throws -> SearchDebugExplanation {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseDorkedSearchQuery(trimmedQuery)
        let searchText = parsed.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddingSearchText = parsed.embeddingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageEmbeddingSearchText = parsed.imageEmbeddingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            return SearchDebugExplanation(title: "Debug Search Ranking", body: "No active search query.")
        }

        let finalResults = try await searchPosts(query: trimmedQuery, mode: mode, limit: Int.max)
        let finalRank = finalResults.firstIndex(where: { $0.id == postID }).map { $0 + 1 }
        let finalPost = finalResults.first(where: { $0.id == postID })

        var lines: [String] = []
        lines.append("Mode: \(mode.rawValue)")
        lines.append("Query: \(trimmedQuery)")
        if !searchText.isEmpty, searchText != trimmedQuery {
            lines.append("Semantic/text portion: \(searchText)")
        }
        if !embeddingSearchText.isEmpty {
            lines.append("Embedding query: \(embeddingSearchText)")
        }
        if !parsed.excludedEmbeddingSearchText.isEmpty {
            lines.append("Excluded embedding queries: \(parsed.excludedEmbeddingSearchText.joined(separator: " | "))")
        }
        if !imageEmbeddingSearchText.isEmpty {
            lines.append("Image embedding query: \(imageEmbeddingSearchText)")
        }
        if !parsed.excludedImageEmbeddingSearchText.isEmpty {
            lines.append("Excluded image embedding queries: \(parsed.excludedImageEmbeddingSearchText.joined(separator: " | "))")
        }
        if let finalRank {
            lines.append("Final rank: \(finalRank) of \(finalResults.count)")
        } else {
            lines.append("Final rank: post is not present in the current result set")
        }

        if parsed.hasHardFilters {
            lines.append("")
            lines.append("Hard filters:")
            if parsed.matchesNullValues { lines.append("- NULL: matches posts with at least one empty or missing field") }
            if !parsed.nullFields.isEmpty { lines.append("- field !NULL: \(parsed.nullFields.map(\.rawValue).sorted().joined(separator: ", "))") }
            if !parsed.excludedNullFields.isEmpty { lines.append("- excluded null fields: \(parsed.excludedNullFields.map(\.rawValue).sorted().joined(separator: ", "))") }
            if !parsed.postIDs.isEmpty { lines.append("- id: \(parsed.postIDs.map(String.init).joined(separator: ", "))") }
            if !parsed.excludedPostIDs.isEmpty { lines.append("- excluded id: \(parsed.excludedPostIDs.map(String.init).joined(separator: ", "))") }
            if !parsed.usernames.isEmpty { lines.append("- user: \(parsed.usernames.joined(separator: ", "))") }
            if !parsed.excludedUsernames.isEmpty { lines.append("- excluded user: \(parsed.excludedUsernames.joined(separator: ", "))") }
            if !parsed.displayNames.isEmpty { lines.append("- name: \(parsed.displayNames.joined(separator: ", "))") }
            if !parsed.excludedDisplayNames.isEmpty { lines.append("- excluded name: \(parsed.excludedDisplayNames.joined(separator: ", "))") }
            if !parsed.topics.isEmpty { lines.append("- topic: \(parsed.topics.joined(separator: ", "))") }
            if !parsed.excludedTopics.isEmpty { lines.append("- excluded topic: \(parsed.excludedTopics.joined(separator: ", "))") }
            if !parsed.primaryTopics.isEmpty { lines.append("- p_topic: \(parsed.primaryTopics.joined(separator: ", "))") }
            if !parsed.excludedPrimaryTopics.isEmpty { lines.append("- excluded p_topic: \(parsed.excludedPrimaryTopics.joined(separator: ", "))") }
            if !parsed.secondaryTopics.isEmpty { lines.append("- s_topic: \(parsed.secondaryTopics.joined(separator: ", "))") }
            if !parsed.excludedSecondaryTopics.isEmpty { lines.append("- excluded s_topic: \(parsed.excludedSecondaryTopics.joined(separator: ", "))") }
            if !parsed.exactPhrases.isEmpty { lines.append("- exact phrases: \(parsed.exactPhrases.joined(separator: " | "))") }
            if !parsed.excludedExactPhrases.isEmpty { lines.append("- excluded exact phrases: \(parsed.excludedExactPhrases.joined(separator: " | "))") }
            if !parsed.excludedSearchTerms.isEmpty { lines.append("- excluded terms: \(parsed.excludedSearchTerms.joined(separator: ", "))") }
            if !parsed.embeddingSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("- embedding query override: \(parsed.embeddingSearchText)") }
            if !parsed.excludedEmbeddingSearchText.isEmpty { lines.append("- excluded embedding queries: \(parsed.excludedEmbeddingSearchText.joined(separator: " | "))") }
            if !parsed.imageEmbeddingSearchText.isEmpty { lines.append("- image embedding query override: \(parsed.imageEmbeddingSearchText)") }
            if !parsed.excludedImageEmbeddingSearchText.isEmpty { lines.append("- excluded image embedding queries: \(parsed.excludedImageEmbeddingSearchText.joined(separator: " | "))") }
            if let finalPost {
                lines.append("- matched all hard filters: \(postMatches(finalPost, parsed: parsed) ? "yes" : "no")")
            }
        }

        if !parsed.hasAnySearchText {
            lines.append("")
            lines.append("This result is here because it matches the hard SQL filters; there is no free-text ranking component in this query.")
            return SearchDebugExplanation(title: "Debug Search Ranking", body: lines.joined(separator: "\n"))
        }

        lines.append("")
        switch mode {
        case .keyword:
            let keywordResults = try await searchPosts(query: searchText, limit: Int.max)
            appendKeywordExplanation(lines: &lines, postID: postID, results: keywordResults, query: searchText)
        case .embedding:
            if !imageEmbeddingSearchText.isEmpty {
                let imageEmbeddingResults = try await searchPostsByImageVectorScored(query: imageEmbeddingSearchText, limit: Int.max, minimumSimilarity: parsed.hasHardFilters ? -1.0 : nil)
                appendImageEmbeddingExplanation(lines: &lines, postID: postID, scored: imageEmbeddingResults)
            } else {
                let embeddingQuery = embeddingSearchText.isEmpty ? searchText : embeddingSearchText
                let embeddingResults = try await searchPostsByVectorScored(query: embeddingQuery, limit: Int.max, minimumSimilarity: parsed.hasHardFilters ? -1.0 : nil)
                appendEmbeddingExplanation(lines: &lines, postID: postID, scored: embeddingResults)
            }
        case .hybrid:
            let componentLimit = Int.max
            let keywordResults = try await searchPosts(query: searchText, limit: componentLimit)
            let topicResults = try await searchPostsByTopics(query: searchText, limit: componentLimit)
            let embeddingQuery = embeddingSearchText.isEmpty ? searchText : embeddingSearchText
            let embeddingResults = try await searchPostsByVectorScored(query: embeddingQuery, limit: componentLimit, minimumSimilarity: parsed.hasHardFilters ? -1.0 : nil)
            let imageEmbeddingQuery = imageEmbeddingSearchText.isEmpty ? searchText : imageEmbeddingSearchText
            let imageEmbeddingResults = try await searchPostsByImageVectorScored(query: imageEmbeddingQuery, limit: componentLimit, minimumSimilarity: parsed.hasHardFilters ? -1.0 : nil)
            let queryTerms = hybridQueryTerms(from: searchText)
            appendKeywordExplanation(lines: &lines, postID: postID, results: keywordResults, query: searchText)
            lines.append("")
            appendTopicExplanation(lines: &lines, postID: postID, results: topicResults, query: searchText)
            lines.append("")
            appendEmbeddingExplanation(lines: &lines, postID: postID, scored: embeddingResults)
            lines.append("")
            appendImageEmbeddingExplanation(lines: &lines, postID: postID, scored: imageEmbeddingResults)
            lines.append("")
            appendHybridExplanation(lines: &lines, post: finalPost, postID: postID, queryTerms: queryTerms, embeddingResults: embeddingResults, imageEmbeddingResults: imageEmbeddingResults)
        }

        return SearchDebugExplanation(title: "Debug Search Ranking", body: lines.joined(separator: "\n"))
    }

    // MARK: - Keyword / Topic search (FTS5 + LIKE fallback)

    func searchPosts(query: String, limit: Int = 100, diagnostics: SearchDiagnosticsCollector? = nil, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        try await connect()
        let startedAt = Date()

        // Prefer FTS5
        var results: [Int] = []
        do {
            let ftsSQL = """
            SELECT rowid FROM posts_fts WHERE posts_fts MATCH ?
            ORDER BY bm25(posts_fts) ASC
            LIMIT \(limit);
            """
            let stmt = try db.prepare(ftsSQL)
            for row in try stmt.run(trimmed) {
                if results.count.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                results.append(Int(row[0] as! Int64))
            }
        }
        let ftsResultCount = results.count
        var backend = "FTS5"
        // Fallback to LIKE if FTS returned nothing
        if results.isEmpty {
            backend = "LIKE fallback"
            let like = "%\(trimmed)%"
            let altSQL = """
            SELECT id FROM Posts
            WHERE full_text LIKE ?
               OR lower(primary_topic) = ?
               OR EXISTS (
                    SELECT 1
                    FROM json_each(coalesce(secondary_topics, '[]'))
                    WHERE lower(json_each.value) = ?
               )
            ORDER BY created_at DESC, id DESC
            LIMIT \(limit);
            """
            let stmt = try db.prepare(altSQL)
            let exact = trimmed.lowercased()
            for row in try stmt.run(like, exact, exact) {
                if results.count.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                results.append(Int(row[0] as! Int64))
            }
        }

        guard !results.isEmpty else { return [] }
        let idsList = results.map(String.init).joined(separator: ",")
        let fetchSQL = """
        SELECT \(SQLitePostRowDecoder.standardProjection)
        FROM Posts WHERE id IN (\(idsList));
        """
        var postsById: [Int: Post] = [:]
        for row in try db.prepare(fetchSQL) {
            if postsById.count.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let post = postRowDecoder.decode(row).post
            postsById[post.id] = post
        }
        var finalResults: [Post] = []
        finalResults.reserveCapacity(results.count)
        for id in results {
            if finalResults.count.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard let post = postsById[id] else { continue }
            finalResults.append(post)
            if finalResults.count % 25 == 0 {
                await onProgress?(finalResults)
            }
        }
        try Task.checkCancellation()
        await onProgress?(finalResults)
        diagnostics?.record(
            method: backend,
            query: trimmed,
            posts: finalResults,
            duration: Date().timeIntervalSince(startedAt),
            detail: backend == "FTS5" ? "Ranked with bm25(posts_fts)" : "FTS5 returned \(ftsResultCount); searched post text and exact topics"
        )
        
        // Log all results with full text (keyword search doesn't have similarity scores)
        logSearchResults(finalResults.map { ($0, 1.0) }, query: trimmed, searchType: "Keyword")
        
        return finalResults
    }

    func searchPostsByTopics(query: String, limit: Int = 100, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        try await connect()
        let sql = """
        SELECT \(SQLitePostRowDecoder.standardProjection)
            FROM Posts
        WHERE lower(primary_topic) = ?
           OR EXISTS (
                SELECT 1
                FROM json_each(coalesce(secondary_topics, '[]'))
                WHERE lower(json_each.value) = ?
           )
        ORDER BY created_at DESC, id DESC
        LIMIT \(limit);
        """
        var out: [Post] = []
        let stmt = try db.prepare(sql)
        let exact = trimmed.lowercased()
        for row in try stmt.run(exact, exact) {
            if out.count.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            out.append(postRowDecoder.decode(row).post)

            if out.count % 25 == 0 {
                try Task.checkCancellation()
                await onProgress?(out)
            }
        }
        try Task.checkCancellation()
        await onProgress?(out)
        
        // Log all results with full text (topic search doesn't have similarity scores)
        logSearchResults(out.map { ($0, 1.0) }, query: trimmed, searchType: "Topic")
        
        return out
    }

    func searchPostsHybridWeighted(query: String, keywordQuery: String? = nil, imageQuery: String? = nil, limit: Int = 500, minimumEmbeddingSimilarity: Double? = nil, minimumImageEmbeddingSimilarity: Double? = nil, diagnostics: SearchDiagnosticsCollector? = nil, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        try Task.checkCancellation()
        let embeddingQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywordQueryTrimmed = (keywordQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        let imageEmbeddingQuery = (imageQuery ?? keywordQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!embeddingQuery.isEmpty || !keywordQueryTrimmed.isEmpty || !imageEmbeddingQuery.isEmpty), limit > 0 else { return [] }

        let queryTerms = hybridQueryTerms(from: keywordQueryTrimmed)
        var termScores: [Int: Double] = [:]
        var embeddingScores: [Int: Double] = [:]
        var imageEmbeddingScores: [Int: Double] = [:]
        var allPosts: [Int: Post] = [:]

        func totalScore(for postID: Int, using terms: [Int: Double], embeddings: [Int: Double], imageEmbeddings: [Int: Double]) -> Double {
            (terms[postID] ?? 0) + (embeddings[postID] ?? 0) + (imageEmbeddings[postID] ?? 0)
        }

        func sortPostIDs(using terms: [Int: Double], embeddings: [Int: Double], imageEmbeddings: [Int: Double], posts: [Int: Post]) -> [Int] {
            posts.keys.sorted { lhs, rhs in
                let leftScore = totalScore(for: lhs, using: terms, embeddings: embeddings, imageEmbeddings: imageEmbeddings)
                let rightScore = totalScore(for: rhs, using: terms, embeddings: embeddings, imageEmbeddings: imageEmbeddings)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }

                guard let leftPost = posts[lhs], let rightPost = posts[rhs] else {
                    return lhs > rhs
                }

                if leftPost.created_at != rightPost.created_at {
                    return leftPost.created_at > rightPost.created_at
                }

                return lhs > rhs
            }
        }

        func sortedResults(using terms: [Int: Double], embeddings: [Int: Double], imageEmbeddings: [Int: Double], posts: [Int: Post]) -> [Post] {
            let sortedIDs = sortPostIDs(using: terms, embeddings: embeddings, imageEmbeddings: imageEmbeddings, posts: posts)
            let cappedIDs = limit == Int.max ? sortedIDs : Array(sortedIDs.prefix(limit))
            return cappedIDs.compactMap { posts[$0] }
        }

        if !queryTerms.isEmpty {
            let termStartedAt = Date()
            let termMatchedPosts = try await searchPostsByAllHybridTerms(queryTerms: queryTerms, limit: Int.max)
            try Task.checkCancellation()
            for post in termMatchedPosts {
                let score = hybridTermAndTopicScore(for: post, queryTerms: queryTerms)
                guard score > 0 else { continue }
                termScores[post.id] = score
                allPosts[post.id] = post
            }
            diagnostics?.record(method: "Hybrid terms/topics", query: queryTerms.joined(separator: " + "), posts: termMatchedPosts, duration: Date().timeIntervalSince(termStartedAt), detail: "Lexical candidates must match every query term; additive exact term and topic scoring")
        }
        try Task.checkCancellation()
        await onProgress?(sortedResults(using: termScores, embeddings: embeddingScores, imageEmbeddings: imageEmbeddingScores, posts: allPosts))

        let embeddingsScored: [(Post, Double)]
        if embeddingQuery.isEmpty {
            embeddingsScored = []
        } else {
            let embeddingLimit = limit == Int.max ? Int.max : max(limit * 2, 1000)
            embeddingsScored = try await searchPostsByVectorScored(query: embeddingQuery, limit: embeddingLimit, minimumSimilarity: minimumEmbeddingSimilarity, diagnostics: diagnostics) { scoredPosts in
                if Task.isCancelled { return }
                var progressEmbeddings = embeddingScores
                var progressPosts = allPosts

                for (post, similarity) in scoredPosts {
                    progressEmbeddings[post.id] = max(0.0, min(1.0, similarity))
                    progressPosts[post.id] = post
                }

                await onProgress?(sortedResults(using: termScores, embeddings: progressEmbeddings, imageEmbeddings: imageEmbeddingScores, posts: progressPosts))
            }
        }

        try Task.checkCancellation()
        for (post, similarity) in embeddingsScored {
            embeddingScores[post.id] = max(0.0, min(1.0, similarity))
            allPosts[post.id] = post
        }

        let imagesScored: [(Post, Double)]
        if imageEmbeddingQuery.isEmpty {
            imagesScored = []
        } else {
            let imageLimit = limit == Int.max ? Int.max : max(limit * 2, 1000)
            imagesScored = try await searchPostsByImageVectorScored(
                query: imageEmbeddingQuery,
                limit: imageLimit,
                minimumSimilarity: minimumImageEmbeddingSimilarity,
                diagnostics: diagnostics
            ) { scoredPosts in
                if Task.isCancelled { return }
                var progressImageEmbeddings = imageEmbeddingScores
                var progressPosts = allPosts

                for (post, similarity) in scoredPosts {
                    progressImageEmbeddings[post.id] = max(0.0, similarity)
                    progressPosts[post.id] = post
                }

                await onProgress?(sortedResults(using: termScores, embeddings: embeddingScores, imageEmbeddings: progressImageEmbeddings, posts: progressPosts))
            }
        }

        try Task.checkCancellation()
        for (post, similarity) in imagesScored {
            imageEmbeddingScores[post.id] = max(0.0, similarity)
            allPosts[post.id] = post
        }
        try Task.checkCancellation()
        await onProgress?(sortedResults(using: termScores, embeddings: embeddingScores, imageEmbeddings: imageEmbeddingScores, posts: allPosts))

        try Task.checkCancellation()
        let sortedIDs = sortPostIDs(using: termScores, embeddings: embeddingScores, imageEmbeddings: imageEmbeddingScores, posts: allPosts)
        let cappedIDs = limit == Int.max ? sortedIDs : Array(sortedIDs.prefix(limit))
        let finalResults = cappedIDs.compactMap { allPosts[$0] }

        print("[HybridSearch] Combined \(termScores.count) term/topic-scored + \(embeddingsScored.count) text-embedding-scored + \(imagesScored.count) image-embedding-scored results")
        print("[HybridSearch] Final result count: \(finalResults.count)")
        if let bestID = sortedIDs.first {
            let bestScore = totalScore(for: bestID, using: termScores, embeddings: embeddingScores, imageEmbeddings: imageEmbeddingScores)
            print("[HybridSearch] Best combined score: \(String(format: "%.3f", bestScore))")
        }

        let finalResultsWithScores = finalResults.map { post in
            (post, totalScore(for: post.id, using: termScores, embeddings: embeddingScores, imageEmbeddings: imageEmbeddingScores))
        }
        logSearchResults(finalResultsWithScores, query: embeddingQuery.isEmpty ? keywordQueryTrimmed : embeddingQuery, searchType: "Hybrid")

        return finalResults
    }

    private func hybridQueryTerms(from query: String) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []

        for rawTerm in query.split(whereSeparator: \.isWhitespace) {
            let normalized = rawTerm
                .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
                .lowercased()

            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            terms.append(normalized)
        }

        return terms
    }

    private func searchPostsByAllHybridTerms(queryTerms: [String], limit: Int, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        guard !queryTerms.isEmpty, limit > 0 else {
            await onProgress?([])
            return []
        }

        try await connect()

        var clauses: [String] = []
        var args: [Binding?] = []

        for term in queryTerms {
            let like = "%\(escapeLikePattern(term))%"
            clauses.append("""
            (
                full_text LIKE ? ESCAPE '\\' OR
                lower(primary_topic) = ? OR
                EXISTS (
                    SELECT 1
                    FROM json_each(coalesce(secondary_topics, '[]'))
                    WHERE lower(json_each.value) = ?
                )
            )
            """)
            args.append(contentsOf: [like, term, term])
        }

        let sql = """
        SELECT \(SQLitePostRowDecoder.standardProjection)
            FROM Posts
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY created_at DESC, id DESC
        LIMIT \(limit);
        """

        var out: [Post] = []
        let stmt = try db.prepare(sql)
        for row in try stmt.run(args) {
            if out.count.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            out.append(postRowDecoder.decode(row).post)

            if out.count % 25 == 0 {
                try Task.checkCancellation()
                await onProgress?(out)
            }
        }

        try Task.checkCancellation()
        await onProgress?(out)
        return out
    }

    private func hybridTermAndTopicScore(for post: Post, queryTerms: [String]) -> Double {
        guard !queryTerms.isEmpty else { return 0 }

        let fullText = post.full_text.lowercased()
        let primaryTopic = post.primary_topic.lowercased()
        let secondaryTopics = post.secondary_topics.map { $0.lowercased() }

        var score = 0.0
        var matchedUniqueTerms = 0
        for term in queryTerms {
            let textOccurrences = countOccurrences(of: term, in: fullText)
            let primaryTopicMatches = primaryTopic == term
            let matchingSecondaryTopics = secondaryTopics.filter { $0 == term }.count

            score += fullTextOccurrenceScore(for: textOccurrences)

            if primaryTopicMatches {
                score += 0.85
            }

            score += 0.7 * Double(matchingSecondaryTopics)

            if textOccurrences > 0 || primaryTopicMatches || matchingSecondaryTopics > 0 {
                matchedUniqueTerms += 1
            }
        }

        score += 0.8 * (Double(matchedUniqueTerms) / Double(queryTerms.count))

        return score
    }

    private func fullTextOccurrenceScore(for occurrences: Int) -> Double {
        guard occurrences > 0 else { return 0 }
        return log2((0.5 * Double(occurrences)) + 0.5) + 0.5
    }

    private func countOccurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty, !text.isEmpty else { return 0 }

        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = "(?<![[:alnum:]_])\(escaped)(?![[:alnum:]_])"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    // MARK: - Vector search (CPU-based for maximum accuracy)

    /// Reuses the selected media's current stored vector when available, otherwise
    /// embeds it with Qwen3-VL. Ranks each post by its strongest qualifying image.
    func searchPostsBySimilarImage(media: Media, limit: Int = Int.max) async throws -> [Post] {
        try await searchPostsBySimilarImageScored(media: media, limit: limit).map(\.post)
    }

    private func searchPostsBySimilarImageScored(media: Media, limit: Int) async throws -> [SimilarImageSearchMatch] {
        guard limit > 0 else { return [] }
        try await connect()

        let queryEmbedding: [Float]
        if let storedEmbedding = try storedImageEmbedding(for: media) {
            queryEmbedding = storedEmbedding
            print("[ImageSearch] Reusing stored query embedding for '\(media.original.absoluteString)'")
        } else {
            guard let generatedEmbedding = await EmbeddingsManager.embedImage(from: media) else {
                return []
            }
            queryEmbedding = generatedEmbedding
        }

        let query = l2NormalizeVec(queryEmbedding)
        let threshold = minimumImageEmbeddingSimilarity
        var bestMatchByPostID: [Int: (similarity: Double, mediaURL: String)] = [:]
        var scannedImages = 0
        var skippedImages = 0
        let rows = try db.prepare("""
            SELECT post_id, media_url, embedding
            FROM ImageEmbeddings
            WHERE model_version = ?;
            """)

        for row in try rows.run(EmbeddingsManager.imageEmbeddingModelVersion) {
            guard let postIDValue = row[0] as? Int64,
                  let mediaURL = row[1] as? String,
                  let blob = row[2] as? Blob else {
                skippedImages += 1
                continue
            }
            let stored = dataToFloats(Data(blob.bytes))
            guard stored.count == query.count,
                  !stored.contains(where: { $0.isNaN || $0.isInfinite }),
                  vectorMagnitude(stored) > 1e-12 else {
                skippedImages += 1
                continue
            }

            scannedImages += 1
            let similarity = dot(query, l2NormalizeVec(stored))
            guard similarity >= threshold else { continue }
            let postID = Int(postIDValue)
            if similarity > (bestMatchByPostID[postID]?.similarity ?? -.infinity) {
                bestMatchByPostID[postID] = (similarity, mediaURL)
            }
        }

        let matches = bestMatchByPostID
            .map { VectorMatch(id: $0.key, similarity: $0.value.similarity) }
            .sorted {
                if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
                return $0.id > $1.id
            }
        let limited = limit == Int.max ? matches : Array(matches.prefix(limit))
        let results = try fetchPostsByIDsPreservingOrder(limited).compactMap { result -> SimilarImageSearchMatch? in
            let (post, similarity) = result
            guard let matchingMediaURL = bestMatchByPostID[post.id]?.mediaURL else { return nil }
            return SimilarImageSearchMatch(
                post: post,
                similarity: similarity,
                matchingMediaURL: matchingMediaURL
            )
        }
        print("[ImageSearch] query='\(media.original.absoluteString)' scanned_images=\(scannedImages) skipped_images=\(skippedImages) matched_posts=\(results.count) threshold=\(String(format: "%.3f", threshold)) aggregation=best")
        return results
    }

    private func storedImageEmbedding(for media: Media) throws -> [Float]? {
        let statement = try db.prepare("""
            SELECT embedding
            FROM ImageEmbeddings
            WHERE model_version = ? AND media_url = ?
            LIMIT 1;
            """)

        guard let row = try statement.run(
            EmbeddingsManager.imageEmbeddingModelVersion,
            media.original.absoluteString
        ).makeIterator().next(), let blob = row[0] as? Blob else {
            return nil
        }

        let embedding = dataToFloats(Data(blob.bytes))
        guard embedding.count == EmbeddingsManager.imageTargetDimension,
              !embedding.contains(where: { $0.isNaN || $0.isInfinite }),
              vectorMagnitude(embedding) > 1e-12 else {
            print("[ImageSearch] Ignoring invalid stored query embedding for '\(media.original.absoluteString)'")
            return nil
        }
        return embedding
    }

    func searchPostsByImageVector(query: String, limit: Int = 100, minimumSimilarity: Double? = nil, diagnostics: SearchDiagnosticsCollector? = nil, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        let scored = try await searchPostsByImageVectorScored(
            query: query,
            limit: limit,
            minimumSimilarity: minimumSimilarity,
            diagnostics: diagnostics
        ) { scoredPosts in
            await onProgress?(scoredPosts.map(\.0))
        }
        return scored.map(\.0)
    }

    /// Embeds text with Qwen3-VL's text tower and compares it against every
    /// stored per-image vector. A post receives the similarity of its strongest
    /// image that meets the threshold.
    func searchPostsByImageVectorScored(query: String, limit: Int = 100, minimumSimilarity: Double? = nil, diagnostics: SearchDiagnosticsCollector? = nil, onProgress: (([(Post, Double)]) async -> Void)? = nil) async throws -> [(Post, Double)] {
        let preprocessed = preprocessQueryForEmbedding(query)
        guard !preprocessed.isEmpty, limit > 0 else { return [] }
        let startedAt = Date()
        try await connect()
        try Task.checkCancellation()

        guard let queryEmbedding = await EmbeddingsManager.embedImageQuery(text: preprocessed) else {
            diagnostics?.record(method: "Image embedding", query: preprocessed, posts: [], duration: Date().timeIntervalSince(startedAt), detail: "Image-model query embedding generation failed")
            return []
        }
        try Task.checkCancellation()

        let threshold = minimumSimilarity ?? minimumImageEmbeddingSimilarity
        let queryVector = l2NormalizeVec(queryEmbedding)
        var bestSimilarityByPostID: [Int: Double] = [:]
        var scannedImages = 0
        var skippedImages = 0
        var processedImages = 0
        var qualifyingImageCount = 0
        var lastPublishedQualifyingImageCount = 0
        var lastPublishedAt = Date.distantPast
        let rows = try db.prepare("""
            SELECT post_id, embedding
            FROM ImageEmbeddings
            WHERE model_version = ?;
            """)

        for row in try rows.run(EmbeddingsManager.imageEmbeddingModelVersion) {
            processedImages += 1
            if processedImages % 500 == 0 {
                try Task.checkCancellation()
            }
            guard let postIDValue = row[0] as? Int64,
                  let blob = row[1] as? Blob else {
                skippedImages += 1
                continue
            }

            let stored = dataToFloats(Data(blob.bytes))
            guard stored.count == queryVector.count,
                  !stored.contains(where: { $0.isNaN || $0.isInfinite }),
                  vectorMagnitude(stored) > 1e-12 else {
                skippedImages += 1
                continue
            }

            scannedImages += 1
            let similarity = dot(queryVector, l2NormalizeVec(stored))
            guard similarity >= threshold else { continue }
            qualifyingImageCount += 1
            let postID = Int(postIDValue)
            bestSimilarityByPostID[postID] = max(bestSimilarityByPostID[postID] ?? -.infinity, similarity)

            let hasInitialProgressBatch = lastPublishedQualifyingImageCount == 0 && qualifyingImageCount >= 25
            let hasAnotherProgressBatch = qualifyingImageCount - lastPublishedQualifyingImageCount >= 100 && Date().timeIntervalSince(lastPublishedAt) >= 0.15
            if hasInitialProgressBatch || hasAnotherProgressBatch {
                let progressMatches = rankedVectorMatches(bestSimilarityByPostID, limit: limit)
                let progressResults = try fetchPostsByIDsPreservingOrder(progressMatches)
                lastPublishedQualifyingImageCount = qualifyingImageCount
                await onProgress?(progressResults)
                lastPublishedAt = Date()
            }
        }

        let matches = rankedVectorMatches(bestSimilarityByPostID, limit: limit)
        let results = try fetchPostsByIDsPreservingOrder(matches)
        await onProgress?(results)
        diagnostics?.record(
            method: "Image embedding",
            query: preprocessed,
            posts: results.map(\.0),
            duration: Date().timeIntervalSince(startedAt),
            detail: "Scanned \(scannedImages) image vectors; \(qualifyingImageCount) qualifying images across \(bestSimilarityByPostID.count) posts at cross-modal cosine threshold \(String(format: "%.3f", threshold)); ranked by strongest qualifying image; skipped \(skippedImages) invalid vectors"
        )
        print("[ImageVectorSearch] query='\(preprocessed)' scanned_images=\(scannedImages) skipped_images=\(skippedImages) qualifying_images=\(qualifyingImageCount) matched_posts=\(bestSimilarityByPostID.count) returned=\(results.count) threshold=\(String(format: "%.3f", threshold)) aggregation=best")
        return results
    }

    private func rankedVectorMatches(_ similaritiesByPostID: [Int: Double], limit: Int) -> [VectorMatch] {
        let matches = similaritiesByPostID
            .map { VectorMatch(id: $0.key, similarity: $0.value) }
            .sorted {
                if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
                return $0.id > $1.id
            }
        return limit == Int.max ? matches : Array(matches.prefix(limit))
    }

    func searchPostsByVector(query: String, limit: Int = 100, minimumSimilarity: Double? = nil, diagnostics: SearchDiagnosticsCollector? = nil, onProgress: (([Post]) async -> Void)? = nil) async throws -> [Post] {
        // Delegate to scored search and drop scores to keep API compatible
        // Results are already ordered by similarity descending (most similar first)
        let scored = try await searchPostsByVectorScored(query: query, limit: limit, minimumSimilarity: minimumSimilarity, diagnostics: diagnostics) { scoredPosts in
            await onProgress?(scoredPosts.map { $0.0 })
        }
        return scored.map { $0.0 }
    }

    /// High-accuracy CPU-based embedding search that returns (post, similarity) and sorts by similarity descending.
    /// Uses cosine similarity for optimal semantic matching accuracy.
    /// minimumSimilarity: Minimum cosine similarity required for a post to be included.
    func searchPostsByVectorScored(query: String, limit: Int = 100, minimumSimilarity: Double? = nil, diagnostics: SearchDiagnosticsCollector? = nil, onProgress: (([(Post, Double)]) async -> Void)? = nil) async throws -> [(Post, Double)] {
        let preprocessed = preprocessQueryForEmbedding(query)
        guard !preprocessed.isEmpty, limit > 0 else { return [] }
        let startedAt = Date()
        try await connect()
        try Task.checkCancellation()
        guard let qVec = await EmbeddingsManager.embed(text: preprocessed) else {
            diagnostics?.record(method: "Embedding", query: preprocessed, posts: [], duration: Date().timeIntervalSince(startedAt), detail: "Query embedding generation failed")
            return []
        }
        try Task.checkCancellation()

        let similarityThreshold = minimumSimilarity ?? minimumEmbeddingSimilarity
        let qNorm = l2NormalizeVec(qVec)
        let index = try ensureTextEmbeddingIndex()
        guard !index.ids.isEmpty, index.dimension > 0 else {
            await onProgress?([])
            diagnostics?.record(method: "Embedding", query: preprocessed, posts: [], duration: Date().timeIntervalSince(startedAt), detail: "No stored text embeddings; threshold \(String(format: "%.3f", similarityThreshold))")
            print("[VectorSearch] query='\(preprocessed)' scanned=0 matched=0 returned=0 threshold=\(String(format: "%.3f", similarityThreshold))")
            return []
        }

        guard qNorm.count == index.dimension else {
            print("[VectorSearch] Query embedding dimension \(qNorm.count) does not match index dimension \(index.dimension)")
            await onProgress?([])
            diagnostics?.record(method: "Embedding", query: preprocessed, posts: [], duration: Date().timeIntervalSince(startedAt), detail: "Dimension mismatch: query \(qNorm.count), index \(index.dimension)")
            return []
        }

        var scannedCount = 0
        var matchedCount = 0
        var lastPublishedScanCount = 0
        var allMatches: [VectorMatch] = []
        var topK = TopKMatches(limit: limit == Int.max ? 0 : limit)
        let needsFullRanking = limit == Int.max

        if needsFullRanking {
            allMatches.reserveCapacity(index.ids.count)
        }

        for rowIndex in index.ids.indices {
            scannedCount += 1
            if scannedCount % 500 == 0 {
                try Task.checkCancellation()
            }
            let sim = dotProduct(qNorm, index.vectors, rowIndex: rowIndex, dimension: index.dimension)

            if sim < similarityThreshold {
                continue
            }

            matchedCount += 1
            let match = VectorMatch(id: index.ids[rowIndex], similarity: sim)
            if needsFullRanking {
                allMatches.append(match)
            } else {
                topK.insert(match)
            }

            if scannedCount - lastPublishedScanCount >= 1_000 {
                let progressMatches = needsFullRanking
                    ? allMatches.sorted { $0.similarity > $1.similarity }
                    : topK.sortedDescending()
                let progressResults = try fetchPostsByIDsPreservingOrder(progressMatches)
                lastPublishedScanCount = scannedCount
                await onProgress?(progressResults)
            }
        }

        let rankedMatches: [VectorMatch]
        if needsFullRanking {
            rankedMatches = allMatches.sorted { $0.similarity > $1.similarity }
        } else {
            rankedMatches = topK.sortedDescending()
        }

        let results = try fetchPostsByIDsPreservingOrder(rankedMatches)
        await onProgress?(results)
        diagnostics?.record(
            method: "Embedding",
            query: preprocessed,
            posts: results.map(\.0),
            duration: Date().timeIntervalSince(startedAt),
            detail: "Scanned \(scannedCount) vectors; \(matchedCount) met cosine threshold \(String(format: "%.3f", similarityThreshold)); dimension \(index.dimension)"
        )

        print("[VectorSearch] query='\(preprocessed)' scanned=\(scannedCount) matched=\(matchedCount) returned=\(results.count) threshold=\(String(format: "%.3f", similarityThreshold))")
        if let best = results.first {
            print("[VectorSearch] Best match similarity: \(String(format: "%.4f", best.1))")
        }
        if results.count >= 3 {
            print("[VectorSearch] Top 3 similarities: \(results.prefix(3).map { String(format: "%.3f", $0.1) }.joined(separator: ", "))")
        }

        validateEmbeddingOrdering(results, query: preprocessed)

        return results
    }

    private func ensureTextEmbeddingIndex() throws -> TextEmbeddingSearchIndex {
        try Task.checkCancellation()
        if let textEmbeddingIndex {
            return textEmbeddingIndex
        }

        let (index, repairs) = try loadTextEmbeddingIndex()
        textEmbeddingIndex = index

        print("[VectorSearch] Loaded text embedding index rows=\(index.ids.count) dimension=\(index.dimension) normalized_repairs=\(index.normalizedRepairCount) skipped_invalid=\(index.skippedInvalidCount) skipped_dimension=\(index.skippedDimensionCount)")

        if !repairs.isEmpty {
            Task { self.repairNormalizedTextEmbeddings(repairs) }
        }

        return index
    }

    private func loadTextEmbeddingIndex() throws -> (TextEmbeddingSearchIndex, repairs: [(id: Int, embedding: [Float])]) {
        let sql = """
        SELECT id, text_embedding_normalized, text_embedding
        FROM Posts
        WHERE COALESCE(text_embedding_normalized, text_embedding) IS NOT NULL
          AND (length(trim(full_text)) > 0 OR quoted_post IS NOT NULL);
        """

        var ids: [Int] = []
        var vectors: [Float] = []
        var dimension: Int?
        var repairs: [(id: Int, embedding: [Float])] = []
        var normalizedRepairCount = 0
        var skippedInvalidCount = 0
        var skippedDimensionCount = 0

        for row in try db.prepare(sql) {
            if ids.count.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let id = Int(row[0] as! Int64)
            let storedNormalized = (row[1] as? Blob).map { dataToFloats(Data($0.bytes)) } ?? []
            let original = (row[2] as? Blob).map { dataToFloats(Data($0.bytes)) } ?? []

            func isUsable(_ vector: [Float]) -> Bool {
                !vector.isEmpty &&
                !vector.contains(where: { $0.isNaN || $0.isInfinite }) &&
                vectorMagnitude(vector) > 1e-12
            }

            var vector: [Float]
            var needsRepair: Bool
            if isUsable(storedNormalized) {
                vector = storedNormalized
                needsRepair = false
            } else if isUsable(original) {
                vector = original
                needsRepair = true
            } else {
                skippedInvalidCount += 1
                continue
            }

            if dimension == nil {
                dimension = vector.count
            }

            if let expectedDimension = dimension, vector.count != expectedDimension {
                if isUsable(original), original.count == expectedDimension {
                    vector = original
                    needsRepair = true
                } else {
                    skippedDimensionCount += 1
                    continue
                }
            }

            let magnitude = vectorMagnitude(vector)
            let normalized: [Float]
            if abs(magnitude - 1.0) > normalizedEmbeddingTolerance {
                normalized = l2NormalizeVec(vector)
                needsRepair = true
            } else {
                normalized = vector
            }

            if needsRepair {
                repairs.append((id: id, embedding: normalized))
                normalizedRepairCount += 1
            }

            ids.append(id)
            vectors.append(contentsOf: normalized)
        }

        let index = TextEmbeddingSearchIndex(
            ids: ids,
            vectors: vectors,
            dimension: dimension ?? 0,
            loadedAt: Date(),
            normalizedRepairCount: normalizedRepairCount,
            skippedInvalidCount: skippedInvalidCount,
            skippedDimensionCount: skippedDimensionCount
        )
        return (index, repairs)
    }

    private func repairNormalizedTextEmbeddings(_ repairs: [(id: Int, embedding: [Float])]) {
        do {
            try db.transaction {
                let stmt = try db.prepare("UPDATE Posts SET text_embedding_normalized = ? WHERE id = ?;")
                for repair in repairs {
                    try stmt.run(floatsToBlob(repair.embedding), Int64(repair.id))
                }
            }
            print("[VectorSearch] Stored \(repairs.count) normalized text embeddings without changing originals")
        } catch {
            print("[VectorSearch] Warning: failed to persist normalized text embeddings: \(error)")
        }
    }

    private func fetchPostsByIDsPreservingOrder(_ matches: [VectorMatch]) throws -> [(Post, Double)] {
        try Task.checkCancellation()
        guard !matches.isEmpty else { return [] }

        let idsList = matches.map { String($0.id) }.joined(separator: ",")
        let fetchSQL = """
        SELECT \(SQLitePostRowDecoder.standardProjection)
        FROM Posts WHERE id IN (\(idsList));
        """

        var postsById: [Int: Post] = [:]
        postsById.reserveCapacity(matches.count)

        for row in try db.prepare(fetchSQL) {
            if postsById.count.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let post = postRowDecoder.decode(row).post
            postsById[post.id] = post
        }

        return matches.compactMap { match in
            guard let post = postsById[match.id] else { return nil }
            return (post, match.similarity)
        }
    }
    
    /// Log all search results with full text and similarity scores in the exact order they're passed to the view
    private func logSearchResults(_ results: [(Post, Double)], query: String, searchType: String) {
        let topIDs = results.prefix(3).map { String($0.0.id) }.joined(separator: ", ")
        let topScores = results.prefix(3).map { String(format: "%.3f", $0.1) }.joined(separator: ", ")
        print("[\(searchType)Search] query='\(query)' results=\(results.count) top_ids=[\(topIDs)] top_scores=[\(topScores)]")
    }

    /// Validate that embedding search results are properly ordered by similarity
    private func validateEmbeddingOrdering(_ results: [(Post, Double)], query: String) {
        guard results.count > 1 else { return }
        
        var isOrdered = true
        for i in 0..<(results.count - 1) {
            if results[i].1 < results[i + 1].1 {
                isOrdered = false
                print("[VectorSearch] WARNING: Results not properly ordered! Index \(i): \(String(format: "%.3f", results[i].1)) < Index \(i+1): \(String(format: "%.3f", results[i + 1].1))")
            }
        }
        
        if !isOrdered {
            print("[VectorSearch] ❌ Results NOT properly ordered by similarity")
        }
    }

    private func preprocessQueryForEmbedding(_ query: String) -> String {
        // Keep preprocessing minimal and identical to how post embeddings are created:
        // trim only, do not alter internal whitespace or append tokens
        // This should match exactly what EmbeddingsManager.embed() does
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Log preprocessing for debugging accuracy issues
        if trimmed != query {
            print("[VectorSearch] Query preprocessing: '\(query)' -> '\(trimmed)'")
        }
        
        return trimmed
    }

    private func appendKeywordExplanation(lines: inout [String], postID: Int, results: [Post], query: String) {
        lines.append("Keyword match")
        if let index = results.firstIndex(where: { $0.id == postID }) {
            lines.append("- matched FTS/keyword search: yes")
            lines.append("- keyword rank: \(index + 1) of \(results.count)")
            if let bm25Score = try? keywordBM25Score(for: postID, query: query) {
                lines.append("- bm25(posts_fts): \(formatDebugDouble(bm25Score))")
            } else {
                lines.append("- bm25(posts_fts): no direct FTS row match; this may have come from the LIKE fallback")
            }
        } else {
            lines.append("- matched FTS/keyword search: no")
        }
    }

    private func appendTopicExplanation(lines: inout [String], postID: Int, results: [Post], query: String) {
        lines.append("Topic match")
        if let index = results.firstIndex(where: { $0.id == postID }) {
            lines.append("- matched exact primary/secondary topic '\(query)': yes")
            lines.append("- topic rank: \(index + 1) of \(results.count)")
        } else {
            lines.append("- matched exact primary/secondary topic '\(query)': no")
        }
    }

    private func appendEmbeddingExplanation(lines: inout [String], postID: Int, scored: [(Post, Double)]) {
        lines.append("Embedding match")
        if let index = scored.firstIndex(where: { $0.0.id == postID }) {
            let similarity = scored[index].1
            lines.append("- matched embedding search: yes")
            lines.append("- embedding rank: \(index + 1) of \(scored.count)")
            lines.append("- cosine similarity: \(formatDebugDouble(similarity))")
            lines.append("- normalized embedding score: \(formatDebugDouble(max(0.0, min(1.0, (similarity + 1.0) / 2.0))))")
        } else {
            lines.append("- matched embedding search: no")
        }
    }

    private func appendImageEmbeddingExplanation(lines: inout [String], postID: Int, scored: [(Post, Double)]) {
        lines.append("Image embedding match")
        if let index = scored.firstIndex(where: { $0.0.id == postID }) {
            let bestSimilarity = scored[index].1
            lines.append("- matched image embedding search: yes")
            lines.append("- image embedding rank: \(index + 1) of \(scored.count)")
            lines.append("- best qualifying image similarity: \(formatDebugDouble(bestSimilarity))")
            lines.append("- image embedding contribution: \(formatDebugDouble(max(0.0, bestSimilarity)))")
        } else {
            lines.append("- matched image embedding search: no")
        }
    }

    private func appendHybridExplanation(
        lines: inout [String],
        post: Post?,
        postID: Int,
        queryTerms: [String],
        embeddingResults: [(Post, Double)],
        imageEmbeddingResults: [(Post, Double)]
    ) {
        lines.append("Hybrid combined score")

        if let post {
            var textContribution = 0.0
            var primaryTopicContribution = 0.0
            var secondaryTopicContribution = 0.0
            var matchedUniqueTerms = 0

            let fullText = post.full_text.lowercased()
            let primaryTopic = post.primary_topic.lowercased()
            let secondaryTopics = post.secondary_topics.map { $0.lowercased() }

            for term in queryTerms {
                let textOccurrences = countOccurrences(of: term, in: fullText)
                let primaryTopicMatches = primaryTopic == term
                let matchingSecondaryTopics = secondaryTopics.filter { $0 == term }.count

                textContribution += fullTextOccurrenceScore(for: textOccurrences)
                if primaryTopicMatches {
                    primaryTopicContribution += 0.85
                }
                secondaryTopicContribution += 0.7 * Double(matchingSecondaryTopics)

                if textOccurrences > 0 || primaryTopicMatches || matchingSecondaryTopics > 0 {
                    matchedUniqueTerms += 1
                }
            }

            let matchesAllQueryTerms = !queryTerms.isEmpty && matchedUniqueTerms == queryTerms.count
            lines.append("- lexical candidate: \(matchesAllQueryTerms ? "yes" : "no") (\(matchedUniqueTerms)/\(queryTerms.count) terms)")
            if matchesAllQueryTerms {
                lines.append("- full_text contribution: \(formatDebugDouble(textContribution))")
                lines.append("- primary_topic contribution: \(formatDebugDouble(primaryTopicContribution))")
                lines.append("- secondary_topics contribution: \(formatDebugDouble(secondaryTopicContribution))")
                lines.append("- full term coverage contribution: \(formatDebugDouble(0.8))")
            } else {
                lines.append("- lexical contribution: 0 (every query term is required)")
            }
        } else {
            lines.append("- full_text contribution: unknown (post is not in the current result set)")
            lines.append("- primary_topic contribution: unknown")
            lines.append("- secondary_topics contribution: unknown")
        }

        if let index = embeddingResults.firstIndex(where: { $0.0.id == postID }) {
            let similarity = max(0.0, min(1.0, embeddingResults[index].1))
            lines.append("- embedding contribution: \(formatDebugDouble(similarity))")
        } else {
            lines.append("- embedding contribution: 0")
        }

        if let index = imageEmbeddingResults.firstIndex(where: { $0.0.id == postID }) {
            let bestSimilarity = max(0.0, imageEmbeddingResults[index].1)
            lines.append("- best image embedding contribution: \(formatDebugDouble(bestSimilarity))")
        } else {
            lines.append("- best image embedding contribution: 0")
        }
    }

    private func keywordBM25Score(for postID: Int, query: String) throws -> Double? {
        let sql = """
        SELECT bm25(posts_fts)
        FROM posts_fts
        WHERE rowid = ? AND posts_fts MATCH ?
        LIMIT 1;
        """
        let stmt = try db.prepare(sql)
        return try stmt.run(Int64(postID), query).compactMap { row in
            if let value = row[0] as? Double { return value }
            if let value = row[0] as? Int64 { return Double(value) }
            return nil
        }.first
    }

    private func debugString(for value: Binding?) -> String {
        guard let value else { return "NULL" }
        if let blob = value as? Blob {
            return "<BLOB \(blob.bytes.count) bytes>"
        }
        if let string = value as? String {
            return String(reflecting: string)
        }
        if let double = value as? Double {
            return formatDebugDouble(double)
        }
        if let int = value as? Int64 {
            return String(int)
        }
        return String(describing: value)
    }

    private func formatDebugDouble(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
    
    private func l2NormalizeVec(_ v: [Float]) -> [Float] {
        let sum = v.reduce(0.0) { $0 + Double($1) * Double($1) }
        let n = max(1e-12, sqrt(sum))
        return v.map { $0 / Float(n) }
    }

    private func vectorMagnitude(_ v: [Float]) -> Double {
        sqrt(v.reduce(0.0) { $0 + Double($1) * Double($1) })
    }

    private func dotProduct(_ query: [Float], _ vectors: [Float], rowIndex: Int, dimension: Int) -> Double {
        let offset = rowIndex * dimension
        guard dimension > 0,
              query.count >= dimension,
              offset >= 0,
              offset + dimension <= vectors.count
        else {
            return scalarDotProduct(query, vectors, offset: max(0, offset), dimension: max(0, dimension))
        }

        return query.withUnsafeBufferPointer { queryBuffer in
            vectors.withUnsafeBufferPointer { vectorBuffer in
                guard
                    let queryBase = queryBuffer.baseAddress,
                    let vectorBase = vectorBuffer.baseAddress
                else {
                    return 0.0
                }

                var result: Float = 0
                vDSP_dotpr(
                    queryBase,
                    1,
                    vectorBase.advanced(by: offset),
                    1,
                    &result,
                    vDSP_Length(dimension)
                )
                return max(-1.0, min(1.0, Double(result)))
            }
        }
    }

    private func scalarDotProduct(_ query: [Float], _ vectors: [Float], offset: Int, dimension: Int) -> Double {
        guard offset < vectors.count else { return 0.0 }
        let n = min(dimension, query.count, vectors.count - offset)
        guard n > 0 else { return 0.0 }

        var result: Double = 0.0
        for i in 0..<n {
            result += Double(query[i]) * Double(vectors[offset + i])
        }
        return max(-1.0, min(1.0, result))
    }

    /// High-precision cosine similarity computation for optimal accuracy
    private func computeCosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0.0 }
        
        // Validate input vectors for quality
        if !validateEmbeddingQuality(a, name: "query") || !validateEmbeddingQuality(b, name: "post") {
            print("[VectorSearch] Warning: Low-quality embeddings detected, similarity may be unreliable")
        }
        
        // Use double precision for maximum accuracy
        var dotProduct: Double = 0.0
        var normA: Double = 0.0
        var normB: Double = 0.0
        
        for i in 0..<n {
            let ai = Double(a[i])
            let bi = Double(b[i])
            dotProduct += ai * bi
            normA += ai * ai
            normB += bi * bi
        }
        
        // Avoid division by zero and ensure numerical stability
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 1e-12 else { return 0.0 }
        
        let similarity = dotProduct / denominator
        
        // Clamp to valid range [-1, 1] for numerical stability
        return max(-1.0, min(1.0, similarity))
    }
    
    /// Validate embedding quality to ensure accurate similarity computation
    private func validateEmbeddingQuality(_ embedding: [Float], name: String) -> Bool {
        guard !embedding.isEmpty else { return false }
        
        // Check for NaN or infinite values
        let hasInvalidValues = embedding.contains { $0.isNaN || $0.isInfinite }
        if hasInvalidValues {
            print("[VectorSearch] Warning: Invalid values in \(name) embedding")
            return false
        }
        
        // Check magnitude (should be close to 1.0 for normalized vectors)
        let magnitude = sqrt(embedding.reduce(0.0) { $0 + Double($1) * Double($1) })
        let magnitudeDeviation = abs(magnitude - 1.0)
        if magnitudeDeviation > 0.1 {
            print("[VectorSearch] Warning: \(name) embedding magnitude \(String(format: "%.3f", magnitude)) deviates from 1.0")
            return false
        }
        
        return true
    }
    
    /// Legacy dot product function (kept for compatibility)
    private func dot(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        var s = 0.0
        var i = 0
        while i < n { s += Double(a[i]) * Double(b[i]); i += 1 }
        return s
    }

    // MARK: - Embedding backfill helpers

    func getTextEmbeddingProgressCounts() async throws -> EmbeddingProgressCounts {
        try await connect()
        let stmt = try db.prepare("""
            SELECT
                COUNT(*),
                SUM(CASE WHEN text_embedding IS NOT NULL THEN 1 ELSE 0 END)
            FROM Posts
            WHERE length(trim(full_text)) > 0
               OR ifnull(article, '') <> ''
               OR quoted_post IS NOT NULL;
            """)
        for row in try stmt.run() {
            let total = Int((row[0] as? Int64) ?? 0)
            let completed = Int((row[1] as? Int64) ?? 0)
            return EmbeddingProgressCounts(total: total, completed: completed)
        }
        return EmbeddingProgressCounts(total: 0, completed: 0)
    }

    func getImageEmbeddingProgressSnapshot() async throws -> ImageEmbeddingProgressSnapshot {
        try await connect()

        var resolvedURLsByPostID: [Int: Set<String>] = [:]
        let storedStmt = try db.prepare("""
            SELECT post_id, media_url
            FROM ImageEmbeddings
            WHERE model_version = ?;
        """)
        for row in try storedStmt.run(EmbeddingsManager.imageEmbeddingModelVersion) {
            guard let postID = row[0] as? Int64, let mediaURL = row[1] as? String else { continue }
            resolvedURLsByPostID[Int(postID), default: []].insert(mediaURL)
        }
        let unavailableStmt = try db.prepare("""
            SELECT post_id, media_url
            FROM UnavailableImageEmbeddings;
            """)
        for row in try unavailableStmt.run() {
            guard let postID = row[0] as? Int64, let mediaURL = row[1] as? String else { continue }
            resolvedURLsByPostID[Int(postID), default: []].insert(mediaURL)
        }

        let postStmt = try db.prepare("""
            SELECT id, media, article, quoted_post
            FROM Posts
            WHERE ifnull(media, '') <> ''
               OR ifnull(article, '') <> ''
               OR ifnull(quoted_post, '') <> '';
            """)
        var total = 0
        var completedPostIDs = Set<Int>()
        for row in try postStmt.run() {
            guard let rawID = row[0] as? Int64 else { continue }
            let postID = Int(rawID)
            let media = decodeJSON(row[1] as? String, as: [Media].self) ?? []
            let article = decodeJSON(row[2] as? String, as: Article.self)
            let quotedPost = decodeJSON(row[3] as? String, as: QuotedPost.self)
            let combined = media + (article?.allMedia ?? []) + (quotedPost?.media ?? [])
            let expectedURLs = Set(
                combined
                    .filter(MediaImageProcessor.isImageSearchMedia)
                    .map { $0.original.absoluteString }
            )
            guard !expectedURLs.isEmpty else { continue }

            total += 1
            if expectedURLs.isSubset(of: resolvedURLsByPostID[postID] ?? []) {
                completedPostIDs.insert(postID)
            }
        }

        return ImageEmbeddingProgressSnapshot(total: total, completedPostIDs: completedPostIDs)
    }

    func fetchPostsMissingImageEmbeddings(limit: Int, beforeCreatedAt: Date? = nil, beforeId: Int? = nil) async throws -> [Post] {
        guard limit > 0 else { return [] }
        try await connect()
        var args: [Binding?] = []
        var whereSQL = "WHERE (ifnull(media,'') <> '' OR ifnull(article,'') <> '' OR ifnull(quoted_post,'') <> '')"
        if let bDate = beforeCreatedAt, let bId = beforeId {
            whereSQL += " AND (created_at < ? OR (created_at = ? AND id < ?))"
            args.append(bDate.timeIntervalSince1970)
            args.append(bDate.timeIntervalSince1970)
            args.append(Int64(bId))
        }
        let sql = """
        SELECT \(SQLitePostRowDecoder.projectionWithoutBookmarkOrdering)
            FROM Posts
        \(whereSQL)
            ORDER BY created_at DESC, id DESC
        LIMIT \(limit);
        """
        var out: [Post] = []
        let stmt = try db.prepare(sql)
        for row in try stmt.run(args) {
            out.append(postRowDecoder.decode(row, layout: .withoutBookmarkOrdering).post)
        }
        return out
    }

    func fetchPostsMissingTextEmbeddings(limit: Int, beforeCreatedAt: Date? = nil, beforeId: Int? = nil) async throws -> [Post] {
        guard limit > 0 else { return [] }
        try await connect()
        var args: [Binding?] = []
        var whereSQL = "WHERE text_embedding IS NULL AND (length(trim(full_text)) > 0 OR ifnull(article,'') <> '' OR quoted_post IS NOT NULL)"
        if let bDate = beforeCreatedAt, let bId = beforeId {
            whereSQL += " AND (created_at < ? OR (created_at = ? AND id < ?))"
            args.append(bDate.timeIntervalSince1970)
            args.append(bDate.timeIntervalSince1970)
            args.append(Int64(bId))
        }
        let sql = """
        SELECT \(SQLitePostRowDecoder.projectionWithoutBookmarkOrdering)
            FROM Posts
        \(whereSQL)
            ORDER BY created_at DESC, id DESC
        LIMIT \(limit);
        """
        var out: [Post] = []
        let stmt = try db.prepare(sql)
        for row in try stmt.run(args) {
            out.append(postRowDecoder.decode(row, layout: .withoutBookmarkOrdering).post)
        }
        return out
    }

    func updateTextEmbeddings(_ items: [(id: Int, embedding: [Float])]) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        try await connect()
        try db.transaction {
            let stmt = try db.prepare("""
                UPDATE Posts
                SET text_embedding = ?,
                    text_embedding_normalized = ?
                WHERE id = ? AND text_embedding IS NULL;
                """)
            for (id, vec) in items {
                try stmt.run(
                    floatsToBlob(vec),
                    floatsToBlob(normalizedTextEmbedding(vec)),
                    Int64(id)
                )
            }
        }
        invalidateTextEmbeddingIndex()

        let verifyStmt = try db.prepare("SELECT text_embedding FROM Posts WHERE id = ? LIMIT 1;")
        var verifiedCount = 0
        for (id, _) in items {
            for row in try verifyStmt.run(Int64(id)) {
                if row[0] is Blob {
                    verifiedCount += 1
                }
            }
        }
        print("[SQLiteManager] Text embedding update verified \(verifiedCount)/\(items.count) rows")
        return verifiedCount
    }

    func resolvedImageEmbeddingURLs(for postIDs: [Int]) async throws -> [Int: Set<String>] {
        guard !postIDs.isEmpty else { return [:] }
        try await connect()
        let ids = postIDs.map(String.init).joined(separator: ",")
        let storedSQL = """
            SELECT post_id, media_url
            FROM ImageEmbeddings
            WHERE model_version = ? AND post_id IN (\(ids));
            """
        var urlsByPostID: [Int: Set<String>] = [:]
        for row in try db.prepare(storedSQL).run(EmbeddingsManager.imageEmbeddingModelVersion) {
            guard let postID = row[0] as? Int64, let mediaURL = row[1] as? String else { continue }
            urlsByPostID[Int(postID), default: []].insert(mediaURL)
        }
        let unavailableSQL = """
            SELECT post_id, media_url
            FROM UnavailableImageEmbeddings
            WHERE post_id IN (\(ids));
            """
        for row in try db.prepare(unavailableSQL).run() {
            guard let postID = row[0] as? Int64, let mediaURL = row[1] as? String else { continue }
            urlsByPostID[Int(postID), default: []].insert(mediaURL)
        }
        return urlsByPostID
    }

    func updateImageEmbeddings(_ items: [ImageEmbeddingUpdate]) async throws {
        guard !items.isEmpty else { return }
        try await connect()
        try db.transaction {
            let stmt = try db.prepare("""
                INSERT INTO ImageEmbeddings (post_id, media_url, embedding, model_version)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(post_id, media_url) DO UPDATE SET
                    embedding = excluded.embedding,
                    model_version = excluded.model_version;
                """)
            for item in items {
                try stmt.run(
                    Int64(item.postID),
                    item.mediaURL.absoluteString,
                    floatsToBlob(item.embedding),
                    EmbeddingsManager.imageEmbeddingModelVersion
                )
                try db.run(
                    "DELETE FROM UnavailableImageEmbeddings WHERE post_id = ? AND media_url = ?;",
                    Int64(item.postID),
                    item.mediaURL.absoluteString
                )
            }
        }
    }

    func updateUnavailableImageEmbeddings(_ items: [UnavailableImageEmbeddingUpdate]) async throws {
        guard !items.isEmpty else { return }
        try await connect()
        try db.transaction {
            let stmt = try db.prepare("""
                INSERT INTO UnavailableImageEmbeddings (post_id, media_url, http_status, detected_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(post_id, media_url) DO UPDATE SET
                    http_status = excluded.http_status,
                    detected_at = excluded.detected_at;
                """)
            for item in items {
                try stmt.run(
                    Int64(item.postID),
                    item.mediaURL.absoluteString,
                    Int64(item.statusCode),
                    Date().timeIntervalSince1970
                )
            }
        }
    }

    /// Fetch stored text embedding for a specific post id as [Float]
    func fetchTextEmbedding(for id: Int) async throws -> [Float]? {
        try await connect()
        let stmt = try db.prepare("SELECT text_embedding FROM Posts WHERE id = ? LIMIT 1;")
        for row in try stmt.run(Int64(id)) {
            if let blob = row[0] as? Blob {
                let data = Data(blob.bytes)
                return dataToFloats(data)
            }
        }
        return nil
    }

    func fetchStoredEmbeddingDimensions(for id: Int) async throws -> (text: Int?, normalizedText: Int?, image: Int?) {
        try await connect()
        let stmt = try db.prepare("""
            SELECT text_embedding, text_embedding_normalized, img_embedding
            FROM Posts
            WHERE id = ? LIMIT 1;
            """)
        for row in try stmt.run(Int64(id)) {
            let textDims = (row[0] as? Blob).map { dataToFloats(Data($0.bytes)).count }
            let normalizedTextDims = (row[1] as? Blob).map { dataToFloats(Data($0.bytes)).count }
            let imageDims = (row[2] as? Blob).map { dataToFloats(Data($0.bytes)).count }
            return (text: textDims, normalizedText: normalizedTextDims, image: imageDims)
        }
        return (text: nil, normalizedText: nil, image: nil)
    }
}

// Shared instance
let sqliteManager = SQLiteManager()
