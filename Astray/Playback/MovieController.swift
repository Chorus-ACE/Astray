internal import Metal
internal import CoreMedia
internal import CoreVideo
internal import Foundation
internal import AVFoundation

internal struct MovieAsset: Sendable {
    internal let url: URL
    internal let duration: Double
}

internal enum MovieAssetLoader {
    internal static func load(
        scenario: Scenario,
        resolver: any AssetResolving,
        warning: @MainActor (AstrayError) -> Void
    ) async throws -> [String: MovieAsset] {
        var result: [String: MovieAsset] = [:]
        for name in Set(scenario.effects.filter { $0.type == 19 }.map(\.value)) {
            guard let url = resolver.url(for: .movie(name)) else { continue }
            do {
                guard let localURL = try await resolver.fileURL(for: .movie(name)) else { continue }
                let asset = AVURLAsset(url: localURL)
                let time = try await asset.load(.duration)
                guard time.seconds.isFinite, time.seconds > 0 else {
                    throw AstrayError.invalidScenario("Invalid movie duration.")
                }
                result[name] = .init(url: localURL, duration: time.seconds)
            } catch is CancellationError { throw CancellationError() } catch {
                await warning(.assetUnavailable(url, error.localizedDescription))
            }
        }
        return result
    }
}

@MainActor
internal final class MovieController {
    internal private(set) var isVisible = false
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var cache: CVMetalTextureCache?
    private var frame: VideoFrame?
    private var asset: MovieAsset?
    private var started = false
    private var startupDeadline: Double = 0
    
    internal var time: Double { player?.currentTime().seconds ?? 0 }
    internal var remaining: Double { max(0, (asset?.duration ?? 0) - time) }
    internal var isFinished: Bool {
        guard let player else { return true }
        if player.currentItem?.status == .failed { return true }
        if !isVisible && started && ProcessInfo.processInfo.systemUptime > startupDeadline { return true }
        return isVisible && remaining < 0.02
    }
    
    internal func prepare(_ asset: MovieAsset) {
        stop()
        self.asset = asset
        let item = AVPlayerItem(asset: AVURLAsset(url: asset.url))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        self.output = output
        player = AVPlayer(playerItem: item)
        player?.actionAtItemEnd = .pause
        player?.automaticallyWaitsToMinimizeStalling = true
    }
    
    internal func start() {
        guard !started else { return }
        started = true
        startupDeadline = ProcessInfo.processInfo.systemUptime + 20
        player?.play()
    }
    
    internal func pause() { player?.pause() }
    internal func resume() { if started { player?.play() } }
    
    internal func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        output = nil
        frame = nil
        asset = nil
        started = false
        isVisible = false
    }
    
    internal func texture(device: any MTLDevice, commandBuffer: any MTLCommandBuffer) throws -> (any MTLTexture)? {
        guard started, let player, let output else { return nil }
        if cache == nil {
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            guard status == kCVReturnSuccess else {
                throw AstrayError.renderingFailed("Unable to create a movie Metal texture cache.")
            }
        }
        if output.hasNewPixelBuffer(forItemTime: player.currentTime()),
            let pixels = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil), let cache
        {
            var wrapper: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixels,
                nil,
                .bgra8Unorm,
                CVPixelBufferGetWidth(pixels),
                CVPixelBufferGetHeight(pixels),
                0,
                &wrapper
            )
            if status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) {
                frame = .init(wrapper: wrapper, texture: texture)
                isVisible = true
            }
        }
        guard let frame else { return nil }
        commandBuffer.addCompletedHandler { [frame] _ in withExtendedLifetime(frame) {} }
        return frame.texture
    }
}

private final class VideoFrame: @unchecked Sendable {
    internal let wrapper: CVMetalTexture
    internal let texture: any MTLTexture
    
    internal init(wrapper: CVMetalTexture, texture: any MTLTexture) {
        self.wrapper = wrapper
        self.texture = texture
    }
}
