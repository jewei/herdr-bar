import Darwin
import Foundation
import Testing
@testable import HerdrBarCore

private let invalidSuccessResults = [
    #"{"type":"pong"}"#, #"{}"#, #"{"accepted":true}"#,
    #"{"type":17}"#, #"{"type":null}"#, #"[]"#, #"null"#,
]

@Test func readsFragmentedSocketResponses() async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        #expect(object["method"] as? String == "session.snapshot")
        let data = try JSONSerialization.data(withJSONObject: [
            "id": object["id"]!,
            "result": ["type": "session_snapshot", "future_metadata": ["revision": 2],
                       "snapshot": ["version": "test", "agents": [], "workspaces": [], "tabs": []]],
        ]) + Data([10])
        return [Data(data.prefix(7)), Data(data.dropFirst(7))]
    }
    defer { server.stop() }
    let snapshot = try await HerdrClient(socketPath: server.path).snapshot()
    #expect(snapshot.version == "test")
    #expect(snapshot.agents.isEmpty)
}

@Test func oversizedResponsesAreRejected() async throws {
    let limit = 32_768
    let server = try TestSocketServer { _ in [Data(repeating: 32, count: limit + 1)] }
    defer { server.stop() }
    do {
        _ = try await SocketTransport(path: server.path).exchange(Data("request\n".utf8), maximumLine: limit)
        Issue.record("Expected a response size error")
    } catch HerdrError.responseTooLarge {}
}

@Test func bytesAfterTheFirstNewlineAreIgnored() async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "ok"]])
        return [data + Data("\nnot json\n".utf8)]
    }
    defer { server.stop() }
    try await HerdrClient(socketPath: server.path).focus(paneID: "w1:p1")
}

@Test func focusSendsOnlyTheSelectedPaneID() async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        #expect(object["method"] as? String == "agent.focus")
        #expect(object["params"] as? [String: String] == ["target": "w12:p3"])
        return [try JSONSerialization.data(withJSONObject: [
            "id": object["id"]!, "future_envelope": true,
            "result": ["type": "ok", "future_metadata": ["revision": 2]],
        ]) + Data([10])]
    }
    defer { server.stop() }
    try await HerdrClient(socketPath: server.path).focus(paneID: "w12:p3")
}

@Test(arguments: invalidSuccessResults)
func focusRejectsInvalidSuccessVariants(result: String) async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        return [Data(#"{"id":"\#(object["id"]!)","result":\#(result)}"#.utf8) + Data([10])]
    }
    defer { server.stop() }
    do {
        try await HerdrClient(socketPath: server.path).focus(paneID: "w1:p1")
        Issue.record("An invalid success variant must not complete the focus action")
    } catch HerdrError.invalidResponse {}
}

@Test(arguments: invalidSuccessResults)
func snapshotsRejectInvalidSuccessVariants(result: String) async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        var payload = try JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed])
        if var fields = payload as? [String: Any] {
            // A valid snapshot body must not make the wrong result variant valid.
            fields["snapshot"] = ["version": "test", "agents": [], "workspaces": [], "tabs": []]
            payload = fields
        }
        return [try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": payload]) + Data([10])]
    }
    defer { server.stop() }
    do {
        _ = try await HerdrClient(socketPath: server.path).snapshot()
        Issue.record("An invalid success variant must not supply a snapshot")
    } catch HerdrError.invalidResponse {}
}

@Test func serverErrorsAreReported() async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        return [try JSONSerialization.data(withJSONObject: [
            "id": object["id"]!, "error": ["code": "not_found", "message": "Agent has closed."],
        ]) + Data([10])]
    }
    defer { server.stop() }
    do {
        try await HerdrClient(socketPath: server.path).focus(paneID: "gone")
        Issue.record("Expected a server error")
    } catch HerdrError.server(let message) {
        #expect(message == "Agent has closed.")
    }
}

