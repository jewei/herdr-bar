import Foundation

/// The Herdr requests that the app uses. Tests replace the client with a fake.
public protocol HerdrService: Sendable {
    var socketPath: String { get }
    func snapshot() async throws -> SessionSnapshot
    func focus(paneID: String) async throws
    func events(paneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, any Error>
}

public struct HerdrClient: HerdrService {
    public let socketPath: String
    private let transport: SocketTransport
    static let maximumBufferedEvents = 256
    // These subscriptions carry identifiers and status/layout notifications, not snapshots.
    // 64 KiB leaves generous metadata headroom while bounding 256 queued wire lines to 16 MiB.
    // Decoded events retain at most a pane identifier, so their buffer has the same byte ceiling.
    static let maximumEventLine = 64 * 1_024

    public init(socketPath: String = SocketLocation.resolve(), timeout: TimeInterval = 2) {
        self.socketPath = socketPath
        transport = SocketTransport(path: socketPath, timeout: timeout)
    }

    public func snapshot() async throws -> SessionSnapshot {
        let result: SnapshotResult = try await request("session.snapshot")
        return result.snapshot
    }

    public func focus(paneID: String) async throws {
        let _: EmptyResult = try await request("agent.focus", params: ["target": paneID])
    }

    /// Subscribes to agent status changes for the given panes and to layout changes.
    /// The first element is `.subscribed`. Herdr accepts one subscription on each connection,
    /// so a new set of panes needs a new stream.
    public func events(paneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, any Error> {
        let id = UUID().uuidString
        let subscriptions = paneIDs.map { Subscription(type: "pane.agent_status_changed", paneID: $0) }
            + HerdrEvent.layoutTypes.map { Subscription(type: $0, paneID: nil) }
        let lines: AsyncThrowingStream<Data, any Error>
        do {
            var data = try JSONEncoder().encode(SubscribeRequest(
                id: id, method: "events.subscribe", params: .init(subscriptions: subscriptions)))
            data.append(10)
            lines = transport.lines(data, firstLineTimeout: transport.timeout,
                                    maximumLine: Self.maximumEventLine,
                                    maximumBufferedLines: Self.maximumBufferedEvents)
        } catch {
            return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.maximumBufferedEvents)) {
                $0.finish(throwing: error)
            }
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.maximumBufferedEvents)) { continuation in
            let task = Task {
                do {
                    var started = false
                    for try await line in lines {
                        try Task.checkCancellation()
                        let event: HerdrEvent
                        if started {
                            // Skipping malformed status frames would silently lose work
                            // transitions. End the subscription so the store resynchronizes.
                            guard let parsed = HerdrEvent(line: line) else { throw HerdrError.invalidResponse }
                            if parsed == .ignored { continue }
                            event = parsed
                        } else {
                            // Herdr can reply to a failed subscription with a different ID.
                            guard let reply = try? JSONDecoder().decode(Response<StartResult>.self, from: line)
                            else { throw HerdrError.invalidResponse }
                            if let error = reply.error { throw HerdrError.server(error.message) }
                            guard reply.id == id, reply.result != nil else { throw HerdrError.invalidResponse }
                            started = true
                            event = .subscribed
                        }
                        switch continuation.yield(event) {
                        case .enqueued: break
                        case .dropped: throw HerdrError.streamOverflow
                        case .terminated: return
                        @unknown default: throw HerdrError.invalidResponse
                        }
                    }
                    guard started else { throw HerdrError.invalidResponse }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request<T: Decodable & Sendable>(_ method: String,
                                                 params: [String: String] = [:]) async throws -> T {
        let id = UUID().uuidString
        var data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        data.append(10)
        let response = try await transport.exchange(data)
        let envelope: Response<T>
        do {
            envelope = try JSONDecoder().decode(Response<T>.self, from: response)
        } catch {
            throw HerdrError.invalidResponse
        }
        guard envelope.id == id else { throw HerdrError.invalidResponse }
        if let error = envelope.error { throw HerdrError.server(error.message) }
        guard let result = envelope.result else { throw HerdrError.invalidResponse }
        return result
    }

    private struct Request: Encodable { let id: String; let method: String; let params: [String: String] }
    private struct Response<T: Decodable>: Decodable {
        let id: String?
        let result: T?
        let error: ErrorBody?
    }
    private struct ErrorBody: Decodable { let message: String }
    private struct SnapshotResult: Decodable, Sendable { let snapshot: SessionSnapshot }
    private struct EmptyResult: Decodable, Sendable {}
    private struct StartResult: Decodable, Sendable {}
    private struct Subscription: Encodable {
        let type: String
        let paneID: String?
        enum CodingKeys: String, CodingKey { case type, paneID = "pane_id" }
    }
    private struct SubscribeRequest: Encodable {
        struct Params: Encodable { let subscriptions: [Subscription] }
        let id: String
        let method: String
        let params: Params
    }
}

public enum HerdrEvent: Equatable, Sendable {
    /// Herdr accepted the subscription. Later changes arrive as events.
    case subscribed
    case agentStatus(paneID: String, status: AgentStatus)
    /// A pane, tab, or workspace changed. A new snapshot shows the change.
    case layoutChanged
    /// A valid event that does not change the state this client uses.
    case ignored

    /// Title changes (`pane.updated`) are not included, because they can occur many times each second.
    static let layoutTypes = [
        "pane.created", "pane.closed", "pane.exited", "pane.moved", "pane.agent_detected",
        "tab.created", "tab.closed", "tab.renamed", "tab.moved",
        "workspace.created", "workspace.closed", "workspace.renamed", "workspace.moved", "workspace.reordered",
    ]
    private static let layoutNames = Set(layoutTypes + layoutTypes.map { $0.replacingOccurrences(of: ".", with: "_") }
        // Keep the prior snapshot fallback for known general status/layout events.
        + ["pane_agent_status_changed", "layout.updated", "layout_updated"])

    init?(line: Data) {
        struct Header: Decodable { let event: String }
        struct StatusEvent: Decodable {
            struct Body: Decodable {
                let paneID: String
                let agentStatus: AgentStatus
                enum CodingKeys: String, CodingKey { case paneID = "pane_id", agentStatus = "agent_status" }
            }
            let data: Body
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: line),
              !header.event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if header.event == "pane.agent_status_changed" {
            guard let event = try? decoder.decode(StatusEvent.self, from: line),
                  !event.data.paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .agentStatus(paneID: event.data.paneID, status: event.data.agentStatus)
        } else if Self.layoutNames.contains(header.event) {
            // Layout payloads vary by event and are replaced by a snapshot anyway.
            self = .layoutChanged
        } else {
            // Unknown events must not suppress valid status transitions or force snapshots.
            self = .ignored
        }
    }
}

public enum SocketLocation {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let path = environment["HERDR_SOCKET_PATH"], !path.isEmpty { return path }
        let configDirectory: URL
        if let config = environment["HERDR_CONFIG_PATH"], !config.isEmpty {
            configDirectory = URL(fileURLWithPath: config).deletingLastPathComponent()
        } else {
            configDirectory = home.appendingPathComponent(".config/herdr", isDirectory: true)
        }
        if let session = environment["HERDR_SESSION"], !session.isEmpty {
            return configDirectory.appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(session, isDirectory: true)
                .appendingPathComponent("herdr.sock").path
        }
        return configDirectory.appendingPathComponent("herdr.sock").path
    }
}
