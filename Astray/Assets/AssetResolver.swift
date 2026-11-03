public import Foundation

public enum AssetRequest: Hashable, Sendable {
    case modelManifest
    case model(directory: String, file: String)
    case motion(directory: String, base: String, kind: String, name: String)
    case resource(URL)
    case effect(String)
    case ui(String)
    case font(String)
    case scenario(String)
    case background(String)
    case character(String)
    case bgm(String)
    case sound(String)
    case voice(scenario: String, id: String)
    case movie(String)
}

public protocol AssetResolving: Sendable {
    func url(for request: AssetRequest) -> URL?
    func urls(for request: AssetRequest) -> [URL]
    func data(for request: AssetRequest) async throws -> Data?
}

extension AssetResolving {
    public func urls(for request: AssetRequest) -> [URL] { url(for: request).map { [$0] } ?? [] }
    
    public func data(for request: AssetRequest) async throws -> Data? {
        try await AssetLoader.data(from: urls(for: request))
    }
}

public struct DirectoryAssetResolver: AssetResolving {
    public let baseURL: URL
    
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }
    
    public func url(for request: AssetRequest) -> URL? {
        let directory: String
        let name: String
        let suffix: String
        switch request {
        case .modelManifest: return baseURL.appending(path: "model_manifest.json")
        case .model(let directory, let file): return relativeURL(directory.isEmpty ? file : directory + "/" + file)
        case .motion(let directory, let base, let kind, let name):
            guard Self.isComponent(name) else { return nil }
            return relativeURL("motions/" + directory + "/" + base + "/" + kind + "/" + name + ".motion3.json")
        case .resource(let url): return url
        case .effect(let path): return relativeURL("fx/" + path)
        case .ui(let path): return relativeURL("ui/" + path)
        case .font(let name): return relativeURL("fonts/" + name)
        case .scenario(let id): (directory, name, suffix) = ("scenario", id, "json")
        case .background(let id): (directory, name, suffix) = ("background", id, "png")
        case .character(let costume): (directory, name, suffix) = ("character", costume, "png")
        case .bgm(let id): (directory, name, suffix) = ("sound/bgm", id, "mp3")
        case .sound(let id): (directory, name, suffix) = ("sound/se", id, "mp3")
        case .voice(let scenario, let id):
            guard Self.isComponent(scenario) else { return nil }
            (directory, name, suffix) = ("sound/voice/\(scenario)", id, "mp3")
        case .movie(let id): (directory, name, suffix) = ("movie", id, "mp4")
        }
        guard Self.isComponent(name) else { return nil }
        return baseURL.appending(path: directory).appendingPathComponent(name + "." + suffix)
    }
    
    private func relativeURL(_ path: String) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ Self.isComponent(String($0)) }) else { return nil }
        return components.reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }
    
    private static func isComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}

internal struct AssetResult: Sendable {
    internal let request: AssetRequest
    internal let data: Data?
    internal let error: AstrayError?
}

internal enum AssetLoader {
    internal static func data(at url: URL) async throws -> Data {
        try Task.checkCancellation()
        if url.isFileURL {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw AstrayError.assetUnavailable(url, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
    
    internal static func data(from urls: [URL]) async throws -> Data? {
        var lastError: (any Error)?
        for url in urls {
            do { return try await data(at: url) } catch is CancellationError { throw CancellationError() } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }
    
    internal static func load(
        _ requests: Set<AssetRequest>,
        resolver: any AssetResolving,
        progress: @MainActor (AssetResult, Int, Int) -> Void
    ) async throws {
        let pending = Array(requests)
        try await withThrowingTaskGroup(of: AssetResult.self) { group in
            var next = 0
            var completed = 0
            func enqueue(_ request: AssetRequest) {
                group.addTask {
                    guard let url = resolver.url(for: request) else {
                        return .init(request: request, data: nil, error: nil)
                    }
                    do {
                        return .init(request: request, data: try await resolver.data(for: request), error: nil)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return .init(
                            request: request,
                            data: nil,
                            error: .assetUnavailable(url, error.localizedDescription)
                        )
                    }
                }
            }
            while next < min(6, pending.count) {
                enqueue(pending[next])
                next += 1
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                await progress(result, completed, pending.count)
                if next < pending.count {
                    enqueue(pending[next])
                    next += 1
                }
            }
        }
    }
}

extension Scenario {
    internal var assetRequests: Set<AssetRequest> {
        var result = Set<AssetRequest>()
        func insert(_ value: String, _ request: (String) -> AssetRequest) {
            if !value.isEmpty { result.insert(request(value)) }
        }
        insert(initialBackground, AssetRequest.background)
        insert(initialBGM, AssetRequest.bgm)
        for character in characters { insert(character.costume, AssetRequest.character) }
        for layout in initialLayout { insert(layout.costume, AssetRequest.character) }
        for layout in layouts { insert(layout.costume, AssetRequest.character) }
        for sound in sounds {
            insert(sound.bgm, AssetRequest.bgm)
            insert(sound.se, AssetRequest.sound)
        }
        for talk in talks {
            for voice in talk.voices {
                insert(voice.voiceID) { .voice(scenario: id, id: $0) }
            }
        }
        for effect in effects {
            if effect.type == 7 { insert(effect.value, AssetRequest.background) }
            if effect.type == 24 {
                insert(effect.secondaryValue) { .voice(scenario: id, id: $0) }
            }
        }
        if !talks.isEmpty { result.insert(.ui("serif_note.png")) }
        if effects.contains(where: { $0.type == 22 && ["hologram", "monitor", ""].contains($0.value) }) {
            result.insert(.ui("scenario/holo.png"))
        }
        if effects.contains(where: { (29...36).contains($0.type) }) {
            result.insert(.ui("scenario/tex_transition_left.png"))
            result.insert(.ui("scenario/tex_transition_top.png"))
        }
        if effects.contains(where: { $0.type == 23 }) { result.insert(.ui("scenario/btn_round_h80_wh.png")) }
        return result
    }
}
