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
@Test func invalidFocusReplyCanBeDismissedWithoutClearingCompletion() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    var opened = false
    var activated = false
    store.onOpen = { opened = true }
    store.activateTerminal = { _, _ in activated = true }
    let completed = try snapshot([agent(status: "done", seq: 1)])
    store.apply(completed)
    let normalHeight = store.paletteHeight
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    fake.answerFocus(error: HerdrError.invalidResponse)
    await eventually { store.openingID == nil }

    #expect(store.actionError?.contains("Open it in your terminal.") == true)
    #expect(store.paletteHeight > normalHeight)
    #expect(store.connected)
    #expect(!opened)
    #expect(!activated)
    #expect(store.rows.first?.status == .done)

    var heightAtDismissal: CGFloat?
    store.onChange = { heightAtDismissal = store.paletteHeight }
    store.dismissActionError()
    #expect(store.actionError == nil)
    #expect(heightAtDismissal == normalHeight)
    store.apply(completed)
    #expect(store.actionError == nil)
    #expect(store.rows.first?.status == .done)
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
        userInfo: NotificationTarget(row: row, socketPath: store.socketPath, scope: store.notificationScope).userInfo))
    #expect(store.row(for: target) == row)
    #expect(store.row(for: NotificationTarget(row: row, socketPath: "/tmp/other.sock", scope: store.notificationScope)) == nil)
    store.apply(try snapshot([agent("w2:p1", status: "done", seq: 1)]))
    #expect(store.row(for: target)?.id == "w2:p1")
    store.apply(try snapshot([agent("w2:p1", status: "done", seq: 1, session: "replacement")]))
    #expect(store.row(for: target) == nil)

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
@Test func snapshotBeforeCompletionWaitsForValidatedAttention() async throws {
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
    #expect(store.rows.first?.status == .working)
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
                                                     agent("w1:p2", status: "idle", seq: 2, terminal: "term2")]))
    await eventually { fake.subscriptions.count == 2 }
    #expect(fake.subscriptions.last == ["w1:p1", "w1:p2"])
    #expect(fake.closedStreams == 1)
}

@MainActor
@Test func fourOverlappingSnapshotsCannotCommitAnUnvalidatedCompletion() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    Task { await store.refresh() }
    for _ in 1...4 {
        await eventually { fake.pendingSnapshots == 1 }
        fake.send(.agentStatus(paneID: "w1:p1", status: .working))
        await eventually { store.rows.first?.status == .working }
        fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
        await eventually { store.rows.first?.status == .idle }
        fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 1)]))
    }
    await eventually { fake.pendingSnapshots == 1 }
    #expect(store.rows.first?.status == .idle)
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 9)]))
    await eventually { store.rows.first?.status == .done }
}

@MainActor
@Test func repeatedTopologyInvalidationsNeverInstallStaleMembership() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    store.apply(try snapshot([agent(status: "done", seq: 2)]))
    Task { await store.refresh() }
    for _ in 1...4 {
        await eventually { fake.pendingSnapshots == 1 }
        fake.send(.layoutChanged)
        await settle()
        fake.answerSnapshot(try snapshot([]))
        await settle()
        #expect(store.rows.first?.status == .done)
    }
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(try snapshot([agent("w2:p1", status: "idle", seq: 2)]))
    await eventually { store.rows.first?.id == "w2:p1" }
    #expect(store.rows.first?.status == .done)
}

@MainActor
@Test func openingWithoutSequencesKeepsNewerCompletionVisible() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    store.apply(try snapshot([agent(status: "working", seq: nil)]))
    store.apply(try snapshot([agent(status: "idle", seq: nil)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    store.apply(try snapshot([agent(status: "working", seq: nil)]))
    store.apply(try snapshot([agent(status: "idle", seq: nil)]))
    fake.answerFocus()
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: nil)]))
    await eventually { store.openingID == nil }
    #expect(store.rows.first?.status == .done)
}

@MainActor
@Test func notificationOccurrencesSurviveMovesAndDistinguishSessions() throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    var delivered: [AgentRow] = []
    store.deliverNotification = { row, _, _ in delivered.append(row) }
    store.notificationsEnabled = true
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    #expect(delivered.isEmpty) // Startup is not a new completion.
    store.apply(try snapshot([agent(status: "done", seq: 2)]))
    store.apply(try snapshot([agent("w2:p1", status: "done", seq: 2)]))
    #expect(delivered.count == 1)
    store.apply(try snapshot([agent("w2:p1", status: "done", seq: 2, session: "replacement")]))
    #expect(delivered.count == 2)
}

