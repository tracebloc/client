#!/usr/bin/env bats
# =============================================================================
#  image-refresh-skip-streak.bats — backend#1964
#
#  The image-refresh CronJob skips a whole tick when the jobs-manager Deployment
#  is not settled. That is right for a rollout in flight and wrong forever for a
#  pod that never becomes Ready — and because the skip happens BEFORE anything is
#  reconciled, requests-proxy and resource-monitor stop updating too while every
#  tick exits 0 and the CronJob stays green.
#
#  WHY THIS RUNS THE SCRIPT INSTEAD OF GREPPING THE TEMPLATE.
#  The chart's helm-unittest suite can only assert that some string is present in
#  the rendered ConfigMap. A guard proved by "the text mentions MAX_SKIP_TICKS"
#  is exactly the inert verification backend#1729 catalogued: it passes forever,
#  including against logic that can never fire. So this suite RENDERS the chart,
#  EXTRACTS the script the pod actually runs, and EXECUTES it against a stubbed
#  kubectl — the exit code and the annotation writes are the assertions.
#
#  The stub is driven entirely by env vars, so each case states the cluster it is
#  describing and nothing is shared between cases.
# =============================================================================

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CHART_DIR="${REPO_ROOT}/client"
  # The same values file the other chart tests render with (chart-env-vocabulary.sh),
  # rather than a hand-rolled minimum: a private --set list here would drift from
  # what CI actually renders, and storage-class.yaml already refuses a bare render.
  CI_VALUES="${REPO_ROOT}/client/ci/bm-values.yaml"
  export REPO_ROOT CHART_DIR CI_VALUES

  # Render once for the whole file: helm is the slow part, the script is static.
  RENDERED="${BATS_FILE_TMPDIR}/image-refresh.sh"
  export RENDERED

  helm template stg "$CHART_DIR" -f "$CI_VALUES" \
    --namespace tracebloc \
    --show-only templates/image-refresh-cronjob.yaml \
    2>/dev/null \
    | python3 -c '
import sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")
for doc in yaml.safe_load_all(sys.stdin.read()):
    if doc and doc.get("kind") == "ConfigMap":
        sys.stdout.write(doc["data"]["image-refresh.sh"])
        break
else:
    sys.exit("no ConfigMap with image-refresh.sh in the rendered output")
' > "$RENDERED"

  chmod +x "$RENDERED"
}

setup() {
  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  ANNOTATIONS="${BATS_TEST_TMPDIR}/annotate.log"
  : > "$ANNOTATIONS"
  export ANNOTATIONS

  # kubectl stub. Only the calls this script makes before/at the settled guard
  # are modelled; anything else is a loud failure rather than a silent 0, so a
  # future call cannot be mistaken for a passing case.
  cat > "$STUB_DIR/kubectl" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "config "*|"config")
    # #634's in-cluster kubeconfig build. Local file writes, no API call.
    exit 0 ;;
  "rollout status")
    exit "${STUB_ROLLOUT_RC:-0}" ;;
  "get deployment")
    # Two distinct calls share this verb: the bare existence probe, and the
    # -o json read behind get_annotation(). Distinguished by -o json.
    for a in "$@"; do
      if [ "$a" = "json" ]; then
        [ "${STUB_JSON_RC:-0}" = "0" ] || exit "${STUB_JSON_RC}"
        printf '%s' "${STUB_JSON:-\{\"metadata\":\{\"annotations\":\{\}\}\}}"
        exit 0
      fi
    done
    exit "${STUB_GET_RC:-0}" ;;
  "annotate deployment")
    shift 2
    printf '%s\n' "$*" >> "$ANNOTATIONS"
    exit "${STUB_ANNOTATE_RC:-0}" ;;
esac
echo "kubectl stub: unmodelled call: $*" >&2
exit 97
STUB
  chmod +x "$STUB_DIR/kubectl"

  # curl stub: HERMETIC BY CONSTRUCTION. On the settled path the script goes on
  # to resolve manifest digests from docker.io, so without this the suite would
  # reach the real registry -- a unit test that fails on a plane, and one that
  # burns the anonymous pull-rate limit the chart is careful about. Failing the
  # fetch takes the script's documented "could not resolve latest digest
  # (rate-limited or transient); skipping this tick" branch, which is exactly the
  # deterministic no-op these cases want after the guard they are testing.
  cat > "$STUB_DIR/curl" <<'CURLSTUB'
