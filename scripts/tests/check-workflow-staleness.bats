#!/usr/bin/env bats
# check-workflow-staleness.sh — the watcher on SCHEDULED workflows that have
# stopped succeeding (backend#2627).
#
# The GitHub Actions API is stubbed via STALENESS_RUNS_STUB and "now" is pinned
# via STALENESS_NOW, so the classification is asserted with no network and no
# clock. The cases that matter are the ones that separate "rot" from "idle" and
# from "healthy but infrequent" — the distinctions that make this safe to point
# at a mix of daily and weekly crons without false alarms:
#
#   * never-succeeded + old streak  -> STALE   (windows-e2e's shape)
#   * had successes, newest failed, last green too long ago -> STALE
#   * newest completed run IS a success -> never flagged, even if that success
#     is far older than the threshold (a weekly job is not stale for being weekly)
#   * newest failed but last success is still recent -> not flagged (flake grace)
#   * no completed scheduled runs at all -> not flagged (idle / brand-new)
#   * a currently-queued run on top of an old cancelled streak -> STALE
#     (we judge the newest COMPLETED run, not the newest run)

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check-workflow-staleness.sh"
  TMP="$(mktemp -d)"
  WF="$TMP/workflows"
  STUB="$TMP/stub"
  mkdir -p "$WF" "$STUB"
  # Pinned clock. All run timestamps in these tests are expressed as N days
  # before this instant.
  NOW=1756252800   # 2026-08-27T00:00:00Z
}
teardown() { rm -rf "$TMP"; }

# iso <days-ago> -> ISO8601 timestamp that many days before NOW.
iso() { jq -rn --argjson e "$((NOW - $1 * 86400))" '$e | todateiso8601'; }

# mkwf <name> -> write a scheduled workflow file (schedule + cron present).
mkwf() {
  cat > "$WF/$1" <<'YAML'
on:
  schedule:
    - cron: '0 4 * * *'
YAML
}

# run_obj <days-ago> <status> <conclusion> -> one run JSON object.
run_obj() {
  jq -cn --arg ca "$(iso "$1")" --arg st "$2" --arg co "$3" \
    '{status:$st, conclusion:$co, created_at:$ca, html_url:"https://x/run"}'
}

# stub <name> <run-json...> -> write stub/<name>.json = {workflow_runs:[...]}.
stub() {
  local name="$1"; shift
  printf '%s\n' "$@" | jq -s '{workflow_runs: .}' > "$STUB/$name.json"
}

# The findings are on STDOUT and the human summary on STDERR; bats `run` merges
# the two, so capture stdout on its own and read `$output`/`$status` from there.
run_check() {
  STALENESS_REPO="tracebloc/example" \
  STALENESS_WORKFLOW_DIR="$WF" \
  STALENESS_RUNS_STUB="$STUB" \
  STALENESS_NOW="$NOW" \
  STALENESS_MAX_DAYS="${MAX_DAYS:-7}" \
    "$SCRIPT" >"$TMP/out.json" 2>"$TMP/err.log" && status=0 || status=$?
  output="$(cat "$TMP/out.json")"
}

# stdout of the last run_check is the findings JSON; these read it back.
n_findings() { jq 'length' <<<"$output"; }
flagged()    { jq -e --arg w "$1" 'any(.[]; .workflow == $w)' <<<"$output" >/dev/null; }

@test "never succeeded + old streak is STALE (windows-e2e shape)" {
  mkwf windows-e2e.yaml
  stub windows-e2e.yaml \
    "$(run_obj 1 completed cancelled)" \
    "$(run_obj 10 completed cancelled)" \
    "$(run_obj 22 completed cancelled)"
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(n_findings)" -eq 1 ]
  flagged windows-e2e.yaml
  # last_success is "never" and it must report the ~22d floor, not the newest run's 1d.
  jq -e '.[0].last_success == "never" and .[0].last_success_known == false and .[0].days_since_success >= 21' <<<"$output"
}

@test "had successes, newest failed, last green too long ago is STALE" {
  mkwf digest-drift.yml
  stub digest-drift.yml \
    "$(run_obj 1 completed failure)" \
    "$(run_obj 3 completed failure)" \
    "$(run_obj 9 completed success)"
  run_check
  [ "$status" -eq 0 ]
  flagged digest-drift.yml
  jq -e '.[0].last_success_known == true and .[0].last_conclusion == "failure" and .[0].days_since_success >= 7' <<<"$output"
}

