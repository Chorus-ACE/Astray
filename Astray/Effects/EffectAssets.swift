internal import Foundation

internal struct PrefabAssets: Sendable {
    internal let document: EffectValue
    internal let textures: [String: Data]
}

internal struct EffectCommand: Sendable {
    internal let name: String
    internal let isPlaying: Bool
    internal let time: Double
    internal var lifetime: Double? = nil
}

internal enum EffectAssetLoader {
    internal static func load(
        scenario: Scenario,
        resolver: any AssetResolving,
        warning: @MainActor (AstrayError) -> Void
    ) async throws -> [String: PrefabAssets] {
        var names: Set<String> = []
        var backgrounds: Set<String> = []
        if !scenario.initialBackground.isEmpty { backgrounds.insert(scenario.initialBackground) }
        for effect in scenario.effects {
            switch effect.type {
            case 7: backgrounds.insert(effect.value)
            case 15: names.insert(effect.value)
            case 21: names.insert("sekai_transition")
            case 41: names.insert("sekai_transition_3anv")
            case 22 where ["hologram", ""].contains(effect.value) && !effect.secondaryValue.isEmpty:
                names.insert("hologram")
            default: break
            }
        }
        if !backgrounds.isEmpty, resolver.url(for: .effect("bg/index.json")) != nil {
            do {
                if let data = try await resolver.data(for: .effect("bg/index.json")) {
                    let index = try JSONDecoder().decode([String].self, from: data)
                    for name in backgrounds.intersection(index) { names.insert("bg/" + name) }
                }
            } catch is CancellationError { throw CancellationError() } catch {}
        }
        var result: [String: PrefabAssets] = [:]
        for name in names where !name.isEmpty {
            try Task.checkCancellation()
            guard let url = resolver.url(for: .effect(name + "/effect.json")) else { continue }
            do {
                guard let data = try await resolver.data(for: .effect(name + "/effect.json")) else { continue }
                let document = try JSONDecoder().decode(EffectValue.self, from: data)
                _ = try PrefabEffect(document: document)
                var files: Set<String> = []
                for node in document["nodes"].array {
                    if !node["ps"].isNull {
                        let file = document["materials"][node["psr"]["materials"][0].string]["tex"]["_MainTex"]["file"]
                            .string
                        if !file.isEmpty { files.insert(file) }
                    }
                    let key = !node["image"].isNull ? node["image"]["sprite"].string : node["sprite"]["sprite"].string
                    let texture = document["sprites"][key]["tex"].string
                    if !texture.isEmpty { files.insert(texture) }
                }
                var textures: [String: Data] = [:]
                for file in files {
                    guard let textureURL = resolver.url(for: .effect(name + "/" + file)) else { continue }
                    do {
                        textures[file] = try await resolver.data(for: .effect(name + "/" + file))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch { await warning(.assetUnavailable(textureURL, error.localizedDescription)) }
                }
                result[name] = .init(document: document, textures: textures)
            } catch is CancellationError { throw CancellationError() } catch {
                await warning(.assetUnavailable(url, error.localizedDescription))
            }
        }
        return result
    }
}
