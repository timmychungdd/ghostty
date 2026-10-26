import AppKit
import Combine
import Darwin
import Foundation
import GhosttyKit
import os

/// Sidebar diagnostics channel. NSLog does not reach the unified log store
/// for this app (stderr only), so use this Logger. Kept lean on purpose:
/// rare lifecycle events plus the rows() anomaly check.
/// Capture live: log stream --process ghostty --info | grep SIDEBAR-DBG
let sidebarDbg = Logger(subsystem: "com.mitchellh.ghostty", category: "sidebar")

/// AgentSidebarModel is the singleton state store behind the agent sidebar.
/// It listens for pi lifecycle events on a unix socket, tracks per-surface
/// agent state, and knows the app's terminal windows so each window's
/// sidebar can render one row per window.
final class AgentSidebarModel: ObservableObject {
    static let shared = AgentSidebarModel()

    /// Row status vocabulary. `background` = agent settled but its session
    /// still has background tasks running.
    enum RowState: Int, Comparable {
        case idle = 0
        case background = 1
        case working = 2
        case needsYou = 3

        static func < (lhs: RowState, rhs: RowState) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var name: String {
            switch self {
            case .idle: return "idle"
            case .background: return "background"
            case .working: return "working"
            case .needsYou: return "needsYou"
            }
        }
    }

    /// One sidebar row: one terminal window.
    struct Row: Identifiable {
        let window: NSWindow
        var id: ObjectIdentifier { ObjectIdentifier(window) }

        var title: String {
            let t = window.title
            // Pi sets its terminal title to "π - <session> - <cwd>"; every
            // workspace runs pi, so the π prefix is noise in the sidebar.
            var stripped: String
            if t.hasPrefix("π") {
                let rest = t.dropFirst().drop(while: { $0 == " " || $0 == "-" })
                stripped = rest.isEmpty ? "Terminal" : String(rest)
            } else {
                stripped = t.isEmpty ? "Terminal" : t
            }
            // Shell windows title with the full pwd ("~/Projects/x"); pi
            // titles with the basename. Match pi: last path component.
            if stripped.hasPrefix("/") || stripped.hasPrefix("~/"),
               let last = stripped.split(separator: "/").last {
                return String(last)
            }
            return stripped
        }
    }

    /// Surface id ("0x%016x") -> agent state, fed by the socket listener.
    @Published private(set) var surfaceStates: [String: RowState] = [:]

    /// Surface id -> AI-generated row label, fed by `label` wire events.
    @Published private(set) var surfaceLabels: [String: (text: String, at: Date)] = [:]

    /// Windows with a needs-you transition the user has not seen yet.
    @Published private(set) var unreadWindows: Set<ObjectIdentifier> = []

    /// Bump when the window list may have changed so views rebuild rows.
    @Published private(set) var windowListGeneration: UInt = 0

    /// Currently selected row for opt+cmd+arrow cycling.
    @Published private(set) var selectedRowID: ObjectIdentifier?

    /// Current sidebar UI scale (cmd+= / cmd+- while the sidebar is
    /// focused); multiplies dot, font, and padding sizes. With a terminal
    /// surface focused the same keys keep upstream's font-size zoom — the
    /// key monitor routes by first responder.
    @Published private(set) var uiScale: CGFloat

    /// Discrete scale steps; the index is persisted in UserDefaults.
    private static let scaleSteps: [CGFloat] = [0.8, 1.0, 1.25, 1.5, 1.8]
    private static let scaleDefaultsKey = "AgentSidebarUIScaleStep"

    private var scaleStepIndex: Int {
        didSet {
            UserDefaults.ghostty.set(scaleStepIndex, forKey: Self.scaleDefaultsKey)
            uiScale = Self.scaleSteps[scaleStepIndex]
        }
    }

    private var keyMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    private init() {
        // Missing key reads as 0, so check object(forKey:) before trusting it.
        let stored = UserDefaults.ghostty.integer(forKey: Self.scaleDefaultsKey)
        let defaultIndex = Self.scaleSteps.firstIndex(of: 1.0) ?? 0
        let index = (UserDefaults.ghostty.object(forKey: Self.scaleDefaultsKey) != nil
            && Self.scaleSteps.indices.contains(stored)) ? stored : defaultIndex
        scaleStepIndex = index
        uiScale = Self.scaleSteps[index]

        startListener()
        startKeyMonitor()
        observeWindowLifecycle()
        WorkspaceHotkeys.shared.start()
        AgentSessionMenu.shared.start()
    }

