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
            lines = transport.lines(data)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var started = false
                    for try await line in lines {
                        if started {
                            if let event = HerdrEvent(line: line) { continuation.yield(event) }
                            continue
                        }
                        // Herdr can reply to a failed subscription with a different ID.
                        guard let reply = try? JSONDecoder().decode(Response<StartResult>.self, from: line)
                        else { throw HerdrError.invalidResponse }
                        if let error = reply.error { throw HerdrError.server(error.message) }
                        guard reply.id == id, reply.result != nil else { throw HerdrError.invalidResponse }
                        started = true
                        continuation.yield(.subscribed)
                    }
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

    /// Title changes (`pane.updated`) are not included, because they can occur many times each second.
    static let layoutTypes = [
        "pane.created", "pane.closed", "pane.exited", "pane.moved", "pane.agent_detected",
        "tab.created", "tab.closed", "tab.renamed", "tab.moved",
        "workspace.created", "workspace.closed", "workspace.renamed", "workspace.moved", "workspace.reordered",
    ]

    init?(line: Data) {
        struct Envelope: Decodable {
            let event: String
            let data: Body?
        }
        struct Body: Decodable {
            let paneID: String?
            let agentStatus: AgentStatus?
            enum CodingKeys: String, CodingKey { case paneID = "pane_id", agentStatus = "agent_status" }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return nil }
        if envelope.event == "pane.agent_status_changed" {
            guard let paneID = envelope.data?.paneID, let status = envelope.data?.agentStatus else { return nil }
            self = .agentStatus(paneID: paneID, status: status)
        } else {
            self = .layoutChanged
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
