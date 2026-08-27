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
#   * a fetch/parse failure -> the whole run fails LOUD, never a silent 'ok'
#
# Every standalone assertion ends in `|| return 1`: bats only fails a test on the
# LAST command's status (and `[[ ]]` escapes errexit on bash 3.2), so an
# unchained assertion is advisory (scripts/tests/unenforced-assertions.awk).

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
  [ "$(n_findings)" -eq 1 ] || return 1
  flagged windows-e2e.yaml || return 1
  # last_success is "never" and it must report the ~22d floor, not the newest run's 1d.
  jq -e '.[0].last_success == "never" and .[0].last_success_known == false and .[0].days_since_success >= 21' >/dev/null <<<"$output" || return 1
}

@test "had successes, newest failed, last green too long ago is STALE" {
  mkwf digest-drift.yml
  stub digest-drift.yml \
    "$(run_obj 1 completed failure)" \
    "$(run_obj 3 completed failure)" \
    "$(run_obj 9 completed success)"
  run_check
  [ "$status" -eq 0 ] || return 1
  flagged digest-drift.yml || return 1
  jq -e '.[0].last_success_known == true and .[0].last_conclusion == "failure" and .[0].days_since_success >= 7' >/dev/null <<<"$output" || return 1
}

@test "newest completed run is a success -> never flagged, even when older than threshold (weekly job)" {
  MAX_DAYS=3
  mkwf weekly.yml
  # Only run in the window is a success 6 days ago. 6 > 3, but it is not stale.
  stub weekly.yml "$(run_obj 6 completed success)"
  run_check
  [ "$status" -eq 0 ] || return 1
  [ "$(n_findings)" -eq 0 ] || return 1
}

@test "newest failed but last success still recent -> not flagged (flake grace)" {
  mkwf flaky.yml
  stub flaky.yml \
    "$(run_obj 1 completed failure)" \
    "$(run_obj 2 completed success)"
  run_check
  [ "$status" -eq 0 ] || return 1
  [ "$(n_findings)" -eq 0 ] || return 1
}

@test "no completed scheduled runs -> not flagged (idle / brand-new)" {
  mkwf idle.yml
  # only an in-progress run, nothing completed
  stub idle.yml "$(run_obj 0 queued null)"
  run_check
  [ "$status" -eq 0 ] || return 1
  [ "$(n_findings)" -eq 0 ] || return 1
}

@test "empty run history -> not flagged" {
  mkwf fresh.yml
  stub fresh.yml   # writes {workflow_runs: []}
  run_check
  [ "$status" -eq 0 ] || return 1
  [ "$(n_findings)" -eq 0 ] || return 1
}

@test "a queued run on top of an old cancelled streak is still STALE (newest COMPLETED wins)" {
  mkwf windows-e2e.yaml
  stub windows-e2e.yaml \
    "$(run_obj 0 queued null)" \
    "$(run_obj 1 completed cancelled)" \
    "$(run_obj 20 completed cancelled)"
  run_check
  [ "$status" -eq 0 ] || return 1
  flagged windows-e2e.yaml || return 1
  jq -e '.[0].last_conclusion == "cancelled"' >/dev/null <<<"$output" || return 1
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
  [ "$status" -eq 0 ] || return 1
  [ "$(n_findings)" -eq 0 ] || return 1
  [[ "$output" == "[]" ]] || return 1
}

@test "threshold boundary: exactly MAX_DAYS old is stale, one day short is not" {
  MAX_DAYS=7
  mkwf a.yml
  mkwf b.yml
  stub a.yml "$(run_obj 7 completed failure)"   # exactly 7d, no success -> stale
  stub b.yml "$(run_obj 6 completed failure)"   # 6d -> not yet
  run_check
  [ "$status" -eq 0 ] || return 1
  flagged a.yml || return 1
  ! flagged b.yml || return 1
}

@test "mixed repo: two stale of several scheduled, findings is valid JSON array" {
  mkwf windows-e2e.yaml
  mkwf digest-drift.yml
  mkwf healthy.yml
  stub windows-e2e.yaml "$(run_obj 22 completed cancelled)"
  stub digest-drift.yml "$(run_obj 13 completed failure)"
  stub healthy.yml      "$(run_obj 1 completed success)"
  run_check
  [ "$status" -eq 0 ] || return 1
  [ "$(n_findings)" -eq 2 ] || return 1
  flagged windows-e2e.yaml || return 1
  flagged digest-drift.yml || return 1
  ! flagged healthy.yml || return 1
  # stdout is a single JSON array and nothing else
  jq -e 'type == "array"' >/dev/null <<<"$output" || return 1
}

@test "a fetch/parse failure fails the whole run LOUD, never a silent ok (Bugbot #868)" {
  # A corrupt runs payload stands in for any gh-api/jq failure. runs_for returns
  # non-zero from its subshell; the caller must die in the parent, NOT print 'ok'
  # and exit 0. Before the fix this exited 0 with `[]` — a broken watcher looking
  # healthy.
  mkwf x.yml
  printf '%s' '{ this is not json' > "$STUB/x.yml.json"
  run_check
  [ "$status" -eq 2 ] || { echo "expected exit 2, got $status; stdout=[$output]"; return 1; }
}

@test "a large run history does not hit the Linux argv limit (Bugbot #868)" {
  # 200 completed 'cancelled' runs with padded html_urls, so the payload passed
  # to classify_one exceeds 128KiB. Passing that as a single --argjson arg would
  # blow MAX_ARG_STRLEN on Linux (ubuntu CI) and kill the watcher; via stdin it
  # must work. Never succeeded -> STALE, and all 200 must be examined.
  mkwf big.yml
  local pad; pad="$(printf 'x%.0s' {1..800})"
  jq -cn --argjson now "$NOW" --arg pad "$pad" '
    {workflow_runs: [ range(0;200) as $i
      | { status:"completed", conclusion:"cancelled",
          created_at: (($now - ($i+1)*86400) | todateiso8601),
          html_url: ("https://x/runs/\($i)?pad=\($pad)") } ]}' > "$STUB/big.yml.json"
  # Guard the guard: the payload must actually exceed the 128KiB single-arg cap,
  # or this test would pass without exercising the limit.
  [ "$(wc -c < "$STUB/big.yml.json")" -gt 131072 ] || return 1
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  flagged big.yml || return 1
  jq -e '.[0].last_conclusion == "cancelled" and .[0].runs_examined == 200' >/dev/null <<<"$output" || return 1
}

@test "bad STALENESS_MAX_DAYS fails closed (exit 2)" {
  mkwf x.yml
  MAX_DAYS=notanumber
  run_check
  [ "$status" -eq 2 ] || return 1
}

@test "missing stub dir fails closed (exit 2)" {
  mkwf x.yml
  STALENESS_REPO="tracebloc/example" \
  STALENESS_WORKFLOW_DIR="$WF" \
  STALENESS_RUNS_STUB="$TMP/does-not-exist" \
  STALENESS_NOW="$NOW" \
    "$SCRIPT" >"$TMP/out.json" 2>"$TMP/err.log" && status=0 || status=$?
  [ "$status" -eq 2 ] || return 1
}
