public import Foundation
internal import Observation

@MainActor
@Observable
public final class StoryPlayer {
    public private(set) var status: PlaybackStatus = .idle
    public private(set) var scenario: Scenario?
    public private(set) var stage = StageState()
    public private(set) var dialogue = DialogueState()
    public private(set) var snippetIndex: Int = 0
    public private(set) var elapsedTime: Double = 0
    public private(set) var visualTime: Double = 0
    public private(set) var assetRevision: Int = 0
    public var isAutomatic: Bool = false
    public var isFastForwarding: Bool = false {
        didSet { if isFastForwarding { audio.stop(.voice) } }
    }
    public var isDialogueHidden: Bool = false
    public var onEvent: (@MainActor (PlayerEvent) -> Void)?
    @ObservationIgnored internal let movie = MovieController()
    @ObservationIgnored private var movieAssets: [String: MovieAsset] = [:]
    @ObservationIgnored internal var prefabAssets: [String: PrefabAssets] = [:]
    @ObservationIgnored internal var effectCommands: [EffectCommand] = []
    @ObservationIgnored internal var isRestoringEffects = false
    @ObservationIgnored internal var live2DAssets: [String: Live2DAssets] = [:]
    @ObservationIgnored internal var assets: [AssetRequest: Data] = [:]
    @ObservationIgnored private let audio = AudioController()
    @ObservationIgnored private var active: [RunningSnippet] = []
    @ObservationIgnored private var animations: [String: Animation] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextSnippet = 0
    @ObservationIgnored private var lastTimestamp: Double?
    @ObservationIgnored private var currentTalk: Int?
    @ObservationIgnored private var captionOwner: Int?
    @ObservationIgnored private var choiceOwner: Int?
    @ObservationIgnored private var bgm = ""
    @ObservationIgnored private var bgmGain: Float = 1
    @ObservationIgnored private var speakingCharacters: [Int] = []
    @ObservationIgnored private var talkLipSync: Int = 0
    @ObservationIgnored private var talkLipSyncScale: Float = 1
    @ObservationIgnored private var textMouthStartedAt: Double = 0
    @ObservationIgnored private var textMouthDuration: Double = 0
    @ObservationIgnored private var fullScreenCapacity = 8
    @ObservationIgnored private var characterShaders: [Int: CharacterShader] = [:]
    @ObservationIgnored internal var motionIsPlaying: ((Int) -> Bool)?
    @ObservationIgnored private var screenShakeIsEndless = false
    @ObservationIgnored private var screenShake: EffectShake?
    @ObservationIgnored private var windowShake: EffectShake?
    @ObservationIgnored private var screenShakeStart: Double = 0
    @ObservationIgnored private var windowShakeStart: Double = 0
    @ObservationIgnored private var shakeScreenUntil: Double = 0
    @ObservationIgnored private var shakeWindowUntil: Double = 0
    @ObservationIgnored private var placePhase: PlacePhase = .hidden
    @ObservationIgnored private var placeCloseReserved = false
    
    public init() {
        audio.onError = { [weak self] error in
            self?.onEvent?(.warning(.audioPlaybackFailed(error.localizedDescription)))
        }
    }
    
    internal var renderRevision: Int { generation }
    
    public var transcript: [TranscriptLine] { scenario?.transcript ?? [] }
    
    public func load(id: String, resolver: any AssetResolving) async throws {
        guard let url = resolver.url(for: .scenario(id)) else {
            throw AstrayError.invalidScenario("The resolver returned no URL for scenario \(id).")
        }
        reset()
        status = .loading
        let token = generation
        do {
            guard let data = try await resolver.data(for: .scenario(id)) else {
                throw AstrayError.assetUnavailable(url, "Missing scenario data.")
            }
            guard token == generation else { throw CancellationError() }
            try await load(Scenario.decode(data), resolver: resolver)
        } catch {
            if token == generation { status = error is CancellationError ? .idle : .failed }
            throw error
        }
    }
    
    public func load(data: Data, resolver: (any AssetResolving)? = nil) async throws {
        try await load(Scenario.decode(data), resolver: resolver)
    }
    
    public func load(_ scenario: Scenario, resolver: (any AssetResolving)? = nil) async throws {
        try scenario.validate()
        reset()
        status = .loading
        self.scenario = scenario
        assets.removeAll()
        live2DAssets.removeAll()
        prefabAssets.removeAll()
        movieAssets.removeAll()
        assetRevision += 1
        let token = generation
        do {
            if let resolver {
                let models = try await Live2DAssetLoader.load(scenario: scenario, resolver: resolver) {
                    [weak self] warning in
                    guard let self, self.generation == token else { return }
                    self.onEvent?(.warning(warning))
                }
                guard token == generation else { throw CancellationError() }
                live2DAssets = models
                let prefabs = try await EffectAssetLoader.load(scenario: scenario, resolver: resolver) {
                    [weak self] warning in
                    guard let self, self.generation == token else { return }
                    self.onEvent?(.warning(warning))
                }
                guard token == generation else { throw CancellationError() }
                prefabAssets = prefabs
                let movies = try await MovieAssetLoader.load(scenario: scenario, resolver: resolver) {
                    [weak self] warning in
                    guard let self, self.generation == token else { return }
                    self.onEvent?(.warning(warning))
                }
                guard token == generation else { throw CancellationError() }
                movieAssets = movies
                let requests = scenario.assetRequests.filter { request in
                    if case .character(let costume) = request { return models[costume] == nil }
                    return true
                }
                try await AssetLoader.load(requests, resolver: resolver) { [weak self] result, count, total in
                    guard let self, self.generation == token else { return }
                    self.assets[result.request] = result.data
                    if let error = result.error {
                        switch result.request {
                        case .ui, .font: break
                        default: self.onEvent?(.warning(error))
                        }
                    }
                    self.onEvent?(.loadProgress(completed: count, total: total))
                }
            }
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            assetRevision += 1
            restoreInitialState()
            status = .ready
            onEvent?(.ready)
        } catch {
            if token == generation { status = error is CancellationError ? .idle : .failed }
            throw error
        }
    }
    
