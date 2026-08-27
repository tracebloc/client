#!/usr/bin/env bats
# alert-workflow-staleness.sh — files one deduplicated tracking issue per stale
# workflow (backend#2627).
#
# The filing itself talks to `gh` (side-effecting) and is exercised end-to-end
# by the workflow, not here. What IS unit-tested is the part a bug would hide in
# and that needs no network: input validation, the empty case, and the
# title/marker/body the alert would carry — via ALERT_DRY_RUN=1, which makes the
# script print the intended issue and make no gh call at all.
#
# Every standalone assertion ends in `|| return 1` (bats fails a test only on the
# last command; see scripts/tests/unenforced-assertions.awk).

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

# A configurable `gh` stub on PATH, so the real (non-dry-run) dedup + filing path
# runs offline. Behaviour is driven by env vars the test exports before calling
# run_alert_live; every invocation is appended to $GH_CALLS so a test can assert
# whether `gh issue create` was reached.
#   GH_SEARCH_EXIT  exit code for `gh search issues`      (default 0)
#   GH_SEARCH_OUT   stdout for `gh search issues`         (default empty)
#   GH_VIEW_EXIT    exit code for `gh issue view`         (default 0)
#   GH_VIEW_BODY    stdout for `gh issue view`            (default empty)
make_gh_stub() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS"
case "$1 $2" in
  "search issues") [ -n "${GH_SEARCH_OUT:-}" ] && printf '%s\n' "$GH_SEARCH_OUT"; exit "${GH_SEARCH_EXIT:-0}" ;;
  "issue view")    [ -n "${GH_VIEW_BODY:-}"  ] && printf '%s\n' "$GH_VIEW_BODY";  exit "${GH_VIEW_EXIT:-0}"   ;;
  "issue create")  echo "https://github.com/tracebloc/backend/issues/999";        exit 0                      ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
}

run_alert_live() {  # findings-json on stdin, real path with the gh stub on PATH
  make_gh_stub
  GH_CALLS="$TMP/gh_calls.log"; : >"$GH_CALLS"; export GH_CALLS
  printf '%s' "$1" | PATH="$TMP/bin:$PATH" ALERT_REPO="tracebloc/backend" ALERT_DRY_RUN=0 \
    "$SCRIPT" >"$TMP/out.log" 2>&1 && status=0 || status=$?
  output="$(cat "$TMP/out.log")"
}

@test "empty findings array files nothing and exits 0" {
  run_alert '[]'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"nothing to file"* ]] || return 1
}

@test "non-array input fails closed (exit 2)" {
  run_alert '{"not":"an array"}'
  [ "$status" -eq 2 ] || return 1
}

@test "dry-run prints title, label and marker for a never-succeeded finding" {
  run_alert "[$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)]"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"DRY-RUN"* ]] || return 1
  [[ "$output" == *"CI staleness: windows-e2e.yaml in tracebloc/client"* ]] || return 1
  [[ "$output" == *"~22d"* ]] || return 1
  [[ "$output" == *"work-type:bug"* ]] || return 1
  [[ "$output" == *"workflow-staleness:tracebloc/client:windows-e2e.yaml"* ]] || return 1
}

@test "dry-run handles multiple findings, one marker each" {
  local f1 f2
  f1="$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)"
  f2="$(finding digest-drift.yml tracebloc/client 13 never failure)"
  run_alert "[$f1,$f2]"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"workflow-staleness:tracebloc/client:windows-e2e.yaml"* ]] || return 1
  [[ "$output" == *"workflow-staleness:tracebloc/client:digest-drift.yml"* ]] || return 1
  [[ "$output" == *"filed 2, skipped 0"* ]] || return 1
}

@test "missing ALERT_REPO fails closed" {
  printf '%s' "[$(finding a.yml tracebloc/client 9 never failure)]" \
    | ALERT_DRY_RUN=1 "$SCRIPT" >"$TMP/out.log" 2>&1 && status=0 || status=$?
  [ "$status" -ne 0 ] || return 1
}

# --- dedup fails closed on a search/read error (backend#2702) ----------------
# A dedup existence-check that could not COMPLETE must never be read as "nothing
# filed yet" and file a duplicate — it must abort loud and file nothing.

@test "dedup search failure fails closed: exits non-zero and does NOT create" {
  export GH_SEARCH_EXIT=1
  run_alert_live "[$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)]"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"dedup search failed"* ]] || return 1
  ! grep -q "issue create" "$GH_CALLS" || return 1
}

@test "dedup candidate-read failure fails closed: exits non-zero and does NOT create" {
  export GH_SEARCH_EXIT=0 GH_SEARCH_OUT="123" GH_VIEW_EXIT=1
  run_alert_live "[$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)]"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"dedup read of tracebloc/backend#123 failed"* ]] || return 1
  ! grep -q "issue create" "$GH_CALLS" || return 1
}

@test "existing open issue with the marker is deduped: skips, no create" {
  export GH_SEARCH_EXIT=0 GH_SEARCH_OUT="123" GH_VIEW_EXIT=0 \
    GH_VIEW_BODY="tracked <!-- workflow-staleness:tracebloc/client:windows-e2e.yaml -->"
  run_alert_live "[$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)]"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"already tracked: windows-e2e.yaml -> tracebloc/backend#123"* ]] || return 1
  ! grep -q "issue create" "$GH_CALLS" || return 1
}

@test "genuine empty search result still files: a completed check green-lights create" {
  export GH_SEARCH_EXIT=0 GH_SEARCH_OUT=""
  run_alert_live "[$(finding windows-e2e.yaml tracebloc/client 22 never cancelled)]"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"filed: windows-e2e.yaml -> https://github.com/tracebloc/backend/issues/999"* ]] || return 1
  grep -q "issue create" "$GH_CALLS" || return 1
}
