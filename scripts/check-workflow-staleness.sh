#!/usr/bin/env bash
# check-workflow-staleness.sh — detect SCHEDULED workflows that have quietly
# stopped succeeding (backend#2627).
#
# WHY THIS EXISTS
# ---------------
# `Windows e2e (self-hosted)` in this repo produced one nightly run per day for
# 22 days and every one was recorded `cancelled` — GitHub's 24h queue-timeout,
# because no `self-hosted, windows, nested-virt` runner ever picked it up. A
# `cancelled` conclusion is not a red check and raises no alert, so a workflow
# that had NEVER once succeeded read, for three weeks, as "the Windows path is
# covered nightly" (backend#2627). The sibling failure is a job that IS red and
# is simply ignored: `digest-drift.yml` here has failed on schedule ~13 days
# running with nobody noticing (compare backend#2386, where red runs masked an
# 18-day EC2 leak).
#
# Both are the same disease: a SCHEDULED workflow that stops producing a
# `success`, with no signal loud enough to be acted on. This script is the
# watcher for that class. It answers ONE property-agnostic question per
# scheduled workflow:
#
#     when did its scheduled runs last SUCCEED, and is that longer ago than we
#     tolerate?
#
# It asserts nothing about WHY a workflow stopped succeeding (broken check, dead
# runner, real unaddressed finding) — the alarm is "this has not been green in a
# while", and a human re-verifies. A watcher that instead asserted a specific
# cause would go green the next time a DIFFERENT cause stopped the same job,
# which is the failure this script exists to prevent, not a variant of it.
#
# EXIT CODE PHILOSOPHY — deliberately UNLIKE check-digest-drift.sh
# ----------------------------------------------------------------
# check-digest-drift.sh exits non-zero on a finding: its job going red IS its
# alert. This script does the OPPOSITE and exits 0 when it finds stale
# workflows, because the whole point of #2627 is that a red (or cancelled)
# scheduled check is exactly the signal that gets ignored. So the ALERT here is
# not this script's exit code and not this job's colour — it is the deduplicated
# issue the CALLING workflow files from the findings this script prints. This
# script exits non-zero ONLY when the watcher itself could not do its job
# (missing tool, unreadable input, API failure). That keeps the invariant the
# right way round: green = "the watcher ran"; red = "the watcher is broken" —
# never "a watched workflow is stale". The one thing that must stay loud is a
# BROKEN watcher, and GitHub emails a scheduled-workflow failure to the repo,
# which is the accepted root of trust (something has to be; this is it).
#
# READ-ONLY. It lists workflow runs and prints findings. It never files an
# issue, writes a file, or mutates anything — the filing (and the cross-repo
# token it needs) lives in the workflow, so this stays testable with no network
# and no credentials.
#
# OUTPUT CONTRACT
#   stdout : a JSON array of finding objects (possibly empty `[]`). Machine-
#            readable; the workflow parses it. NOTHING else goes to stdout.
#   stderr : a human-readable per-workflow line and a summary.
#   exit 0 : ran to completion (with or without findings).
#   exit 2 : usage / internal error (bad config, unreadable stub, API failure).
#   exit 3 : a required tool (gh, jq) is missing.
#
# CONFIG (env)
#   STALENESS_MAX_DAYS      integer, default 7. A scheduled workflow is stale if
#                           its most recent COMPLETED scheduled run did not
#                           succeed AND its last success is >= this many days
#                           old (or it has never succeeded within the window).
#                           Must exceed the SLOWEST watched cron period, or a
#                           healthy-but-infrequent job trips it on its first
#                           miss — see docs/WORKFLOW-STALENESS.md.
#   STALENESS_REPO          owner/name to inspect. Default: $GITHUB_REPOSITORY,
#                           else derived from `git remote get-url origin`.
#   STALENESS_WORKFLOW_DIR  default .github/workflows.
#   STALENESS_RUNS_STUB     TEST SEAM. A directory. For workflow file `foo.yml`
#                           the script reads `<dir>/foo.yml.json` (the shape
#                           `gh api .../runs` returns: {workflow_runs:[...]}) and
#                           makes NO network call. A stubbed run prints STUBBED
#                           on stderr so a log can never be mistaken for a real
#                           audit.
#   STALENESS_NOW           TEST SEAM. Epoch seconds used as "now" for the age
#                           math, so tests are deterministic. Default: date +%s.
set -uo pipefail

MAX_DAYS="${STALENESS_MAX_DAYS:-7}"
WF_DIR="${STALENESS_WORKFLOW_DIR:-.github/workflows}"
NOW="${STALENESS_NOW:-$(date +%s)}"

die() { echo "ERROR: $*" >&2; exit 2; }

# --- preconditions ---------------------------------------------------------
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 3; }
[[ "$MAX_DAYS" =~ ^[0-9]+$ && "$MAX_DAYS" -ge 1 ]] || die "STALENESS_MAX_DAYS must be a positive integer (got '$MAX_DAYS')"
[[ "$NOW" =~ ^[0-9]+$ ]] || die "STALENESS_NOW must be epoch seconds (got '$NOW')"
[[ -d "$WF_DIR" ]] || die "workflow dir not found: $WF_DIR (run from the repo root)"

STUB="${STALENESS_RUNS_STUB:-}"
if [[ -n "$STUB" ]]; then
  [[ -d "$STUB" ]] || die "STALENESS_RUNS_STUB is set but is not a directory: $STUB"
  echo "check-workflow-staleness: STUBBED (reading $STUB, no network)" >&2
