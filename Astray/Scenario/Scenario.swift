public enum ScenarioAction: Int, Codable, Sendable {
    case none = 0, talk, characterLayout, inputName, characterMotion, selectable, specialEffect, sound,
        characterLayoutMode
}

public enum ScenarioProgress: Int, Codable, Sendable {
    case now = 0, waitFinished
}

public struct ScenarioSnippet: Codable, Sendable, Equatable {
    public var index: Int
    public var action: ScenarioAction
    public var progressBehavior: ScenarioProgress
    public var referenceIndex: Int
    public var delay: Double
    
    public init(
        index: Int = 0,
        action: ScenarioAction = .none,
        progressBehavior: ScenarioProgress = .now,
        referenceIndex: Int = 0,
        delay: Double = 0
    ) {
        self.index = index
        self.action = action
        self.progressBehavior = progressBehavior
        self.referenceIndex = referenceIndex
        self.delay = delay
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decodeIfPresent(Int.self, forKey: .index) ?? 0
        action = try values.decodeIfPresent(ScenarioAction.self, forKey: .action) ?? .none
        progressBehavior = try values.decodeIfPresent(ScenarioProgress.self, forKey: .progressBehavior) ?? .now
        referenceIndex = try values.decodeIfPresent(Int.self, forKey: .referenceIndex) ?? 0
        delay = try values.decodeIfPresent(Double.self, forKey: .delay) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case index = "Index"
        case action = "Action"
        case progressBehavior = "ProgressBehavior"
        case referenceIndex = "ReferenceIndex"
        case delay = "Delay"
    }
}

public struct ScenarioCharacter: Codable, Sendable, Equatable {
    public var characterID: Int
    public var costume: String
    
    public init(
        characterID: Int = 0,
        costume: String = ""
    ) {
        self.characterID = characterID
        self.costume = costume
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        characterID = try values.decodeIfPresent(Int.self, forKey: .characterID) ?? 0
        costume = try values.decodeIfPresent(String.self, forKey: .costume) ?? ""
    }
    
    private enum CodingKeys: String, CodingKey {
        case characterID = "Character2dId"
        case costume = "CostumeType"
    }
}

public struct ScenarioInitialLayout: Codable, Sendable, Equatable {
    public var side: Int
    public var characterID: Int
    public var costume: String
    public var motion: String
    public var facial: String
    public var offsetX: Double
    
    public init(
        side: Int = 0,
        characterID: Int = 0,
        costume: String = "",
        motion: String = "",
        facial: String = "",
        offsetX: Double = 0
    ) {
        self.side = side
        self.characterID = characterID
        self.costume = costume
        self.motion = motion
        self.facial = facial
        self.offsetX = offsetX
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        side = try values.decodeIfPresent(Int.self, forKey: .side) ?? 0
        characterID = try values.decodeIfPresent(Int.self, forKey: .characterID) ?? 0
        costume = try values.decodeIfPresent(String.self, forKey: .costume) ?? ""
        motion = try values.decodeIfPresent(String.self, forKey: .motion) ?? ""
        facial = try values.decodeIfPresent(String.self, forKey: .facial) ?? ""
        offsetX = try values.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case side = "PositionSide"
        case characterID = "Character2dId"
        case costume = "CostumeType"
        case motion = "MotionName"
        case facial = "FacialName"
        case offsetX = "OffsetX"
    }
}

public struct ScenarioMotion: Codable, Sendable, Equatable {
    public var characterID: Int
    public var motion: String
    public var facial: String
    public var timing: Double
    
    public init(
        characterID: Int = 0,
        motion: String = "",
        facial: String = "",
        timing: Double = 0
    ) {
        self.characterID = characterID
        self.motion = motion
        self.facial = facial
        self.timing = timing
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        characterID = try values.decodeIfPresent(Int.self, forKey: .characterID) ?? 0
        motion = try values.decodeIfPresent(String.self, forKey: .motion) ?? ""
        facial = try values.decodeIfPresent(String.self, forKey: .facial) ?? ""
        timing = try values.decodeIfPresent(Double.self, forKey: .timing) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case characterID = "Character2dId"
        case motion = "MotionName"
        case facial = "FacialName"
        case timing = "TimingSyncValue"
    }
}

