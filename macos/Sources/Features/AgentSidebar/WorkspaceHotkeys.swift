import AppKit

/// Fork feature: cmd+1/2/3/4/0 open preset workspace windows — one pi pane
/// with its cwd at a base directory. Hardcoded, no config surface.
///
/// These keys override stock goto_tab (a libghostty default keybind): this
/// local monitor consumes the event before the surface's key handling sees
/// it. Tab selection remains via sidebar click and opt+cmd+arrows.
final class WorkspaceHotkeys {
    static let shared = WorkspaceHotkeys()

    /// The command workspace panes launch with. It ends in `exec zsh -il`:
    /// pi owns the pane's process, so pi exiting (ctrl+D on empty editor,
    /// crash) would otherwise close the pane. Dropping into an interactive
    /// shell keeps the pane alive.
    static let piCommand = "/bin/zsh -ilc \"pi; exec zsh -il\""

    /// The command a restored pane runs to reopen one exact pi session file
    /// (WorkspaceStore). Same shell wrapper as `piCommand`.
    static func piResumeCommand(sessionFile: String) -> String {
        let quoted = "'" + sessionFile.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "/bin/zsh -ilc \"pi --session \(quoted); exec zsh -il\""
    }

    /// ANSI keyCode -> base directory (1=18, 2=19, 3=20, 4=21, 0=29).
    private static let workspaces: [UInt16: String] = [
        18: "/Users/tim.chung/Projects/agent-config",
        19: "/Users/tim.chung/Projects/wayfinder-support",
        20: "/Users/tim.chung/Projects/pedregal",
        21: "/Users/tim.chung/Projects/auto-company",
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
        // -i matters: Tim's PATH (homebrew, ~/.local/bin) is set in .zshrc,
        // which non-interactive login shells skip.
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = baseDir
        config.command = Self.piCommand

        // Tab into the current frame (the cmd+T path) so the workspace
        // becomes a new sidebar row in the SAME window. Parent = key window
        // when it's a terminal; otherwise the preferred parent (main window,
        // else most recent) — keyWindow is nil while the app is inactive.
        // With no terminal window at all this falls back to a fresh frame;
        // a non-native-fullscreen parent gets the standard alert and no tab.
        var parent = NSApp.keyWindow
        if !(parent?.windowController is TerminalController) {
            parent = TerminalController.preferredParent?.window
        }
        _ = TerminalController.newTab(delegate.ghostty, from: parent, withBaseConfig: config)
    }
}
