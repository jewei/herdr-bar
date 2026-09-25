# Herdr protocol compatibility

## Fixture provenance

The fixtures in `Tests/HerdrBarCoreTests/Fixtures/` are pinned to **Herdr 0.9.1,
protocol 22, schema version 1**. On 2026-09-25 UTC, the installed executable was
located at `/opt/homebrew/bin/herdr`. Only these offline Herdr commands were run:

```sh
/opt/homebrew/bin/herdr --version
# herdr 0.9.1
/opt/homebrew/bin/herdr api schema --json > /tmp/herdr-bar-protocol-schema.json
shasum -a 256 /tmp/herdr-bar-protocol-schema.json
```

The exact schema stdout was 276,851 bytes; its SHA-256 was:

```text
226d4ecbd128d2e6bc84e4c8ddcec21ba9c7e51a0aafffcf087111ead3f1fa9a
```

`herdr-0.9.1-schema-excerpt.json` retains 23 selected, unchanged schema nodes.
Each `excerpts` key is its original JSON Pointer into that stdout document.
Whitespace is compacted; references are not rewritten and may point outside the
excerpt. This is provenance and a focused compatibility reference, **not a complete
standalone JSON Schema**. The full 270 KiB schema is intentionally not vendored.
Its hash identifies the source bytes, not the executable or the compact excerpt.

`herdr-0.9.1-examples.json` contains **synthetic schema-derived examples**, not wire
captures. All IDs, titles, paths, state sequences and session values are invented.
It includes snapshots before/after a cross-workspace move, the move notification,
other layout notifications, all five agent status values, a subscription request
and its acknowledgement. No live socket was queried and no user session was
inspected or modified. The CLI version does not establish the version of any
already-running server; this fixture pin is not a universal compatibility promise.

## Wire details covered

- `session.snapshot` returns `result.type = "session_snapshot"` and
  `result.snapshot`. Real snapshots include `protocol`, panes and layouts in
  addition to the fields Herdr Bar consumes. Extra fields are ignored by decoding.
- `terminal_id` and `agent_session` identify the same agent across a move, while
  `pane_id`, `workspace_id` and `tab_id` change. The move event exposes
  `previous_pane_id` and the new `pane.pane_id`; use the new routing address.
- `events.subscribe` takes `params.subscriptions`. Status subscriptions require
  `type: "pane.agent_status_changed"` and `pane_id`; omitting the optional
  `agent_status` filter requests every status. Layout subscriptions need only
  their `type` selector. Acceptance returns `result.type = "subscription_started"`.
- Subscription selectors use dots (`pane.moved`), but the general event schema
  uses underscores (`pane_moved`). Status subscription notifications instead use
  the dotted `pane.agent_status_changed`, with `data.pane_id` and
  `data.agent_status`. General event payloads vary: a move contains a nested pane,
  a close contains IDs, and a reorder contains workspace objects.
- Status payloads are decoded strictly enough to require a nonempty pane ID and
  string status. Unknown string statuses become `.unknown`. Named layout and
  otherwise unknown nonempty event names conservatively trigger a snapshot refresh;
  their data shape is deliberately ignored. Malformed envelopes/status events fail
  the stream with `invalidResponse`, rather than silently losing an update.

`ProtocolFixtureTests` decodes the examples, checks move identity, compares all
emitted subscription fields (apart from the generated correlation ID) with the
pinned request, and checks selectors/required fields/string types against the
schema excerpt. The stream test uses an isolated temporary mock UNIX socket,
never the installed Herdr session. Separate in-test mutations exercise future
status names and arbitrary layout data; these are compatibility probes, **not**
claims about payloads emitted by 0.9.1. These focused tests are not a general
JSON Schema validator or live-server conformance suite.

## Event size is a client policy

Herdr Bar caps an incoming event-stream line at **64 KiB (65,536 bytes, excluding
the newline delimiter)**, including the subscription acknowledgement. This is a
**client resource limit, not a server guarantee**. The pinned schema provides no
overall serialized-event byte ceiling. Layout events can include full pane or
workspace objects and arrays, while titles, labels and status metadata strings
are not given a general length bound. Therefore even a schema-valid event can
exceed this cap. The compact fixtures do not establish a maximum event size.

An oversized line fails with `responseTooLarge`; queue overflow fails with
`streamOverflow`. Consumers must reconnect/resnapshot rather than assume every
notification was delivered. The queue bound of 256 and the per-line cap bound
queued wire payload, not total process memory (which also includes buffers,
decoded objects and allocation overhead).

Run the focused suite with:

```sh
swift test --filter ProtocolFixtureTests
```

When updating fixtures, obtain a fresh offline version/schema pair, record the
exact stdout hash, review changed selectors and payload shapes, and explicitly
label synthetic examples versus genuine captures. Do not collect private session
data to refresh these fixtures.
