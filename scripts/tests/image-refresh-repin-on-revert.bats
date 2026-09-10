#!/usr/bin/env bats
# image-refresh RE-PINS the digest when a helm re-render reverted the workload
# to `repo:tag`, instead of no-op'ing off the annotation alone.
#
# client-runtime#199. `recorded == latest` proves the REGISTRY digest has not moved; it
# does NOT prove the workload is running it. `helm upgrade --reset-then-reuse-values`
# (the fleet auto-upgrade) re-renders the Deployment back to `repo:tag` and discards
# an earlier `set image repo@digest` pin -- and on a node whose `:tag` layer is
# stale that silently runs an OLD control-plane image (client-runtime#199). So the
# loop reads each workload's LIVE image and re-pins whenever it is off the digest.
#
# These assert BEHAVIOUR, not text presence: the earlier helm-unittest checks that
# `workload_image_for_repo`/`have=`/`proxy_on_digest` merely APPEAR in the script
# still pass if the comparison is inverted. This extracts the shipped branch from
# the RENDERED chart and drives it with the registry + live-workload reads stubbed,
# so an inverted comparison reddens.

setup() {
  TMP="$(mktemp -d)"
  CHART="${BATS_TEST_DIRNAME}/../../client"
  helm template t "$CHART" --set clientId=x --set clientPassword=y \
    --set storageClass.create=false > "$TMP/rendered.yaml"
  python3 - "$TMP/rendered.yaml" "$TMP/branch.sh" <<'PYX'
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
assert script, "no rendered script containing the re-pin branch"

lines = script.splitlines()
start = next(i for i, l in enumerate(lines)
             if l.strip() == 'if [ "$recorded" = "$latest" ]; then')
# The branch ends at the `esac` that closes the `case "$repo" in` re-image block
# (no nested `case`, so the first `esac` after it closes it).
case_at = next(i for i in range(start, len(lines))
               if lines[i].strip() == 'case "$repo" in')
end = next(i for i in range(case_at, len(lines)) if lines[i].strip() == "esac")
body = "\n".join(l[6:] if l.startswith(" " * 6) else l.lstrip()
                 for l in lines[start:end + 1])
open(sys.argv[2], "w").write(body)
PYX
}
teardown() { rm -rf "$TMP"; }

# Runs the shipped re-pin branch with the registry HEAD (already known: recorded
# == latest) and the two LIVE-image reads stubbed.
#   $1 = STUB_API     what workload_image_for_repo returns ("" = unreadable)
#   $2 = STUB_PROXY   what requests_proxy_image returns   ("" = unreadable)
#   $3 = RP_PINNED    "1" opts the requests-proxy out of following the digest
#   $4 = PENDING      the ATTEMPT_KEY value carried in (0 = no unfinished re-image)
#   $5 = STUB_APPLIED         get_annotation value for ${applied_key}
#                             (non-empty = a digest was rolled here before)
#   $6 = STUB_FIRST_OBSERVED  get_annotation value for ${first_observed_key}
#                             (non-empty = we recorded this workload's first,
#                              annotation-less tick here)
# The off-digest arm skips ONLY on first_observed present AND applied absent
# (fresh install). applied present rolls (established edge); NEITHER marker rolls
# (pre-marker/legacy edge -- not stranded on the upgrade hop). #1008.
#
# The branch is wrapped in a ONE-ITERATION loop so its `continue` statements run
# as they ship, rather than being stripped (which would change control flow).
run_branch() {
  cat > "$TMP/harness.sh" <<EOF
set -eu
repo="tracebloc/jobs-manager"
key="tracebloc.io/last-refreshed-jobs-manager-digest"
applied_key="tracebloc.io/digest-applied-jobs-manager"
first_observed_key="tracebloc.io/first-observed-jobs-manager"
IMAGE_REGISTRY="docker.io"
IMAGE_TAG="dev"
REQUESTS_PROXY_DEPLOYMENT="t-requests-proxy"
REQUESTS_PROXY_PINNED="\${3:-0}"
latest="sha256:aaa"
recorded="sha256:aaa"
STUB_API="\${1:-}"
STUB_PROXY="\${2:-}"
pending_attempt="\${4:-0}"
STUB_APPLIED="\${5:-}"
STUB_FIRST_OBSERVED="\${6:-}"
MAX_REFRESH_ATTEMPTS=3
restart_needed=0
annotate_args=""
jm_set_args=""
rp_set_args=""
rm_set_args=""
RELEASE_NAMESPACE="tracebloc"
DEPLOYMENT_NAME="jobs-manager"
ATTEMPT_KEY="tracebloc.io/refresh-attempt"
FLAP_KEY="tracebloc.io/refresh-flap-detected"
log() { printf '%s\n' "\$*"; }
kubectl() { printf 'KUBECTL:%s\n' "\$*"; }
workload_image_for_repo() { [ -n "\$STUB_API" ] && printf '%s' "\$STUB_API"; }
requests_proxy_image() { [ -n "\$STUB_PROXY" ] && printf '%s' "\$STUB_PROXY"; }
# Only the two markers are read inside this branch. Model the real get_annotation:
# return 0 with the value (empty = annotation ABSENT), never non-zero -- a
# non-zero return means a kubectl/jq READ ERROR, which the branch handles
# separately. Using \`[ -n ] && printf\` here would return non-zero on an empty
# stub and be misread as a read error.
get_annotation() {
  case "\$1" in
    "\$applied_key")        printf '%s' "\$STUB_APPLIED" ;;
    "\$first_observed_key") printf '%s' "\$STUB_FIRST_OBSERVED" ;;
  esac
}
for _once in 1; do
$(sed 's/^/  /' "$TMP/branch.sh")
done
printf 'RESTART:%s\n' "\$restart_needed"
printf 'JM:%s\n' "\$jm_set_args"
printf 'RP:%s\n' "\$rp_set_args"
printf 'ANNOTATE:%s\n' "\$annotate_args"
EOF
  sh "$TMP/harness.sh" "${1:-}" "${2:-}" "${3:-}" "${4:-0}" "${5:-}" "${6:-}"
}

