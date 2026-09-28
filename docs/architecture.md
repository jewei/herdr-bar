# State and task ownership

Herdr Bar uses agent identity and snapshot validation to keep completion state
correct when events arrive late or panes move. `HerdrBarCore` contains the
protocol models, socket client, process discovery, and `AttentionTracker`.
`HerdrBar` contains the AppKit and SwiftUI code. Tests replace socket requests
with controlled responses through `HerdrService`.

## Agent identity

An agent identity contains the terminal ID, agent kind, and agent session.
A pane ID is a routing address that can change when the agent moves.
Unread state follows the agent identity across workspace moves.

Each attention occurrence has a local generation number. An acknowledgement
must match both the identity and generation in `AttentionTracker`. A pending
focus action therefore cannot clear a newer completion, even without
`state_change_seq`. Notifications use the same identity and generation, plus a
connection scope.

## Completion policy

**Done** is unread state local to the running Herdr Bar instance. An explicit
`done` status in a snapshot creates a completion. A snapshot transition from
`working` to `idle` for the same agent also creates a completion.

A successful open or **Mark completed agents as read** acknowledges the
completion. An acknowledgement in another Herdr client does not clear it.
Confirmed new work, a blocked or unknown state, agent replacement, or agent
removal supersedes an old completion. Opening a blocked agent leaves its blocked
state unchanged. App restarts and connection changes clear local unread state.

`AttentionTracker` computes new state without external effects. It keeps two
bounded records per identity: committed state from snapshots and provisional
state from events that identify a pane. Events update the provisional state in
arrival order. That order does not establish server chronology because
subscription selectors have separate history positions. Snapshot replies arrive
on a separate connection.

Provisional **Running** or **Unknown** activity can appear immediately.
Attention states, notifications, and acknowledgements use committed state.
Provisional work can block acknowledgement of an older row until snapshot
validation. Provisional events cannot clear confirmed unread attention if the
pane address later proves unreliable.

An event-only work cycle requires all of these conditions before it creates a
completion:

- The snapshot confirms the same agent identity and pane address.
- The snapshot contains a known sequence that has advanced.
- The snapshot's final status matches the event cycle.

An unchanged sequence cannot validate old events. Missing sequence data cannot
validate an event-only cycle. Several cycles before validation produce at most
the latest confirmed notification. The tracker stores bounded state instead of
a full transition history.

## Snapshot validation

During a snapshot request, `AgentStore` records which panes receive status events.
An overlapping event does not prove that the reply is current or identifies the
same agent. Provisional state can wait for a later snapshot if the current reply
does not confirm it.

An incompatible snapshot transition, sequence reset, changed identity, or
changed address discards the provisional state. A snapshot can reveal a changed
identity or address before the layout event arrives.

A layout event invalidates any active snapshot request. The store discards the
reply and retries. After three consecutive layout invalidations, the delayed
refresh task handles the next attempt. The store never accepts an invalid reply
because it reached the retry limit.

A layout change also removes provisional events and blocks later pane-only
events until a fresh snapshot arrives. Confirmed unread state follows the agent
identity across a move.

## Recovery limits

A gap in event history is a separate input to the tracker. It removes
unvalidated events and retains committed state for recovery. After a gap, an
advanced explicit completion sequence can produce a duplicate notification.

Missing sequences, uncertain pane mappings, polling, and stream gaps can hide
short work cycles. A snapshot cannot recover lost history. A move away and back
between snapshots can leave no visible change in the pane mapping.

A changed identity or a regressing sequence identifies a server restart.
The client cannot reliably detect a restart that reuses identical identities
without sequences. These protocol limits can delay attention or lose a short
completion. The [protocol ordering notes](protocol-compatibility.md#event-order)
describe the server behavior.

## Task lifetime

`AgentStore` owns polling, polling sleep, event consumption, active refresh,
delayed refresh, and focus tasks. A pending flag combines refresh requests into
one later refresh.

`stop()` cancels the tasks and advances the connection generation.
Changing the socket also advances that generation. Work from an earlier
generation cannot update the current connection. A new connection or restart
does not wait for an obsolete request.

Live polling sleeps until the next title refresh, at a 15-second interval.
Polling without an event stream uses a two-second interval. Failed snapshot
connections increase the retry delay up to 30 seconds. Stream changes and
explicit refreshes wake the scheduler.

## Transport and external effects

Both event queues have count limits. A line size limit also bounds the queued
wire data. Overflow, malformed status frames, and oversized lines end the
subscription. The store then uses polling and requests a snapshot to restore
current state.

The client ignores valid unknown event names. Known layout names accept their
documented aliases. Successful responses require the expected response type,
a matching request ID, and no error. Extra metadata fields remain valid.
The [protocol reference](protocol-compatibility.md) records the exact types and
size limits.

One-shot requests have total deadlines. Cancellation shuts down the request's
socket to wake a pending read. The worker then closes the socket. A lock prevents
late cancellation from shutting down a descriptor that the OS has reused.

The event reader limits work per dispatch callback. Its subscription
acknowledgement has a deadline. An established stream can remain quiet
indefinitely.

Terminal process discovery runs outside the main actor. AppKit lookup and
activation run on the main actor. The store checks its connection generation
again after activation. Tests can replace notification delivery, terminal
activation, and polling sleep. The design has no PID cache or general dependency
injection framework.
