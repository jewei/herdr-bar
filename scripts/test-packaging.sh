#!/bin/bash
# Deterministic packaging/release-guard regression tests; no Swift or Apple services.
set -euo pipefail

scripts_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-packaging.XXXXXX")"
test_dir="$(cd "$test_dir" && pwd -P)"
trap 'rm -rf "$test_dir"' EXIT
export TEST_PROJECT="$test_dir/project with spaces"
export MOCK_LOG="$test_dir/commands.log"
export REAL_MV="$(command -v mv)"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$TEST_PROJECT/scripts" "$TEST_PROJECT/Resources" "$TEST_PROJECT/bin" "$test_dir/mocks"
cp "$scripts_dir/build.sh" "$scripts_dir/release.sh" "$TEST_PROJECT/scripts/"
printf 'fresh executable\n' > "$TEST_PROJECT/bin/HerdrBar"
printf 'fresh plist\n' > "$TEST_PROJECT/Resources/Info.plist"

# Mock executables are confined to this temporary fixture and subprocess PATH.
printf '%s\n' '#!/bin/bash
set -eu
printf "swift %s\n" "$*" >> "$MOCK_LOG"
[[ "${MOCK_FAIL:-}" != build ]] || exit 1
if [[ "$*" == "build -c release --show-bin-path" ]]; then
    [[ "${MOCK_FAIL:-}" != bin-path ]] || exit 1
    printf "%s/bin\n" "$TEST_PROJECT"
elif [[ "$*" != "build -c release" ]]; then
    exit 1
fi' > "$test_dir/mocks/swift"
printf '%s\n' '#!/bin/bash
set -eu
printf "codesign %s\n" "$*" >> "$MOCK_LOG"
app="${!#}"
if [[ "$1" == --force ]]; then
    [[ "${MOCK_FAIL:-}" != sign ]] || exit 1
    mkdir -p "$app/Contents/_CodeSignature"
    printf "fresh signature\n" > "$app/Contents/_CodeSignature/CodeResources"
elif [[ "$1" == --verify ]]; then
    [[ "${MOCK_FAIL:-}" != verify ]] || exit 1
    test -f "$app/Contents/_CodeSignature/CodeResources"
else
    exit 1
fi' > "$test_dir/mocks/codesign"
printf '%s\n' '#!/bin/bash
set -eu
if [[ "${MOCK_FAIL:-}" == promote && "$#" == 2 && "$2" == "$TEST_PROJECT/dist/Herdr Bar.app" && "$1" != */previous.app ]]; then
    exit 1
fi
exec "$REAL_MV" "$@"' > "$test_dir/mocks/mv"
printf '%s\n' '#!/bin/bash
printf "release guard passed\n" >> "$MOCK_LOG"
exit 1' > "$test_dir/mocks/plutil"
# Refuse any accidental attempt to contact Apple, open apps, or package a release.
for command in xcrun ditto spctl open; do
    printf '%s\n' '#!/bin/bash' 'exit 99' > "$test_dir/mocks/$command"
