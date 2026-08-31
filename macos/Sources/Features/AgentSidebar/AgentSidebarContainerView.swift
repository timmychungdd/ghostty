import AppKit
import SwiftUI

/// Wraps a terminal window's content with the agent sidebar: fixed-width
/// column on the left, terminal content filling the rest.
final class AgentSidebarContainerView: NSView {
    static let sidebarWidth: CGFloat = 200

    private let sidebarView: NSView
    private let terminalContent: NSView

    init(config: Ghostty.Config, terminalContent: NSView) {
        self.terminalContent = terminalContent
        self.sidebarView = NSHostingView(rootView: AgentSidebarView(
            model: AgentSidebarModel.shared,
            ownWindowID: nil,
            config: config
        ))
        super.init(frame: .zero)
        addSubview(sidebarView)
        addSubview(terminalContent)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = terminalContent.intrinsicContentSize
        if size.width > 0 { size.width += Self.sidebarWidth }
        return size
    }

    override func layout() {
        super.layout()
        sidebarView.frame = NSRect(
            x: 0, y: 0,
            width: Self.sidebarWidth, height: bounds.height)
        terminalContent.frame = NSRect(
            x: Self.sidebarWidth, y: 0,
            width: max(0, bounds.width - Self.sidebarWidth), height: bounds.height)
    }
}
