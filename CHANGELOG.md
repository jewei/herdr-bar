# Changelog

This file records user-visible changes, with the newest version first.
Add changes under Unreleased. At release time, move them into a dated version
entry and leave Unreleased ready for the next changes.

## Unreleased

## [1.0.5](https://github.com/jewei/herdr-bar/releases/tag/v1.0.5) - 2026-10-06

- Show separate orange needs-input, yellow running, and blue done groups in the
  menu bar. Each group has a distinct symbol and its own count.
- Hide groups with zero counts. Click any part of the status item to open the
  agent panel.
- Update and compress the README screenshot.
- Add this changelog and include its maintenance in the release procedure.

## [1.0.4](https://github.com/jewei/herdr-bar/releases/tag/v1.0.4) - 2026-10-03

- Improve agent palette spacing, colors, selection feedback, and long names.
- Place agent and tab details below each workspace name.
- Improve loading, empty, offline, and error states, with fixed retry controls
  and readable last known status while offline.
- Keep selected agents in view and fit recovery controls within the screen.
- Add Reduce Motion and Increase Contrast treatments.

## [1.0.3](https://github.com/jewei/herdr-bar/releases/tag/v1.0.3) - 2026-09-29

- Add a sheep app icon for Finder and notifications. macOS 26 and later apply
  the system icon shape and glass effect; earlier versions show a flat icon.
- Add a script to render and compile the icon from its canvas source.

## [1.0.2](https://github.com/jewei/herdr-bar/releases/tag/v1.0.2) - 2026-09-29

- Accept Herdr's valid `agent_info` reply when opening an agent, fixing the
  incorrect invalid-response error.
- Enlarge the error dismissal button. Escape clears the error before closing
  the palette on a second press.
- Show recovery instructions when an open reply cannot be validated.

## [1.0.1](https://github.com/jewei/herdr-bar/releases/tag/v1.0.1) - 2026-09-28

- Preserve completion state when panes move and prevent old actions from
  clearing newer completions.
- Validate snapshots to prevent false notifications from delayed status events.
- Cancel old requests on connection changes and recover from stream failures.
- Limit event queues and message sizes, with polling after a stream exceeds
  those limits.
- Add setup, troubleshooting, verification, performance, and release guides.

## [1.0.0](https://github.com/jewei/herdr-bar/releases/tag/v1.0.0) - 2026-09-25

- Initial release.