@MainActor
@Test func eachValidatedCompletionNotifiesOnce() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    var delivered: [AgentRow] = []
    store.deliverNotification = { row, _, _ in delivered.append(row) }
    store.notificationsEnabled = true
    for index in 1...2 {
        fake.send(.agentStatus(paneID: "w1:p1", status: .working))
        await eventually { store.rows.first?.status == .working }
        fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
        await eventually { store.rows.first?.status != .working }
        #expect(delivered.count == index - 1)
        await answerSnapshots(fake, with: try snapshot([agent(status: "idle", seq: UInt64(1 + index * 2))]))
        #expect(delivered.count == index)
    }
    #expect(delivered[0].stateGeneration != delivered[1].stateGeneration)
    store.apply(try snapshot([agent(status: "idle", seq: 5)]))
    #expect(delivered.count == 2)
}

@MainActor
@Test func multipleProvisionalCyclesProduceOneValidatedNotice() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    var delivered: [AgentRow] = []
    store.deliverNotification = { row, _, _ in delivered.append(row) }
    store.notificationsEnabled = true
    for _ in 0..<2 {
        fake.send(.agentStatus(paneID: "w1:p1", status: .working))
        fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
    }
    await eventually { fake.pendingSnapshots == 1 }
    #expect(delivered.isEmpty)
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 5)]))
    await eventually { store.rows.first?.status == .done }
    #expect(delivered.count == 1)
}

@MainActor
@Test func failedEventStreamExposesPollingDiagnostics() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    #expect(store.transportMode == "Live")
    fake.failStream()
    await eventually { store.transportMode == "Polling" }
    #expect(store.lastEventError != nil)
    await answerSnapshots(fake, with: try snapshot([agent(status: "idle", seq: 1)]))
    #expect(store.connected)
    #expect(store.lastSuccessfulRefresh != nil)
}

@MainActor
@Test func ambiguousPaneEventsCannotCompleteTheMovedAgentsWork() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    fake.send(.layoutChanged)
    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
    await answerSnapshots(fake, with: try snapshot([
        agent("w2:p1", status: "idle", seq: 1),
        agent("w1:p1", status: "idle", seq: 3, terminal: "replacement"),
    ]))
    #expect(store.rows.allSatisfy { $0.status == .idle })
}

@MainActor
@Test func focusAtAnOldAddressDoesNotAcknowledgeTheMovedAgent() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    let moved = try snapshot([agent("w2:p1", status: "done", seq: 1),
                              agent("w1:p1", status: "idle", seq: 1, terminal: "replacement")])
    store.apply(moved)
    fake.answerFocus()
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(moved)
    await eventually { store.openingID == nil }
    #expect(store.rows.first(where: { $0.id == "w2:p1" })?.status == .done)
}

@MainActor
@Test func connectionChangeDuringTerminalActivationCannotAcknowledgeNewConnection() async throws {
    let (store, fake, clients) = makeStore()
    defer { store.stop(); fake.close(); clients.all.forEach { $0.close() } }
    var activation: CheckedContinuation<Void, Never>?
    store.activateTerminal = { _, _ in
        await withCheckedContinuation { activation = $0 }
    }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    fake.answerFocus()
    await eventually { activation != nil }
    store.setSocketPath("/tmp/second.sock")
    let second = try #require(clients.all.last)
    await eventually { second.pendingSnapshots == 1 }
    second.answerSnapshot(try snapshot([agent(status: "done", seq: 1)]))
    await eventually { store.connected }
    activation?.resume()
    await settle()
    #expect(store.rows.first?.status == .done)
    #expect(second.pendingSnapshots == 0)
}

@MainActor
@Test func timedOutHandshakeRetriesEvenWhenPaneSetDoesNotChange() async throws {
    let (store, fake, _) = makeStore(eventRetryDelay: .zero)
    defer { store.stop(); fake.close() }
    let idle = try snapshot([agent(status: "idle", seq: 1)])
    store.start()
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(idle)
    await eventually { fake.subscriptions.count == 1 }
    // The transport's handshake deadline fails the stream without ever yielding subscribed.
    fake.failStream()
    await eventually { store.lastEventError != nil }
    #expect(store.transportMode == "Polling")
    await answerSnapshots(fake, with: idle)
    await eventually { fake.subscriptions.count == 2 }
    fake.send(.subscribed)
    await answerSnapshots(fake, with: idle)
    #expect(store.transportMode == "Live")
    #expect(store.lastEventError == nil)
}

