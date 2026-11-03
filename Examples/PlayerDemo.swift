import Astray
import SwiftUI
import Foundation
import UniformTypeIdentifiers

@main
struct AstrayDemoApp: App {
    var body: some Scene {
        WindowGroup { DemoView() }
    }
}

@MainActor
private struct DemoView: View {
    @State private var player: StoryPlayer
    private let renderer: StoryRenderer?
    @AppStorage("LatestAssetRoot") private var assetRoot = ""
    @State private var error: String?
    @State private var isImporting = false
    @State private var showsTranscript = true
    
    init() {
        let player = StoryPlayer()
        _player = State(initialValue: player)
        do {
            renderer = try .init(player: player)
        } catch {
            renderer = nil
            _error = State(initialValue: error.localizedDescription)
        }
    }
    
    var body: some View {
        @Bindable var player = player
        VStack(spacing: 0) {
            HStack {
                Text("Astray").font(.title2.bold())
                Text(player.status.rawValue).foregroundStyle(.secondary)
                Spacer()
                Button("Live2D 示例") { Task { await loadSDKDemo() } }
                Button("效果示例") { Task { await loadSDKDemo("effects_demo") } }
                if let assets = Bundle.main.resourceURL?.appending(path: "HarukiAssets"),
                    FileManager.default.fileExists(atPath: assets.appending(path: "provenance.json").path)
                {
                    Button("真实剧情示例") { Task { await loadHarukiDemo(assets) } }
                }
                Button("打开剧情", systemImage: "doc") { isImporting = true }
                Toggle("台词", isOn: $showsTranscript).toggleStyle(.button)
            }
            .padding()
            HStack(spacing: 0) {
                if let renderer {
                    AstrayStoryView(renderer: renderer)
                        .frame(minWidth: 640, minHeight: 360)
                }
                if showsTranscript {
                    List(player.transcript) { line in
                        Button {
                            do { try player.jump(to: line.snippetIndex) } catch {
                                self.error = error.localizedDescription
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.speaker.isEmpty ? "旁白" : line.speaker).font(.caption.bold())
                                Text(line.body).font(.callout)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            line.snippetIndex == player.snippetIndex ? Color.accentColor.opacity(0.16) : Color.clear
                        )
                    }
                    .frame(width: 280)
                }
            }
            HStack {
                Button(player.status == .playing ? "暂停" : "播放") {
                    if player.status == .playing { player.pause() } else { player.play() }
                }
                Button("重播") {
                    player.stop(); player.play()
                }
                Button("下一句") { player.advance() }
                Toggle("自动", isOn: $player.isAutomatic)
                Toggle("快进", isOn: $player.isFastForwarding)
                Toggle("隐藏文字", isOn: $player.isDialogueHidden)
                Spacer()
                Text(
                    "\(min(player.snippetIndex + 1, player.scenario?.snippets.count ?? 0)) / \(player.scenario?.snippets.count ?? 0)"
                )
                .monospacedDigit()
            }
            .padding()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("素材根目录 / URL")
                    TextField("可留空，仅播放文字和转场", text: $assetRoot)
                        .textFieldStyle(.roundedBorder)
                }
                if let url = URL(string: assetRoot), let root = HarukiAssetResolver.japaneseAssetRoot(for: url) {
                    Text("Haruki 播放素材：\(root.absoluteString)（与网页一致，保留导入的剧情文本）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding([.horizontal, .bottom])
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding([.horizontal, .bottom])
            }
        }
        .frame(minWidth: 960, minHeight: 580)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await load(url) }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .onDisappear { player.onEvent = nil }
        .task {
            player.onEvent = { event in
                switch event {
                case .warning(let warning): error = warning.localizedDescription
                case .unsupportedAction(_, _, let detail): error = detail
                default: break
                }
            }
            if let url = Bundle.main.url(forResource: "demo", withExtension: "json") { await load(url) }
        }
    }
    
    private func loadHarukiDemo(_ assets: URL) async {
        error = nil
        do {
            try await player.load(id: "mmj_01_06", resolver: DirectoryAssetResolver(baseURL: assets))
            player.play()
        } catch { self.error = error.localizedDescription }
    }
    
    private func loadSDKDemo(_ name: String = "live2d_demo") async {
        guard let assets = Bundle.main.resourceURL?.appending(path: "SDKAssets"),
            let scenario = Bundle.main.url(forResource: name, withExtension: "json")
        else { return }
        error = nil
        do {
            try await player.load(data: Data(contentsOf: scenario), resolver: SDKDemoResolver(baseURL: assets))
            player.play()
        } catch { self.error = error.localizedDescription }
    }
    
    private func load(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        error = nil
        do {
            let scenario = try Scenario.decode(Data(contentsOf: url))
            let resolver: (any AssetResolving)?
            if assetRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolver = nil
            } else {
                let input = assetRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                let root =
                    input.hasPrefix("https://") || input.hasPrefix("http://")
                    ? URL(string: input) : URL(fileURLWithPath: input, isDirectory: true)
                guard let root else { throw AstrayError.invalidScenario("Invalid asset URL.") }
                if HarukiAssetResolver.japaneseAssetRoot(for: root) != nil {
                    resolver = try await HarukiAssetResolver(baseURL: root, scenario: scenario)
                } else {
                    resolver = DirectoryAssetResolver(baseURL: root)
                }
            }
            try await player.load(scenario, resolver: resolver)
            player.play()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SDKDemoResolver: AssetResolving {
    let baseURL: URL
    
    func url(for request: AssetRequest) -> URL? {
        switch request {
        case .modelManifest, .model, .resource: DirectoryAssetResolver(baseURL: baseURL).url(for: request)
        case .effect(let path) where !path.hasPrefix("bg/"): DirectoryAssetResolver(baseURL: baseURL).url(for: request)
        default: nil
        }
    }
}
