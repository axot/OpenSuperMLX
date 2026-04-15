import Foundation
import HuggingFace

// MARK: - Direct Download Progress Delegate

/// Reports byte-level progress directly to a standalone Progress object,
/// bypassing Foundation.Progress parent-child KVO (which is broken for large downloads).
private final class DirectDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: Progress
    let offset: Int64
    let destination: URL
    let continuation: CheckedContinuation<Void, Error>
    var session: URLSession?

    private let lock = NSLock()
    private var resumed = false

    init(
        progress: Progress,
        offset: Int64,
        destination: URL,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.progress = progress
        self.offset = offset
        self.destination = destination
        self.continuation = continuation
        super.init()
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            progress.totalUnitCount = max(progress.totalUnitCount, offset + totalBytesExpectedToWrite)
        }
        progress.completedUnitCount = offset + totalBytesWritten
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            resumeOnce(throwing: error)
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session?.finishTasksAndInvalidate()
        if let error {
            resumeOnce(throwing: error)
            return
        }
        guard let httpResponse = task.response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            let path = task.originalRequest?.url?.lastPathComponent ?? "unknown"
            resumeOnce(throwing: ModelUtilsError.downloadFailed("\(path) (HTTP \(statusCode))"))
            return
        }
        resumeOnce(throwing: nil)
    }

    private func resumeOnce(throwing error: Error?) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        guard shouldResume else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    let value: Progress
    init(_ value: Progress) { self.value = value }
}

// MARK: - ModelUtils