done
chmod +x "$test_dir/mocks/"*
export PATH="$test_dir/mocks:$PATH"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_no_staging() {
    local leftovers
    shopt -s nullglob
    leftovers=("$TEST_PROJECT/dist/".HerdrBar-stage.*)
    shopt -u nullglob
    [[ ${#leftovers[@]} == 0 ]] || fail 'staging directories leaked'
}
seed_old_bundle() {
    rm -rf "$TEST_PROJECT/dist"
    local app="$TEST_PROJECT/dist/Herdr Bar.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/_CodeSignature"
    printf 'old executable\n' > "$app/Contents/MacOS/HerdrBar"
    printf 'old plist\n' > "$app/Contents/Info.plist"
    printf 'stale resource\n' > "$app/Contents/Resources/deleted-resource.txt"
    printf 'stale signature\n' > "$app/Contents/_CodeSignature/stale"
}

seed_old_bundle
bash "$TEST_PROJECT/scripts/build.sh" > "$test_dir/output" 2>&1
app="$TEST_PROJECT/dist/Herdr Bar.app"
[[ ! -e "$app/Contents/Resources/deleted-resource.txt" ]] || fail 'stale resource survived'
[[ ! -e "$app/Contents/_CodeSignature/stale" ]] || fail 'stale signature survived'
cmp "$TEST_PROJECT/bin/HerdrBar" "$app/Contents/MacOS/HerdrBar"
cmp "$TEST_PROJECT/Resources/Info.plist" "$app/Contents/Info.plist"
[[ -x "$app/Contents/MacOS/HerdrBar" ]] || fail 'executable bit missing'
[[ -f "$app/Contents/_CodeSignature/CodeResources" ]] || fail 'bundle was not signed'
assert_no_staging
printf 'PASS: fresh bundle excludes stale resources and signatures\n'

for failure in build bin-path sign verify promote missing-binary missing-plist; do
    seed_old_bundle
    rm -rf "$test_dir/expected.app"
    cp -R "$app" "$test_dir/expected.app"
    case "$failure" in
        missing-binary) "$REAL_MV" "$TEST_PROJECT/bin/HerdrBar" "$test_dir/saved" ;;
        missing-plist) "$REAL_MV" "$TEST_PROJECT/Resources/Info.plist" "$test_dir/saved" ;;
    esac
    if MOCK_FAIL="$failure" bash "$TEST_PROJECT/scripts/build.sh" > "$test_dir/output" 2>&1; then
        fail "$failure unexpectedly succeeded"
    fi
    diff -r "$test_dir/expected.app" "$app" || fail "$failure replaced existing bundle"
    assert_no_staging
    case "$failure" in
        missing-binary) "$REAL_MV" "$test_dir/saved" "$TEST_PROJECT/bin/HerdrBar" ;;
        missing-plist) "$REAL_MV" "$test_dir/saved" "$TEST_PROJECT/Resources/Info.plist" ;;
    esac
    printf 'PASS: %s failure preserves existing bundle\n' "$failure"
done

# Release guards must reject changes anywhere, including with untracked display disabled.
cd "$TEST_PROJECT"
printf '.build/\ndist/\nbin/\n' > .gitignore
mkdir -p Tests .github/workflows
printf 'test fixture\n' > Tests/example.swift
printf 'workflow fixture\n' > .github/workflows/ci.yml
git init -q
git config user.name 'Packaging Test'
git config user.email 'packaging@example.invalid'
git config status.showUntrackedFiles no
git add .
git -c commit.gpgsign=false commit -qm 'fixture'
mkdir -p .build
printf 'ignored build artifact\n' > .build/artifact

assert_release_guard() {
    local expected="$1" output
    : > "$MOCK_LOG"
    if bash scripts/release.sh > "$test_dir/output" 2>&1; then
        fail 'release should stop at guard or mocked plutil'
    fi
    output="$(< "$test_dir/output")"
    if [[ "$expected" == clean ]]; then
        [[ "$(< "$MOCK_LOG")" == 'release guard passed' ]] || fail 'ignored artifacts blocked release'
    else
        [[ ! -s "$MOCK_LOG" ]] || fail 'dirty release reached build/signing tools'
        [[ "$output" == *'Commit or remove all tracked and untracked source-tree changes'* ]] || fail 'missing dirty-tree diagnostic'
    fi
}
assert_release_guard clean
for source in Tests/example.swift scripts/build.sh .github/workflows/ci.yml; do
    printf 'dirty\n' >> "$source"
    assert_release_guard dirty
    git checkout -- "$source"
done
printf 'staged change\n' >> Tests/example.swift
git add Tests/example.swift
assert_release_guard dirty
git reset -q HEAD -- Tests/example.swift
git checkout -- Tests/example.swift
printf 'untracked source\n' > Tests/new.swift
assert_release_guard dirty
rm Tests/new.swift
assert_release_guard clean
printf 'PASS: release rejects tracked, staged, and untracked changes; ignores build artifacts\n'
