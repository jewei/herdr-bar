import Foundation

public struct HerdrClient: Sendable {
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
