public import Foundation
internal import CryptoKit

/// Downloaded Astray resources, independent of URLCache and WebKit. Only these
/// files contribute to disk usage; decoded audio and GPU resources remain in memory.
public actor StoryAssetCache {
    public static let shared = StoryAssetCache()
    public nonisolated let directory: URL
    private let maximumAge: TimeInterval
    private let download: @Sendable (URLRequest) async throws -> (URL, URLResponse)
    private let now: @Sendable () -> Date
    private var generation = UUID()
    private var pending: [String: Task<URL, Error>] = [:]

    /// Resources are revalidated daily; versioned URL paths remain separate entries.
    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "Astray/StoryResources-v1")) {
        self.directory = directory
        maximumAge = 24 * 60 * 60
        now = { Date() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        download = { try await session.download(for: $0) }
    }

    internal init(directory: URL, maximumAge: TimeInterval,
                  now: @escaping @Sendable () -> Date,
                  download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse)) {
        self.directory = directory
        self.maximumAge = maximumAge
        self.now = now
        self.download = download
    }

    public func data(at url: URL, revalidate: Bool = false) async throws -> Data {
        let file = try await fileURL(at: url, revalidate: revalidate)
        try Task.checkCancellation()
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    /// Movie playback uses the same downloaded file instead of AVPlayer's opaque network storage.
    public func fileURL(at url: URL, revalidate: Bool = false) async throws -> URL {
        try Task.checkCancellation()
        if url.isFileURL { return url }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let suffix = url.pathExtension
        let safeSuffix = !suffix.isEmpty && suffix.count <= 12 && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            ? suffix : "asset"
        let file = directory.appending(path: key + "." + safeSuffix)
        let metadataURL = directory.appending(path: key + ".metadata.json")
        let metadata = cachedMetadata(at: metadataURL, file: file)
        if !revalidate, let metadata, now().timeIntervalSince(metadata.validatedAt) < maximumAge { return file }
        if let task = pending[key] {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }
        let token = generation
        let task = Task { try await self.fetch(url, file: file, metadataURL: metadataURL, metadata: metadata, token: token) }
        pending[key] = task
        defer { if generation == token { pending[key] = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    public func diskUsage() throws -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        // The store is flat. Never follow a linked directory or count unrelated resources.
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)).reduce(0) { size, url in
            let values = try url.resourceValues(forKeys: keys)
            return size + (values.isRegularFile == true && values.isSymbolicLink != true ? Int64(values.fileSize ?? 0) : 0)
        }
    }

    /// A clear invalidates in-flight downloads, so they cannot recreate cleared files.
    public func clear() throws {
        generation = UUID()
        for task in pending.values { task.cancel() }
        pending = [:]
        do { try FileManager.default.removeItem(at: directory) }
        catch CocoaError.fileNoSuchFile { }
    }

    private struct Metadata: Codable, Sendable {
        var validatedAt: Date
        var byteCount: Int64
        var etag: String?
        var lastModified: String?
    }

    private func cachedMetadata(at url: URL, file: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == metadata.byteCount else { return nil }
        return metadata
    }

    private func fetch(_ url: URL, file: URL, metadataURL: URL, metadata: Metadata?, token: UUID) async throws -> URL {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(metadata?.etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(metadata?.lastModified, forHTTPHeaderField: "If-Modified-Since")
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await download(request) }
        catch {
            try Task.checkCancellation()
            // Offline playback may use a previously validated file, but never mask an HTTP failure.
            if metadata != nil, let error = error as? URLError,
               [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code),
               generation == token { return file }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else {
            throw AstrayError.assetUnavailable(url, "Invalid HTTP response.")
        }
        if response.statusCode == 304, var metadata {
            metadata.validatedAt = now()
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            return file
        }
        guard response.statusCode == 200 else {
            throw AstrayError.assetUnavailable(url, "HTTP \(response.statusCode)")
        }
        let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
        let updated = Metadata(validatedAt: now(), byteCount: Int64(values.fileSize ?? 0),
                               etag: response.value(forHTTPHeaderField: "ETag"),
                               lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: file.path) {
            _ = try manager.replaceItemAt(file, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: file)
        }
        try JSONEncoder().encode(updated).write(to: metadataURL, options: .atomic)
        return file
    }
}