@Test func mismatchedResponseIDsAreRejected() async throws {
    let server = try TestSocketServer { _ in [Data(#"{"id":"wrong","result":{"type":"ok"}}"#.utf8) + Data([10])] }
    defer { server.stop() }
    do {
        try await HerdrClient(socketPath: server.path).focus(paneID: "w1:p1")
        Issue.record("Expected an invalid response error")
    } catch HerdrError.invalidResponse {}
}

@Test func malformedJSONIsRejected() async throws {
    let server = try TestSocketServer { _ in [Data("not json\n".utf8)] }
    defer { server.stop() }
    do {
        _ = try await HerdrClient(socketPath: server.path).snapshot()
        Issue.record("Expected an invalid response error")
    } catch HerdrError.invalidResponse {}
}

@Test func unresponsiveServerHasABoundedTimeout() async throws {
    let server = try TestSocketServer { _ in usleep(150_000); return [] }
    defer { server.stop() }
    do {
        _ = try await HerdrClient(socketPath: server.path, timeout: 0.03).snapshot()
        Issue.record("Expected a timeout")
    } catch HerdrError.timeout {}
}

@Test func closedConnectionDoesNotWaitForTheFullTimeout() async throws {
    let server = try TestSocketServer { _ in [] }
    defer { server.stop() }
    do {
        _ = try await HerdrClient(socketPath: server.path).snapshot()
        Issue.record("Expected an invalid response error")
    } catch HerdrError.invalidResponse {}
}

@Test func missingSocketReportsConnectionFailure() async throws {
    do {
        _ = try await HerdrClient(socketPath: "/tmp/herdr-bar-\(UUID().uuidString).sock").snapshot()
        Issue.record("Expected a connection failure")
    } catch HerdrError.unavailable {}
}

@Test func excessiveSocketPathsAreRejectedBeforeConnecting() async throws {
    do {
        _ = try await HerdrClient(socketPath: "/" + String(repeating: "x", count: 200)).snapshot()
        Issue.record("Expected an invalid path error")
    } catch HerdrError.unavailable(let message) {
        #expect(message.contains("too long"))
    }
}

@Test func eventStreamsReportTheSubscriptionAndEachEvent() async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        #expect(object["method"] as? String == "events.subscribe")
        let subscriptions = (object["params"] as! [String: Any])["subscriptions"] as! [[String: String]]
        #expect(subscriptions.contains(["type": "pane.agent_status_changed", "pane_id": "w1:p1"]))
        #expect(subscriptions.contains(["type": "pane.created"]))
        let lines = [
            #"{"id":"\#(object["id"]!)","future_envelope":true,"result":{"type":"subscription_started","future_metadata":{"revision":2}}}"#,
            #"{"data":{"agent_status":"working","pane_id":"w1:p1","workspace_id":"w1"},"event":"pane.agent_status_changed"}"#,
            #"{"data":{"agent_status":"idle","pane_id":"w1:p1","workspace_id":"w1"},"event":"pane.agent_status_changed"}"#,
            #"{"data":{"pane_id":"w1:p2","type":"pane_closed","workspace_id":"w1"},"event":"pane_closed"}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        // Split inside a line to test how lines join across reads.
        return [data.prefix(90), data.dropFirst(90)]
    }
    defer { server.stop() }
    var events: [HerdrEvent] = []
    for try await event in HerdrClient(socketPath: server.path).events(paneIDs: ["w1:p1"]) {
        events.append(event)
    }
    #expect(events == [.subscribed, .agentStatus(paneID: "w1:p1", status: .working),
                       .agentStatus(paneID: "w1:p1", status: .idle), .layoutChanged])
}

@Test(arguments: invalidSuccessResults)
func subscriptionsRejectInvalidSuccessVariantsBeforeBecomingLive(result: String) async throws {
    let server = try TestSocketServer(linger: 3_000_000) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        return [Data(#"{"id":"\#(object["id"]!)","result":\#(result)}"#.utf8) + Data([10]),
                Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"done"}}"#.utf8) + Data([10])]
    }
    defer { server.stop() }
    var events: [HerdrEvent] = []
    do {
        for try await event in HerdrClient(socketPath: server.path).events(paneIDs: ["w1:p1"]) {
            events.append(event)
        }
        Issue.record("An invalid success variant must fail the subscription")
    } catch HerdrError.invalidResponse {}
    #expect(events.isEmpty)
    #expect(await signalled(server.clientClosed))
}

