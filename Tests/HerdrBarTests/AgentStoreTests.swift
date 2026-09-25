import Foundation
import HerdrBarCore
import os
import Testing
@testable import HerdrBar

@MainActor
@Test func openingAnAgentAcknowledgesItsCompletion() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    var opened = false
    store.onOpen = { opened = true }
    store.apply(try snapshot([agent(status: "working", seq: 1)]))
    store.apply(try snapshot([agent(status: "idle", seq: 2)]))
    let row = try #require(store.rows.first)
    #expect(row.status == .done)

    store.open(row)
    await eventually { fake.pendingFocuses == 1 }
    fake.answerFocus()
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 2)]))
    await eventually { store.openingID == nil }
    #expect(opened)
    #expect(store.rows.first?.status == .idle)
}

@MainActor
@Test func openingAnAgentKeepsANewerCompletionVisible() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    store.apply(try snapshot([agent(status: "working", seq: 1)]))
    store.apply(try snapshot([agent(status: "idle", seq: 2)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }

    // The agent starts and finishes new work while the focus request waits.
    store.apply(try snapshot([agent(status: "working", seq: 3)]))
    store.apply(try snapshot([agent(status: "idle", seq: 4)]))
    fake.answerFocus()
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 4)]))
    await eventually { store.openingID == nil }
    #expect(store.rows.first?.status == .done)
}

@MainActor
@Test func anActionForAnOldConnectionDoesNotChangeTheNewConnection() async throws {
    let (store, fake, clients) = makeStore()
    defer { store.stop(); fake.close(); clients.all.forEach { $0.close() } }
    var opened = false
    store.onOpen = { opened = true }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }

    store.setSocketPath("/tmp/second.sock")
    #expect(store.openingID == nil)
    let second = try #require(clients.all.last)
    await eventually { second.pendingSnapshots == 1 }
    // The new session reuses the same pane ID.
    second.answerSnapshot(try snapshot([agent(status: "done", seq: 1)]))
    await eventually { store.connected }

    fake.answerFocus()
    await settle()
    #expect(!opened)
    #expect(store.rows.first?.status == .done)
    #expect(second.pendingSnapshots == 0)
}

@MainActor
@Test func aFailedActionForAnOldConnectionShowsNoError() async throws {
    let (store, fake, clients) = makeStore()
    defer { store.stop(); fake.close(); clients.all.forEach { $0.close() } }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    store.setSocketPath("/tmp/second.sock")
    fake.answerFocus(error: HerdrError.server("Agent has closed."))
    await settle()
    #expect(store.actionError == nil)
}

@MainActor
@Test func aNewConnectionDoesNotWaitForTheOldRequest() async throws {
    let (store, fake, clients) = makeStore()
    defer { store.stop(); fake.close(); clients.all.forEach { $0.close() } }
    Task { await store.refresh() }
    await eventually { fake.pendingSnapshots == 1 }

    store.setSocketPath("/tmp/second.sock")
    let second = try #require(clients.all.last)
    await eventually { second.pendingSnapshots == 1 }
    second.answerSnapshot(try snapshot([]))
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 1)]))
    await eventually { store.connected }
    await settle()
    #expect(store.rows.isEmpty)
}

@MainActor
@Test func notificationsOpenOnlyTheirOwnAgent() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    let row = try #require(store.rows.first)
    let target = try #require(NotificationTarget(
        userInfo: NotificationTarget(row: row, socketPath: store.socketPath).userInfo))
    #expect(store.row(for: target) == row)
    #expect(store.row(for: NotificationTarget(row: row, socketPath: "/tmp/other.sock")) == nil)

    store.apply(try snapshot([agent(status: "done", seq: 2, terminal: "replacement")]))
    #expect(store.row(for: target) == nil)
}

@MainActor
@Test func unchangedSnapshotsDoNotUpdateTheMenuBar() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    var changes = 0
    store.onChange = { changes += 1 }
    let idle = try snapshot([agent(status: "idle", seq: 1)])
    store.apply(idle)
    store.apply(idle)
    #expect(changes == 1)
    store.apply(try snapshot([agent(status: "working", seq: 2)]))
    #expect(changes == 2)
}

@MainActor
@Test func eventsShowWorkThatEndsBetweenTwoSnapshots() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)

    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
    await answerSnapshots(fake, with: try snapshot([agent(status: "idle", seq: 3)]))
    #expect(store.rows.first?.status == .done)
}

@MainActor
@Test func aSnapshotOlderThanAnEventIsNotShown() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)

    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    await eventually { fake.pendingSnapshots == 1 }
    fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
    await settle()
    // Herdr made this snapshot before the agent became idle.
    fake.answerSnapshot(try snapshot([agent(status: "working", seq: 2)]))
    await eventually { fake.pendingSnapshots == 1 }
    #expect(store.rows.first?.status == .idle)
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 3)]))
    await eventually { store.rows.first?.status == .done }
}