    public func play() {
        guard [.ready, .paused].contains(status) else { return }
        status = .playing
        lastTimestamp = nil
        if !bgm.isEmpty && !audio.hasBGM { playBGM(bgm, duration: 0) }
        audio.resume()
        movie.resume()
    }
    
    public func pause() {
        guard status == .playing else { return }
        status = .paused
        lastTimestamp = nil
        audio.pause()
        movie.pause()
    }
    
    public func stop() {
        reset()
        restoreInitialState()
        status = scenario == nil ? .idle : .ready
    }
    
    public func advance() {
        guard status == .playing else { return }
        if isDialogueHidden {
            isDialogueHidden = false
            return
        }
        if let owner = currentTalk, let running = active.first(where: { $0.index == owner }) {
            if dialogue.isTyping {
                running.revealed = dialogue.body.count
                dialogue.visibleCharacters = running.revealed
                dialogue.isTyping = false
                running.holdElapsed = 0
                running.typingSkipped = true
            } else if running.isFullScreenText && running.fullScreenVoiceFinishedAt == nil {
                running.voiceWaitSkipped = true
            } else {
                running.dismissed = true
            }
        } else if let owner = captionOwner,
            let running = active.first(where: { $0.index == owner }),
            elapsedTime - running.startedAt >= 0.333
        {
            running.dismissed = true
        }
    }
    
    public func selectChoice(at index: Int) {
        guard status == .playing, stage.choices.indices.contains(index), let owner = choiceOwner else { return }
        let value = stage.choices[index]
        guard let running = active.first(where: { $0.index == owner }), !running.dismissed,
            elapsedTime - running.startedAt >= 0.125
        else { return }
        running.dismissed = true
        onEvent?(.selected(index: index, value: value))
    }
    
    public func setVolume(bgm: Float = 0.7, voice: Float = 1, sound: Float = 1) {
        audio.bgmVolume = bgm.isFinite ? max(0, min(1, bgm)) : 0.7
        audio.voiceVolume = voice.isFinite ? max(0, min(1, voice)) : 1
        audio.soundVolume = sound.isFinite ? max(0, min(1, sound)) : 1
    }
    
    public func jump(to index: Int) throws {
        guard let scenario, (0...scenario.snippets.count).contains(index), status != .loading else {
            throw AstrayError.invalidJump(index)
        }
        let wasPaused = status == .paused
        reset()
        isRestoringEffects = true
        restoreInitialState()
        for position in 0..<index {
            let snippet = scenario.snippets[position]
            apply(snippet, position: position, restoring: true)
        }
        nextSnippet = index
        snippetIndex = index
        if !bgm.isEmpty { playBGM(bgm, duration: 0) }
        status = wasPaused ? .paused : .playing
        if wasPaused { audio.pause() }
        onEvent?(.progress(index: index, total: scenario.snippets.count))
    }
    
    public func update(at timestamp: Double) {
        guard timestamp.isFinite else { return }
        let delta = lastTimestamp.map { min(0.1, max(0, timestamp - $0)) } ?? 0
        lastTimestamp = timestamp
        advance(by: delta)
    }
    
    /// Advances the shared timeline, independent of a display or wall clock.
    public func advance(by deltaTime: Double) {
        guard deltaTime.isFinite, deltaTime > 0, status == .playing || status == .finished else { return }
        let token = generation
        var remaining = deltaTime
        while remaining > 0.0000001, status == .playing || status == .finished, generation == token {
            let step = min(1.0 / 60, remaining)
            tick(step * (isFastForwarding ? 3 : 1), realDelta: step)
            remaining -= step
        }
    }
    
    private func reset() {
        generation += 1
        effectCommands.removeAll()
        isRestoringEffects = false
        active.removeAll()
        animations.removeAll()
        audio.stop()
        movie.stop()
        nextSnippet = 0
        snippetIndex = 0
        elapsedTime = 0
        visualTime = 0
        lastTimestamp = nil
        currentTalk = nil
        captionOwner = nil
        choiceOwner = nil
        speakingCharacters = []
        characterShaders = [:]
        textMouthDuration = 0
        fullScreenCapacity = 8
        shakeScreenUntil = 0
        shakeWindowUntil = 0
        screenShake = nil
        windowShake = nil
        placePhase = .hidden
        placeCloseReserved = false
        dialogue = .init()
    }
    
    private func restoreInitialState() {
        stage = .init()
        guard let scenario else { return }
        stage.background = scenario.initialBackground
        stage.layoutMode = scenario.initialLayoutMode
        bgm = scenario.initialBGM
        bgmGain = 1
        for layout in scenario.initialLayout {
            var character = CharacterState(id: layout.characterID)
            character.costume = layout.costume
            character.side = layout.side
            character.offsetX = layout.offsetX
            character.x = sidePosition(layout.side, mode: stage.layoutMode, offset: layout.offsetX)
            character.scale = stage.layoutMode == 3 ? 0.9 : 1
            character.motion = layout.motion
            character.facial = layout.facial
            stage.characters[layout.characterID] = character
        }
    }
    
