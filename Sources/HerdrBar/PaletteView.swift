import SwiftUI
import HerdrBarCore

struct PaletteView: View {
    @ObservedObject var store: AgentStore
    var close: () -> Void
    var editConnection: () -> Void
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.rows.isEmpty {
                emptyState
            } else {
                agentList
            }
            if let error = store.actionError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.actionError = nil; store.onChange?() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss message")
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.blocked)
                .padding(.horizontal, 12)
                .frame(height: 66)
            }
            footer
        }
        .frame(width: Theme.width)
        .background(Theme.background)
        .foregroundStyle(Theme.foreground)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(.upArrow) { store.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { store.moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { store.openSelected(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Herdr agents")
    }

    private var header: some View {
        HStack {
            Text("agents").font(Theme.header)
            Spacer()
            Button {
                store.order = store.order == .grouped ? .attention : .grouped
            } label: {
                HStack(spacing: 4) {
                    Text(store.order.rawValue)
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 9))
                }
            }
            .buttonStyle(QuietButtonStyle())
            .help(store.order == .grouped ? "Show agents that need attention first" : "Group agents by workspace")
            .accessibilityLabel("Sort agents. Current order: \(store.order.rawValue)")
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var agentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sortedRows) { row in
                        AgentRowView(row: row, selected: store.selectedID == row.id,
                                     opening: store.openingID == row.id,
                                     available: store.connected) {
                            store.open(row)
                        }
                        .disabled(!store.connected || store.openingID != nil)
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
            .frame(height: min(CGFloat(store.rows.count) * Theme.rowHeight + 8, Theme.maximumListHeight))
            .onChange(of: store.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if store.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: store.connected ? "terminal" : "bolt.slash")
                        .foregroundStyle(Theme.muted)
                }
                Text(store.loading ? "Connecting to Herdr" : store.connected ? "No agents yet" : "Herdr is offline")
                    .font(Theme.body)
            }
            Text(store.loading ? "Reading agent status." : store.connected
                 ? "Start an agent in Herdr. It will appear here."
                 : "Start Herdr in your terminal. This list will update automatically.")
                .font(Theme.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !store.loading, !store.connected {
                Button("Retry connection") { Task { await store.refresh() } }
                    .font(Theme.caption)
                    .buttonStyle(QuietButtonStyle())
                    .foregroundStyle(Theme.done)
                    .help(store.connectionError ?? "Connect to Herdr")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(height: 144)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Theme.divider.frame(height: 1)
            HStack(spacing: 8) {
                if store.connected {
                    Text(store.summary.description.isEmpty ? "Waiting for agents" : store.summary.description)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(store.summary.description)
                        .accessibilityLabel("Status: \(store.summary.description)")
                } else {
                    Image(systemName: store.loading ? "ellipsis" : "bolt.slash")
                    Text(store.loading ? "Connecting" : "Offline · retrying")
                        .help(store.connectionError ?? "Connecting to Herdr")
                }
                Spacer(minLength: 0)
                settings
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 14)
            .frame(height: 41)
        }
    }

    private var settings: some View {
        Menu {
            Button("Refresh now") { Task { await store.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Mark completed agents as read") { store.markDoneAsRead() }
                .disabled(store.summary.done == 0)
            Divider()
            Toggle("Notify when agents need attention", isOn: Binding(
                get: { store.notificationsEnabled }, set: { store.setNotifications($0) }))
            Toggle("Start at login", isOn: Binding(
                get: { store.startsAtLogin }, set: { store.setStartsAtLogin($0) }))
            Picker("Terminal", selection: $store.terminalID) {
                ForEach(TerminalActivator.choices, id: \.0) { choice in
                    Text(choice.1).tag(choice.0)
                }
            }
            Button("Connection…", action: editConnection)
            Divider()
            Text("Herdr Bar 1.0")
            Button("Quit Herdr Bar") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .font(.system(size: 12))
                .frame(width: 22, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
        .accessibilityLabel("Herdr Bar settings")
    }
}

struct AgentRowView: View {
    let row: AgentRow
    let selected: Bool
    let opening: Bool
    let available: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                StatusMark(status: row.status)
                    .frame(width: 10, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(row.workspace)
                            .foregroundStyle(Theme.foreground)
                            .layoutPriority(1)
                        Text("· \(row.tab)")
                            .foregroundStyle(Theme.muted)
                    }
                    .font(Theme.body)
                    .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(row.kind).foregroundStyle(Theme.muted)
                        Spacer(minLength: 2)
                        if opening {
                            Text("opening…").foregroundStyle(Theme.muted)
                        } else if row.status != .idle || hovered {
                            Text(row.status.label.lowercased())
                                .foregroundStyle(Theme.color(for: row.status))
                        }
                    }
                    .font(Theme.caption)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: Theme.rowHeight)
            .background(selected ? Theme.selected : hovered ? Theme.hover : Theme.background)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovered = $0 }
        .opacity(available ? 1 : 0.45)
        .help("\(row.title)\n\(row.status.label) · \(row.detail)\nClick to open in Herdr")
        .accessibilityLabel("\(row.workspace), tab \(row.tab), \(row.kind), \(row.status.label)")
        .accessibilityHint(available ? "Open this agent in Herdr" : "Herdr is offline")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct StatusMark: View {
    let status: AgentStatus

    var body: some View {
        Group {
            switch status {
            case .idle:
                Circle().strokeBorder(Theme.idle, lineWidth: 1).frame(width: 7, height: 7)
            case .working:
                Circle().fill(Theme.running).frame(width: 7, height: 7)
            case .blocked:
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.blocked)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.done)
            case .unknown:
                Image(systemName: "questionmark").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.unknown)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(configuration.isPressed ? Theme.focus.opacity(0.12) : .clear)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
