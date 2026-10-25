import AppKit
import GhosttyKit
import OSLog

private let storeLog = Logger(subsystem: "com.mitchellh.ghostty", category: "workspace-store")

/// Fork feature: save and restore every terminal frame, tab, and split,
/// replacing macOS window restoration (set `window-save-state = never`).
///
/// - Save: once a second the store snapshots all terminal windows and, when
///   the snapshot changed, writes `workspaces.json` atomically (temp file +
///   rename). A crash loses at most the last second.
/// - Pi panes: the ghostty-agent pi extension reports each pane's session
///   file on `session_start`; restore relaunches that exact file with
///   `pi --session <file>`.
/// - Restore: at launch the store copies `workspaces.json` to
///   `workspaces.prev.json` before touching anything, rebuilds the windows,
///   then writes `restore-report.json`. Each restored pi pane must report
///   back the session id it was saved with; a wrong id or no report within
///   `verifyTimeout` marks the pane failed — red marker on its sidebar row.
///
/// Files live in `~/Library/Application Support/<bundle id>/`, so a Debug
/// build keeps its own state beside the installed app.
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty")
    }()

    private static let stateURL = supportDirectory.appendingPathComponent("workspaces.json")
    private static let prevURL = supportDirectory.appendingPathComponent("workspaces.prev.json")
    private static let reportURL = supportDirectory.appendingPathComponent("restore-report.json")
    private static let verifyTimeout: TimeInterval = 90

    // MARK: - File format

    struct Snapshot: Codable, Equatable {
        var version: Int
        var frames: [Frame]
    }

    /// One macOS window frame holding one or more tabs (sidebar rows).
    struct Frame: Codable, Equatable {
        var rect: Rect
        var selectedTab: Int
        var fullscreen: FullscreenMode?
        var tabs: [Tab]
    }

    struct Rect: Codable, Equatable {
        var x, y, width, height: Double
    }

    struct Tab: Codable, Equatable {
        var titleOverride: String?
        var layout: Node
    }

    /// A pane (`pane` set) or a split (`direction`, `ratio`, two `children`).
    struct Node: Codable, Equatable {
        var pane: Pane?
        var direction: String?
        var ratio: Double?
        var children: [Node]?
    }

    struct Pane: Codable, Equatable {
        var cwd: String?
        /// Launch command for non-pi panes; nil runs the default shell.
        var command: String?
        /// Set when pi runs in the pane; restore reopens this exact session.
        var piSession: PiSession?
        var focused: Bool
    }

    struct PiSession: Codable, Equatable {
        var id: String
        var file: String
        var cwd: String?
    }

    // MARK: - Restore report

    struct Report: Codable {
        var restoredAt: Date
        var source: String
        var error: String?
        var ok: Int
        var failed: Int
        var pending: Int
        var panes: [ReportPane]
    }

    struct ReportPane: Codable {
        var frame: Int
        var tab: Int
        var cwd: String?
        var command: String?
        var expectedSession: String?
        var observedSession: String?
        /// "ok", "launched" (non-pi pane), "fresh-pi-unwritten-session" (saved
        /// pi session never wrote its file), "pending", "mismatch",
        /// "no-session-event".
        var status: String
    }

    // MARK: - State

    /// Surface key -> pi session running in that pane.
    private var piSessions: [String: PiSession] = [:]
    /// Surface key -> report index, for restored pi panes not yet verified.
    private var pendingVerification: [String: Int] = [:]
    /// Surface keys of restored panes whose verification failed.
    private(set) var failedSurfaces: Set<String> = []
    private var report: Report?
    private var lastWritten: Data?
    private var timer: Timer?
    private var frozen = false

    private init() {}

    // MARK: - Pi session events (from AgentSidebarModel's socket listener)

    func sessionStarted(surface: String, id: String?, file: String?, cwd: String?) {
        if let id, let file {
            piSessions[surface] = PiSession(id: id, file: file, cwd: cwd)
        } else {
            piSessions.removeValue(forKey: surface)
        }

        guard let index = pendingVerification.removeValue(forKey: surface), var report else { return }
        let expected = report.panes[index].expectedSession
        report.panes[index].observedSession = id
        if id == expected {
            report.panes[index].status = "ok"
            failedSurfaces.remove(surface)
        } else {
            report.panes[index].status = "mismatch"
            failedSurfaces.insert(surface)
            storeLog.error("restore mismatch: expected session \(expected ?? "nil", privacy: .public), pi reported \(id ?? "nil", privacy: .public)")
        }
        self.report = report
        writeReport()
        NotificationCenter.default.post(name: AgentSidebarModel.stateDidChange, object: nil)
    }

    func sessionEnded(surface: String) {
        piSessions.removeValue(forKey: surface)
    }

    func restoreFailed(window: NSWindow) -> Bool {
        guard !failedSurfaces.isEmpty,
              let controller = window.windowController as? BaseTerminalController else { return false }
        for leaf in controller.surfaceTree.root?.leaves() ?? [] {
            guard let surface = leaf.surface else { continue }
            if failedSurfaces.contains(AgentSidebarModel.surfaceKey(ghostty_surface_id(surface))) {
                return true
            }
        }
        return false
    }

    // MARK: - Launch

    /// Called once from applicationDidFinishLaunching, before the initial
    /// window logic runs. Saving starts only after the restore built its
    /// windows, so a half-restored state never overwrites the file.
    func restoreAtLaunch(_ ghostty: Ghostty.App) {
        let fm = FileManager.default
        try! fm.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        defer { startSaving() }

        guard fm.fileExists(atPath: Self.stateURL.path) else {
            storeLog.info("no saved workspaces at \(Self.stateURL.path, privacy: .public)")
            return
        }

        if fm.fileExists(atPath: Self.prevURL.path) {
            try! fm.removeItem(at: Self.prevURL)
        }
        try! fm.copyItem(at: Self.stateURL, to: Self.prevURL)

        let snapshot: Snapshot
        do {
            let data = try Data(contentsOf: Self.stateURL)
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else {
                throw NSError(domain: "WorkspaceStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "unsupported version \(snapshot.version)",
                ])
            }
        } catch {
            failUnreadable(error)
            return
        }

        report = Report(
            restoredAt: Date(), source: Self.prevURL.path, error: nil,
            ok: 0, failed: 0, pending: 0, panes: [])
        for (frameIndex, frame) in snapshot.frames.enumerated() {
            restore(frame, index: frameIndex, ghostty: ghostty)
        }
        writeReport()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyTimeout) { [weak self] in
            self?.expirePending()
        }
    }

    /// An unreadable file is moved aside (so the next save cannot bury it)
    /// and reported with an alert.
    private func failUnreadable(_ error: Error) {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = Self.supportDirectory.appendingPathComponent("workspaces.unreadable-\(stamp).json")
        try! FileManager.default.moveItem(at: Self.stateURL, to: aside)
        report = Report(
            restoredAt: Date(), source: aside.path, error: "\(error)",
            ok: 0, failed: 0, pending: 0, panes: [])
        writeReport()
        storeLog.error("workspaces.json unreadable: \(String(describing: error), privacy: .public)")

        let alert = NSAlert()
        alert.messageText = "Ghostty could not restore workspaces"
        alert.informativeText = "\(error)\n\nThe file was moved to \(aside.path)."
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func restore(_ frame: Frame, index frameIndex: Int, ghostty: Ghostty.App) {
        guard let app = ghostty.app else { preconditionFailure("app must be loaded") }

        var controllers: [TerminalController] = []
        var focusTargets: [Ghostty.SurfaceView?] = []
        for (tabIndex, tab) in frame.tabs.enumerated() {
            var focused: Ghostty.SurfaceView?
            let root = buildNode(tab.layout, app: app, frame: frameIndex, tab: tabIndex, focused: &focused)
            let c = TerminalController(ghostty, withSurfaceTree: SplitTree(root: root, zoomed: nil))
            c.titleOverride = tab.titleOverride
            if let focused { c.focusedSurface = focused }
            controllers.append(c)
            focusTargets.append(focused)
        }

        guard let first = controllers.first, let firstWindow = first.window else {
            preconditionFailure("restored frame \(frameIndex) has no tabs or no window")
        }
        first.showWindowSafely(nil)
        for c in controllers.dropFirst() {
            guard let window = c.window else { preconditionFailure("restored tab has no window") }
            let anchor = firstWindow.tabGroup?.windows.last ?? firstWindow
            anchor.addTabbedWindowSafely(window, ordered: .above)
            c.showWindowSafely(nil)
        }

        let selectedIndex = min(max(frame.selectedTab, 0), controllers.count - 1)
        let selected = controllers[selectedIndex]
        selected.showWindowSafely(nil)
        firstWindow.setFrame(
            NSRect(x: frame.rect.x, y: frame.rect.y, width: frame.rect.width, height: frame.rect.height),
            display: true)
        for (c, target) in zip(controllers, focusTargets) {
            if let target, let window = c.window { focus(target, in: window) }
        }

        if let mode = frame.fullscreen {
            DispatchQueue.main.async { selected.toggleFullscreen(mode: mode) }
        }
    }

    private func buildNode(
        _ node: Node,
        app: ghostty_app_t,
        frame: Int,
        tab: Int,
        focused: inout Ghostty.SurfaceView?
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        if let pane = node.pane {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.piSession?.cwd ?? pane.cwd
            // Pi writes its session file only after the first exchange; a
            // session that never got one has nothing to resume, so the pane
            // restarts as a fresh pi with no verification.
            var resumable: PiSession?
            if let session = pane.piSession, FileManager.default.fileExists(atPath: session.file) {
                resumable = session
            }
            if let resumable {
                config.command = WorkspaceHotkeys.piResumeCommand(sessionFile: resumable.file)
            } else if pane.piSession != nil {
                config.command = WorkspaceHotkeys.piCommand
            } else {
                config.command = pane.command
            }
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            if pane.focused { focused = view }

            guard let surface = view.surface else { preconditionFailure("restored surface failed to start") }
            let key = AgentSidebarModel.surfaceKey(ghostty_surface_id(surface))
            report!.panes.append(ReportPane(
                frame: frame, tab: tab, cwd: config.workingDirectory, command: config.command,
                expectedSession: resumable?.id, observedSession: nil,
                status: resumable != nil ? "pending" : (pane.piSession != nil ? "fresh-pi-unwritten-session" : "launched")))
            if let session = resumable {
                // Pre-seed so a save before pi starts still records the session.
                piSessions[key] = session
                pendingVerification[key] = report!.panes.count - 1
            }
            return .leaf(view: view)
        }

        guard let direction = node.direction, let ratio = node.ratio,
              let children = node.children, children.count == 2 else {
            preconditionFailure("workspace node is neither a pane nor a two-child split")
        }
        let left = buildNode(children[0], app: app, frame: frame, tab: tab, focused: &focused)
        let right = buildNode(children[1], app: app, frame: frame, tab: tab, focused: &focused)
        return .split(.init(
            direction: direction == "vertical" ? .vertical : .horizontal,
            ratio: ratio, left: left, right: right))
    }

    /// Restored views attach to their window a few run-loop turns after the
    /// window shows; retry for up to 2 seconds.
    private func focus(_ view: Ghostty.SurfaceView, in window: NSWindow, attempts: Int = 0) {
        guard attempts <= 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempts == 0 ? 0 : 0.05)) {
            guard view.window === window else {
                self.focus(view, in: window, attempts: attempts + 1)
                return
            }
            window.makeFirstResponder(view)
        }
    }

    private func expirePending() {
        guard var report, !pendingVerification.isEmpty else { return }
        for (key, index) in pendingVerification {
            report.panes[index].status = "no-session-event"
            failedSurfaces.insert(key)
            storeLog.error("restore unverified: pane \(index) sent no session_start within \(Self.verifyTimeout)s")
        }
        pendingVerification.removeAll()
        self.report = report
        writeReport()
        NotificationCenter.default.post(name: AgentSidebarModel.stateDidChange, object: nil)
    }

    private func writeReport() {
        guard var report else { return }
        report.ok = report.panes.filter { $0.status == "ok" }.count
        report.pending = report.panes.filter { $0.status == "pending" }.count
        report.failed = report.panes.filter { ["mismatch", "no-session-event"].contains($0.status) }.count
        self.report = report
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try! encoder.encode(report).write(to: Self.reportURL, options: .atomic)
    }

    // MARK: - Exit prompt

    /// Asks whether to keep the current windows for next launch. Save
    /// writes the final snapshot and freezes it; Don't Save deletes
    /// `workspaces.json` so the next launch opens one blank window. Returns
    /// false on Cancel: the caller keeps Ghostty running.
    func promptOnExit() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save these windows for next launch?"
        alert.informativeText = "Running processes in every window will be terminated."
        alert.addButton(withTitle: "Save Windows")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            freeze()
            storeLog.info("exit prompt: saved windows for next launch")
            return true
        case .alertSecondButtonReturn:
            freeze()
            if FileManager.default.fileExists(atPath: Self.stateURL.path) {
                try! FileManager.default.removeItem(at: Self.stateURL)
            }
            storeLog.info("exit prompt: discarded saved windows")
            return true
        default:
            return false
        }
    }

    private func freeze() {
        frozen = true
        timer?.invalidate()
    }

    // MARK: - Save

    private func startSaving() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.save()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Final save, then stop: windows torn down during termination
            // must not overwrite the state they are about to lose.
            self.save()
            self.freeze()
        }
    }

    private func save() {
        guard !frozen else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(snapshot())
        guard data != lastWritten else { return }
        do {
            try data.write(to: Self.stateURL, options: .atomic)
            lastWritten = data
        } catch {
            storeLog.error("workspaces.json write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func snapshot() -> Snapshot {
        var seen = Set<ObjectIdentifier>()
        var frames: [Frame] = []
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let members = window.tabGroup?.windows ?? [window]
            let groupID = window.tabGroup.map { ObjectIdentifier($0) } ?? ObjectIdentifier(window)
            guard seen.insert(groupID).inserted else { continue }

            let tabControllers = members
                .compactMap { $0.windowController as? TerminalController }
                .filter { !$0.surfaceTree.isEmpty }
            guard !tabControllers.isEmpty else { continue }

            let selectedWindow = window.tabGroup?.selectedWindow ?? window
            let selectedIndex = tabControllers.firstIndex { $0.window === selectedWindow } ?? 0
            let style = tabControllers[selectedIndex].fullscreenStyle
            let rect = window.frame
            frames.append(Frame(
                rect: Rect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
                selectedTab: selectedIndex,
                fullscreen: style?.isFullscreen == true ? style?.fullscreenMode : nil,
                tabs: tabControllers.map { tab($0) }))
        }
        return Snapshot(version: 1, frames: frames)
    }

    private func tab(_ controller: TerminalController) -> Tab {
        guard let root = controller.surfaceTree.root else { preconditionFailure("empty tree filtered above") }
        return Tab(titleOverride: controller.titleOverride, layout: encode(root, focused: controller.focusedSurface))
    }

    private func encode(_ node: SplitTree<Ghostty.SurfaceView>.Node, focused: Ghostty.SurfaceView?) -> Node {
        switch node {
        case .leaf(let view):
            var session: PiSession?
            if let surface = view.surface {
                session = piSessions[AgentSidebarModel.surfaceKey(ghostty_surface_id(surface))]
            }
            return Node(pane: Pane(
                cwd: session?.cwd ?? view.pwd ?? view.launchDirectory,
                command: Self.savedCommand(view.launchCommand),
                piSession: session,
                focused: view === focused))
        case .split(let split):
            return Node(
                direction: split.direction == .vertical ? "vertical" : "horizontal",
                ratio: split.ratio,
                children: [encode(split.left, focused: focused), encode(split.right, focused: focused)])
        }
    }

    /// A pane launched as pi — fresh or resumed — saves as the fresh pi
    /// launcher; restore swaps in `pi --session` when a session is known.
    private static func savedCommand(_ command: String?) -> String? {
        guard let command else { return nil }
        if command == WorkspaceHotkeys.piCommand || command.hasPrefix("/bin/zsh -ilc \"pi --session ") {
            return WorkspaceHotkeys.piCommand
        }
        return command
    }
}
