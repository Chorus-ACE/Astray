public import SwiftUI
internal import MetalKit

public struct AstrayStoryView: View {
    public let renderer: StoryRenderer
    public let contentMode: ContentMode
    public let safeAreaInsets: EdgeInsets
    
    public init(
        renderer: StoryRenderer,
        contentMode: ContentMode = .fill,
        safeAreaInsets: EdgeInsets = .init()
    ) {
        self.renderer = renderer
        self.contentMode = contentMode
        self.safeAreaInsets = safeAreaInsets
    }
    
    public var body: some View {
        StorySurface(renderer: renderer, contentMode: contentMode, safeAreaInsets: safeAreaInsets)
            .id(ObjectIdentifier(renderer))
    }
}

@MainActor
private struct StorySurface {
    internal let renderer: StoryRenderer
    internal let contentMode: ContentMode
    internal let safeAreaInsets: EdgeInsets
    
    private func configure(_ view: _MetalStoryView) {
        view.configure(
            scalesToFill: contentMode == .fill,
            top: safeAreaInsets.top,
            leading: safeAreaInsets.leading,
            bottom: safeAreaInsets.bottom,
            trailing: safeAreaInsets.trailing
        )
    }
}

#if os(macOS)
extension StorySurface: NSViewRepresentable {
    internal func makeNSView(context: Context) -> _MetalStoryView {
        let view = _MetalStoryView(renderer: renderer)
        configure(view)
        return view
    }
    
    internal func updateNSView(_ view: _MetalStoryView, context: Context) { configure(view) }
    
    internal static func dismantleNSView(_ view: _MetalStoryView, coordinator: ()) {
        view.isPaused = true
        view.renderer.player.pause()
    }
}
#else
extension StorySurface: UIViewRepresentable {
    internal func makeUIView(context: Context) -> _MetalStoryView {
        let view = _MetalStoryView(renderer: renderer)
        configure(view)
        return view
    }
    
    internal func updateUIView(_ view: _MetalStoryView, context: Context) { configure(view) }
    
    internal static func dismantleUIView(_ view: _MetalStoryView, coordinator: ()) {
        view.isPaused = true
        view.renderer.player.pause()
    }
}
#endif
