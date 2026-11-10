internal import Foundation

/// The model-authored range and a snapshot of a Cubism parameter.
public struct ModelParameter: Identifiable, Sendable {
    public let id: String
    public let minimum: Float
    public let maximum: Float
    public let defaultValue: Float
    public let value: Float
}

public struct ModelManifestEntry: Codable, Sendable {
    public var modelDir: String
    public var modelFile: String
    public var motionDir: String
    public var motionBase: String
    
    public init(modelDir: String, modelFile: String, motionDir: String = "", motionBase: String = "") {
        self.modelDir = modelDir
        self.modelFile = modelFile
        self.motionDir = motionDir
        self.motionBase = motionBase
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelDir = try values.decode(String.self, forKey: .modelDir)
        modelFile = try values.decode(String.self, forKey: .modelFile)
        motionDir = try values.decodeIfPresent(String.self, forKey: .motionDir) ?? ""
        motionBase = try values.decodeIfPresent(String.self, forKey: .motionBase) ?? ""
    }
    
    private enum CodingKeys: String, CodingKey { case modelDir, modelFile, motionDir, motionBase }
}

internal struct Live2DAssets: Sendable {
    internal let moc: Data
    internal let physics: Data?
    internal let pose: Data?
    internal let textures: [Data]
    internal var motions: [String: Data]
    internal var facials: [String: Data]
}

internal enum Live2DAssetLoader {
    internal static func load(
        scenario: Scenario,
        resolver: any AssetResolving,
        progress: @MainActor (Int, Int) -> Void = { _, _ in },
        warning: @MainActor (AstrayError) -> Void
    ) async throws -> [String: Live2DAssets] {
        var costumes: [String: Int] = [:]
        for character in scenario.characters { costumes[character.costume] = character.characterID }
        for layout in scenario.initialLayout { costumes[layout.costume] = layout.characterID }
        for layout in scenario.layouts where !layout.costume.isEmpty { costumes[layout.costume] = layout.characterID }
        costumes.removeValue(forKey: "")
        guard !costumes.isEmpty else { return [:] }
        let manifest: [String: ModelManifestEntry]
        do {
            guard let data = try await resolver.data(for: .modelManifest) else { return [:] }
            manifest = try JSONDecoder().decode([String: ModelManifestEntry].self, from: data)
        } catch is CancellationError { throw CancellationError() } catch { return [:] }
        var output: [String: Live2DAssets] = [:]
        for (offset, pair) in costumes.sorted(by: { $0.key < $1.key }).enumerated() {
            await progress(offset, costumes.count)
            let (costume, characterID) = pair
            try Task.checkCancellation()
            guard let entry = manifest[costume],
                let modelURL = resolver.url(for: .model(directory: entry.modelDir, file: entry.modelFile))
            else { continue }
            do {
                guard let data = try await resolver.data(for: .model(directory: entry.modelDir, file: entry.modelFile))
                else { continue }
                let settings = try JSONDecoder().decode(EffectValue.self, from: data)
                let references = settings["FileReferences"]
                func resource(_ path: String) async throws -> Data {
                    guard !path.isEmpty, let relative = URL(string: path, relativeTo: modelURL)?.absoluteURL,
                        let url = resolver.url(for: .resource(relative))
                    else {
                        throw AstrayError.assetUnavailable(modelURL, "Missing model resource: \(path)")
                    }
                    guard let data = try await resolver.data(for: .resource(relative)) else {
                        throw AstrayError.assetUnavailable(url, "Missing model resource: \(path)")
                    }
                    return data
                }
                async let moc = resource(references["Moc"].string)
                async let physics: Data? =
                    references["Physics"].string.isEmpty ? nil : resource(references["Physics"].string)
                async let pose: Data? = references["Pose"].string.isEmpty ? nil : resource(references["Pose"].string)
                let textures = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for (index, texture) in references["Textures"].array.enumerated() {
                        group.addTask { (index, try await resource(texture.string)) }
                    }
                    var loaded: [Int: Data] = [:]
                    for try await (index, data) in group { loaded[index] = data }
                    return loaded.sorted { $0.key < $1.key }.map(\.value)
                }
                var motions: [String: Data] = [:]
                var facials: [String: Data] = [:]
                var motionNames: Set<String> = []
                var facialNames: Set<String> = []
                for layout in scenario.initialLayout where layout.characterID == characterID {
                    motionNames.insert(layout.motion); facialNames.insert(layout.facial)
                }
                for layout in scenario.layouts where layout.characterID == characterID {
                    motionNames.insert(layout.motion); facialNames.insert(layout.facial)
                }
                for talk in scenario.talks {
                    for motion in talk.motions where motion.characterID == characterID {
                        motionNames.insert(motion.motion); facialNames.insert(motion.facial)
                    }
                }
                for (group, clips) in references["Motions"].object {
                    for (index, clip) in clips.array.enumerated() {
                        let name = clip["Name"].string.isEmpty ? "\(group)_\(index)" : clip["Name"].string
                        motions[name] = try await resource(clip["File"].string)
                    }
                }
                for clip in references["Expressions"].array {
                    facials[clip["Name"].string] = try await resource(clip["File"].string)
                }
                for (kind, names) in [("motion", motionNames), ("facial", facialNames)] {
                    for name in names where !name.isEmpty {
                        guard
                            let url = resolver.url(
                                for: .motion(directory: entry.motionDir, base: entry.motionBase, kind: kind, name: name)
                            )
                        else { continue }
                        do {
                            guard
                                let data = try await resolver.data(
                                    for: .motion(
                                        directory: entry.motionDir,
                                        base: entry.motionBase,
                                        kind: kind,
                                        name: name
                                    )
                                )
                            else { continue }
                            if kind == "motion" { motions[name] = data } else { facials[name] = data }
                        } catch is CancellationError { throw CancellationError() } catch {
                            await warning(.assetUnavailable(url, error.localizedDescription))
                        }
                    }
                }
                output[costume] = try await .init(
                    moc: moc,
                    physics: physics,
                    pose: pose,
                    textures: textures,
                    motions: motions,
                    facials: facials
                )
            } catch is CancellationError { throw CancellationError() } catch {
                await warning(.assetUnavailable(modelURL, error.localizedDescription))
            }
        }
        await progress(costumes.count, costumes.count)
        return output
    }
}