else
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required (or set STALENESS_RUNS_STUB)" >&2; exit 3; }
fi

# --- repo resolution -------------------------------------------------------
REPO="${STALENESS_REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  # `owner/name` out of the origin URL, ssh or https, with or without .git.
  origin="$(git remote get-url origin 2>/dev/null || true)"
  REPO="$(printf '%s\n' "$origin" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
fi
[[ "$REPO" == */* ]] || die "could not resolve owner/name (set STALENESS_REPO); got '$REPO'"

# runs_for <workflow-file> -> prints the `.workflow_runs` array as JSON.
# Real path fetches the last 100 scheduled runs (`event=schedule`): we judge a
# workflow's SCHEDULED cadence health, deliberately blind to its PR/push runs —
# a job whose PRs are green but whose nightly cron has been cancelling for weeks
# is exactly what we must still catch. 100 (the API max per page) covers >3
# months of a daily cron, far more than any sane MAX_DAYS. A sub-daily cron
# (many runs/day) whose failing streak fits inside 100 runs but spans fewer than
# MAX_DAYS of wall-clock could be under-flagged — see docs/WORKFLOW-STALENESS.md;
# no such cron exists in this org (slowest cadence here is daily).
runs_for() {
  local wf="$1"
  if [[ -n "$STUB" ]]; then
    local f="$STUB/$wf.json"
    if [[ -r "$f" ]]; then jq -c '.workflow_runs // []' "$f" || die "stub is not valid JSON: $f"
    else echo '[]'; fi
    return 0
  fi
  local out
  # Fail CLOSED: a swallowed API error must not read as "no stale workflows".
  if ! out="$(gh api -H "Accept: application/vnd.github+json" \
        "/repos/$REPO/actions/workflows/$wf/runs?event=schedule&per_page=100" \
        --jq '.workflow_runs // []' 2>/dev/null)"; then
    die "gh api failed listing runs for $wf in $REPO (auth? actions:read?)"
  fi
  printf '%s\n' "$out"
}

# classify_one <workflow-file> <runs-json> -> emits a finding object, or nothing.
# All age math is done in jq via fromdateiso8601 (portable — no date -d/-j fork),
# with `now` injected so tests are deterministic.
classify_one() {
  local wf="$1" runs="$2"
  jq -c -n \
    --arg wf "$wf" --arg repo "$REPO" \
    --argjson max_days "$MAX_DAYS" --argjson now "$NOW" \
    --argjson runs "$runs" '
    ( [ $runs[] | select(.status=="completed") ] ) as $completed
    | if ($completed | length) == 0 then empty          # no completed scheduled run: idle or brand-new, not rot
      else
        ( $completed | sort_by(.created_at) | reverse ) as $c
        | $c[0] as $newest
        | ( [ $c[] | select(.conclusion=="success") ] ) as $succ
        | ( if ($succ|length) > 0 then $succ[0] else null end ) as $lastok
        | ( if $lastok != null
              then ( ($now - ($lastok.created_at | fromdateiso8601)) / 86400 )
              else ( ($now - ($c[-1].created_at   | fromdateiso8601)) / 86400 )   # no success in window: floor = age of oldest run seen
            end ) as $age
        # Stale iff it has RUN and NOT succeeded recently. Gating on the newest
        # completed run being non-success is what makes a healthy-but-infrequent
        # workflow (whose newest scheduled run IS a success) immune regardless of
        # cadence — only a job that ran and did not go green can be flagged.
        | if ($newest.conclusion != "success") and ($age >= $max_days)
          then {
            workflow: $wf, repo: $repo, max_days: $max_days,
            days_since_success: ($age | floor),
            last_success: ( if $lastok != null then $lastok.created_at else "never" end ),
            last_success_known: ($lastok != null),
            last_run: $newest.created_at,
            last_conclusion: $newest.conclusion,
            runs_examined: ($completed | length),
            html_url: ($newest.html_url // "")
          }
          else empty end
      end'
}

# --- scan ------------------------------------------------------------------
# In scope: a workflow file that declares a schedule trigger. Require BOTH a
# `schedule:` key and a `cron:` line so a stray "schedule" elsewhere in the file
# can't pull an event-driven workflow into scope.
findings='[]'
scanned=0
stale=0
shopt -s nullglob
for path in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  grep -qE '^[[:space:]]*schedule:' "$path" || continue
  grep -qE '^[[:space:]]*-?[[:space:]]*cron:' "$path" || continue
  wf="$(basename "$path")"
  scanned=$((scanned + 1))
  runs="$(runs_for "$wf")"
  finding="$(classify_one "$wf" "$runs")"
  if [[ -n "$finding" ]]; then
    stale=$((stale + 1))
    days="$(jq -r '.days_since_success' <<<"$finding")"
    lastok="$(jq -r '.last_success' <<<"$finding")"
    concl="$(jq -r '.last_conclusion' <<<"$finding")"
    echo "STALE  $wf — last success: $lastok; newest scheduled run: $concl; ~${days}d without a green scheduled run (threshold ${MAX_DAYS}d)" >&2
    findings="$(jq -c --argjson f "$finding" '. + [$f]' <<<"$findings")"
  else
    echo "ok     $wf" >&2
  fi
done

echo "check-workflow-staleness: scanned $scanned scheduled workflow(s) in $REPO; $stale stale (threshold ${MAX_DAYS}d)" >&2
printf '%s\n' "$findings"
