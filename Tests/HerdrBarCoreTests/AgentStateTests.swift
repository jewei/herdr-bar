import Foundation
import Testing
@testable import HerdrBarCore

@Test func idleAgentsDoNotNeedAttentionAtStartup() throws {
    var tracker = AttentionTracker()
    let rows = tracker.update(try snapshot(status: "idle"))
    #expect(rows.first?.status == .idle)
    #expect(AgentSummary(rows: rows).attention == 0)
}

@Test func completionStaysVisibleUntilAcknowledged() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: 1))
    let idle = try snapshot(status: "idle", sequence: 2)
    let completed = tracker.update(idle)
    #expect(completed.first?.status == .done)
    #expect(tracker.update(idle).first?.status == .done)
    tracker.acknowledge(try #require(completed.first))
    #expect(tracker.update(idle).first?.status == .idle)
}

@Test func focusedPaneCompletionStillNeedsAttention() throws {
    // Herdr's selected pane can be in a terminal that is behind another application.
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: 1, focused: true))
    #expect(tracker.update(try snapshot(status: "idle", sequence: 2, focused: true)).first?.status == .done)
}

@Test func replacementAgentCannotCompleteThePreviousAgentsWork() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", terminal: "old"))
    #expect(tracker.update(try snapshot(status: "idle", terminal: "new")).first?.status == .idle)
}

@Test func aServerSequenceResetClearsLocalCompletion() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: 90))
    #expect(tracker.update(try snapshot(status: "idle", sequence: 91)).first?.status == .done)
    #expect(tracker.update(try snapshot(status: "idle", sequence: 1)).first?.status == .idle)
}

@Test func aNewSessionInTheSameTerminalDoesNotCompleteThePreviousSession() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", session: "first"))
    #expect(tracker.update(try snapshot(status: "idle", session: "second")).first?.status == .idle)
}

@Test func aBlockedAgentStaysBlockedWhenOpened() throws {
    var tracker = AttentionTracker()
    let blocked = try snapshot(status: "blocked")
    let row = try #require(tracker.update(blocked).first)
    tracker.acknowledge(row)
    #expect(tracker.update(blocked).first?.status == .blocked)
    #expect(AgentSummary(rows: [row]).blocked == 1)
}

@Test func anExplicitDoneStateCanBeAcknowledgedWithoutHidingLaterCompletions() throws {
    var tracker = AttentionTracker()
    let done = try snapshot(status: "done", sequence: 10)
    let row = try #require(tracker.update(done).first)
    tracker.acknowledge(row)
    #expect(tracker.update(done).first?.status == .idle)
    #expect(tracker.update(try snapshot(status: "done", sequence: 12)).first?.status == .done)
}

@Test func anOpenedRowMatchesOnlyTheSameCompletion() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: 1))
    let opened = try #require(tracker.update(try snapshot(status: "idle", sequence: 2)).first)
    #expect(opened.hasSameState(as: opened))
    // The agent starts and finishes new work while the focus request waits.
    _ = tracker.update(try snapshot(status: "working", sequence: 3))
    let newer = try #require(tracker.update(try snapshot(status: "idle", sequence: 4)).first)
    #expect(newer.status == .done)
    #expect(!newer.hasSameState(as: opened))
}

@Test func anOpenedRowDoesNotMatchAReplacementAgent() throws {
    var tracker = AttentionTracker()
    let opened = try #require(tracker.update(try snapshot(status: "done", sequence: 5)).first)
    let replacement = try #require(tracker.update(try snapshot(status: "done", sequence: 5, session: "second")).first)
    #expect(!replacement.hasSameState(as: opened))
}

@Test func eventsShowWorkThatEndsBetweenTwoSnapshots() throws {
    var tracker = AttentionTracker()
    let idle = try snapshot(status: "idle", sequence: 1)
    _ = tracker.update(idle)
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .idle)
    tracker.observe(paneID: "w1:p1", status: .idle)
    let row = try #require(tracker.update(try snapshot(status: "idle", sequence: 3)).first)
    #expect(row.status == .done)
    tracker.acknowledge(row)
    #expect(tracker.update(try snapshot(status: "idle", sequence: 3)).first?.status == .idle)
}

