import SwiftUI

/// The agent sidebar: one row per terminal window with a three-state
/// agent status glyph. Colors come from the resolved Ghostty config so
/// the panel always matches the main window theme.
struct AgentSidebarView: View {
    @ObservedObject var model: AgentSidebarModel
    /// The window this sidebar instance lives in, to highlight its own row.
    let ownWindowID: ObjectIdentifier?
    /// The resolved Ghostty config; color properties read live from the C config.
    let config: Ghostty.Config

    var body: some View {
        let _ = model.windowListGeneration
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.rows) { row in
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
        let selected = row.id == model.selectedRowID || row.id == ownWindowID
        return Button(action: { model.focus(row) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(glyphColor(for: row))
                    .frame(width: 8, height: 8)
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

    private func glyphColor(for row: AgentSidebarModel.Row) -> Color {
        switch model.state(for: row.window) {
        case .working: return .blue
        case .needsYou: return .orange
        case .idle: return Color.secondary.opacity(0.5)
        }
    }
}
