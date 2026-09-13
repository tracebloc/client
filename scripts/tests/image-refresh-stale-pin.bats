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
#
# PULLABILITY (added with the digestRegistry rule). A digest names bytes on the
# registry it was resolved on; a pin the registry has never held cannot pull, and
# a pod told to pull it never starts -- a digest pin that outlived its registry
# cost an edge two days of timed-out auto-upgrades and, once, its jobs-manager.
# The chart now refuses to RENDER a pin onto a registry it was not resolved on;
# this branch is the runtime backstop for what the render cannot see (a wrong
# `digestRegistry`, a digest the registry has since dropped): before comparing a
# pin for staleness it HEADs the manifest BY DIGEST on IMAGE_REGISTRY, and a 404
# is `ERROR: PIN IS NOT PULLABLE` plus a `stale-pin-<image>=unpullable:<digest>`
# annotation, the workload untouched. The shipped `manifest_status_by_digest` is
# extracted and run too, with curl stubbed to the status under test.

setup() {
  TMP="$(mktemp -d)"
  CHART="${BATS_TEST_DIRNAME}/../../client"
  helm template t "$CHART" --set clientId=x --set clientPassword=y \
    --set storageClass.create=false > "$TMP/rendered.yaml"
  python3 - "$TMP/rendered.yaml" "$TMP/branch.sh" "$TMP/head_fn.sh" <<'PYX'
import sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

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
open(sys.argv[2], "w").write(body)
# The shipped HEAD-by-digest function, so the branch calls the real thing (with
# curl and get_token stubbed) rather than a stand-in written here.
fstart = next(i for i, l in enumerate(lines) if l.strip() == "manifest_status_by_digest() {")
fend = next(i for i in range(fstart, len(lines)) if lines[i].strip() == "}")
fn = "\n".join(l[4:] if l.startswith(" " * 4) else l.lstrip() for l in lines[fstart:fend + 1])
assert "manifests/" in fn and "http_code" in fn, "extracted function is not the HEAD-by-digest check"
open(sys.argv[3], "w").write(fn)
PYX
}
teardown() { rm -rf "$TMP"; }

# Runs the shipped branch with the registry stubbed.
#   $1 = the values pin        $2 = what the tag resolves to ("" = unresolvable)
#   $3 = an existing stale-pin annotation, if any
#   $4 = the HTTP status the manifest HEAD by digest returns (default 200 =
#        pullable, so the staleness cases below run exactly as they always did)
# curl is stubbed to print that status and record its argv in $TMP/curl.args,
# so the by-digest endpoint the shipped function hits can be asserted.
#
# The branch is wrapped in a ONE-ITERATION loop rather than having its `continue`
# statements stripped. Stripping them silently changed control flow -- the early
# "not a values pin" skip fell through into the comparison -- so the harness was
# testing a shape that does not ship. A loop runs the real thing.
run_branch() {
  cat > "$TMP/harness.sh" <<EOF
set -eu
repo="tracebloc/jobs-manager"
# The branch resolves the pin on the registry the pods pull from (IMAGE_REGISTRY),
# not a docker.io literal; the pod supplies it, so the harness must too (set -u).
IMAGE_REGISTRY="docker.io"
IMAGE_TAG="dev"
pinned=1
pin_digest="\${1:-}"
STUB_LATEST="\${2:-}"
EXISTING_ANNOTATION="\${3:-}"
STUB_HEAD="\${4:-200}"
annotate_args=""
# #1008 item 1: the stale-pin writes moved into their own accumulator
# (annotated before the restart block so a latched flap can't drop them). The
# branch under test writes here now, so the harness must define + print it.
stale_pin_args=""
log() { printf '%s\n' "\$*"; }
get_latest_digest() { [ -n "\$STUB_LATEST" ] && printf '%s' "\$STUB_LATEST"; }
get_annotation() { [ -n "\$EXISTING_ANNOTATION" ] && printf '%s' "\$EXISTING_ANNOTATION"; }
get_token() { printf 'stub-token'; }
curl() { printf '%s\n' "\$*" > "$TMP/curl.args"; printf '%s' "\$STUB_HEAD"; }
$(cat "$TMP/head_fn.sh")
for _once in 1; do
$(sed 's/^/  /' "$TMP/branch.sh")
done
printf 'ANNOTATE:%s\n' "\$annotate_args"
printf 'STALEPIN:%s\n' "\$stale_pin_args"
EOF
  sh "$TMP/harness.sh" "$1" "$2" "${3:-}" "${4:-200}"
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

@test "the branch never fails the tick — telemetry pinning must not stop a refresh" {
  run run_branch "sha256:aaa" "sha256:bbb"
  [ "$status" -eq 0 ] || return 1
}

@test "the disabled-monitor exit clears a prior stale-pin finding too" {
  # A stale pin can be remediated INTO this state: drop the digest AND set
  # resourceMonitor: false. Fixing only the CURRENT and unpinned exits would leave
  # the same write-only annotation, just harder to reach. (Bugbot on client#824.)
  run run_branch "" "sha256:bbb" "sha256:old" || return 1
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"tracebloc.io/stale-pin-jobs-manager-"* ]] || return 1
}

@test "the disabled-monitor exit makes no write when there is nothing to clear" {
  run run_branch "" "sha256:bbb" "" || return 1
  [[ "$output" != *"stale-pin-jobs-manager-"* ]] || return 1
}

