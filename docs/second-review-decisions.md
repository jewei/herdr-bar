# Second review decisions

On 2026-09-28, two independent agents checked all seven sections of the second
review against commit `5c40c78`. Both confirmed the two reported defects.
They also found related state and protocol cases.

The [native verification record](native-verification.md) contains later test
results and the owner's release-check exclusions.

## Decisions by review item

The review produced these decisions:

| Review item | Decision and change |
| --- | --- |
| 1. Earlier fixes | Retained the buffer limits, cancellation, task ownership, process discovery outside the main actor, and release construction fixes. |
| 2. Status before layout | Required a fix before release. Snapshot-confirmed state is separate from provisional pane events. A layout change discards provisional events and retains unread state by identity. A changed snapshot mapping has the same effect before a layout event arrives. |
| 2. Incorrect notifications | Strengthened the recommendation. A full provisional work cycle can arrive before a layout event. Undoing state afterward cannot recall a notification. Only confirmed attention can send notifications. |
| 3. Success response types | Required `ok` for focus, `subscription_started` for subscriptions, and `session_snapshot` for snapshots. Extra fields remain valid. Request ID and error checks remain. Tests no longer accept unrelated success types. |
| 4. Performance | Required measurement before caches. Added repeatable workloads and a tool that reads app and server counters. Correctness tests cannot establish speed, total memory limits, or workload measurements. Summary and sorting caches remain deferred. |
| 5. Architecture | Retained the package split, service interface, and store. The tracker keeps bounded committed and provisional state. Layout invalidation and event history gaps have separate inputs and documented effects. |
| 6. Timing tests | Added cases for status or a complete cycle before layout, delayed events with unchanged sequences, changed snapshot mappings, and unread state across moves. An integration model controls subscription positions and snapshot replies independently. |
| 6. Release tests | Added `swift test -c release` to CI and the release script alongside debug tests. Failure of these Swift tests must preserve the previous archive. |
| 6. Runtime support | Accepted that compilation and metadata do not establish support on the oldest OS. The owner excluded macOS 14 and logout and login checks for 1.0.1. Those checks were not performed. Distribution requires built and verified architectures. |
| 7. Release process | Retained builds from a fixed source commit, signing, notarization, source records, and restoration after failure. Native results apply to the recorded candidate. |
| 7. Documentation and UI checks | Distinguished event arrival order from server chronology. Retained keyboard, notification, terminal, recovery, contrast, and long-label results. The owner excluded VoiceOver, larger text, and startup after login for 1.0.1. The review added no license grant or broad UI redesign. |

## Additional findings

Old status events can arrive after a newer snapshot. An unchanged snapshot
sequence must not validate a second local work cycle. New tests cover this case
and the reported late layout event.

Snapshot success types were also unchecked. A payload with a snapshot field
and an unrelated response type now fails.

A newer incompatible snapshot must interrupt a provisional cycle.
Retaining old `working` evidence across a later blocked or unknown state could
create another false completion. The reviewers checked that case during
implementation.

## Accepted behavior limits

Status events contain a pane address. They do not contain a stable agent
identity or a sequence marker shared with snapshots.

A short event-only cycle requires an unchanged identity and address, an advanced
known sequence, and a matching snapshot status. Missing sequences or uncertain
pane mappings can therefore lose a short completion. Several cycles before
validation produce at most the latest confirmed occurrence. A snapshot
transition from `working` to `idle` still works without sequences.

The client cannot prove every pane mapping if an agent moves away and back
between snapshots. Complete recovery would require stronger server guarantees,
such as events with stable identity. The current protocol does not guarantee
global event order or a notification for every transition.
