import SwiftUI

/// Popover shown when the menu bar item is clicked.
/// Displays the agent list.
/// Observes PastureStore directly and reflects state changes in real time while open.
struct BarPopoverView: View {
    let store: PastureStore
    let settings: BarDotSettingsStore
    let onReconnect: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    /// Agents to display, prioritized by state and limited to nine.
    private var agents: [PastureAgent] { BarAgentSelection.select(store.sortedAgents) }
    private var totalAgentCount: Int { store.sortedAgents.count }
    private var connectionState: ConnectionState { store.connectionState }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if totalAgentCount > BarAgentSelection.maxAgents {
                overflowNotice
            }
            Divider()
            agentList
            Divider()
            footer
        }
        .frame(width: 260)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("HerdEye")
                .font(.headline)
            Spacer()
            connectionLabel
            // Always available: a connection can stall while still reporting `.live`
            // (herdr alive but sending nothing), so gating this on `.reconnecting`
            // hid the only manual recovery from the exact case it was meant to fix.
            Button(action: onReconnect) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Reconnect")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch connectionState {
        case .live:
            Label("Live", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .connecting:
            Label("Connecting", systemImage: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.orange)
        case .reconnecting(let attempt):
            Label("Reconnect #\(attempt)", systemImage: "arrow.clockwise.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var overflowNotice: some View {
        if totalAgentCount > agents.count {
            HStack {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("\(totalAgentCount - agents.count) hidden (priority: active first)")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit HerdEye", action: onQuit)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Agent List

    private var agentList: some View {
        Group {
            if agents.isEmpty {
                Text(connectionState == .live ? "No agents" : "Waiting for connection…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(agents) { agent in
                            AgentRow(agent: agent, settings: settings)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }
}

// MARK: - DotView

/// Renders a single dot. Shape, outline, and fill follow BarDotSettingsStore.
/// Empty slots (no agent) use a light-gray circular outline.
struct DotView: View {
    let state: AgentState?
    let size: CGFloat
    let isLive: Bool
    let settings: BarDotSettingsStore

    /// A nil state represents an empty slot with no agent.
    private var isEmpty: Bool { !isLive || state == nil }

    var body: some View {
        if isEmpty {
            Circle()
                .strokeBorder(.gray.opacity(0.8), lineWidth: 1)
                .frame(width: size, height: size)
        } else {
            let appearance = settings.appearance(for: state!)
            dotShape(appearance.shape)
                .fill(appearance.fill ? appearance.fillColor.color : .clear)
                .overlay(
                    dotShape(appearance.shape)
                        .stroke(appearance.outline ? appearance.outlineColor.color : .clear, lineWidth: outlineWidth)
                )
                .frame(width: size, height: size)
        }
    }

    private var outlineWidth: CGFloat {
        max(1, size * 0.15)
    }

    private func dotShape(_ shape: DotShape) -> AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .square: AnyShape(RoundedRectangle(cornerRadius: size * 0.15))
        }
    }
}

// MARK: - AgentRow

/// One row in the agent list: dot, labels, and state text.
struct AgentRow: View {
    let agent: PastureAgent
    let settings: BarDotSettingsStore

    var body: some View {
        HStack(spacing: 8) {
            DotView(state: agent.state, size: 10, isLive: true, settings: settings)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.primaryLabel)
                    .font(.caption)
                    .lineLimit(1)
                Text(agent.secondaryLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(stateLabel)
                .font(.caption2)
                .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var stateLabel: String {
        switch agent.state {
        case .idle:     "Idle"
        case .working:  "Working"
        case .blocked:  "Blocked"
        case .done:     "Done"
        case .unknown:  "?"
        }
    }

    private var stateColor: Color {
        let a = settings.appearance(for: agent.state)
        return a.fill ? a.fillColor.color : a.outlineColor.color
    }
}
