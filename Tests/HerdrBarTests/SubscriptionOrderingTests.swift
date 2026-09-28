import Foundation
import HerdrBarCore
import os
import Testing
@testable import HerdrBar

/// Models the independent history cursors used by Herdr 0.9.1 subscriptions.
/// Snapshot replies can advance independently of either cursor. This tests the
/// store/reducer contract; the socket tests separately check wire decoding.
@MainActor
@Test(arguments: [false, true])
func independentSubscriptionsCannotAssignMovedAgentsWork(snapshotBeforeLayout: Bool) async throws {
    let initial = try cursorSnapshot(moved: false)
    let recovered = try cursorSnapshot(moved: true)
    let service = CursorService(initial)
    let suite = "herdr-cursor-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let store = AgentStore(client: service, defaults: defaults)
    defer { store.stop(); service.close(); defaults.removePersistentDomain(forName: suite) }
    var notices: [String] = []
    store.notificationsEnabled = true
    store.deliverNotification = { row, _, _ in notices.append(row.info.terminalID) }
    store.start()
    try await cursorWait { store.eventsLive }

    // Server chronology is move, then replacement starts work. The status
    // selector skips the move while the layout selector still has its own cursor.
    service.beginHoldingSnapshots(recovered)
    service.append(.layoutChanged)
    service.append(.agentStatus(paneID: "w1:p1", status: .working))
    #expect(service.pollStatus() == .agentStatus(paneID: "w1:p1", status: .working))
    try await cursorWait { store.rows.first?.status == .working }
    try await cursorWait { service.pendingSnapshots > 0 }

    if snapshotBeforeLayout {
        service.answerSnapshot()
        try await cursorWait { store.rows.first?.id == "w2:p1" }
        #expect(store.rows.first?.status == .idle)
    }
    // Poll the original layout subscription. If the snapshot already replaced
    // the stream, its late frame must not enter the replacement subscription.
    #expect(service.pollLayout() == .layoutChanged)
    // Layout invalidation must remove any unvalidated activity immediately.
    try await cursorWait { store.rows.first?.status == .idle }

    // Release all held replies and use current server state from now on. The
    // first reply may be discarded due to layout invalidation; a new one follows.
    service.resumeSnapshots()
    await store.refresh()
    try await cursorWait { store.rows.first?.id == "w2:p1" && store.connected }
    #expect(store.rows.first?.status == .idle)
    await store.refresh()
    #expect(store.rows.first?.status == .idle)
    #expect(notices.isEmpty)
}

private func cursorSnapshot(moved: Bool) throws -> SessionSnapshot {
    var agents: [[String: Any]] = [[
        "pane_id": moved ? "w2:p1" : "w1:p1", "terminal_id": "original",
        "workspace_id": moved ? "w2" : "w1", "tab_id": moved ? "w2:t1" : "w1:t1",
        "agent": "codex", "agent_session": ["kind": "id", "value": "original"],
        "agent_status": "idle", "state_change_seq": 1, "focused": false,
    ]]
    if moved {
        agents.append([
            "pane_id": "w1:p1", "terminal_id": "replacement", "workspace_id": "w1", "tab_id": "w1:t1",
            "agent": "codex", "agent_session": ["kind": "id", "value": "replacement"],
            "agent_status": "working", "state_change_seq": 2, "focused": false,
        ])
    }
    return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: [
        "version": "cursor-model", "agents": agents, "workspaces": [], "tabs": [],
    ]))
}

@MainActor
private func cursorWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "The cursor-model condition did not become true")
        try await Task.sleep(for: .milliseconds(2))
    }
}

private final class CursorService: HerdrService {
    private struct Cursor {
        var statusPosition: Int
        var layoutPosition: Int
        let stream: AsyncThrowingStream<HerdrEvent, any Error>.Continuation
    }
    private struct State {
        var current: SessionSnapshot
        var history: [HerdrEvent] = []
        var cursors: [Cursor] = []
        var holdSnapshots = false
        var pending: [(CheckedContinuation<SessionSnapshot, any Error>, SessionSnapshot)] = []
    }
    let socketPath = "/tmp/unused-herdr-cursor-model.sock"
    private let state: OSAllocatedUnfairLock<State>

    init(_ snapshot: SessionSnapshot) { state = OSAllocatedUnfairLock(initialState: State(current: snapshot)) }

    func snapshot() async throws -> SessionSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { state -> SessionSnapshot? in
                guard state.holdSnapshots else { return state.current }
                state.pending.append((continuation, state.current))
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func focus(paneID: String) async throws { throw HerdrError.invalidResponse }

    func events(paneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, any Error> {
        AsyncThrowingStream { continuation in
            state.withLock {
                $0.cursors.append(Cursor(statusPosition: $0.history.count,
                                         layoutPosition: $0.history.count, stream: continuation))
            }
            continuation.yield(.subscribed)
        }
    }

    var pendingSnapshots: Int { state.withLock { $0.pending.count } }
    func beginHoldingSnapshots(_ snapshot: SessionSnapshot) {
        state.withLock { $0.current = snapshot; $0.holdSnapshots = true }
    }
    func append(_ event: HerdrEvent) { state.withLock { $0.history.append(event) } }

    func pollStatus() -> HerdrEvent? { poll(status: true) }
    func pollLayout() -> HerdrEvent? { poll(status: false) }
    private func poll(status: Bool) -> HerdrEvent? {
        let (stream, event) = state.withLock { state in
            var cursor = status ? state.cursors[0].statusPosition : state.cursors[0].layoutPosition
            var match: HerdrEvent?
            while cursor < state.history.count {
                let event = state.history[cursor]
                cursor += 1
                if status, case .agentStatus = event { match = event; break }
                if !status, event == .layoutChanged { match = event; break }
            }
            if status { state.cursors[0].statusPosition = cursor } else { state.cursors[0].layoutPosition = cursor }
            return (state.cursors[0].stream, match)
        }
        if let event { stream.yield(event) }
        return event
    }

    func answerSnapshot() {
        let pending = state.withLock { $0.pending.isEmpty ? nil : $0.pending.removeFirst() }
        if let pending { pending.0.resume(returning: pending.1) }
    }

    func resumeSnapshots() {
        let pending = state.withLock { state in
            state.holdSnapshots = false
            defer { state.pending = [] }
            return state.pending
        }
        pending.forEach { $0.0.resume(returning: $0.1) }
    }

    func close() {
        let (pending, streams) = state.withLock { state in
            defer { state.pending = []; state.cursors = [] }
            return (state.pending, state.cursors.map(\.stream))
        }
        pending.forEach { $0.0.resume(throwing: CancellationError()) }
        streams.forEach { $0.finish() }
    }
}
