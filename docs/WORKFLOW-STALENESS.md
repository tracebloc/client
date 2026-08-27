# Workflow staleness watch

`.github/workflows/workflow-staleness-watch.yml` + `scripts/check-workflow-staleness.sh` + `scripts/alert-workflow-staleness.sh` (backend#2627).

## The failure class it closes

A **scheduled** workflow can stop producing a `success` without anyone noticing:

- **Silent cancel.** `Windows e2e (self-hosted)` ran nightly for 22 days and every run was `cancelled` — GitHub's 24h queue-timeout, because no matching runner ever picked it up. `cancelled` is not a red check and fires no alert, so a job that had **never once succeeded** read as "covered nightly" for three weeks (backend#2627).
- **Ignored red.** This repo's own `digest-drift.yml` failed on schedule ~13 days running with nobody acting on it — the same disease with a red check instead of a cancel (compare backend#2386, where red runs masked an 18-day EC2 leak).

Both are: *a scheduled job stopped going green and no signal was loud enough to act on.*

## What it does

Daily (08:00 UTC) on a GitHub-hosted runner — so it always actually runs — it:

1. finds every workflow in `.github/workflows` that declares a `schedule:` trigger;
2. for each, reads its recent `event=schedule` runs and finds the most recent **successful** one;
3. flags it **stale** when its most recent *completed* scheduled run did **not** succeed **and** its last success is `≥ N` days old (or it has never succeeded in the window);
4. files **one deduplicated tracking issue per stale workflow** in the private catch-all `tracebloc/backend`, labelled `work-type:bug` (so it routes straight to `Ready` on the engineer kanban).

The alert is an **issue**, not a check colour — because the whole point of #2627 is that a red/cancelled scheduled check is exactly the signal that gets ignored.

## The rule, precisely (and why it doesn't false-alarm)

Staleness is gated on **the most recent completed scheduled run being non-success**. That makes a healthy-but-infrequent job immune regardless of cadence: a weekly workflow whose newest scheduled run is a `success` is never flagged, even if that success is older than `N`. Only a job that **ran and did not go green** can be flagged. A workflow with no completed scheduled runs at all (idle / brand-new) is skipped.

`N` is `STALENESS_MAX_DAYS` (default **7**, overridable via the `max-days` dispatch input). It must exceed the **slowest** watched cron's period, or a healthy job that merely failed a single infrequent tick trips it. Daily jobs are tolerant of a one-off flake (a single miss is `< N` old); a weekly job that fails its scheduled run surfaces promptly (its last success is already ~7 days back).

Known limitations:

- It detects scheduled jobs that **run but stop succeeding**, not a schedule GitHub has silently **disabled** (no runs at all) — GitHub emails the repo on auto-disable, so that mode is not silent.
- The detector examines the last 100 scheduled runs. A **sub-daily** cron (many runs per day) whose failing streak fits inside those 100 runs but spans fewer than `N` days of wall-clock could be under-flagged. The slowest cadence in this repo is daily (100 runs ≈ 3 months), so this does not bite here.

"Who watches the watcher": if this job itself breaks it exits non-zero and goes RED, and GitHub emails a scheduled-run failure to the repo — the accepted root of trust.

## Exit-code contract (deliberately unlike `check-digest-drift.sh`)

`check-workflow-staleness.sh` exits **0** whether or not it finds stale workflows — the alert is the filed issue, not the exit code, because a red watcher would itself become an ignored red. It exits non-zero **only** when the watcher cannot do its job (missing tool, unreadable input, API error). Green = "the watcher ran"; red = "the watcher is broken". `alert-workflow-staleness.sh` exits non-zero if a create fails (e.g. the App lacks `issues:write`) so a broken alerter is loud.

## Local / manual use

```bash
# detect only (reads the live GitHub API; needs gh + jq)
STALENESS_REPO=tracebloc/client scripts/check-workflow-staleness.sh

# preview what would be filed, without filing (no gh writes)
STALENESS_REPO=tracebloc/client scripts/check-workflow-staleness.sh \
  | ALERT_REPO=tracebloc/backend ALERT_DRY_RUN=1 scripts/alert-workflow-staleness.sh
```

Or run the workflow with **Run workflow → dry-run = true**. The classification logic is unit-tested offline via the `STALENESS_RUNS_STUB` / `STALENESS_NOW` seams (`scripts/tests/check-workflow-staleness.bats`, `scripts/tests/alert-workflow-staleness.bats`).

## Porting to another repo

The org class sweep (backend#2627, measured 2026-08-27) found `windows-e2e.yaml` is currently the **only** self-hosted-targeting workflow in the org — this exists so the *next* rotting scheduled job can't be silent. To cover another repo, copy the workflow + both scripts and keep `ALERT_REPO` (and the App token's `repositories:`) pointing at the private catch-all. Nothing is client-specific.