@Test func eventsThatEndBlockedDoNotCountAsCompletion() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "idle"))
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .blocked)
    tracker.observe(paneID: "w1:p1", status: .idle)
    #expect(tracker.update(try snapshot(status: "idle")).first?.status == .idle)
}

@Test func clientCommandLinesResolveTheirSessionSocket() {
    let home = URL(fileURLWithPath: "/Users/test")
    let main = "/Users/test/.config/herdr/herdr.sock"
    let work = "/Users/test/.config/herdr/sessions/work/herdr.sock"
    #expect(ClientProcess.socketPath(arguments: ["herdr"], environment: [:], home: home) == main)
    #expect(ClientProcess.socketPath(arguments: ["herdr", "--session", "work"], environment: [:], home: home) == work)
    #expect(ClientProcess.socketPath(arguments: ["herdr", "--session=work"], environment: [:], home: home) == work)
    #expect(ClientProcess.socketPath(arguments: ["herdr", "session", "attach", "work"], environment: [:],
                                     home: home) == work)
    #expect(ClientProcess.socketPath(arguments: ["herdr"], environment: ["HERDR_SESSION": "work"], home: home) == work)
    #expect(ClientProcess.socketPath(arguments: ["herdr"], environment: ["HERDR_SOCKET_PATH": "/tmp/x.sock"],
                                     home: home) == main)
    #expect(ClientProcess.socketPath(arguments: ["herdr", "server"], environment: [:], home: home) == nil)
    #expect(ClientProcess.socketPath(arguments: ["herdr", "agent", "list"], environment: [:], home: home) == nil)
}

@Test func aLaterDoneStateWithoutASequenceIsNotHidden() throws {
    // Herdr can omit `state_change_seq`. Then an acknowledgement cannot compare sequences.
    var tracker = AttentionTracker()
    let done = try snapshot(status: "done", sequence: nil)
    tracker.acknowledge(try #require(tracker.update(done).first))
    #expect(tracker.update(done).first?.status == .idle)
    _ = tracker.update(try snapshot(status: "idle", sequence: nil))
    #expect(tracker.update(done).first?.status == .done)
}

@Test func movingAPanePreservesUnreadAndAcknowledgedOccurrences() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: 1))
    let done = try #require(tracker.update(try snapshot(status: "idle", sequence: 2)).first)
    let moved = try #require(tracker.update(try snapshot(status: "idle", sequence: 2, pane: "w2:p1")).first)
    #expect(moved.status == .done)
    #expect(moved.hasSameState(as: done))
    let acknowledged = tracker.acknowledge(done)
    #expect(acknowledged)
    #expect(tracker.update(try snapshot(status: "idle", sequence: 2, pane: "w3:p1")).first?.status == .idle)

    let explicit = try #require(tracker.update(try snapshot(status: "done", sequence: 3, pane: "w3:p1")).first)
    tracker.acknowledge(explicit)
    #expect(tracker.update(try snapshot(status: "done", sequence: 3, pane: "w4:p1")).first?.status == .idle)
}

@Test func explicitDoneRemainsUnreadAfterAnotherClientMarksItSeen() throws {
    var tracker = AttentionTracker()
    let done = try #require(tracker.update(try snapshot(status: "done", sequence: 1)).first)
    let idle = try #require(tracker.update(try snapshot(status: "idle", sequence: 1)).first)
    #expect(idle.status == .done)
    #expect(idle.hasSameState(as: done))
    tracker.acknowledge(done)
    #expect(tracker.update(try snapshot(status: "idle", sequence: 1)).first?.status == .idle)
}

@Test func missingSequencesStillDistinguishAuthoritativeCompletionOccurrences() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: nil))
    let first = try #require(tracker.update(try snapshot(status: "idle", sequence: nil)).first)
    _ = tracker.update(try snapshot(status: "working", sequence: nil))
    let second = try #require(tracker.update(try snapshot(status: "idle", sequence: nil)).first)
    #expect(!first.hasSameState(as: second))
    let accepted = tracker.acknowledge(first)
    #expect(!accepted)
    #expect(tracker.project([second]).first?.status == .done)
}

