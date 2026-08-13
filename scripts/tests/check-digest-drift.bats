#!/usr/bin/env bats
# check-digest-drift.sh — the watcher on every mutable label that points at a
# pinned digest (backend#1853).
#
# The registry is stubbed via DRIFT_RESOLVE_STUB so classification can be
# asserted without a network. The two bugs this script actually shipped were
# both in DISCOVERY, not in resolution, so most of these cases are about which
# pins are found and what happens to the ones that cannot be watched:
#
#   1. images:-scoped discovery watched 1 of 3 pins -- squid's pin lives outside
#      images:, and an "empty field means skip" rule dropped mysqlClient in
#      silence.
#   2. IFS=$'\t' collapses runs of tabs (tab is IFS whitespace), so a record with
#      an empty repository AND tag slid the pin into the wrong variable, leaving
#      $pin empty and the row skipped without a word. 0x1f is not whitespace.
#
# Both were found by RUNNING it against the real chart, not by reading it, which
# is why "watched N of M" is asserted explicitly rather than just "exit 0".

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check-digest-drift.sh"
  TMP="$(mktemp -d)"
  SEP="$(printf '\037')"
}
teardown() { rm -rf "$TMP"; }

# A values.yaml with one plain image: repository + tag + digest.
plain_values() {  # <tag> <digest>
  cat > "$TMP/values.yaml" <<EOF
images:
  widget:
    repository: example/widget
    tag: "$1"
    digest: "$2"
EOF
}
stub() { printf '%s%s%s\n' "$1" "$SEP" "$2" > "$TMP/stub"; }
run_check() {
  CHART_VALUES="$TMP/values.yaml" DRIFT_RESOLVE_STUB="$TMP/stub" run "$SCRIPT"
}

D_TRUST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
D_MOVED="sha256:2222222222222222222222222222222222222222222222222222222222222222"

@test "agreement between float and pin is clean" {
  plain_values "1.0" "$D_TRUST"
  stub "example/widget:1.0" "$D_TRUST"
  run_check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"ok "* ]] || return 1
}

@test "the float resolving elsewhere is DRIFT" {
  plain_values "1.0" "$D_TRUST"
  stub "example/widget:1.0" "$D_MOVED"
  run_check
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"DRIFT"* ]] || return 1
}

@test "DRIFT names both digests, so the reader need not go looking" {
  plain_values "1.0" "$D_TRUST"
  stub "example/widget:1.0" "$D_MOVED"
  run_check
  [[ "$output" == *"$D_TRUST"* ]] || return 1
  [[ "$output" == *"$D_MOVED"* ]] || return 1
}

@test "DRIFT does not claim the new build is bad, only unreviewed" {
  plain_values "1.0" "$D_TRUST"
  stub "example/widget:1.0" "$D_MOVED"
  run_check
  [[ "$output" == *"only that nobody has looked at it"* ]] || return 1
}

@test "an unresolvable label is reported, never treated as agreement" {
  plain_values "1.0" "$D_TRUST"
  : > "$TMP/stub"                     # resolves nothing
  run_check
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"UNRESOLVED"* ]] || return 1
}

# --- discovery: bug 1 ------------------------------------------------------

@test "a pin OUTSIDE the images: block is still discovered" {
  cat > "$TMP/values.yaml" <<EOF
egress:
  proxy:
    repository: ubuntu/squid
    tag: "6.6"
    digest: "$D_TRUST"
EOF
  stub "ubuntu/squid:6.6" "$D_TRUST"
  run_check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"1 of 1"* ]] || return 1
}

@test "every pin is discovered, not just the first" {
  cat > "$TMP/values.yaml" <<EOF
images:
  a:
    repository: example/a
    tag: "1"
    digest: "$D_TRUST"
  b:
    repository: example/b
    tag: "2"
    digest: "$D_TRUST"
EOF
  printf 'example/a:1%s%s\nexample/b:2%s%s\n' "$SEP" "$D_TRUST" "$SEP" "$D_TRUST" > "$TMP/stub"
  run_check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"2 of 2"* ]] || return 1
}