@Test func failedSubscriptionsReportTheServerError() async throws {
    let server = try TestSocketServer { _ in
        [Data(#"{"id":"x:sub:0:probe","error":{"code":"pane_not_found","message":"pane w9:p9 not found"}}"#.utf8) + Data([10])]
    }
    defer { server.stop() }
    do {
        for try await _ in HerdrClient(socketPath: server.path).events(paneIDs: ["w9:p9"]) {}
        Issue.record("Expected a server error")
    } catch HerdrError.server(let message) {
        #expect(message == "pane w9:p9 not found")
    }
}

@Test(arguments: [
    "not JSON", "{}", "[]", #"{"event":17}"#, #"{"event":" "}"#,
    #"{"event":"pane.agent_status_changed"}"#,
    #"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1"}}"#,
    #"{"event":"pane.agent_status_changed","data":{"pane_id":"","agent_status":"idle"}}"#,
    #"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","agent_status":17}}"#,
])
func malformedEventEndsTheStreamInsteadOfSkippingATransition(line: String) async throws {
    let server = try TestSocketServer(linger: 3_000_000) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let acknowledgement = try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]])
        return [acknowledgement + Data([10]),
                Data("{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"w1:p1\",\"agent_status\":\"working\"}}\n".utf8),
                Data((line + "\n").utf8),
                Data("{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"w1:p1\",\"agent_status\":\"idle\"}}\n".utf8)]
    }
    defer { server.stop() }
    var events: [HerdrEvent] = []
    do {
        for try await event in HerdrClient(socketPath: server.path).events(paneIDs: ["w1:p1"]) {
            events.append(event)
        }
        Issue.record("Expected malformed event to fail the subscription")
    } catch HerdrError.invalidResponse {}
    #expect(events == [.subscribed, .agentStatus(paneID: "w1:p1", status: .working)])
    #expect(await signalled(server.clientClosed))
}

@Test func futureEventsAndStatusesDoNotBreakForwardCompatibility() async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        return [try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]]) + Data([10]),
                Data("{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"w1:p1\",\"agent_status\":\"future_state\"}}\n".utf8),
                Data("{\"event\":\"workspace.future_event\",\"data\":[1,2,3]}\n".utf8),
                Data("{\"event\":\"pane.moved\",\"data\":{\"agent_status\":17}}\n".utf8)]
    }
    defer { server.stop() }
    var events: [HerdrEvent] = []
    for try await event in HerdrClient(socketPath: server.path).events(paneIDs: ["w1:p1"]) {
        events.append(event)
    }
    #expect(events == [.subscribed, .agentStatus(paneID: "w1:p1", status: .unknown), .layoutChanged])
}

@Test func unknownEventsDoNotInterruptAWorkTransition() async throws {
    let server = try TestSocketServer(chunkDelay: 0) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        var data = try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]]) + Data([10])
        data.append(Data("{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"w1:p1\",\"agent_status\":\"working\"}}\n".utf8))
        for _ in 0..<64 { data.append(Data("{\"event\":\"workspace.future_event\"}\n".utf8)) }
        data.append(Data("{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"w1:p1\",\"agent_status\":\"idle\"}}\n".utf8))
        return [data]
    }
    defer { server.stop() }
    var events: [HerdrEvent] = []
    for try await event in HerdrClient(socketPath: server.path).events(paneIDs: ["w1:p1"]) { events.append(event) }
    #expect(events == [.subscribed, .agentStatus(paneID: "w1:p1", status: .working),
                       .agentStatus(paneID: "w1:p1", status: .idle)])
}

@Test func stoppingAnEventStreamClosesTheConnection() async throws {
    let server = try TestSocketServer(linger: 3_000_000) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        return [try JSONSerialization.data(withJSONObject: [
            "id": object["id"]!, "result": ["type": "subscription_started"],
        ]) + Data([10])]
    }
    defer { server.stop() }
    for try await event in HerdrClient(socketPath: server.path).events(paneIDs: []) {
        #expect(event == .subscribed)
        break
    }
    let closed = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: server.clientClosed.wait(timeout: .now() + 1) == .success)
        }
    }
    #expect(closed)
}

