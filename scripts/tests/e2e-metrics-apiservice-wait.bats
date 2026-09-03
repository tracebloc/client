#!/usr/bin/env bats
# =============================================================================
#  e2e-metrics-apiservice-wait.bats — every e2e harness that installs a
#  preflight-carrying chart must wait for the metrics.k8s.io APIService BEFORE it
#  helm-installs, and must do that wait correctly.
#
#  WHY THIS EXISTS (client#863). The chart's resource-monitor preflight does a
#  live `lookup` for the v1beta1.metrics.k8s.io APIService (client#823) and
#  `fail`s the WHOLE release when it is absent. k3s registers that APIService from
#  its bundled metrics-server addon ASYNCHRONOUSLY, after nodes report Ready — so
#  a harness that gates only on `kubectl wait --for=condition=Ready nodes` and
#  then helm-installs is racing the addon. `Seal-check egress-enforcement (k3d)`
#  false-failed at 26 s (#862) while it passed at 51 s (#861), neither touching
#  the chart or these scripts. e2e_wait_for_metrics_apiservice closes the race by
#  waiting for the real precondition first.
#
#  WHAT IS PINNED HERE — the requirement, not one file's wording:
#    1. Every harness that directly `helm install`s a chart carrying the preflight
#       calls the wait, and calls it BEFORE its first `helm install`. That is
#       e2e-seal-check.sh, its secret-ful sibling e2e-full-seal.sh,
#       e2e-auto-upgrade.sh (whose first install is the LAST PUBLISHED chart,
#       which carries the preflight too), and e2e-mysql.sh (which installs THIS
#       chart directly on the 8.4 engine — backend#3074, added after it shipped an
#       inline, non-fatal copy of the wait that this list did not yet cover).
#       e2e-common.sh's own header records that
#       these copy-pasted bring-up blocks "had to move in lockstep or drift";
#       dropping the wait from any one of them is exactly that drift, and it
#       re-opens the race silently. This is the guard for it.
#    2. The wait POLLS FOR THE APISERVICE TO EXIST before it waits on a
#       condition. The object itself appears late, not merely its condition, and
#       `kubectl wait` on a not-yet-created named object errors out ("NotFound")
#       rather than waiting — so a bare `kubectl wait --for=condition=Available
#       apiservice/...` (the issue's first-draft one-liner) would just swap one
#       red for another in the same window. Reverting to that shape is a
#       regression this pins against.
#
#  Pure text/structure assertions on the scripts — no cluster, no kubectl, no
#  network (the real end-to-end exercise is the e2e-*.sh scripts on a live k3d
#  cluster in CI).
# =============================================================================

setup() {
  TESTS_DIR="$BATS_TEST_DIRNAME"
  COMMON="$TESTS_DIR/lib/e2e-common.sh"
  # The harnesses that install a preflight-carrying chart directly (the ones that
  # stop before the tracebloc install — e2e-cluster/journey/proxy — are excluded
  # on purpose: they render no resource-monitor, so no preflight, no race).
  HARNESSES=(
    "$TESTS_DIR/e2e-seal-check.sh"
    "$TESTS_DIR/e2e-full-seal.sh"
    "$TESTS_DIR/e2e-auto-upgrade.sh"
    "$TESTS_DIR/e2e-mysql.sh"
  )
}

# First line number of a CALL (start-of-line, optionally indented) — not a
# comment mention — of the given token in a file; empty if there is none.
_call_line() { grep -nE "^[[:space:]]*$2([[:space:]]|\$)" "$1" | head -1 | cut -d: -f1; }

@test "e2e_wait_for_metrics_apiservice is defined in e2e-common.sh" {
  run grep -Eq '^e2e_wait_for_metrics_apiservice\(\)' "$COMMON"
  [ "$status" -eq 0 ] || return 1
}

@test "every preflight-installing harness calls the metrics wait BEFORE its first helm install" {
  for f in "${HARNESSES[@]}"; do
    local call_ln install_ln
    call_ln="$(_call_line "$f" e2e_wait_for_metrics_apiservice)"
    install_ln="$(grep -nE '^[[:space:]]*helm install ' "$f" | head -1 | cut -d: -f1)"
    [ -n "$call_ln" ]    || { echo "no e2e_wait_for_metrics_apiservice call in $f — the metrics-APIService race is unguarded (client#863)"; return 1; }
    [ -n "$install_ln" ] || { echo "no 'helm install' in $f — test assumption broken"; return 1; }
    [ "$call_ln" -lt "$install_ln" ] || {
      echo "in $f the metrics wait (line $call_ln) does not precede 'helm install' (line $install_ln) — it must run first or the preflight can still lose the race"
      return 1
    }
  done
}

@test "the wait polls for the APIService to EXIST before it waits on a condition" {
  # Extract just the function body, then assert the existence poll (`kubectl get
  # apiservice`) comes before the condition wait (`kubectl wait`). A bare
  # `kubectl wait` with no prior existence poll is the broken shape (NotFound on
  # a not-yet-created object) — see the header.
  local body get_ln wait_ln
  body="$(awk '/^e2e_wait_for_metrics_apiservice\(\)/{f=1} f{print} f&&/^}/{exit}' "$COMMON")"
  get_ln="$(printf '%s\n' "$body" | grep -n 'kubectl get apiservice' | head -1 | cut -d: -f1)"
  wait_ln="$(printf '%s\n' "$body" | grep -n 'kubectl wait' | head -1 | cut -d: -f1)"
  [ -n "$get_ln" ]  || { echo "the wait never polls 'kubectl get apiservice' — a bare 'kubectl wait' errors NotFound on a not-yet-created object"; return 1; }
  [ -n "$wait_ln" ] || { echo "the wait has no 'kubectl wait' condition step"; return 1; }
  [ "$get_ln" -lt "$wait_ln" ] || {
    echo "existence poll (line $get_ln) must precede the condition wait (line $wait_ln) in e2e_wait_for_metrics_apiservice"
    return 1
  }
}