#!/bin/sh
echo "curl stub: refusing network access in a unit test: $*" >&2
exit 6
CURLSTUB
  chmod +x "$STUB_DIR/curl"

  # The env the pod supplies. IMAGE_REGISTRY must be docker.io or the mirror
  # guard exits 0 long before the settled guard is reached.
  export PATH="$STUB_DIR:$PATH"
  export RELEASE_NAME=stg RELEASE_NAMESPACE=tracebloc
  export DEPLOYMENT_NAME=stg-jobs-manager
  export REQUESTS_PROXY_DEPLOYMENT=stg-requests-proxy
  export RESOURCE_MONITOR_DAEMONSET=stg-resource-monitor
  export NODE_AGENTS_NAMESPACE=tracebloc-node-agents
  export IMAGE_REGISTRY=docker.io IMAGE_TAG=stg
  export ROLLOUT_TIMEOUT=300s
  # The script builds an explicit in-cluster kubeconfig from these (#634) and
  # runs under `set -u`, so they are not optional.
  export KUBERNETES_SERVICE_HOST=10.96.0.1 KUBERNETES_SERVICE_PORT=443
  export JOBS_MANAGER_PINNED=0 PODS_MONITOR_PINNED=0 RESOURCE_MONITOR_PINNED=0
  export MAX_SKIP_TICKS=8
}

# "the streak annotation was never written". NOT `grep -qv`: that returns 1 on an
# empty file (no lines at all, matching or otherwise) and 0 on a file holding any
# unrelated line, so it is wrong in both directions -- it failed the missing-
# deployment case and PASSED the healthy-edge case for the wrong reason, because
# Pass 1 writes digest annotations. Count the lines that actually matter.
_assert_no_streak_write() {
  local n
  n="$(grep -c 'refresh-skip-streak' "$ANNOTATIONS" || true)"
  if [ "$n" != "0" ]; then
    printf 'expected no skip-streak write, found %s:\n%s\n' \
      "$n" "$(grep 'refresh-skip-streak' "$ANNOTATIONS")" >&2
    return 1
  fi
}

# A deployment that is present but unsettled. The streak so far is $1.
_unsettled_with_streak() {
  export STUB_ROLLOUT_RC=1 STUB_GET_RC=0
  export STUB_JSON="{\"metadata\":{\"annotations\":{\"tracebloc.io/refresh-skip-streak\":\"$1\"}}}"
}

@test "the harness really extracted the script the pod runs (not an empty file)" {
  [ -s "$RENDERED" ] || return 1
  head -1 "$RENDERED" | grep -q '^#!/bin/sh' || return 1
  grep -q 'MAX_SKIP_TICKS' "$RENDERED" || return 1
}

@test "first unsettled tick still skips benignly, and records streak=1" {
  export STUB_ROLLOUT_RC=1 STUB_GET_RC=0
  export STUB_JSON='{"metadata":{"annotations":{}}}'
  run sh "$RENDERED"
  [ "$status" -eq 0 ] || return 1
  grep -q 'skipping this refresh tick 1/8' <<<"$output" || return 1
  grep -q 'refresh-skip-streak=1' "$ANNOTATIONS" || return 1
}

@test "an ongoing streak below the ceiling keeps skipping and increments" {
  _unsettled_with_streak 6
  run sh "$RENDERED"
  [ "$status" -eq 0 ] || return 1
  grep -q 'skipping this refresh tick 7/8' <<<"$output" || return 1
  grep -q 'refresh-skip-streak=7' "$ANNOTATIONS" || return 1
}

@test "at the ceiling the tick FAILS instead of exiting 0 — the whole point of #1964" {
  _unsettled_with_streak 7
  run sh "$RENDERED"
  [ "$status" -eq 1 ] || return 1
  grep -q 'IMAGE REFRESH IS FROZEN' <<<"$output" || return 1
  grep -q 'refresh-skip-streak=8' "$ANNOTATIONS" || return 1
}

@test "the frozen message names the OTHER workloads that stopped updating" {
  # The reason this ticket outranks its severity: three more components are
  # silently frozen, and an operator reading only "jobs-manager not settled"
  # has no reason to think so.
  #
  # SCOPED TO THE FROZEN LINE on purpose. The startup banner already prints
  # "also reconciling: deployment/<release>-requests-proxy ...", so grepping the
  # whole output passes even if the frozen message names nothing at all — this
  # assertion was vacuous in its first revision, and caught by watching it pass
  # while the script was exiting long before the guard.
  local frozen
  _unsettled_with_streak 7
  run sh "$RENDERED"
  frozen="$(grep 'IMAGE REFRESH IS FROZEN' <<<"$output")"
  [ -n "$frozen" ] || return 1
  grep -q 'stg-requests-proxy' <<<"$frozen" || return 1
  grep -q 'stg-resource-monitor' <<<"$frozen" || return 1
}

@test "the frozen message points at the never-Ready ingestion server, the reachable cause" {
  _unsettled_with_streak 7
  run sh "$RENDERED"
  grep -q 'ingestion HTTP server' <<<"$output" || return 1
  grep -q 'ingestion-authz.yaml' <<<"$output" || return 1
}

@test "a streak past the ceiling stays failed rather than lapsing back to green" {
  _unsettled_with_streak 40
  run sh "$RENDERED"
  [ "$status" -eq 1 ] || return 1
  grep -q 'IMAGE REFRESH IS FROZEN' <<<"$output" || return 1
}

@test "an unreadable streak annotation FAILS the tick — it must not collapse to zero" {
  # Fail-open here would reset the streak every tick, so the ceiling would never
  # be reached: the freeze would become permanent AND unreported.
  export STUB_ROLLOUT_RC=1 STUB_GET_RC=0 STUB_JSON_RC=1
  run sh "$RENDERED"
  [ "$status" -eq 1 ] || return 1
  grep -q 'skip streak cannot be counted' <<<"$output" || return 1
}

