# First review decisions

The supplied ChatGPT review examined commit `534aca9`. Two independent
reviewers checked each section against that commit and local commit `db0353c`.
Both supported the existing package split. They prioritized state correctness,
stream limits, and release verification.

This record describes the first review. The
[second review](second-review-decisions.md) changed the event validation and
notification policy described here.

## Decisions by review item

The table distinguishes retained fixes, added work, and deferred changes.
Tests establish the stated software behavior. Native UI and distribution checks
require separate evidence.

| Review item | Decision and change |
| --- | --- |
| 1. A pending open can acknowledge new work | Retained shared agent identity and local occurrence generations. Open and mark-as-read both validate the exact occurrence in the tracker. |
| 1. The retry cap permits stale snapshots | Retained event status over snapshot metadata. Invalid layout snapshots are discarded and retried within a limit. The limit never forces acceptance of an invalid snapshot. |
| 1. Equal displayed status hides a new notification | Retained duplicate suppression by identity and occurrence. The initial snapshot sends no notifications. |
| 2. Unbounded stream buffers | Retained limits on both queues, overflow errors, and work per read callback. Snapshots recover current state but cannot recover lost history. |
| 2. A completed line exceeds its limit | Retained checks before delivery. Added a check before each trailing-fragment append. Smaller test limits check boundaries without large concurrent transfers. |
| 2. A subscription can wait forever | Retained the acknowledgement deadline. An established stream can remain quiet. |
| 2. Unknown event names cause refreshes | Added a known-name set. Other valid event names are ignored. Dot and underscore layout aliases remain supported, including `pane_closed`. Malformed status frames still fail the stream. |
| 3. Process discovery runs on the main actor | Retained discovery on a worker and AppKit on the main actor. The generation check after activation remains. No measured UI speed improvement was claimed. |
| 3. Event bursts repeat refresh work | Retained immediate event presentation. Added separate ownership for active and delayed refresh tasks, with a pending refresh flag. |
| 3. Quiet and offline polling wakes too often | Added deadlines for live polling and an increasing offline retry delay with a maximum. Tests replace polling sleep to check the schedule. |
| 3. Summary passes and repeated sorting | Deferred caches. Measurements had not shown a need. A cache would add invalidation rules. |
| 4. Split the store into three owners | Partly accepted. Retained the state reducer and service interface. Explicit task ownership fixes the defect without another coordinator. A later split remains possible if the store grows. |
| 4. Unify notification and agent identity | Retained checks for terminal, agent session, occurrence, and connection scope. Pane moves preserve attention. Stale targets cannot open replacement agents. |
| 4. Show connection failures | Retained **Live**, **Polling**, **Disconnected**, refresh time, stream errors, and logs that omit session contents. |
| 4. Stop and cancellation ownership | Added a missing fix. Stop advances the connection generation and cancels its tasks. One-shot socket cancellation and delayed-response tests cover the behavior. |
| 5. Event order and stream tests | Retained state, socket, discovery, and protocol fixture tests. Added stop, restart, cancellation, polling schedule, and unknown-event tests. Critical new tests wait for observable state. Some older wait helpers remain. |
| 5. macOS CI | Retained CI with an explicit Xcode 16.4 selection. Added text format checks, complete release mocks, and app metadata, architecture, and signature validation. Pull request jobs contain no signing credentials. |
| 5. Native UI and visual checks | Retained a separate native checklist. Preview images cannot verify notifications, startup at login, VoiceOver, or outer terminal window selection. |
| 6. Clean source and fresh app bundle | Retained fresh bundle construction and repository checks. Added a temporary export of the exact source commit for tests and builds. |
| 6. Release source and architecture records | Added file names with CPU architecture and a JSON manifest for source, toolchain, version, architecture, and SHA-256. Signed archives can differ across builds. |
| 6. Version drift and tag rules | Retained the **Settings** version from bundle metadata. Prepared version 1.0.1, build 2. Checks enforce the tag version, tag commit, and increasing build number. |
| 7. Connection and troubleshooting docs | Added socket setting precedence, launch environment differences, and procedures for offline status, terminal selection, and notifications. |
| 7. State and latency claims | Retained the completion and event-gap policy. Accepted status events can appear immediately. Opening a blocked agent leaves its blocked state unchanged. |
| 7. Architecture and compatibility notes | Added task ownership notes. Retained versioned Herdr fixtures and native verification records. The ignored local verification file remains separate. |
| 7. License | Left the license choice to the owner. The review made no license grant. |
| 7. Accessibility and fixed UI dimensions | Accepted the need for native checks. A palette redesign requires findings from those checks. |

## Additional findings

Both reviewers found that a scheduled refresh cleared its task handle before
the response arrived. Stop could leave that request active. Task ownership and
connection generation checks now cover that case.

A cancelled one-shot request retained its socket until timeout. Cancellation now
wakes the read and closes the socket.

A new connection could inherit the previous stream's retry delay. Connections
and restarts now reset the delay. Regression tests cover both cases.

Four large socket tests timed out in the first native run. Smaller injected
limits test the same boundaries without concurrent multi-megabyte writes.

Release tests change the original checkout during a build and check that the
exported source remains fixed. Failed tests, signing, notarization, or assessment
must preserve the previous archive. A failed archive replacement also restores
the matching manifest and checksum.

## Deferred changes and evidence limits

The review deferred PID and sorting caches, a general dependency injection
framework, and a broad UI redesign until evidence shows a need.
The build does not produce a universal binary.

Unit tests do not establish native permission, login, accessibility, or
notarization results. The [native verification record](native-verification.md)
contains the completed checks and their limits. The
[native release checklist](native-checklist.md) contains the remaining procedures.
