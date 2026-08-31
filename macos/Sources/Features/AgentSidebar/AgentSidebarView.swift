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
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.rows(for: ownWindow)) { row in
                    rowView(row)
                }
            }
            .padding(6)
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

    private func rowView(_ row: AgentSidebarModel.Row) -> some View {
        let selected = row.id == model.selectedRowID || row.window === ownWindow
        return Button(action: { model.focus(row) }) {
            HStack(spacing: 8) {
                dotsView(for: row)
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(selected ? 0.14 : 0.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// One dot per live agent session in the row's window (max 4,
    /// highest-priority states first). A window with no live sessions shows
    /// a single dim idle dot so the row never looks empty.
    private func dotsView(for row: AgentSidebarModel.Row) -> some View {
        let states = model.states(for: row.window)
        return HStack(spacing: 3) {
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
            .frame(width: 8, height: 8)
    }

    private func dotColor(for state: AgentSidebarModel.RowState) -> Color {
        switch state {
        case .working: return .blue
        case .needsYou: return .orange
        case .idle: return Color.secondary.opacity(0.5)
        }
    }
}