@test "a MISSING deployment is still the pre-existing exit 1, not a skip (#571 unchanged)" {
  export STUB_ROLLOUT_RC=1 STUB_GET_RC=1
  run sh "$RENDERED"
  [ "$status" -eq 1 ] || return 1
  grep -q 'not a benign skip' <<<"$output" || return 1
  _assert_no_streak_write || return 1
}

@test "settling again clears the streak annotation" {
  export STUB_ROLLOUT_RC=0 STUB_GET_RC=0
  export STUB_JSON='{"metadata":{"annotations":{"tracebloc.io/refresh-skip-streak":"5"}}}'
  run sh "$RENDERED"
  grep -q 'settled again after 5 skipped tick' <<<"$output" || return 1
  grep -q 'refresh-skip-streak-' "$ANNOTATIONS" || return 1
}

# --- backend#2007: the CLEAR must not be able to abort the tick ---------------
#
# #1964 made a permanently-unsettled deployment a loud finding. Its RECOVERY path
# then had its own way to freeze: the settled branch clears the bookkeeping
# annotation under `set -e`, so a transient API error on that one write aborted
# the tick BEFORE Pass 1 -- requests-proxy and resource-monitor stayed frozen on
# the very tick that proved jobs-manager had recovered.
#
# "Reached Pass 1" is the assertion, not the exit status: Pass 1 logs a `checking
# <repo>` line per image, and under the hermetic curl stub it then takes the
# documented "could not resolve latest digest" no-op. Asserting the log line
# pins the SPECIFIC thing the bug destroyed (work after the clear), where an
# exit-status assertion would also pass if the script died somewhere later.

@test "a failed streak clear does NOT abort the tick before Pass 1 (backend#2007)" {
  export STUB_ROLLOUT_RC=0 STUB_GET_RC=0
  export STUB_JSON='{"metadata":{"annotations":{"tracebloc.io/refresh-skip-streak":"5"}}}'
  # Every annotate fails -- the clear is the first one the settled path reaches.
  export STUB_ANNOTATE_RC=1
  run sh "$RENDERED"
  # It genuinely attempted the clear (otherwise this case proves nothing).
  grep -q 'settled again after 5 skipped tick' <<<"$output" || return 1
  # ...and carried on into Pass 1 instead of dying at the failed write.
  grep -q 'checking tracebloc/jobs-manager' <<<"$output" || return 1
  grep -q 'checking tracebloc/resource-monitor' <<<"$output" || return 1
}

@test "a failed streak clear is reported as a WARNING, not swallowed (backend#2007)" {
  # The shared lesson of #1964 and #2007: "images did not update" must never be
  # inferable only from the Job's colour. Non-fatal must still mean visible.
  export STUB_ROLLOUT_RC=0 STUB_GET_RC=0
  export STUB_JSON='{"metadata":{"annotations":{"tracebloc.io/refresh-skip-streak":"5"}}}'
  export STUB_ANNOTATE_RC=1
  run sh "$RENDERED"
  grep -q 'WARNING: could not clear tracebloc.io/refresh-skip-streak' <<<"$output" || return 1
}

@test "a healthy edge with no streak is not patched every tick" {
  export STUB_ROLLOUT_RC=0 STUB_GET_RC=0
  export STUB_JSON='{"metadata":{"annotations":{}}}'
  run sh "$RENDERED"
  _assert_no_streak_write || return 1
}

@test "MAX_SKIP_TICKS is honoured from the environment, not hardcoded" {
  export MAX_SKIP_TICKS=2
  _unsettled_with_streak 1
  run sh "$RENDERED"
  [ "$status" -eq 1 ] || return 1
  grep -q 'MAX_SKIP_TICKS=2' <<<"$output" || return 1
}

@test "the chart wires MAX_SKIP_TICKS into the CronJob env (default 8)" {
  # Without this the script would silently fall back to its own default and
  # imageRefresh.maxSkipTicks in values.yaml would be decoration.
  run helm template stg "$CHART_DIR" -f "$CI_VALUES" --namespace tracebloc \
    --show-only templates/image-refresh-cronjob.yaml
  [ "$status" -eq 0 ] || return 1
  grep -q 'name: MAX_SKIP_TICKS' <<<"$output" || return 1
  grep -A1 'name: MAX_SKIP_TICKS' <<<"$output" | grep -q '"8"' || return 1
}

@test "imageRefresh.maxSkipTicks overrides the rendered value" {
  run helm template stg "$CHART_DIR" -f "$CI_VALUES" --namespace tracebloc \
    --set imageRefresh.maxSkipTicks=3 \
    --show-only templates/image-refresh-cronjob.yaml
  [ "$status" -eq 0 ] || return 1
  grep -A1 'name: MAX_SKIP_TICKS' <<<"$output" | grep -q '"3"' || return 1
}
