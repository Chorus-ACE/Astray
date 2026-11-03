internal import AVFAudio
internal import Foundation

@MainActor
internal final class AudioController {
    internal var bgmVolume: Float = 0.7
    internal var voiceVolume: Float = 1
    internal var soundVolume: Float = 1
    internal var onError: ((Error) -> Void)?
    private var clips: [Clip] = []
    private var pending: [Pending] = []
    
    internal var hasBGM: Bool { clips.contains { $0.kind == .bgm } }
    
    internal var isVoicePlaying: Bool { clips.contains { $0.kind == .voice && $0.player.isPlaying } }
    
    internal func play(
        _ data: Data?,
        kind: Kind,
        id: String = "",
        characterID: Int = 0,
        volume: Float = 1,
        fade: Double = 0,
        delay: Double = 0
    ) {
        if delay > 0 {
            pending.append(
                .init(data: data, kind: kind, id: id, characterID: characterID, volume: volume, delay: delay)
            )
            return
        }
        guard let data else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = kind == .bgm ? -1 : 0
            player.isMeteringEnabled = kind == .voice
            if kind == .bgm {
                for clip in clips where clip.kind == .bgm {
                    clip.fadeFrom = clip.gain
                    clip.fadeTo = 0
                    clip.fadeElapsed = 0
                    clip.fadeDuration = fade
                }
            }
            let clip = Clip(player: player, kind: kind, id: id, characterID: characterID, gain: fade > 0 ? 0 : volume)
            clip.onDecodeError = { [weak self] error in self?.onError?(error) }
            clip.fadeTo = volume
            clip.fadeDuration = fade
            player.volume = clip.gain * busVolume(kind)
            player.prepareToPlay()
            guard player.play() else { throw AstrayError.audioPlaybackFailed("Unable to start audio clip \(id).") }
            clips.append(clip)
        } catch {
            onError?(error)
        }
    }
    
    internal func tick(_ delta: Double) {
        for index in pending.indices { pending[index].delay -= delta }
        let ready = pending.filter { $0.delay <= 0 }
        pending.removeAll { $0.delay <= 0 }
        for item in ready {
            play(item.data, kind: item.kind, id: item.id, characterID: item.characterID, volume: item.volume)
        }
        for clip in clips {
            clip.fadeElapsed += delta
            let fraction = clip.fadeDuration > 0 ? Float(min(1, clip.fadeElapsed / clip.fadeDuration)) : 1
            clip.gain = clip.fadeFrom + (clip.fadeTo - clip.fadeFrom) * fraction
            clip.player.volume = clip.gain * busVolume(clip.kind)
            if clip.fadeTo == 0 && fraction >= 1 { clip.stop() }
        }
        clips.removeAll(where: \.hasFinished)
    }
    
    internal func mouthOpen(for characterID: Int, scale: Float) -> Float {
        var rms: Float = 0
        for clip in clips where clip.kind == .voice && clip.characterID == characterID && clip.player.isPlaying {
            clip.player.updateMeters()
            rms = max(rms, pow(10, clip.player.averagePower(forChannel: 0) / 20))
        }
        return LipSync.voiceTarget(rms: rms, scale: scale)
    }
    
    internal func stop(_ kind: Kind? = nil, id: String? = nil) {
        for clip in clips where (kind == nil || clip.kind == kind) && (id == nil || clip.id == id) {
            clip.stop()
        }
        clips.removeAll(where: \.hasFinished)
        pending.removeAll { (kind == nil || $0.kind == kind) && (id == nil || $0.id == id) }
    }
    
    internal func pause() {
        for clip in clips where clip.player.isPlaying {
            clip.wasPaused = true
            clip.player.pause()
        }
    }
    
    internal func resume() {
        for clip in clips where clip.wasPaused {
            clip.player.play()
            clip.wasPaused = false
        }
    }
    
    private func busVolume(_ kind: Kind) -> Float {
        switch kind {
        case .bgm: bgmVolume
        case .voice: voiceVolume
        case .sound: soundVolume
        }
    }
    
    internal enum Kind { case bgm, voice, sound }
    
    @MainActor
    private final class Clip: NSObject, AVAudioPlayerDelegate {
        internal let player: AVAudioPlayer
        internal let kind: Kind
        internal let id: String
        internal let characterID: Int
        internal var gain: Float
        internal var fadeFrom: Float
        internal var fadeTo: Float
        internal var wasPaused = false
        internal var hasFinished = false
        internal var onDecodeError: ((Error) -> Void)?
        internal var fadeElapsed: Double = 0
        internal var fadeDuration: Double = 0
        
        internal init(player: AVAudioPlayer, kind: Kind, id: String, characterID: Int, gain: Float) {
            self.player = player
            self.kind = kind
            self.id = id
            self.characterID = characterID
            self.gain = gain
            fadeFrom = gain
            fadeTo = gain
            super.init()
            player.delegate = self
        }
        
        internal func stop() {
            // A naturally ended player still needs its queued finishedPlaying: delivery.
            if player.isPlaying || wasPaused {
                player.delegate = nil
                player.stop()
                hasFinished = true
            }
        }
        
        internal func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            hasFinished = true
            player.delegate = nil
        }
        
        internal func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            hasFinished = true
            player.delegate = nil
            if let error { onDecodeError?(error) }
        }
    }
    
    private struct Pending {
        internal let data: Data?
        internal let kind: Kind
        internal let id: String
        internal let characterID: Int
        internal let volume: Float
        internal var delay: Double
    }
}
