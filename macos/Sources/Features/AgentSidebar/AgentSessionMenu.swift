import AppKit
import GhosttyKit
import OSLog

private let menuLog = Logger(subsystem: "com.mitchellh.ghostty", category: "session-menu")

/// Fork feature: a menu bar item listing recently closed interactive pi
/// sessions, each reopened in a new tab with one click (Tim, 2026-10-27:
/// closed sessions replace the live list, after an expired agent gateway
/// token cost him several sessions at once).
///
/// The ghostty-agent pi extension writes one JSON file per running TUI
/// session to `~/.pi/agent/live-sessions/<session id>.json`. On exit it moves
/// the file to `~/.pi/agent/closed-sessions/` with `closedAt` and
/// `closeReason` added, and a session that starts again deletes its closed
/// file. A live file whose pid is dead belongs to a crashed pi; this menu and
/// the Slack launcher move it to the closed folder. Same rules as
/// pi/extensions/lib/live-registry.mjs.
///
/// Reopen opens a tab running `pi --session <file>` in the session's folder,
/// so the sidebar and workspace restore see it like any other tab, and a
/// Slack-on session reattaches to its thread.
final class AgentSessionMenu: NSObject, NSMenuDelegate {
    static let shared = AgentSessionMenu()

    static let registryDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/live-sessions")
    static let closedDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/closed-sessions")

    /// Rows shown, newest first.
    private static let shownLimit = 20

    /// Mirrors `RegistryRecord` in pi/extensions/ghostty-agent.ts, plus the
    /// two fields `closeRecord` in live-registry.mjs adds.
    struct Record: Decodable {
        let sessionId: String
        let name: String
        let sessionFile: String?
        let cwd: String
        let pid: Int32
        /// When the pid started; a reused pid has a different one. Absent in
        /// records written before 2026-10-26.
        let pidStartedAt: Double?
        let label: String?
        let startedAt: Double
        let stateSince: Double
        let closedAt: Double?
        let closeReason: String?

        var title: String { label ?? name }
        var folder: String { (cwd as NSString).lastPathComponent }
    }

