import AppKit
import SwiftUI

/// Wraps a terminal window's content with the agent sidebar: a draggable-width
/// column on the left, a thin divider handle, terminal content filling the
/// rest. The width is shared across windows and persists across launches in
/// UserDefaults ("AgentSidebarWidth").
final class AgentSidebarContainerView: NSView {
    private static let widthDefaultsKey = "AgentSidebarWidth"
    private static let defaultWidth: CGFloat = 200
    private static let minWidth: CGFloat = 120
    private static let handleWidth: CGFloat = 6

    /// Posted when any container persists a new width so every other window's
    /// sidebar follows (all sidebars share one width).
    private static let widthDidChange = Notification.Name("AgentSidebarWidthDidChange")

    private let sidebarView: NSView
    private let terminalContent: NSView
    private let handle = DragHandleView()
    private let config: Ghostty.Config
    private var widthObserver: NSObjectProtocol?

    /// Sidebar column width in points.
    private var sidebarWidth: CGFloat

    /// Width at the start of the current drag; deltas apply against this.
    private var dragStartWidth: CGFloat = 0

    init(config: Ghostty.Config, terminalContent: NSView, ownWindow: NSWindow?) {
        self.terminalContent = terminalContent
        self.config = config
        let stored = UserDefaults.ghostty.double(forKey: Self.widthDefaultsKey)
        self.sidebarWidth = stored > 0 ? CGFloat(stored) : Self.defaultWidth
        self.sidebarView = NSHostingView(rootView: AgentSidebarView(
            model: AgentSidebarModel.shared,
            ownWindow: ownWindow,
            config: config
        ))
        super.init(frame: .zero)
        addSubview(sidebarView)
        addSubview(handle)
        addSubview(terminalContent)

        handle.onDragStart = { [weak self] in
            guard let self else { return }
            self.dragStartWidth = self.sidebarWidth
        }
        handle.onDrag = { [weak self] delta in
            self?.applyDrag(delta)
        }
        handle.onDragEnd = { [weak self] in
            self?.persistWidth()
        }

        widthObserver = NotificationCenter.default.addObserver(
            forName: Self.widthDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadPersistedWidth()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let widthObserver {
            NotificationCenter.default.removeObserver(widthObserver)
        }
    }

    override var intrinsicContentSize: NSSize {
        var size = terminalContent.intrinsicContentSize
        if size.width > 0 { size.width += sidebarWidth + Self.handleWidth }
        return size
    }

    override func layout() {
        super.layout()
        // A shrunken window can push the sidebar past the 50% max; clamp here.
        let width = clampedWidth(sidebarWidth, for: bounds.width)
        if width != sidebarWidth { sidebarWidth = width }

        sidebarView.frame = NSRect(
            x: 0, y: 0,
            width: width, height: bounds.height)
        handle.frame = NSRect(
            x: width, y: 0,
            width: Self.handleWidth, height: bounds.height)
        // The handle strip must read as part of the sidebar: paint it the
        // sidebar's background or the window's vibrancy bleeds through as a
        // bright stripe. Config colors read live, so this tracks reloads.
        handle.sidebarBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)
        terminalContent.frame = NSRect(
            x: width + Self.handleWidth, y: 0,
            width: max(0, bounds.width - width - Self.handleWidth),
            height: bounds.height)
    }

    // MARK: - Width

    /// Clamp to [minWidth, 50% of the container width]. The min wins when the
    /// container is too narrow to satisfy both.
    private func clampedWidth(_ proposed: CGFloat, for containerWidth: CGFloat) -> CGFloat {
        let maxWidth = containerWidth > 0 ? containerWidth * 0.5 : .greatestFiniteMagnitude
        return min(max(proposed, Self.minWidth), max(maxWidth, Self.minWidth))
    }

    private func applyDrag(_ delta: CGFloat) {
        let newWidth = clampedWidth(dragStartWidth + delta, for: bounds.width)
        guard newWidth != sidebarWidth else { return }
        sidebarWidth = newWidth
        invalidateIntrinsicContentSize()
        // Relayout synchronously so the terminal resizes live during the drag.
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func persistWidth() {
        UserDefaults.ghostty.set(Double(sidebarWidth), forKey: Self.widthDefaultsKey)
        NotificationCenter.default.post(name: Self.widthDidChange, object: nil)
    }

    private func reloadPersistedWidth() {
        let stored = UserDefaults.ghostty.double(forKey: Self.widthDefaultsKey)
        let newWidth = clampedWidth(stored > 0 ? CGFloat(stored) : Self.defaultWidth, for: bounds.width)
        guard newWidth != sidebarWidth else { return }
        sidebarWidth = newWidth
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

/// The draggable divider between sidebar and terminal content. Drag deltas
/// are computed in screen coordinates so the math stays stable while the
/// view itself moves during the drag.
private final class DragHandleView: NSView {
    var onDragStart: () -> Void = {}
    var onDrag: (_ delta: CGFloat) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    /// Full-strip background matching the sidebar; set by the container.
    var sidebarBackgroundColor: NSColor = .clear {
        didSet { layer?.backgroundColor = sidebarBackgroundColor.cgColor }
    }

    private let line = NSView()
    private var dragStartScreenX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(line)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // A 1pt hairline centered in the handle strip.
        line.frame = NSRect(
            x: (bounds.width - 1) / 2, y: 0,
            width: 1, height: bounds.height)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenX = NSEvent.mouseLocation.x
        onDragStart()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag(NSEvent.mouseLocation.x - dragStartScreenX)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd()
    }
}