@Test(arguments: [-1, 0, 1])
func newlineTerminatedResponsesEnforceTheExactBoundary(extraBytes: Int) async throws {
    let limit = 32_768
    let size = limit + extraBytes
    let server = try TestSocketServer { _ in [Data(repeating: 65, count: size) + Data([10])] }
    defer { server.stop() }
    do {
        let response = try await SocketTransport(path: server.path).exchange(Data("request\n".utf8), maximumLine: limit)
        #expect(extraBytes <= 0)
        #expect(response.count == size)
    } catch HerdrError.responseTooLarge {
        #expect(extraBytes > 0)
    }
}

@Test(arguments: [-1, 0, 1])
func newlineTerminatedStreamLinesEnforceTheExactBoundary(extraBytes: Int) async throws {
    let limit = 32_768
    let size = limit + extraBytes
    let server = try TestSocketServer { _ in
        // Keep the newline in the final fragment, including the byte that crosses the limit.
        [Data(repeating: 65, count: limit - 1),
         Data(repeating: 65, count: extraBytes + 1) + Data([10])]
    }
    defer { server.stop() }
    var count = 0
    do {
        for try await line in SocketTransport(path: server.path).lines(
            Data("request\n".utf8), firstLineTimeout: nil, maximumLine: limit) {
            count += 1
            #expect(line.count == size)
        }
        #expect(extraBytes <= 0)
        #expect(count == 1)
    } catch HerdrError.responseTooLarge {
        #expect(extraBytes > 0)
        #expect(count == 0)
    }
}

@Test(arguments: [false, true])
func subscriptionWithoutAcknowledgementTimesOutAndCloses(partialReply: Bool) async throws {
    let server = try TestSocketServer(linger: 3_000_000) { _ in
        // Neither silence nor partial replies may disable the handshake deadline.
        partialReply ? [Data(#"{"id":"unfinished"#.utf8)] : []
    }
    defer { server.stop() }
    do {
        for try await _ in HerdrClient(socketPath: server.path, timeout: 0.05).events(paneIDs: []) {}
        Issue.record("Expected a subscription acknowledgement timeout")
    } catch HerdrError.timeout {}
    #expect(await signalled(server.clientClosed))
}

@Test func establishedSubscriptionCanRemainQuietPastTheHandshakeTimeout() async throws {
    let server = try TestSocketServer(chunkDelay: 300_000) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        return [try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]]) + Data([10]),
                Data("{\"event\":\"pane.created\"}\n".utf8)]
    }
    defer { server.stop() }
    let start = ContinuousClock.now
    var events: [HerdrEvent] = []
    for try await event in HerdrClient(socketPath: server.path, timeout: 0.1).events(paneIDs: []) {
        events.append(event)
    }
    #expect(events == [.subscribed, .layoutChanged])
    #expect(start.duration(to: .now) >= .milliseconds(250))
}

@Test func subscriptionClosedBeforeAcknowledgementIsInvalid() async throws {
    let server = try TestSocketServer { _ in [] }
    defer { server.stop() }
    do {
        for try await _ in HerdrClient(socketPath: server.path).events(paneIDs: []) {}
        Issue.record("Expected an invalid response")
    } catch HerdrError.invalidResponse {}
}

@Test func slowLineConsumerGetsAnExplicitOverflowAndSocketClosure() async throws {
    let server = try TestSocketServer(linger: 3_000_000) { _ in
        [Data(repeating: 10, count: SocketTransport.maximumBufferedLines + 1)]
    }
    defer { server.stop() }
    let stream = SocketTransport(path: server.path).lines(Data("request\n".utf8))
    // Do not drain until the producer has exhausted its buffer and closed the connection.
    #expect(await signalled(server.clientClosed))
    var received = 0
    do {
        for try await _ in stream { received += 1 }
        Issue.record("Expected a line buffer overflow")
    } catch HerdrError.streamOverflow {}
    #expect(received == SocketTransport.maximumBufferedLines)
}

