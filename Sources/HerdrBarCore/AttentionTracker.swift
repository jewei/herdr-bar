import Foundation

/// Identity-bound snapshot state and local unread attention. Address-only events
/// are provisional until a snapshot supplies matching identity and sequence evidence.
public struct AttentionTracker: Sendable {
    private struct State: Sendable {
        var status: AgentStatus?
        var sequence: UInt64?
        var unread = false
        var inferredCompletion = false
        var generation: UInt64 = 0
        var observedTransition = false
    }

    private struct Observation: Sendable {
        let paneID: String
        let baselineSequence: UInt64?
        var state: State
    }

    private var states: [AgentIdentity: State] = [:]
    private var observations: [AgentIdentity: Observation] = [:]
    private var addresses: [String: AgentIdentity] = [:]
    private var nextGeneration: UInt64 = 0

    public init() {}

    /// Pending address-only work cannot authorize an acknowledgement or be erased by one.
    @discardableResult
    public mutating func acknowledge(_ row: AgentRow) -> Bool {
        guard var state = states[row.identity], state.generation == row.stateGeneration,
              rendered(state) == row.status,
              observations[row.identity]?.state.observedTransition != true else { return false }
        if row.status == .done { state.unread = false }
        states[row.identity] = state
        return true
    }

    public mutating func observe(paneID: String, status: AgentStatus) {
        guard let identity = addresses[paneID], let committed = states[identity] else { return }
        var observation = observations[identity]
            ?? Observation(paneID: paneID, baselineSequence: committed.sequence, state: committed)
        if observation.state.status != status { observation.state.observedTransition = true }
        record(&observation.state, status: status)
        observations[identity] = observation
    }

    /// A layout notification can arrive after status events for a new occupant.
    /// Discard that provisional evidence, never an established unread occurrence.
    public mutating func invalidateTopology() {
        observations.removeAll(keepingCapacity: true)
        addresses.removeAll(keepingCapacity: true)
    }

    /// Lost transport history cannot prove an event-only cycle. Recovery uses
    /// committed snapshots; an advanced explicit attention sequence can notify again.
    public mutating func markEventGap() {
        observations.removeAll(keepingCapacity: true)
    }

    /// Snapshot replies and subscriptions have no shared ordering watermark.
    /// An event-only completion needs an unchanged mapping, a newer sequence, and
    /// a matching final status. An overlap can retain evidence for a later request,
    /// but cannot turn provisional attention into a committed effect by itself.
    public mutating func update(_ snapshot: SessionSnapshot,
                                preservingObservedStateFor panes: Set<String> = []) -> [AgentRow] {
        let previousAddresses = addresses
        let live = Set(snapshot.agents.map { AgentIdentity($0) })
        states = states.filter { live.contains($0.key) }
        observations = observations.filter { live.contains($0.key) }
        addresses = Dictionary(snapshot.agents.map { ($0.paneID, AgentIdentity($0)) },
                               uniquingKeysWith: { first, _ in first })
        let workspaces = Dictionary(snapshot.workspaces.map { ($0.workspaceID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary(snapshot.tabs.map { ($0.tabID, $0) },
                              uniquingKeysWith: { first, _ in first })

        let rows = snapshot.agents.map { info in
            let identity = AgentIdentity(info)
            var state = states[identity] ?? State()
            let oldSequence = state.sequence
            var observation = observations[identity]
            // A sequence reset or changed routing map invalidates provisional history.
            if let old = oldSequence, let new = info.stateChangeSeq, new < old {
                state = State()
                observation = nil
            }
            if observation?.paneID != info.paneID || previousAddresses[info.paneID] != identity {
                observation = nil
            }
            let advancesSequence = info.stateChangeSeq.map { new in oldSequence.map { new > $0 } ?? false } ?? false
            let confirmsObservation = observation.map { pending in
                pending.state.observedTransition && advancesSequence
                    && pending.baselineSequence.map { info.stateChangeSeq! > $0 } == true
                    && pending.state.status == info.agentStatus
            } ?? false
            if confirmsObservation, let pending = observation {
                let previousGeneration = state.generation
                state = pending.state
                if state.generation < previousGeneration {
                    nextGeneration += 1
                    state.generation = nextGeneration
                }
                state.observedTransition = false
                observation = nil
            } else {
                let unseenOccurrence = advancesSequence
                    && (info.agentStatus == .done || (info.agentStatus == .blocked && state.status == .blocked))
                // Equal sequence snapshots can change done to idle when another client
                // marks the server state seen. They cannot prove a new work cycle.
                let inferCompletion = oldSequence == nil || info.stateChangeSeq == nil || advancesSequence
                record(&state, status: info.agentStatus, newOccurrence: unseenOccurrence,
                       inferCompletion: inferCompletion)
                // Running can be an intermediate snapshot of the pending cycle.
                // A newer incompatible blocked/unknown/idle snapshot breaks that
                // evidence; retaining it could invent a later blocked → idle completion.
                if !panes.contains(info.paneID)
                    || (advancesSequence && info.agentStatus != .working
                        && observation?.state.status != info.agentStatus) {
                    observation = nil
                }
            }
            if let sequence = info.stateChangeSeq { state.sequence = sequence }
            states[identity] = state
            observations[identity] = observation
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
        return project(rows)
    }

    /// Only these rows can cause attention effects. Provisional activity does not
    /// suppress or replace an established unread occurrence in the committed state.
    public func committedRows(_ rows: [AgentRow]) -> [AgentRow] {
        rows.map { row in
            guard let state = states[row.identity] else { return row }
            return replacingState(in: row, status: rendered(state), generation: state.generation)
        }
    }

    /// Running/unknown activity can appear immediately. Attention waits for identity-
    /// bound snapshot evidence, so a late layout event cannot leave a false notice.
    public func project(_ rows: [AgentRow]) -> [AgentRow] {
        committedRows(rows).map { row in
            guard let pending = observations[row.identity],
                  pending.state.status == .working || pending.state.status == .unknown else { return row }
            return replacingState(in: row, status: pending.state.status!, generation: pending.state.generation)
        }
    }

    private func replacingState(in row: AgentRow, status: AgentStatus, generation: UInt64) -> AgentRow {
        AgentRow(info: row.info, workspace: row.workspace, tab: row.tab,
                 workspaceOrder: row.workspaceOrder, tabOrder: row.tabOrder,
                 status: status, stateGeneration: generation)
    }

    private func rendered(_ state: State) -> AgentStatus {
        switch state.status {
        case .idle, .done: state.unread ? .done : .idle
        default: state.status ?? .unknown
        }
    }

    private mutating func record(_ state: inout State, status: AgentStatus, newOccurrence: Bool = false,
                                 inferCompletion: Bool = true) {
        let old = state.status
        var changed = old == nil
        switch status {
        case .working, .blocked, .unknown:
            changed = changed || old != status || newOccurrence
            state.unread = false
            state.inferredCompletion = false
        case .idle:
            if old == .working && inferCompletion {
                changed = true
                state.unread = true
                state.inferredCompletion = true
            }
        case .done:
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
