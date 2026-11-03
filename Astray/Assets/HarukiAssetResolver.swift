public import Foundation

public struct HarukiAssetResolver: AssetResolving {
    public static func japaneseAssetRoot(for url: URL) -> URL? {
        let regions: Set<String> = ["jp-assets", "cn-assets", "en-assets", "tw-assets", "tc-assets", "kr-assets"]
        let parts = url.pathComponents.filter { $0 != "/" }
        let prefix: [String]
        if let index = parts.firstIndex(where: regions.contains) {
            prefix = Array(parts[..<index])
        } else if url.host?.hasPrefix("sekai-assets") == true {
            prefix = []
        } else {
            return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = "/" + (prefix + ["jp-assets"]).joined(separator: "/") + "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }
    
    public let baseURL: URL
    private let index: Index
    private let manifest: Data
    private let scenario: Scenario
    private let eventBundle: String?
    private let partVoices: [String: [String]]
    
    public init(baseURL: URL, scenario: Scenario) async throws {
        guard let root = Self.japaneseAssetRoot(for: baseURL) else {
            throw AstrayError.invalidScenario("A Haruki asset URL must identify a region asset tree.")
        }
        let data = try await AssetLoader.data(at: root.appending(path: "story-player/index.json"))
        let index = try JSONDecoder().decode(Index.self, from: data)
        var eventBundle: String?
        var partVoices: [String: [String]] = [:]
        if !root.isFileURL {
            if scenario.id.hasPrefix("event_"),
                scenario.sounds.contains(where: { !$0.se.isEmpty && index.se[$0.se] == nil })
            {
                let stories = try await Self.master("eventStories")
                eventBundle =
                    stories.array.first { story in
                        story["episodes"].array.contains { $0["scenarioId"].string == scenario.id }
                    }?["assetbundleName"].string
            }
            let voices = scenario.talks.flatMap(\.voices).filter { $0.voiceID.hasPrefix("partvoice") }
            if !voices.isEmpty {
                let characters = try await Self.master("character2ds")
                for voice in voices {
                    guard let character = characters.array.first(where: { Int($0["id"].number()) == voice.characterID })
                    else { continue }
                    let asset = character["assetName"].string
                    let unit = ["", "none"].contains(character["unit"].string) ? "piapro" : character["unit"].string
                    guard Self.isComponent(asset), Self.isComponent(unit) else { continue }
                    var directories: [String] = []
                    if !asset.hasPrefix("v2_") {
                        directories.append("startapp/sound/scenario/voice/part_voice_v2_\(asset)_\(unit)")
                    }
                    directories += [
                        "startapp/sound/scenario/voice/part_voice_\(asset)_\(unit)",
                        "startapp/sound/scenario/voice/part_voice_\(asset)",
                        "tutorial/sound/scenario/part_voice/\(asset)_\(unit)",
                    ]
                    partVoices[voice.voiceID] = directories
                }
            }
        }
        self.baseURL = root
        self.index = index
        self.scenario = scenario
        self.eventBundle = eventBundle
        self.partVoices = partVoices
        manifest = try JSONEncoder().encode(
            index.models.mapValues { entry in
                ModelManifestEntry(
                    modelDir: entry.dir,
                    modelFile: entry.model3,
                    motionDir: entry.dir,
                    motionBase: entry.motionBase ?? ""
                )
            }
        )
    }
    
    public func url(for request: AssetRequest) -> URL? { urls(for: request).first }
    
    public func urls(for request: AssetRequest) -> [URL] {
        switch request {
        case .modelManifest: return paths(["story-player/index.json"])
        case .model(let directory, let file): return paths([directory + "/" + file])
        case .motion(let directory, let base, let kind, let name):
            guard Self.isComponent(name), ["motion", "facial"].contains(kind) else { return [] }
            let clip = name.lowercased()
            if kind == "motion", let model = index.models.values.first(where: { $0.dir == directory }) {
                let parent = directory.split(separator: "/").dropLast().joined(separator: "/") + "/"
                let owner =
                    model.motions?.contains(clip) == true
                    ? model
                    : index.models.sorted { $0.key < $1.key }.first { _, entry in
                        entry.dir.hasPrefix(parent) && entry.motions?.contains(clip) == true
                    }?.value
                if let owner { return paths([owner.dir + "/motions/" + clip + ".motion3.json"]) }
            }
            return base.isEmpty ? [] : paths([base + "/" + kind + "/" + clip + ".motion3.json"])
        case .resource(let url): return [url]
        case .effect(let file): return paths(["story-player/v1/fx/" + file])
        case .ui(let file): return paths(["story-player/v1/ui/" + file])
        case .font(let file): return paths(["story-player/v1/fonts/" + file])
        case .character: return []
        case .scenario(let path):
            guard path.contains("/") else { return [] }
            return paths([path.hasSuffix(".json") ? path : path + ".json"])
        case .voice(let episode, let voice):
            guard Self.isComponent(episode), Self.isComponent(voice) else { return [] }
            var directories = [
                "ondemand/sound/scenario/voice", "ondemand/sound/card_scenario/voice", "startapp/sound/scenario/voice",
            ]
            if episode.hasPrefix("card_") { directories.swapAt(0, 1) }
            if episode.hasPrefix("areatalk_") { directories.insert("additionalvoice/sound/actionset/voice", at: 0) }
            let shared = directories.map { $0 + "/" + episode + "/" + voice + ".mp3" }
            return paths(partVoices[voice, default: []].map { $0 + "/" + voice + ".mp3" } + shared)
        case .bgm(let id):
            guard Self.isComponent(id) else { return [] }
            return paths(["ondemand/sound/scenario/bgm/\(id)/\(id).mp3", "startapp/sound/scenario/bgm/\(id)/\(id).mp3"])
        case .sound(let id):
            guard Self.isComponent(id) else { return [] }
            if let file = index.se[id] { return paths([file]) }
            if let eventBundle { return paths(["ondemand/event_story/\(eventBundle)/scenario_se/\(id).mp3"]) }
            let bundles = scenario.sounds.filter { $0.se == id && !$0.seBundle.isEmpty }.map(\.seBundle)
            return paths(bundles.map { "ondemand/" + $0 + "/" + id + ".mp3" })
        case .background(let id):
            guard Self.isComponent(id) else { return [] }
            return paths([
                "ondemand/scenario/background/\(id)/\(id).png", "startapp/scenario/background/\(id)/\(id).png",
                "ondemand/scenario/background/\(id)/scenariobgdata.assets/texture2d/\(id).png",
            ])
        case .movie(let name): return index.movies[name].map { paths([$0]) } ?? []
        }
    }
    
    public func data(for request: AssetRequest) async throws -> Data? {
        if request == .modelManifest { return manifest }
        guard let data = try await AssetLoader.data(from: urls(for: request)) else { return nil }
        if case .model(let directory, let file) = request,
            let entry = index.models.values.first(where: { $0.dir == directory && $0.model3 == file })
        {
            var model = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var references = model["FileReferences"] as? [String: Any] ?? [:]
            references["Physics"] = entry.physics
            model["FileReferences"] = references
            return try JSONSerialization.data(withJSONObject: model)
        }
        return data
    }
    
    private func paths(_ values: [String]) -> [URL] {
        values.compactMap { path in
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ Self.isComponent(String($0)) }) else { return nil }
            return components.reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        }
    }
    
    private static func isComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
    
    private static func master(_ name: String) async throws -> EffectValue {
        let urls = [
            URL(string: "https://sekai-api-cdn.haruki.seiunx.com/v1/master/jp/files/\(name).json")!,
            URL(string: "https://raw.githubusercontent.com/Team-Haruki/haruki-sekai-master/main/master/\(name).json")!,
        ]
        let data = try await AssetLoader.data(from: urls)!
        return try JSONDecoder().decode(EffectValue.self, from: data)
    }
    
    private struct Index: Decodable, Sendable {
        internal let models: [String: Model]
        internal let movies: [String: String]
        internal let se: [String: String]
    }
    
    private struct Model: Decodable, Sendable {
        internal let dir: String
        internal let model3: String
        internal let physics: String?
        internal let motionBase: String?
        internal let motions: [String]?
    }
}
