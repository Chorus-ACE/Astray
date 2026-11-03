public import Foundation

public enum AstrayError: Error, LocalizedError, Sendable {
    case invalidScenario(String)
    case assetUnavailable(URL, String)
    case metalUnavailable
    case shaderLibraryUnavailable(String)
    case renderingFailed(String)
    case audioPlaybackFailed(String)
    case invalidJump(Int)
    
    public var errorDescription: String? {
        switch self {
        case .invalidScenario(let detail): "Invalid scenario: \(detail)"
        case .assetUnavailable(let url, let detail): "Asset unavailable at \(url): \(detail)"
        case .metalUnavailable: "Metal is unavailable on this device."
        case .shaderLibraryUnavailable(let detail): "Unable to load Astray's compiled Metal library: \(detail)"
        case .renderingFailed(let detail): "Metal rendering failed: \(detail)"
        case .audioPlaybackFailed(let detail): "Audio playback failed: \(detail)"
        case .invalidJump(let index): "Invalid snippet position: \(index)"
        }
    }
}

extension Scenario {
    public static func decode(_ data: Data) throws -> Self {
        let scenario = try JSONDecoder().decode(Self.self, from: data)
        try scenario.validate()
        return scenario
    }
    
    public func validate() throws {
        for (position, snippet) in snippets.enumerated() {
            guard snippet.delay.isFinite, snippet.delay >= 0 else {
                throw AstrayError.invalidScenario("Negative or nonfinite delay at snippet \(position).")
            }
            let count: Int?
            switch snippet.action {
            case .talk: count = talks.count
            case .characterLayout, .characterMotion: count = layouts.count
            case .sound: count = sounds.count
            case .specialEffect: count = effects.count
            case .characterLayoutMode: count = layoutModes.count
            default: count = nil
            }
            if let count, !(0..<count).contains(snippet.referenceIndex) {
                throw AstrayError.invalidScenario("Invalid reference \(snippet.referenceIndex) at snippet \(position).")
            }
        }
        guard effects.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 }),
            sounds.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 && $0.volume.isFinite }),
            talks.allSatisfy({
                $0.speed.isFinite && $0.fontSize.isFinite && $0.lipSyncScale.isFinite
                    && $0.motions.allSatisfy { $0.timing.isFinite && $0.timing >= 0 }
                    && $0.voices.allSatisfy { $0.volume.isFinite }
            }),
            layouts.allSatisfy({ $0.offsetFrom.isFinite && $0.offsetTo.isFinite }),
            initialLayout.allSatisfy({ $0.offsetX.isFinite })
        else {
            throw AstrayError.invalidScenario("Nonfinite or negative timing, coordinate, or volume.")
        }
    }
    
    public var transcript: [TranscriptLine] {
        snippets.enumerated().compactMap { index, snippet in
            if snippet.action == .talk, talks.indices.contains(snippet.referenceIndex) {
                let talk = talks[snippet.referenceIndex]
                return .init(snippetIndex: index, speaker: talk.speaker, body: talk.body)
            }
            if snippet.action == .specialEffect, effects.indices.contains(snippet.referenceIndex) {
                let effect = effects[snippet.referenceIndex]
                if [8, 24].contains(effect.type) {
                    return .init(
                        snippetIndex: index,
                        speaker: "",
                        body: effect.type == 24 ? FullScreenText(effect.value).text : effect.value
                    )
                }
            }
            return nil
        }
    }
}

public struct TranscriptLine: Identifiable, Sendable, Equatable {
    public let snippetIndex: Int
    public let speaker: String
    public let body: String
    
    public var id: Int { snippetIndex }
}