@test "a pin flag with no pin value is a quiet skip, not a recurring false finding" {
  # resourceMonitor: false also sets PINNED=1 with an empty pin. Reporting it
  # would put "cannot compare" in every healthy edge's log on every tick.
  run run_branch "" "sha256:bbb" || return 1
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"nothing to compare"* ]] || return 1
  [[ "$output" != *"is a finding"* ]] || return 1
  [[ "$output" != *"PIN IS STALE"* ]] || return 1
}

@test "CURRENT clears a previous stale-pin annotation, so it does not outlive the problem" {
  run run_branch "sha256:aaa" "sha256:aaa" "sha256:old" || return 1
  [[ "$output" == *"tracebloc.io/stale-pin-jobs-manager-"* ]] || return 1
}

@test "CURRENT with no existing annotation makes no write at all" {
  run run_branch "sha256:aaa" "sha256:aaa" "" || return 1
  [[ "$output" == *"ANNOTATE:"* ]] || return 1
  [[ "$output" != *"stale-pin-jobs-manager-"* ]] || return 1
}

@test "an unresolvable tag leaves the last known state rather than asserting agreement" {
  run run_branch "sha256:aaa" "" "sha256:old" || return 1
  [[ "$output" == *"last KNOWN state"* ]] || return 1
  [[ "$output" != *"stale-pin-jobs-manager-"* ]] || return 1
}

# --- pullability: the registry must actually hold the pinned digest ------------

@test "the harness really extracted the shipped HEAD-by-digest function (not a stand-in)" {
  [ -s "$TMP/head_fn.sh" ] || return 1
  grep -q '^manifest_status_by_digest() {' "$TMP/head_fn.sh" || return 1
  grep -q 'manifests/\${_digest}' "$TMP/head_fn.sh" || return 1
}

@test "a pin the registry 404s is ERROR: PIN IS NOT PULLABLE, naming the registry" {
  run run_branch "sha256:aaa" "sha256:bbb" "" 404
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"ERROR: PIN IS NOT PULLABLE on docker.io"* ]] || return 1
  [[ "$output" == *"docker.io/tracebloc/jobs-manager@sha256:aaa"* ]] || return 1
}

@test "NOT PULLABLE leaves the unpullable annotation, on the same stale-pin key" {
  run run_branch "sha256:aaa" "sha256:bbb" "" 404
  [[ "$output" == *"tracebloc.io/stale-pin-jobs-manager=unpullable:sha256:aaa"* ]] || return 1
}

@test "NOT PULLABLE short-circuits the staleness compare (stale presumes the bytes exist)" {
  run run_branch "sha256:aaa" "sha256:bbb" "" 404
  [[ "$output" != *"PIN IS STALE"* ]] || return 1
  [[ "$output" != *"pin is CURRENT"* ]] || return 1
  [[ "$output" != *"stale-pin-jobs-manager=sha256:bbb"* ]] || return 1
}

@test "NOT PULLABLE names both remedies and says the workload is untouched" {
  run run_branch "sha256:aaa" "sha256:bbb" "" 404
  [[ "$output" == *"digestRegistry"* ]] || return 1
  [[ "$output" == *"clear"*"images.<name>.digest"* ]] || return 1
  [[ "$output" == *"left untouched"* ]] || return 1
}

@test "NOT PULLABLE never fails the tick" {
  run run_branch "sha256:aaa" "sha256:bbb" "" 404
  [ "$status" -eq 0 ] || return 1
}

@test "a pullable pin (200) raises no pullability error and proceeds to the compare" {
  run run_branch "sha256:aaa" "sha256:aaa" "" 200
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"NOT PULLABLE"* ]] || return 1
  [[ "$output" != *"could not verify"* ]] || return 1
  [[ "$output" == *"pin is CURRENT"* ]] || return 1
}

@test "an unverifiable HEAD (transport 000) is a finding, not agreement -- and the compare still runs" {
  run run_branch "sha256:aaa" "sha256:bbb" "" 000
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"could not verify the pin is pullable on docker.io"* ]] || return 1
  [[ "$output" == *"not knowing is a finding"* ]] || return 1
  [[ "$output" != *"NOT PULLABLE"* ]] || return 1
  [[ "$output" == *"PIN IS STALE"* ]] || return 1
}

@test "a 401/429 is likewise 'could not tell', never NOT PULLABLE" {
  run run_branch "sha256:aaa" "sha256:aaa" "" 429
  [[ "$output" == *"could not verify"*"(HTTP 429)"* ]] || return 1
  [[ "$output" != *"NOT PULLABLE"* ]] || return 1
}

@test "the shipped function HEADs the manifest BY DIGEST on IMAGE_REGISTRY, with the registry token" {
  run run_branch "sha256:aaa" "sha256:aaa" "" 200
  [ -s "$TMP/curl.args" ] || return 1
  args="$(cat "$TMP/curl.args")"
  [[ "$args" == *"-I"* ]] || return 1
  [[ "$args" == *"https://registry-1.docker.io/v2/tracebloc/jobs-manager/manifests/sha256:aaa"* ]] || return 1
  [[ "$args" == *"Authorization: Bearer stub-token"* ]] || return 1
  [[ "$args" == *"application/vnd.oci.image.index.v1+json"* ]] || return 1
  [[ "$args" == *"%{http_code}"* ]] || return 1
}

@test "the pullability check runs BEFORE the tag is resolved (404 makes no compare call)" {
  # STUB_LATEST empty would otherwise log the unresolvable finding; a 404 must
  # exit the image before get_latest_digest is consulted at all.
  run run_branch "sha256:aaa" "" "" 404
  [[ "$output" == *"NOT PULLABLE"* ]] || return 1
  [[ "$output" != *"could not resolve"* ]] || return 1
}