@MainActor
@Test func aNewAgentStartsANewSubscription() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)

    fake.send(.layoutChanged)
    await answerSnapshots(fake, with: try snapshot([agent(status: "idle", seq: 1),
                                                     agent("w1:p2", status: "idle", seq: 2)]))
    await eventually { fake.subscriptions.count == 2 }
    #expect(fake.subscriptions.last == ["w1:p1", "w1:p2"])
    #expect(fake.closedStreams == 1)
}

// MARK: - Helpers

@MainActor
private func makeStore() -> (AgentStore, FakeHerdr, Clients) {
    let fake = FakeHerdr(socketPath: "/tmp/first.sock")
    let clients = Clients()
    let defaults = UserDefaults(suiteName: "herdr-bar-tests-\(UUID().uuidString)")!
    let store = AgentStore(client: fake, defaults: defaults) { path in
        let client = FakeHerdr(socketPath: path)
        clients.all.append(client)
        return client
    }
    store.activateTerminal = { _, _ in }
    return (store, fake, clients)
}

/// Starts polling, answers the first snapshot, and accepts the event subscription.
@MainActor
private func startWithEvents(_ store: AgentStore, _ fake: FakeHerdr) async throws {
    let idle = try snapshot([agent(status: "idle", seq: 1)])
    store.start()
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(idle)
    await eventually { fake.subscriptions.count == 1 }
    #expect(fake.subscriptions.first == ["w1:p1"])
    fake.send(.subscribed)
    await answerSnapshots(fake, with: idle)
}

/// Answers each snapshot request until the store stops asking.
@MainActor
private func answerSnapshots(_ fake: FakeHerdr, with snapshot: SessionSnapshot) async {
    await eventually { fake.pendingSnapshots > 0 }
    while fake.pendingSnapshots > 0 {
        fake.answerSnapshot(snapshot)
        await settle()
    }
}

@MainActor
private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<1_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("The condition did not become true.", sourceLocation: sourceLocation)
}

/// Gives the store time to run its pending tasks.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(30))
}

private func agent(_ pane: String = "w1:p1", status: String, seq: UInt64,
                   terminal: String = "term1") -> [String: Any] {
    ["pane_id": pane, "terminal_id": terminal, "workspace_id": "w1", "tab_id": "w1:t1",
     "agent": "claude", "agent_status": status, "agent_session": ["kind": "id", "value": "session1"],
     "state_change_seq": seq, "focused": false]
}

private func snapshot(_ agents: [[String: Any]]) throws -> SessionSnapshot {
    let json: [String: Any] = [
        "version": "test", "agents": agents,
        "workspaces": [["workspace_id": "w1", "label": "herdr-bar", "number": 1]],
        "tabs": [["tab_id": "w1:t1", "label": "main", "number": 1]],
    ]
    return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
}

@MainActor
private final class Clients {
    var all: [FakeHerdr] = []
}

/// Holds each request until the test answers it, so the test controls the order of events.
private final class FakeHerdr: HerdrService {
    private struct State {
        var snapshots: [CheckedContinuation<SessionSnapshot, any Error>] = []
        var focuses: [CheckedContinuation<Void, any Error>] = []
        var streams: [AsyncThrowingStream<HerdrEvent, any Error>.Continuation] = []
        var subscriptions: [[String]] = []
        var closedStreams = 0
    }

    let socketPath: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(socketPath: String) { self.socketPath = socketPath }

    func snapshot() async throws -> SessionSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.snapshots.append(continuation) }
        }
    }

    func focus(paneID: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.focuses.append(continuation) }
        }
    }

    func events(paneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [state] _ in state.withLock { $0.closedStreams += 1 } }
            state.withLock {
                $0.streams.append(continuation)
                $0.subscriptions.append(paneIDs)
            }
        }
    }

    var pendingSnapshots: Int { state.withLock { $0.snapshots.count } }
    var pendingFocuses: Int { state.withLock { $0.focuses.count } }
    var subscriptions: [[String]] { state.withLock { $0.subscriptions } }
    var closedStreams: Int { state.withLock { $0.closedStreams } }

    func answerSnapshot(_ snapshot: SessionSnapshot, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let continuation = state.withLock({ $0.snapshots.isEmpty ? nil : $0.snapshots.removeFirst() }) else {
            Issue.record("The store did not request a snapshot.", sourceLocation: sourceLocation)
            return
        }
        continuation.resume(returning: snapshot)
    }

    func answerFocus(error: (any Error)? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let continuation = state.withLock({ $0.focuses.isEmpty ? nil : $0.focuses.removeFirst() }) else {
            Issue.record("The store did not request focus.", sourceLocation: sourceLocation)
            return
        }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func send(_ event: HerdrEvent) {
        _ = state.withLock { $0.streams.last }?.yield(event)
    }

    /// Ends every request that is still open, so no continuation leaks after a test.
    func close() {
        let (snapshots, focuses, streams) = state.withLock { state in
            defer { state.snapshots = []; state.focuses = []; state.streams = [] }
            return (state.snapshots, state.focuses, state.streams)
        }
        snapshots.forEach { $0.resume(throwing: CancellationError()) }
        focuses.forEach { $0.resume(throwing: CancellationError()) }
        streams.forEach { $0.finish() }
    }
}
