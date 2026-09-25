import Foundation

/// Local unread state. Both explicit `done` and observed working → idle completions
/// remain unread until opened here, superseded by new work, or the agent disappears.
public struct AttentionTracker: Sendable {
    private struct State: Sendable {
        var status: AgentStatus?
        var sequence: UInt64?
        var unread = false
        // Acknowledgement must not erase evidence that a later explicit `done`
        // merely confirms the completion already inferred from working → idle.
        var inferredCompletion = false
        var generation: UInt64 = 0
        var observedTransition = false
    }

    private var states: [AgentIdentity: State] = [:]
    private var addresses: [String: AgentIdentity] = [:]
    private var nextGeneration: UInt64 = 0

    public init() {}

    /// Returns false if newer work arrived while the action was pending.
    @discardableResult
    public mutating func acknowledge(_ row: AgentRow) -> Bool {
        guard var state = states[row.identity], state.generation == row.stateGeneration,
              rendered(state) == row.status else { return false }
        if row.status == .done { state.unread = false }
        states[row.identity] = state
        return true
    }

    public mutating func observe(paneID: String, status: AgentStatus) {
        guard let identity = addresses[paneID], var state = states[identity] else { return }
        if state.status != status { state.observedTransition = true }
        record(&state, status: status)
        states[identity] = state
    }

    /// A gap removes our evidence that intervening sequence changes were observed.
    /// Conservatively treat a later sequenced `done` as new; a duplicate alert is
    /// preferable to silently acknowledging potentially unseen work.
    public mutating func markEventGap() {
        for identity in states.keys { states[identity]?.observedTransition = false }
    }

    /// Status events received during a snapshot request are newer evidence than that
    /// snapshot. Install metadata, but do not replay old statuses over those agents.
    /// No unbounded event log or duplicate replay is needed: observe already folded
    /// every transition into the local occurrence state.
    public mutating func update(_ snapshot: SessionSnapshot,
                                preservingObservedStateFor panes: Set<String> = []) -> [AgentRow] {
        let preserved = Set(panes.compactMap { addresses[$0] })
        let live = Set(snapshot.agents.map { AgentIdentity($0) })
        states = states.filter { live.contains($0.key) }
        addresses = Dictionary(snapshot.agents.map { ($0.paneID, AgentIdentity($0)) },
                               uniquingKeysWith: { first, _ in first })
        let workspaces = Dictionary(snapshot.workspaces.map { ($0.workspaceID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary(snapshot.tabs.map { ($0.tabID, $0) },
                              uniquingKeysWith: { first, _ in first })

        return snapshot.agents.map { info in
            let identity = AgentIdentity(info)
            var state = states[identity] ?? State()
            if !preserved.contains(identity) || state.status == nil {
                // A sequence reset indicates a new server/occupant generation. Missing
                // sequences are not evidence of a reset.
                if let old = state.sequence, let new = info.stateChangeSeq, new < old {
                    state = State()
                }
                let unseenOccurrence = !state.observedTransition
                    && (info.agentStatus == .done || (info.agentStatus == .blocked && state.status == .blocked))
                    && info.stateChangeSeq != nil && state.sequence != nil
                    && info.stateChangeSeq != state.sequence
                record(&state, status: info.agentStatus, newOccurrence: unseenOccurrence)
                if let sequence = info.stateChangeSeq {
                    state.sequence = sequence
                    state.observedTransition = false
                }
            }
            states[identity] = state
            let workspace = workspaces[info.workspaceID]
            let tab = tabs[info.tabID]
            let fallback = info.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            return AgentRow(info: info,
                            workspace: workspace?.label ?? fallback ?? info.workspaceID,
                            tab: tab?.label ?? info.tabID,
                            workspaceOrder: workspace?.number ?? Int.max,
                            tabOrder: tab?.number ?? Int.max,
                            status: rendered(state), stateGeneration: state.generation)
        }
    }

    /// Refresh presentation after an event or acknowledgement without reapplying a snapshot.
    public func project(_ rows: [AgentRow]) -> [AgentRow] {
        rows.map { row in
            guard let state = states[row.identity] else { return row }
            return AgentRow(info: row.info, workspace: row.workspace, tab: row.tab,
                            workspaceOrder: row.workspaceOrder, tabOrder: row.tabOrder,
                            status: rendered(state), stateGeneration: state.generation)
        }
    }

    private func rendered(_ state: State) -> AgentStatus {
        switch state.status {
        case .idle, .done: state.unread ? .done : .idle
        default: state.status ?? .unknown
        }
    }

    private mutating func record(_ state: inout State, status: AgentStatus, newOccurrence: Bool = false) {
        let old = state.status
        var changed = old == nil
        switch status {
        case .working, .blocked, .unknown:
            changed = changed || old != status || newOccurrence
            state.unread = false
            state.inferredCompletion = false
        case .idle:
            if old == .working {
                changed = true
                state.unread = true
                state.inferredCompletion = true
            }
        case .done:
            // An inferred completion subsequently reported explicitly is still the
            // same occurrence. A changed server sequence can reveal unseen work.
            if newOccurrence || (old != .done && !(old == .idle && state.inferredCompletion)) {
                changed = true
                state.unread = true
            }
            state.inferredCompletion = false
        }
        if changed {
            nextGeneration += 1
            state.generation = nextGeneration
        }
        state.status = status
    }
}
