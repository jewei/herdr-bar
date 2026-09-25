import AppKit
import Combine
import HerdrBarCore
import ServiceManagement
import UserNotifications

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var rows: [AgentRow] = []
    @Published private(set) var connected = false
    @Published private(set) var loading = true
    @Published private(set) var connectionError: String?
    @Published var actionError: String?
    @Published var openingID: String?
    @Published var selectedID: String?
    @Published var order: AgentOrder {
        didSet { defaults.set(order.rawValue, forKey: "agentOrder") }
    }
    @Published var notificationsEnabled: Bool
    @Published private(set) var startsAtLogin = false
    @Published var terminalID: String {
        didSet { defaults.set(terminalID, forKey: "terminalID") }
    }

    private(set) var client: any HerdrService
    private let makeClient: (String) -> any HerdrService
    private let defaults: UserDefaults
    private var tracker = AttentionTracker()
    private var pollTask: Task<Void, Never>?
    private var refreshingGeneration: Int?
    private var hasSnapshot = false
    private var connectionGeneration = 0
    private var eventTask: Task<Void, Never>?
    private var eventPanes: Set<String>?
    private var eventStreamID = 0
    private var eventsLive = false
    private var eventSerial = 0
    private var eventRetry = ContinuousClock.now
    private var lastRefresh = ContinuousClock.now
    var onChange: (() -> Void)?
    var onOpen: (() -> Void)?
    var isPreview = false
    /// Brings the terminal to the front after Herdr focuses a pane.
    var activateTerminal: (_ preferred: String, _ socketPath: String) async throws -> Void = {
        try await TerminalActivator.activate(preferred: $0, socketPath: $1)
    }

    init(client: (any HerdrService)? = nil, defaults: UserDefaults = .standard,
         makeClient: @escaping (String) -> any HerdrService = { HerdrClient(socketPath: $0) }) {
        self.defaults = defaults
        self.makeClient = makeClient
        order = AgentOrder(rawValue: defaults.string(forKey: "agentOrder") ?? "") ?? .grouped
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        terminalID = defaults.string(forKey: "terminalID") ?? "auto"
        let path = defaults.string(forKey: "socketPath").flatMap { $0.isEmpty ? nil : $0 }
        self.client = client ?? makeClient(path ?? SocketLocation.resolve())
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    var sortedRows: [AgentRow] { order.sorted(rows) }
    var summary: AgentSummary { AgentSummary(rows: connected ? rows : []) }
    var socketPath: String { client.socketPath }
    var paletteHeight: CGFloat {
        let list = rows.isEmpty ? 144 : min(CGFloat(rows.count) * Theme.rowHeight + 8, Theme.maximumListHeight)
        return 40 + list + 42 + (actionError == nil ? 0 : 66)
    }

    func start() {
        guard pollTask == nil, !isPreview else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Events report status changes at once. Then a slow poll only updates titles.
                if let self, !eventsLive || .now - lastRefresh >= .seconds(15) { await refresh() }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        stopEvents()
    }

    func refresh() async {
        // A request for an old connection must not delay the first request for a new one.
        guard refreshingGeneration != connectionGeneration, !isPreview else { return }
        let generation = connectionGeneration
        refreshingGeneration = generation
        lastRefresh = .now
        defer { if refreshingGeneration == generation { refreshingGeneration = nil } }
        var discarded = 0
        do {
            while true {
                let serial = eventSerial
                let snapshot = try await client.snapshot()
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                // An event during the request makes this snapshot older than the tracker state.
                // An old snapshot can hide a completion for a moment, so request a new one.
                if serial != eventSerial, discarded < 3 {
                    discarded += 1
                    continue
                }
                apply(snapshot)
                if pollTask != nil { syncEvents() }
                if serial != eventSerial { Task { await refresh() } }
                return
            }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            stopEvents()
            let message = error.localizedDescription
            guard connected || loading || connectionError != message else { return }
            connected = false
            loading = false
            connectionError = message
            onChange?()
        }
    }

    func apply(_ snapshot: SessionSnapshot) {
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = tracker.update(snapshot)
        if hasSnapshot, notificationsEnabled, !isPreview {
            for row in updated where row.status.needsAttention {
                let old = previous[row.id]
                if old?.status != row.status || old?.info.terminalID != row.info.terminalID {
                    notify(row)
                }
            }
        }
        hasSnapshot = true
        // Each assignment to a published property updates SwiftUI, so assign only changed values.
        let rowsChanged = rows != updated
        let changed = rowsChanged || !connected || loading || connectionError != nil
        if rowsChanged { rows = updated }
        if !connected { connected = true }
        if loading { loading = false }
        if connectionError != nil { connectionError = nil }
        if !rows.contains(where: { $0.id == selectedID }) { selectInitialRow() }
        if changed { onChange?() }
    }

    func selectInitialRow() {
        let id = sortedRows.first(where: { $0.status.needsAttention })?.id
            ?? rows.first(where: { $0.info.focused })?.id ?? sortedRows.first?.id
        if selectedID != id { selectedID = id }
    }

    func moveSelection(by offset: Int) {
        let ordered = sortedRows
        guard !ordered.isEmpty else { return }
        let index = ordered.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : ordered.count)
        selectedID = ordered[max(0, min(ordered.count - 1, index + offset))].id
    }

    func openSelected() {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return }
        open(row)
    }

    func open(_ row: AgentRow) {
        guard connected, openingID == nil, !isPreview else { return }
        let generation = connectionGeneration
        let client = client
        openingID = row.id
        selectedID = row.id
        actionError = nil
        Task {
            // After a connection change, this action must not change the new connection's state.
            defer {
                if generation == connectionGeneration { openingID = nil; onChange?() }
            }
            do {
                try await client.focus(paneID: row.id)
                guard generation == connectionGeneration else { return }
                try await activateTerminal(terminalID, client.socketPath)
                // The agent can start new work while focus is pending. Keep a newer completion visible.
                if let index = rows.firstIndex(where: { $0.id == row.id }), rows[index].hasSameState(as: row) {
                    tracker.acknowledge(rows[index])
                    if rows[index].status == .done { rows[index].status = .idle }
                }
                onOpen?()
                await refresh()
            } catch {
                guard generation == connectionGeneration else { return }
                actionError = error.localizedDescription
            }
        }
    }

    func markDoneAsRead() {
        for index in rows.indices where rows[index].status == .done {
            tracker.acknowledge(rows[index])
            rows[index].status = .idle
        }
        onChange?()
    }

    func setNotifications(_ enabled: Bool) {
        if !enabled {
            notificationsEnabled = false
            defaults.set(false, forKey: "notificationsEnabled")
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = granted
                defaults.set(granted, forKey: "notificationsEnabled")
                if !granted {
                    actionError = "Allow Herdr Bar in System Settings > Notifications."
                }
            } catch { actionError = error.localizedDescription }
            onChange?()
        }
    }

    func setStartsAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startsAtLogin = SMAppService.mainApp.status == .enabled
            if enabled, !startsAtLogin {
                actionError = "Allow Herdr Bar in System Settings > General > Login Items."
            }
        } catch { actionError = error.localizedDescription }
        onChange?()
    }

    func setSocketPath(_ path: String) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (value as NSString).expandingTildeInPath
        defaults.set(expanded, forKey: "socketPath")
        connectionGeneration += 1
        stopEvents()
        client = makeClient(expanded.isEmpty ? SocketLocation.resolve() : expanded)
        tracker = AttentionTracker()
        rows = []
        hasSnapshot = false
        loading = true
        connected = false
        connectionError = nil
        actionError = nil
        openingID = nil
        if notificationsEnabled {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        onChange?()
        Task { await refresh() }
    }

    /// Keeps one event subscription for the agents in the current snapshot.
    /// If the subscription fails, polling continues and the store tries again later.
    private func syncEvents() {
        let panes = Set(rows.map(\.id))
        if let eventPanes {
            guard eventPanes != panes else { return }
        } else {
            guard ContinuousClock.now >= eventRetry else { return }
        }
        stopEvents()
        let id = eventStreamID
        let stream = client.events(paneIDs: panes.sorted())
        eventPanes = panes
        eventTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, id == eventStreamID else { return }
                    handle(event)
                }
            } catch {}
            guard let self, id == eventStreamID else { return }
            eventRetry = .now + .seconds(10)
            stopEvents()
        }
    }

    private func stopEvents() {
        eventStreamID += 1
        eventTask?.cancel()
        eventTask = nil
        eventPanes = nil
        eventsLive = false
    }

    private func handle(_ event: HerdrEvent) {
        switch event {
        case .subscribed: eventsLive = true
        case .agentStatus(let paneID, let status): tracker.observe(paneID: paneID, status: status)
        case .layoutChanged: break
        }
        eventSerial += 1
        Task { await refresh() }
    }

    /// Finds the agent that a notification describes. Returns nil for another connection or agent.
    func row(for target: NotificationTarget) -> AgentRow? {
        guard target.socketPath == socketPath else { return nil }
        return rows.first { $0.id == target.paneID && $0.info.terminalID == target.terminalID }
    }

    private func notify(_ row: AgentRow) {
        let content = UNMutableNotificationContent()
        content.title = row.status == .blocked ? "\(row.workspace) needs input" : "\(row.workspace) finished"
        content.body = "\(row.kind) · \(row.tab). Click to open the agent."
        content.sound = .default
        content.userInfo = NotificationTarget(row: row, socketPath: socketPath).userInfo
        let request = UNNotificationRequest(identifier: "agent-\(row.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Identifies the connection and the agent that sent a notification.
struct NotificationTarget: Sendable {
    let socketPath: String
    let paneID: String
    let terminalID: String

    init(row: AgentRow, socketPath: String) {
        self.socketPath = socketPath
        paneID = row.id
        terminalID = row.info.terminalID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let socketPath = userInfo["socketPath"] as? String,
              let paneID = userInfo["paneID"] as? String,
              let terminalID = userInfo["terminalID"] as? String else { return nil }
        self.socketPath = socketPath
        self.paneID = paneID
        self.terminalID = terminalID
    }

    var userInfo: [String: String] {
        ["socketPath": socketPath, "paneID": paneID, "terminalID": terminalID]
    }
}

@MainActor
enum TerminalActivator {
    static let choices: [(String, String)] = [
        ("auto", "Automatic"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.apple.Terminal", "Terminal"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("dev.warp.Warp-Stable", "Warp"),
    ]

    static func activate(preferred: String, socketPath: String) async throws {
        if preferred == "auto", let app = hostingApplication(socketPath: socketPath) {
            guard app.activate(options: []) else {
                throw HerdrError.server("Cannot bring the terminal to the front.")
            }
            return
        }
        // Without a known client, for example in tmux or over SSH, use the first running terminal.
        let candidates = preferred == "auto" ? choices.dropFirst().map(\.0) : [preferred]
        let running = NSWorkspace.shared.runningApplications
        for id in candidates {
            if let app = running.first(where: { $0.bundleIdentifier == id }) {
                guard app.activate(options: []) else {
                    throw HerdrError.server("Cannot bring the terminal to the front.")
                }
                return
            }
        }
        throw HerdrError.server("Open Herdr in your terminal, then select the agent again.")
    }

    /// Returns the application that runs a Herdr client for this socket.
    /// The first regular application among a client's parent processes is its terminal.
    static func hostingApplication(socketPath: String) -> NSRunningApplication? {
        for client in ClientProcess.find(socketPath: socketPath) {
            var pid = ClientProcess.parent(of: client)
            while let current = pid {
                if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                    return app
                }
                pid = ClientProcess.parent(of: current)
            }
        }
        return nil
    }
}