    private var statusItem: NSStatusItem?

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: "closed pi sessions")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    // MARK: - Registry

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Start time of a running pid in JavaScript milliseconds.
    private static func startMs(_ pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
    }

    /// The record's pi is still running. After a crash or reboot, macOS can
    /// hand a dead pi's pid to another process; its start time differs.
    private static func ownerAlive(_ record: Record) -> Bool {
        guard isAlive(record.pid) else { return false }
        guard let expected = record.pidStartedAt else { return true }
        guard let start = startMs(record.pid) else { return false }
        return abs(start - expected) < 2000
    }

    /// Decoded `.json` files of a folder, plus the names of files that would
    /// not decode.
    private func readFolder(_ folder: URL) -> (records: [(URL, Record)], unreadable: [String]) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], [])
        } catch {
            menuLog.error("\(folder.path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return ([], ["\(folder.path): \(error.localizedDescription)"])
        }
        var records: [(URL, Record)] = []
        var unreadable: [String] = []
        for name in names where name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            do {
                records.append((url, try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))))
            } catch {
                menuLog.error("registry file \(name, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
                unreadable.append(name)
            }
        }
        return (records, unreadable)
    }

    /// Move a crashed pi's live file to the closed folder, like
    /// `closeRecord(record, "crashed")` in live-registry.mjs.
    private func closeCrashed(_ url: URL) throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["closedAt"] = Date().timeIntervalSince1970 * 1000
        object["closeReason"] = "crashed"
        try FileManager.default.createDirectory(at: Self.closedDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.closedDirectory.appendingPathComponent(url.lastPathComponent), options: .atomic)
        try FileManager.default.removeItem(at: url)
    }

    /// Closed sessions that have a conversation to resume and are not running
    /// again, newest first, plus unreadable file names.
    private func closedRecords() -> (records: [Record], unreadable: [String]) {
        let live = readFolder(Self.registryDirectory)
        var running = Set<String>()
        var unreadable = live.unreadable
        for (url, record) in live.records {
            if Self.ownerAlive(record) {
                running.insert(record.sessionId)
                continue
            }
            do {
                try closeCrashed(url)
                menuLog.info("moved registry file of dead or reused pid \(record.pid) to closed-sessions: \(url.lastPathComponent, privacy: .public)")
            } catch {
                menuLog.error("could not move \(url.lastPathComponent, privacy: .public) to closed-sessions: \(error.localizedDescription, privacy: .public)")
                unreadable.append(url.lastPathComponent)
            }
        }
        let closed = readFolder(Self.closedDirectory)
        unreadable += closed.unreadable
        let records = closed.records.map(\.1)
            .filter { record in
                // pi writes its session file after the first exchange; before
                // that there is no conversation to resume.
                !running.contains(record.sessionId)
                    && record.sessionFile.map { FileManager.default.fileExists(atPath: $0) } == true
            }
            .sorted { ($0.closedAt ?? 0) > ($1.closedAt ?? 0) }
        return (records, unreadable)
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let (records, unreadable) = closedRecords()
        menu.addItem(disabled(records.isEmpty ? "No closed pi sessions" : "Recently closed pi sessions — click to reopen"))
        for name in unreadable {
            menu.addItem(disabled("Unreadable registry file: \(name)"))
        }
        guard !records.isEmpty else { return }
        menu.addItem(.separator())
        for record in records.prefix(Self.shownLimit) { menu.addItem(row(record)) }
        if records.count > Self.shownLimit {
            menu.addItem(.separator())
            menu.addItem(disabled("\(records.count - Self.shownLimit) older in ~/.pi/agent/closed-sessions"))
        }
    }

    /// Diagnostic for the "dump" wire event: write the menu as it would open
    /// to /tmp/ghostty-session-menu.json, since a status item menu cannot be
    /// screenshotted headlessly.
    func dump() {
        let menu = NSMenu()
        menuWillOpen(menu)
        let items: [[String: Any]] = menu.items.map { item in
            let title = (item.view as? StayOpenMenuItemView)?.title ?? item.title
            return ["title": item.isSeparatorItem ? "---" : title, "enabled": item.isEnabled]
        }
        let url = URL(fileURLWithPath: "/tmp/ghostty-session-menu.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])
            try data.write(to: url)
        } catch {
            menuLog.error("session menu dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A click reopens the session and keeps the menu open, so several
    /// sessions closed together reopen in a row (the End Session precedent,
    /// Tim, 2026-10-26).
    private func row(_ record: Record) -> NSMenuItem {
        let item = NSMenuItem()
        let closed = record.closedAt.map { "closed \(Self.age(since: $0)) ago" } ?? "closed"
        let title = "\(record.title) · \(record.folder) · \(closed)"
        let view = StayOpenMenuItemView(title: title)
        view.toolTip = [
            record.name,
            (record.cwd as NSString).abbreviatingWithTildeInPath,
            "ended by: \(record.closeReason ?? "unknown")",
        ].joined(separator: "\n")
        view.onClick = { [weak self] view in
            guard let self else { return }
            guard self.reopen(record) else { return }
            view.title = "\(record.title) · \(record.folder) · reopened"
            view.isEnabled = false
        }
        item.view = view
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Registry timestamps are JavaScript milliseconds.
    private static func age(since ms: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    // MARK: - Actions

    /// The extension deletes a session's closed file when it starts again, so
    /// a missing file means the session is running somewhere already.
    private func reopen(_ record: Record) -> Bool {
        let closedFile = Self.closedDirectory.appendingPathComponent("\(record.sessionId).json")
        guard FileManager.default.fileExists(atPath: closedFile.path) else {
            fail("\(record.title) is running again; it was not reopened.")
            return false
        }
        guard let file = record.sessionFile else { return false }
        return openTab(sessionFile: file, cwd: record.cwd, label: record.label)
    }

    /// A new tab in the current frame (the cmd+T path), like the workspace
    /// hotkeys; with no terminal window it opens a new one.
    private func openTab(sessionFile: String, cwd: String, label: String?) -> Bool {
        guard let delegate = NSApp.delegate as? AppDelegate else { return false }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.command = WorkspaceHotkeys.piResumeCommand(sessionFile: sessionFile)
        if let label { config.environmentVariables["GHOSTTY_AGENT_LABEL"] = label }

        var parent = NSApp.keyWindow
        if !(parent?.windowController is TerminalController) {
            parent = TerminalController.preferredParent?.window
        }
        guard let controller = TerminalController.newTab(delegate.ghostty, from: parent, withBaseConfig: config) else {
            fail("Ghostty did not open a tab for \(sessionFile).")
            return false
        }
        if let label, let surface = controller.surfaceTree.root?.leaves().first?.surface {
            AgentSidebarModel.shared.restoreLabel(label, for: AgentSidebarModel.surfaceKey(ghostty_surface_id(surface)))
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func fail(_ message: String) {
        statusItem?.menu?.cancelTracking()
        menuLog.error("\(message, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "pi session menu"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// A menu item row drawn like a standard item whose click runs `onClick`
/// without closing the menu. AppKit sets the enclosing item's highlight on
/// hover and redraws the view.
private final class StayOpenMenuItemView: NSView {
    var onClick: ((StayOpenMenuItemView) -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        // The menu is as wide as its widest item; the row fits its title.
        let width = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        super.init(frame: NSRect(x: 0, y: 0, width: max(220, ceil(width) + 40), height: 22))
        autoresizingMask = [.width]
        label.stringValue = title
        label.font = .menuFont(ofSize: 0)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var highlighted: Bool { isEnabled && enclosingMenuItem?.isHighlighted == true }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        label.textColor = !isEnabled ? .disabledControlTextColor
            : highlighted ? .selectedMenuItemTextColor : .controlTextColor
        super.draw(dirtyRect)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?(self)
    }
}