@Test func provisionalCompletionNeedsAnAdvancingSequence() throws {
    for sequence: UInt64? in [1, nil] {
        var tracker = AttentionTracker()
        let initial = tracker.update(try snapshot(status: "idle", sequence: sequence))
        tracker.observe(paneID: "w1:p1", status: .working)
        #expect(tracker.project(initial).first?.status == .working)
        tracker.observe(paneID: "w1:p1", status: .idle)
        #expect(tracker.project(initial).first?.status == .idle)
        #expect(tracker.update(try snapshot(status: "idle", sequence: sequence)).first?.status == .idle)
        #expect(tracker.update(try snapshot(status: "idle", sequence: sequence)).first?.status == .idle)
    }
}

@Test func repeatedOverlappingSnapshotsCannotCommitProvisionalAttention() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "idle", sequence: 1))
    for _ in 1...4 {
        tracker.observe(paneID: "w1:p1", status: .working)
        tracker.observe(paneID: "w1:p1", status: .idle)
        let stale = try snapshot(status: "idle", sequence: 1)
        #expect(tracker.update(stale, preservingObservedStateFor: ["w1:p1"]).first?.status == .idle)
    }
    #expect(tracker.update(try snapshot(status: "idle", sequence: 9)).first?.status == .done)
}

@Test func newerIncompatibleSnapshotBreaksProvisionalCompletionEvidence() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "idle", sequence: 1))
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .idle)
    #expect(tracker.update(try snapshot(status: "blocked", sequence: 4),
                           preservingObservedStateFor: ["w1:p1"]).first?.status == .blocked)
    #expect(tracker.update(try snapshot(status: "idle", sequence: 5)).first?.status == .idle)
}

@Test func inferredThenExplicitCompletionIsOnlyOneOccurrence() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: 1))
    tracker.observe(paneID: "w1:p1", status: .idle)
    let inferred = try #require(tracker.update(try snapshot(status: "idle", sequence: 2)).first)
    tracker.observe(paneID: "w1:p1", status: .done)
    let explicit = try #require(tracker.update(try snapshot(status: "done", sequence: 2)).first)
    #expect(inferred.hasSameState(as: explicit))
}

@Test func aSnapshotDoesNotDoubleCountAnExplicitCompletionEvent() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "done", sequence: 1))
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .done)
    let rows = tracker.update(try snapshot(status: "done", sequence: 3), preservingObservedStateFor: ["w1:p1"])
    let fresh = tracker.update(try snapshot(status: "done", sequence: 3))
    #expect(rows.first?.stateGeneration == fresh.first?.stateGeneration)
}

@Test func acknowledgedInferredCompletionIsNotReopenedByExplicitConfirmation() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working", sequence: 1))
    let inferred = try #require(tracker.update(try snapshot(status: "idle", sequence: 2)).first)
    tracker.acknowledge(inferred)
    let explicit = try #require(tracker.update(try snapshot(status: "done", sequence: 2)).first)
    #expect(explicit.status == .idle)
    #expect(explicit.stateGeneration == inferred.stateGeneration)
    #expect(tracker.update(try snapshot(status: "done", sequence: 4)).first?.status == .done)
}

@Test func aSnapshotWithNoSequenceCannotValidateAnEventOnlyCompletion() throws {
    var tracker = AttentionTracker()
    let initial = tracker.update(try snapshot(status: "idle", sequence: 10))
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .idle)
    #expect(tracker.project(initial).first?.status == .idle)
    #expect(tracker.update(try snapshot(status: "idle", sequence: nil)).first?.status == .idle)
    // A later sequence alone cannot reconstruct the discarded short cycle.
    #expect(tracker.update(try snapshot(status: "idle", sequence: 12)).first?.status == .idle)
}

@Test func absentSequenceDoesNotEraseTheLastKnownWatermark() throws {
    var tracker = AttentionTracker()
    let done = try #require(tracker.update(try snapshot(status: "done", sequence: 10)).first)
    tracker.acknowledge(done)
    #expect(tracker.update(try snapshot(status: "done", sequence: nil)).first?.status == .idle)
    #expect(tracker.update(try snapshot(status: "done", sequence: 12)).first?.status == .done)
    #expect(tracker.update(try snapshot(status: "idle", sequence: nil)).first?.status == .done)
    #expect(tracker.update(try snapshot(status: "idle", sequence: 1)).first?.status == .idle)
}

