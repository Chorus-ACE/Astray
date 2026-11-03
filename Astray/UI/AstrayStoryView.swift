public import SwiftUI
internal import MetalKit

public struct AstrayStoryView: View {
    public let renderer: StoryRenderer
    
    public init(renderer: StoryRenderer) {
        self.renderer = renderer
    }
    
    public var body: some View {
        StorySurface(renderer: renderer)
            .id(ObjectIdentifier(renderer))
    }
}

private struct StorySurface {
    internal let renderer: StoryRenderer
}

#if os(macOS)
extension StorySurface: NSViewRepresentable {
    internal func makeNSView(context: Context) -> _MetalStoryView {
        .init(renderer: renderer)
    }
    
    internal func updateNSView(_ view: _MetalStoryView, context: Context) {}
    
    internal static func dismantleNSView(_ view: _MetalStoryView, coordinator: ()) {
        view.isPaused = true
        view.renderer.player.pause()
    }
}
#else
extension StorySurface: UIViewRepresentable {
    internal func makeUIView(context: Context) -> _MetalStoryView {
        .init(renderer: renderer)
    }
    
    internal func updateUIView(_ view: _MetalStoryView, context: Context) {}
    
    internal static func dismantleUIView(_ view: _MetalStoryView, coordinator: ()) {
        view.isPaused = true
        view.renderer.player.pause()
    }
}
#endif