public struct ScenarioVoice: Codable, Sendable, Equatable {
    public var characterID: Int
    public var voiceID: String
    public var volume: Float
    
    public init(
        characterID: Int = 0,
        voiceID: String = "",
        volume: Float = 1
    ) {
        self.characterID = characterID
        self.voiceID = voiceID
        self.volume = volume
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        characterID = try values.decodeIfPresent(Int.self, forKey: .characterID) ?? 0
        voiceID = try values.decodeIfPresent(String.self, forKey: .voiceID) ?? ""
        volume = try values.decodeIfPresent(Float.self, forKey: .volume) ?? 1
    }
    
    private enum CodingKeys: String, CodingKey {
        case characterID = "Character2dId"
        case voiceID = "VoiceId"
        case volume = "Volume"
    }
}

public struct ScenarioTalk: Codable, Sendable, Equatable {
    public var characters: [ScenarioCharacter]
    public var speaker: String
    public var body: String
    public var lipSync: Int
    public var motionChangeFrom: Int
    public var motions: [ScenarioMotion]
    public var voices: [ScenarioVoice]
    public var speed: Double
    public var fontSize: Double
    public var closesWindow: Bool
    public var lipSyncScale: Double
    
    public init(
        characters: [ScenarioCharacter] = [],
        speaker: String = "",
        body: String = "",
        lipSync: Int = 0,
        motionChangeFrom: Int = 0,
        motions: [ScenarioMotion] = [],
        voices: [ScenarioVoice] = [],
        speed: Double = 0,
        fontSize: Double = 0,
        closesWindow: Bool = false,
        lipSyncScale: Double = 0
    ) {
        self.characters = characters
        self.speaker = speaker
        self.body = body
        self.lipSync = lipSync
        self.motionChangeFrom = motionChangeFrom
        self.motions = motions
        self.voices = voices
        self.speed = speed
        self.fontSize = fontSize
        self.closesWindow = closesWindow
        self.lipSyncScale = lipSyncScale
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        characters = try values.decodeIfPresent([ScenarioCharacter].self, forKey: .characters) ?? []
        speaker = try values.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        lipSync = try values.decodeIfPresent(Int.self, forKey: .lipSync) ?? 0
        motionChangeFrom = try values.decodeIfPresent(Int.self, forKey: .motionChangeFrom) ?? 0
        motions = try values.decodeIfPresent([ScenarioMotion].self, forKey: .motions) ?? []
        voices = try values.decodeIfPresent([ScenarioVoice].self, forKey: .voices) ?? []
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0
        if let flag = try? values.decode(Bool.self, forKey: .closesWindow) {
            closesWindow = flag
        } else {
            closesWindow = try values.decodeIfPresent(Int.self, forKey: .closesWindow) ?? 0 != 0
        }
        lipSyncScale = try values.decodeIfPresent(Double.self, forKey: .lipSyncScale) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case characters = "TalkCharacters"
        case speaker = "WindowDisplayName"
        case body = "Body"
        case lipSync = "LipSync"
        case motionChangeFrom = "MotionChangeFrom"
        case motions = "Motions"
        case voices = "Voices"
        case speed = "Speed"
        case fontSize = "FontSize"
        case closesWindow = "WhenFinishCloseWindow"
        case lipSyncScale = "TargetValueScale"
    }
}

public struct ScenarioLayout: Codable, Sendable, Equatable {
    public var type: Int
    public var sideFrom: Int
    public var offsetFrom: Double
    public var sideTo: Int
    public var offsetTo: Double
    public var depth: Int
    public var characterID: Int
    public var costume: String
    public var motion: String
    public var facial: String
    public var moveSpeed: Int
    
