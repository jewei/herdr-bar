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
    static let maximumLine = 8 * 1_024 * 1_024
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

    /// Sends one request on a connection that stays open, then returns each line that the server sends.
    /// The connect and the send have the usual timeout. The read has no timeout.
    /// The connection closes when the stream ends or when the consumer stops the iteration.
    public func lines(_ request: Data) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let reader = LineReader(continuation: continuation)
            continuation.onTermination = { _ in reader.cancel() }
            reader.start(transport: self, request: request)
        }
    }

    private func exchangeBlocking(_ request: Data) throws -> Data {
        let deadline = makeDeadline()
        let fd = try connectAndSend(request, deadline: deadline)
        defer { close(fd) }
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
            // Search only the new bytes, so large fragmented responses stay linear.
            let chunk = buffer[..<count]
            let end = chunk.firstIndex(of: 10) ?? count
            guard response.count + end <= Self.maximumLine else { throw HerdrError.responseTooLarge }
            response.append(contentsOf: chunk[..<end])
            if end < count { return response }
        }
    }

    func makeDeadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0.001, timeout) * 1_000_000_000)
    }

    /// Returns a non-blocking socket that has sent the full request. The caller must close it.
    func connectAndSend(_ request: Data, deadline: UInt64) throws -> Int32 {
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
        do {
            try connect(fd, to: &address, deadline: deadline)
            try send(request, to: fd, deadline: deadline)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func connect(_ fd: Int32, to address: inout sockaddr_un, deadline: UInt64) throws {
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw systemError() }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
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
    }

    private func send(_ request: Data, to fd: Int32, deadline: UInt64) throws {
        var sent = 0
        while sent < request.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = request.withUnsafeBytes { bytes in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw systemError()
            }
            guard count > 0 else { throw HerdrError.invalidResponse }
            sent += count
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

    func systemError(_ code: Int32 = errno) -> HerdrError {
        .unavailable(String(cString: strerror(code)))
    }
}

/// Reads lines from one long-lived connection. A dispatch source reports when data is ready,
/// so no thread waits while the connection is quiet.
/// All state belongs to `queue`. The descriptor closes only in the source's cancel handler.
private final class LineReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.herdrbar.events", qos: .utility)
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var source: DispatchSourceRead?
    private var cancelled = false
    private var pending = Data()

    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.continuation = continuation
    }

    func start(transport: SocketTransport, request: Data) {
        queue.async { [self] in
            guard !cancelled else { return }
            let fd: Int32
            do {
                fd = try transport.connectAndSend(request, deadline: transport.makeDeadline())
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd, transport: transport) }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            source?.cancel()
            source = nil
        }
    }

    private func read(_ fd: Int32, transport: SocketTransport) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while source != nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                return finish(transport.systemError())
            }
            guard count > 0 else { return finish(nil) }
            var start = 0
            while let newline = buffer[start..<count].firstIndex(of: 10) {
                pending.append(contentsOf: buffer[start..<newline])
                continuation.yield(pending)
                pending = Data()
                start = newline + 1
            }
            pending.append(contentsOf: buffer[start..<count])
            guard pending.count <= SocketTransport.maximumLine else {
                return finish(HerdrError.responseTooLarge)
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        continuation.finish(throwing: error)
        source?.cancel()
        source = nil
    }
}
