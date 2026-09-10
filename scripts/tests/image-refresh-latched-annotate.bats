#!/usr/bin/env bats
# image-refresh writes the Pass-0 stale-pin annotations BEFORE the restart block,
# so they survive a tick that is both off-digest (restart_needed=1) and LATCHED
# (refresh-attempt >= MAX_REFRESH_ATTEMPTS).
#
# #1008 item 1. The #563 flap guard does `WARN + FLAP_KEY + exit 0` once
# the attempt counter reaches MAX -- BEFORE the digest-record annotate at the end
# of the tick. When the stale-pin CLEARS were batched into that final annotate,
# a latched tick dropped them, leaving a FALSE "pin is stale" finding to persist
# forever -- and on the exact tick refresh is dead, when the finding matters most.
# The fix moves the stale-pin writes into their own bounded annotate above the
# restart block; the `last-refreshed` digest record deliberately stays BELOW,
# after a successful rollout (@shujaatTracebloc on #1008).
#
# This asserts BEHAVIOUR: it extracts the shipped tail (the stale-pin annotate +
# the restart block + the final digest annotate) from the RENDERED chart and
# drives it with kubectl and the attempt-counter read stubbed, so re-batching the
# stale-pin writes back into the final annotate reddens.

setup() {
  TMP="$(mktemp -d)"
  CHART="${BATS_TEST_DIRNAME}/../../client"
  helm template t "$CHART" --set clientId=x --set clientPassword=y \
    --set storageClass.create=false > "$TMP/rendered.yaml"
  python3 - "$TMP/rendered.yaml" "$TMP/tail.sh" <<'PYX'
import sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

MARKER = "already on the pinned digest; no-op"

def walk(o):
    if isinstance(o, str) and MARKER in o:
        return o
    if isinstance(o, dict):
        for v in o.values():
            r = walk(v)
            if r:
                return r
    if isinstance(o, list):
        for v in o:
            r = walk(v)
            if r:
                return r

script = None
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d:
        continue
    script = walk(d)
    if script:
        break
assert script, "no rendered image-refresh script found"

lines = script.splitlines()
start = next(i for i, l in enumerate(lines)
            if l.strip() == 'if [ -n "$stale_pin_args" ]; then')
# the LAST `log "tick complete"` -- the flap-guard early exits use the same line,
# so the first match would truncate the region mid-restart-block.
end = max(i for i in range(start, len(lines))
         if lines[i].strip() == 'log "tick complete"')
region = lines[start:end + 1]
indent = min(len(l) - len(l.lstrip()) for l in region if l.strip())
open(sys.argv[2], "w").write("\n".join(l[indent:] for l in region))
PYX
}
teardown() { rm -rf "$TMP"; }

# Drives the shipped tail with kubectl + the ATTEMPT_KEY read stubbed.
#   $1 = STUB_ATTEMPT  what get_annotation returns for ATTEMPT_KEY (the flap count)
#   $2 = JM_SET_ARGS   `set image` args (non-empty => a rollout runs, stubbed OK)
# stale_pin_args and annotate_args are always populated so the test can assert
# which of the two landed.
#
# The kubectl stub records EVERY call to "$TMP/calls.log" rather than stdout,
# because the stale-pin annotate is wrapped in a non-fatal handler that discards
# its stdout (`2>&1 >/dev/null`) -- exactly as a real silent-success annotate
# would. The file captures the call regardless of the caller's redirections;
# assert kubectl invocations against "$TMP/calls.log" and log lines against stdout.
run_tail() {
  : > "$TMP/calls.log"
  cat > "$TMP/harness.sh" <<EOF
set -eu
CALLS="$TMP/calls.log"
RELEASE_NAMESPACE="tracebloc"
DEPLOYMENT_NAME="jobs-manager"
REQUESTS_PROXY_DEPLOYMENT="t-requests-proxy"
RESOURCE_MONITOR_DAEMONSET="t-resource-monitor"
NODE_AGENTS_NAMESPACE="tracebloc-node-agents"
ATTEMPT_KEY="tracebloc.io/refresh-attempt"
FLAP_KEY="tracebloc.io/refresh-flap-detected"
MAX_REFRESH_ATTEMPTS=3
ROLLOUT_TIMEOUT="10m"
restart_needed=1
stale_pin_args=" tracebloc.io/stale-pin-jobs-manager-"
annotate_args=" tracebloc.io/last-refreshed-jobs-manager-digest=sha256:beef"
jm_set_args="\${2:-}"
rp_set_args=""
rm_set_args=""
STUB_ATTEMPT="\${1:-0}"
log() { printf '%s\n' "\$*"; }
kubectl() { printf 'KUBECTL:%s\n' "\$*" >> "\$CALLS"; }
get_annotation() { case "\$1" in "\$ATTEMPT_KEY") printf '%s' "\$STUB_ATTEMPT" ;; esac; }
$(cat "$TMP/tail.sh")
EOF
  sh "$TMP/harness.sh" "${1:-0}" "${2:-}"
}