public enum ModelUtils {
    public static func resolveModelType(
        repoID: Repo.ID,
        hfToken: String? = nil,
        cache: HubCache = .default
    ) async throws -> String? {
        let modelNameComponents = repoID.name.split(separator: "/").last?.split(separator: "-")
        let modelURL = try await resolveOrDownloadModel(
            repoID: repoID,
            requiredExtension: "safetensors",
            hfToken: hfToken,
            cache: cache
        )
        let configJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: modelURL.appendingPathComponent("config.json")))
        if let config = configJSON as? [String: Any] {
            return (config["model_type"] as? String) ?? (config["architecture"] as? String) ?? modelNameComponents?.first?.lowercased()
        }
        return nil
    }

    /// Resolves a model from cache or downloads it if not cached.
    /// - Parameters:
    ///   - string: The repository name
    ///   - requiredExtension: File extension that must exist for cache to be considered complete (e.g., "safetensors")
    ///   - hfToken: The huggingface token for access to gated repositories, if needed.
    /// - Returns: The model directory URL
    public static func resolveOrDownloadModel(
        repoID: Repo.ID,
        requiredExtension: String,
        hfToken: String? = nil,
        cache: HubCache = .default,
        progressHandler: (@Sendable @MainActor (Progress) -> Void)? = nil
    ) async throws -> URL {
        let downloadCache = HubCache(
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mlx-hub-download")
        )
        let client: HubClient
        if let token = hfToken, !token.isEmpty {
            print("Using HuggingFace token from configuration")
            client = HubClient(host: HubClient.defaultHost, bearerToken: token, cache: downloadCache)
        } else {
            client = HubClient(cache: downloadCache)
        }
        return try await resolveOrDownloadModel(
            client: client,
            cache: cache,
            repoID: repoID,
            requiredExtension: requiredExtension,
            progressHandler: progressHandler
        )
    }

    /// Resolves a model from cache or downloads it if not cached.
    /// - Parameters:
    ///   - client: The HuggingFace Hub client
    ///   - cache: The HuggingFace cache
    ///   - repoID: The repository ID
    ///   - requiredExtension: File extension that must exist for cache to be considered complete (e.g., "safetensors")
    /// - Returns: The model directory URL
    public static func resolveOrDownloadModel(
        client: HubClient,
        cache: HubCache = .default,
        repoID: Repo.ID,
        requiredExtension: String,
        progressHandler: (@Sendable @MainActor (Progress) -> Void)? = nil
    ) async throws -> URL {
        let normalizedRequiredExtension = requiredExtension.hasPrefix(".")
            ? String(requiredExtension.dropFirst())
            : requiredExtension

        // Store downloaded model snapshots under the configured Hugging Face cache root.
        let modelSubdir = repoID.description.replacingOccurrences(of: "/", with: "_")
        let modelDir = cache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelSubdir)

        // Check if model already exists with required files
        if FileManager.default.fileExists(atPath: modelDir.path) {
            let files = try? FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: [.fileSizeKey])
            let hasRequiredFile = files?.contains { file in
                guard file.pathExtension == normalizedRequiredExtension else { return false }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return size > 0
            } ?? false

            if hasRequiredFile {
                // Validate that config.json is valid JSON
                let configPath = modelDir.appendingPathComponent("config.json")
                if FileManager.default.fileExists(atPath: configPath.path) {
                    if let configData = try? Data(contentsOf: configPath),
                       let _ = try? JSONSerialization.jsonObject(with: configData) {
                        print("Using cached model at: \(modelDir.path)")
                        return modelDir
                    } else {
                        print("Cached config.json is invalid, clearing cache...")
                        Self.clearCaches(modelDir: modelDir, repoID: repoID, hubCache: cache)
                    }
                }
            } else {
                print("Cached model appears incomplete, clearing cache...")
                Self.clearCaches(modelDir: modelDir, repoID: repoID, hubCache: cache)
            }
        }

        // Create directory if needed
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let allowedExtensions: Set<String> = ["*.\(normalizedRequiredExtension)", "*.safetensors", "*.json", "*.txt", "*.wav"]

        print("Downloading model \(repoID)...")

        // List files to determine sizes and split into small/large for download strategy.
        // Large files are downloaded with our own URLSessionDownloadDelegate for real-time
        // byte-level progress, avoiding Foundation.Progress parent-child KVO staleness.
        let allEntries = try await client.listFiles(
            in: repoID, kind: .model, revision: "main", recursive: true
        )
        let entries = allEntries.filter { entry in
            guard entry.type == .file else { return false }
            return allowedExtensions.contains { glob in
                fnmatch(glob, entry.path, 0) == 0
            }
        }

        let largeFileThreshold = 50 * 1024 * 1024
        let totalBytes = entries.reduce(Int64(0)) { $0 + max(Int64($1.size ?? 0), 1) }

        // Standalone Progress — no parent-child relationship, updated directly by our delegate
        let progress = Progress(totalUnitCount: max(totalBytes, 1))
        if let progressHandler {
            await progressHandler(progress)
        }

        // Periodically call progressHandler to trigger SwiftUI re-renders
        let progressBox = ProgressBox(progress)
        let samplingTask: Task<Void, Never>? = progressHandler.map { handler in
            Task {
                while !Task.isCancelled {
                    await handler(progressBox.value)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }

        var downloadedBytes: Int64 = 0

        do {
            for entry in entries {
                let fileSize = max(Int64(entry.size ?? 0), 1)
                let destination = modelDir.appendingPathComponent(entry.path)

                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if fileSize < largeFileThreshold {
                    _ = try await client.downloadFile(
                        at: entry.path,
                        from: repoID,
                        to: destination,
                        kind: .model,
                        revision: "main"
                    )
                    downloadedBytes += fileSize
                    progress.completedUnitCount = downloadedBytes
                } else {
                    try await downloadLargeFile(
                        host: client.host,
                        bearerToken: await client.bearerToken,
                        repoID: repoID,
                        filePath: entry.path,
                        destination: destination,
                        progress: progress,
                        offset: downloadedBytes
                    )
                    downloadedBytes += fileSize
                }
            }
        } catch {
            samplingTask?.cancel()
            throw error
        }

        samplingTask?.cancel()
        progress.completedUnitCount = progress.totalUnitCount
        if let progressHandler {
            await progressHandler(progress)
        }

        // Clean /tmp download cache after successful download
        if let tmpCache = client.cache {
            let tmpRepoDir = tmpCache.repoDirectory(repo: repoID, kind: .model)
            try? FileManager.default.removeItem(at: tmpRepoDir)
        }

        // Post-download validation: ensure required files are non-zero
        let downloadedFiles = try? FileManager.default.contentsOfDirectory(
            at: modelDir, includingPropertiesForKeys: [.fileSizeKey]
        )
        let hasValidFile = downloadedFiles?.contains { file in
            guard file.pathExtension == normalizedRequiredExtension else { return false }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        } ?? false

        if !hasValidFile {
            Self.clearCaches(modelDir: modelDir, repoID: repoID, hubCache: cache)
            throw ModelUtilsError.incompleteDownload(repoID.description)
        }

        print("Model downloaded to: \(modelDir.path)")
        return modelDir
    }

    // MARK: - Large File Download

    /// Downloads a large file directly with our own URLSessionDownloadDelegate,
    /// providing real-time byte-level progress via the delegate's didWriteData callback.
    private static func downloadLargeFile(
        host: URL,
        bearerToken: String?,
        repoID: Repo.ID,
        filePath: String,
        destination: URL,
        progress: Progress,
        offset: Int64
    ) async throws {
        // Construct the same resolve URL that HubClient uses
        let url = host
            .appending(path: repoID.namespace)
            .appending(path: repoID.name)
            .appending(path: "resolve")
            .appending(component: "main")
            .appending(path: filePath)

        var request = URLRequest(url: url)
        if let token = bearerToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DirectDownloadDelegate(
                progress: progress, offset: offset,
                destination: destination, continuation: continuation
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    // MARK: - Cache Management

    private static func clearCaches(modelDir: URL, repoID: Repo.ID, hubCache: HubCache) {
        try? FileManager.default.removeItem(at: modelDir)
        let hubRepoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        if FileManager.default.fileExists(atPath: hubRepoDir.path) {
            print("Clearing Hub cache at: \(hubRepoDir.path)")
            try? FileManager.default.removeItem(at: hubRepoDir)
        }
    }
}

// MARK: - Errors

public enum ModelUtilsError: LocalizedError {
    case incompleteDownload(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .incompleteDownload(let repo):
            return "Downloaded model '\(repo)' has missing or zero-byte weight files. "
                + "The cache has been cleared — please try again."
        case .downloadFailed(let detail):
            return "Failed to download file: \(detail)"
        }
    }
}
