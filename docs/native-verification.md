# Native verification

## Second review checks — 2026-09-28

On macOS 27.0 arm64 with Swift 6.4, both `swift test` and
`swift test -c release` passed 116 tests: 37 store tests and 79 core tests.
The new cases cover delayed topology notices, independently advancing subscription
cursors and snapshots, stale event cycles, provisional notification suppression,
and invalid success response types. Packaging and release-script mocks passed,
including preservation of the previous artifact after an optimized-test failure.

These checks exercise the second review's code changes. The earlier interactive
results below apply to their recorded candidate. They do not establish a new
full GUI or supported-OS verification run. VoiceOver remains skipped by owner
request; larger text, real logout/login, and macOS 14 execution remain open.

## Interactive release check — 2026-09-28

The signed and notarized 1.0.1 candidate (build 2) was tested on macOS 27.0
(26A428), Apple Silicon, with Herdr 0.9.1 / protocol 22 and Apple Terminal.
The candidate source was `5c40c7877c0be1071e6c9fb3e18756c8daefb38c`.
A separate named Herdr session held synthetic agent reports. The production
Herdr session was not stopped or changed.

| Check | Result |
| --- | --- |
| Keyboard navigation | Up and Down selected rows. Return focused the selected pane and closed the popover. Escape closed the popover. |
| Selection and status | Attention order put blocked work first. Opening a blocked row kept its blocked status. |
| Native notifications | macOS permission was granted. Two distinct completions sent notices. An unchanged refresh did not send another notice. Clicking a notice focused the correct pane and acknowledged its completion. |
| Pane moves and replacements | A notice followed its agent after a move to another workspace. After the old pane was closed, its notice did not focus the replacement pane. Replacing an agent session in the same terminal remains covered by automated tests, not this native check. |
| Terminal activation | Automatic and explicit Terminal selection worked. Automatic selection also worked with two attached Terminal clients. Selecting an unavailable terminal showed an error and kept the completion unread. Exact outer window selection is not guaranteed. |
| Connection recovery | Stopping only the test server produced Offline. After that server restarted, the app returned to Live without a manual refresh. The brief Polling phase was not separately captured. |
| Login item registration | Enabling and disabling the setting changed the native menu state. macOS reported the added login item. Registration was disabled again. A real logout/login cycle was not performed. |
| Accessibility metadata | Row labels exposed full names, agent kind, status, selection, and action hints. A long workspace name was shortened in the visible row and retained in its accessible label. |
| Text contrast | Calculated theme contrast was at least 4.67:1 for the checked foreground, muted, and status colors against normal and selected row backgrounds. This does not establish larger-text or assistive-technology usability. |
| Distribution | Developer ID signature, Apple notarization, stapled ticket, archive checksum, and Gatekeeper assessment passed. The extracted archive also passed assessment with quarantine set. |

VoiceOver navigation and speech checks are skipped for release 1.0.1 at the
owner's request on 2026-09-28. The earlier speech check did not complete because
the automation lost keyboard focus to another application. Accessible labels
alone do not prove spoken navigation works. VoiceOver, its temporary AppleScript
setting, app preferences, and the installed app were restored after the check.
macOS notification permission remains granted; the app's original notification
preference was restored separately.

The remaining release checks are larger-text use, a real logout/login cycle,
and execution on the oldest supported macOS version. The logout test needs a
separate session because it would close current work. Only `arm64` is distributed
by this candidate; these results do not establish Intel support. No release was
published during this check.

## Independent review follow-up — 2026-09-28

Checked on macOS 27.0 (26A428), Apple Silicon, with Xcode 27.0 and Swift 6.4:

- All 100 native Swift tests passed: 32 store tests and 68 core tests.
- The release build passed. Bundle metadata, the `arm64` executable, and its
  ad hoc code signature passed validation.
- Packaging and full release tests passed with mock Apple services. They cover
  source export, source changes during a build, tag/build rules, provenance,
  checksums, and rollback after artifact promotion failure.
- All five release-build previews rendered and were inspected: agents,
  attention, empty, offline, and loading. The attention summary uses an ellipsis
  when its text exceeds the available footer width.
- Two independent agents checked every supplied review item and checked the
  follow-up fixes. See [decisions and limits](review-decisions.md).

CI selects Xcode 16.4 on macOS 15 and repeats tests and bundle validation.
See the pull request and main-branch CI results for the tested commit. Release
manifests record the source commit and actual signing build toolchain. Mock
release tests do not establish Apple notarization of a distribution artifact.

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

## Repeatable interactive release checklist

Use a disposable Herdr session and a built app installed in `~/Applications`.
Record macOS, architecture, Herdr version, terminal application, and each result.
Do not stop a production session or close working terminals to perform these checks.

- **Notifications:** explicitly enable permission, with Focus/Do Not Disturb accounted for. Complete two tasks in the same agent and verify new notifications; unchanged snapshots must not generate more. Move the pane and test notification routing. Replace the agent session and confirm an old notification cannot open/acknowledge the replacement. Restore the preferred notification setting afterward.
- **Terminal focus:** exercise Automatic and an explicit terminal with multiple windows, multiple attached clients, and named sessions. Check the actual pane being shown, not merely the foreground app. Exact outer window/tab selection remains a documented limitation. Verify a terminal-activation failure leaves completion unread and shows an actionable error.
- **Disconnect/reconnect:** point Herdr Bar at the disposable session, stop/restart that session, and check Disconnected → Polling → Live recovery. Confirm no stale connection can alter the replacement connection's rows. Short work completed entirely during a gap may not be recoverable.
- **Login item:** explicitly toggle on, check System Settings → General → Login Items, log out/in, and confirm a single working app instance. Then restore the original setting. The check above covers registration only.
- **Distribution:** validate signing, notarization, oldest supported macOS, and each distributed CPU architecture separately. Neither preview rendering nor the current host's unit tests establish those properties.
