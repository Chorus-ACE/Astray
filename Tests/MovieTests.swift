import Metal
import CoreMedia
import CoreVideo
import Foundation
import AVFoundation
@testable import Astray

@main
@MainActor
private struct MovieTests {
    private static func wait(_ buffer: any MTLCommandBuffer) { buffer.waitUntilCompleted() }
    
    private static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(
            path: ".build/TestArtifacts/Movie"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: UUID().uuidString + ".mp4")
        try await makeMovie(at: url)
        let player = StoryPlayer()
        var warnings: [String] = []
        player.onEvent = { if case .warning(let error) = $0 { warnings.append(error.localizedDescription) } }
        try await player.load(
            .init(
                snippets: [
                    .init(action: .specialEffect, referenceIndex: 0),
                    .init(action: .talk, progressBehavior: .waitFinished, referenceIndex: 0),
                ],
                talks: [.init(body: "After movie")],
                effects: [.init(type: 19, value: "clip")]
            ),
            resolver: Resolver(url: url)
        )
        let renderer = try StoryRenderer(player: player)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 640,
            height: 360,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let target = renderer.device.makeTexture(descriptor: descriptor)!
        var videoPixels = false
        var testedPause = false
        player.play()
        for _ in 0..<500 {
            player.update(at: ProcessInfo.processInfo.systemUptime)
            let buffer = try renderer.render(to: target)
            wait(buffer)
            guard buffer.status == .completed else { throw TestError.failure("Movie GPU buffer failed") }
            if player.movie.isVisible && player.stage.cover.w < 0.2 {
                var pixel: UInt32 = 0
                target.getBytes(
                    &pixel,
                    bytesPerRow: 4,
                    from: .init(origin: .init(x: 320, y: 180, z: 0), size: .init(width: 1, height: 1, depth: 1)),
                    mipmapLevel: 0
                )
                videoPixels = videoPixels || (pixel & 255) > 150
            }
            if !testedPause && player.movie.isVisible && player.movie.time >= 0.25 {
                player.pause()
                let time = player.movie.time
                try await Task.sleep(for: .milliseconds(120))
                guard abs(player.movie.time - time) < 0.04 else {
                    throw TestError.failure("Pausing did not freeze native video")
                }
                player.play()
                testedPause = true
            }
            if player.dialogue.body == "After movie" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard testedPause, videoPixels, player.dialogue.body == "After movie", warnings.isEmpty else {
            throw TestError.failure(
                "Movie did not complete correctly: pause=\(testedPause), pixels=\(videoPixels), dialogue=\(player.dialogue.body), warnings=\(warnings)"
            )
        }
        player.stop()
        print(
            "PASS: native movie decode, CVMetalTexture video frames, cover fades, pause/resume and timeline completion."
        )
    }
    
    private static func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw TestError.failure("AVAssetWriter start failed") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<40 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixels: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixels) == kCVReturnSuccess, let pixels
            else { throw TestError.failure("Video fixture pixel pool") }
            CVPixelBufferLockBaseAddress(pixels, [])
            let address = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<180 {
                for x in 0..<320 {
                    let pixel = address.advanced(by: y * stride + x * 4)
                    pixel[0] = 220
                    pixel[1] = UInt8(index * 3)
                    pixel[2] = 20
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: .init(value: Int64(index), timescale: 20)) else {
                throw TestError.failure("Video fixture frame append")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else {
            throw TestError.failure("Video fixture failed: \(String(describing: writer.error))")
        }
    }
    
    private struct Resolver: AssetResolving {
        let url: URL
        func url(for request: AssetRequest) -> URL? {
            if case .movie = request { return url }
            return nil
        }
    }
    
    private enum TestError: Error { case failure(String) }
}