@Test func repeatedBlockedSnapshotsWithNewSequencesAreDistinctOccurrences() throws {
    var tracker = AttentionTracker()
    let first = try #require(tracker.update(try snapshot(status: "blocked", sequence: 1)).first)
    let next = try #require(tracker.update(try snapshot(status: "blocked", sequence: 3)).first)
    #expect(!first.hasSameState(as: next))
}

@Test func eventGapConservativelyReannouncesAdvancedDoneSequence() throws {
    var tracker = AttentionTracker()
    let observed = try #require(tracker.update(try snapshot(status: "done", sequence: 3)).first)
    tracker.acknowledge(observed)
    tracker.markEventGap()
    let recovered = try #require(tracker.update(try snapshot(status: "done", sequence: 5)).first)
    #expect(recovered.status == .done)
    #expect(recovered.stateGeneration != observed.stateGeneration)
}

@Test func aMovedSnapshotDiscardsUnvalidatedAddressEvidence() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "idle", sequence: 1))
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .idle)
    let moved = try snapshot(status: "idle", sequence: 1, pane: "w2:p1")
    #expect(tracker.update(moved, preservingObservedStateFor: ["w1:p1"]).first?.status == .idle)
    #expect(tracker.update(moved).first?.status == .idle)
}

@Test func duplicateEventsCannotChangeCommittedOccurrenceOrBlockAcknowledgement() throws {
    var tracker = AttentionTracker()
    let completed = try #require(tracker.update(try snapshot(status: "done", sequence: 3)).first)
    tracker.observe(paneID: "w1:p1", status: .done)
    tracker.observe(paneID: "w1:p1", status: .done)
    #expect(tracker.project([completed]).first?.stateGeneration == completed.stateGeneration)
    let accepted = tracker.acknowledge(completed)
    #expect(accepted)
    let unchanged = tracker.update(try snapshot(status: "done", sequence: 3))
    #expect(unchanged.first?.status == .idle)
    #expect(unchanged.first?.stateGeneration == completed.stateGeneration)
}

@Test func invalidTopologyRejectsFurtherAddressOnlyObservations() throws {
    var tracker = AttentionTracker()
    let initial = tracker.update(try snapshot(status: "idle", sequence: 1))
    tracker.invalidateTopology()
    tracker.observe(paneID: "w1:p1", status: .working)
    #expect(tracker.project(initial).first?.status == .idle)
    #expect(tracker.update(try snapshot(status: "idle", sequence: 2)).first?.status == .idle)
}

@Test func topologyInvalidationPreservesCommittedUnreadAndAcknowledgements() throws {
    for acknowledged in [false, true] {
        var tracker = AttentionTracker()
        let completed = try #require(tracker.update(try snapshot(status: "done", sequence: 3)).first)
        if acknowledged {
            let accepted = tracker.acknowledge(completed)
            #expect(accepted)
        }
        tracker.observe(paneID: "w1:p1", status: .working)
        tracker.invalidateTopology()
        let moved = tracker.update(try snapshot(status: "idle", sequence: 3, pane: "w2:p1"))
        #expect(moved.first?.status == (acknowledged ? .idle : .done))
        #expect(moved.first?.stateGeneration == completed.stateGeneration)
    }
}

@Test func pendingEventsPreventAnOldAcknowledgementBeforeValidation() throws {
    var tracker = AttentionTracker()
    let completed = try #require(tracker.update(try snapshot(status: "done", sequence: 3)).first)
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .idle)
    let accepted = tracker.acknowledge(completed)
    #expect(!accepted)
    let newer = try #require(tracker.update(try snapshot(status: "idle", sequence: 5)).first)
    #expect(newer.status == .done)
    #expect(newer.stateGeneration != completed.stateGeneration)
    let acceptedAfterValidation = tracker.acknowledge(completed)
    #expect(!acceptedAfterValidation)
}

