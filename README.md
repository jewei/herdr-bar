# Herdr Bar

A native macOS menu bar app for [Herdr](https://herdr.dev). See which agents are running, need input, or have finished. Click an agent to open its pane in your terminal.

![Herdr Bar agent status palette](docs/palette.png)

The app updates every two seconds. Use Settings to enable notifications, start at login, or choose your terminal.

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

Built with SwiftUI and AppKit. No external packages.