@test "newest completed run is a success -> never flagged, even when older than threshold (weekly job)" {
  MAX_DAYS=3
  mkwf weekly.yml
  # Only run in the window is a success 6 days ago. 6 > 3, but it is not stale.
  stub weekly.yml "$(run_obj 6 completed success)"
  run_check
  [ "$status" -eq 0 ]
  [ "$(n_findings)" -eq 0 ]
}

@test "newest failed but last success still recent -> not flagged (flake grace)" {
  mkwf flaky.yml
  stub flaky.yml \
    "$(run_obj 1 completed failure)" \
    "$(run_obj 2 completed success)"
  run_check
  [ "$status" -eq 0 ]
  [ "$(n_findings)" -eq 0 ]
}

@test "no completed scheduled runs -> not flagged (idle / brand-new)" {
  mkwf idle.yml
  # only an in-progress run, nothing completed
  stub idle.yml "$(run_obj 0 queued null)"
  run_check
  [ "$status" -eq 0 ]
  [ "$(n_findings)" -eq 0 ]
}

@test "empty run history -> not flagged" {
  mkwf fresh.yml
  stub fresh.yml   # writes {workflow_runs: []}
  run_check
  [ "$status" -eq 0 ]
  [ "$(n_findings)" -eq 0 ]
}

@test "a queued run on top of an old cancelled streak is still STALE (newest COMPLETED wins)" {
  mkwf windows-e2e.yaml
  stub windows-e2e.yaml \
    "$(run_obj 0 queued null)" \
    "$(run_obj 1 completed cancelled)" \
    "$(run_obj 20 completed cancelled)"
  run_check
  [ "$status" -eq 0 ]
  flagged windows-e2e.yaml
  jq -e '.[0].last_conclusion == "cancelled"' <<<"$output"
}

@test "event-driven workflow (no schedule/cron) is out of scope" {
  cat > "$WF/pr-only.yml" <<'YAML'
on:
  pull_request:
    branches: [develop]
YAML
  # even if a stub existed for it, it must not be scanned
  stub pr-only.yml "$(run_obj 30 completed failure)"
  run_check
  [ "$status" -eq 0 ]
  [ "$(n_findings)" -eq 0 ]
  [[ "$output" == "[]" ]]
}

@test "threshold boundary: exactly MAX_DAYS old is stale, one day short is not" {
  MAX_DAYS=7
  mkwf a.yml
  mkwf b.yml
  stub a.yml "$(run_obj 7 completed failure)"   # exactly 7d, no success -> stale
  stub b.yml "$(run_obj 6 completed failure)"   # 6d -> not yet
  run_check
  [ "$status" -eq 0 ]
  flagged a.yml
  ! flagged b.yml
}

@test "mixed repo: two stale of several scheduled, findings is valid JSON array" {
  mkwf windows-e2e.yaml
  mkwf digest-drift.yml
  mkwf healthy.yml
  stub windows-e2e.yaml "$(run_obj 22 completed cancelled)"
  stub digest-drift.yml "$(run_obj 13 completed failure)"
  stub healthy.yml      "$(run_obj 1 completed success)"
  run_check
  [ "$status" -eq 0 ]
  [ "$(n_findings)" -eq 2 ]
  flagged windows-e2e.yaml
  flagged digest-drift.yml
  ! flagged healthy.yml
  # stdout is a single JSON array and nothing else
  jq -e 'type == "array"' <<<"$output"
}

@test "bad STALENESS_MAX_DAYS fails closed (exit 2)" {
  mkwf x.yml
  MAX_DAYS=notanumber
  run_check
  [ "$status" -eq 2 ]
}

@test "missing stub dir fails closed (exit 2)" {
  mkwf x.yml
  STALENESS_REPO="tracebloc/example" \
  STALENESS_WORKFLOW_DIR="$WF" \
  STALENESS_RUNS_STUB="$TMP/does-not-exist" \
  STALENESS_NOW="$NOW" \
    "$SCRIPT" >"$TMP/out.json" 2>"$TMP/err.log" && status=0 || status=$?
  [ "$status" -eq 2 ]
}
