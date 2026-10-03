import SwiftUI
import HerdrBarCore

struct PaletteView: View {
    @ObservedObject var store: AgentStore
    var close: () -> Void
    var editConnection: () -> Void
    @FocusState private var hasKeyboardFocus: Bool
    @FocusState private var focusedRowID: String?
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.connected, !store.rows.isEmpty { offlineNotice }
            if store.rows.isEmpty { emptyState } else { agentList }
            if let error = store.actionError { errorNotice(error) }
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
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.return) {
            guard hasKeyboardFocus || focusedRowID != nil else { return .ignored }
            store.openSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            if store.actionError != nil { store.dismissActionError() }
            else { close() }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Herdr agents")
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard hasKeyboardFocus || focusedRowID != nil else { return .ignored }
        store.moveSelection(by: offset)
        hasKeyboardFocus = true
        return .handled
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("agents").font(Theme.header)
            if !store.rows.isEmpty {
                Text("\(store.rows.count)")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("\(store.rows.count) agents")
            }
            Spacer()
            Menu {
                Picker("Sort agents", selection: $store.order) {
                    Text("Workspace").tag(AgentOrder.grouped)
                    Text("Needs attention first").tag(AgentOrder.attention)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(store.order == .grouped ? "Workspace" : "Attention")
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(Theme.caption)
            .fixedSize()
            .help("Sort by workspace or show agents that need attention first")
            .accessibilityLabel("Sort agents")
            .accessibilityValue(store.order == .grouped ? "Workspace" : "Needs attention first")
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.headerHeight)
    }

    private var agentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.rowSpacing) {
                    ForEach(store.sortedRows) { row in
                        AgentRowView(row: row, selected: store.selectedID == row.id,
                                     opening: store.openingID == row.id,
                                     available: store.connected) {
                            store.open(row)
                        }
                        .disabled(!store.connected || store.openingID != nil)
                        .focused($focusedRowID, equals: row.id)
                        .id(row.id)
                    }
                }
                .padding(Theme.listInset)
            }
            .scrollIndicators(.automatic)
            .frame(height: store.listHeight)
            .defaultScrollAnchor(.top)
            .onAppear { if let id = store.selectedID { proxy.scrollTo(id) } }
            .onChange(of: store.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: focusedRowID) { _, id in
                if let id { store.selectedID = id }
            }
            .onChange(of: store.sortedRows.map(\.id)) { _, _ in
                if let id = store.selectedID { proxy.scrollTo(id) }
            }
            .onChange(of: store.listHeight) { _, _ in
                if let id = store.selectedID { proxy.scrollTo(id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if store.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: store.connected ? "terminal" : "bolt.slash")
                        .foregroundStyle(store.connected ? Theme.muted : Theme.blocked)
                }
                Text(store.loading ? "Connecting to Herdr" : store.connected ? "No agents yet" : "Herdr is offline")
                    .font(Theme.body)
            }
            Text(store.loading ? "Reading agent status…" : store.connected
                 ? "Start an agent in Herdr. It will appear here."
                 : "Start Herdr in your terminal, or choose a different connection. We will retry automatically.")
                .font(Theme.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !store.loading, !store.connected { recoveryActions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .frame(height: Theme.emptyHeight)
    }

    private var offlineNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Offline · showing last known status", systemImage: "bolt.slash")
                .foregroundStyle(Theme.blocked)
            recoveryActions
        }
        .font(Theme.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(height: Theme.offlineHeight)
        .background(Theme.blocked.opacity(0.06))
    }

    private var recoveryActions: some View {
        HStack(spacing: 8) {
            Button(action: refresh) {
                HStack(spacing: 6) {
                    if retrying { ProgressView().controlSize(.mini) }
                    Text(retrying ? "Connecting…" : "Retry connection")
                }
            }
            .disabled(retrying)
            .help(store.connectionError ?? "Connect to Herdr")
            Button("Connection…", action: editConnection)
        }
        .font(Theme.caption)
        .buttonStyle(QuietButtonStyle())
    }

    private func errorNotice(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .help(error)
                if Theme.errorNeedsScrolling(error) {
                    Label("Scroll to read the full message", systemImage: "chevron.down")
                        .font(.system(size: 11))
                }
            }
            Button(action: store.dismissActionError) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Dismiss message (Esc)")
            .accessibilityLabel("Dismiss message")
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.blocked)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: Theme.errorHeight(error))
        .background(Theme.blocked.opacity(0.06))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Theme.divider.frame(height: 1)
            HStack(spacing: 8) {
                Text(store.connected
                     ? (store.summary.description.isEmpty ? "Waiting for agents" : store.summary.description)
                     : store.loading ? "Connecting to Herdr…" : "Offline · retrying automatically")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(store.connected ? store.summary.description : store.connectionError ?? "")
                settings
            }
            .frame(height: 37)
            HStack(spacing: 12) {
                if store.connected, !store.rows.isEmpty {
                    keyboardHint("↑↓", "Select")
                    keyboardHint("↵", store.openingID == nil ? "Open" : "Opening…")
                }
                keyboardHint("esc", store.actionError == nil ? "Close" : "Dismiss")
                Spacer(minLength: 0)
                if store.connected {
                    Text(store.transportMode)
                        .help(store.diagnostics)
                        .accessibilityLabel("Connection: \(store.diagnostics)")
                }
            }
            .frame(height: 30)
            Spacer(minLength: 0)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 16)
        .frame(height: Theme.footerHeight)
    }

    private func keyboardHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .frame(height: 17)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 11))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key == "↑↓" ? "Up and Down arrows" : key == "↵" ? "Return" : "Escape"): \(label)")
    }

    private func refresh() {
        guard !retrying else { return }
        retrying = true
        Task {
            await store.refresh()
            retrying = false
        }
    }

    private var settings: some View {
        Menu {
            Button(retrying ? "Refreshing…" : "Refresh now", action: refresh)
                .disabled(retrying)
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
            Text(store.transportMode)
                .help(store.diagnostics)
            if let error = store.lastEventError { Text("Event stream: \(error)") }
            Text("Herdr Bar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
            Button("Quit Herdr Bar") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
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
            HStack(spacing: 10) {
                StatusMark(status: available ? row.status : .unknown)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(row.workspace)
                            .font(Theme.body)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.tab)
                            .font(Theme.caption.monospaced())
                            .foregroundStyle(Theme.muted)
                            .truncationMode(.middle)
                            .frame(maxWidth: 110, alignment: .trailing)
                    }
                    HStack(spacing: 6) {
                        Text(row.kind).foregroundStyle(Theme.muted)
                        Spacer(minLength: 2)
                        Text(opening ? "Opening…" : row.status.label)
                            .foregroundStyle(available ? Theme.color(for: row.status) : Theme.muted)
                    }
                    .font(Theme.caption)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: Theme.rowHeight)
            .background(selected ? Theme.selected : hovered ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.focus)
                        .frame(width: 2, height: 24)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovered = $0 }
        .help("\(row.title)\n\(row.status.label) · \(row.detail)\n\(available ? "Open in Herdr" : "Last known status. Reconnect to open.")")
        .accessibilityLabel("\(row.workspace), tab \(row.tab), \(row.kind), \(available ? "" : "Last known status: ")\(row.status.label)")
        .accessibilityValue(opening ? "Opening" : selected ? "Selected" : "")
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
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(configuration.isPressed ? Theme.focus.opacity(0.12) : .clear)
            }
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.foreground : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(configuration.isPressed ? Theme.selected : Theme.hover,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .contentShape(Rectangle())
    }
}