    /// Step the sidebar UI scale up (delta > 0) or down (delta < 0).
    func adjustScale(_ delta: Int) {
        let next = min(max(scaleStepIndex + delta, 0), Self.scaleSteps.count - 1)
        guard next != scaleStepIndex else { return }
        scaleStepIndex = next
    }

    // MARK: - Rows

    /// The global rows: one per terminal window, in screen order.
    var rows: [Row] {
        TerminalController.all.compactMap { $0.window }.map { Row(window: $0) }
    }

    /// Rows for one window frame: the terminal windows of its tab group, in
    /// tab order. A solo window yields just itself; a nil or non-terminal
    /// window yields the global list / nothing, respectively.
    ///
    /// Live-log evidence (round 2) showed window.tabGroup can read nil
    /// transiently at tab-reveal time — the nil fallback then silently
    /// yields one solo row (counts match, no anomaly). A group-keyed weak
    /// cache covers the transient: any member's non-nil read refreshes the
    /// whole group's membership and every member's group mapping, so a
    /// parked window whose hosting view has not evaluated lately still
    /// resolves its group. Self-heals on the next non-nil read.
    func rows(for window: NSWindow?) -> [Row] {
        guard let window else { return rows }
        if let group = window.tabGroup {
            let gid = ObjectIdentifier(group)
            let members = group.windows.filter { $0.windowController is BaseTerminalController }
            windowsByGroup[gid] = members.map(WeakWindowBox.init)
            for member in members {
                groupByWindow[ObjectIdentifier(member)] = gid
            }
            let result = members.map { Row(window: $0) }
            if result.count != group.windows.count {
                sidebarDbg.log("[SIDEBAR-DBG] rows(for: win#\(window.windowNumber, privacy: .public)) ANOMALY: groupCount=\(group.windows.count, privacy: .public) rowNums=\(result.map { String($0.window.windowNumber) }.joined(separator: ","), privacy: .public)")
            }
            return result
        }
        // tabGroup read nil: serve the last known group if its members are
        // still alive terminal windows, else the solo fallback. Logging only
        // fires for windows that HAD a group — plain solo windows are quiet.
        if let gid = groupByWindow[ObjectIdentifier(window)],
           let cached = windowsByGroup[gid] {
            let live = cached.compactMap(\.window).filter {
                $0.windowController is BaseTerminalController
            }
            if live.count > 1 {
                sidebarDbg.log("[SIDEBAR-DBG] rows(for: win#\(window.windowNumber, privacy: .public)) tabGroup=nil, cache hit rows=\(live.count, privacy: .public)")
                return live.map { Row(window: $0) }
            }
            sidebarDbg.log("[SIDEBAR-DBG] rows(for: win#\(window.windowNumber, privacy: .public)) tabGroup=nil, cache stale -> solo row")
        }
        return [Row(window: window)]
    }

    /// Call when a terminal window is created so sidebars refresh.
    func noteWindowListChanged() {
        DispatchQueue.main.async { self.windowListGeneration &+= 1 }
    }

    /// Weak box so the group cache never retains a closed window.
    private final class WeakWindowBox {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    /// tabGroup object id -> last known member list (weak, tab order).
    private var windowsByGroup: [ObjectIdentifier: [WeakWindowBox]] = [:]
    /// window id -> the tab group object it was last seen in.
    private var groupByWindow: [ObjectIdentifier: ObjectIdentifier] = [:]

    /// Agent states for a window: one entry per surface with a live session
    /// (an entry in surfaceStates), sorted highest-priority first so a
    /// display cap keeps the most important dots.
    func states(for window: NSWindow) -> [RowState] {
        guard let controller = window.windowController as? BaseTerminalController else {
            return []
        }
        var result: [RowState] = []
        for leaf in controller.surfaceTree.root?.leaves() ?? [] {
            guard let surface = leaf.surface else { continue }
            let key = Self.surfaceKey(ghostty_surface_id(surface))
            if let state = surfaceStates[key] { result.append(state) }
        }
        return result.sorted(by: >)
    }

    static func surfaceKey(_ id: UInt64) -> String {
        // Must match Zig's format exactly: "0x" + 16 lowercase hex digits.
        // (%016x would read only 32 bits of the UInt64 vararg; %016llx reads all 64.)
        String(format: "0x%016llx", id)
    }

    // MARK: - Focus

