import Metal
import Astray
import Foundation

@main
@MainActor
private struct RenderPerformanceTests {
    private static func complete(_ buffer: any MTLCommandBuffer) { buffer.waitUntilCompleted() }
    
    private static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let real = try Scenario.decode(
            Data(contentsOf: root.appending(path: ".build/HarukiAssets/scenario/mmj_01_06.json"))
        )
        let layouts = real.characters.prefix(3).enumerated().map { index, character in
            let pose = real.layouts.first { $0.characterID == character.characterID }
            return ScenarioInitialLayout(
                side: [3, 4, 5][index],
                characterID: character.characterID,
                costume: character.costume,
                motion: pose?.motion ?? "",
                facial: pose?.facial ?? ""
            )
        }
        let isStatic = CommandLine.arguments.contains("--static")
        let name =
            (CommandLine.arguments.contains("--baseline") ? "baseline" : "optimized")
            + (isStatic ? "-static" : "")
        let scene = Scenario(
            initialLayout: layouts,
            initialBackground: isStatic ? "bg_b001001" : "bg_b001002",
            snippets: [.init(delay: 30)]
        )
        let resolver = DirectoryAssetResolver(baseURL: root.appending(path: ".build/HarukiAssets"))
        var results: [[String: Any]] = []
        for scale in [1, 2] {
            let player = StoryPlayer()
            var warnings: [String] = []
            player.onEvent = { if case .warning(let error) = $0 { warnings.append(error.localizedDescription) } }
            try await player.load(scene, resolver: resolver)
            let renderer = try StoryRenderer(player: player)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 1280 * scale,
                height: 720 * scale,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let target = renderer.device.makeTexture(descriptor: descriptor)!
            var cpu: [Double] = [], gpu: [Double] = []
            player.play()
            for frame in 0..<90 {
                try autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    player.advance(by: 1 / 120)
                    let buffer = try renderer.render(to: target)
                    let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    complete(buffer)
                    guard buffer.status == .completed else { throw Failure.gpu }
                    if frame >= 30 {
                        cpu.append(duration)
                        gpu.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
                    }
                }
            }
            guard warnings.isEmpty else { throw Failure.warning(warnings.joined(separator: "\n")) }
            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                let sorted = values.sorted()
                return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
            }
            let row: [String: Any] = [
                "scale": scale, "width": target.width, "height": target.height,
                "cpuMedianMs": percentile(cpu, 0.5), "cpuP95Ms": percentile(cpu, 0.95),
                "gpuMedianMs": percentile(gpu, 0.5), "gpuP95Ms": percentile(gpu, 0.95),
                "allocatedBytes": renderer.device.currentAllocatedSize, "device": renderer.device.name,
            ]
            results.append(row)
            print(row)
            var pixels = [UInt8](repeating: 0, count: target.width * target.height * 4)
            target.getBytes(
                &pixels,
                bytesPerRow: target.width * 4,
                from: .init(
                    origin: .init(x: 0, y: 0, z: 0),
                    size: .init(width: target.width, height: target.height, depth: 1)
                ),
                mipmapLevel: 0
            )
            let output = root.appending(path: ".build/TestArtifacts/Performance")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(pixels).write(to: output.appending(path: "\(name)-\(scale).bgra"))
        }
        let output = root.appending(path: ".build/TestArtifacts/Performance/\(name).json")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
    
    private enum Failure: Error { case gpu, warning(String) }
}
