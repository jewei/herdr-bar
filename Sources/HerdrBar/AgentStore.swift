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
        didSet { UserDefaults.standard.set(order.rawValue, forKey: "agentOrder") }
    }
    @Published var notificationsEnabled: Bool
    @Published private(set) var startsAtLogin = false
    @Published var terminalID: String {
        didSet { UserDefaults.standard.set(terminalID, forKey: "terminalID") }
    }

    private(set) var client: HerdrClient
    private var tracker = AttentionTracker()
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    private var hasSnapshot = false
    private var connectionGeneration = 0
    var onChange: (() -> Void)?
    var onOpen: (() -> Void)?
    var isPreview = false

    init(client: HerdrClient? = nil) {
        let defaults = UserDefaults.standard
        order = AgentOrder(rawValue: defaults.string(forKey: "agentOrder") ?? "") ?? .grouped
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        terminalID = defaults.string(forKey: "terminalID") ?? "auto"
        let path = defaults.string(forKey: "socketPath").flatMap { $0.isEmpty ? nil : $0 }
        self.client = client ?? HerdrClient(socketPath: path ?? SocketLocation.resolve())
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
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh() async {
        guard !refreshing, !isPreview else { return }
        refreshing = true
        let generation = connectionGeneration
        defer { refreshing = false }
        do {
            let snapshot = try await client.snapshot()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            apply(snapshot)
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            connected = false
            loading = false
            connectionError = error.localizedDescription
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
        rows = updated
        hasSnapshot = true
        connected = true
        loading = false
        connectionError = nil
        if !rows.contains(where: { $0.id == selectedID }) { selectInitialRow() }
        onChange?()
    }

    func selectInitialRow() {
        selectedID = sortedRows.first(where: { $0.status.needsAttention })?.id
            ?? rows.first(where: { $0.info.focused })?.id ?? sortedRows.first?.id
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
        openingID = row.id
        selectedID = row.id
        actionError = nil
        Task {
            defer { openingID = nil; onChange?() }
            do {
                try await client.focus(paneID: row.id)
                try await TerminalActivator.activate(preferred: terminalID)
                tracker.acknowledge(row)
                if let index = rows.firstIndex(where: { $0.id == row.id }), rows[index].status == .done {
                    rows[index].status = .idle
                }
                onOpen?()
                await refresh()
            } catch {
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
            UserDefaults.standard.set(false, forKey: "notificationsEnabled")
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = granted
                UserDefaults.standard.set(granted, forKey: "notificationsEnabled")
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
        UserDefaults.standard.set(expanded, forKey: "socketPath")
        connectionGeneration += 1
        client = HerdrClient(socketPath: expanded.isEmpty ? SocketLocation.resolve() : expanded)
        tracker = AttentionTracker()
        rows = []
        hasSnapshot = false
        loading = true
        connected = false
        connectionError = nil
        actionError = nil
        onChange?()
        Task { await refresh() }
    }

    private func notify(_ row: AgentRow) {
        let content = UNMutableNotificationContent()
        content.title = row.status == .blocked ? "\(row.workspace) needs input" : "\(row.workspace) finished"
        content.body = "\(row.kind) · \(row.tab). Click to open the agent."
        content.sound = .default
        content.userInfo = ["paneID": row.id]
        let request = UNNotificationRequest(identifier: "agent-\(row.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
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

    static func activate(preferred: String) async throws {
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
}
