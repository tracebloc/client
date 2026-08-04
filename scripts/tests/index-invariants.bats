#!/usr/bin/env bats
# Tests for scripts/index-invariants.sh — "the public helm index holds only
# stable versions". The guard's whole value is that it fails LOUD on a leak and
# fails CLOSED when it cannot check, so every test here asserts one of the three
# verdicts: leak found, no leak, could-not-check.
#
# The regression that motivated the extraction (Bugbot on client#515): the check
# used to live inline in .github/workflows/release-helm-chart.yaml as
# `printf '%s\n' "$idx" | grep -qF "${TAG#v}"` under `set -o pipefail`. grep -q
# exits on its FIRST match, printf takes SIGPIPE (141), pipefail makes the
# pipeline 141, and the `if` reads a REAL LEAK as "invariants hold". The two
# "past the 64KB pipe buffer" tests below are the ones that pin it.

GUARD_SH=""
IDX=""

setup() {
  GUARD_SH="${BATS_TEST_DIRNAME}/../index-invariants.sh"
  cd "$BATS_TEST_TMPDIR" || return 1
  IDX="$BATS_TEST_TMPDIR/index.yaml"
  seed_index '1.9.8'
}

# A minimally realistic index.yaml holding one client entry at the given version.
seed_index() {
  cat >"$IDX" <<YAML
apiVersion: v1
entries:
  client:
  - apiVersion: v2
    appVersion: "$1"
    created: "2026-07-29T10:00:00Z"
    digest: 0000000000000000000000000000000000000000000000000000000000000000
    name: client
    urls:
    - https://tracebloc.github.io/client/client-$1.tgz
    version: $1
generated: "2026-07-29T10:00:00Z"
YAML
}

# Append stable-only filler so the index is comfortably past the ~64KB pipe
# buffer. The filler must not itself trip an invariant.
pad_index() {
  local i=0
  while [ "$i" -lt 900 ]; do
    printf '  filler-chart-with-a-deliberately-long-name-%s:\n  - name: filler-chart-with-a-deliberately-long-name-%s\n    urls:\n    - https://tracebloc.github.io/client/filler-chart-with-a-deliberately-long-name-%s-1.0.0.tgz\n    version: 1.0.0\n' "$i" "$i" "$i" >>"$IDX"
    i=$((i + 1))
  done
}

guard() { run env INDEX_FILE="$IDX" TAG="${TAG:-}" PRERELEASE="${PRERELEASE:-}" bash "$GUARD_SH"; }

# ── invariant 1: no prerelease-shaped version is ever indexed ────────────────

@test "a stable-only index passes" {
  guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"Index invariants hold"* ]]
}

@test "a prerelease-shaped version in the index is REJECTED" {
  seed_index '1.9.9-rc1'
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"prerelease-shaped versions"* ]]
  [[ "$output" == *"1.9.9-rc1"* ]]
}

@test "a hyphen in a chart NAME is not a prerelease version" {
  printf '  my-ingestor-chart:\n  - name: my-ingestor-chart\n    version: 0.2.0\n' >>"$IDX"
  guard
  [ "$status" -eq 0 ]
}

@test "a hyphen in a URL is not a prerelease version" {
  # The old inline form grepped `version:` lines and then `-` anywhere on the
  # line; the url lines it skipped are the reason that shape looked safe. Pin
  # that the tightened single-grep form still ignores them.
  guard
  [ "$status" -eq 0 ]
}

# ── invariant 2: a prerelease run must not index its own version ─────────────

@test "a prerelease run whose version IS indexed is REJECTED" {
  seed_index '2.0.0'
  TAG='v2.0.0' PRERELEASE='true' guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaked into the public index"* ]]
}

@test "a prerelease run whose version is NOT indexed passes" {
  TAG='v2.0.0-rc1' PRERELEASE='true' guard
  [ "$status" -eq 0 ]
}

@test "a STABLE run does not trip invariant 2 on its own indexed version" {
  TAG='v1.9.8' PRERELEASE='false' guard
  [ "$status" -eq 0 ]
}

@test "the tag is matched literally, not as a regex" {
  # 1.9x8 must not match the indexed 1.9.8 through a live `.` metacharacter.
  TAG='v1.9x8' PRERELEASE='true' guard
  [ "$status" -eq 0 ]
}

# ── fail closed: a guard that cannot check must not claim the index is clean ──

@test "a missing INDEX_FILE fails closed" {
  run env -u INDEX_FILE bash "$GUARD_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INDEX_FILE is not set"* ]]
}

@test "a nonexistent index file fails closed" {
  run env INDEX_FILE="$BATS_TEST_TMPDIR/absent.yaml" bash "$GUARD_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "an empty index read fails closed" {
  : >"$IDX"
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty read"* ]]
}

@test "PRERELEASE=true with no TAG fails closed" {
  TAG='' PRERELEASE='true' guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"TAG is empty"* ]]
}

@test "grep erroring out (exit >= 2) fails closed, it is not 'no leak'" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 2\n' >"$BATS_TEST_TMPDIR/bin/grep"
  chmod +x "$BATS_TEST_TMPDIR/bin/grep"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" INDEX_FILE="$IDX" bash "$GUARD_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"grep exited 2"* ]]
}

# ── the SIGPIPE class this guard must never regress into (Bugbot #515) ───────

@test "a prerelease leak at the TOP of an index past the 64KB pipe buffer is still caught" {
  seed_index '2.0.0'          # the match is in the first few hundred bytes...
  pad_index                    # ...and the rest is far past the pipe buffer
  bytes="$(wc -c <"$IDX")"
  [ "$bytes" -gt 65622 ]       # prove the input really is past the buffer
  TAG='v2.0.0' PRERELEASE='true' guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaked into the public index"* ]]
}

@test "a prerelease-shaped version at the TOP of a large index is still caught" {
  seed_index '1.9.9-rc1'
  pad_index
  bytes="$(wc -c <"$IDX")"
  [ "$bytes" -gt 65622 ]
  guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"prerelease-shaped versions"* ]]
}

@test "a large CLEAN index still passes (the fix did not just invert the verdict)" {
  pad_index
  bytes="$(wc -c <"$IDX")"
  [ "$bytes" -gt 65622 ]
  TAG='v2.0.0' PRERELEASE='true' guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"Index invariants hold"* ]]
}

# ── the workflow actually calls the script (extraction stays wired up) ───────

@test "release-helm-chart.yaml runs the extracted guard, not an inline pipeline" {
  wf="${BATS_TEST_DIRNAME}/../../.github/workflows/release-helm-chart.yaml"
  grep -q 'bash scripts/index-invariants.sh' "$wf"
  # The in-memory index variable the old pipelines fed is gone entirely, so no
  # unbounded producer is left to take SIGPIPE. (The workflow still pipes a
  # ~10-byte "$TAG" into `grep -q` when shaping the tag — a producer that small
  # is written in full before grep can close the pipe, so SIGPIPE is
  # unreachable there. The index read is the one that could exceed the buffer.)
  run grep -n '\$idx' "$wf"
  [ "$status" -eq 1 ]
}
