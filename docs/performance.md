# Measure performance

Use a release build, a separate named Herdr session, and synthetic agent data.
The [recorded baseline](performance-baseline.md) covers one quiet connection.

## Prepare the measurement

1. Record the app commit, Herdr version, macOS version, and CPU architecture.
2. Record the agent count, event rate, and test duration.
3. Record whether the popover is open.
4. Find the app PID and the test server PID.
   Use the server PID, not the CLI PID that sent a command.
5. Check that you can read process counters for both PIDs.

## Collect app and server counters

1. Compile the counter tool from the repository root:

   ```sh
   swiftc -O -parse-as-library scripts/profile-processes.swift -o /tmp/herdr-process-profile
   ```

2. Replace `APP_PID` and `SERVER_PID` below with the test process IDs.
3. Collect a sample:

   ```sh
   /tmp/herdr-process-profile APP_PID SERVER_PID 30 > /tmp/herdr-counters.json
   ```

4. Retain the raw output with the run notes.

The tool reads counters without socket access, process control, or session data
collection. It does not request elevated privileges. It fails if a process exits
or the OS reuses its PID during the sample.

## Repeat the workloads

Run each case with the popover closed and open. Use the same machine and
workload for comparisons. For the quiet case, change the duration argument from
`30` to at least `60`.

| Case | Inputs | Measurements |
| --- | --- | --- |
| Quiet live connection | 1, 10, and 100 idle agents. At least 60 seconds per sample. | Snapshot request count. App and server CPU, wakeups, and memory. |
| Status burst | 1, 10, and 100 agents. 10 and 100 status changes per second. | Time between an event and visible state. Main-thread time, snapshot request count, and confirmed notification count. |
| Slow consumer and overflow | A controlled socket producer and delayed consumer. Fixed queue and line limits. | Time until queue failure and socket closure. Memory, recovered state, and notifications. |
| Automatic terminal selection | One attached client, then several attached clients. Record the system process count. | Discovery time, activation time, and cancellation time. |

## Interpret the counters

Treat one CPU core as 100 percent. The tool converts Mach ticks with the host
timebase. Treat the largest resident memory sample as a sampled maximum.
The one-second interval can miss the true peak.

Use wakeup counters as kernel process counters. They do not count Swift tasks
or snapshot requests. Do not infer a speed improvement from a source change
or a single sample.

The socket tests check overflow and socket closure. The store tests check state
and notifications with delayed snapshots and separate subscription positions.
Those tests do not measure production latency or peak memory.

## Measure terminal discovery

Run the commands from the repository root:

```sh
profile_dir="$(mktemp -d)"
swiftc -O Sources/HerdrBarCore/*.swift scripts/profile-discovery.swift -o "$profile_dir/profile"
"$profile_dir/profile"
```

The tool measures process discovery without activating a terminal or connecting
to a socket. Its output includes the median, p95, and maximum time from 30
samples. Machine load and process count affect the result. Elapsed discovery
time does not measure time spent on the main actor.

## Assess a performance change

Use Instruments to measure main-thread work before changing row updates,
summary passes, or sorting. Keep collection and sorting caches deferred until
measurements show a need.

If rendering causes a measured delay, combine presentation updates.
Preserve status transition processing and snapshot validation before committing
attention effects. Do not discard status transitions to reduce rendering work.