    private func tick(_ delta: Double, realDelta: Double) {
        guard let scenario else { return }
        let token = generation
        elapsedTime += delta
        visualTime += realDelta
        audio.tick(delta)
        guard token == generation else { return }
        for (key, animation) in Array(animations) {
            animation.elapsed += delta
            let isComplete = animation.elapsed >= animation.duration
            if isComplete { animations.removeValue(forKey: key) }
            // Reserve 1 for completion so Float rounding cannot fire callbacks twice.
            let fraction: Float = isComplete ? 1 : min(Float(1).nextDown, Float(animation.elapsed / animation.duration))
            animation.update(fraction)
            guard token == generation else { return }
        }
        if status == .finished {
            updateAmbientState(delta: delta)
            return
        }
        for running in active {
            running.elapsed += delta
            if !running.started && running.elapsed >= running.snippet.delay {
                running.started = true
                running.startedAt = elapsedTime
                running.duration = apply(running.snippet, position: running.index, restoring: false)
                if token != generation { return }
            }
            guard running.started else { continue }
            let age = elapsedTime - running.startedAt
            if running.isMovie {
                updateMovie(running, age: age)
            } else if running.isFullScreenText {
                updateFullScreenText(running, age: age, delta: delta)
            } else if running.snippet.action == .talk {
                updateTalk(running, age: age, delta: delta)
            } else if running.isCaption {
                updateCaption(running, age: age)
            } else if running.isChoice {
                stage.choiceScale = Float(min(1, age / 0.125))
                if running.dismissed {
                    if running.exitAt == nil { running.exitAt = age }
                    let closing = age - running.exitAt!
                    stage.choiceScale = Float(max(0, 1 - closing / 0.125))
                    if closing >= 0.625 {
                        running.finished = true
                        stage.choices = []
                        choiceOwner = nil
                    }
                }
            } else {
                let interrupted =
                    running.animationKey.map { key in
                        running.animationObject != nil && animations[key] !== running.animationObject
                    } ?? false
                running.finished = age >= running.duration || interrupted
            }
        }
        active.removeAll { $0.finished }
        updateAmbientState(delta: delta)
        if nextSnippet < scenario.snippets.count {
            let snippet = scenario.snippets[nextSnippet]
            if snippet.progressBehavior == .now || active.isEmpty {
                let index = nextSnippet
                nextSnippet += 1
                snippetIndex = index
                active.append(.init(index: index, snippet: snippet))
                onEvent?(.progress(index: index, total: scenario.snippets.count))
                if token != generation { return }
            }
        } else if active.isEmpty {
            status = .finished
            audio.stop(.voice)
            onEvent?(.finished)
        }
    }
    
    @discardableResult
    private func apply(_ snippet: ScenarioSnippet, position: Int, restoring: Bool) -> Double {
        guard let scenario else { return 0 }
        switch snippet.action {
        case .none: break
        case .talk:
            let talk = scenario.talks[snippet.referenceIndex]
            if restoring {
                for motion in talk.motions { applyMotion(motion) }
            } else {
                beginTalk(talk, position: position)
            }
        case .characterLayout:
            return applyLayout(scenario.layouts[snippet.referenceIndex], restoring: restoring)
        case .characterMotion:
            let layout = scenario.layouts[snippet.referenceIndex]
            applyMotion(.init(characterID: layout.characterID, motion: layout.motion, facial: layout.facial))
        case .sound:
            applySound(scenario.sounds[snippet.referenceIndex], restoring: restoring)
        case .specialEffect:
            return applyEffect(scenario.effects[snippet.referenceIndex], position: position, restoring: restoring)
        case .characterLayoutMode:
            stage.layoutMode = scenario.layoutModes[snippet.referenceIndex].mode
            for id in stage.characters.keys {
                guard let character = stage.characters[id] else { continue }
                animations.removeValue(forKey: "character.\(id).x")
                stage.characters[id]?.offsetX = 0
                stage.characters[id]?.x = sidePosition(character.side, mode: stage.layoutMode, offset: 0)
                stage.characters[id]?.scale = stage.layoutMode == 3 ? 0.9 : 1
            }
        case .inputName, .selectable:
            if !restoring {
                onEvent?(
                    .unsupportedAction(
                        snippetIndex: position,
                        action: snippet.action,
                        detail: "This action's game data schema is not available. Use SimpleSelectable for choices."
                    )
                )
            }
        }
        return 0
    }
    
    private func beginTalk(_ talk: ScenarioTalk, position: Int, fullScreen: Bool = false) {
        audio.stop(.voice)
        currentTalk = position
        speakingCharacters = talk.lipSync == 1 ? talk.voices.map(\.characterID) : talk.characters.map(\.characterID)
        talkLipSync = talk.lipSync
        let scale = Float(talk.lipSyncScale)
        talkLipSyncScale = scale.isFinite && scale > 0 ? scale : 1
        let opensWindow = !dialogue.isVisible || dialogue.isFullScreen
        active.first(where: { $0.index == position })?.talkOpenDelay = opensWindow ? 0.2 : 0
        textMouthStartedAt = elapsedTime + (opensWindow ? 0.2 : 0)
        textMouthDuration = Double(talk.body.unicodeScalars.count) * LipSync.textStep
        dialogue = .init(
            speaker: talk.speaker,
            body: talk.body.replacingOccurrences(of: "\\n", with: "\n"),
            fontSize: 26.6666667,
            isVisible: true,
            isTyping: true,
            isFullScreen: fullScreen
        )
        if !isFastForwarding, let scenario {
            for voice in talk.voices {
                audio.play(
                    assets[.voice(scenario: scenario.id, id: voice.voiceID)],
                    kind: .voice,
                    characterID: voice.characterID,
                    volume: voice.volume
                )
            }
        }
        onEvent?(.dialogue(snippetIndex: position))
    }
    
