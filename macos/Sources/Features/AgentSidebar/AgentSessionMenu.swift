import AppKit
import GhosttyKit
import OSLog

private let menuLog = Logger(subsystem: "com.mitchellh.ghostty", category: "session-menu")

/// Fork feature: a menu bar item listing every running interactive pi
/// session — Ghostty tabs, Slack-launched tmux sessions, other terminals.
///
/// The ghostty-agent pi extension writes one JSON file per running TUI
/// session to `~/.pi/agent/live-sessions/<session id>.json` and deletes it on
/// exit. This menu reads that folder when it opens; a file whose pid is dead
/// belongs to a crashed pi and is removed. Each session can be shown (a tab
/// in this app), moved into a new tab of this app, or ended.
///
/// Move = end the pi process with SIGTERM, wait for it to exit, then open a
/// tab running `pi --session <file>`. One process per conversation, so the
/// sidebar and workspace restore see the moved session like any other tab.
/// A Slack-on session reattaches to its thread when the tab's pi starts.
final class AgentSessionMenu: NSObject, NSMenuDelegate {
    static let shared = AgentSessionMenu()

    static let registryDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/live-sessions")

    /// Mirrors `RegistryRecord` in pi/extensions/ghostty-agent.ts.
    struct Record: Decodable {
        struct Host: Decodable {
            let kind: String // ghostty | tmux | terminal
            let bundleId: String?
            let surface: String?
            let pane: String?
            let program: String?
        }
        let sessionId: String
        let name: String
        let sessionFile: String?
        let cwd: String
        let pid: Int32
        let host: Host
        let state: String // working | idle | needs-input | background
        let backgroundTasks: Int
        let label: String?
        let slackThreadTs: String?
        let startedAt: Double
        let stateSince: Double

        var title: String { label ?? name }
        var folder: String { (cwd as NSString).lastPathComponent }
    }

    private enum Place: Int, CaseIterable {
        case thisGhostty, tmux, elsewhere

        var heading: String {
            switch self {
            case .thisGhostty: return "In Ghostty"
            case .tmux: return "In the background (tmux)"
            case .elsewhere: return "In other terminals"
            }
        }
    }

    private struct Entry {
        let record: Record
        let place: Place
        let window: NSWindow?
        let rssKB: Int?
    }