    func focus(_ row: Row) {
        selectedRowID = row.id
        unreadWindows.remove(row.id)
        let group = row.window.tabGroup
        sidebarDbg.log("[SIDEBAR-DBG] focus(win#\(row.window.windowNumber, privacy: .public)): tabGroup=\(group == nil ? "nil" : "set", privacy: .public) groupCount=\(group?.windows.count ?? -1, privacy: .public) branch=\((group?.windows.contains(row.window) ?? false) ? "group-selected" : "makeKey", privacy: .public)")
        // In a tab group, select the tab — the frame stays put and the chosen
        // window becomes key. Ungrouped windows come forward directly.
        if let group = group, group.windows.contains(row.window) {
            group.selectedWindow = row.window
        } else {
            row.window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// opt+cmd+left/right: cycle row selection within the key window's frame
    /// (its tab group) and focus the selected tab.
    func cycle(_ delta: Int) {
        let key = NSApp.keyWindow
        let current = rows(for: key)
        guard !current.isEmpty else { return }
        let index = current.firstIndex { $0.id == selectedRowID }
            ?? current.firstIndex { $0.window === key }
            ?? 0
        let next = (index + delta + current.count) % current.count
        focus(current[next])
    }

    /// Close a row's workspace through the standard close path: tab-close
    /// coordination plus the running-process confirmation. Clicking the × on
    /// a background row does not focus it first.
    func closeWorkspace(_ row: Row) {
        row.window.performClose(nil)
    }

    // MARK: - Key monitor (opt+cmd+arrows, cmd+= / cmd+-)

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isSuperset(of: [.option, .command]) {
                switch Int(event.keyCode) {
                case 123: self.cycle(-1); return nil  // left
                case 124: self.cycle(1); return nil   // right
                default: return event
                }
            }
            // cmd+= / cmd+- (shift allowed so cmd+plus works): zoom follows
            // focus. A focused terminal surface lets the event through to
            // libghostty's increase/decrease_font_size binds; anything else
            // (sidebar focused, window itself) scales the sidebar UI here.
            if mods.contains(.command), !mods.contains(.option), !mods.contains(.control) {
                switch Int(event.keyCode) {
                case 24, 27:  // = / + and -
                    let fr = (event.window ?? NSApp.keyWindow)?.firstResponder
                    if fr is Ghostty.SurfaceView { return event }
                    self.adjustScale(Int(event.keyCode) == 24 ? 1 : -1)
                    return nil
                default: return event
                }
            }
            return event
        }
    }

    // MARK: - Window lifecycle

    private func observeWindowLifecycle() {
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            if window.windowController is BaseTerminalController {
                // Let the close settle before rebuilding rows.
                DispatchQueue.main.async { self.windowListGeneration &+= 1 }
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window.windowController is BaseTerminalController else { return }
            self.selectedRowID = ObjectIdentifier(window)
            // Becoming key is the read receipt for the row's unread marker.
            self.unreadWindows.remove(ObjectIdentifier(window))
        })
    }

    // MARK: - Event application

    /// Posted on the main queue after any applied event mutates sidebar
    /// state. Containers swap their hosting view in response: evidenced
    /// repeatedly (2026-09-10 repro included) that @Published invalidation
    /// NEVER re-evaluates these hosting views — only view creation renders.
    static let stateDidChange = Notification.Name("AgentSidebarStateDidChange")

    /// Workspace restore: show a pane's saved label before pi reports one.
    func restoreLabel(_ text: String, for surface: String) {
        apply(type: "label", surface: surface, text: text)
    }

