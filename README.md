# Herdr Bar

A native macOS menu bar app for [Herdr](https://herdr.dev). See which agents are running, need input, or have finished. Click an agent to open its pane in your terminal.

![Herdr Bar agent status palette](docs/palette.png)

The app subscribes to Herdr events, so it shows observed status changes immediately. If events are not available, the app checks every two seconds. The palette shows **Live** or **Polling**; hover that label for the last successful refresh and event-stream error. Use Settings to enable notifications, start at login, or choose your terminal. With the Automatic setting, the app activates the terminal application that runs your Herdr session; selecting the exact outer terminal window/tab is not guaranteed.

## Completion policy

**Done is local unread state while Herdr Bar is running.** Both Herdr's explicit `done` status and an observed `working → idle` transition create a completion. Seeing or acknowledging it in another Herdr client does not clear Herdr Bar's badge. Open it successfully here, or choose **Mark completed agents as read**, to acknowledge it. New work, a blocked/unknown state, agent replacement, or removal supersedes the old completion. Unread state is not persisted across app restarts or switching connections.

Moving an agent between workspaces preserves its unread state using terminal and agent-session identity, rather than its public pane address. Each observed attention occurrence has a local generation, so a newer completion is not acknowledged by an older pending action, even if Herdr omits `state_change_seq`.

Snapshot refreshes preserve status transitions received during the request. Layout changes invalidate in-flight snapshots; retries are coalesced and never force-install a stale response. Pane-only events are not attributed while a layout change makes their occupant ambiguous. Event queues are bounded (256 lines/events, at most 64 KiB per event line). Overflow, oversized lines, or malformed event/status frames close the subscription, expose polling fallback, and trigger resynchronization. Valid future event names and unknown string statuses remain supported. Snapshot responses retain the 8 MiB limit. Polling, initial discovery, and subscription/layout gaps can miss short tasks; a current snapshot cannot reconstruct lost event history. After an event-stream or layout gap, an advanced explicit completion sequence is conservatively announced again rather than silently treated as acknowledged; this can produce a duplicate notification. A server restart is detected through changed identity or a regressing sequence; identical reused identities without sequences cannot be distinguished reliably.

## Build and run

Requires macOS 14 or later, Swift 6 build tools, and a running local Herdr session.

```sh
./scripts/build.sh --open
```

The script creates `dist/Herdr Bar.app`. Move it to `~/Applications` for regular use. Quit the running app before you launch a new build.

## Development

```sh
swift test
swift run HerdrBar --check
```

Built with SwiftUI and AppKit. No external packages. macOS CI runs the native tests, a release build, and mocked packaging regression checks. Builds target the host architecture; the release script does not produce a universal binary. macOS 14 is the deployment target, not a claim that CI exercises every supported OS version.

Protocol reference: [Herdr socket API](https://herdr.dev/docs/socket-api/). The client uses `session.snapshot`, `agent.focus`, and `events.subscribe`; snapshot `state_change_seq` is optional. Use the schema shipped with your Herdr version (`herdr api schema --json`) when checking compatibility. See [pinned protocol fixtures and client limits](docs/protocol-compatibility.md) and the [native verification checklist](docs/native-verification.md).

Automatic terminal discovery runs process enumeration and parent traversal off the main actor; only AppKit lookup/activation runs on main. It does not cache PIDs. For a read-only timing check, compile and run `scripts/profile-discovery.swift` using the commands at the top of that file.

## Release

Set the version in `Resources/Info.plist` and commit it. Then run:

```sh
./scripts/release.sh
```

The script runs the tests, builds the app, signs it with a Developer ID, notarizes it, and staples the ticket. It creates `dist/HerdrBar-VERSION.zip` and prints its SHA-256. It does not publish anything. The script needs a Developer ID Application identity and notary credentials in the Keychain (`xcrun notarytool store-credentials notarytool`).

Publish the zip with `gh release create vVERSION dist/HerdrBar-VERSION.zip`.
