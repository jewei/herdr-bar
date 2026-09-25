// Read-only benchmark; never focuses a terminal or connects to the Herdr socket.
// From the repository root:
//   dir="$(mktemp -d)"
//   swiftc -O Sources/HerdrBarCore/*.swift scripts/profile-discovery.swift -o "$dir/profile"
//   "$dir/profile"
import Foundation

@main enum DiscoveryProfile {
    static func main() async {
        let path = SocketLocation.resolve()
        var milliseconds: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = await ClientProcess.applicationAncestors(socketPath: path)
            let elapsed = start.duration(to: .now).components
            milliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        milliseconds.sort()
        print(String(format: "30 discovery samples: median %.2f ms, p95 %.2f ms, max %.2f ms",
                     milliseconds[15], milliseconds[28], milliseconds[29]))
    }
}
