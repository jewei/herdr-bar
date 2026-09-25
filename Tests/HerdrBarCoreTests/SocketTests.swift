import Darwin
import Foundation
import Testing
@testable import HerdrBarCore

@Test func readsFragmentedSocketResponses() async throws {
    let server = try TestSocketServer { request in
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        #expect(object["method"] as? String == "session.snapshot")
        let data = try JSONSerialization.data(withJSONObject: [
            "id": object["id"]!,
            "result": ["snapshot": ["version": "test", "agents": [], "workspaces": [], "tabs": []]],
        ]) + Data([10])
        return [Data(data.prefix(7)), Data(data.dropFirst(7))]
    }
    defer { server.stop() }
    let snapshot = try await HerdrClient(socketPath: server.path).snapshot()
    #expect(snapshot.version == "test")
    #expect(snapshot.agents.isEmpty)
}

@Test func oversizedResponsesAreRejected() async throws {
    let server = try TestSocketServer { _ in [Data(repeating: 32, count: 9 * 1_024 * 1_024)] }
    defer { server.stop() }
    do {
        _ = try await HerdrClient(socketPath: server.path).snapshot()
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
        return [try JSONSerialization.data(withJSONObject: ["id": object["id"]!, "result": ["type": "ok"]]) + Data([10])]
    }
    defer { server.stop() }
    try await HerdrClient(socketPath: server.path).focus(paneID: "w12:p3")
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
            #"{"id":"\#(object["id"]!)","result":{"type":"subscription_started"}}"#,
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

/// A single-request local server. Each test owns its socket and file descriptor.
private final class TestSocketServer: Sendable {
    let path: String
    let fd: Int32
    /// Signals when the client closes the connection during `linger`.
    let clientClosed = DispatchSemaphore(value: 0)

    /// `linger` keeps the connection open after the last chunk, in microseconds.
    init(linger: useconds_t = 0, handler: @escaping @Sendable (Data) throws -> [Data]) throws {
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
        DispatchQueue.global().async {
            var pollFD = pollfd(fd: listeningFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 2_000) > 0 else { return }
            let client = accept(listeningFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request = Data()
            while !request.contains(10) {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { return }
                request.append(contentsOf: buffer.prefix(count))
            }
            do {
                for chunk in try handler(request) {
                    _ = chunk.withUnsafeBytes { send(client, $0.baseAddress, chunk.count, 0) }
                    usleep(2_000)
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