@Test func slowEventConsumerGetsAnExplicitOverflowAndSocketClosure() async throws {
    let decodedLimit = 4
    let server = try TestSocketServer(linger: 3_000_000, chunkDelay: 0) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let acknowledgement = try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]])
        // Five frames fit the wire queue, but overflow the four-element decoded queue.
        let events = String(repeating: "{\"event\":\"pane.created\"}\n", count: decodedLimit)
        return [acknowledgement + Data([10]) + Data(events.utf8)]
    }
    defer { server.stop() }
    let stream = HerdrClient(socketPath: server.path).events(paneIDs: [], maximumBufferedEvents: decodedLimit)
    try #require(await signalled(server.clientClosed, timeout: 2))
    var received = 0
    do {
        for try await _ in stream { received += 1 }
        Issue.record("Expected an event buffer overflow")
    } catch HerdrError.streamOverflow {}
    #expect(received == decodedLimit)
}

@Test func cancellingAQuietLineConsumerClosesTheSocket() async throws {
    let server = try TestSocketServer(linger: 3_000_000) { _ in [] }
    defer { server.stop() }
    let stream = SocketTransport(path: server.path).lines(Data("request\n".utf8))
    let task = Task { for try await _ in stream {} }
    #expect(await signalled(server.requestReceived))
    task.cancel()
    _ = try await task.value
    #expect(await signalled(server.clientClosed))
}

@Test func cancellingAOneShotRequestClosesTheSocketBeforeItsDeadline() async throws {
    let server = try TestSocketServer(linger: 6_000_000) { _ in [] }
    defer { server.stop() }
    let finished = DispatchSemaphore(value: 0)
    let task = Task {
        defer { finished.signal() }
        do {
            _ = try await SocketTransport(path: server.path, timeout: 5).exchange(Data("request\n".utf8))
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
    }
    defer { task.cancel() }
    try #require(await signalled(server.requestReceived))
    task.cancel()
    try #require(await signalled(finished))
    try await task.value
    #expect(await signalled(server.clientClosed))
}

@Test func anAlreadyCancelledRequestDoesNotConnect() async throws {
    let server = try TestSocketServer { _ in [] }
    defer { server.stop() }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try await SocketTransport(path: server.path).exchange(Data("request\n".utf8))
            Issue.record("Expected cancellation before connection")
        } catch is CancellationError {}
    }
    try await task.value
    #expect(!(await signalled(server.requestReceived, timeout: 0)))
}

@Test func aSingleWriteBurstOf64EventsPreservesEveryEventInOrder() async throws {
    let server = try TestSocketServer(chunkDelay: 0) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        var burst = try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]]) + Data([10])
        for index in 0..<64 {
            burst.append(Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p\#(index)","agent_status":"working"}}"#.utf8))
            burst.append(10)
        }
        // A single chunk, deliberately without sleeps or consumer scheduling between events.
        return [burst]
    }
    defer { server.stop() }
    var events: [HerdrEvent] = []
    for try await event in HerdrClient(socketPath: server.path).events(paneIDs: []) {
        events.append(event)
    }
    let expected: [HerdrEvent] = [.subscribed] + (0..<64).map {
        .agentStatus(paneID: "w1:p\($0)", status: .working)
    }
    #expect(events == expected)
}

@Test(arguments: [-1, 0, 1])
func subscriptionLinesHaveASmallerExactSizeLimit(extraBytes: Int) async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let acknowledgement = try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]])
        var event = Data("{\"event\":\"pane.created\"}".utf8)
        event.append(Data(repeating: 32, count: HerdrClient.maximumEventLine + extraBytes - event.count))
        event.append(10)
        return [acknowledgement + Data([10]), event]
    }
    defer { server.stop() }
    var events: [HerdrEvent] = []
    do {
        for try await event in HerdrClient(socketPath: server.path).events(paneIDs: []) {
            events.append(event)
        }
        #expect(extraBytes <= 0)
        #expect(events == [.subscribed, .layoutChanged])
    } catch HerdrError.responseTooLarge {
        #expect(extraBytes > 0)
        #expect(events == [.subscribed])
    }
}

