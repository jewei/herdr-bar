# Herdr protocol compatibility

Herdr Bar uses `session.snapshot`, `agent.focus`, and `events.subscribe`.
Snapshot `state_change_seq` is optional. The public
[Herdr socket API](https://herdr.dev/docs/socket-api/) describes the protocol.
The fixtures below record compatibility with a specific Herdr version.

## Fixture source

The files in `Tests/HerdrBarCoreTests/Fixtures/` use Herdr 0.9.1, protocol 22,
and schema version 1. The installed executable was `/opt/homebrew/bin/herdr`
on 2026-09-25 UTC. The fixture export used these offline commands:

```sh
/opt/homebrew/bin/herdr --version
# herdr 0.9.1
/opt/homebrew/bin/herdr api schema --json > /tmp/herdr-bar-protocol-schema.json
shasum -a 256 /tmp/herdr-bar-protocol-schema.json
```

The schema output contained 276,851 bytes. Its SHA-256 was:

```text
226d4ecbd128d2e6bc84e4c8ddcec21ba9c7e51a0aafffcf087111ead3f1fa9a
```

`herdr-0.9.1-schema-excerpt.json` retains selected schema nodes without changes
to their values. Each `excerpts` key is the original JSON Pointer into the
exported document. The excerpt compacts whitespace but preserves references,
including references outside the excerpt. It is not a complete, standalone JSON
Schema. The full schema is absent from the repository. The hash identifies the
exported bytes, not the executable or excerpt.

`herdr-0.9.1-examples.json` contains synthetic examples derived from the schema.
The IDs, titles, paths, state sequences, and session values are invented.
The examples include these messages:

- Snapshots before and after a move between workspaces
- An agent focus reply with agent details
- The move event and other layout events
- Each agent status value
- A subscription request and its acknowledgement

The export did not query a live socket or inspect or change a user session.
The CLI version does not establish the version of a running server.
These fixtures apply to the recorded schema version.

## Requests and responses

The client requires these response types:

| Method | Required `result.type` | Response data |
| --- | --- | --- |
| `session.snapshot` | `session_snapshot` | `result.snapshot` |
| `agent.focus` | `agent_info` | `result.agent` |
| `events.subscribe` | `subscription_started` | Subscription acknowledgement |

A matching request ID alone does not establish success. The client also checks
errors and the response type. Decoding accepts extra fields. Real snapshots
include `protocol`, panes, and layouts beyond the fields Herdr Bar uses.

On 2026-09-29, a fresh offline schema export had the same byte count and SHA-256
as the original export. The focus fixture adds the `agent_info` variant from
`ResponseResult/oneOf/12`. Herdr 0.9.1's
[focus handler](https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/api/agents.rs#L55-L62)
returns this variant. The schema lists response variants but does not map each
method to its reply. The earlier requirement for `ok` was incorrect and caused
valid focus replies to fail. The focus regression test checks the synthetic
reply through a temporary socket.

Across a move, `terminal_id` and `agent_session` identify the same agent.
The `pane_id`, `workspace_id`, and `tab_id` change. A move event contains
`previous_pane_id` and the new routing address in `pane.pane_id`.

`events.subscribe` takes `params.subscriptions`. A status subscription requires
`type: "pane.agent_status_changed"` and `pane_id`. Without the optional
`agent_status` filter, it requests every status. A layout subscription requires
only its `type` selector.

## Event decoding

Subscription selectors use dots, as in `pane.moved`. The general event schema
uses underscores, as in `pane_moved`. Status subscription notifications use
`pane.agent_status_changed`, with `data.pane_id` and `data.agent_status`.

General event payloads differ by event. A move contains a nested pane, a close
contains IDs, and a reorder contains workspace objects. Known layout names and
their underscore aliases trigger a snapshot refresh. The client ignores their
data shape.

Status payloads require a nonempty pane ID and a string status. Unknown string
statuses decode as `.unknown`. Other valid, nonempty event names cause no refresh.
Malformed event envelopes or status events fail the stream with
`invalidResponse`.

## Event order

Herdr 0.9.1
[polls selectors in request order](https://github.com/herdrdev/herdr/blob/v0.9.1/src/api/server.rs#L752).
Status and layout selectors have
[independent history positions](https://github.com/herdrdev/herdr/blob/v0.9.1/src/api/subscriptions.rs#L283).
A status selector can skip a move and emit a later status before the layout
selector reports the move. A snapshot response has no shared stream position.
Selector order does not establish global event order.

Status events contain an address and status. They contain neither a stable
agent identity nor a sequence marker shared with snapshots. Herdr Bar keeps
these provisional events separate from snapshot-confirmed attention state.

An unchanged sequence cannot validate a delayed cycle. A changed pane mapping
discards provisional events and retains confirmed unread state by identity.
Without a sequence, an event-only cycle cannot create a completion. A move away
and back between snapshots can remain undetected. The client cannot recover
every short cycle.

## Client limits

The client applies these limits:

| Data | Limit |
| --- | --- |
| Event stream line, including the subscription acknowledgement | 64 KiB, or 65,536 bytes, excluding the newline |
| Each event queue | 256 lines or events |
| Snapshot response line | 8 MiB |

The schema specifies no overall event size limit. Layout events can contain
full pane or workspace objects and arrays. Titles, labels, and status metadata
strings have no general length bound. A valid event can therefore exceed the
client's line limit.

An oversized line fails with `responseTooLarge`. Queue overflow fails with
`streamOverflow`. Recovery requires a new subscription and snapshot.
The limits bound queued wire data. Total process memory also includes buffers,
decoded objects, and allocation overhead.

## Test coverage

`ProtocolFixtureTests` decodes examples and checks agent identity across moves.
It compares emitted subscription fields with the fixture, except for the generated
request ID. It also checks selectors, required fields, and string types against
the schema excerpt.

The stream test uses an isolated temporary UNIX socket. Separate test mutations
check future status names and arbitrary layout data. Those mutations test client
behavior beyond the recorded Herdr 0.9.1 payloads.

`SubscriptionOrderingTests` models one chronological history with independent
status and layout positions. It controls snapshot reply timing separately.
The cases include status before layout and a new snapshot before a delayed
layout event.

These tests cover selected client behavior. They do not validate the complete
JSON Schema or establish live-server conformance. The
[build and test guide](development.md#run-the-tests) includes the fixture test
command.

## Fixture update requirements

A fixture update requires a fresh offline version and schema export, with the
exact output hash. The review covers changed selectors and payload shapes.
Examples have explicit labels that distinguish synthetic data from captured
messages. Fixture updates exclude private session data.
