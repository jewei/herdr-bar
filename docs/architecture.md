# State and task ownership

`HerdrBarCore` contains protocol models, the socket client, process discovery,
and `AttentionTracker`. `HerdrBar` contains AppKit and SwiftUI presentation.
`HerdrService` lets tests replace socket requests with controlled responses.

## Identity and attention

An agent identity contains the terminal ID, agent kind, and agent session.
A pane ID is a routing address. It can change when the agent moves.
Each observed attention occurrence has a local generation. A row acknowledgement
must match both identity and generation in the tracker. Thus, a pending focus
action cannot clear a newer completion. Notifications use the same identity and
generation, plus a connection scope.

The tracker is a pure state reducer. It receives every accepted status transition
in order. It creates unread completion for explicit `done` or observed
`working` to `idle`. The store publishes the resulting rows immediately.
Refresh requests can combine; status transitions cannot be discarded silently.

## Refresh and lifecycle

`AgentStore` owns polling, polling sleep, the event consumer, active refresh,
delayed refresh, and focus tasks. A pending flag requests one later refresh.
`stop()` cancels these tasks and advances the connection generation.
Changing the socket also advances the generation. Work from an earlier
generation cannot publish into the current connection. A new connection or
restart does not wait for an obsolete request.

During a snapshot request, the store records which panes received status events.
It keeps those agents' reduced status while installing snapshot metadata.
A layout event invalidates snapshot membership. The store discards that snapshot
and tries again. After three consecutive layout invalidations it yields to the
delayed refresh task; it never installs a known stale snapshot.

While topology is uncertain, pane-only status events cannot identify an occupant
reliably. The store waits for a fresh snapshot. A sequence increase after a gap
can generate a duplicate completion notice; it is not silently acknowledged.
No snapshot can reconstruct all short tasks lost during a connection gap.

## Transport and effects

Both event queues have fixed count limits. A fixed line limit also bounds their
queued wire payload. Overflow, malformed status frames, or oversized lines end
the subscription and cause polling and resynchronization. Unknown event names
are ignored. Known layout names accept their documented compatibility aliases.

One-shot requests have total deadlines. Cancellation shuts down the owned socket
to wake a pending read; the worker closes it. A lock prevents late cancellation
from shutting down a descriptor that the operating system has reused.
The event reader limits work per dispatch callback. Its handshake has a deadline;
an established stream can remain quiet indefinitely.

Live polling sleeps until the next 15-second title refresh. Polling fallback uses
two seconds. Failed snapshot connections increase their retry delay up to
30 seconds. Stream changes and explicit refreshes wake the scheduler.

Terminal process discovery runs outside the main actor. AppKit lookup and
activation remain on the main actor. The store checks its generation again after
activation. Notification delivery, terminal activation, and polling sleep have
narrow test boundaries. No PID cache or general injection framework is needed.
