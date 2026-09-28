# Review decisions

This records the first review. The [second review decisions](second-review-decisions.md)
update the event reconciliation and notification policy described below.

The supplied ChatGPT review examined commit `534aca9`. Two fresh independent
reviewers checked every section against that commit and local commit `db0353c`.
Both agreed with the main assessment: keep the current package split and fix
state correctness, stream limits, and release verification first.

The table records the shared decisions. "Keep" means that the existing local
fix is part of the change being merged. "Add" means that this review found more
work. Tests establish the stated software behavior, not unperformed native UI
or distribution checks.

| Review item | Decision and resulting change |
| --- | --- |
| 1. A pending open can acknowledge new work | Agree. Keep shared agent identity and local occurrence generations. Both open and mark-as-read validate the exact occurrence in the tracker. |
| 1. The retry cap permits stale snapshots | Agree. Keep event status overlaid on snapshot metadata. Discard invalid topology snapshots and schedule a bounded retry. Never force a stale install. |
| 1. Equal displayed status hides a new notification | Agree. Keep notification deduplication by identity and occurrence, with startup suppression. |
| 2. Unbounded stream buffers | Agree. Keep limits on both queues, explicit overflow failure, and bounded work in each read callback. A snapshot recovers current state, not lost history. |
| 2. A completed line exceeds its limit | Agree. Keep boundary checks before delivery. Add a check before every trailing-fragment append. Use smaller injected limits to test boundaries without large concurrent transfers. |
| 2. A subscription can wait forever | Agree. Keep the acknowledgement deadline. A quiet established stream remains valid. |
| 2. Unknown event names cause refreshes | Agree. Add an explicit known-name set and ignore other valid event names. Keep dot and underscore layout aliases, including `pane_closed`. Malformed status frames still fail the stream. |
| 3. Process discovery runs on the main actor | Agree. Keep discovery on a worker and AppKit on main. Keep the generation check after terminal activation. No UI speedup is claimed. |
| 3. Event bursts create repeated refresh work | Agree. Keep immediate event presentation. Add separate ownership for active and delayed refresh tasks and a pending refresh flag. |
| 3. Quiet and offline polling wakes too often | Agree. Add deadline-based live polling and bounded offline backoff, with injectable sleep tests. |
| 3. Summary passes and repeated sorting | Defer. These are small costs without a measured bottleneck. A cache adds invalidation rules. |
| 4. Split the store into three new owners | Partly agree. Keep the pure reducer and service boundary. Explicit task ownership fixes the current defect without a new coordinator framework. Extraction can follow if the store grows. |
| 4. Unify notification and agent identity | Agree. Keep terminal, agent session, occurrence, and connection scope checks. Pane moves preserve attention; stale targets cannot open replacement agents. |
| 4. Show degraded operation | Agree. Keep Live/Polling/Disconnected, refresh time, stream error text, and logs that omit session contents. |
| 4. Stop and cancellation ownership | Agree; add a missing fix. Stop advances the lifecycle generation and cancels owned work. Add one-shot socket cancellation and held-response tests. |
| 5. Adverse-order and stream tests | Agree. Keep the new state, socket, discovery, and protocol fixture tests. Add stop/restart, cancellation, polling schedule, and unknown-event tests. Critical new tests wait for observable state; a few old settling helpers remain. |
| 5. macOS CI | Agree. Keep CI and select Xcode 16.4 explicitly. Add shared text-format checks, complete release mocks, and real app metadata/architecture/signature validation. No signing credentials enter pull-request jobs. |
| 5. Native UI and visual checks | Agree on the need. Keep a separate native checklist. Preview images do not prove notification delivery, login startup, VoiceOver, or outer terminal window selection. |
| 6. Clean source and fresh app bundle | Agree. Keep fresh bundle staging and full repository cleanliness checks. Add a temporary export of the exact source commit for tests and builds. |
| 6. Release source and architecture records | Agree. Add architecture-specific names and a JSON manifest with source, toolchain, version, architecture, and SHA-256. Do not promise identical signed bytes across builds. |
| 6. Version drift and tag rules | Agree. Keep the Settings version from bundle metadata. Prepare version 1.0.1, build 2. Check tag/version agreement, tag commit, and increasing build number. |
| 7. Connection and troubleshooting docs | Agree. Add setting/environment precedence, launch-context differences, and help for offline mode, wrong terminal, and missing notifications. |
| 7. State and latency claims | Agree. Keep the completion/gap policy. Immediate presentation is now supported for accepted status events. Opening a blocked agent does not resolve it. |
| 7. Architecture and compatibility notes | Agree. Add task ownership notes. Keep pinned Herdr fixtures and durable native verification notes. Preserve the ignored local verification file. |
| 7. License | Owner decision. Do not create a license grant without the owner's choice. This is separate from code correctness. |
| 7. Accessibility and fixed UI dimensions | Agree that native checks are needed. Do not redesign the palette without findings from those checks. |

## Additional findings

- A scheduled refresh cleared its task handle before awaiting the response.
  Stop could therefore leave it active. Both reviewers found this defect
  independently. Ownership and lifecycle-generation checks now cover it.
- A cancelled one-shot request kept its socket until its timeout. The transport
  now wakes the read and closes the socket when the task is cancelled.
- A new connection could inherit the previous stream's retry delay. New
  connections and restarts now reset that delay, with regression tests.
- Four large socket tests timed out in the first native run. Smaller injected
  limits test the same size boundaries without competing multi-megabyte writes.
- Release tests now change the original checkout during a build and verify that
  the exported source stays fixed. Failed tests, signing, notarization, or
  assessment must preserve the previously accepted archive. Promotion failure
  also restores the matching manifest and checksum.

## Deliberate limits

Do not add a PID cache, sorting cache, general injection framework, universal
binary claim, or broad UI redesign without evidence. Do not infer successful
native permission, login, accessibility, or notarization checks from unit tests.
See [native verification](native-verification.md) for the recorded checks and
the remaining interactive release checks.
