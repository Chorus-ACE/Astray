public import MetalKit
internal import Foundation
internal import QuartzCore

@MainActor
public final class _MetalStoryView: MTKView {
    internal static func pixelSize(for size: CGSize, scale: CGFloat) -> CGSize {
        .init(width: ceil(size.width * scale), height: ceil(size.height * scale))
    }
    
    public let renderer: StoryRenderer
    private let driver: StoryViewDriver
    
    public init(renderer: StoryRenderer) {
        self.renderer = renderer
        driver = .init(renderer: renderer)
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 120
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = driver
        #if os(macOS)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Story player")
        setAccessibilityHelp("Press Space to reveal or advance dialogue.")
        #else
        isAccessibilityElement = true
        accessibilityLabel = "Story player"
        accessibilityTraits = .button
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: _MetalStoryView, _: UITraitCollection) in
            view.synchronizeDrawableSize()
        }
        #endif
    }
    
    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("Use init(renderer:).") }
    
    private func synchronizeDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        #if os(macOS)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer?.contentsScale = scale
        #else
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        contentScaleFactor = scale
        #endif
        let size = Self.pixelSize(for: bounds.size, scale: scale)
        if drawableSize != size { drawableSize = size }
    }
    
    #if os(macOS)
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronizeDrawableSize() }
    
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); synchronizeDrawableSize()
    }
    
    public override func layout() { super.layout(); synchronizeDrawableSize() }
    
    public override var acceptsFirstResponder: Bool { true }
    
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        activate(at: .init(x: point.x, y: bounds.height - point.y))
    }
    
    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            renderer.player.advance()
        } else {
            super.keyDown(with: event)
        }
    }
    
    public override func accessibilityPerformPress() -> Bool {
        renderer.player.advance()
        return true
    }
    #else
    public override func didMoveToWindow() { super.didMoveToWindow(); synchronizeDrawableSize() }
    
    public override func layoutSubviews() { super.layoutSubviews(); synchronizeDrawableSize() }
    
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        activate(at: point)
    }
    
    public override func accessibilityActivate() -> Bool {
        renderer.player.advance()
        return true
    }
    #endif
    
    private func activate(at point: CGPoint) {
        let viewport = StoryRenderer.viewport(width: Int(bounds.width), height: Int(bounds.height))
        guard viewport.width > 0, viewport.height > 0 else { return }
        let x = Float((point.x - viewport.originX) / viewport.width)
        let y = Float((point.y - viewport.originY) / viewport.height)
        guard (0...1).contains(x), (0...1).contains(y) else { return }
        let player = renderer.player
        if player.stage.choices.isEmpty {
            player.advance()
        } else {
            for index in player.stage.choices.indices {
                let rect = StoryRenderer.choiceRect(index: index, count: player.stage.choices.count)
                if x >= rect.x, x <= rect.x + rect.z, y >= rect.y, y <= rect.y + rect.w {
                    player.selectChoice(at: index)
                    break
                }
            }
        }
    }
}

@MainActor
private final class StoryViewDriver: NSObject, MTKViewDelegate {
    private let renderer: StoryRenderer
    private var reportedFailure = false
    private var lastState: State?
    
    internal init(renderer: StoryRenderer) { self.renderer = renderer }
    
    internal func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { lastState = nil }
    
    internal func draw(in view: MTKView) {
        let player = renderer.player
        let state = State(
            revision: player.renderRevision,
            assets: player.assetRevision,
            status: player.status,
            hidden: player.isDialogueHidden,
            automatic: player.isAutomatic,
            fast: player.isFastForwarding,
            size: view.drawableSize
        )
        if player.status != .playing && player.status != .finished && lastState == state { return }
        guard let drawable = view.currentDrawable else { return }
        renderer.player.update(at: CACurrentMediaTime())
        do {
            try renderer.render(to: drawable.texture, presenting: drawable)
            reportedFailure = false
            lastState = state
        } catch {
            if !reportedFailure {
                renderer.player.onEvent?(.warning(.renderingFailed(error.localizedDescription)))
                reportedFailure = true
            }
        }
    }
    
    private struct State: Equatable {
        internal let revision: Int
        internal let assets: Int
        internal let status: PlaybackStatus
        internal let hidden: Bool
        internal let automatic: Bool
        internal let fast: Bool
        internal let size: CGSize
    }
}
