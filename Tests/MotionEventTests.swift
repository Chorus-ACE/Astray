import Foundation
import AstrayCubismBridge

@main
@MainActor
private struct MotionEventTests {
    private static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let haru = root.appending(path: "Vendor/CubismNativeSamples/Samples/Resources/Haru")
        let moc = try Data(contentsOf: haru.appending(path: "Haru.moc3"))
        let clip = eventMotion()
        let model = try ASRCubismModel(moc: moc, physics: nil, pose: nil)
        try model.loadMotion(clip, name: "body", facial: false)
        try model.loadMotion(clip, name: "facial", facial: true)
        for (body, facial) in [("body", ""), ("", "facial"), ("body", "facial")] {
            model.reset()
            model.playMotion(body, facial: facial, instant: true)
            model.update(0, time: 0, mouth: 0)
            for frame in 1...60 {
                if frame == 10 { model.playMotion(body, facial: facial, instant: false) }
                model.update(1 / 60, time: Double(frame) / 60, mouth: 0)
            }
            guard !model.drawables.isEmpty else { throw Failure.noDrawables }
            model.playMotion(body, facial: facial, instant: false)
            model.update(0.5, time: 1.5, mouth: 0)
        }
        print("PASS: body and facial motion UserData events survive playback, overlapping restarts and resets.")
    }
    
    private static func eventMotion() -> Data {
        Data(
            """
            {
                "Version": 3,
                "Meta": {
                    "Duration": 1, "Fps": 30, "Loop": false, "AreBeziersRestricted": true,
                    "CurveCount": 1, "TotalSegmentCount": 1, "TotalPointCount": 2,
                    "UserDataCount": 2, "TotalUserDataSize": 38
                },
                "Curves": [{"Target": "Parameter", "Id": "ParamAngleX", "Segments": [
                    0, 0, 0, 1, 15
                ]}],
                "UserData": [
                    {"Time": 0.05, "Value": "eyeblink,0.2,1.22,0.3"},
                    {"Time": 0.25, "Value": "regression-marker"}
                ]
            }
            """.utf8
        )
    }
    
    private enum Failure: Error { case noDrawables }
}