@test "the harness really extracted the shipped tail (not an empty file)" {
  [ -s "$TMP/tail.sh" ] || return 1
  grep -q 'stale_pin_args' "$TMP/tail.sh" || return 1
  grep -q 'restart_needed' "$TMP/tail.sh" || return 1
}

@test "LATCHED tick (restart_needed=1, attempt>=MAX): stale-pin clear LANDS, digest record does NOT" {
  # The acceptance case (#1008 item 1). attempt=3, MAX=3 -> the flap guard
  # WARNs, annotates FLAP_KEY, and exit 0s. The stale-pin clear must already have
  # been written (before the restart block); the last-refreshed digest record
  # must NOT be (its annotate is after the guard and never runs).
  run run_tail "3"
  [ "$status" -eq 0 ] || return 1
  calls="$(cat "$TMP/calls.log")"
  # stale-pin clear landed, above the restart block
  [[ "$calls" == *"annotate deployment"*"tracebloc.io/stale-pin-jobs-manager-"* ]] || return 1
  # the flap guard fired
  [[ "$output" == *"FLAP DETECTED"* ]] || return 1
  [[ "$calls" == *"tracebloc.io/refresh-flap-detected=3"* ]] || return 1
  # the digest record did NOT land (dropped by the exit 0, as designed)
  [[ "$calls" != *"last-refreshed-jobs-manager-digest=sha256:beef"* ]] || return 1
}

@test "NON-latched tick (attempt<MAX): stale-pin clear lands AND the digest record lands after the rollout" {
  # A healthy re-image tick still writes both, in order: stale-pin first, then
  # the counter bump + rollout, then the digest record. Proves the split did not
  # drop the digest record on the normal path.
  run run_tail "0" "api=docker.io/tracebloc/jobs-manager@sha256:beef"
  [ "$status" -eq 0 ] || return 1
  calls="$(cat "$TMP/calls.log")"
  [[ "$calls" == *"annotate deployment"*"tracebloc.io/stale-pin-jobs-manager-"* ]] || return 1
  # the counter is bumped (not latched) and a rollout runs
  [[ "$calls" == *"tracebloc.io/refresh-attempt=1"* ]] || return 1
  [[ "$calls" == *"set image"* ]] || return 1
  # the digest record DOES land on a healthy tick
  [[ "$calls" == *"last-refreshed-jobs-manager-digest=sha256:beef"* ]] || return 1
  [[ "$output" != *"FLAP DETECTED"* ]] || return 1
}

@test "stale-pin annotate is a SEPARATE call from the digest-record annotate" {
  # The two must not be the same annotate: batching is exactly what dropped the
  # clears on a latched tick. On a healthy tick both run, as two distinct
  # `kubectl annotate` calls -- the stale-pin one carrying the stale-pin key, the
  # other carrying last-refreshed.
  run run_tail "0" "api=docker.io/tracebloc/jobs-manager@sha256:beef"
  [ "$status" -eq 0 ] || return 1
  stale="$(grep -c 'annotate.*stale-pin-jobs-manager' "$TMP/calls.log")"
  digest="$(grep -c 'annotate.*last-refreshed-jobs-manager-digest' "$TMP/calls.log")"
  [ "$stale" -ge 1 ] || return 1
  [ "$digest" -ge 1 ] || return 1
  # and no single annotate carries both keys
  [ "$(grep 'annotate' "$TMP/calls.log" | grep 'stale-pin' | grep -c 'last-refreshed')" -eq 0 ] || return 1
}
