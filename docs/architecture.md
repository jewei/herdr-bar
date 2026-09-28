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

The tracker is a pure state reducer with two bounded state records per identity:
committed state from snapshots and a provisional reduction of pane-addressed
events. It processes accepted events in their received order. This is not global
server chronology: different subscription selectors have independent history
positions, and snapshot replies travel on another connection.

Provisional Running/Unknown activity can appear immediately. Attention states,
notifications, and acknowledgements use committed state. Meaningful provisional
work blocks acknowledgement of an older row until reconciliation. It cannot
erase established unread attention if its address later proves unreliable.
Snapshot-only `working` to `idle` and explicit `done` still create completion.

An event-only cycle needs the same identity and address, an advancing known
sequence, and a matching final status in a snapshot. An unchanged sequence cannot
confirm queued old events. Missing sequence data cannot validate an event-only
cycle. Several cycles before validation produce one latest occurrence, not a
promise of a notice per raw cycle. The reducer keeps bounded state rather than
an unbounded transition history.

## Refresh and lifecycle

`AgentStore` owns polling, polling sleep, the event consumer, active refresh,
delayed refresh, and focus tasks. A pending flag requests one later refresh.
`stop()` cancels these tasks and advances the connection generation.
Changing the socket also advances the generation. Work from an earlier
generation cannot publish into the current connection. A new connection or
restart does not wait for an obsolete request.

During a snapshot request, the store records which panes received status events.
Overlap alone proves neither freshness nor identity. Provisional evidence can
wait for a later snapshot when the current reply has not yet confirmed it.
An incompatible authoritative transition, sequence reset, changed identity, or
changed address discards the candidate. A layout event invalidates snapshot
membership. The store discards that reply and tries again. After three consecutive
layout invalidations it yields to the delayed refresh task; it never forces that
reply into the state.

Topology invalidation removes provisional observations already received and
quarantines later pane-only events until a fresh snapshot. Established unread
state follows the stable identity across a move. A transport-history gap is a
separate reducer input; unvalidated observations are removed, while committed
state remains available for recovery. An advanced explicit completion sequence
can conservatively generate another notice after a gap.

This protocol cannot prove every short-lived address-to-identity relationship.
Moving away and back between snapshots may leave no visible mapping change.
Conservative reconciliation can miss short tasks and delay attention; it does
not establish lossless event history. See the [protocol ordering notes](protocol-compatibility.md).

## Transport and effects

Both event queues have fixed count limits. A fixed line limit also bounds their
queued wire payload. Overflow, malformed status frames, or oversized lines end
the subscription and cause polling and resynchronization. Unknown event names
are ignored. Known layout names accept their documented compatibility aliases.

Successful responses require the method's discriminator: `session_snapshot`,
`ok`, or `subscription_started`. Correlation and error checks remain in place;
unknown additive fields do not invalidate a correctly typed response.

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