    private func updateTalk(_ running: RunningSnippet, age: Double, delta: Double) {
        guard currentTalk == running.index, let scenario else {
            running.finished = true
            return
        }
        let talk: ScenarioTalk
        if running.isFullScreenText {
            let effect = scenario.effects[running.snippet.referenceIndex]
            talk = .init(body: effect.value, closesWindow: true)
        } else {
            talk = scenario.talks[running.snippet.referenceIndex]
        }
        for (index, motion) in talk.motions.enumerated() where !running.firedMotions.contains(index) {
            if motion.timing == 0 || (talk.motionChangeFrom == 1 && age >= motion.timing) {
                running.firedMotions.insert(index)
                applyMotion(motion)
            }
        }
        let bodyCount = dialogue.body.count
        let interval = 0.06
        let count =
            isFastForwarding
            ? bodyCount
            : (age >= running.talkOpenDelay ? min(bodyCount, Int((age - running.talkOpenDelay) / interval) + 1) : 0)
        running.revealed = max(running.revealed, count)
        dialogue.visibleCharacters = running.revealed
        dialogue.isTyping =
            !isFastForwarding && !running.typingSkipped && age < running.talkOpenDelay + Double(bodyCount) * interval
        dialogue.opacity = Float(min(1, age / 0.15))
        let layoutBusy = active.contains { $0.snippet.action == .characterLayout && !$0.finished }
        let motionBusy = stage.characters.values.contains { $0.opacity > 0 && motionIsPlaying?($0.id) == true }
        if !dialogue.isTyping {
            if running.needsVoiceCompletion == nil {
                running.needsVoiceCompletion =
                    !talk.voices.isEmpty && (audio.isVoicePlaying || layoutBusy || motionBusy)
            }
            running.holdElapsed += delta
        }
        if running.needsVoiceCompletion == true && (running.holdElapsed >= 30 || !audio.isVoicePlaying) && !layoutBusy
            && !motionBusy
        {
            running.readyElapsed += delta
        } else {
            running.readyElapsed = 0
        }
        let readyToAdvance =
            running.needsVoiceCompletion == true ? running.readyElapsed >= 0.5 : running.holdElapsed >= 2
        let automatic = isAutomatic && !dialogue.isTyping && readyToAdvance
        let fast = isFastForwarding && running.holdElapsed >= 1.5
        if running.dismissed || automatic || fast {
            running.finished = true
            currentTalk = nil
            audio.stop(.voice)
            speakingCharacters = []
            dialogue.isTyping = false
            hidePlace()
            for pending in active where pending.snippet.action == .characterMotion && !pending.started {
                apply(pending.snippet, position: pending.index, restoring: false)
                pending.started = true
                pending.finished = true
            }
            if talk.closesWindow || running.isFullScreenText { dialogue.isVisible = false }
            for (index, motion) in talk.motions.enumerated() where !running.firedMotions.contains(index) {
                applyMotion(motion)
            }
        }
    }
    
    private func applyMotion(_ motion: ScenarioMotion) {
        guard stage.characters[motion.characterID] != nil else { return }
        if !motion.motion.isEmpty {
            stage.characters[motion.characterID]?.motion = motion.motion
            stage.characters[motion.characterID]?.motionRevision += 1
        }
        if !motion.facial.isEmpty { stage.characters[motion.characterID]?.facial = motion.facial }
    }
    
    private func applyLayout(_ layout: ScenarioLayout, restoring: Bool) -> Double {
        let id = layout.characterID
        let previous = stage.characters[id]
        let fresh = previous == nil || (!layout.costume.isEmpty && previous?.costume != layout.costume)
        if previous == nil && layout.costume.isEmpty { return 0 }
        var character = previous ?? .init(id: id)
        if !layout.costume.isEmpty { character.costume = layout.costume }
        if !layout.motion.isEmpty { character.motion = layout.motion; character.motionRevision += 1 }
        if !layout.facial.isEmpty { character.facial = layout.facial }
        character.scale = stage.layoutMode == 3 ? 0.9 : 1
        character.depth = layout.depth
        let destination = sidePosition(layout.sideTo, mode: stage.layoutMode, offset: layout.offsetTo)
        let duration = [0: 0.5, 1: 0.33, 2: 0.75][layout.moveSpeed] ?? 0.5
        let moving = layout.type == 1 || ((layout.type == 2 || layout.type == 3) && layout.sideFrom != layout.sideTo)
        if layout.type == 2 || (layout.type == 3 && layout.sideFrom != 0) {
            character.x = sidePosition(layout.sideFrom, mode: stage.layoutMode, offset: layout.offsetFrom)
        }
        let startX = character.x
        let startOpacity: Float = layout.type == 2 && fresh ? 0 : character.opacity
        let endOpacity: Float = layout.type == 3 ? 0 : (layout.type == 2 ? 1 : character.opacity)
        character.side = layout.sideTo
        character.offsetX = layout.offsetTo
        character.opacity = restoring ? endOpacity : startOpacity
        if let shader = characterShaders[id] { shader.apply(to: &character) }
        if restoring && moving { character.x = destination }
        stage.characters[id] = character
        if restoring { return 0 }
        if moving {
            let delay = layout.type == 2 && fresh ? 0.034 : 0
            animate("character.\(id).x", duration: duration + delay) { [weak self] fraction in
                let progress = Float(max(0, (Double(fraction) * (duration + delay) - delay) / duration))
                self?.stage.characters[id]?.x = startX + (destination - startX) * progress
            }
        }
        if layout.type == 2 || layout.type == 3 {
            let fadeDelay = layout.type == 3 ? (moving ? max(0, duration * 0.5 - 0.1) : 0.075) : (fresh ? 0.034 : 0)
            animate("character.\(id).opacity", duration: fadeDelay + 0.1) { [weak self] fraction in
                let opacityFraction = min(1, max(0, (fraction * Float(fadeDelay + 0.1) - Float(fadeDelay)) / 0.1))
                self?.stage.characters[id]?.opacity = startOpacity + (endOpacity - startOpacity) * opacityFraction
            }
            return fadeDelay + 0.1
        }
        if layout.type == 4 || layout.type == 5 {
            animate("character.\(id).shake", duration: 0.135) { [weak self] fraction in
                let phase = min(2, Int(fraction * 3))
                let progress = fraction * 3 - Float(phase)
                let value: Float = fraction >= 1 ? 0 : progress * (phase == 1 ? -14 : 14)
                self?.stage.characters[id]?.shake = layout.type == 4 ? .init(value / 1280, 0) : .init(0, value / 720)
            }
            return 0.135
        }
        return moving ? duration : 0
    }
    
