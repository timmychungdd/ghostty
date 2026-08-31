import AppKit
import SwiftUI

/// NSHostingView that reports when it (re)joins a live render loop:
/// attached to a window and about to draw. Used to re-fire the sidebar's
/// published invalidation at the exact moment it can be consumed.
final class SidebarHostingView: NSHostingView<AgentSidebarView> {
    var onLiveRenderLoopJoin: (() -> Void)?
    /// Cooldown so draw storms cannot spam the generation counter.
    private var lastJoinFire: Date = .distantPast

    private func fireJoin() {
        let now = Date()
        guard now.timeIntervalSince(lastJoinFire) > 0.25 else { return }
        lastJoinFire = now
        sidebarDbg.log("[SIDEBAR-DBG] hosting view joined live render loop (win#\(self.window?.windowNumber ?? -1, privacy: .public)) -> generation bump")
        onLiveRenderLoopJoin?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { fireJoin() }
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        if window != nil { fireJoin() }
    }
}

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

    private var sidebarView: SidebarHostingView
    private let terminalContent: NSView
    private let handle = DragHandleView()
    private let config: Ghostty.Config
    private weak var ownWindow: NSWindow?
    private var widthObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var revealWorkItem: DispatchWorkItem?

    /// Sidebar column width in points.
    private var sidebarWidth: CGFloat

    /// Width at the start of the current drag; deltas apply against this.
    private var dragStartWidth: CGFloat = 0

    init(config: Ghostty.Config, terminalContent: NSView, ownWindow: NSWindow?) {
        self.terminalContent = terminalContent
        self.config = config
        self.ownWindow = ownWindow
        let stored = UserDefaults.ghostty.double(forKey: Self.widthDefaultsKey)
        self.sidebarWidth = stored > 0 ? CGFloat(stored) : Self.defaultWidth
        self.sidebarView = SidebarHostingView(rootView: AgentSidebarView(
            model: AgentSidebarModel.shared,
            ownWindow: ownWindow,
            config: config
        ))
        // The hosting view of a tab-group's FIRST window drops out of
        // SwiftUI's render loop when the group forms; published
        // invalidations fired while detached are discarded, so the sidebar
        // keeps rendering its frozen solo snapshot on reveal. Bump the
        // generation when the view re-attaches / is about to draw — the
        // invalidation then lands inside a live render loop.
        sidebarView.onLiveRenderLoopJoin = {
            AgentSidebarModel.shared.noteWindowListChanged()
        }
        sidebarDbg.log("[SIDEBAR-DBG] container init: ownWindow=\(ownWindow == nil ? "nil" : "win#\(ownWindow!.windowNumber)", privacy: .public)")
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

        // Reveal refresh. Instrumented Debug evidence (round 3): the
        // hosting view of a tab-group's FIRST window never re-evaluates its
        // SwiftUI body after the group forms — generation bumps, rootView
        // reassignment, viewDidMoveToWindow, and viewWillDraw all fail to
        // reach it while/revealed; its window backing store stays a frozen
        // solo render until a full cycle away and back. The one path that
        // provably yields a fresh evaluation is the creation path: a NEW
        // hosting view added to a live window evaluates immediately. So on
        // reveal, replace the hosting view with a fresh instance (and once
        // more after AppKit's transition settles, coalesced).
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: ownWindow, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let winDesc = self.ownWindow == nil ? "nil" : "win#\(self.ownWindow!.windowNumber)"
            sidebarDbg.log("[SIDEBAR-DBG] reveal: ownWindow=\(winDesc, privacy: .public) -> sidebar view swap")
            self.replaceSidebarView("reveal")
            self.revealWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                sidebarDbg.log("[SIDEBAR-DBG] reveal settle+0.1s: ownWindow=\(winDesc, privacy: .public) -> sidebar view swap")
                self?.replaceSidebarView("settle")
            }
            self.revealWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
    }

    /// Swap in a fresh hosting view so the sidebar re-evaluates from current
    /// model state — a new hosting view attached to a live window renders
    /// immediately, which frozen parked-window hosting views never do.
    private func replaceSidebarView(_ reason: String) {
        let winDesc = ownWindow == nil ? "nil" : "win#\(ownWindow!.windowNumber)"
        sidebarDbg.log("[SIDEBAR-DBG] replaceSidebarView(\(reason, privacy: .public)): ownWindow=\(winDesc, privacy: .public)")
        let fresh = SidebarHostingView(rootView: AgentSidebarView(
            model: AgentSidebarModel.shared,
            ownWindow: ownWindow,
            config: config
        ))
        fresh.onLiveRenderLoopJoin = {
            AgentSidebarModel.shared.noteWindowListChanged()
        }
        sidebarView.removeFromSuperview()
        sidebarView = fresh
        addSubview(fresh, positioned: .below, relativeTo: handle)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        revealWorkItem?.cancel()
        if let widthObserver {
            NotificationCenter.default.removeObserver(widthObserver)
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
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
