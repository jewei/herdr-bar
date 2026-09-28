// Read-only counters for an explicitly selected app and server. No socket access,
// process control, privilege changes, or collection of command lines/session data.
// Compile: swiftc -O -parse-as-library scripts/profile-processes.swift -o /tmp/herdr-process-profile
// Run: /tmp/herdr-process-profile APP_PID SERVER_PID [SECONDS]
import Darwin
import Foundation

@main enum ProcessProfile {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func read(_ pid: Int32) -> rusage_info_v2 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { fail("Cannot read process \(pid): \(String(cString: strerror(errno)))") }
        return usage
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard (3...4).contains(args.count),
              let app = Int32(args[1]), app > 0,
              let server = Int32(args[2]), server > 0, app != server,
              let seconds = Int(args.count == 4 ? args[3] : "30"), (1...3_600).contains(seconds) else {
            fail("Usage: profile-processes APP_PID SERVER_PID [SECONDS, 1...3600]")
        }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            fail("Cannot read the Mach clock conversion")
        }
        let nanosecondsPerTick = Double(timebase.numer) / Double(timebase.denom)
        let pids = [app, server]
        let before = pids.map(read)
        var after = before
        var peakRSS = before.map(\.ri_resident_size)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<seconds {
            Thread.sleep(forTimeInterval: 1)
            after = pids.map(read)
            for index in pids.indices {
                guard before[index].ri_proc_start_abstime == after[index].ri_proc_start_abstime else {
                    fail("Process \(pids[index]) was replaced during measurement")
                }
                peakRSS[index] = max(peakRSS[index], after[index].ri_resident_size)
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let processes: [[String: Any]] = pids.indices.map { index in
            let first = before[index]
            let last = after[index]
            let cpuTicks = Double(last.ri_user_time - first.ri_user_time)
                + Double(last.ri_system_time - first.ri_system_time)
            let cpuNS = cpuTicks * nanosecondsPerTick
            return [
                "role": index == 0 ? "app" : "server", "pid": pids[index],
                "cpu_percent_one_core": cpuNS / (elapsed * 1e9) * 100,
                "interrupt_wakeups": last.ri_interrupt_wkups - first.ri_interrupt_wkups,
                "package_idle_wakeups": last.ri_pkg_idle_wkups - first.ri_pkg_idle_wkups,
                "resident_bytes_start": first.ri_resident_size,
                "resident_bytes_end": last.ri_resident_size,
                "resident_bytes_sampled_peak": peakRSS[index],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "elapsed_seconds": elapsed, "sample_interval_seconds": 1,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processes": processes,
        ], options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
