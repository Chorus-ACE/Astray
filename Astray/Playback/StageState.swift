public enum PlaybackStatus: String, Sendable {
    case idle, loading, ready, playing, paused, finished, failed
}

public struct CharacterState: Sendable, Equatable, Identifiable {
    public internal(set) var id: Int
    public internal(set) var costume: String = ""
    public internal(set) var motion: String = ""
    public internal(set) var facial: String = ""
    public internal(set) var side: Int = 0
    public internal(set) var offsetX: Double = 0
    public internal(set) var x: Float = 0.5
    public internal(set) var opacity: Float = 1
    public internal(set) var scale: Float = 1
    public internal(set) var depth: Int = 0
    public internal(set) var shake: SIMD2<Float> = .zero
    public internal(set) var mouthOpen: Float = 0
    public internal(set) var motionRevision: Int = 0
    public internal(set) var shader: String = ""
    public internal(set) var shaderIntensity: Float = 1
    public internal(set) var effectBundle: String = ""
}

public struct DialogueState: Sendable, Equatable {
    public internal(set) var speaker: String = ""
    public internal(set) var body: String = ""
    public internal(set) var visibleCharacters: Int = 0
    public internal(set) var fontSize: Double = 30
    public internal(set) var isVisible: Bool = false
    public internal(set) var isTyping: Bool = false
    public internal(set) var isFullScreen: Bool = false
    public internal(set) var shake: SIMD2<Float> = .zero
    public internal(set) var opacity: Float = 1
    public internal(set) var cinemaBarHeight: Float = 0
    public internal(set) var characterAlphas: [Float] = []
    internal var textRuns: [TextRun] = []
    internal var fullScreenBackgroundOpacity: Float = 0.5
    
    public var displayedText: String { String(body.prefix(visibleCharacters)) }
}

public struct StageState: Sendable, Equatable {
    public internal(set) var background: String = ""
    public internal(set) var backgroundTime: Double = 0
    public internal(set) var previousBackground: String = ""
    public internal(set) var backgroundMix: Float = 1
    public internal(set) var characters: [Int: CharacterState] = [:]
    public internal(set) var layoutMode: Int = 0
    public internal(set) var cover: SIMD4<Float> = .zero
    public internal(set) var tint: SIMD3<Float> = .one
    public internal(set) var colorEffect: Int = 0
    public internal(set) var camera: SIMD3<Float> = .init(0, 0, 1)
    public internal(set) var dolly: SIMD4<Float> = .init(1, 0, 0, 0)
    public internal(set) var isCameraBlurActive = false
    public internal(set) var blur: Float = 0
    public internal(set) var backgroundBlur: Float = 0
    public internal(set) var shake: SIMD2<Float> = .zero
    public internal(set) var wipe: Float = 0
    public internal(set) var wipeDirection: Int = 0
    public internal(set) var wipeOffset: SIMD2<Float> = .zero
    public internal(set) var isWipeVisible = false
    public internal(set) var captionTransform: SIMD4<Float> = .init(1, 1, 1, 0)
    public internal(set) var placeOffset: Float = 0
    public internal(set) var choiceScale: Float = 0
    public internal(set) var caption: String = ""
    public internal(set) var place: String = ""
    public internal(set) var choices: [String] = []
    public internal(set) var effects: Set<String> = []
}

public enum PlayerEvent: Sendable {
    case loadProgress(completed: Int, total: Int)
    case ready
    case progress(index: Int, total: Int)
    case dialogue(snippetIndex: Int)
    case choice(options: [String])
    case selected(index: Int, value: String)
    case scenarioEffect(name: String, isPlaying: Bool)
    case unsupportedAction(snippetIndex: Int, action: ScenarioAction, detail: String)
    case warning(AstrayError)
    case finished
}

internal func sidePosition(_ side: Int, mode: Int, offset: Double = 0) -> Float {
    let distance: Float = mode == 3 ? 576 : 360
    let x: Float
    switch side {
    case 1, 3, 8, 9: x = -distance
    case 5, 7, 11, 12: x = distance
    case 2: x = -1779
    case 6: x = 1779
    default: x = 0
    }
    return 0.5 + (x + Float(offset)) / 1920 * 0.96
}
