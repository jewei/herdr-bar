import Darwin
import Foundation

/// Finds the Herdr client processes that show a session. A client runs inside a terminal,
/// so its parent processes lead to the terminal application.
public enum ClientProcess {
    /// Returns the IDs of client processes that connect to the given server socket.
    public static func find(socketPath: String) -> [pid_t] {
        let target = normalized(socketPath)
        return allProcessIDs().filter { pid in
            guard executableName(pid) == "herdr", let (arguments, environment) = argumentsAndEnvironment(pid),
                  let path = self.socketPath(arguments: arguments, environment: environment) else { return false }
            return normalized(path) == target
        }
    }

    /// Uses `sysctl`, because `proc_pidinfo` fails for root processes such as `login`.
    public static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// Returns the server socket of a client process, or nil when the process is not a client.
    /// Clients start as `herdr`, `herdr --session NAME`, or `herdr session attach NAME`.
    /// Commands such as `herdr server` or `herdr agent list` are not clients.
    public static func socketPath(arguments: [String], environment: [String: String],
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        var environment = environment
        let options = Array(arguments.dropFirst())
        if options.count == 3, options[0] == "session", options[1] == "attach" {
            environment["HERDR_SESSION"] = options[2]
        } else if options.count == 2, options[0] == "--session" {
            environment["HERDR_SESSION"] = options[1]
        } else if options.count == 1, options[0].hasPrefix("--session=") {
            environment["HERDR_SESSION"] = String(options[0].dropFirst("--session=".count))
        } else if !options.isEmpty {
            return nil
        }
        // A client that runs inside a Herdr pane inherits the pane's socket variable.
        // The client itself does not use it, so remove it before resolving the path.
        environment["HERDR_SOCKET_PATH"] = nil
        return SocketLocation.resolve(environment: environment, home: home)
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func allProcessIDs() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private static func executableName(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)), as: UTF8.self)).lastPathComponent
    }

    /// Reads `KERN_PROCARGS2`: the argument count, the executable path, the arguments,
    /// and then the environment. Each string ends with a zero byte.
    private static func argumentsAndEnvironment(_ pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the zero bytes that pad it.
        while index < size, bytes[index] != 0 { index += 1 }
        while index < size, bytes[index] == 0 { index += 1 }
        var strings: [String] = []
        var start = index
        while index < size {
            if bytes[index] == 0 {
                strings.append(String(decoding: bytes[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        guard strings.count >= count else { return nil }
        let arguments = Array(strings.prefix(count))
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(count) {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return (arguments, environment)
    }
}