    private func applySound(_ sound: ScenarioSound, restoring: Bool) {
        let token = generation
        switch sound.playMode {
        case 0, 1:
            if !sound.bgm.isEmpty {
                bgm = sound.bgm
                if !restoring { playBGM(sound.bgm, duration: sound.duration > 0 ? sound.duration : 0.25) }
            }
            guard token == generation else { return }
            if !restoring && !sound.se.isEmpty {
                audio.play(assets[.sound(sound.se)], kind: .sound, id: sound.se, delay: sound.duration)
            }
        case 2:
            if !restoring { audio.play(assets[.sound(sound.se)], kind: .sound, id: sound.se, volume: sound.volume) }
        case 3:
            if !restoring { audio.stop(.sound, id: sound.se.isEmpty ? nil : sound.se) }
        case 4:
            bgmGain = max(0, min(1, sound.volume))
            if !restoring { playBGM(bgm, duration: sound.duration) }
        default:
            if !restoring {
                onEvent?(
                    .unsupportedAction(
                        snippetIndex: snippetIndex,
                        action: .sound,
                        detail: "Sound mode \(sound.playMode) requires a game audio middleware adapter."
                    )
                )
            }
        }
    }
    
    private func playBGM(_ id: String, duration: Double) {
        audio.play(assets[.bgm(id)], kind: .bgm, id: id, volume: bgmGain, fade: duration)
    }
    
    private func animate(_ key: String, duration: Double, update: @escaping (Float) -> Void) {
        animations.removeValue(forKey: key)
        if duration <= 0 { update(1) } else { animations[key] = .init(duration: duration, update: update) }
    }
    
    private func updateAmbientState(delta: Double) {
        stage.shake = .zero
        if let screenShake, elapsedTime < shakeScreenUntil {
            let age = elapsedTime - screenShakeStart
            let offset = screenShake.offset(at: age)
            let kick =
                screenShakeIsEndless ? 8 : 8 * (1 - Float(EffectTiming.ease("OutQuad", age / screenShake.duration)))
            stage.shake = .init(offset.x / 1920, (-kick - offset.y) / 1080)
        }
        if let windowShake, elapsedTime < shakeWindowUntil {
            let offset = windowShake.offset(at: elapsedTime - windowShakeStart)
            dialogue.shake = .init(offset.x / 1920, -offset.y / 1080)
        } else {
            dialogue.shake = .zero
        }
        for id in stage.characters.keys {
            let speaking = speakingCharacters.contains(id) || speakingCharacters.contains(900000)
            let target: Float
            if speaking && talkLipSync == 1 {
                target = audio.mouthOpen(for: id, scale: talkLipSyncScale)
            } else if speaking && talkLipSync == 0 && dialogue.isTyping && !isFastForwarding {
                target = LipSync.textTarget(at: elapsedTime - textMouthStartedAt, duration: textMouthDuration)
            } else {
                target = 0
            }
            stage.characters[id]?.mouthOpen = target
        }
    }
    
    private enum PlacePhase { case hidden, entering, shown, exiting }
    
    private struct CharacterShader {
        internal let kind: String
        internal let intensity: Float
        internal let bundle: String
        
        internal func apply(to character: inout CharacterState) {
            character.shader = kind
            character.shaderIntensity = intensity
            character.effectBundle = bundle
        }
    }
    
    private final class RunningSnippet {
        internal let index: Int
        internal let snippet: ScenarioSnippet
        internal var elapsed: Double = 0
        internal var duration: Double = 0
        internal var startedAt: Double = 0
        internal var holdElapsed: Double = 0
        internal var readyElapsed: Double = 0
        internal var needsVoiceCompletion: Bool?
        internal var started = false
        internal var finished = false
        internal var dismissed = false
        internal var revealed = 0
        internal var firedMotions: Set<Int> = []
        internal var animationKey: String?
        internal var animationObject: Animation?
        internal var isMovie = false
        internal var exitAt: Double?
        internal var talkOpenDelay: Double = 0
        internal var typingSkipped = false
        internal var isFirstFullScreen = false
        internal var isLastFullScreen = false
        internal var fullScreenVoiceStarted = false
        internal var fullScreenSlots = 8
        internal var fullScreenTextCompletedAt: Double?
        internal var fullScreenVoiceFinishedAt: Double?
        internal var voiceWaitSkipped = false
        internal var isCaption = false
        internal var isFullScreenText = false
        internal var isChoice = false
        
        internal init(index: Int, snippet: ScenarioSnippet) {
            self.index = index
            self.snippet = snippet
        }
    }
    
    private final class Animation {
        internal let duration: Double
        internal let update: (Float) -> Void
        internal var elapsed: Double = 0
        
        internal init(duration: Double, update: @escaping (Float) -> Void) {
            self.duration = duration
            self.update = update
        }
    }
}

