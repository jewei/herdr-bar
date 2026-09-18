import Foundation

/// Remembers work completed while this app is running. Herdr also reports its own `done` state.
public struct AttentionTracker: Sendable {
    private var previous: [String: AgentInfo] = [:]
    private var completed: Set<String> = []
    private var acknowledged: [String: UInt64] = [:]

    public init() {}

    public mutating func acknowledge(_ row: AgentRow) {
        completed.remove(row.id)
        if row.info.agentStatus == .done {
            acknowledged[row.id] = row.info.stateChangeSeq ?? 0
        }
    }

    public mutating func update(_ snapshot: SessionSnapshot) -> [AgentRow] {
        let liveIDs = Set(snapshot.agents.map(\.paneID))
        completed.formIntersection(liveIDs)
        acknowledged = acknowledged.filter { liveIDs.contains($0.key) }
        let workspaces = Dictionary(snapshot.workspaces.map { ($0.workspaceID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary(snapshot.tabs.map { ($0.tabID, $0) },
                              uniquingKeysWith: { first, _ in first })

        let rows = snapshot.agents.map { info in
            let old = previous[info.paneID]
            // A pane ID can be reused after a server restart or an agent replacement.
            let sameAgent = old?.terminalID == info.terminalID && old?.agent == info.agent
                && old?.agentSession == info.agentSession
                && (info.stateChangeSeq ?? 0) >= (old?.stateChangeSeq ?? 0)
            if !sameAgent {
                completed.remove(info.paneID)
                acknowledged.removeValue(forKey: info.paneID)
            }
            if sameAgent, old?.agentStatus == .working, info.agentStatus == .idle {
                completed.insert(info.paneID)
            }
            if info.agentStatus == .working || info.agentStatus == .blocked || info.agentStatus == .unknown {
                completed.remove(info.paneID)
                acknowledged.removeValue(forKey: info.paneID)
            }
            var status = info.agentStatus
            if status == .idle, completed.contains(info.paneID) { status = .done }
            if status == .done, acknowledged[info.paneID] == (info.stateChangeSeq ?? 0) {
                status = .idle
            }
            let workspace = workspaces[info.workspaceID]
            let tab = tabs[info.tabID]
            let fallback = info.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            return AgentRow(info: info,
                            workspace: workspace?.label ?? fallback ?? info.workspaceID,
                            tab: tab?.label ?? info.tabID,
                            workspaceOrder: workspace?.number ?? Int.max,
                            tabOrder: tab?.number ?? Int.max,
                            status: status)
        }
        previous = Dictionary(snapshot.agents.map { ($0.paneID, $0) },
                              uniquingKeysWith: { first, _ in first })
        return rows
    }
}
