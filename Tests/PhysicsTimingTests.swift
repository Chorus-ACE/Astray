import Foundation
@testable import Astray
import AstrayCubismBridge

@main
@MainActor
private struct PhysicsTimingTests {
    private static var motion: Data {
        Data(
            """
            {
                "Version": 3,
                "Meta": {
                    "Duration": 12, "Fps": 30, "Loop": false, "AreBeziersRestricted": true,
                    "CurveCount": 1, "TotalSegmentCount": 6, "TotalPointCount": 7
                },
                "Curves": [{"Target": "Parameter", "Id": "ParamAngleX", "Segments": [
                    0, 0, 0, 2, 30, 0, 4, -30, 0, 6, 30, 0, 8, -30, 0, 10, 0, 0, 12, 0
                ]}]
            }
            """.utf8
        )
    }
    
    private static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directories: [URL]
        if CommandLine.arguments.contains("--real") {
            let models = root.appending(path: ".build/HarukiAssets/models")
            directories = try FileManager.default.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)
                .sorted { $0.path < $1.path }
        } else {
            directories = [root.appending(path: "Vendor/CubismNativeSamples/Samples/Resources/Haru")]
        }
        guard !directories.isEmpty else { throw Failure.message("No physics fixtures found") }
        for directory in directories {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard let moc = files.first(where: { $0.pathExtension == "moc3" }),
                let physics = files.first(where: { $0.lastPathComponent.hasSuffix("physics3.json") })
            else { throw Failure.message("Missing model or physics: \(directory.path)") }
            let mocData = try Data(contentsOf: moc)
            let physicsData = try Data(contentsOf: physics)
            for epsilon in [1.1e-8, 1e-6] {
                try verifyJitter(
                    moc: mocData,
                    physics: physicsData,
                    epsilon: epsilon,
                    label: directory.lastPathComponent
                )
            }
            try verifyLongFrames(moc: mocData, physics: physicsData)
        }
        print("PASS: Cubism physics remains continuous under display-clock jitter and evenly subdivided long frames.")
    }
    
    private static func verifyJitter(moc: Data, physics: Data, epsilon: Double, label: String) throws {
        let steady = try model(moc: moc, physics: physics)
        let jittered = try model(moc: moc, physics: physics)
        var previousSteady = positions(steady)
        var previousJittered = positions(jittered)
        var peakError: Float = 0
        var peakSteadyStep: Float = 0
        var peakJitteredStep: Float = 0
        for frame in 0..<600 {
            steady.update(1 / 60, time: 0, mouth: 0)
            Live2DRenderer.advance(
                jittered,
                by: 1 / 60 + (frame.isMultiple(of: 2) ? epsilon : -epsilon),
                time: 0,
                mouth: 0
            )
            let a = positions(steady)
            let b = positions(jittered)
            peakError = max(peakError, difference(a, b))
            peakSteadyStep = max(peakSteadyStep, difference(a, previousSteady))
            peakJitteredStep = max(peakJitteredStep, difference(b, previousJittered))
            previousSteady = a
            previousJittered = b
        }
        guard peakError < steady.canvasHeight * 0.0001,
            peakJitteredStep < peakSteadyStep * 2 + steady.canvasHeight * 0.00001
        else {
            throw Failure.message(
                "\(label), jitter \(epsilon): vertex error \(peakError), frame displacement \(peakJitteredStep) vs steady \(peakSteadyStep)"
            )
        }
        print("PASS: \(label), jitter \(epsilon), peak vertex error \(peakError), displacement \(peakJitteredStep).")
    }
    
    private static func verifyLongFrames(moc: Data, physics: Data) throws {
        let steady = try model(moc: moc, physics: physics)
        let batched = try model(moc: moc, physics: physics)
        var steps = 0
        for count in Array(repeating: [2, 3, 6, 15], count: 20).joined() {
            for _ in 0..<count { steady.update(1 / 60, time: 0, mouth: 0) }
            Live2DRenderer.advance(batched, by: Double(count) / 60, time: 0, mouth: 0)
            guard difference(positions(steady), positions(batched)) < steady.canvasHeight * 0.00001 else {
                throw Failure.message("Long frames changed the physical trajectory or lost elapsed motion time")
            }
            steps += count
        }
        let before = positions(batched)
        Live2DRenderer.advance(batched, by: 0, time: 0, mouth: 0)
        guard positions(batched) == before, steps > 500 else { throw Failure.message("Paused physics advanced") }
    }
    
    private static func model(moc: Data, physics: Data) throws -> ASRCubismModel {
        let model = try ASRCubismModel(moc: moc, physics: physics, pose: nil)
        try model.loadMotion(motion, name: "test", facial: false)
        model.playMotion("test", facial: "", instant: true)
        model.update(0, time: 0, mouth: 0)
        return model
    }
    
    private static func positions(_ model: ASRCubismModel) -> [Float] {
        model.drawables.flatMap { drawable in
            drawable.positions.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }
    
    private static func difference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
    
    private enum Failure: Error { case message(String) }
}
