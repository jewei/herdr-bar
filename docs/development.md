# Build and test Herdr Bar

Use macOS 14 or later with Swift 6 build tools. Run the commands from the
repository root. To connect the app, start a local Herdr session.

## Build and open the app

1. Quit any running instance of Herdr Bar.
2. Build and open the app:

   ```sh
   ./scripts/build.sh --open
   ```

3. For regular use, move `dist/Herdr Bar.app` to `~/Applications`.

If the app cannot connect, follow the [connection checks](troubleshooting.md#restore-a-connection).

## Run the tests

1. Run the debug tests:

   ```sh
   swift test
   ```

2. Run the release tests:

   ```sh
   swift test -c release
   ```

3. Check packaging and release scripts with mock Apple services:

   ```sh
   bash scripts/test-packaging.sh
   bash scripts/test-release.sh
   ```

To run only the protocol fixture tests, use:

```sh
swift test --filter ProtocolFixtureTests
```

To check the connection to your local Herdr session, use:

```sh
swift run HerdrBar --check
```

## Check text format

Use spaces, LF line endings, and a final newline in text files. Remove trailing
whitespace. These rules do not require a full Swift source reformat.

Run the repository check:

```sh
python3 scripts/check-format.py
```

## Render the previews

Use a macOS GUI session for this check. The previews use synthetic data and a
missing socket for the offline state. They leave live Herdr sessions, notification
permissions, login registration, and the normal app instance unchanged.

1. Build the release executable:

   ```sh
   swift build -c release
   ```

2. Render the preview states:

   ```sh
   binary_dir="$(swift build -c release --show-bin-path)"
   preview_dir="$(mktemp -d)"
   for state in agents attention empty offline loading; do
       "$binary_dir/HerdrBar" --render-preview "$preview_dir/$state.png" --state "$state"
   done
   printf 'Inspect previews in %s\n' "$preview_dir"
   ```

3. Inspect each PNG in the printed directory.

For checks that require interaction with macOS, use the
[native release checklist](native-checklist.md).