@MainActor
@Test func quarantinedStatusTrafficAllowsRecoveryAndDoesNotHideNewWork() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    fake.send(.agentStatus(paneID: "w1:p1", status: .done))
    await answerSnapshots(fake, with: try snapshot([agent(status: "done", seq: 3)]))
    store.markDoneAsRead()
    fake.send(.layoutChanged)
    await eventually { fake.pendingSnapshots == 1 }
    // Same membership; no resubscription will mark a gap on our behalf.
    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    fake.send(.agentStatus(paneID: "w1:p1", status: .done))
    await settle()
    fake.answerSnapshot(try snapshot([agent(status: "done", seq: 5)]))
    await eventually { store.rows.first?.status == .done }
    // Quarantined status changes must not invalidate this recovery snapshot.
    #expect(store.rows.first?.info.stateChangeSeq == 5)
    #expect(fake.subscriptions.count == 1)
    await answerSnapshots(fake, with: try snapshot([agent(status: "done", seq: 5)]))
}

@MainActor
@Test func malformedEventFailureFallsBackAndRecoversWithTheSamePanes() async throws {
    let (store, fake, _) = makeStore(eventRetryDelay: .zero)
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    fake.failStream(error: .invalidResponse)
    await eventually { store.lastEventError != nil }
    #expect(store.transportMode == "Polling")
    #expect(store.connected)
    #expect(store.lastEventError == HerdrError.invalidResponse.localizedDescription)
    await answerSnapshots(fake, with: try snapshot([agent(status: "idle", seq: 1)]))
    await eventually { fake.subscriptions.count == 2 }
    fake.send(.subscribed)
    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
    await answerSnapshots(fake, with: try snapshot([agent(status: "idle", seq: 3)]))
    #expect(store.transportMode == "Live")
    #expect(store.lastEventError == nil)
    #expect(store.rows.first?.status == .done)
}

@MainActor
@Test func invalidFocusReplyCannotActivateOrAcknowledgeCompletion() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    var activated = false
    var opened = false
    store.activateTerminal = { _, _ in activated = true }
    store.onOpen = { opened = true }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    fake.answerFocus(error: HerdrError.invalidResponse)
    await eventually { store.openingID == nil }
    #expect(!activated)
    #expect(!opened)
    #expect(store.rows.first?.status == .done)
    #expect(store.actionError == "Cannot confirm the agent opened. Unexpected Herdr reply. Open it in your terminal.")
    #expect(fake.pendingSnapshots == 0)
}

@MainActor
@Test func failedTerminalActivationDoesNotAcknowledgeCompletion() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    store.activateTerminal = { _, _ in throw HerdrError.server("Terminal unavailable") }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    fake.answerFocus()
    await eventually { store.openingID == nil }
    #expect(store.actionError == "Terminal unavailable")
    #expect(store.rows.first?.status == .done)
    #expect(fake.pendingSnapshots == 0)
}

@MainActor
@Test func stoppingTheStoreCancelsPendingTerminalDiscovery() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    var started = false
    var cancelled = false
    store.activateTerminal = { _, _ in
        started = true
        do { try await Task.sleep(for: .seconds(5)) }
        catch { cancelled = true; throw error }
    }
    store.apply(try snapshot([agent(status: "done", seq: 1)]))
    store.open(try #require(store.rows.first))
    await eventually { fake.pendingFocuses == 1 }
    fake.answerFocus()
    await eventually { started }
    store.stop()
    await eventually { cancelled && store.openingID == nil }
    #expect(store.actionError == nil)
    #expect(store.rows.first?.status == .done)
    #expect(fake.pendingSnapshots == 0)
}

@MainActor
@Test func stoppingDuringManualRefreshPreventsLatePublication() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    var changes = 0
    store.onChange = { changes += 1 }
    let refresh = Task { await store.refresh() }
    await eventually { fake.pendingSnapshots == 1 }
    store.stop()
    fake.answerSnapshot(try snapshot([agent(status: "done", seq: 1)]))
    await refresh.value
    #expect(store.rows.isEmpty)
    #expect(!store.connected)
    #expect(store.loading)
    #expect(changes == 0)
    #expect(fake.subscriptions.isEmpty)
}

