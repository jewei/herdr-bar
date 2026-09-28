# Native verification

This record separates automated results from interactive macOS checks.
Each result applies to the recorded run or candidate. The
[native release checklist](native-checklist.md) contains the procedure for future
checks.

## Release 1.0.1 check exclusions

On 2026-09-28, the owner excluded these checks from release 1.0.1:

| Check | Status |
| --- | --- |
| VoiceOver navigation and speech | Skipped at the owner's request. The speech check did not complete. |
| Larger-text use | Skipped at the owner's request. Not performed. |
| Startup after logout and login | Skipped at the owner's request. Registration passed, but startup was not tested. |
| Execution on macOS 14 | Skipped at the owner's request. Not performed. |

The excluded checks are not recorded as passed.

## Second review checks

On 2026-09-28, `swift test` and `swift test -c release` each passed 116 tests
on macOS 27.0 arm64 with Swift 6.4. The run included 37 store tests and 79 core
tests.

The new cases covered these behaviors:

- Delayed layout events
- Independent subscription positions and snapshot replies
- Stale event cycles
- Suppression of provisional notifications
- Invalid success response types

Packaging and release tests with mock services passed. They included a check
that a failed `swift test -c release` run preserved the previous archive.

The release executable connected to an isolated Herdr 0.9.1 server for the
[quiet-state performance sample](performance-baseline.md). The installed app
and its preferences remained unchanged.

These results cover the second review's code changes. They do not repeat the
earlier interactive checks or test every supported OS. The release 1.0.1
exclusions still apply.

## Interactive release check

On 2026-09-28, the signed and notarized 1.0.1 candidate, build 2, ran on
macOS 27.0, build 26A428, on Apple Silicon. The check used Herdr 0.9.1,
protocol 22, and Apple Terminal. The candidate source was
`5c40c7877c0be1071e6c9fb3e18756c8daefb38c`.

A separate named Herdr session contained synthetic agent reports.
The production Herdr session remained unchanged. The check produced these results:

| Check | Result |
| --- | --- |
| Keyboard navigation | Up and Down selected rows. Return focused the selected pane and closed the popover. Escape closed the popover. |
| Selection and status | Attention order placed blocked work first. Opening a blocked row preserved its blocked status. |
| Native notifications | macOS permission was granted. Two completions sent separate notifications. An unchanged refresh sent no duplicate. A notification click focused the correct pane and acknowledged its completion. |
| Pane moves and replacements | A notification followed its agent across a workspace move. After the old pane closed, its notification did not focus the replacement pane. |
| Terminal activation | Automatic and explicit Terminal selection worked. Automatic also worked with two attached Terminal clients. An unavailable terminal caused an error and left the completion unread. |
| Connection recovery | Stopping the test server caused Offline status. After the server restarted, Live status returned without manual refresh. The brief Polling phase was not recorded separately. |
| Login item registration | Enabling and disabling the setting changed the native menu state. macOS reported the added login item. Registration was disabled again after the check. |
| Accessibility metadata | Row labels contained full names, agent kind, status, selection, and action hints. A shortened workspace name remained complete in its accessible label. |
| Text contrast | Calculated contrast was at least 4.67:1 for the checked foreground, muted, and status colors against normal and selected row backgrounds. |
| Distribution | The Developer ID signature, notarization, stapled ticket, archive checksum, and Gatekeeper assessment passed. The extracted archive also passed assessment with quarantine set. |

Automated tests cover replacement of an agent session in the same terminal.
This native check did not test that case. Terminal activation does not guarantee
selection of a specific outer window. Contrast and accessible labels do not
establish usability with larger text or assistive technology.

The earlier VoiceOver speech check did not complete because the automation lost
keyboard focus to another application. After the check, VoiceOver and its
temporary AppleScript setting returned to their original state. App preferences
and the installed app were also restored. macOS notification permission remained
granted, while the app's notification preference returned to its original value.

Larger-text use, startup after logout and login, and macOS 14 execution were not
tested. The owner later excluded those checks and VoiceOver for release 1.0.1.
The candidate distributes only `arm64`. These results do not establish Intel
support. No release was published during this check.

## First review follow-up

On 2026-09-28, the checks ran on macOS 27.0, build 26A428, on Apple Silicon
with Xcode 27.0 and Swift 6.4. They produced these results:

- All 100 native Swift tests passed, with 32 store tests and 68 core tests.
- The release build, bundle metadata, `arm64` executable, and ad hoc signature
  passed validation.
- Packaging and release tests passed with mock Apple services. They covered
  source export, source changes during a build, tag rules, build numbers,
  manifests, checksums, and recovery after a failed archive replacement.
- The agents, attention, empty, offline, and loading previews rendered and passed
  visual inspection. The attention summary used an ellipsis when its text
  exceeded the footer width.
- Two independent agents checked every supplied review item and the later fixes.
  The [first review decisions](review-decisions.md) record their findings.

CI selects Xcode 16.4 on macOS 15 and repeats tests and bundle validation.
Pull request and main-branch CI records identify the tested commit.
Release manifests record the source commit and actual signing toolchain.
Mock release tests do not establish Apple notarization of a distribution archive.

## Reliability follow-up

The earlier reliability checks ran on macOS 27.0, build 26A428, on Apple Silicon
with Swift 6.4. They produced these results:

| Check | Result |
| --- | --- |
| `swift test` | All 89 tests passed. |
| `swift build -c release` | The build passed without compiler warnings. |
| `bash scripts/test-packaging.sh` | Isolated bundle construction and release precondition tests passed with mock signing and notarization. |
| Native previews | The agents, attention, empty, offline, and loading previews rendered and passed visual inspection. |
| Protocol fixtures | Five tests covered Herdr 0.9.1 and protocol 22. Retained schema nodes also matched the offline export. |

The tests covered socket closure after malformed frames, polling and retry
recovery, cancelled process discovery, and unread state after terminal activation
failure. Mock activation does not establish real window focus behavior.
Mock signing and notarization do not verify a published archive.

The offline preview used a missing socket. No live Herdr session was stopped
or changed. The preview check left the normal app instance, notification
permissions, and login registration unchanged. The
[preview procedure](development.md#render-the-previews) contains the commands.

The protocol checks covered selected schema nodes. They did not validate the
full schema or establish live-server conformance. The
[protocol reference](protocol-compatibility.md) records fixture sources and limits.

Before process discovery moved off the main actor, 30 optimized samples measured
a median of 5.61 ms, p95 of 6.69 ms, and maximum of 100.67 ms.
The samples measured process scans and parent traversal. They did not measure
AppKit activation or establish a visible UI delay.

Process discovery now runs in a cancellable detached task. AppKit stays on the
main actor. No PID cache was added. The
[discovery measurement procedure](performance.md#measure-terminal-discovery)
contains the command for new samples. Machine load and process count affect
results. Elapsed discovery time does not measure time spent on the main actor.
