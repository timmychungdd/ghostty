import AppKit

/// Fork feature: cmd+1/2/3/0 open preset workspace windows — cwd at a base
/// directory, yazi in a 30%-width left split, pi in the 70% right split,
/// focus on pi. Hardcoded, no config surface.
///
/// These keys override stock goto_tab (a libghostty default keybind): this
/// local monitor consumes the event before the surface's key handling sees
/// it. Tab selection remains via sidebar click and opt+cmd+arrows.
final class WorkspaceHotkeys {
    static let shared = WorkspaceHotkeys()

    /// ANSI keyCode -> base directory (1=18, 2=19, 3=20, 0=29).
    private static let workspaces: [UInt16: String] = [
        18: "/Users/tim.chung/Projects/agent-config",
        19: "/Users/tim.chung/Projects/wayfinder-support",
        20: "/Users/tim.chung/Projects/pedregal",
        29: "/Users/tim.chung/Projects",
    ]

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
                  let dir = Self.workspaces[event.keyCode] else { return event }
            Self.open(baseDir: dir)
            return nil
        }
    }

    private static func open(baseDir: String) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }

        // Commands go through a login shell: the GUI-launched app's PATH is
        // minimal and pi is a pnpm shim that needs Tim's full environment.
        var left = Ghostty.SurfaceConfiguration()
        left.workingDirectory = baseDir
        left.command = "/bin/zsh -lc yazi"

        // With tabbingMode .preferred the new window may join the key
        // window's frame as a native tab — either way it becomes a new
        // sidebar row.
        let controller = TerminalController.newWindow(delegate.ghostty, withBaseConfig: left)

        guard let root = controller.surfaceTree.root,
              case .leaf(let initial) = root else { return }

        var right = Ghostty.SurfaceConfiguration()
        right.workingDirectory = baseDir
        right.command = "/bin/zsh -lc pi"
        // newSplit moves focus to the new (right) surface.
        guard controller.newSplit(at: initial, direction: .right, baseConfig: right) != nil else {
            return
        }

        // 30/70: yazi left third, pi the rest.
        if let splitRoot = controller.surfaceTree.root {
            controller.surfaceTree = SplitTree(
                root: splitRoot.resizing(to: 0.3),
                zoomed: controller.surfaceTree.zoomed)
        }
    }
}
