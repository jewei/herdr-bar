# Native verification

## Reliability follow-up

Checked locally on macOS 27.0 (26A428), Apple Silicon, with Swift 6.4:

- `swift test`: 89 tests passed, including malformed-frame socket closure, polling/retry recovery, cancelled process discovery, and failed terminal activation preserving unread state. Mock activation tests do not establish real window focus behavior.
- `swift build -c release`: passed without compiler warnings.
- `bash scripts/test-packaging.sh`: passed the isolated staging and release-guard checks. Signing/notarization is mocked, not a check of a published artifact.
- The release executable rendered the agents, attention, empty, offline, and loading palettes; all five PNGs were visually inspected. The offline preview uses a deliberately missing socket; no live Herdr session is stopped or modified.
- Five schema-fixture tests cover Herdr 0.9.1 / protocol 22. The retained excerpt nodes were also compared with the offline schema export. See [provenance and limits](protocol-compatibility.md); this is not full-schema or live-server conformance validation.
- Before moving discovery off-main, 30 optimized process-scan/ancestor-walk samples measured median 5.61 ms, p95 6.69 ms, and maximum 100.67 ms. This measures process discovery, not AppKit activation or a demonstrated UI stall. Process work now runs in a cancellable detached task, while AppKit stays main-actor isolated. No PID cache was added.

Reproduce the noninteractive native preview check from the repository root:

```sh
swift test
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
preview_dir="$(mktemp -d)"
for state in agents attention empty offline loading; do
    "$binary_dir/HerdrBar" --render-preview "$preview_dir/$state.png" --state "$state"
done
printf 'Inspect previews in %s\n' "$preview_dir"
```

This needs a macOS GUI session. It renders synthetic data without opening the
normal app instance, changing notification permissions, or registering a login
item. The comments in `scripts/profile-discovery.swift` provide a read-only,
repeatable discovery timing command. Results depend on machine load and process
count; elapsed discovery time is not time spent blocking the main actor.

## Interactive release checklist — not performed in this follow-up

Use a disposable Herdr session and a built app installed in `~/Applications`.
Record macOS, architecture, Herdr version, terminal application, and each result.
Do not stop a production session or close working terminals to perform these checks.

- **Notifications:** explicitly enable permission, with Focus/Do Not Disturb accounted for. Complete two tasks in the same agent and verify new notifications; unchanged snapshots must not generate more. Move the pane and test notification routing. Replace the agent session and confirm an old notification cannot open/acknowledge the replacement. Restore the preferred notification setting afterward.
- **Terminal focus:** exercise Automatic and an explicit terminal with multiple windows, multiple attached clients, and named sessions. Check the actual pane being shown, not merely the foreground app. Exact outer window/tab selection remains a documented limitation. Verify a terminal-activation failure leaves completion unread and shows an actionable error.
- **Disconnect/reconnect:** point Herdr Bar at the disposable session, stop/restart that session, and check Disconnected → Polling → Live recovery. Confirm no stale connection can alter the replacement connection's rows. Short work completed entirely during a gap may not be recoverable.
- **Login item:** explicitly toggle on, check System Settings → General → Login Items, log out/in, and confirm a single working app instance. Then restore the original setting. No login registration or permission prompts were triggered by this follow-up.
- **Distribution:** validate signing, notarization, oldest supported macOS, and each distributed CPU architecture separately. Neither preview rendering nor the current host's unit tests establish those properties.
