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

/// A single-request local server. Each test owns its socket and file descriptor.
private final class TestSocketServer: Sendable {
    let path: String
    let fd: Int32

    init(handler: @escaping @Sendable (Data) throws -> [Data]) throws {
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
            } catch { Issue.record(error) }
        }
    }

    func stop() { close(fd); unlink(path) }
}