@Test func delayedOldEventsCannotReopenAnAcknowledgedCompletion() throws {
    var tracker = AttentionTracker()
    let completed = try #require(tracker.update(try snapshot(status: "done", sequence: 9)).first)
    let accepted = tracker.acknowledge(completed)
    #expect(accepted)
    tracker.observe(paneID: "w1:p1", status: .working)
    tracker.observe(paneID: "w1:p1", status: .idle)
    let recovered = tracker.update(try snapshot(status: "idle", sequence: 9))
    #expect(recovered.first?.status == .idle)
    #expect(recovered.first?.stateGeneration == completed.stateGeneration)
}

@Test func closingAPaneRemovesItsAttentionState() throws {
    var tracker = AttentionTracker()
    _ = tracker.update(try snapshot(status: "working"))
    _ = tracker.update(try snapshot(status: "idle"))
    let empty = try JSONDecoder().decode(SessionSnapshot.self, from:
        Data(#"{"version":"test","agents":[],"workspaces":[],"tabs":[]}"#.utf8))
    #expect(tracker.update(empty).isEmpty)
    #expect(tracker.update(try snapshot(status: "idle")).first?.status == .idle)
}

@Test func unknownFutureStatesDoNotBreakTheList() throws {
    var tracker = AttentionTracker()
    let rows = tracker.update(try snapshot(status: "a_future_state"))
    #expect(rows.first?.status == .unknown)
    #expect(AgentSummary(rows: rows).unknown == 1)
}

@Test func workspaceAndTabLabelsMatchHerdr() throws {
    var tracker = AttentionTracker()
    let row = try #require(tracker.update(try snapshot(status: "working")).first)
    #expect(row.workspace == "remakan")
    #expect(row.tab == "orchestrator")
    #expect(row.kind == "codex")
}

@Test func attentionSortingKeepsWorkspaceOrderWithinEachState() throws {
    var tracker = AttentionTracker()
    let info = try #require(tracker.update(try snapshot(status: "working")).first?.info)
    func row(_ name: String, _ status: AgentStatus, _ order: Int) -> AgentRow {
        AgentRow(info: info, workspace: name, tab: "1", workspaceOrder: order, tabOrder: 1, status: status)
    }
    let rows = [row("idle", .idle, 1), row("run", .working, 2), row("done", .done, 3),
                row("blocked2", .blocked, 5), row("blocked1", .blocked, 4)]
    #expect(AgentOrder.grouped.sorted(rows).map(\.workspace) == ["idle", "run", "done", "blocked1", "blocked2"])
    #expect(AgentOrder.attention.sorted(rows).map(\.workspace) == ["blocked1", "blocked2", "done", "run", "idle"])
}

@Test func socketResolutionHonorsOverridesAndNamedSessions() {
    let home = URL(fileURLWithPath: "/Users/test")
    #expect(SocketLocation.resolve(environment: [:], home: home) == "/Users/test/.config/herdr/herdr.sock")
    #expect(SocketLocation.resolve(environment: ["HERDR_SESSION": "work"], home: home)
            == "/Users/test/.config/herdr/sessions/work/herdr.sock")
    #expect(SocketLocation.resolve(environment: ["HERDR_SOCKET_PATH": "/tmp/custom.sock", "HERDR_SESSION": "work"], home: home)
            == "/tmp/custom.sock")
    #expect(SocketLocation.resolve(environment: ["HERDR_CONFIG_PATH": "/tmp/config/config.toml"], home: home)
            == "/tmp/config/herdr.sock")
}

private func snapshot(status: String, terminal: String = "term1", sequence: UInt64? = 0,
                      focused: Bool = false, session: String = "session1", pane: String = "w1:p1") throws -> SessionSnapshot {
    var agent: [String: Any] = ["pane_id": pane, "terminal_id": terminal, "workspace_id": "w1",
                                "tab_id": "w1:t1", "agent": "codex", "agent_status": status,
                                "agent_session": ["kind": "id", "value": session], "focused": focused]
    agent["state_change_seq"] = sequence
    let json: [String: Any] = [
        "version": "0.9.1",
        "agents": [agent],
        "workspaces": [["workspace_id": "w1", "label": "remakan", "number": 1]],
        "tabs": [["tab_id": "w1:t1", "label": "orchestrator", "number": 1]],
    ]
    return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
}