@test "ESTABLISHED edge reverted to :tag re-pins the digest (restart_needed=1)" {
  # A digest was applied here before (applied marker present, $5="1"), then a helm
  # re-render reverted the workload onto :tag -- the client-runtime#199 repair
  # must roll. #1008.
  run run_branch "docker.io/tracebloc/jobs-manager:dev" "" "1" "0" "1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"RESTART:1"* ]] || return 1
  [[ "$output" == *"api=docker.io/tracebloc/jobs-manager@sha256:aaa"* ]] || return 1
  [[ "$output" == *"re-pinning the digest"* ]] || return 1
  # the re-image records the digest AND stamps the applied marker, in one annotate
  [[ "$output" == *"tracebloc.io/digest-applied-jobs-manager=1"* ]] || return 1
}

@test "FRESH install (first-observed here, never applied) does NOT roll -- stays on :tag" {
  # #1008. recorded == latest, workload on :tag, first_observed set ($6="1") and
  # applied absent ($5="") -- a workload we watched born on :tag here. Rolling
  # would pay the full #563 flap-path / Recreate cost for byte-identical content
  # the install already pulled. The tick must leave it on :tag.
  run run_branch "docker.io/tracebloc/jobs-manager:dev" "" "1" "0" "" "1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"fresh install"* ]] || return 1
  [[ "$output" == *"NOT rolling"* ]] || return 1
  [[ "$output" == *"RESTART:0"* ]] || return 1
  # nothing queued for a rollout, and no digest/marker write this tick
  [[ "$output" != *"JM:api="* ]] || return 1
  [[ "$output" != *"re-pinning the digest"* ]] || return 1
  [[ "$output" != *"digest-applied-jobs-manager=1"* ]] || return 1
}

@test "PRE-MARKER / legacy edge (NEITHER marker) still gets the repair roll" {
  # LukasWodka on #1008: an edge pinned by a version predating these markers has
  # neither ($5="" $6=""). The upgrade shipping this chart reverts it to :tag, so
  # its first post-upgrade tick is byte-for-byte the fresh shape. Skipping on
  # absence alone would strand the whole existing fleet on a possibly-stale :tag
  # until the next upstream digest change -- the exact #199 exposure. A legacy
  # edge must therefore ROLL (repair), which then stamps the applied marker.
  run run_branch "docker.io/tracebloc/jobs-manager:dev" "" "1" "0" "" ""
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"RESTART:1"* ]] || return 1
  [[ "$output" == *"predates the fresh-install markers"* ]] || return 1
  [[ "$output" == *"api=docker.io/tracebloc/jobs-manager@sha256:aaa"* ]] || return 1
  [[ "$output" == *"tracebloc.io/digest-applied-jobs-manager=1"* ]] || return 1
  [[ "$output" != *"fresh install"* ]] || return 1
}

@test "api and proxy both on the digest is a no-op (restart_needed=0, no set args)" {
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" \
                 "docker.io/tracebloc/jobs-manager@sha256:aaa" "0"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"no-op"* ]] || return 1
  [[ "$output" == *"RESTART:0"* ]] || return 1
  # nothing queued for a rollout
  [[ "$output" == *"JM:"* ]] && [[ "$output" != *"JM:api="* ]] || return 1
}

@test "on-digest with an UNFINISHED attempt re-runs the rollout, not a silent no-op" {
  # A prior re-pin's rollout timed out on requests-proxy / resource-monitor (both
  # outside the settled guard): the spec reads on-digest but ATTEMPT_KEY is still
  # raised. This must re-enter the re-image path so rollout status retries and the
  # flap guard can surface a genuinely-stuck rollout (Bugbot High on #1008).
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" \
                 "docker.io/tracebloc/jobs-manager@sha256:aaa" "0" "2"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"unfinished re-image"* ]] || return 1
  [[ "$output" == *"RESTART:1"* ]] || return 1
  [[ "$output" != *"; no-op"* ]] || return 1
}

