import Foundation
import Testing
@testable import HerdrBarCore

@MainActor
@Test func processDiscoveryRunsOffMainAndHandlesCyclesAndSharedAncestors() async {
    let ancestors = await ClientProcess.applicationAncestors(socketPath: "/tmp/test.sock", find: { path in
        #expect(!Thread.isMainThread)
        #expect(path == "/tmp/test.sock")
        return [10, 20, 30]
    }, parent: { pid in
        #expect(!Thread.isMainThread)
        // The last process exited; two others share an ancestor, with a cycle
        // simulating PID reuse while discovery is running.
        return [10: 11, 11: 12, 12: 11, 20: 21, 21: 12][pid]
    })
    #expect(ancestors == [11, 12, 21])
    MainActor.preconditionIsolated()
}

@MainActor
@Test func cancellingProcessDiscoveryPropagatesToTheWorker() async {
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let gate = DispatchSemaphore(value: 0)
    let task = Task {
        await ClientProcess.applicationAncestors(socketPath: "/tmp/test.sock", find: { _ in
            #expect(!Thread.isMainThread)
            continuation.yield(())
            continuation.finish()
            // Bound the test even if main-actor scheduling accidentally regresses.
            #expect(gate.wait(timeout: .now() + 2) == .success)
            return [10]
        }, parent: { _ in 11 })
    }
    defer { gate.signal(); task.cancel(); continuation.finish() }
    for await _ in started { break }
    task.cancel()
    gate.signal()
    let ancestors = await task.value
    #expect(ancestors.isEmpty)
}
