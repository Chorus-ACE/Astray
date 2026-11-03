import Foundation
@testable import Astray

@main
@MainActor
private struct AudioLifetimeTests {
    private static func main() async throws {
        let controller = AudioController()
        controller.voiceVolume = 0
        var errors = 0
        controller.onError = { _ in errors += 1 }
        let sound = tone()
        for attempt in 0..<8 {
            controller.play(sound, kind: .voice)
            guard controller.isVoicePlaying else { throw Failure.playback }
            try waitForPlaybackEnd(controller)
            if attempt.isMultiple(of: 2) { controller.tick(1 / 60) } else { controller.stop(.voice) }
            try await Task.sleep(for: .milliseconds(40))
            controller.tick(1 / 60)
        }
        controller.play(sound, kind: .voice)
        controller.pause()
        controller.tick(1 / 60)
        controller.resume()
        guard controller.isVoicePlaying else { throw Failure.pause }
        controller.stop()
        try await Task.sleep(for: .milliseconds(150))
        guard errors == 0 else { throw Failure.decode }
        print(
            "PASS: audio completion survives cleanup before queued finish callbacks, explicit stop, pause and resume."
        )
    }
    
    private static func waitForPlaybackEnd(_ controller: AudioController) throws {
        // Keep finish delivery queued while cleanup observes playback has already ended.
        let deadline = Date.now.addingTimeInterval(3)
        while controller.isVoicePlaying {
            guard Date.now < deadline else { throw Failure.timeout }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    
    private static func tone() -> Data {
        var result = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        let samples = 4410
        result.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples * 2))
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(44100))
        append(UInt32(88200))
        append(UInt16(2))
        append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(UInt32(samples * 2))
        result.append(Data(repeating: 0, count: samples * 2))
        return result
    }
    
    private enum Failure: Error { case playback, pause, timeout, decode }
}
