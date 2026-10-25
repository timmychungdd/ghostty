import AppKit
import Combine
import SwiftUI

/// NSHostingView that reports when it (re)joins a live render loop:
/// attached to a window and about to draw. Used to re-fire the sidebar's
/// published invalidation at the exact moment it can be consumed.
final class SidebarHostingView: NSHostingView<AgentSidebarView> {
    var onLiveRenderLoopJoin: (() -> Void)?
    /// Cooldown so draw storms cannot spam the generation counter.
    private var lastJoinFire: Date = .distantPast

    /// The sidebar takes keyboard focus on click so the model's key monitor
    /// can route cmd+= / cmd+- by first responder: sidebar focused scales
    /// the sidebar UI, terminal focused zooms the pane font. Row taps still
    /// fire (super handles the SwiftUI click); clicking a pane hands focus
    /// back to the surface.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

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
    private let dragStrip = WindowDragStripView()
    /// Swapped on config reload: Ghostty.App REPLACES its Config wrapper on
    /// reload, so a config captured at init reads creation-time values
    /// forever. Updated by `configObserver`.
    private var config: Ghostty.Config
    private weak var ownWindow: NSWindow?
    private var widthObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private var revealWorkItem: DispatchWorkItem?
    private var generationCancellable: AnyCancellable?
    private var stateObserver: NSObjectProtocol?
    /// The window's tab-group identity + membership at last check; a change
    /// without a key change means the hosting view may be the parked one
    /// that no longer re-evaluates, so it gets swapped for a fresh one.
    private var lastKnownGroupKey: String?
    /// State-event swap throttle: leading swap renders immediately when idle,
    /// trailing swap coalesces bursts so tool-event spam cannot churn views.
    private var lastSwap: Date = .distantPast
    private var pendingStateSwap: DispatchWorkItem?
    private static let stateSwapInterval: TimeInterval = 0.3

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
        // Above the terminal: the surface swallows clicks in the hidden
        // titlebar zone, so this strip gives the window its drag area back.
        addSubview(dragStrip)

        handle.onDragStart = { [weak self] in
            guard let self else { return }
            // Divider drags count as sidebar interaction for zoom routing.
            self.window?.makeFirstResponder(self.sidebarView)
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

        lastKnownGroupKey = Self.groupKey(for: ownWindow)
        lastSwap = Date()

        // State events (dots, labels, unread) only reach the screen through
        // a fresh hosting view — SwiftUI invalidation is discarded by these
        // hosting views even while visible, so every applied event asks for
        // a throttled swap.
        stateObserver = NotificationCenter.default.addObserver(
            forName: AgentSidebarModel.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.throttledStateSwap()
        }

        // Group formation/dissolution can happen without this window ever
        // seeing didBecomeKey (e.g. a tab added behind it), and the parked
        // hosting view then keeps rendering a frozen snapshot. The window
        // list generation bumps on window create/close, so re-check the
        // group membership there and swap the view when it changed.
        generationCancellable = AgentSidebarModel.shared.$windowListGeneration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let key = Self.groupKey(for: self.ownWindow)
                if key != self.lastKnownGroupKey {
                    self.lastKnownGroupKey = key
                    self.replaceSidebarView("group-change")
                }
            }

        // Config reload: swap in the new Config wrapper and rebuild the
        // sidebar view so colors track (the creation path provably
        // re-evaluates; a stored stale wrapper never would). App-level
        // posts carry object == nil; surface-targeted posts are ignored.
        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.object == nil else { return }
            guard let newConfig = notification.userInfo?[
                Notification.Name.GhosttyConfigChangeKey
            ] as? Ghostty.Config else { return }
            self.config = newConfig
            self.replaceSidebarView("config-reload")
        }
    }

    /// Swap in a fresh hosting view so the sidebar re-evaluates from current
    /// model state — a new hosting view attached to a live window renders
    /// immediately, which frozen parked-window hosting views never do.
    /// Swap on a state event, throttled: leading swap if the last render is
    /// older than the interval, else one trailing swap at the interval edge.
    private func throttledStateSwap() {
        let elapsed = Date().timeIntervalSince(lastSwap)
        if elapsed >= Self.stateSwapInterval {
            replaceSidebarView("state")
        } else if pendingStateSwap == nil {
            let item = DispatchWorkItem { [weak self] in
                self?.pendingStateSwap = nil
                self?.replaceSidebarView("state-trailing")
            }
            pendingStateSwap = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Self.stateSwapInterval - elapsed), execute: item)
        }
    }

    /// "<group-id>:<member-count>" for grouped windows, "solo" otherwise.
    private static func groupKey(for window: NSWindow?) -> String {
        guard let window, let group = window.tabGroup else { return "solo" }
        return "\(ObjectIdentifier(group)):\(group.windows.count)"
    }

    private func replaceSidebarView(_ reason: String) {
        let winDesc = ownWindow == nil ? "nil" : "win#\(ownWindow!.windowNumber)"
        sidebarDbg.log("[SIDEBAR-DBG] replaceSidebarView(\(reason, privacy: .public)): ownWindow=\(winDesc, privacy: .public)")
        lastSwap = Date()
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
        pendingStateSwap?.cancel()
        generationCancellable?.cancel()
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        if let widthObserver {
            NotificationCenter.default.removeObserver(widthObserver)
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    override var intrinsicContentSize: NSSize {
        var size = terminalContent.intrinsicContentSize
        if size.width > 0 { size.width += sidebarWidth + Self.handleWidth }
        return size
    }

    // The drag strip's height comes from the window's titlebar.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
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
        // The strip covers the hidden titlebar's height over the terminal;
        // native fullscreen has no titlebar, so the strip collapses to 0.
        let titlebarHeight = window.map { max(0, $0.frame.height - $0.contentLayoutRect.height) } ?? 0
        dragStrip.frame = NSRect(
            x: terminalContent.frame.minX, y: bounds.height - titlebarHeight,
            width: terminalContent.frame.width, height: titlebarHeight)
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

/// Transparent strip over the top of the terminal that moves the window like
/// a titlebar: drag moves it, double-click follows the system "double-click a
/// window's title bar" setting (zoom, minimize, or nothing).
private final class WindowDragStripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
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
