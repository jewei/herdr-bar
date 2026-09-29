#!/bin/bash
# Test the full release path with mock Apple services in an isolated Git repository.
set -euo pipefail
scripts_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-release-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export TEST_PROJECT="$test_dir/project with spaces"
export RELEASE_TEST_LOG="$test_dir/commands.log"
export REAL_RELEASE_MV="$(command -v mv)"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$TEST_PROJECT/scripts" "$TEST_PROJECT/Resources" "$test_dir/mocks"
cp "$scripts_dir/build.sh" "$scripts_dir/release.sh" "$scripts_dir/verify-bundle.py" "$TEST_PROJECT/scripts/"
cp "$scripts_dir/../Resources/"{Info.plist,AppIcon.icns,Assets.car} "$TEST_PROJECT/Resources/"
printf '.build/\ndist/\n' > "$TEST_PROJECT/.gitignore"
printf 'fixed source\n' > "$TEST_PROJECT/README.md"
cat > "$test_dir/mocks/swift" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$PWD" != "$TEST_PROJECT" ]] || { echo 'Built from mutable checkout' >&2; exit 1; }
printf 'swift %s\n' "$*" >> "$RELEASE_TEST_LOG"
case "$*" in
    test)
        [[ "${MOCK_FAILURE:-}" != tests ]] || exit 1
        if [[ "${MOCK_MUTATE_SOURCE:-}" == 1 ]]; then
            printf 'changed during release\n' >> "$TEST_PROJECT/README.md"
        fi
        ;;
    'test -c release') [[ "${MOCK_FAILURE:-}" != optimized-tests ]] || exit 1 ;;
    'build -c release') mkdir -p .build/release; printf 'mock executable\n' > .build/release/HerdrBar ;;
    'build -c release --show-bin-path') printf '%s/.build/release\n' "$PWD" ;;
    --version) printf 'Swift test toolchain\n' ;;
    *) exit 1 ;;
esac
MOCK
cat > "$test_dir/mocks/codesign" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "$RELEASE_TEST_LOG"
[[ "${MOCK_FAILURE:-}" != sign ]] || exit 1
MOCK
cat > "$test_dir/mocks/xcrun" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "$RELEASE_TEST_LOG"
case "$1 $2" in
    'notarytool submit')
        if [[ "${MOCK_FAILURE:-}" == notary ]]; then
            printf '{"status":"Invalid","id":"test-id"}\n'
        else
            printf '{"status":"Accepted","id":"test-id"}\n'
        fi ;;
    'stapler staple'|'stapler validate') exit 0 ;;
    *) exit 1 ;;
esac
MOCK
cat > "$test_dir/mocks/spctl" <<'MOCK'
#!/bin/bash
printf 'spctl %s\n' "$*" >> "$RELEASE_TEST_LOG"
[[ "${MOCK_FAILURE:-}" != assess ]]
MOCK
printf '%s\n' '#!/bin/bash' 'echo arm64' > "$test_dir/mocks/lipo"
printf '%s\n' '#!/bin/bash' 'echo "Xcode test toolchain"' > "$test_dir/mocks/xcodebuild"
cat > "$test_dir/mocks/mv" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ "${MOCK_FAILURE:-}" == promote && "$*" == *'/new/'*'.json'* ]]; then exit 1; fi
exec "$REAL_RELEASE_MV" "$@"
MOCK
chmod +x "$test_dir/mocks/"*
export PATH="$test_dir/mocks:$PATH"
cd "$TEST_PROJECT"
git init -q
git config user.name 'Release Test'
git config user.email 'release@example.invalid'
plutil -replace CFBundleShortVersionString -string 1.0.0 Resources/Info.plist
plutil -replace CFBundleVersion -string 1 Resources/Info.plist
git add .
git -c commit.gpgsign=false commit -qm 'previous release'
git tag v1.0.0
plutil -replace CFBundleShortVersionString -string 1.0.1 Resources/Info.plist
plutil -replace CFBundleVersion -string 2 Resources/Info.plist
git add .
git -c commit.gpgsign=false commit -qm 'next release'
revision="$(git rev-parse HEAD)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The original checkout changes after export. All build inputs must stay pinned.
MOCK_MUTATE_SOURCE=1 bash scripts/release.sh v1.0.1 > "$test_dir/output" 2>&1 || { cat "$test_dir/output"; exit 1; }
python3 - "$revision" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
manifest = json.loads(Path('dist/HerdrBar-1.0.1-arm64.json').read_text())
archive = Path('dist/HerdrBar-1.0.1-arm64.zip')
assert manifest['source_commit'] == sys.argv[1]
assert manifest['version'] == '1.0.1' and manifest['build_number'] == '2'
assert manifest['architecture'] == 'arm64' and manifest['notarized'] is True
assert manifest['sha256'] == hashlib.sha256(archive.read_bytes()).hexdigest()
assert manifest['swift'] == 'Swift test toolchain'
assert manifest['tag'] == 'v1.0.1'
PY
[[ "$(< README.md)" == *'changed during release'* ]] || fail 'mutation did not run'
grep -Fxq 'swift test -c release' "$RELEASE_TEST_LOG" || fail 'optimized tests did not run'
git checkout -- README.md
(cd dist && shasum -a 256 -c HerdrBar-1.0.1-arm64.sha256)
printf 'PASS: fixed source, architecture, manifest, and archive checksum\n'

for suffix in zip json sha256; do
    cp "dist/HerdrBar-1.0.1-arm64.$suffix" "$test_dir/accepted.$suffix"
done
for failure in tests optimized-tests sign notary assess promote; do
    if MOCK_FAILURE="$failure" bash scripts/release.sh > "$test_dir/output" 2>&1; then
        fail "$failure unexpectedly succeeded"
    fi
    for suffix in zip json sha256; do
        cmp "dist/HerdrBar-1.0.1-arm64.$suffix" "$test_dir/accepted.$suffix"
    done
    printf 'PASS: %s failure preserves the previous artifact\n' "$failure"
done
if bash scripts/release.sh v9.9.9 > "$test_dir/output" 2>&1; then
    fail 'mismatched version tag was accepted'
fi
git tag v1.0.1 HEAD^
if bash scripts/release.sh > "$test_dir/output" 2>&1; then
    fail 'tag on another commit was accepted'
fi
git tag -d v1.0.1 >/dev/null
plutil -replace CFBundleVersion -string 1 Resources/Info.plist
git add Resources/Info.plist
git -c commit.gpgsign=false commit -qm 'invalid build number'
if bash scripts/release.sh > "$test_dir/output" 2>&1; then
    fail 'reused build number was accepted'
fi
printf 'PASS: mismatched tags and reused build numbers are rejected\n'
