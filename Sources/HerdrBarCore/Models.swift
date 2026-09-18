import Foundation

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle, working, blocked, done, unknown

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Running"
        case .blocked: "Needs input"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }

    public var needsAttention: Bool { self == .blocked || self == .done }

    public var priority: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .unknown: 3
        case .idle: 4
        }
    }
}

public struct AgentSessionInfo: Decodable, Sendable, Equatable {
    public let kind: String
    public let value: String
}

public struct AgentInfo: Decodable, Sendable, Equatable {
    public let paneID: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let agent: String?
    public let agentSession: AgentSessionInfo?
    public let displayAgent: String?
    public let agentStatus: AgentStatus
    public let focused: Bool
    public let cwd: String?
    public let title: String?
    public let terminalTitleStripped: String?
    public let stateChangeSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", terminalID = "terminal_id"
        case workspaceID = "workspace_id", tabID = "tab_id"
        case agent, displayAgent = "display_agent", agentStatus = "agent_status"
        case agentSession = "agent_session"
        case focused, cwd, title, terminalTitleStripped = "terminal_title_stripped"
        case stateChangeSeq = "state_change_seq"
    }
}

public struct WorkspaceInfo: Decodable, Sendable {
    public let workspaceID: String
    public let label: String
    public let number: Int

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", label, number
    }
}

public struct TabInfo: Decodable, Sendable {
    public let tabID: String
    public let label: String
    public let number: Int

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", label, number
    }
}

public struct SessionSnapshot: Decodable, Sendable {
    public let version: String
    public let agents: [AgentInfo]
    public let workspaces: [WorkspaceInfo]
    public let tabs: [TabInfo]
}

public struct AgentRow: Identifiable, Equatable, Sendable {
    public let info: AgentInfo
    public let workspace: String
    public let tab: String
    public let workspaceOrder: Int
    public let tabOrder: Int
    public var status: AgentStatus

    public var id: String { info.paneID }
    public var kind: String { info.displayAgent ?? info.agent ?? "agent" }
    public var title: String { "\(workspace) · \(tab)" }
    public var detail: String { info.title ?? info.terminalTitleStripped ?? info.cwd ?? title }

    public init(info: AgentInfo, workspace: String, tab: String,
                workspaceOrder: Int, tabOrder: Int, status: AgentStatus) {
        self.info = info
        self.workspace = workspace
        self.tab = tab
        self.workspaceOrder = workspaceOrder
        self.tabOrder = tabOrder
        self.status = status
    }
}

public enum AgentOrder: String, Sendable {
    case grouped, attention

    public func sorted(_ rows: [AgentRow]) -> [AgentRow] {
        rows.sorted { lhs, rhs in
            if self == .attention, lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            if lhs.workspaceOrder != rhs.workspaceOrder {
                return lhs.workspaceOrder < rhs.workspaceOrder
            }
            if lhs.tabOrder != rhs.tabOrder { return lhs.tabOrder < rhs.tabOrder }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }
}

public struct AgentSummary: Equatable, Sendable {
    public let running: Int
    public let blocked: Int
    public let done: Int
    public let idle: Int
    public let unknown: Int
    public var attention: Int { blocked + done }

    public init(rows: [AgentRow]) {
        running = rows.filter { $0.status == .working }.count
        blocked = rows.filter { $0.status == .blocked }.count
        done = rows.filter { $0.status == .done }.count
        idle = rows.filter { $0.status == .idle }.count
        unknown = rows.filter { $0.status == .unknown }.count
    }

    public var description: String {
        let parts = [(blocked, blocked == 1 ? "needs input" : "need input"), (done, "done"), (running, "running"),
                     (idle, "idle"), (unknown, "unknown")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}
