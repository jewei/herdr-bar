import Darwin
import Foundation

public enum HerdrError: LocalizedError, Sendable {
    case unavailable(String)
    case timeout
    case invalidResponse
    case responseTooLarge
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Cannot connect to Herdr. \(reason)"
        case .timeout: "Herdr did not reply in time."
        case .invalidResponse: "Herdr sent an invalid response."
        case .responseTooLarge: "The Herdr response is too large."
        case .server(let message): message
        }
    }
}

/// One bounded request per connection. Socket work never runs on the main thread.
public struct SocketTransport: Sendable {
    public let path: String
    public let timeout: TimeInterval
    private static let queue = DispatchQueue(label: "dev.herdrbar.socket", qos: .utility,
                                             attributes: .concurrent)

    public init(path: String, timeout: TimeInterval = 2) {
        self.path = path
        self.timeout = timeout
    }

    public func exchange(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try self.exchangeBlocking(request) })
            }
        }
    }

    private func exchangeBlocking(_ request: Data) throws -> Data {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8) + [0]
        guard !path.utf8.contains(0), pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw HerdrError.unavailable("The socket path is invalid or too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd) }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw systemError() }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.001, timeout) * 1_000_000_000)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw systemError() }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw systemError() }
            guard error == 0 else { throw systemError(error) }
        }

        var sent = 0
        while sent < request.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = request.withUnsafeBytes { bytes in
                send(fd, bytes.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw systemError()
            }
            guard count > 0 else { throw HerdrError.invalidResponse }
            sent += count
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw systemError()
            }
            guard count > 0 else { throw HerdrError.invalidResponse }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 8 * 1_024 * 1_024 else { throw HerdrError.responseTooLarge }
            if let newline = response.firstIndex(of: 10) { return Data(response[..<newline]) }
        }
    }

    private func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw HerdrError.timeout }
            let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 { return }
            if result == 0 { throw HerdrError.timeout }
            if errno != EINTR { throw systemError() }
        }
    }

    private func systemError(_ code: Int32 = errno) -> HerdrError {
        .unavailable(String(cString: strerror(code)))
    }
}
