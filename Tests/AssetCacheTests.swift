import Foundation
@testable import Astray

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { time } }
    func advance() { lock.withLock { time += 101 } }
}

private actor DownloadFixture {
    private var requests: [URLRequest] = []
    private var status = 200
    private var body = Data("resource-v1".utf8)
    private var offline = false
    private var shouldHold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { continuation != nil }
    var count: Int { requests.count }
    var lastRequest: URLRequest? { requests.last }

    func configure(status: Int = 200, body: String = "resource-v1", offline: Bool = false, hold: Bool = false) {
        self.status = status
        self.body = Data(body.utf8)
        self.offline = offline
        shouldHold = hold
    }
    func release() { continuation?.resume(); continuation = nil }
    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        requests.append(request)
        let status = self.status
        let body = self.body
        if offline { throw URLError(.notConnectedToInternet) }
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation = $0 }
        }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try body.write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                    headerFields: ["ETag": "fixture-etag", "Last-Modified": "Wed, 04 Nov 2026 00:00:00 GMT"])!)
    }
}

private final class FixtureDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let bytes = Data("native-http-download".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(bytes.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
private struct AssetCacheTests {
    static func main() async throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = temporary.appending(path: "Astray/StoryResources-v1")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let fixture = DownloadFixture()
        let clock = FixtureClock()
        let cache = StoryAssetCache(directory: directory, maximumAge: 100, now: { clock.now() }, download: { try await fixture.download($0) })
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let source = URL(string: "https://assets.example/jp/model/texture.png")!
        expect(try await cache.diskUsage() == 0, "An unused cache has no disk usage")
        let first = try await cache.data(at: source)
        expect(first == Data("resource-v1".utf8), "A successful download is available")
        let count = await fixture.count
        let repeated = try await cache.data(at: source)
        let afterRepeat = await fixture.count
        expect(repeated == first && afterRepeat == count, "A repeated load must not download again")
        let file = try await cache.fileURL(at: source)
        expect(file.pathExtension == "png" && file.path.hasPrefix(directory.path), "Native media gets a local file with a usable extension")
        let actualSize = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).reduce(Int64(0)) {
            try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        expect(try await cache.diskUsage() == actualSize && actualSize > first.count, "Count payload and metadata exactly once")
        let local = temporary.appending(path: "bundle-resource")
        try Data("bundled".utf8).write(to: local)
        expect(try await cache.fileURL(at: local) == local, "Bundled files are not copied into the cache")
        expect(try await cache.diskUsage() == actualSize, "Bundled resources do not inflate downloaded resource size")
        try manager.createSymbolicLink(at: directory.appending(path: "external-link"), withDestinationURL: local)
        expect(try await cache.diskUsage() == actualSize, "Do not count symlink targets")

        await fixture.configure(status: 304)
        expect(try await cache.data(at: source, revalidate: true) == first, "Mutable catalogs can revalidate even a fresh cache entry")
        expect(await fixture.count == count + 1, "Forced validation consults the server")
        clock.advance()
        await fixture.configure(status: 304)
        expect(try await cache.data(at: source) == first, "HTTP 304 retains the downloaded bytes")
        let conditional = await fixture.lastRequest
        expect(conditional?.value(forHTTPHeaderField: "If-None-Match") == "fixture-etag", "Revalidate with ETag")
        expect(conditional?.value(forHTTPHeaderField: "If-Modified-Since") != nil, "Preserve Last-Modified")
        clock.advance()
        await fixture.configure(body: "resource-v2-longer")
        expect(try await cache.data(at: source) == Data("resource-v2-longer".utf8), "A changed resource replaces its previous file")

        // Full URL identity separates regions and hosts even when filenames match.
        let regional = URL(string: "https://assets.example/cn/model/texture.png")!
        let mirror = URL(string: "https://mirror.example/jp/model/texture.png")!
        let regionalFile = try await cache.fileURL(at: regional)
        let mirrorFile = try await cache.fileURL(at: mirror)
        expect(regionalFile != file && mirrorFile != file, "Never assume regional or mirror contents are identical")
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for metadata in files where metadata.lastPathComponent.hasSuffix("metadata.json") {
            try Data("corrupt".utf8).write(to: metadata)
        }
        let beforeRepair = await fixture.count
        _ = try await cache.data(at: source)
        expect(await fixture.count == beforeRepair + 1, "Corrupt metadata cannot create a false cache hit")
        try Data("truncated".utf8).write(to: file)
        let beforeTruncation = await fixture.count
        _ = try await cache.data(at: source)
        expect(await fixture.count == beforeTruncation + 1, "A truncated payload is redownloaded")

        clock.advance()
        await fixture.configure(status: 404)
        do { _ = try await cache.data(at: source); preconditionFailure("Cached bytes masked an HTTP failure") }
        catch is AstrayError { }
        await fixture.configure(offline: true)
        expect(try await cache.data(at: source) == Data("resource-v2-longer".utf8), "Use validated bytes when offline")
        let missing = URL(string: "https://assets.example/missing.mp3")!
        do { _ = try await cache.data(at: missing); preconditionFailure("Invented an uncached offline resource") }
        catch is URLError { }

        let movie = URL(string: "https://assets.example/movie.mp4")!
        await fixture.configure(body: "movie", hold: true)
        let beforeMovie = await fixture.count
        async let firstMovie = cache.fileURL(at: movie)
        while !(await fixture.isHolding) { await Task.yield() }
        async let secondMovie = cache.fileURL(at: movie)
        await fixture.release()
        let movies = try await (firstMovie, secondMovie)
        let afterMovie = await fixture.count
        expect(movies.0 == movies.1 && afterMovie == beforeMovie + 1, "Concurrent consumers share a single download")
        // A new cache instance reuses the files after an app relaunch.
        let reopened = StoryAssetCache(directory: directory, maximumAge: 100, now: { clock.now() }, download: { _ in
            preconditionFailure("A persisted resource was fetched again")
        })
        expect(try await reopened.fileURL(at: movie) == movies.0, "Reopen the persisted movie without network access")

        await fixture.configure(hold: true)
        let slowURL = URL(string: "https://assets.example/slow.moc3")!
        let slow = Task { try await cache.fileURL(at: slowURL) }
        while !(await fixture.isHolding) { await Task.yield() }
        try await cache.clear()
        expect(try await cache.diskUsage() == 0, "Clearing removes all native resource files")
        await fixture.release()
        do { _ = try await slow.value; preconditionFailure("A cleared download wrote its result back") }
        catch is CancellationError { }
        expect(try await cache.diskUsage() == 0, "In-flight downloads cannot repopulate a cleared cache")
        expect(manager.fileExists(atPath: local.path), "Clearing preserves files outside the owned directory")
        try await cache.clear()
        await fixture.configure(body: "download-after-clear")
        expect(try await cache.data(at: source) == Data("download-after-clear".utf8), "An existing reader downloads again after clearing")
        // Exercise URLSession's actual download-to-file path with an intercepted response.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [FixtureDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let httpCache = StoryAssetCache(directory: temporary.appending(path: "HTTP"), maximumAge: 100,
            now: { clock.now() }, download: { try await session.download(for: $0) })
        expect(try await httpCache.data(at: source) == Data("native-http-download".utf8), "URLSession downloads land in the owned cache")
        expect(try await httpCache.diskUsage() > 0, "The native HTTP response contributes to disk usage")
        print("Astray cache sizes, persistence, media files, conditional refresh, regional isolation, corruption, offline reads, deduplication, and clear races passed")
    }
}