extension StoryPlayer {
    private func applyEffect(_ effect: ScenarioEffect, position: Int, restoring: Bool) -> Double {
        let duration = restoring ? 0 : effect.duration
        let running = active.first { $0.index == position }
        switch effect.type {
        case 0, 11, 17, 37: return 0
        case 1...4, 20, 21, 40, 41:
            let isWhite = [3, 4, 20, 21, 40, 41].contains(effect.type)
            let isIn = [1, 3, 20, 40].contains(effect.type)
            let isTransition = [20, 21, 40, 41].contains(effect.type)
            let color: SIMD3<Float> = isWhite ? .one : .zero
            let start = isIn ? SIMD4(color.x, color.y, color.z, 1) : stage.cover
            let target = SIMD4(color.x, color.y, color.z, isIn ? Float(0) : 1)
            let delay = restoring || !isTransition ? 0 : (isIn ? 0.25 : 0.5)
            stage.cover = start
            if !restoring && [21, 41].contains(effect.type) {
                effectCommands.append(
                    .init(
                        name: effect.type == 41 ? "sekai_transition_3anv" : "sekai_transition",
                        isPlaying: true,
                        time: visualTime,
                        lifetime: 5
                    )
                )
            }
            animate("cover", duration: delay + duration) { [weak self] fraction in
                let progress =
                    duration <= 0
                    ? (Double(fraction) * (delay + duration) >= delay ? 1 : 0)
                    : min(1, max(0, (Double(fraction) * (delay + duration) - delay) / duration))
                self?.stage.cover = start + (target - start) * Float(progress)
            }
            return delay + duration
        case 5, 6:
            let seconds = min(effect.duration, 3600)
            let endless = effect.duration >= 3600
            guard seconds > 0, !restoring || endless else { return 0 }
            let shake = EffectShake(
                duration: seconds,
                strength: 10,
                vibrato: 16,
                fadeOut: effect.type == 6 || !endless,
                ignoreZ: effect.type == 6
            )
            if effect.type == 5 {
                screenShake = shake
                screenShakeStart = elapsedTime
                shakeScreenUntil = elapsedTime + seconds
                screenShakeIsEndless = endless
            } else {
                windowShake = shake
                windowShakeStart = elapsedTime
                shakeWindowUntil = elapsedTime + seconds
            }
            if !endless {
                let key = effect.type == 5 ? "screen.shake" : "window.shake"
                animate(key, duration: seconds) { _ in }
                trackAnimation(key, running: running)
            }
            return endless ? 0 : seconds
        case 7:
            guard !effect.value.isEmpty else { return 0 }
            stage.previousBackground = stage.background
            stage.background = effect.value
            stage.backgroundTime = restoring ? 0 : visualTime
            stage.backgroundMix = 0
            stage.tint = .one
            animate("background", duration: duration) { [weak self] in self?.stage.backgroundMix = $0 }
            return duration
        case 8:
            if !restoring {
                stage.caption = effect.value.replacingOccurrences(of: "\\n", with: "\n")
                stage.captionTransform = .zero
                running?.isCaption = true
                captionOwner = position
            }
        case 9, 27:
            stage.colorEffect = effect.type == 27 ? 2 : 1
            stage.isCameraBlurActive = false
            animations.removeValue(forKey: "blur")
        case 10, 28: stage.colorEffect = 0
        case 12: stage.tint = .one
        case 13: stage.tint = .init(0.99, 0.9, 0.8)
        case 14: stage.tint = .init(0.83, 0.86, 0.91)
        case 15, 16:
            let isPlaying = effect.type == 15
            animate("scenarioEffect.\(position)", duration: duration) { [weak self] fraction in
                guard fraction >= 1, let self else { return }
                if isPlaying {
                    self.stage.effects.insert(effect.value)
                } else {
                    self.stage.effects.remove(effect.value)
                }
                if !restoring {
                    self.effectCommands.append(.init(name: effect.value, isPlaying: isPlaying, time: self.visualTime))
                    self.onEvent?(.scenarioEffect(name: effect.value, isPlaying: isPlaying))
                }
            }
        case 18:
            if !restoring {
                stage.place = effect.value
                if placePhase == .shown || placePhase == .entering { return 0 }
                placePhase = .entering
                placeCloseReserved = false
                let start = Float(-732.0 / 1920)
                stage.placeOffset = start
                animate("place", duration: 0.2) { [weak self] fraction in
                    guard let self else { return }
                    self.stage.placeOffset = start * (1 - Float(EffectTiming.ease("OutQuart", Double(fraction))))
                    if fraction >= 1 {
                        self.placePhase = .shown
                        if self.placeCloseReserved { self.hidePlace() }
                    }
                }
            }
        case 19:
            if !restoring {
                beginMovie(effect.value, running: running)
            } else {
                for id in stage.characters.keys { stage.characters[id]?.opacity = 0 }
            }
        case 22:
            if effect.value == "none" {
                characterShaders[effect.integer] = nil
                stage.characters[effect.integer]?.shader = ""
                stage.characters[effect.integer]?.shaderIntensity = 1
                stage.characters[effect.integer]?.effectBundle = ""
            } else {
                let kind = effect.value.isEmpty ? "hologram" : effect.value
                guard ["hologram", "monitor", "blur"].contains(kind) else { return 0 }
                if kind == "blur" && characterShaders[effect.integer]?.kind == "blur" { return 0 }
                let intensity = Float(effect.secondaryValue).flatMap { $0.isFinite ? $0 : nil } ?? 1
                let shader = CharacterShader(
                    kind: kind,
                    intensity: intensity,
                    bundle: kind == "hologram" ? effect.secondaryValue : ""
                )
                characterShaders[effect.integer] = shader
                if var character = stage.characters[effect.integer] {
                    shader.apply(to: &character)
                    stage.characters[effect.integer] = character
                }
            }
        case 23:
            if !restoring {
                stage.choices = Array(effect.value.components(separatedBy: "/").prefix(2))
                stage.choiceScale = 0
                running?.isChoice = true
                choiceOwner = position
                onEvent?(.choice(options: stage.choices))
            }
        case 24:
            if !restoring, let running, let scenario {
                func isFullScreen(_ index: Int) -> Bool {
                    guard scenario.snippets.indices.contains(index) else { return false }
                    let snippet = scenario.snippets[index]
                    return snippet.action == .specialEffect && scenario.effects[snippet.referenceIndex].type == 24
                }
                running.isFullScreenText = true
                running.isFirstFullScreen = !isFullScreen(position - 1)
                running.isLastFullScreen = !isFullScreen(position + 1)
                beginTalk(.init(body: effect.value, closesWindow: true), position: position, fullScreen: true)
                let text = FullScreenText(effect.value)
                if running.isFirstFullScreen { fullScreenCapacity = 8 }
                fullScreenCapacity = max(fullScreenCapacity, text.processingCount)
                running.fullScreenSlots = fullScreenCapacity
                dialogue.body = text.text
                dialogue.textRuns = text.runs
                dialogue.fullScreenBackgroundOpacity = running.isFirstFullScreen ? 0 : 0.5
                dialogue.visibleCharacters = dialogue.body.count
                dialogue.fontSize = 56 * 2 / 3
                dialogue.characterAlphas = Array(repeating: 0, count: dialogue.body.count)
                dialogue.cinemaBarHeight = running.isFirstFullScreen ? 0 : 160 / 720
            }
        case 25:
            shakeScreenUntil = 0
            animations.removeValue(forKey: "screen.shake")
        case 26:
            shakeWindowUntil = 0
            animations.removeValue(forKey: "window.shake")
        case 29...36:
            let isIn = effect.type % 2 == 1
            let direction = (effect.type - 29) / 2
            stage.wipeDirection = direction
            let distance: SIMD2<Float>
            switch direction {
            case 0: distance = .init(-(1920 + 512) / 1920.0, 0)
            case 1: distance = .init((1920 + 512) / 1920.0, 0)
            case 2: distance = .init(0, -(1080 + 512) / 1080.0)
            default: distance = .init(0, (1080 + 512) / 1080.0)
            }
            stage.wipeOffset = isIn ? .zero : distance
            stage.isWipeVisible = true
            animate("wipe", duration: duration) { [weak self] fraction in
                guard let self else { return }
                let eased = Float(EffectTiming.ease("OutQuad", Double(fraction)))
                self.stage.wipeOffset = isIn ? -distance * eased : distance * (1 - eased)
                self.stage.wipe = isIn ? 1 - eased : eased
                if fraction >= 1 && isIn { self.stage.isWipeVisible = false }
            }
            return duration
        case 38, 39:
            stage.isCameraBlurActive = true
            stage.colorEffect = 0
            let into = effect.type == 38
            animate("blur", duration: duration) { [weak self] fraction in
                guard let self else { return }
                let amount = min(EffectTiming.ease("OutQuad", Double(fraction)) / max(1e-6, effect.duration), 1)
                self.stage.blur = Float(into ? 3 * amount : 3 - 3 * amount)
                if fraction >= 1 && !into { self.stage.isCameraBlurActive = false }
            }
            return duration
        case 42:
            let values = effect.value.split(separator: ",").compactMap {
                Float($0.trimmingCharacters(in: .whitespaces))
            }
            guard values.count >= 2, values.allSatisfy(\.isFinite) else { return 0 }
            let start = stage.camera
            let end = SIMD2<Float>(values[0] / 1920, -values[1] / 1080)
            animate("camera.position", duration: duration) { [weak self] fraction in
                let eased = Float(EffectTiming.ease("OutQuad", Double(fraction)))
                self?.stage.camera.x = start.x + (end.x - start.x) * eased
                self?.stage.camera.y = start.y + (end.y - start.y) * eased
            }
            trackAnimation("camera.position", running: running)
            return duration
        case 43:
            guard let value = Float(effect.value), value.isFinite, value > 0 else { return 0 }
            let start = stage.camera.z
            animate("camera.zoom", duration: duration) { [weak self] fraction in
                self?.stage.camera.z = start + (value - start) * Float(EffectTiming.ease("OutQuad", Double(fraction)))
            }
            trackAnimation("camera.zoom", running: running)
            return duration
        case 44:
            stage.backgroundBlur = effect.value.trimmingCharacters(in: .whitespaces).lowercased() == "true" ? 2.8 : 0
        case 45:
            var values: [String: Float] = [:]
            for component in effect.value.replacingOccurrences(of: "：", with: ":").split(separator: ",") {
                let parts = component.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if parts.count == 2, let value = Float(parts[1]), value.isFinite { values[parts[0]] = value }
            }
            guard let zoom = values["zoom"], zoom > 0 else { return 0 }
            let distortion = (values["dist"] ?? 0) * (1 - zoom)
            let blur = values["blur"] ?? 0
            let clear = blur <= 0 && distortion == 0
            var start = stage.dolly
            if clear {
                stage.dolly.y = 0; stage.dolly.z = 0; stage.dolly.w = 0; start = stage.dolly
            } else {
                stage.dolly.w = 1
            }
            animate("dolly", duration: duration) { [weak self] fraction in
                let eased = Float(EffectTiming.ease(effect.secondaryValue, Double(fraction)))
                self?.stage.dolly.x = start.x + (zoom - start.x) * eased
                if !clear {
                    self?.stage.dolly.y = start.y + (blur - start.y) * eased
                    self?.stage.dolly.z = start.z + (distortion - start.z) * eased
                }
            }
        default:
            if !restoring {
                onEvent?(
                    .unsupportedAction(
                        snippetIndex: position,
                        action: .specialEffect,
                        detail: "Unknown special effect \(effect.type)."
                    )
                )
            }
        }
        return 0
    }
    
