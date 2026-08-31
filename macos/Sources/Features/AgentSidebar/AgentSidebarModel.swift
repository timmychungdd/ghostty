import AppKit
import Combine
import Darwin
import Foundation
import GhosttyKit

/// AgentSidebarModel is the singleton state store behind the agent sidebar.
/// It listens for pi lifecycle events on a unix socket, tracks per-surface
/// agent state, and knows the app's terminal windows so each window's
/// sidebar can render one row per window.
final class AgentSidebarModel: ObservableObject {
    static let shared = AgentSidebarModel()

    /// Row status vocabulary (goal doc): exactly three states.
    enum RowState: Int, Comparable {
        case idle = 0
        case working = 1
        case needsYou = 2

        static func < (lhs: RowState, rhs: RowState) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One sidebar row: one terminal window.
    struct Row: Identifiable {
        let window: NSWindow
        var id: ObjectIdentifier { ObjectIdentifier(window) }

        var title: String {
            let t = window.title
            return t.isEmpty ? "Terminal" : t
        }
    }

    /// Surface id ("0x%016x") -> agent state, fed by the socket listener.
    @Published private(set) var surfaceStates: [String: RowState] = [:]

    /// Bump when the window list may have changed so views rebuild rows.
    @Published private(set) var windowListGeneration: UInt = 0

    /// Currently selected row for opt+cmd+arrow cycling.
    @Published private(set) var selectedRowID: ObjectIdentifier?

    private var keyMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    private init() {
        startListener()
        startKeyMonitor()
        observeWindowLifecycle()
    }

    // MARK: - Rows

    /// The current rows: one per terminal window, in screen order.
    var rows: [Row] {
        TerminalController.all.compactMap { $0.window }.map { Row(window: $0) }
    }

    /// Call when a terminal window is created so sidebars refresh.
    func noteWindowListChanged() {
        DispatchQueue.main.async { self.windowListGeneration &+= 1 }
    }

    /// Agent state for a window: highest-priority state across its surfaces.
    func state(for window: NSWindow) -> RowState {
        guard let controller = window.windowController as? BaseTerminalController else {
            return .idle
        }
        var result: RowState = .idle
        for leaf in controller.surfaceTree.root?.leaves() ?? [] {
            guard let surface = leaf.surface else { continue }
            let key = Self.surfaceKey(ghostty_surface_id(surface))
            if let state = surfaceStates[key], state > result { result = state }
        }
        return result
    }

    static func surfaceKey(_ id: UInt64) -> String {
        // Must match Zig's format exactly: "0x" + 16 lowercase hex digits.
        // (%016x would read only 32 bits of the UInt64 vararg; %016llx reads all 64.)
        String(format: "0x%016llx", id)
    }

    // MARK: - Focus

    func focus(_ row: Row) {
        selectedRowID = row.id
        row.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// opt+cmd+left/right: cycle row selection and focus the selected window.
    func cycle(_ delta: Int) {
        let current = rows
        guard !current.isEmpty else { return }
        let index = current.firstIndex { $0.id == selectedRowID } ?? 0
        let next = (index + delta + current.count) % current.count
        focus(current[next])
    }

    // MARK: - Key monitor (opt+cmd+arrows)

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                      .isSuperset(of: [.option, .command]) else { return event }
            switch Int(event.keyCode) {
            case 123: self.cycle(-1); return nil  // left
            case 124: self.cycle(1); return nil   // right
            default: return event
            }
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
        })
    }

    // MARK: - Event application

    private func apply(type: String, surface: String) {
        switch type {
        case "session_start":
            surfaceStates[surface] = .idle
        case "turn_start", "tool", "working":
            surfaceStates[surface] = .working
        case "awaiting_input", "settled":
            surfaceStates[surface] = .needsYou
        case "session_end":
            surfaceStates.removeValue(forKey: surface)
        default:
            return
        }
    }

    // MARK: - Unix socket listener

    private static let socketPath =
        NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty/agent-events.sock"

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
        let surface: String
    }

    private func handleLine(_ bytes: [UInt8]) {
        guard let event = try? JSONDecoder().decode(WireEvent.self, from: Data(bytes)),
              !event.surface.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.apply(type: event.type, surface: event.surface)
        }
    }
}
