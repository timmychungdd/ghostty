import AppKit
import SwiftUI

/// The agent sidebar: one row per tab in this window frame's tab group with
/// a three-state agent status glyph. Colors come from the resolved Ghostty
/// config so the panel always matches the main window theme.
struct AgentSidebarView: View {
    @ObservedObject var model: AgentSidebarModel
    /// The window this sidebar instance lives in. Its tab group defines the
    /// row list, and its own row is highlighted. Weak: the view must not
    /// retain the window whose content view hosts it.
    weak var ownWindow: NSWindow?
    /// The resolved Ghostty config; color properties read live from the C config.
    let config: Ghostty.Config

    var body: some View {
        let _ = model.windowListGeneration
        let scale = model.uiScale
        ScrollView {
            VStack(alignment: .leading, spacing: 2 * scale) {
                ForEach(model.rows(for: ownWindow)) { row in
                    SidebarRowView(
                        row: row,
                        model: model,
                        selected: row.id == model.selectedRowID || row.window === ownWindow,
                        scale: scale
                    )
                }
            }
            .padding(6 * scale)
        }
        // Fork: no safe-area games here — with the traffic lights visible
        // (HiddenTitlebarTerminalWindow fork edit), the window's top safe
        // area covers the light zone and ScrollView insets rows below it
        // automatically.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(backgroundColor)
    }

    private var backgroundColor: Color {
        config.backgroundColor.opacity(config.backgroundOpacity)
    }
}

/// One sidebar row: status dots, title, and a close button that appears on
/// hover (always visible on the selected row, Safari-style). The row body
/// focuses the workspace; the × closes it without focusing first. All
/// metrics multiply by the model's UI scale (cmd+= / cmd+-).
private struct SidebarRowView: View {
    let row: AgentSidebarModel.Row
    let model: AgentSidebarModel
    let selected: Bool
    let scale: CGFloat
    @State private var hovering = false
    @State private var closeHovering = false

    var body: some View {
        let unread = model.unreadWindows.contains(row.id)
        HStack(spacing: 8 * scale) {
            dotsView
            Text(model.label(for: row.window) ?? row.title)
                .font(.system(size: 12 * scale, weight: unread ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if unread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6 * scale, height: 6 * scale)
            }
            if hovering || selected {
                Button(action: { model.closeWorkspace(row) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8 * scale, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 15 * scale, height: 15 * scale)
                        .background(
                            Circle().fill(Color.primary.opacity(closeHovering ? 0.18 : 0.0))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { closeHovering = $0 }
            }
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 6 * scale)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6 * scale)
                .fill(Color.primary.opacity(selected ? 0.14 : 0.0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6 * scale))
        .onTapGesture { model.focus(row) }
        .onHover { hovering = $0 }
        .help(row.window.title)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    /// One dot per live agent session in the row's window (max 4,
    /// highest-priority states first). A window with no live sessions shows
    /// a single dim idle dot so the row never looks empty.
    private var dotsView: some View {
        let states = model.states(for: row.window)
        return HStack(spacing: 3 * scale) {
            if states.isEmpty {
                dotView(.idle)
            } else {
                ForEach(Array(states.prefix(4).enumerated()), id: \.offset) { _, state in
                    dotView(state)
                }
            }
        }
    }

    private func dotView(_ state: AgentSidebarModel.RowState) -> some View {
        Circle()
            .fill(dotColor(for: state))
            .frame(width: 8 * scale, height: 8 * scale)
    }

    private func dotColor(for state: AgentSidebarModel.RowState) -> Color {
        switch state {
        case .working: return .blue
        case .needsYou: return .orange
        case .background: return .purple
        case .idle: return Color.secondary.opacity(0.5)
        }
    }
}
