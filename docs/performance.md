# Performance measurements

Measure a release build with a separate named Herdr session and synthetic agent
data. Record the app commit, Herdr version, macOS, CPU architecture, agent count,
event rate, test duration, and whether the popover is open. Do not infer a speed
improvement from a source change or from one timing sample.

## Joint app and server counters

`scripts/profile-processes.swift` reads CPU time, wakeup counters, and resident
memory for two explicit process IDs. It does not connect to a socket, collect
session contents, or control either process. Use the PID of the test server,
not the CLI process which sent a command to it.

```sh
swiftc -O -parse-as-library scripts/profile-processes.swift -o /tmp/herdr-process-profile
/tmp/herdr-process-profile APP_PID SERVER_PID 30 > /tmp/herdr-counters.json
```

The CPU percentage converts Mach ticks with the host timebase and uses one core
as 100 percent. Memory is sampled once per
second; the largest sample is not an exact peak. The wakeup counters are kernel
process counters, not counts of Swift tasks or snapshot requests. The tool fails
if a process exits or its PID is reused during the sample. It needs permission
to read both processes and does not request elevated privileges.

## Workload matrix

Repeat each case with the popover closed and open. Use the same machine and
workload for comparisons; retain raw counter output with the run notes.

| Case | Inputs | Additional measurements |
| --- | --- | --- |
| Quiet live connection | 1, 10, and 100 idle agents; at least 60 seconds | Snapshot request count; app and server CPU, wakeups, and memory |
| Status burst | The same agent counts; 10 and 100 status changes per second | Event-to-visible-state time, main-thread time, snapshot request count, committed notification count |
| Slow consumer and overflow | A controlled socket producer and delayed consumer; fixed queue and line limits | Queue failure and socket-close times, memory, recovery state and notices |
| Automatic terminal selection | One and several attached clients; record system process count | Discovery and activation times, cancellation time |

The deterministic socket tests exercise overflow and prompt closure. The store
tests count semantic effects across held snapshots and independent subscription
cursors. Those tests establish correctness, not production latency or peak
memory. Use Instruments to attribute main-thread time before changing row
projection, summary passes, or sorting. The existing `profile-discovery.swift`
measures process discovery only; it does not activate a terminal.

Do not drop status transitions to reduce render cost. If measurements establish
a bottleneck, combine presentation updates while retaining transition processing
and the snapshot validation needed before attention effects are committed.

## Quiet-state baseline — 2026-09-28

Source `a32e893a7b482bd35a383875238d42df757c2dea`, release configuration, macOS
27.0 arm64, Herdr 0.9.1. A separate named test server had one synthetic idle
agent and no attached terminal client. The unbundled app executable ran with
the popover closed and notifications disabled. A local forwarding socket counted
requests without changing their contents. After startup, the sample lasted
60.23 seconds. See the [raw counters](performance-baseline.json).

| Process | CPU, one core = 100% | Interrupt wakeups | Largest sampled resident memory |
| --- | --- | --- | --- |
| Herdr Bar | 0.0066% | 9 | 48.4 MiB |
| Herdr server | 0.3853% | 1,087 | 22.2 MiB |

The app sent three snapshot requests during the sample. There was no new
subscription request. The test app/server were removed afterward; installed app
preferences were unchanged. This is one quiet-state baseline, not a claim about
event bursts, large agent lists, open-popover behavior, activation latency, or
the exact peak memory of a distributed bundle. The remaining workload cases
above still need measurement before performance changes are justified.