    public init(
        type: Int = 0,
        sideFrom: Int = 0,
        offsetFrom: Double = 0,
        sideTo: Int = 0,
        offsetTo: Double = 0,
        depth: Int = 0,
        characterID: Int = 0,
        costume: String = "",
        motion: String = "",
        facial: String = "",
        moveSpeed: Int = 0
    ) {
        self.type = type
        self.sideFrom = sideFrom
        self.offsetFrom = offsetFrom
        self.sideTo = sideTo
        self.offsetTo = offsetTo
        self.depth = depth
        self.characterID = characterID
        self.costume = costume
        self.motion = motion
        self.facial = facial
        self.moveSpeed = moveSpeed
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(Int.self, forKey: .type) ?? 0
        sideFrom = try values.decodeIfPresent(Int.self, forKey: .sideFrom) ?? 0
        offsetFrom = try values.decodeIfPresent(Double.self, forKey: .offsetFrom) ?? 0
        sideTo = try values.decodeIfPresent(Int.self, forKey: .sideTo) ?? 0
        offsetTo = try values.decodeIfPresent(Double.self, forKey: .offsetTo) ?? 0
        depth = try values.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        characterID = try values.decodeIfPresent(Int.self, forKey: .characterID) ?? 0
        costume = try values.decodeIfPresent(String.self, forKey: .costume) ?? ""
        motion = try values.decodeIfPresent(String.self, forKey: .motion) ?? ""
        facial = try values.decodeIfPresent(String.self, forKey: .facial) ?? ""
        moveSpeed = try values.decodeIfPresent(Int.self, forKey: .moveSpeed) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case sideFrom = "SideFrom"
        case offsetFrom = "SideFromOffsetX"
        case sideTo = "SideTo"
        case offsetTo = "SideToOffsetX"
        case depth = "DepthType"
        case characterID = "Character2dId"
        case costume = "CostumeType"
        case motion = "MotionName"
        case facial = "FacialName"
        case moveSpeed = "MoveSpeedType"
    }
}

public struct ScenarioSound: Codable, Sendable, Equatable {
    public var playMode: Int
    public var bgm: String
    public var se: String
    public var volume: Float
    public var seBundle: String
    public var duration: Double
    public var bgmBlockIndex: Int
    
    public init(
        playMode: Int = 0,
        bgm: String = "",
        se: String = "",
        volume: Float = 1,
        seBundle: String = "",
        duration: Double = 0,
        bgmBlockIndex: Int = 0
    ) {
        self.playMode = playMode
        self.bgm = bgm
        self.se = se
        self.volume = volume
        self.seBundle = seBundle
        self.duration = duration
        self.bgmBlockIndex = bgmBlockIndex
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        playMode = try values.decodeIfPresent(Int.self, forKey: .playMode) ?? 0
        bgm = try values.decodeIfPresent(String.self, forKey: .bgm) ?? ""
        se = try values.decodeIfPresent(String.self, forKey: .se) ?? ""
        volume = try values.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        seBundle = try values.decodeIfPresent(String.self, forKey: .seBundle) ?? ""
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        bgmBlockIndex = try values.decodeIfPresent(Int.self, forKey: .bgmBlockIndex) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case playMode = "PlayMode"
        case bgm = "Bgm"
        case se = "Se"
        case volume = "Volume"
        case seBundle = "SeBundleName"
        case duration = "Duration"
        case bgmBlockIndex = "BgmBlockIndex"
    }
}

public struct ScenarioEffect: Codable, Sendable, Equatable {
    public var type: Int
    public var value: String
    public var secondaryValue: String
    public var duration: Double
    public var integer: Int
    
