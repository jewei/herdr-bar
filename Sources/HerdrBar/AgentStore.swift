import AppKit
import Combine
import HerdrBarCore
import ServiceManagement
import UserNotifications
import os

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var rows: [AgentRow] = []
    @Published private(set) var connected = false
    @Published private(set) var loading = true
    @Published private(set) var connectionError: String?
    @Published private(set) var eventsLive = false
    @Published private(set) var lastEventError: String?
    @Published private(set) var lastSuccessfulRefresh: Date?
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
    private var pollSleepTask: Task<Void, any Error>?
    private var openTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var refreshNeeded = false
    private var stopped = false
    private var lastNotified: [AgentIdentity: UInt64] = [:]
    nonisolated private static let logger = Logger(subsystem: "dev.jewei.herdr-bar", category: "connection")
    /// Injectable so notification eligibility can be tested without macOS services.
    var deliverNotification: @MainActor (AgentRow, String, String) -> Void = AgentStore.sendNotification
    private(set) var notificationScope = UUID().uuidString
    private var hasSnapshot = false
    private var connectionGeneration = 0
    private var eventTask: Task<Void, Never>?
    private var eventPanes: Set<String>?
    private var eventStreamID = 0
    private var eventSerial = 0
    private var layoutSerial = 0
    private var topologyUncertain = false
    private var pendingEventPanes: Set<String> = []
    private let eventRetryDelay: Duration
    private var eventRetry = ContinuousClock.now
    private var lastRefresh = ContinuousClock.now
    private var offlineRetryDelay: Duration = .seconds(2)
    /// Tests can observe deadlines without waiting for the production intervals.
    var sleepForPolling: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var onChange: (() -> Void)?
    var onOpen: (() -> Void)?
    var isPreview = false
    /// Brings the terminal to the front after Herdr focuses a pane.
    var activateTerminal: (_ preferred: String, _ socketPath: String) async throws -> Void = {
        try await TerminalActivator.activate(preferred: $0, socketPath: $1)
    }

    init(client: (any HerdrService)? = nil, defaults: UserDefaults = .standard,
         eventRetryDelay: Duration = .seconds(10),
         makeClient: @escaping (String) -> any HerdrService = { HerdrClient(socketPath: $0) }) {
        self.defaults = defaults
        self.makeClient = makeClient
        self.eventRetryDelay = eventRetryDelay
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
    var transportMode: String { !connected ? "Disconnected" : eventsLive ? "Live" : "Polling" }
    var diagnostics: String {
        var text = transportMode
        if let date = lastSuccessfulRefresh { text += " · refreshed \(date.formatted(date: .omitted, time: .standard))" }
        if let error = lastEventError { text += "\nEvent stream: \(error)" }
        return text
    }
    var paletteHeight: CGFloat {
        let list = rows.isEmpty ? 144 : min(CGFloat(rows.count) * Theme.rowHeight + 8, Theme.maximumListHeight)
        return 40 + list + 42 + (actionError == nil ? 0 : 66)
    }

    func start() {
        guard pollTask == nil, !isPreview else { return }
        stopped = false
        eventRetry = .now
        pollTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if first || nextPollDelay <= .zero { await refresh() }
                first = false
                guard !Task.isCancelled else { return }
                let delay = nextPollDelay
                let sleep = sleepForPolling
                let sleeper = Task { try await sleep(delay) }
                pollSleepTask = sleeper
                do { try await sleeper.value }
                catch { if Task.isCancelled { return } }
                guard !Task.isCancelled else { return }
                pollSleepTask = nil
            }
        }
    }

    private var nextPollDelay: Duration {
        let interval: Duration = eventsLive ? .seconds(15) : connected ? .seconds(2) : offlineRetryDelay
        return max(.zero, (lastRefresh + interval) - .now)
    }

    func stop() {
        stopped = true
        connectionGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        pollSleepTask?.cancel()
        pollSleepTask = nil
        openTask?.cancel()
        openTask = nil
        openingID = nil
        refreshTask?.cancel()
        refreshTask = nil
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        refreshNeeded = false
        stopEvents()
    }

    func refresh() async {
        guard !stopped, !isPreview else { return }
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        if let refreshTask { await refreshTask.value; return }
        refreshNeeded = false
        let generation = connectionGeneration
        let task = Task { [weak self] in
            guard let self, generation == connectionGeneration, !stopped, !Task.isCancelled else { return }
            await performRefresh(generation: generation)
            guard generation == connectionGeneration else { return }
            lastRefresh = .now
            refreshTask = nil
            pollSleepTask?.cancel()
            if refreshNeeded { scheduleRefresh() }
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(generation: Int) async {
        lastRefresh = .now
        var discarded = 0
        do {
            while true {
                let serial = eventSerial
                let layout = layoutSerial
                pendingEventPanes.removeAll(keepingCapacity: true)
                let snapshot = try await client.snapshot()
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                // A topology change makes even the snapshot's membership unsafe. Never
                // install it, even after repeated invalidations; yield and retry instead.
                if layout != layoutSerial {
                    discarded += 1
                    if discarded < 3 { continue }
                    scheduleRefresh()
                    return
                }
                // A reply and an event stream have no shared watermark. The tracker
                // validates attention and retains provisional activity across an overlap.
                apply(snapshot, preservingObservedStateFor: pendingEventPanes)
                lastSuccessfulRefresh = .now
                if pollTask != nil { syncEvents() }
                if serial != eventSerial { scheduleRefresh() }
                return
            }
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            stopEvents()
            offlineRetryDelay = connected || loading ? .seconds(2) : min(offlineRetryDelay * 2, .seconds(30))
            let message = error.localizedDescription
            guard connected || loading || connectionError != message else { return }
            connected = false
            loading = false
            connectionError = message
            onChange?()
        }
    }

    func apply(_ snapshot: SessionSnapshot, preservingObservedStateFor panes: Set<String> = []) {
        let updated = tracker.update(snapshot, preservingObservedStateFor: panes)
        offlineRetryDelay = .seconds(2)
        topologyUncertain = false
        let live = Set(updated.map(\.identity))
        lastNotified = lastNotified.filter { live.contains($0.key) }
        emitNotifications(for: tracker.committedRows(updated))
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
        guard connected, openingID == nil, !stopped, !isPreview else { return }
        guard !topologyUncertain, rows.contains(where: { $0.id == row.id && $0.identity == row.identity }) else {
            actionError = "The agent layout changed. Select the agent again after it refreshes."
            onChange?()
            return
        }
        let generation = connectionGeneration
        let client = client
        openingID = row.id
        selectedID = row.id
        actionError = nil
        openTask = Task {
            // After a connection change, this action must not change the new connection's state.
            defer {
                if generation == connectionGeneration { openingID = nil; openTask = nil; onChange?() }
            }
            do {
                try await client.focus(paneID: row.id)
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                try await activateTerminal(terminalID, client.socketPath)
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                // Compare the occurrence, not its current public address or a nullable
                // server sequence. The tracker also sees events not yet snapshotted.
                if !topologyUncertain,
                   let current = rows.first(where: { $0.id == row.id }), current.identity == row.identity {
                    if tracker.acknowledge(row) { rows = tracker.project(rows) }
                    onOpen?()
                } else {
                    actionError = "The agent moved while opening. Select it again."
                }
                await refresh()
            } catch {
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                if case HerdrError.invalidResponse = error {
                    actionError = "Cannot confirm the agent opened. Unexpected Herdr reply. Open it in your terminal."
                } else {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    func dismissActionError() {
        guard actionError != nil else { return }
        actionError = nil
        onChange?()
    }

    func markDoneAsRead() {
        for row in rows where row.status == .done { tracker.acknowledge(row) }
        rows = tracker.project(rows)
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
        openTask?.cancel()
        openTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        refreshNeeded = false
        stopEvents()
        lastNotified = [:]
        notificationScope = UUID().uuidString
        topologyUncertain = false
        eventRetry = .now
        lastEventError = nil
        lastSuccessfulRefresh = nil
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
        offlineRetryDelay = .seconds(2)
        scheduleRefresh(delay: .zero)
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
            } catch {
                guard let self, id == eventStreamID else { return }
                lastEventError = error.localizedDescription
                Self.logger.warning("Event stream failed; falling back to polling.")
            }
            guard let self, id == eventStreamID else { return }
            if lastEventError == nil { lastEventError = "The event stream closed." }
            eventRetry = .now + eventRetryDelay
            stopEvents()
            scheduleRefresh()
        }
    }

    private func stopEvents() {
        eventStreamID += 1
        eventTask?.cancel()
        eventTask = nil
        eventPanes = nil
        eventsLive = false
        pollSleepTask?.cancel()
        tracker.markEventGap()
    }

    private func handle(_ event: HerdrEvent) {
        switch event {
        case .subscribed:
            eventsLive = true
            lastEventError = nil
            pollSleepTask?.cancel()
        case .agentStatus(let paneID, let status):
            if !topologyUncertain, rows.contains(where: { $0.id == paneID }) {
                pendingEventPanes.insert(paneID)
                tracker.observe(paneID: paneID, status: status)
                let updated = tracker.project(rows)
                if rows != updated { rows = updated; onChange?() }
            } else if !topologyUncertain {
                // A public address may now belong to another terminal. Do not
                // attribute unversioned events until a fresh topology is installed.
                topologyUncertain = true
                tracker.invalidateTopology()
                rows = tracker.project(rows)
                onChange?()
                layoutSerial += 1
            }
            // Once quarantined, status traffic is not further evidence of a
            // topology change: let the recovery snapshot finish, even under load.
        case .layoutChanged:
            topologyUncertain = true
            tracker.invalidateTopology()
            rows = tracker.project(rows)
            onChange?()
            layoutSerial += 1
        case .ignored:
            return
        }
        eventSerial += 1
        scheduleRefresh()
    }

    /// One coalesced follow-up, rather than a task per event or a busy retry loop.
    private func scheduleRefresh(delay: Duration = .milliseconds(100)) {
        guard !stopped else { return }
        refreshNeeded = true
        guard refreshTask == nil, scheduledRefreshTask == nil else { return }
        let generation = connectionGeneration
        scheduledRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, generation == connectionGeneration else { return }
            scheduledRefreshTask = nil
            await refresh()
        }
    }

    private func emitNotifications(for updated: [AgentRow]) {
        for row in updated where row.status.needsAttention {
            let isNew = lastNotified[row.identity] != row.stateGeneration
            // Baseline startup/disabled notifications too; enabling is not a replay.
            lastNotified[row.identity] = row.stateGeneration
            if isNew, hasSnapshot, notificationsEnabled, !isPreview {
                deliverNotification(row, socketPath, notificationScope)
            }
        }
    }

    /// Finds the agent that a notification describes. Returns nil for another connection or agent.
    func row(for target: NotificationTarget) -> AgentRow? {
        guard target.socketPath == socketPath, target.scope == notificationScope else { return nil }
        return rows.first {
            $0.info.terminalID == target.terminalID && $0.info.agent == target.agent
                && $0.info.agentSession == target.session && $0.stateGeneration == target.generation
        }
    }

    private static func sendNotification(_ row: AgentRow, socketPath: String, scope: String) {
        let content = UNMutableNotificationContent()
        content.title = row.status == .blocked ? "\(row.workspace) needs input" : "\(row.workspace) finished"
        content.body = "\(row.kind) · \(row.tab). Click to open the agent."
        content.sound = .default
        content.userInfo = NotificationTarget(row: row, socketPath: socketPath, scope: scope).userInfo
        let request = UNNotificationRequest(identifier: "agent-\(row.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil { logger.warning("Notification delivery failed.") }
        }
    }
}

/// Identifies the connection and the agent that sent a notification.
struct NotificationTarget: Sendable {
    let socketPath: String
    let paneID: String
    let terminalID: String
    let agent: String?
    let session: AgentSessionInfo?
    let generation: UInt64
    let scope: String

    init(row: AgentRow, socketPath: String, scope: String) {
        self.socketPath = socketPath
        paneID = row.id
        terminalID = row.info.terminalID
        agent = row.info.agent
        session = row.info.agentSession
        generation = row.stateGeneration
        self.scope = scope
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let socketPath = userInfo["socketPath"] as? String,
              let paneID = userInfo["paneID"] as? String,
              let terminalID = userInfo["terminalID"] as? String,
              let scope = userInfo["scope"] as? String,
              let value = userInfo["generation"] as? String,
              let generation = UInt64(value) else { return nil }
        self.socketPath = socketPath
        self.paneID = paneID
        self.terminalID = terminalID
        self.scope = scope
        self.generation = generation
        agent = userInfo["agent"] as? String
        if let kind = userInfo["sessionKind"] as? String, let value = userInfo["sessionValue"] as? String {
            session = AgentSessionInfo(kind: kind, value: value)
        } else { session = nil }
    }

    var userInfo: [String: String] {
        var values = ["socketPath": socketPath, "paneID": paneID, "terminalID": terminalID,
                      "scope": scope, "generation": String(generation)]
        values["agent"] = agent
        values["sessionKind"] = session?.kind
        values["sessionValue"] = session?.value
        return values
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
        try Task.checkCancellation()
        if preferred == "auto", let app = await hostingApplication(socketPath: socketPath) {
            try Task.checkCancellation()
            guard app.activate(options: []) else {
                throw HerdrError.server("Cannot bring the terminal to the front.")
            }
            return
        }
        try Task.checkCancellation()
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
    static func hostingApplication(socketPath: String) async -> NSRunningApplication? {
        let ancestors = await ClientProcess.applicationAncestors(socketPath: socketPath)
        guard !Task.isCancelled else { return nil }
        for pid in ancestors {
            if let app = NSRunningApplication(processIdentifier: pid),
               !app.isTerminated, app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }
}
