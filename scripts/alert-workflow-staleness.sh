#!/usr/bin/env bash
# alert-workflow-staleness.sh — turn findings from check-workflow-staleness.sh
# into ONE deduplicated tracking issue per stale workflow (backend#2627).
#
# WHY A SEPARATE SCRIPT FROM THE DETECTOR
# ---------------------------------------
# check-workflow-staleness.sh is READ-ONLY and needs no credentials, so it stays
# unit-testable with no network. This script is the side-effecting half: it
# WRITES issues, and it needs a cross-repo, issues:write token (the detector
# watches client's PUBLIC workflows, but CI-health / runner work is internal, so
# per CLAUDE.md the alert is filed in the PRIVATE catch-all `backend`, not in the
# public repo — a `client` GITHUB_TOKEN cannot write there, hence the workflow
# mints a tracebloc-release-train App token first). Keeping the two apart means
# the classification is tested offline and only the thin filing glue talks to gh.
#
# THE ALERT IS AN ISSUE, NOT A RED CHECK — ON PURPOSE
# ---------------------------------------------------
# #2627 exists because a cancelled/red scheduled check is precisely the signal
# that gets ignored (the windows-e2e cancels; digest-drift's ignored reds;
# backend#2386's ignored reds). So the durable signal is a deduplicated issue
# that lands on the engineer kanban (`work-type:bug` -> Ready automatically), not
# another check colour nobody watches.
#
# DEDUP (same shape as the e2e-agent, backend#1575/#2619): each issue carries a
# hidden fingerprint marker in its body. Before filing we look for an OPEN issue
# already carrying that exact marker and, if found, do nothing. One stale
# workflow therefore yields exactly one live card until a human closes it; the
# daily run does not re-file.
#
# FAILS LOUD, AND FAILS CLOSED. If a create cannot be done (e.g. the App lacks
# issues:write on the alert repo), or the dedup existence-check cannot COMPLETE
# (a `gh search` / `gh issue view` error), this exits non-zero so the watcher job
# goes RED — a broken alerter is the one thing that must not be quiet, and GitHub
# emails a scheduled-run failure to the repo. A dedup check that could not run is
# never read as "nothing filed yet": doing so files a fresh duplicate on every
# daily run until search recovers (backend#2702, same class as backend#2631).
#
# CONFIG (env)
#   ALERT_REPO      owner/name to file into. Required.
#   ALERT_LABEL     label applied to filed issues. Default: work-type:bug
#                   (routes straight to Ready on the kanban — defects don't wait).
#   ALERT_DRY_RUN   "1" -> print the issue that WOULD be filed and make NO gh
#                   call at all (used by `workflow_dispatch` preview and by the
#                   tests). Default: 0.
#
# INPUT: a findings JSON array (the detector's stdout), from $1 or stdin.
set -uo pipefail

ALERT_REPO="${ALERT_REPO:?set ALERT_REPO (owner/name to file into)}"
ALERT_LABEL="${ALERT_LABEL:-work-type:bug}"
DRY_RUN="${ALERT_DRY_RUN:-0}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 3; }
[[ "$DRY_RUN" == 1 ]] || command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required (or set ALERT_DRY_RUN=1)" >&2; exit 3; }

findings="$(cat "${1:-/dev/stdin}")"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$findings" || { echo "ERROR: input is not a JSON array" >&2; exit 2; }

n="$(jq 'length' <<<"$findings")"
if [[ "$n" -eq 0 ]]; then echo "no stale workflows — nothing to file"; exit 0; fi

filed=0; skipped=0
for i in $(seq 0 $((n - 1))); do
  f="$(jq -c ".[$i]" <<<"$findings")"
  wf="$(jq -r '.workflow'            <<<"$f")"
  srcrepo="$(jq -r '.repo'           <<<"$f")"
  days="$(jq -r '.days_since_success'<<<"$f")"
  lastok="$(jq -r '.last_success'    <<<"$f")"
  concl="$(jq -r '.last_conclusion'  <<<"$f")"
  lastrun="$(jq -r '.last_run'       <<<"$f")"
  maxd="$(jq -r '.max_days'          <<<"$f")"
  url="$(jq -r '.html_url'           <<<"$f")"

  marker="workflow-staleness:${srcrepo}:${wf}"
  last_success_phrase="$lastok"
  [[ "$lastok" == "never" ]] && last_success_phrase="never (no success in the runs examined)"

  title="CI staleness: ${wf} in ${srcrepo} has no successful scheduled run in ~${days}d"

  # Build the body in a temp FILE via a plain heredoc redirect. Deliberately not
  # `body="$(cat <<EOF ...)"`: bash 3.2 (macOS) mis-parses an apostrophe inside a
  # heredoc nested in command substitution and dies with "unexpected EOF looking
  # for matching '" (this repo is bash-3.2-safe — see check-digest-drift.sh). A
  # redirect to a file sidesteps it and lets us use `gh --body-file`.
  bodyfile="$(mktemp)"
  cat > "$bodyfile" <<EOF
