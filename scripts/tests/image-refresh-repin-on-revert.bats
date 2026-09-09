#!/usr/bin/env bats
# image-refresh RE-PINS the digest when a helm re-render reverted the workload
# to `repo:tag`, instead of no-op'ing off the annotation alone.
#
# backend#199. `recorded == latest` proves the REGISTRY digest has not moved; it
# does NOT prove the workload is running it. `helm upgrade --reset-then-reuse-values`
# (the fleet auto-upgrade) re-renders the Deployment back to `repo:tag` and discards
# an earlier `set image repo@digest` pin -- and on a node whose `:tag` layer is
# stale that silently runs an OLD control-plane image (client-runtime#199). So the
# loop reads each workload's LIVE image and re-pins whenever it is off the digest.
#
# These assert BEHAVIOUR, not text presence: the earlier helm-unittest checks that
# `workload_image_for_repo`/`have=`/`proxy_off_digest` merely APPEAR in the script
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
#   $1 = STUB_API   what workload_image_for_repo returns ("" = unreadable)
#   $2 = STUB_PROXY what requests_proxy_image returns   ("" = unreadable)
#   $3 = RP_PINNED  "1" opts the requests-proxy out of following the digest
#
# The branch is wrapped in a ONE-ITERATION loop so its `continue` statements run
# as they ship, rather than being stripped (which would change control flow).
run_branch() {
  cat > "$TMP/harness.sh" <<EOF
set -eu
repo="tracebloc/jobs-manager"
key="tracebloc.io/last-refreshed-jobs-manager-digest"
IMAGE_REGISTRY="docker.io"
IMAGE_TAG="dev"
REQUESTS_PROXY_DEPLOYMENT="t-requests-proxy"
REQUESTS_PROXY_PINNED="\${3:-0}"
latest="sha256:aaa"
recorded="sha256:aaa"
STUB_API="\${1:-}"
STUB_PROXY="\${2:-}"
restart_needed=0
annotate_args=""
jm_set_args=""
rp_set_args=""
rm_set_args=""
log() { printf '%s\n' "\$*"; }
workload_image_for_repo() { [ -n "\$STUB_API" ] && printf '%s' "\$STUB_API"; }
requests_proxy_image() { [ -n "\$STUB_PROXY" ] && printf '%s' "\$STUB_PROXY"; }
for _once in 1; do
$(sed 's/^/  /' "$TMP/branch.sh")
done
printf 'RESTART:%s\n' "\$restart_needed"
printf 'JM:%s\n' "\$jm_set_args"
printf 'RP:%s\n' "\$rp_set_args"
printf 'ANNOTATE:%s\n' "\$annotate_args"
EOF
  sh "$TMP/harness.sh" "${1:-}" "${2:-}" "${3:-}"
}

@test "workload reverted to :tag re-pins the digest (restart_needed=1)" {
  run run_branch "docker.io/tracebloc/jobs-manager:dev" "" "1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"RESTART:1"* ]] || return 1
  [[ "$output" == *"api=docker.io/tracebloc/jobs-manager@sha256:aaa"* ]] || return 1
  [[ "$output" == *"re-pinning the digest"* ]] || return 1
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
