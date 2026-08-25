#!/usr/bin/env bats
# image-refresh reports a STALE operator pin instead of skipping in silence.
#
# backend#2458. `imageRefresh` honours an explicit `images.<name>.digest` pin --
# an operator pin outranks auto-refresh, and that is correct. It used to `continue`
# BEFORE resolving the tag, so nothing ever learned the pin had gone stale.
#
# The cost, measured on tb-client-dev-templates 2026-08-25: jobsManager was pinned
# to a build predating the code that writes the edge Collector's ingest token, so
# the token was never written and the Collector could not be enabled. Every version
# signal read current -- chart label 1.9.67, deployment spec current, pod minutes
# old with 0 restarts -- while the container was days behind. It cost most of a day.
#
# WHY NOT check-digest-drift.sh (backend#1853). That watcher reads
# `client/values.yaml`, the CHART's defaults, where `jobsManager.digest` is "".
# A pin set in an INSTALL's values is invisible to it. This branch runs in the
# cluster, against the effective values, which is the only place that pin exists.
#
# The branch is extracted from the RENDERED chart, not from the template source, so
# these exercise the shell that actually ships.

setup() {
  TMP="$(mktemp -d)"
  CHART="${BATS_TEST_DIRNAME}/../../client"
  helm template t "$CHART" --set clientId=x --set clientPassword=y \
    --set storageClass.create=false > "$TMP/rendered.yaml"
  python3 - "$TMP/rendered.yaml" "$TMP/branch.sh" <<'PYX'
import sys, yaml
def walk(o):
    if isinstance(o, str) and "PIN IS STALE" in o: return o
    if isinstance(o, dict):
        for v in o.values():
            r = walk(v)
            if r: return r
    if isinstance(o, list):
        for v in o:
            r = walk(v)
            if r: return r
script = None
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d: continue
    script = walk(d)
    if script: break
assert script, "no rendered script containing the stale-pin branch"
lines = script.splitlines()
start = next(i for i, l in enumerate(lines) if l.strip() == 'if [ "$pinned" = "1" ]; then')
depth = 0
for end in range(start, len(lines)):
    s = lines[end].strip()
    if s.startswith("if ") or s == "if": depth += 1
    elif s == "fi": 
        depth -= 1
        if depth == 0: break
body = "\n".join(l[6:] if l.startswith(" " * 6) else l.lstrip() for l in lines[start:end + 1])
# drop the trailing `continue` so the branch can run outside a loop
body = body.replace("\ncontinue\n", "\n")
open(sys.argv[2], "w").write(body)
PYX
}
teardown() { rm -rf "$TMP"; }

# Runs the shipped branch with the registry stubbed. $1 = the values pin,
# $2 = what the tag currently resolves to ("" means unresolvable).
run_branch() {
  cat > "$TMP/harness.sh" <<EOF
set -eu
pinned=1
repo="tracebloc/jobs-manager"
IMAGE_TAG="dev"
pin_digest="\${1:-}"
STUB_LATEST="\${2:-}"
annotate_args=""
log() { printf '%s\n' "\$*"; }
get_latest_digest() { [ -n "\$STUB_LATEST" ] && printf '%s' "\$STUB_LATEST"; }
$(cat "$TMP/branch.sh")
printf 'ANNOTATE:%s\n' "\$annotate_args"
EOF
  sh "$TMP/harness.sh" "$1" "$2"
}

@test "a pin matching the current tag is reported CURRENT, not silently skipped" {
  run run_branch "sha256:aaa" "sha256:aaa"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"pin is CURRENT"* ]] || return 1
  [[ "$output" != *"PIN IS STALE"* ]] || return 1
}

@test "a pin the tag has moved past is reported STALE" {
  run run_branch "sha256:aaa" "sha256:bbb"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"PIN IS STALE"* ]] || return 1
}

@test "STALE names BOTH digests, so the reader need not go looking" {
  run run_branch "sha256:aaa" "sha256:bbb"
  [[ "$output" == *"sha256:aaa"* ]] || return 1
  [[ "$output" == *"sha256:bbb"* ]] || return 1
}

@test "STALE says the image is FROZEN — the consequence, not just the fact" {
  run run_branch "sha256:aaa" "sha256:bbb"
  [[ "$output" == *"FROZEN"* ]] || return 1
}

@test "STALE leaves an annotation, so it outlives the log" {
  run run_branch "sha256:aaa" "sha256:bbb"
  [[ "$output" == *"tracebloc.io/stale-pin-jobs-manager=sha256:bbb"* ]] || return 1
}

@test "a CURRENT pin leaves no stale-pin annotation" {
  run run_branch "sha256:aaa" "sha256:aaa"
  [[ "$output" != *"stale-pin-"* ]] || return 1
}

@test "an unresolvable tag is a finding, never reported as agreement" {
  run run_branch "sha256:aaa" ""
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"not knowing is a finding"* ]] || return 1
  [[ "$output" != *"pin is CURRENT"* ]] || return 1
  [[ "$output" != *"PIN IS STALE"* ]] || return 1
}

@test "a pin the tick cannot see is a finding, not agreement" {
  run run_branch "" "sha256:bbb"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"cannot compare"* ]] || return 1
  [[ "$output" != *"pin is CURRENT"* ]] || return 1
}

@test "the branch never fails the tick — telemetry pinning must not stop a refresh" {
  run run_branch "sha256:aaa" "sha256:bbb"
  [ "$status" -eq 0 ] || return 1
}
