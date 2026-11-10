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
    private var interfaceInsets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) = (0, 0, 0, 0)
    
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
    
    internal func configure(
        scalesToFill: Bool,
        top: CGFloat,
        leading: CGFloat,
        bottom: CGFloat,
        trailing: CGFloat
    ) {
        renderer.scalesToFill = scalesToFill
        interfaceInsets = (top, leading, bottom, trailing)
        synchronizeDrawableSize()
    }
    
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
        renderer.interfaceBounds = .init(
            x: interfaceInsets.leading * size.width / bounds.width,
            y: interfaceInsets.top * size.height / bounds.height,
            width: max(1, bounds.width - interfaceInsets.leading - interfaceInsets.trailing) * size.width
                / bounds.width,
            height: max(1, bounds.height - interfaceInsets.top - interfaceInsets.bottom) * size.height / bounds.height
        )
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
    
    internal func choiceIndex(at point: CGPoint) -> Int? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let viewport = renderer.interfaceViewport(width: Int(drawableSize.width), height: Int(drawableSize.height))
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let x = Float((point.x * drawableSize.width / bounds.width - viewport.originX) / viewport.width)
        let y = Float((point.y * drawableSize.height / bounds.height - viewport.originY) / viewport.height)
        let stage = renderer.player.stage
        return stage.choices.indices.first { index in
            let rect = StoryRenderer.choiceRect(index: index, count: stage.choices.count, scale: stage.choiceScale)
            return x >= rect.x && x <= rect.x + rect.z && y >= rect.y && y <= rect.y + rect.w
        }
    }
    
    private func activate(at point: CGPoint) {
        let player = renderer.player
        if player.stage.choices.isEmpty {
            player.advance()
        } else if let index = choiceIndex(at: point) {
            player.selectChoice(at: index)
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
            modelControls: player.modelControlsRevision,
            assets: player.assetRevision,
            status: player.status,
            hidden: player.isDialogueHidden,
            automatic: player.isAutomatic,
            fast: player.isFastForwarding,
            size: view.drawableSize,
            scalesToFill: renderer.scalesToFill,
            interfaceBounds: renderer.interfaceBounds
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
        internal let modelControls: Int
        internal let assets: Int
        internal let status: PlaybackStatus
        internal let hidden: Bool
        internal let automatic: Bool
        internal let fast: Bool
        internal let size: CGSize
        internal let scalesToFill: Bool
        internal let interfaceBounds: CGRect?
    }
}