@MainActor
@Test func stoppingDuringEventRefreshPreventsLatePublication() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    await eventually { fake.pendingSnapshots == 1 }
    var joined = false
    let refresh = Task { joined = true; await store.refresh() }
    await eventually { joined }
    store.stop()
    fake.answerSnapshot(try snapshot([agent(status: "blocked", seq: 3)]))
    await refresh.value
    #expect(store.rows.first?.status == .working)
    #expect(!store.eventsLive)
    #expect(fake.pendingSnapshots == 0)
    #expect(fake.subscriptions.count == 1)
}

@MainActor
@Test func restartDoesNotWaitForOrPublishAnOldRefresh() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    let oldRefresh = Task { await store.refresh() }
    await eventually { fake.pendingSnapshots == 1 }
    store.stop()
    store.start()
    await eventually { fake.pendingSnapshots == 2 }
    fake.answerSnapshot(try snapshot([agent(status: "working", seq: 2)]), at: 1)
    await eventually { store.connected }
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 1)]))
    await oldRefresh.value
    #expect(store.rows.first?.status == .working)
    #expect(fake.subscriptions.count == 1)
}

@MainActor
@Test func aNewConnectionDoesNotInheritTheOldSubscriptionRetryDelay() async throws {
    let (store, fake, clients) = makeStore(eventRetryDelay: .seconds(60))
    defer { store.stop(); fake.close(); clients.all.forEach { $0.close() } }
    try await startWithEvents(store, fake)
    fake.failStream()
    await eventually { !store.eventsLive && store.lastEventError != nil }

    store.setSocketPath("/tmp/second.sock")
    let second = try #require(clients.all.last)
    await eventually { second.pendingSnapshots == 1 }
    second.answerSnapshot(try snapshot([agent(status: "idle", seq: 1)]))
    // The new connection must subscribe before the old connection's 60-second deadline.
    await eventually { second.subscriptions.count == 1 }
    second.send(.subscribed)
    await eventually { store.eventsLive }
}

@MainActor
@Test func restartingTheStoreDoesNotWaitForThePreviousSubscriptionRetry() async throws {
    let (store, fake, _) = makeStore(eventRetryDelay: .seconds(60))
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    fake.failStream()
    await eventually { !store.eventsLive && store.lastEventError != nil }

    store.stop()
    store.start()
    await eventually { fake.pendingSnapshots == 1 }
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 1)]))
    await eventually { fake.subscriptions.count == 2 }
    fake.send(.subscribed)
    await eventually { store.eventsLive }
}

@MainActor
@Test func anOldFocusCannotAcknowledgeCompletionEventsBeforeReconciliation() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    store.apply(try snapshot([agent(status: "done", seq: 3)]))
    let oldRow = try #require(store.rows.first)
    store.open(oldRow)
    await eventually { fake.pendingFocuses == 1 }
    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    await eventually { store.rows.first?.status == .working }
    fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
    await eventually { store.rows.first?.status == .done }
    await eventually { fake.pendingSnapshots == 1 }
    var opened = false
    store.onOpen = { opened = true }
    fake.answerFocus()
    await eventually { opened }
    #expect(store.rows.first?.status == .done)
    fake.answerSnapshot(try snapshot([agent(status: "idle", seq: 5)]))
    await eventually { store.openingID == nil }
    #expect(store.rows.first?.status == .done)
    #expect(store.rows.first?.stateGeneration != oldRow.stateGeneration)
}

@MainActor
@Test func statusBeforeLayoutCannotNotifyForTheOldOccupant() async throws {
    for completeCycle in [false, true] {
        let (store, fake, _) = makeStore()
        defer { store.stop(); fake.close() }
        try await startWithEvents(store, fake)
        var delivered: [AgentRow] = []
        store.deliverNotification = { row, _, _ in delivered.append(row) }
        store.notificationsEnabled = true
        fake.send(.agentStatus(paneID: "w1:p1", status: .working))
        await eventually { store.rows.first?.status == .working }
        if completeCycle { fake.send(.agentStatus(paneID: "w1:p1", status: .idle)) }
        fake.send(.layoutChanged)
        await eventually { store.rows.first?.status == .idle }
        #expect(delivered.isEmpty)
        let recovered = try snapshot([
            agent("w2:p1", status: "idle", seq: 1),
            agent("w1:p1", status: "working", seq: 2, terminal: "replacement"),
        ])
        await answerSnapshots(fake, with: recovered)
        store.apply(recovered)
        #expect(store.rows.first(where: { $0.id == "w2:p1" })?.status == .idle)
        #expect(delivered.isEmpty)
    }
}

