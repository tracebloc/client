#!/usr/bin/env bats
# jobs-manager-waits-for-mysql.bats — behavioural guard for the wait-for-mysql
# initContainer in client/templates/jobs-manager-deployment.yaml (backend#2913).
#
# WHY THIS EXISTS
# The api container's jobs_manager.py makes an INITIAL, un-retried MySQL connect
# at startup. On an install where mysqld is not listening yet (errno 111,
# connection refused — NOT a credential problem) that connect raises and the
# process exits, so the kubelet crashloops the pod and an e2e leg fails before it
# ever reaches training. The pod recovers minutes later and looks healthy by the
# time anyone inspects, so the only evidence is the PREVIOUS container's log —
# which is what made this expensive to diagnose. The fix is a chart-level init
# gate (the retry does not live in the jobs-manager image), and the behaviour
# that matters is the not-ready-THEN-ready handoff plus the bounded, loud failure
# when MySQL never comes up.
#
# TESTS THE REAL SCRIPT, NOT A COPY (rule 1: derive, don't restate). The wait
# loop is extracted from the RENDERED chart and executed against a fake `nc`
# (and a no-op `sleep`) on PATH, exactly as wait-for-ingest-pod.bats drives a
# fake `kubectl`. A hand-copied loop here would pass while the chart's own drifted.

setup() {
  CHART="${BATS_TEST_DIRNAME}/../../client"
  VALUES="${CHART}/ci/bm-values.yaml"
  require_tool helm || return 1
  require_tool python3 || return 1
  require_pymodule yaml PyYAML || return 1
  [ -d "$CHART" ] || { echo "chart directory not found at $CHART" >&2; return 1; }
  [ -f "$VALUES" ] || { echo "CI values file not found at $VALUES" >&2; return 1; }

  TMP="$(mktemp -d)"
  BIN="$TMP/bin"; mkdir -p "$BIN"
  NCCALLS="$TMP/nc_calls"; printf '0' >"$NCCALLS"
  # READY_AT: the attempt on which the fake `nc` starts succeeding. A value the
  # loop can never reach (999) is "MySQL never comes up".
  READY_AT="$TMP/ready_at"; printf '999' >"$READY_AT"

  # Fake `nc`: ignores every flag/host/port the script passes and answers purely
  # from the counter, so a test controls exactly when the port "opens". exit 0 =
  # listening, non-zero = connection refused (errno 111), which is the case.
  cat >"$BIN/nc" <<EOF
#!/usr/bin/env bash
n=\$(cat "$NCCALLS"); n=\$((n + 1)); printf '%s' "\$n" >"$NCCALLS"
[ "\$n" -ge "\$(cat "$READY_AT")" ] && exit 0 || exit 1
EOF
  # No-op `sleep` so the bounded-failure case runs its whole cap instantly
  # instead of taking the real 240s.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/sleep"
  chmod +x "$BIN/nc" "$BIN/sleep"

  # Extract with the REAL tools on PATH (helm, python3)...
  SCRIPT="$TMP/wait.sh"
  extract_wait_for_mysql >"$SCRIPT"
  [ -s "$SCRIPT" ] || { echo "could not extract the wait-for-mysql command from the rendered chart" >&2; return 1; }

  # ...then put the fakes ahead of the real tools before the wait loop runs.
  # Without this the loop would hit real DNS/connect on a non-existent host and
  # the bounded-failure case would take its full real 240s cap.
  PATH="$BIN:$PATH"
}

teardown() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }

# A missing tool is a SKIP on a laptop and a FAILURE in CI — a required gate must
# never report green on assertions it silently skipped (see chart-pull-secret.bats).
require_tool() {
  command -v "$1" >/dev/null && return 0
  if [ "${CI:-}" = "true" ]; then
    echo "::error::$1 is missing in CI, so this chart-render guard would be" >&2
    echo "::error::skipped rather than run. Install it in the job instead." >&2
    return 1
  fi
  skip "$1 not installed (local run)"
}

require_pymodule() {
  python3 -c "import $1" >/dev/null 2>&1 && return 0
  if [ "${CI:-}" = "true" ]; then
    echo "::error::python3 module '$1' ($2) is missing in CI (pip install $2)." >&2
    return 1
  fi
  skip "python3 module '$1' ($2) not installed (local run)"
}

# Render the REAL chart and pull out the wait-for-mysql initContainer's shell
# body (command[2]). Parsed as YAML, not grepped: there are two init containers
# and two app containers, and only a structured read can pick the right one by
# name regardless of its index (it is [0] on CSI, [1] on hostPath).
extract_wait_for_mysql() {
  helm template myrel "$CHART" -f "$VALUES" --namespace tracebloc \
    -s templates/jobs-manager-deployment.yaml 2>/dev/null | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not doc or doc.get("kind") != "Deployment":
        continue
    if "jobs-manager" not in doc["metadata"]["name"]:
        continue
    for c in (doc["spec"]["template"]["spec"].get("initContainers") or []):
        if c["name"] == "wait-for-mysql":
            sys.stdout.write(c["command"][2])
'
}

@test "hands off to the api container once MySQL starts accepting connections" {
  printf '3' >"$READY_AT"   # refused twice, then listening on the 3rd attempt
  run sh "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status: $output" >&2; return 1; }
  [[ "$output" == *"not ready yet (attempt 1/80)"* ]] || return 1
  [[ "$output" == *"is accepting connections (attempt 3/80)"* ]] || return 1
}

@test "the very first probe succeeding hands off immediately (no spurious wait)" {
  printf '1' >"$READY_AT"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"is accepting connections (attempt 1/80)"* ]] || return 1
  [[ "$output" != *"not ready yet"* ]] || return 1
}

@test "is BOUNDED and fails LOUDLY when MySQL never comes up (not an infinite Pending)" {
  # READY_AT stays 999 — the port never opens. The loop must give up at the cap
  # with a non-zero exit and a diagnosable message, not spin forever.
  run sh "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status" >&2; return 1; }
  [[ "$output" == *"FATAL"* ]] || return 1
  [[ "$output" == *"is not listening"* ]] || return 1
  # It actually exhausted the cap rather than bailing early.
  [[ "$output" == *"attempt 80/80"* ]] || return 1
}