A **scheduled** workflow has not produced a successful run in about **${days} days** (alert threshold: ${maxd}d). Filed automatically by the workflow-staleness watch in \`${srcrepo}\` (backend#2627).

| | |
|---|---|
| workflow | \`${wf}\` |
| repo | \`${srcrepo}\` |
| last successful scheduled run | ${last_success_phrase} |
| most recent scheduled run | \`${concl}\` at ${lastrun} |
| newest run | ${url} |

A \`cancelled\` conclusion is not a red check and raises no alert, so a scheduled workflow can stop succeeding for weeks without anyone noticing — that is the failure class this watch closes (backend#2627; compare the ignored reds in backend#2386).

**What to check:** is the runner/environment gone (queue-timeout cancels), is the job genuinely broken, or is it red because of a real finding nobody has triaged? Then either fix it, retire/repoint it, or — if this is expected — silence it at the source (remove the \`schedule:\` trigger) so it stops claiming coverage it does not provide.

This issue is **deduplicated**: while it stays open, the daily watch will not file again for \`${wf}\`. Close it once the workflow is green (or retired).

<!-- ${marker} -->
EOF

  if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY-RUN — would file into ${ALERT_REPO}:"
    echo "  title : ${title}"
    echo "  label : ${ALERT_LABEL}"
    echo "  marker: ${marker}"
    rm -f "$bodyfile"
    filed=$((filed + 1))
    continue
  fi

  # Dedup: narrow by full-text search on the marker, then CONFIRM the exact
  # marker is in the candidate body (search tokenises punctuation, so a match is
  # a candidate, not proof). Search indexing lag is irrelevant at a daily cadence
  # and we file at most one per workflow per run, so no intra-run duplicate.
  #
  # FAIL CLOSED (backend#2702): the errors here must NOT be swallowed into an
  # empty result and read as "not yet tracked" — that files a fresh duplicate
  # every daily run until search recovers. A failed `gh search` leaves stdout
  # empty, indistinguishable from a genuine zero-result unless we also check its
  # exit status, so capture the status and abort loud rather than create when the
  # search — or a candidate read — could not complete. Same class as backend#2631.
  if ! candidates="$(gh search issues --repo "$ALERT_REPO" --state open \
                       --match body "$marker" --json number --jq '.[].number')"; then
    echo "ERROR: dedup search failed for ${wf} in ${ALERT_REPO}; not filing (would risk a duplicate)" >&2
    rm -f "$bodyfile"
    exit 2
  fi
  existing=""
  for num in $candidates; do
    if ! cand_body="$(gh issue view "$num" --repo "$ALERT_REPO" --json body --jq '.body')"; then
      echo "ERROR: dedup read of ${ALERT_REPO}#${num} failed for ${wf}; not filing (would risk a duplicate)" >&2
      rm -f "$bodyfile"
      exit 2
    fi
    if grep -qF "$marker" <<<"$cand_body"; then
      existing="$num"; break
    fi
  done
  if [[ -n "$existing" ]]; then
    echo "already tracked: ${wf} -> ${ALERT_REPO}#${existing}"
    skipped=$((skipped + 1))
    continue
  fi

  # A failed create must fail the job (loud). Capture output so a 403 (missing
  # issues:write on the App) is visible in the log rather than swallowed.
  if ! created="$(gh issue create --repo "$ALERT_REPO" --title "$title" --body-file "$bodyfile" --label "$ALERT_LABEL" 2>&1)"; then
    echo "ERROR: could not file issue for ${wf} in ${ALERT_REPO}: ${created}" >&2
    rm -f "$bodyfile"
    exit 2
  fi
  rm -f "$bodyfile"
  echo "filed: ${wf} -> ${created}"
  filed=$((filed + 1))
done

echo "alert-workflow-staleness: filed ${filed}, skipped ${skipped} (already tracked)"
