//
//  LocalEmbeddingModelManager.swift
//  Xray
//

import Foundation
import HuggingFace
import Observation

enum LocalEmbeddingModel: String, CaseIterable, Identifiable, Sendable {
    case text
    case image

    var id: String { rawValue }

    var repositoryID: Repo.ID {
        switch self {
        case .text:
            "mlx-community/Qwen3-Embedding-0.6B-8bit"
        case .image:
            "mlx-community/Qwen3-VL-Embedding-2B-8bit"
        }
    }

    var displayName: String {
        switch self {
        case .text:
            "Qwen3 Text Embeddings"
        case .image:
            "Qwen3-VL Image Embeddings"
        }
    }

    var repositoryName: String {
        repositoryID.description
    }

    var directoryName: String {
        switch self {
        case .text:
            "Qwen3-Embedding-0.6B-8bit"
        case .image:
            "Qwen3-VL-Embedding-2B-8bit"
        }
    }

    var weightsURL: URL {
        URL(string: "https://huggingface.co/\(repositoryID.description)/resolve/main/model.safetensors")!
    }
}

enum LocalModelDownloadState: Equatable {
    case notInstalled
    case downloading(Double)
    case installed(Int64)
    case failed(String)
}

enum LocalEmbeddingModelStore {
    static func modelsDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Xray", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static func directory(for model: LocalEmbeddingModel) -> URL {
        modelsDirectory().appendingPathComponent(model.directoryName, isDirectory: true)
    }

    static func cache(for model: LocalEmbeddingModel) -> HubCache {
        HubCache(cacheDirectory: directory(for: model))
    }

    static func resolvedModelDirectory(for model: LocalEmbeddingModel) -> URL? {
        let legacyDirectory = directory(for: model)
        if containsCompleteModel(at: legacyDirectory) {
            return legacyDirectory
        }

        let cache = cache(for: model)
        guard let revision = cache.resolveRevision(repo: model.repositoryID, kind: .model, ref: "main") else {
            return nil
        }

        let snapshot = cache.snapshotsDirectory(repo: model.repositoryID, kind: .model)
            .appendingPathComponent(revision, isDirectory: true)
        return containsCompleteModel(at: snapshot) ? snapshot : nil
    }

    static func modelIdentifier(for model: LocalEmbeddingModel) -> String {
        (resolvedModelDirectory(for: model) ?? directory(for: model)).path
    }

    static func isInstalled(_ model: LocalEmbeddingModel) -> Bool {
        resolvedModelDirectory(for: model) != nil
    }

    private static func containsCompleteModel(at directory: URL) -> Bool {
        let config = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: config.path) else { return false }

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return enumerator?.contains {
            guard let url = $0 as? URL else { return false }
            return url.pathExtension == "safetensors"
        } ?? false
    }

    static func allocatedSize(of model: LocalEmbeddingModel) -> Int64 {
        let directory = directory(for: model)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ]), values.isRegularFile == true else { continue }
            size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return size
    }
}

@MainActor
@Observable
final class LocalEmbeddingModelManager {
    private(set) var states: [LocalEmbeddingModel: LocalModelDownloadState] = [:]

    init() {
        refresh()
    }

    var isDownloading: Bool {
        states.values.contains {
            if case .downloading = $0 { return true }
            return false
        }
    }

    var totalInstalledSize: Int64 {
        states.values.reduce(0) { partial, state in
            guard case let .installed(size) = state else { return partial }
            return partial + size
        }
    }

    func state(for model: LocalEmbeddingModel) -> LocalModelDownloadState {
        states[model] ?? .notInstalled
    }

    func refresh() {
        for model in LocalEmbeddingModel.allCases {
            states[model] = LocalEmbeddingModelStore.isInstalled(model)
                ? .installed(LocalEmbeddingModelStore.allocatedSize(of: model))
                : .notInstalled
        }
    }

    func downloadMissingModels() async {
        for model in LocalEmbeddingModel.allCases where !LocalEmbeddingModelStore.isInstalled(model) {
            await download(model)
        }
    }

    func download(_ model: LocalEmbeddingModel) async {
        guard !isDownloading else { return }

        let destination = LocalEmbeddingModelStore.directory(for: model)
        if LocalEmbeddingModelStore.isInstalled(model) {
            states[model] = .installed(LocalEmbeddingModelStore.allocatedSize(of: model))
            return
        }
        states[model] = .downloading(0)

        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )

