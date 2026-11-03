internal import Foundation

@MainActor
internal final class EffectRuntime {
    private let player: StoryPlayer
    private var instances: [Instance] = []
    private var generation = -1
    private var assetRevision = -1
    private var commandCount = 0
    private var lastTime: Double = 0
    private var background = ""
    private var characterEffects: [Int: String] = [:]
    private var backgroundMeshes: [(String, EffectMesh)] = []
    private var layerMeshes: [EffectLayer: [(String, EffectMesh)]] = [:]
    
    internal init(player: StoryPlayer) { self.player = player }
    
    internal func update() {
        let restoring = generation != player.renderRevision
        if restoring || assetRevision != player.assetRevision {
            if assetRevision == player.assetRevision && background == player.stage.background {
                instances = instances.filter(\.isBackground)
                for instance in instances { instance.startedAt = 0 }
            } else {
                instances = []
                background = ""
            }
            characterEffects = [:]
            commandCount = 0
            generation = player.renderRevision
            assetRevision = player.assetRevision
            lastTime = 0
            if player.isRestoringEffects {
                for name in player.stage.effects { play(name, settle: true) }
                commandCount = player.effectCommands.count
            }
        }
        if background != player.stage.background {
            for instance in instances where instance.isBackground { instance.effect.forceStop() }
            background = player.stage.background
            play("bg/" + background, isBackground: true, startedAt: player.stage.backgroundTime)
        }
        if commandCount < player.effectCommands.count {
            for command in player.effectCommands[commandCount...] {
                if command.isPlaying {
                    play(command.name, startedAt: command.time, lifetime: command.lifetime)
                } else {
                    for instance in instances
                    where instance.name == command.name && instance.characterID == nil && !instance.isBackground {
                        if player.isFastForwarding { instance.effect.forceStop() } else { instance.effect.stop() }
                    }
                }
            }
            commandCount = player.effectCommands.count
        }
        for character in player.stage.characters.values {
            let bundle = character.shader == "hologram" ? character.effectBundle : ""
            if characterEffects[character.id, default: ""] != bundle {
                for instance in instances where instance.characterID == character.id { instance.effect.forceStop() }
                if !bundle.isEmpty {
                    play("hologram", characterID: character.id, settle: restoring && player.isRestoringEffects)
                }
                characterEffects[character.id] = bundle
            }
        }
        let delta = max(0, player.visualTime - lastTime)
        for instance in instances {
            if let id = instance.characterID {
                guard let character = player.stage.characters[id] else { instance.effect.forceStop(); continue }
                instance.effect.origin = .init(
                    Double((character.x - 0.5 + character.shake.x) * 1920),
                    -540 - Double(character.shake.y * 1080),
                    0
                )
                instance.effect.originScale = 1080 / 1024 * Double(character.scale)
                instance.effect.pivotY = 0
                instance.effect.isVisible = character.opacity > 0.01
            }
            if let lifetime = instance.lifetime, player.visualTime - instance.startedAt >= lifetime {
                instance.effect.stop()
            }
            var remaining = min(delta, max(0, player.visualTime - instance.startedAt))
            if !instance.hasUpdated { instance.effect.update(0); instance.hasUpdated = true }
            while remaining > 1e-8 {
                let step = min(1.0 / 30, remaining)
                instance.effect.update(step)
                remaining -= step
            }
        }
        lastTime = player.visualTime
        instances.removeAll { $0.effect.state == .dead }
        backgroundMeshes.removeAll(keepingCapacity: true)
        layerMeshes.removeAll(keepingCapacity: true)
        for instance in instances {
            for mesh in instance.effect.meshes() {
                if instance.isBackground {
                    backgroundMeshes.append((instance.name, mesh))
                } else {
                    layerMeshes[mesh.layer, default: []].append((instance.name, mesh))
                }
            }
        }
        func ordered(_ lhs: (String, EffectMesh), _ rhs: (String, EffectMesh)) -> Bool {
            lhs.1.order != rhs.1.order ? lhs.1.order < rhs.1.order : lhs.1.sequence < rhs.1.sequence
        }
        backgroundMeshes.sort(by: ordered)
        for layer in layerMeshes.keys { layerMeshes[layer]?.sort(by: ordered) }
    }
    
    internal func meshes(layer: EffectLayer, backgroundOnly: Bool = false) -> [(String, EffectMesh)] {
        backgroundOnly ? backgroundMeshes : layerMeshes[layer, default: []]
    }
    
    private func play(
        _ name: String,
        characterID: Int? = nil,
        isBackground: Bool = false,
        settle: Bool = false,
        startedAt: Double? = nil,
        lifetime: Double? = nil
    ) {
        guard let assets = player.prefabAssets[name] else { return }
        do {
            let effect = try PrefabEffect(document: assets.document)
            if settle { effect.settle() }
            instances.append(
                .init(
                    name: name,
                    effect: effect,
                    characterID: characterID,
                    isBackground: isBackground,
                    startedAt: startedAt ?? player.visualTime,
                    lifetime: lifetime
                )
            )
        } catch { player.onEvent?(.warning(.renderingFailed(error.localizedDescription))) }
    }
    
    private final class Instance {
        internal let name: String
        internal let effect: PrefabEffect
        internal let characterID: Int?
        internal let isBackground: Bool
        internal var startedAt: Double
        internal let lifetime: Double?
        internal var hasUpdated = false
        
        internal init(
            name: String,
            effect: PrefabEffect,
            characterID: Int?,
            isBackground: Bool,
            startedAt: Double,
            lifetime: Double?
        ) {
            self.name = name
            self.effect = effect
            self.characterID = characterID
            self.isBackground = isBackground
            self.startedAt = startedAt
            self.lifetime = lifetime
        }
    }
}
