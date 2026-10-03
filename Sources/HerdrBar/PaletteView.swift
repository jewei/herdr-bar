import SwiftUI
import HerdrBarCore

struct PaletteView: View {
    @ObservedObject var store: AgentStore
    var close: () -> Void
    var editConnection: () -> Void
    @FocusState private var hasKeyboardFocus: Bool
    @FocusState private var focusedRowID: String?
    @State private var retrying = false
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var sortHovered = false
    @State private var settingsHovered = false
    @State private var hasContentBelow = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.connected, !store.rows.isEmpty {
                PaletteOfflineNotice(retrying: retrying, connectionError: store.connectionError,
                                     retry: refresh, editConnection: editConnection)
            }
            if store.rows.isEmpty {
                PaletteEmptyState(loading: store.loading, connected: store.connected, retrying: retrying,
                                  connectionError: store.connectionError, retry: refresh,
                                  editConnection: editConnection)
            } else { agentList }
            if let error = store.actionError {
                PaletteErrorNotice(message: error, dismiss: store.dismissActionError)
            }
            footer
        }
        .frame(width: Theme.width)
        .background {
            Theme.background
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.white.opacity(contrast == .increased ? 0 : 0.025), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("HERDR BAR")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    Text("Agents").font(Theme.header)
                    if !store.rows.isEmpty {
                        Text("\(store.rows.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Theme.hover, in: Capsule())
                            .accessibilityLabel("\(store.rows.count) agents")
                    }
                }
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Sort agents", selection: $store.order) {
                    Text("Workspace").tag(AgentOrder.grouped)
                    Text("Needs attention first").tag(AgentOrder.attention)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text(store.order == .grouped ? "Workspace" : "Attention")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.muted)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(sortHovered ? Theme.selected : Theme.hover,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.muted.opacity(contrast == .increased ? 0.65 : 0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { sortHovered = $0 }
            .help("Sort by workspace or show agents that need attention first")
            .accessibilityLabel("Sort agents")
            .accessibilityValue(store.order == .grouped ? "Workspace" : "Needs attention first")
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.headerHeight)
        .overlay(alignment: .bottom) {
            Theme.divider.opacity(contrast == .increased ? 1 : 0.55)
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
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
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: AgentListBounds.self,
                                               value: geometry.frame(in: .named("agentList")))
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: store.listHeight)
            .coordinateSpace(name: "agentList")
            .onPreferenceChange(AgentListBounds.self) { bounds in
                hasContentBelow = bounds.maxY - Theme.listInset > store.listHeight + 0.5
            }
            .mask {
                let edge = min(0.2, 10 / store.listHeight)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: edge),
                    .init(color: .black, location: 1 - edge),
                    .init(color: hasContentBelow ? .clear : .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
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

    private var footer: some View {
        VStack(spacing: 0) {
            Theme.divider.opacity(contrast == .increased ? 1 : 0.55).frame(height: 1)
            HStack(spacing: 8) {
                Text(store.connected
                     ? (store.summary.description.isEmpty ? "No active agents" : store.summary.description)
                     : store.loading ? "Connecting to Herdr…" : "Automatic retry is on")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(store.connected ? store.summary.description : store.connectionError ?? "")
                settings
            }
            .frame(height: 36)
            HStack(spacing: 10) {
                if store.connected, !store.rows.isEmpty {
                    keyboardHint("↑↓", "Select")
                    keyboardHint("↵", store.openingID == nil ? "Open" : "Opening…")
                }
                keyboardHint("esc", store.actionError == nil ? "Close" : "Dismiss")
                Spacer(minLength: 4)
                if store.connected {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(store.eventsLive ? Theme.idle : Theme.muted)
                            .frame(width: 4, height: 4)
                        Text(store.transportMode)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .help(store.diagnostics)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Connection: \(store.diagnostics)")
                }
            }
            .frame(height: 24)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 20)
        .frame(height: Theme.footerHeight)
        .background(.black.opacity(0.08))
    }

    private func keyboardHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .frame(height: 17)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.muted.opacity(contrast == .increased ? 0.65 : 0.16), lineWidth: 0.5)
                }
            Text(label).font(.system(size: 10))
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
        .background(settingsHovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { settingsHovered = $0 }
        .help("Settings")
        .accessibilityLabel("Herdr Bar settings")
    }
}

private struct AgentListBounds: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