@test "an UNPINNED image is not a finding — it made no trust decision" {
  cat > "$TMP/values.yaml" <<EOF
images:
  pinned:
    repository: example/a
    tag: "1"
    digest: "$D_TRUST"
  floats:
    repository: example/b
    tag: "2"
    digest: ""
EOF
  stub "example/a:1" "$D_TRUST"
  run_check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"example/b"* ]] || return 1
}

# --- discovery: bug 2 (the tab-collapse) -----------------------------------

@test "a pin with NO repository is reported UNWATCHABLE, not skipped" {
  cat > "$TMP/values.yaml" <<EOF
images:
  mysteryClient:
    tag: ""
    digest: "$D_TRUST"
EOF
  : > "$TMP/stub"
  run_check
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"UNWATCHABLE"* ]] || return 1
  [[ "$output" == *"mysteryClient"* ]] || return 1
}

@test "a pin with a repository but no tag is reported UNWATCHABLE" {
  cat > "$TMP/values.yaml" <<EOF
images:
  noTag:
    repository: example/x
    tag: ""
    digest: "$D_TRUST"
EOF
  : > "$TMP/stub"
  run_check
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"UNWATCHABLE"* ]] || return 1
}

@test "the empty-field record keeps its pin (the tab-collapse regression)" {
  # With IFS=tab this row collapsed, $pin came out empty, and the row was
  # skipped in total silence. The pin must appear in the output.
  cat > "$TMP/values.yaml" <<EOF
images:
  bothEmpty:
    tag: ""
    digest: "$D_TRUST"
EOF
  : > "$TMP/stub"
  run_check
  [[ "$output" == *"$D_TRUST"* ]] || return 1
}

# --- fail-closed -----------------------------------------------------------

@test "finding zero pins is an ERROR, not 'no drift'" {
  printf 'images:\n  none:\n    repository: example/x\n    tag: "1"\n    digest: ""\n' > "$TMP/values.yaml"
  : > "$TMP/stub"
  run_check
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"examined nothing"* ]] || return 1
}

@test "an unreadable values.yaml is a hard error" {
  CHART_VALUES="$TMP/nope.yaml" run "$SCRIPT"
  [ "$status" -eq 2 ] || return 1
}

@test "a stubbed run says so, loudly, in the banner and the summary" {
  plain_values "1.0" "$D_TRUST"
  stub "example/widget:1.0" "$D_TRUST"
  run_check
  [[ "$output" == *"STUBBED RUN"* ]] || return 1
  [[ "$output" == *"proves nothing about the real registry"* ]] || return 1
}

# --- the ingestor's own shape ---------------------------------------------

@test "prodDigest is paired with channelTags.prod, not with tag:" {
  cat > "$TMP/values.yaml" <<EOF
images:
  ingestor:
    repository: "ghcr.io/tracebloc/ingestor"
    tag: ""
    channelTags:
      dev: "dev"
      stg: "stg"
      prod: "0.8"
    prodDigest: "$D_TRUST"
EOF
  stub "ghcr.io/tracebloc/ingestor:0.8" "$D_MOVED"
  run_check
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"DRIFT"* ]] || return 1
  [[ "$output" == *"ingestor:0.8"* ]] || return 1
}

@test "the ingestor's empty tag: does not make it UNWATCHABLE" {
  cat > "$TMP/values.yaml" <<EOF
images:
  ingestor:
    repository: "ghcr.io/tracebloc/ingestor"
    tag: ""
    channelTags:
      prod: "0.8"
    prodDigest: "$D_TRUST"
EOF
  stub "ghcr.io/tracebloc/ingestor:0.8" "$D_TRUST"
  run_check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"UNWATCHABLE"* ]] || return 1
}