@test "on-digest with NO pending attempt is still a clean no-op" {
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" \
                 "docker.io/tracebloc/jobs-manager@sha256:aaa" "0" "0"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"; no-op"* ]] || return 1
  [[ "$output" == *"RESTART:0"* ]] || return 1
}

@test "on-digest with a LATCHED attempt (>= MAX) is a no-op, not a forced re-run" {
  # Once ATTEMPT_KEY has reached MAX_REFRESH_ATTEMPTS the flap guard downstream
  # annotates FLAP_KEY and exit 0s BEFORE any set image / rollout status, so a
  # forced re-run there resolves nothing and, worse, skips the tick's annotation
  # write forever. The branch must fall to the no-op path instead
  # (@shujaatTracebloc on #1008, blocking 1 & 2). MAX is 3, so pending=3 latches.
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" \
                 "docker.io/tracebloc/jobs-manager@sha256:aaa" "0" "3"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"; no-op"* ]] || return 1
  [[ "$output" == *"RESTART:0"* ]] || return 1
  [[ "$output" != *"unfinished re-image"* ]] || return 1
}

@test "a LATCHED tick still SURFACES the stopped refresh (WARN + FLAP_KEY), not a bare no-op" {
  # With the `< MAX` gate a latched tick keeps restart_needed=0 and never enters
  # the downstream flap guard -- the only other writer of FLAP_KEY and the MANUAL
  # ATTENTION WARN. So refresh is dead for ALL control-plane images while the
  # CronJob stays green, and #1964 forbids "images did not update" being
  # inferable only from the Job's colour. The latched arm must itself emit the
  # WARN naming the refresh-attempt clear and annotate FLAP_KEY before the no-op
  # (@shujaatTracebloc / @LukasWodka / @saadqbal on #1008). MAX is 3.
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" \
                 "docker.io/tracebloc/jobs-manager@sha256:aaa" "0" "3"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"FLAP LATCHED"* ]] || return 1
  [[ "$output" == *"MANUAL ATTENTION NEEDED"* ]] || return 1
  [[ "$output" == *"clear the tracebloc.io/refresh-attempt annotation"* ]] || return 1
  [[ "$output" == *"KUBECTL:annotate deployment"*"tracebloc.io/refresh-flap-detected=3"* ]] || return 1
}

@test "a NON-latched no-op (pending<MAX) stays silent -- no FLAP_KEY, no WARN" {
  # The surface-the-latch arm must fire ONLY at pending>=MAX; a clean on-digest
  # tick (pending=0) and a bounded-attempt tick must not annotate FLAP_KEY.
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" \
                 "docker.io/tracebloc/jobs-manager@sha256:aaa" "0" "0"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"; no-op"* ]] || return 1
  [[ "$output" != *"FLAP LATCHED"* ]] || return 1
  [[ "$output" != *"KUBECTL:"* ]] || return 1
}

@test "api on digest but proxy reverted re-pins the PROXY, not the api" {
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" \
                 "docker.io/tracebloc/jobs-manager:dev" "0"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"re-pinning the requests-proxy digest"* ]] || return 1
  [[ "$output" == *"RESTART:1"* ]] || return 1
  [[ "$output" == *"proxy=docker.io/tracebloc/jobs-manager@sha256:aaa"* ]] || return 1
  # the fall-through re-derives BOTH set args; re-setting the api to the digest
  # it already runs is an idempotent no-op patch (no rollout), which is why the
  # proxy-only revert is repaired without special-casing it.
  [[ "$output" == *"api=docker.io/tracebloc/jobs-manager@sha256:aaa"* ]] || return 1
}

@test "an unreadable api image SKIPS the re-pin this tick (no restart, no churn)" {
  run run_branch "" "" "1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"unreadable"* ]] || return 1
  [[ "$output" == *"skipping re-pin this tick"* ]] || return 1
  [[ "$output" == *"RESTART:0"* ]] || return 1
}

@test "an unreadable requests-proxy image SKIPS the re-pin this tick too" {
  run run_branch "docker.io/tracebloc/jobs-manager@sha256:aaa" "" "0"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"requests-proxy image is unreadable"* ]] || return 1
  [[ "$output" == *"RESTART:0"* ]] || return 1
}

@test "a registry-prefix rewrite (mutating webhook) is NOT mistaken for a revert" {
  # The webhook keeps the @sha256 suffix; comparing on the digest must read this
  # as already-pinned, or every tick re-pins and three ticks trip the #563 flap
  # lockout for all images (LukasWodka on #1008).
  run run_branch "mirror.internal/tracebloc/jobs-manager@sha256:aaa" \
                 "mirror.internal/tracebloc/jobs-manager@sha256:aaa" "0"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"no-op"* ]] || return 1
  [[ "$output" == *"RESTART:0"* ]] || return 1
}
