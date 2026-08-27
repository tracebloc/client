#!/usr/bin/env bats
# alert-workflow-staleness.sh — files one deduplicated tracking issue per stale
# workflow (backend#2627).
#
# The filing itself talks to `gh` (side-effecting) and is exercised end-to-end
# by the workflow, not here. What IS unit-tested is the part a bug would hide in
# and that needs no network: input validation, the empty case, and the
# title/marker/body the alert would carry — via ALERT_DRY_RUN=1, which makes the
# script print the intended issue and make no gh call at all.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../alert-workflow-staleness.sh"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# finding <workflow> <repo> <days> <last_success> <conclusion> -> one finding obj
finding() {
  jq -cn --arg wf "$1" --arg repo "$2" --argjson days "$3" \
         --arg ok "$4" --arg co "$5" \
    '{workflow:$wf, repo:$repo, max_days:7, days_since_success:$days,
      last_success:$ok, last_success_known:($ok!="never"),
      last_run:"2026-08-26T04:16:59Z", last_conclusion:$co,
      runs_examined:22, html_url:"https://github.com/x/actions/runs/1"}'
}

run_alert() {  # findings-json on stdin
  printf '%s' "$1" | ALERT_REPO="tracebloc/backend" ALERT_DRY_RUN=1 \
    "$SCRIPT" >"$TMP/out.log" 2>&1 && status=0 || status=$?
  output="$(cat "$TMP/out.log")"
}

@test "empty findings array files nothing and exits 0" {
  run_alert '[]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to file"* ]]
}

@test "non-array input fails closed (exit 2)" {
  run_alert '{"not":"an array"}'
  [ "$status" -eq 2 ]
}

@test "dry-run prints title, label and marker for a never-succeeded finding" {
  run_alert "[$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)]"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"CI staleness: windows-e2e.yaml in tracebloc/client"* ]]
  [[ "$output" == *"~22d"* ]]
  [[ "$output" == *"work-type:bug"* ]]
  [[ "$output" == *"workflow-staleness:tracebloc/client:windows-e2e.yaml"* ]]
  [[ "$output" == *"filed 2"* ]] || [[ "$output" == *"filed 1"* ]]
}

@test "dry-run handles multiple findings, one marker each" {
  local f1 f2
  f1="$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)"
  f2="$(finding digest-drift.yml tracebloc/client 13 never failure)"
  run_alert "[$f1,$f2]"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow-staleness:tracebloc/client:windows-e2e.yaml"* ]]
  [[ "$output" == *"workflow-staleness:tracebloc/client:digest-drift.yml"* ]]
  [[ "$output" == *"filed 2, skipped 0"* ]]
}

@test "missing ALERT_REPO fails closed" {
  printf '%s' "[$(finding a.yml tracebloc/client 9 never failure)]" \
    | ALERT_DRY_RUN=1 "$SCRIPT" >"$TMP/out.log" 2>&1 && status=0 || status=$?
  [ "$status" -ne 0 ]
}
