# Create and publish a release

Use a Mac with a Developer ID Application identity in the Keychain. Store the
notary credentials before you build:

```sh
xcrun notarytool store-credentials notarytool
```

The release script builds for the host CPU architecture. It does not create a
universal binary. CI uses ad hoc signing and mock Apple services without release
credentials.

## Prepare the source commit

1. Set the three-part marketing version in `Resources/Info.plist`.
2. Increase the positive integer build number in the same file.
   The number must exceed the last reachable release's build number.
3. Commit all source changes.
4. Check that CI passes for this commit.

If the release tag already exists, check that it points to this source commit.
The tag must match the bundle version.

## Build the release archive

For a version other than 1.0.1, replace `v1.0.1` below with the matching tag.
You can omit the tag argument to use the bundle version.

Run the release script:

```sh
./scripts/release.sh v1.0.1
```

The script rejects uncommitted source changes and exports `HEAD` to a temporary
directory. It runs the exported debug tests, release tests, and build scripts.
It validates the fresh bundle's metadata and CPU architecture. It then signs
the app with a Developer ID, notarizes it, and staples the ticket.
Changes to the original checkout cannot alter the exported source.

Check that the script creates these files in `dist/`:

- `HerdrBar-VERSION-ARCH.zip` contains the app. `ARCH` is `arm64` or `x86_64`.
- `HerdrBar-VERSION-ARCH.json` records the source commit, version, build number,
  Swift and Xcode versions, architecture, minimum macOS version, and archive
  SHA-256.
- `HerdrBar-VERSION-ARCH.sha256` contains the archive checksum.

The manifest identifies the build source. Signatures and Apple timestamps can
produce different archive bytes across builds.

## Check the release archive

For release 1.0.1, apply the owner's
[recorded check exclusions](native-verification.md#release-101-check-exclusions).

1. Complete the [native release checklist](native-checklist.md) for the archive.
2. Record the results for that source commit and architecture.
3. Distribute only architectures that you have built and verified.

## Publish the release

The build script does not publish files. Before you run the command below,
replace `SOURCE_COMMIT` with `source_commit` from the manifest.
For another version or architecture, use the matching tag and file names.

To publish an Apple Silicon build of version 1.0.1, use:

```sh
gh release create v1.0.1 --target SOURCE_COMMIT \
    dist/HerdrBar-1.0.1-arm64.zip \
    dist/HerdrBar-1.0.1-arm64.json \
    dist/HerdrBar-1.0.1-arm64.sha256
```