    private func trackAnimation(_ key: String, running: RunningSnippet?) {
        running?.animationKey = key
        running?.animationObject = animations[key]
    }
    
    private func updateCaption(_ running: RunningSnippet, age: Double) {
        guard captionOwner == running.index else { running.finished = true; return }
        if running.exitAt == nil && age >= 0.333
            && (running.dismissed || ((isAutomatic || isFastForwarding) && age >= 2.333))
        {
            running.exitAt = age
        }
        if let exit = running.exitAt {
            let alpha = Float(EffectTiming.sample(EffectTiming.telopHide, at: age - exit))
            stage.captionTransform.y = alpha
            stage.captionTransform.z = alpha
            if age - exit >= 0.333 { stage.caption = ""; captionOwner = nil; running.finished = true }
        } else {
            stage.captionTransform = .init(
                Float(EffectTiming.sample(EffectTiming.telopScale, at: age)),
                Float(EffectTiming.sample(EffectTiming.telopBaseAlpha, at: age)),
                Float(EffectTiming.sample(EffectTiming.telopTextAlpha, at: age)),
                Float(EffectTiming.sample(EffectTiming.telopTextX, at: age) / 1920)
            )
        }
    }
    
    private func hidePlace() {
        if placePhase == .entering { placeCloseReserved = true; return }
        guard placePhase == .shown else { return }
        placePhase = .exiting
        let start = stage.placeOffset
        animate("place", duration: 0.2) { [weak self] fraction in
            self?.stage.placeOffset =
                start + (Float(-732.0 / 1920) - start) * Float(EffectTiming.ease("OutQuart", Double(fraction)))
            if fraction >= 1 { self?.stage.place = ""; self?.placePhase = .hidden }
        }
    }
    