    private var statusItem: NSStatusItem?
    private var titleTimer: Timer?

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "pi sessions")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        refreshTitle()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    // MARK: - Registry

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Live records, plus the names of files that would not decode. Files of
    /// dead pids are removed.
    private func loadRecords() -> (records: [Record], unreadable: [String]) {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: Self.registryDirectory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], [])
        } catch {
            menuLog.error("registry folder unreadable: \(error.localizedDescription, privacy: .public)")
            return ([], ["\(Self.registryDirectory.path): \(error.localizedDescription)"])
        }
        var records: [Record] = []
        var unreadable: [String] = []
        for name in names where name.hasSuffix(".json") {
            let url = Self.registryDirectory.appendingPathComponent(name)
            do {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
                if Self.isAlive(record.pid) {
                    records.append(record)
                } else {
                    try fm.removeItem(at: url)
                    menuLog.info("removed registry file of dead pid \(record.pid): \(name, privacy: .public)")
                }
            } catch {
                menuLog.error("registry file \(name, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
                unreadable.append(name)
            }
        }
        return (records, unreadable)
    }

    /// Resident memory per pid in KB, from one `ps` call.
    private func residentKB(_ pids: [Int32]) -> [Int32: Int] {
        guard !pids.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,rss=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            menuLog.error("ps failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var result: [Int32: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, let pid = Int32(parts[0]), let rss = Int(parts[1]) { result[pid] = rss }
        }
        return result
    }

    private func entries() -> (entries: [Entry], unreadable: [String]) {
        let (records, unreadable) = loadRecords()
        let rss = residentKB(records.map(\.pid))
        let bundleId = Bundle.main.bundleIdentifier
        let entries = records.map { record -> Entry in
            var place: Place = .elsewhere
            var window: NSWindow?
            switch record.host.kind {
            case "ghostty":
                if record.host.bundleId == bundleId, let surface = record.host.surface,
                   let found = AgentSidebarModel.shared.window(forSurfaceKey: surface) {
                    place = .thisGhostty
                    window = found
                }
            case "tmux":
                place = .tmux
            default:
                break
            }
            return Entry(record: record, place: place, window: window, rssKB: rss[record.pid])
        }
        .sorted { $0.record.stateSince > $1.record.stateSince }
        return (entries, unreadable)
    }

    private func refreshTitle() {
        let count = loadRecords().records.count
        statusItem?.button?.title = count > 0 ? " \(count)" : ""
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let (entries, unreadable) = entries()
        statusItem?.button?.title = entries.isEmpty ? "" : " \(entries.count)"

        let totalKB = entries.compactMap(\.rssKB).reduce(0, +)
        let idleBackground = entries.filter { $0.place == .tmux && $0.record.state == "idle" }
        menu.addItem(disabled("\(entries.count) pi session\(entries.count == 1 ? "" : "s") · \(Self.memory(totalKB))"))

        for name in unreadable {
            menu.addItem(disabled("Unreadable registry file: \(name)"))
        }

        for place in Place.allCases {
            let group = entries.filter { $0.place == place }
            guard !group.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(disabled(place.heading))
            for entry in group { menu.addItem(row(entry)) }
        }

        menu.addItem(.separator())
        let endIdle = NSMenuItem(
            title: "End Idle Background Sessions (\(idleBackground.count))…",
            action: #selector(endIdleBackground(_:)), keyEquivalent: "")
        endIdle.target = self
        endIdle.isEnabled = !idleBackground.isEmpty
        endIdle.representedObject = idleBackground.map(\.record)
        menu.addItem(endIdle)
    }

    /// Diagnostic for the "dump" wire event: write the menu as it would open
    /// to /tmp/ghostty-session-menu.json, since a status item menu cannot be
    /// screenshotted headlessly.
    func dump() {
        let menu = NSMenu()
        menuWillOpen(menu)
        func items(_ menu: NSMenu) -> [[String: Any]] {
            menu.items.map { item in
                var entry: [String: Any] = ["title": item.isSeparatorItem ? "---" : item.title, "enabled": item.isEnabled]
                if let submenu = item.submenu { entry["submenu"] = items(submenu) }
                return entry
            }
        }
        let url = URL(fileURLWithPath: "/tmp/ghostty-session-menu.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: items(menu), options: [.prettyPrinted])
            try data.write(to: url)
        } catch {
            menuLog.error("session menu dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func row(_ entry: Entry) -> NSMenuItem {
        let record = entry.record
        let item = NSMenuItem(title: "\(record.title) · \(record.folder) · \(Self.stateText(record))", action: nil, keyEquivalent: "")
        item.image = Self.stateImage(record.state)
        item.isEnabled = true

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        var facts = [record.name]
        if record.slackThreadTs != nil { facts.append("Slack on") }
        if let kb = entry.rssKB { facts.append(Self.memory(kb)) }
        facts.append("started \(Self.age(since: record.startedAt)) ago")
        submenu.addItem(disabled(facts.joined(separator: " · ")))
        submenu.addItem(disabled((record.cwd as NSString).abbreviatingWithTildeInPath))
        submenu.addItem(.separator())

        if entry.place == .thisGhostty {
            submenu.addItem(action("Show Tab", #selector(showTab(_:)), entry.window as Any))
        } else {
            let move = action("Move to Ghostty Tab", #selector(moveToTab(_:)), record)
            // pi writes its session file after the first exchange; before
            // that there is no conversation to resume.
            let hasFile = record.sessionFile.map { FileManager.default.fileExists(atPath: $0) } ?? false
            move.isEnabled = hasFile
            if !hasFile { move.title = "Move to Ghostty Tab (no conversation yet)" }
            submenu.addItem(move)
        }
        submenu.addItem(action("End Session", #selector(endSession(_:)), record))
        item.submenu = submenu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.isEnabled = true
        return item
    }

    private static func stateText(_ record: Record) -> String {
        let since = age(since: record.stateSince)
        switch record.state {
        case "working": return "working \(since)"
        case "needs-input": return "needs input \(since)"
        case "background": return "\(record.backgroundTasks) background task\(record.backgroundTasks == 1 ? "" : "s")"
        default: return "idle \(since)"
        }
    }

    private static func stateImage(_ state: String) -> NSImage? {
        let color: NSColor
        switch state {
        case "working": color = .systemBlue
        case "needs-input": color = .systemOrange
        case "background": color = .systemPurple
        default: color = .systemGray
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: state)?
            .withSymbolConfiguration(config)
    }

    /// Registry timestamps are JavaScript milliseconds.
    private static func age(since ms: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    private static func memory(_ kb: Int) -> String {
        kb >= 1024 * 1024
            ? String(format: "%.1f GB", Double(kb) / 1024 / 1024)
            : "\(kb / 1024) MB"
    }

    // MARK: - Actions

    @objc private func showTab(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        AgentSidebarModel.shared.focus(AgentSidebarModel.Row(window: window))
    }

    @objc private func endSession(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? Record else { return }
        terminate(record)
    }

    @objc private func endIdleBackground(_ sender: NSMenuItem) {
        guard let records = sender.representedObject as? [Record], !records.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "End \(records.count) idle background session\(records.count == 1 ? "" : "s")?"
        alert.informativeText = records.map { "\($0.title) (\($0.name))" }.joined(separator: "\n")
        alert.addButton(withTitle: "End Sessions")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        records.forEach(terminate)
    }

    private func terminate(_ record: Record) {
        if kill(record.pid, SIGTERM) != 0 {
            let message = String(cString: strerror(errno))
            fail("Could not end \(record.title) (pid \(record.pid)): \(message)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshTitle() }
    }

    @objc private func moveToTab(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? Record, let file = record.sessionFile else { return }
        guard kill(record.pid, SIGTERM) == 0 else {
            fail("Could not end \(record.title) (pid \(record.pid)) to move it: \(String(cString: strerror(errno)))")
            return
        }
        // pi runs session_shutdown on SIGTERM (Slack posts "Session ended.",
        // the registry file goes away), then exits.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(10)
            while Self.isAlive(record.pid), Date() < deadline { usleep(100_000) }
            let stillAlive = Self.isAlive(record.pid)
            DispatchQueue.main.async {
                guard let self else { return }
                if stillAlive {
                    self.fail("\(record.title) (pid \(record.pid)) did not exit within 10 seconds of SIGTERM. It was not moved.")
                    return
                }
                self.openTab(sessionFile: file, cwd: record.cwd, label: record.label)
            }
        }
    }

    /// A new tab in the current frame (the cmd+T path), like the workspace
    /// hotkeys; with no terminal window it opens a new one.
    private func openTab(sessionFile: String, cwd: String, label: String?) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
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
            return
        }
        if let label, let surface = controller.surfaceTree.root?.leaves().first?.surface {
            AgentSidebarModel.shared.restoreLabel(label, for: AgentSidebarModel.surfaceKey(ghostty_surface_id(surface)))
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func fail(_ message: String) {
        menuLog.error("\(message, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "pi session menu"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
