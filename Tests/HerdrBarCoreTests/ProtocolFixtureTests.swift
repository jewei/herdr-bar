import Darwin
import Foundation
import Testing
@testable import HerdrBarCore

/// Schema-derived synthetic examples, not recordings of a user's session.
@Suite struct ProtocolFixtureTests {
    private func resource(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func examples() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: resource("herdr-0.9.1-examples")) as? [String: Any])
    }

    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

    private struct SnapshotResponse: Decodable {
        struct Result: Decodable { let snapshot: SessionSnapshot }
        let result: Result
    }

    @Test func pinnedSnapshotsPreserveIdentityAcrossWorkspaceMove() throws {
        let fixtures = try examples()
        let before = try JSONDecoder().decode(SnapshotResponse.self,
            from: encode(try #require(fixtures["snapshot_before_move"]))).result.snapshot
        let after = try JSONDecoder().decode(SnapshotResponse.self,
            from: encode(try #require(fixtures["snapshot_after_move"]))).result.snapshot
        #expect(before.version == "0.9.1")
        #expect(after.version == before.version)
        let old = try #require(before.agents.first)
        let moved = try #require(after.agents.first)
        #expect(old.paneID == "w1:p1")
        #expect(moved.paneID == "w2:p1")
        #expect(old.workspaceID != moved.workspaceID)
        #expect(old.tabID != moved.tabID)
        #expect(old.terminalID == moved.terminalID)
        #expect(old.agentSession == moved.agentSession)
        #expect(AgentIdentity(old) == AgentIdentity(moved))
        #expect(old.agentStatus == .blocked)
        #expect(old.stateChangeSeq == 41)
        #expect(moved.stateChangeSeq == old.stateChangeSeq)
        #expect(old.title == nil)
        #expect(old.displayAgent == nil)
        #expect(moved.displayAgent == "Codex")
        #expect(after.workspaces.first?.label == "Destination")
        #expect(after.tabs.first?.label == "Review")

        let layouts = try #require(fixtures["layout_events"] as? [[String: Any]])
        let move = try #require(layouts.first?["data"] as? [String: Any])
        let pane = try #require(move["pane"] as? [String: Any])
        #expect(move["previous_pane_id"] as? String == old.paneID)
        #expect(move["previous_workspace_id"] as? String == old.workspaceID)
        #expect(move["previous_tab_id"] as? String == old.tabID)
        #expect(pane["pane_id"] as? String == moved.paneID)
        #expect(pane["terminal_id"] as? String == old.terminalID)
    }

    @Test func pinnedStatusAndLayoutPayloadsDecode() throws {
        let fixtures = try examples()
        let statuses = try #require(fixtures["status_events"] as? [[String: Any]])
        #expect(statuses.count == AgentStatus.allCases.count)
        for (payload, status) in zip(statuses, AgentStatus.allCases) {
            #expect(HerdrEvent(line: try encode(payload)) == .agentStatus(paneID: "w1:p1", status: status))
        }
        let layouts = try #require(fixtures["layout_events"] as? [[String: Any]])
        for payload in layouts {
            // Actual general-event names use underscores, unlike subscription selectors.
            #expect(HerdrEvent(line: try encode(payload)) == .layoutChanged)
        }
    }

    @Test func clientConsumesPinnedSnapshotSuccessVariant() async throws {
        let acknowledgement = try encode(try #require(examples()["snapshot_before_move"]))
        let server = try ProtocolFixtureSocket { requestData in
            let request = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            #expect(request["method"] as? String == "session.snapshot")
            var reply = try #require(JSONSerialization.jsonObject(with: acknowledgement) as? [String: Any])
            reply["id"] = request["id"]
            return try JSONSerialization.data(withJSONObject: reply) + Data([10])
        }
        defer { server.stop() }
        let snapshot = try await HerdrClient(socketPath: server.path).snapshot()
        #expect(snapshot.version == "0.9.1")
        #expect(snapshot.agents.first?.paneID == "w1:p1")
        #expect(snapshot.agents.first?.agentStatus == .blocked)
    }

    @Test func clientConsumesPinnedFocusSuccessVariant() async throws {
        // Herdr 0.9.1 handle_agent_focus returns AgentInfo, not Ok.
        let acknowledgement = try encode(try #require(examples()["focus_response"]))
        let server = try ProtocolFixtureSocket { requestData in
            let request = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            #expect(request["method"] as? String == "agent.focus")
            #expect(request["params"] as? [String: String] == ["target": "w1:p1"])
            var reply = try #require(JSONSerialization.jsonObject(with: acknowledgement) as? [String: Any])
            reply["id"] = request["id"]
            return try JSONSerialization.data(withJSONObject: reply) + Data([10])
        }
        defer { server.stop() }
        try await HerdrClient(socketPath: server.path).focus(paneID: "w1:p1")
    }

    @Test func additivePayloadChangesRemainCompatible() throws {
        // These mutations are forward-compatibility probes, not 0.9.1 schema examples.
        let bodies: [Any] = [NSNull(), 17, ["pane_id": 42, "agent_status": ["new": true]]]
        let names = HerdrEvent.layoutTypes + HerdrEvent.layoutTypes.map { $0.replacingOccurrences(of: ".", with: "_") }
            + ["pane_agent_status_changed", "layout.updated", "layout_updated"]
        for name in names {
            for body in bodies {
                #expect(HerdrEvent(line: try encode(["event": name, "data": body])) == .layoutChanged)
            }
        }
        for name in ["future.layout_event", "workspace.future_event", "pane.updated"] {
            for body in bodies {
                #expect(HerdrEvent(line: try encode(["event": name, "data": body])) == .ignored)
            }
        }
        #expect(HerdrEvent(line: Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"future_status"}}"#.utf8))
            == .agentStatus(paneID: "w1:p1", status: .unknown))
    }

    @Test func subscriptionSelectorsMatchPinnedSchema() throws {
        let document = try #require(JSONSerialization.jsonObject(
            with: resource("herdr-0.9.1-schema-excerpt")) as? [String: Any])
        let provenance = try #require(document["provenance"] as? [String: Any])
        #expect(provenance["herdr_version"] as? String == "0.9.1")
        #expect(provenance["protocol"] as? Int == 22)
        let excerpts = try #require(document["excerpts"] as? [String: Any])
        let schema = try #require(excerpts["#/schemas/request/$defs/Subscription"] as? [String: Any])
        let variants = try #require(schema["oneOf"] as? [[String: Any]])
        let request = try #require(examples()["subscribe_request"] as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let subscriptions = try #require(params["subscriptions"] as? [[String: String]])
        #expect(subscriptions.first == ["type": "pane.agent_status_changed", "pane_id": "w1:p1"])
        #expect(subscriptions.dropFirst().compactMap { $0["type"] } == HerdrEvent.layoutTypes)
        for subscription in subscriptions {
            let variant = try #require(variants.first {
                let properties = $0["properties"] as? [String: Any]
                return (properties?["type"] as? [String: Any])?["const"] as? String == subscription["type"]
            })
            let required = try #require(variant["required"] as? [String])
            #expect(Set(required).isSubset(of: Set(subscription.keys)))
            let properties = try #require(variant["properties"] as? [String: Any])
            for key in subscription.keys {
                let property = try #require(properties[key] as? [String: Any])
                #expect(property["type"] as? String == "string")
            }
        }
    }

    @Test func clientEmitsPinnedSubscriptionAndConsumesFixtureStream() async throws {
        let fixtures = try examples()
        let expectedRequest = try encode(try #require(fixtures["subscribe_request"]))
        let acknowledgement = try encode(try #require(fixtures["subscription_started"]))
        let statuses = try #require(fixtures["status_events"] as? [[String: Any]])
        let layouts = try #require(fixtures["layout_events"] as? [[String: Any]])
        let eventLines = try (statuses + layouts).map { try encode($0) + Data([10]) }
        let server = try ProtocolFixtureSocket { requestData in
            let request = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            var expected = try #require(JSONSerialization.jsonObject(with: expectedRequest) as? [String: Any])
            // Only the request correlation ID is generated at runtime.
            expected["id"] = request["id"]
            #expect(NSDictionary(dictionary: request).isEqual(to: expected))
            var reply = try #require(JSONSerialization.jsonObject(with: acknowledgement) as? [String: Any])
            reply["id"] = request["id"]
            return try JSONSerialization.data(withJSONObject: reply) + Data([10]) + eventLines.reduce(Data(), +)
        }
        defer { server.stop() }
        var received: [HerdrEvent] = []
        for try await event in HerdrClient(socketPath: server.path).events(paneIDs: ["w1:p1"]) {
            received.append(event)
        }
        #expect(received == [.subscribed] + AgentStatus.allCases.map {
            .agentStatus(paneID: "w1:p1", status: $0)
        } + Array(repeating: .layoutChanged, count: layouts.count))
    }
}

/// An isolated one-request fixture server; never connects to an installed Herdr session.
private final class ProtocolFixtureSocket: Sendable {
    let path: String
    private let fd: Int32

    init(reply: @escaping @Sendable (Data) throws -> Data) throws {
        path = "/tmp/hb-fixture-\(UUID().uuidString).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.unavailable("Fixture socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            unlink(path)
            throw HerdrError.unavailable("Fixture socket bind failed")
        }
        let listener = fd
        DispatchQueue.global().async {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 2_000) > 0 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains(10) {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0, request.count + count <= 64 * 1024 else { return }
                request.append(contentsOf: buffer.prefix(count))
            }
            do {
                let response = try reply(request)
                var sent = 0
                while sent < response.count {
                    let count = response.withUnsafeBytes {
                        send(client, $0.baseAddress!.advanced(by: sent), response.count - sent, 0)
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return }
                    sent += count
                }
            } catch { Issue.record(error) }
        }
    }

    func stop() { close(fd); unlink(path) }
}