@Test func cancellingDuringSustainedEventTrafficClosesTheSocketPromptly() async throws {
    let server = try TestSocketServer(chunkDelay: 1_000, repeatLastChunkFor: 3) { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let acknowledgement = try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "subscription_started"]])
        return [acknowledgement + Data([10]), Data("{\"event\":\"pane.created\"}\n".utf8)]
    }
    defer { server.stop() }
    let trafficSeen = DispatchSemaphore(value: 0)
    let consumerFinished = DispatchSemaphore(value: 0)
    let task = Task {
        defer { consumerFinished.signal() }
        var count = 0
        do {
            for try await event in HerdrClient(socketPath: server.path).events(paneIDs: []) {
                if event == .layoutChanged {
                    count += 1
                    if count == 32 { trafficSeen.signal() }
                }
            }
        } catch is CancellationError {
            #expect(Task.isCancelled)
        }
        return count
    }
    defer { task.cancel() }
    #expect(await signalled(trafficSeen))
    // The producer is still sending; neither EOF nor an idle receive drives this cancellation.
    task.cancel()
    try #require(await signalled(consumerFinished))
    #expect(try await task.value >= 32)
    #expect(await signalled(server.clientClosed))
}

private func signalled(_ semaphore: DispatchSemaphore, timeout: Double = 1) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

/// A single-request local server. Each test owns its socket and file descriptor.
private final class TestSocketServer: Sendable {
    let path: String
    let fd: Int32
    /// Signals when the client closes the connection during `linger`.
    let clientClosed = DispatchSemaphore(value: 0)
    let requestReceived = DispatchSemaphore(value: 0)

    /// `linger` keeps the connection open after the last chunk, in microseconds.
    init(linger: useconds_t = 0, chunkDelay: useconds_t = 2_000, repeatLastChunkFor: TimeInterval = 0,
         handler: @escaping @Sendable (Data) throws -> [Data]) throws {
        path = "/tmp/hb-\(UUID().uuidString).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.unavailable("Cannot create test socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            unlink(path)
            throw HerdrError.unavailable("Cannot bind test socket")
        }
        let listeningFD = fd
        let clientClosed = clientClosed
        let requestReceived = requestReceived
        DispatchQueue.global().async {
            var pollFD = pollfd(fd: listeningFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 2_000) > 0 else { return }
            let client = accept(listeningFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            // A failed test must not leave a worker blocked forever in send or recv.
            var ioTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request = Data()
            while !request.contains(10) {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { return }
                request.append(contentsOf: buffer.prefix(count))
            }
            requestReceived.signal()
            func writeChunk(_ chunk: Data) -> Bool {
                let deadline = ContinuousClock.now + .seconds(2)
                var sent = 0
                while sent < chunk.count {
                    guard ContinuousClock.now < deadline else { return false }
                    let count = chunk.withUnsafeBytes {
                        send(client, $0.baseAddress!.advanced(by: sent), chunk.count - sent, 0)
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        if errno == EPIPE || errno == ECONNRESET { clientClosed.signal() }
                        return false
                    }
                    sent += count
                }
                usleep(chunkDelay)
                return true
            }
            do {
                let chunks = try handler(request)
                for chunk in chunks {
                    guard writeChunk(chunk) else { return }
                }
                if repeatLastChunkFor > 0, let chunk = chunks.last {
                    let deadline = ContinuousClock.now + .seconds(repeatLastChunkFor)
                    while ContinuousClock.now < deadline {
                        guard writeChunk(chunk) else { return }
                    }
                }
                var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                if linger > 0, poll(&descriptor, 1, Int32(linger / 1_000)) > 0,
                   recv(client, &buffer, buffer.count, 0) == 0 {
                    clientClosed.signal()
                }
            } catch { Issue.record(error) }
        }
    }

    func stop() { close(fd); unlink(path) }
}