            let cache = LocalEmbeddingModelStore.cache(for: model)
            let client = HubClient(cache: cache)
            let snapshot = try await client.downloadSnapshot(
                of: model.repositoryID,
                matching: ["*.json", "*.md", "*.jinja", "*.txt", ".gitattributes"],
                maxConcurrentDownloads: 2
            ) { [weak self] progress in
                self?.states[model] = .downloading(
                    min(max(progress.fractionCompleted * 0.01, 0), 0.01)
                )
            }

            let weights = snapshot.appendingPathComponent("model.safetensors")
            let incompleteWeights = snapshot.appendingPathComponent("model.safetensors.incomplete")
            try await PersistentFileDownloader.download(
                from: model.weightsURL,
                to: weights,
                incompleteFile: incompleteWeights
            ) { [weak self] progress in
                self?.states[model] = .downloading(0.01 + (progress * 0.99))
            }

            guard LocalEmbeddingModelStore.isInstalled(model) else {
                throw LocalModelError.incompleteDownload(model.displayName)
            }
            states[model] = .installed(LocalEmbeddingModelStore.allocatedSize(of: model))
        } catch is CancellationError {
            states[model] = .notInstalled
        } catch {
            states[model] = .failed(error.localizedDescription)
        }
    }

    func delete(_ model: LocalEmbeddingModel) async {
        switch model {
        case .text:
            EmbeddingsManager.unloadTextModel()
        case .image:
            await EmbeddingsManager.unloadImageModel()
        }

        do {
            let directory = LocalEmbeddingModelStore.directory(for: model)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            states[model] = .notInstalled
        } catch {
            states[model] = .failed(error.localizedDescription)
        }
    }
}

private final class PersistentFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let destination: URL
    private let incompleteFile: URL
    private let progressHandler: @MainActor @Sendable (Double) -> Void

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var resumeOffset: Int64 = 0
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 0

    private init(
        source: URL,
        destination: URL,
        incompleteFile: URL,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) {
        self.source = source
        self.destination = destination
        self.incompleteFile = incompleteFile
        self.progressHandler = progressHandler
    }

    static func download(
        from source: URL,
        to destination: URL,
        incompleteFile: URL,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            await progressHandler(1)
            return
        }

        let downloader = PersistentFileDownloader(
            source: source,
            destination: destination,
            incompleteFile: incompleteFile,
            progressHandler: progressHandler
        )
        try await downloader.start()
    }

    private func start() async throws {
        try FileManager.default.createDirectory(
            at: incompleteFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: incompleteFile.path) {
            FileManager.default.createFile(atPath: incompleteFile.path, contents: nil)
        }

        let values = try incompleteFile.resourceValues(forKeys: [.fileSizeKey])
        resumeOffset = Int64(values.fileSize ?? 0)
        completedBytes = resumeOffset
        fileHandle = try FileHandle(forWritingTo: incompleteFile)
        try fileHandle?.seekToEnd()

        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 || response.statusCode == 206 else {
            completionHandler(.cancel)
            finish(with: URLError(.badServerResponse))
            return
        }

        do {
            if resumeOffset > 0, response.statusCode == 200 {
                try fileHandle?.truncate(atOffset: 0)
                try fileHandle?.seek(toOffset: 0)
                resumeOffset = 0
                completedBytes = 0
            }
            let remainingBytes = max(response.expectedContentLength, 0)
            totalBytes = resumeOffset + remainingBytes
            reportProgress()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(with: error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            completedBytes += Int64(data.count)
            reportProgress()
        } catch {
            task?.cancel()
            finish(with: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: error)
            return
        }

        do {
            try fileHandle?.close()
            fileHandle = nil
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: incompleteFile, to: destination)
            Task { @MainActor in progressHandler(1) }
            finish(with: nil)
        } catch {
            finish(with: error)
        }
    }

    private func reportProgress() {
        guard totalBytes > 0 else { return }
        let fraction = min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        Task { @MainActor in progressHandler(fraction) }
    }

    private func finish(with error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        try? fileHandle?.close()
        fileHandle = nil
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private enum LocalModelError: LocalizedError {
    case incompleteDownload(String)

    var errorDescription: String? {
        switch self {
        case let .incompleteDownload(name):
            "The download for \(name) did not contain a complete model."
        }
    }
}
