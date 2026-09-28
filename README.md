# Herdr Bar

A native macOS menu bar app for [Herdr](https://herdr.dev). See which agents are running, need input, or have finished. Click an agent to open its pane in your terminal.

![Herdr Bar agent status palette](docs/palette.png)

The app subscribes to Herdr events. Running activity can appear immediately; attention states and notifications wait for snapshot validation. If events are not available, the app checks every two seconds. The palette shows **Live** or **Polling**; hover that label for the last successful refresh and event-stream error. Use Settings to enable notifications, start at login, or choose your terminal. With the Automatic setting, the app activates the terminal application that runs your Herdr session; selecting the exact outer terminal window/tab is not guaranteed.

## Connection and troubleshooting

The socket path uses this order:

1. A nonempty **Connection** setting saved in Herdr Bar. A leading `~` is expanded when you save this setting.
2. `HERDR_SOCKET_PATH`, if set and nonempty in the app's environment.
3. The directory that contains `HERDR_CONFIG_PATH`, or `~/.config/herdr` if that variable is empty or absent.
   In this directory, `HERDR_SESSION` selects `sessions/SESSION/herdr.sock`. Without a session name, the path is `herdr.sock`.

An app opened from Finder or at login does not normally receive your terminal's shell variables. Set the socket path in **Connection** for these launch methods. Clear that setting to use the environment and default path again.

- **Offline:** confirm that Herdr is running. Compare its session socket with the Connection setting. Correct the path and refresh. Failed connections retry with a delay that increases to 30 seconds.
- **Polling:** snapshots still work. Hover the mode label for the stream error. The app retries the event subscription; a quiet established stream stays connected.
- **Wrong terminal:** choose the terminal in Settings. Automatic checks attached Herdr clients and their parent processes. With multiple clients, it uses the first matching application. If no application is found, it tries the running terminals in this order: Ghostty, iTerm2, Terminal, WezTerm, Warp. SSH and nested terminal multiplexers can prevent host detection. Selection of a particular outer window or tab is not guaranteed.
- **No notifications:** enable notifications in Herdr Bar and in System Settings > Notifications. Check Focus settings. The initial snapshot does not send notifications. Opening an agent or marking it as read clears only local completion attention. Opening a blocked agent does not remove its blocked state.

## Completion policy

**Done is local unread state while Herdr Bar is running.** Herdr's explicit `done` status or an identity-bound `working → idle` transition in snapshots creates a completion. A cycle seen only through pane-addressed events needs snapshot validation: the same agent at the same address, an advanced sequence, and a matching final status. Seeing or acknowledging a completion in another Herdr client does not clear Herdr Bar's badge. Open it successfully here, or choose **Mark completed agents as read**, to acknowledge it. Confirmed new work, a blocked/unknown state, agent replacement, or removal supersedes the old completion. Unread state is not persisted across app restarts or switching connections.

Moving an agent between workspaces preserves its unread state using terminal and agent-session identity, rather than its public pane address. Each observed attention occurrence has a local generation, so a newer completion is not acknowledged by an older pending action, even if Herdr omits `state_change_seq`.

Stream arrival order does not establish chronology across subscription types or snapshot replies. Unvalidated events cannot send notifications or clear a confirmed unread completion. A topology change discards provisional evidence and invalidates in-flight snapshots; retries are coalesced. A snapshot can also reveal a changed identity or address before its layout event arrives. Multiple event-only cycles before validation produce at most the latest confirmed notice. Missing sequences, topology uncertainty, polling, and stream gaps can hide short cycles; a snapshot cannot reconstruct lost history. A move away and back between snapshots cannot always be detected with this protocol. After a gap, an advanced explicit completion sequence can produce a duplicate notice. A server restart is detected through changed identity or a regressing sequence; identical reused identities without sequences cannot be distinguished reliably.

Event queues are bounded (256 lines/events, at most 64 KiB per event line). Overflow, oversized lines, or malformed event/status frames close the subscription, expose polling fallback, and trigger resynchronization. Valid future event names and unknown string statuses remain supported. Snapshot responses retain the 8 MiB limit. Success replies must contain the expected response type; extra metadata fields remain supported.

## Build and run

Requires macOS 14 or later, Swift 6 build tools, and a running local Herdr session.

```sh
./scripts/build.sh --open
```

The script creates `dist/Herdr Bar.app`. Move it to `~/Applications` for regular use. Quit the running app before you launch a new build.

## Development

```sh
swift test
swift test -c release
swift run HerdrBar --check
```

Built with SwiftUI and AppKit. No external packages. macOS CI selects Xcode 16.4 on macOS 15. It checks text format and shell syntax, runs debug and release-mode native tests and mocked release tests, then builds and validates an app bundle. Builds target the host architecture; the release script does not produce a universal binary. macOS 14 is the deployment target, not a claim that CI exercises every supported OS version.

Use spaces, LF line endings, and a final newline in text files. Run `python3 scripts/check-format.py` to check these rules. This check does not require a full Swift source reformat. See the [state and task ownership notes](docs/architecture.md) and [review decisions](docs/review-decisions.md).

Protocol reference: [Herdr socket API](https://herdr.dev/docs/socket-api/). The client uses `session.snapshot`, `agent.focus`, and `events.subscribe`; snapshot `state_change_seq` is optional. Use the schema shipped with your Herdr version (`herdr api schema --json`) when checking compatibility. See [pinned protocol fixtures and client limits](docs/protocol-compatibility.md) and the [native verification checklist](docs/native-verification.md).

Automatic terminal discovery runs process enumeration and parent traversal off the main actor; only AppKit lookup/activation runs on main. It does not cache PIDs. For a read-only timing check, compile and run `scripts/profile-discovery.swift` using the commands at the top of that file.

See the [performance workload matrix](docs/performance.md) for joint app/server CPU, wakeup, and memory measurements. Collection and sorting caches remain deferred until measurements establish a need.

## Release

Set the three-part marketing version and increase the positive integer build number in `Resources/Info.plist`. Commit all changes. Require a passing CI run for this commit before release. Then run:

```sh
./scripts/release.sh v1.0.1
```

The optional tag argument must match the bundle version. An existing tag must point to the source commit. The build number must exceed the last reachable release's build number.

The script rejects a dirty repository and exports `HEAD` into a temporary directory. It runs the exported debug and release-mode tests and build scripts, constructs a fresh app, validates its metadata and CPU architecture, signs it with a Developer ID, notarizes it, and staples the ticket. Changes to the original checkout during the build cannot change its source inputs.

The result is `dist/HerdrBar-VERSION-ARCH.zip`, where `ARCH` is `arm64` or `x86_64`. Distribute only the architectures you have built and verified. The matching `.json` records the source commit, version, build number, Swift and Xcode versions, architecture, minimum macOS version, and archive SHA-256. The `.sha256` file can verify the download. These records make the source traceable; signatures and Apple timestamps mean byte-for-byte identical archives are not promised.

The script does not publish anything. It needs a Developer ID Application identity and notary credentials in the Keychain (`xcrun notarytool store-credentials notarytool`). CI uses ad hoc signing and mocked Apple services; it has no release credentials. Complete the [native verification checklist](docs/native-verification.md) for the distributed artifact.

Publish the archive and its records from the recorded commit. For an Apple Silicon build:

```sh
gh release create v1.0.1 --target SOURCE_COMMIT \
  dist/HerdrBar-1.0.1-arm64.zip \
  dist/HerdrBar-1.0.1-arm64.json \
  dist/HerdrBar-1.0.1-arm64.sha256
```

Replace `SOURCE_COMMIT` with `source_commit` from the manifest. Publishing is a separate step.