    private func updateFullScreenText(_ running: RunningSnippet, age: Double, delta: Double) {
        guard currentTalk == running.index, let scenario else { running.finished = true; return }
        let effect = scenario.effects[running.snippet.referenceIndex]
        let opening = running.isFirstFullScreen ? 1.5 : 0
        dialogue.opacity = 1
        dialogue.cinemaBarHeight = Float(
            160.0 / 720 * EffectTiming.ease("OutQuad", running.isFirstFullScreen ? age : 1)
        )
        dialogue.fullScreenBackgroundOpacity = Float(
            0.5 * EffectTiming.ease("OutQuad", running.isFirstFullScreen ? age : 1)
        )
        guard age >= opening else { return }
        if !running.fullScreenVoiceStarted {
            running.fullScreenVoiceStarted = true
            if !isFastForwarding && !effect.secondaryValue.isEmpty {
                audio.play(assets[.voice(scenario: scenario.id, id: effect.secondaryValue)], kind: .voice)
            }
        }
        let count = dialogue.body.unicodeScalars.count
        let textAge = age - opening
        let typingDuration = Double(running.fullScreenSlots) * 0.125
        if isFastForwarding || running.typingSkipped || running.dismissed {
            dialogue.characterAlphas = Array(repeating: 1, count: count)
            if running.fullScreenTextCompletedAt == nil { running.fullScreenTextCompletedAt = age }
        } else {
            dialogue.characterAlphas = (0..<count).map { Float(min(1, max(0, textAge / 0.125 - Double($0)))) }
            if textAge >= typingDuration && running.fullScreenTextCompletedAt == nil {
                running.fullScreenTextCompletedAt = age
            }
        }
        dialogue.isTyping = running.fullScreenTextCompletedAt == nil
        guard let completed = running.fullScreenTextCompletedAt else { return }
        if running.exitAt == nil {
            let voiceReady = !audio.isVoicePlaying || age - completed >= 10 || running.voiceWaitSkipped
            if voiceReady && running.fullScreenVoiceFinishedAt == nil { running.fullScreenVoiceFinishedAt = age }
            let held = running.fullScreenVoiceFinishedAt.map { age - $0 >= 1 } ?? false
            if isFastForwarding || running.dismissed || held {
                if running.dismissed { audio.stop(.voice) }
                running.exitAt = age
            }
        }
        guard let exit = running.exitAt else { return }
        if running.isLastFullScreen {
            let alpha = Float(1 - EffectTiming.ease("OutQuad", age - exit))
            dialogue.opacity = alpha
            dialogue.fullScreenBackgroundOpacity *= alpha
            dialogue.cinemaBarHeight = 160 / 720 * alpha
            if age - exit < 1 { return }
            dialogue.isVisible = false
        } else {
            dialogue.body = ""
        }
        currentTalk = nil
        running.finished = true
        audio.stop(.voice)
    }
}

extension StoryPlayer {
    private func beginMovie(_ name: String, running: RunningSnippet?) {
        guard let asset = movieAssets[name], let running else { return }
        for id in stage.characters.keys { stage.characters[id]?.opacity = 0 }
        movie.prepare(asset)
        running.isMovie = true
        let start = stage.cover
        animate("cover", duration: 0.5) { [weak self] fraction in
            self?.stage.cover = start + (SIMD4<Float>(0, 0, 0, 1) - start) * fraction
        }
    }
    
    private func updateMovie(_ running: RunningSnippet, age: Double) {
        guard age >= 0.5 else { return }
        movie.start()
        if movie.isFinished {
            movie.stop()
            running.finished = true
            stage.cover = .init(0, 0, 0, 1)
            animate("cover", duration: 1) { [weak self] fraction in
                self?.stage.cover.w = max(0, min(1, 2 - fraction * 2))
            }
            return
        }
        if movie.isVisible {
            let head = max(0, 1 - Float(movie.time / 0.5))
            let tail = max(0, 1 - Float(movie.remaining / 0.5))
            stage.cover = .init(0, 0, 0, max(head, tail))
        }
    }
}