    public init(
        type: Int = 0,
        value: String = "",
        secondaryValue: String = "",
        duration: Double = 0,
        integer: Int = 0
    ) {
        self.type = type
        self.value = value
        self.secondaryValue = secondaryValue
        self.duration = duration
        self.integer = integer
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(Int.self, forKey: .type) ?? 0
        value = try values.decodeIfPresent(String.self, forKey: .value) ?? ""
        secondaryValue = try values.decodeIfPresent(String.self, forKey: .secondaryValue) ?? ""
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        integer = try values.decodeIfPresent(Int.self, forKey: .integer) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case type = "EffectType"
        case value = "StringVal"
        case secondaryValue = "StringValSub"
        case duration = "Duration"
        case integer = "IntVal"
    }
}

public struct ScenarioLayoutMode: Codable, Sendable, Equatable {
    public var mode: Int
    
    public init(
        mode: Int = 0
    ) {
        self.mode = mode
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Int.self, forKey: .mode) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case mode = "CharacterLayoutMode"
    }
}

public struct Scenario: Codable, Sendable, Equatable {
    public var id: String
    public var characters: [ScenarioCharacter]
    public var initialLayout: [ScenarioInitialLayout]
    public var initialBGM: String
    public var initialBackground: String
    public var initialLayoutMode: Int
    public var snippets: [ScenarioSnippet]
    public var talks: [ScenarioTalk]
    public var layouts: [ScenarioLayout]
    public var sounds: [ScenarioSound]
    public var effects: [ScenarioEffect]
    public var layoutModes: [ScenarioLayoutMode]
    
    public init(
        id: String = "",
        characters: [ScenarioCharacter] = [],
        initialLayout: [ScenarioInitialLayout] = [],
        initialBGM: String = "",
        initialBackground: String = "",
        initialLayoutMode: Int = 0,
        snippets: [ScenarioSnippet] = [],
        talks: [ScenarioTalk] = [],
        layouts: [ScenarioLayout] = [],
        sounds: [ScenarioSound] = [],
        effects: [ScenarioEffect] = [],
        layoutModes: [ScenarioLayoutMode] = []
    ) {
        self.id = id
        self.characters = characters
        self.initialLayout = initialLayout
        self.initialBGM = initialBGM
        self.initialBackground = initialBackground
        self.initialLayoutMode = initialLayoutMode
        self.snippets = snippets
        self.talks = talks
        self.layouts = layouts
        self.sounds = sounds
        self.effects = effects
        self.layoutModes = layoutModes
    }
    
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        characters = try values.decodeIfPresent([ScenarioCharacter].self, forKey: .characters) ?? []
        initialLayout = try values.decodeIfPresent([ScenarioInitialLayout].self, forKey: .initialLayout) ?? []
        initialBGM = try values.decodeIfPresent(String.self, forKey: .initialBGM) ?? ""
        initialBackground = try values.decodeIfPresent(String.self, forKey: .initialBackground) ?? ""
        initialLayoutMode = try values.decodeIfPresent(Int.self, forKey: .initialLayoutMode) ?? 0
        snippets = try values.decodeIfPresent([ScenarioSnippet].self, forKey: .snippets) ?? []
        talks = try values.decodeIfPresent([ScenarioTalk].self, forKey: .talks) ?? []
        layouts = try values.decodeIfPresent([ScenarioLayout].self, forKey: .layouts) ?? []
        sounds = try values.decodeIfPresent([ScenarioSound].self, forKey: .sounds) ?? []
        effects = try values.decodeIfPresent([ScenarioEffect].self, forKey: .effects) ?? []
        layoutModes = try values.decodeIfPresent([ScenarioLayoutMode].self, forKey: .layoutModes) ?? []
    }
    
    private enum CodingKeys: String, CodingKey {
        case id = "ScenarioId"
        case characters = "AppearCharacters"
        case initialLayout = "FirstLayout"
        case initialBGM = "FirstBgm"
        case initialBackground = "FirstBackground"
        case initialLayoutMode = "FirstCharacterLayoutMode"
        case snippets = "Snippets"
        case talks = "TalkData"
        case layouts = "LayoutData"
        case sounds = "SoundData"
        case effects = "SpecialEffectData"
        case layoutModes = "ScenarioSnippetCharacterLayoutModes"
    }
}