    private func apply(type: String, surface: String, text: String? = nil) {
        sidebarDbg.log("[SIDEBAR-DBG] apply \(type, privacy: .public) surface=\(surface, privacy: .public)")
        switch type {
        case "session_start":
            surfaceStates[surface] = .idle
        case "turn_start", "tool", "working":
            setState(.working, for: surface)
        case "awaiting_input", "settled":
            setState(.needsYou, for: surface)
        case "background":
            setState(.background, for: surface)
        case "label":
            guard let text, !text.isEmpty else { return }
            surfaceLabels[surface] = (text: text, at: Date())
        case "session_end":
            surfaceStates.removeValue(forKey: surface)
            surfaceLabels.removeValue(forKey: surface)
        default:
            return
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// State transition with unread bookkeeping: a surface that newly needs
    /// attention while its window is not key marks the window unread. The
    /// marker clears when the window becomes key (see observeWindowLifecycle)
    /// or is focused through the sidebar.
    private func setState(_ state: RowState, for surface: String) {
        let old = surfaceStates[surface]
        surfaceStates[surface] = state
        guard state == .needsYou, old != .needsYou,
              let window = window(forSurfaceKey: surface),
              !window.isKeyWindow else { return }
        unreadWindows.insert(ObjectIdentifier(window))
    }

    /// The window containing a surface, by walking every terminal window's
    /// surface tree.
    func window(forSurfaceKey key: String) -> NSWindow? {
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            for leaf in controller.surfaceTree.root?.leaves() ?? [] {
                guard let surface = leaf.surface else { continue }
                if Self.surfaceKey(ghostty_surface_id(surface)) == key {
                    return window
                }
            }
        }
        return nil
    }

    /// The AI-generated label for a window: the label of its surface with
    /// the most recent label event, or nil when no surface has one.
    func label(for window: NSWindow) -> String? {
        guard let controller = window.windowController as? BaseTerminalController else {
            return nil
        }
        var best: (text: String, at: Date)?
        for leaf in controller.surfaceTree.root?.leaves() ?? [] {
            guard let surface = leaf.surface else { continue }
            let key = Self.surfaceKey(ghostty_surface_id(surface))
            guard let label = surfaceLabels[key] else { continue }
            if best == nil || label.at > best!.at { best = label }
        }
        return best?.text
    }

    // MARK: - Unix socket listener

    /// In the app's own support folder (keyed by bundle id) so a Debug build
    /// runs beside the installed app; ghostty-agent.ts derives the same path
    /// from the __CFBundleIdentifier env var.
    private static let socketPath =
        WorkspaceStore.supportDirectory.appendingPathComponent("agent-events.sock").path

    private func startListener() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.listenerLoop()
        }
    }

    private func listenerLoop() {
        let path = Self.socketPath
        unlink(path)

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return }
        defer { close(serverFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(serverFD, 16) == 0 else { return }

        while true {
            let conn = accept(serverFD, nil, nil)
            if conn < 0 { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.readLoop(conn)
            }
        }
    }

    private func readLoop(_ fd: Int32) {
        defer { close(fd) }
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[0..<newline]
                buffer.removeFirst(newline + 1)
                handleLine(Array(line))
            }
        }
    }

    private struct WireEvent: Decodable {
        let type: String
        let surface: String?
        let text: String?
        let session: String?
        let sessionFile: String?
        let cwd: String?
    }

    private func handleLine(_ bytes: [UInt8]) {
        guard let event = try? JSONDecoder().decode(WireEvent.self, from: Data(bytes)) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // "dump" carries no surface: it is a diagnostic, not agent state.
            if event.type == "dump" {
                self.dumpSidebars()
                AgentSessionMenu.shared.dump()
                return
            }
            guard let surface = event.surface, !surface.isEmpty else { return }
            // Pi session identity feeds workspace save/restore.
            switch event.type {
            case "session_start":
                WorkspaceStore.shared.sessionStarted(
                    surface: surface, id: event.session, file: event.sessionFile, cwd: event.cwd)
            case "session_end":
                WorkspaceStore.shared.sessionEnded(surface: surface)
            default:
                break
            }
            self.apply(type: event.type, surface: surface, text: event.text)
        }
    }

    // MARK: - Diagnostics (dump)

    /// Diagnostic entry point for the "dump" wire event: render every
    /// terminal window's sidebar view to /tmp/ghostty-sidebar-<win#>.png and
    /// write /tmp/ghostty-sidebar-dump.json with the model's row state.
    /// Self-rendered, so unlike screencapture it needs no TCC grants; the
    /// only pixel path available to headless validation.
    private func dumpSidebars() {
        var entries: [[String: Any]] = []
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let num = window.windowNumber
            var entry: [String: Any] = [
                "window": num,
                "title": Row(window: window).title,
                "states": states(for: window).map { $0.name },
                "isKey": window.isKeyWindow,
                "selected": selectedRowID == ObjectIdentifier(window),
            ]
                entry["label"] = label(for: window) ?? NSNull()
            entry["unread"] = unreadWindows.contains(ObjectIdentifier(window))
            // Own-window CGWindowList capture: exact on-screen pixels, and
            // no Screen Recording grant needed for one's own windows.
            let path = "/tmp/ghostty-sidebar-\(num).png"
            entry["png"] = Self.captureWindow(num, to: URL(fileURLWithPath: path)) ? path : "FAILED"

            entries.append(entry)
        }
        let url = URL(fileURLWithPath: "/tmp/ghostty-sidebar-dump.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        sidebarDbg.log("[SIDEBAR-DBG] dump: \(entries.count, privacy: .public) windows -> /tmp/ghostty-sidebar-dump.json")
    }

    private static func captureWindow(_ windowNumber: Int, to url: URL) -> Bool {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
