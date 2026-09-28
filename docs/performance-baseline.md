# Performance baseline

The measurement on 2026-09-28 used source commit
`a32e893a7b482bd35a383875238d42df757c2dea`, a release build, macOS 27.0
on arm64, and Herdr 0.9.1.

## Sample conditions

A separate named test server had one synthetic idle agent and no attached
terminal client. The unbundled app executable ran with the popover closed and
notifications disabled. A local forwarding socket counted requests without
changing their contents.

The sample began after startup and lasted 60.23 seconds.
The [raw counters](performance-baseline.json) contain the recorded values.

## Results

The sample produced these measurements:

| Process | CPU, one core = 100% | Interrupt wakeups | Largest sampled resident memory |
| --- | --- | --- | --- |
| Herdr Bar | 0.0066% | 9 | 48.4 MiB |
| Herdr server | 0.3853% | 1,087 | 22.2 MiB |

The app sent three snapshot requests during the sample. It sent no new
subscription request. The test app and server were removed afterward.
Installed app preferences remained unchanged.

## Measurement limits

The sample covers one quiet connection. It does not measure event bursts,
large agent lists, an open popover, activation latency, or a distributed bundle.
The largest resident memory sample is not the exact peak.

The remaining [workload cases](performance.md#repeat-the-workloads) have no
recorded measurements here. The measurement guide contains the commands for
new samples. This baseline does not establish a need for performance changes.