@MainActor
@Test func lateOldStatusCycleCannotNotifyAfterANewerSnapshot() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    try await startWithEvents(store, fake)
    store.apply(try snapshot([agent(status: "idle", seq: 7)]))
    var delivered: [AgentRow] = []
    store.deliverNotification = { row, _, _ in delivered.append(row) }
    store.notificationsEnabled = true
    fake.send(.agentStatus(paneID: "w1:p1", status: .working))
    await eventually { store.rows.first?.status == .working }
    fake.send(.agentStatus(paneID: "w1:p1", status: .idle))
    await answerSnapshots(fake, with: try snapshot([agent(status: "idle", seq: 7)]))
    store.apply(try snapshot([agent(status: "idle", seq: 7)]))
    #expect(store.rows.first?.status == .idle)
    #expect(delivered.isEmpty)
}

@MainActor
@Test func livePollingSleepsToTheTitleDeadlineAndStreamFailureWakesIt() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
    store.sleepForPolling = { delay in
        sleeps.withLock { $0.append(delay) }
        try await Task.sleep(for: .seconds(60))
    }
    try await startWithEvents(store, fake)
    await eventually { sleeps.withLock { ($0.last ?? .zero) > .seconds(14) } }
    #expect(sleeps.withLock { $0.last! <= .seconds(15) })
    let count = sleeps.withLock { $0.count }
    fake.failStream()
    await eventually { sleeps.withLock { $0.count > count && $0.last! <= .seconds(2) } }
    #expect(!store.eventsLive)
}

@MainActor
@Test func offlinePollingBackoffIsCappedAndSuccessRestoresTheNormalInterval() async throws {
    let (store, fake, _) = makeStore()
    defer { store.stop(); fake.close() }
    let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
    store.sleepForPolling = { delay in
        sleeps.withLock { $0.append(delay) }
        try await Task.sleep(for: .seconds(60))
    }
    store.start()
    for seconds in [2, 4, 8, 16, 30, 30] {
        await eventually { fake.pendingSnapshots == 1 }
        let count = sleeps.withLock { $0.count }
        fake.failSnapshot()
        await eventually { sleeps.withLock { $0.count > count } }
        let delay = try #require(sleeps.withLock { $0.last })
        #expect(delay <= .seconds(seconds))
        #expect(delay > .seconds(seconds - 1))
        // A user request must start at once, even while the poll timer backs off.
        Task { await store.refresh() }
    }
    await eventually { fake.pendingSnapshots == 1 }
    let count = sleeps.withLock { $0.count }
    fake.answerSnapshot(try snapshot([]))
    await eventually { store.connected && sleeps.withLock { $0.count > count } }
    #expect(sleeps.withLock { $0.last! <= .seconds(2) })
}

// MARK: - Helpers

@MainActor
private func makeStore(eventRetryDelay: Duration = .seconds(10)) -> (AgentStore, FakeHerdr, Clients) {
    let fake = FakeHerdr(socketPath: "/tmp/first.sock")
    let clients = Clients()
    let defaults = UserDefaults(suiteName: "herdr-bar-tests-\(UUID().uuidString)")!
    let store = AgentStore(client: fake, defaults: defaults, eventRetryDelay: eventRetryDelay) { path in
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

private func agent(_ pane: String = "w1:p1", status: String, seq: UInt64?,
                   terminal: String = "term1", session: String = "session1") -> [String: Any] {
    var value: [String: Any] = ["pane_id": pane, "terminal_id": terminal, "workspace_id": "w1", "tab_id": "w1:t1",
     "agent": "claude", "agent_status": status, "agent_session": ["kind": "id", "value": session], "focused": false]
    value["state_change_seq"] = seq
    return value
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

    func answerSnapshot(_ snapshot: SessionSnapshot, at index: Int = 0,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        guard let continuation = state.withLock({ $0.snapshots.indices.contains(index) ? $0.snapshots.remove(at: index) : nil }) else {
            Issue.record("The store did not request a snapshot.", sourceLocation: sourceLocation)
            return
        }
        continuation.resume(returning: snapshot)
    }

    func failSnapshot(sourceLocation: SourceLocation = #_sourceLocation) {
        guard let continuation = state.withLock({ $0.snapshots.isEmpty ? nil : $0.snapshots.removeFirst() }) else {
            Issue.record("The store did not request a snapshot.", sourceLocation: sourceLocation)
            return
        }
        continuation.resume(throwing: HerdrError.timeout)
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

    func failStream(error: HerdrError = .timeout) {
        state.withLock { $0.streams.last }?.finish(throwing: error)
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
