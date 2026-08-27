#!/usr/bin/env bash
#
#  helm-unittest-gated.sh — the 585-test chart tier must stay REPORTABLE, so it
#  can stay GATING (backend#2651).
#
#  WHY THIS EXISTS. Until #2651 the whole helm-unittest tier — 34 suites, 585
#  tests — lived in `helm-ci.yaml` and was required on no branch. All of it
#  could be red and the PR still merged, which made every assertion in it
#  advisory, including the ones #2606 had just repaired. backend#1729 rule 2: a
#  guard in a non-required CI job is advice, not a gate.
#
#  Making it required is only half the job. Two ways it silently stops gating
#  again, and this guard exists for both:
#
#  1. A `paths:` FILTER ON `pull_request`. A path-filtered job never creates its
#     check run on a PR outside those paths, so GitHub leaves the required check
#     at "Expected - waiting for status to be reported" and the PR is
#     UNMERGEABLE FOREVER. Not hypothetical: drift-checks.yaml's header records
#     it blocking client#651, #657 and #660 on 2026-08-11, none of which touched
#     the filtered paths. This is the failure mode that looks like the gate
#     working until someone opens a docs-only PR.
#
#  2. A RENAME. Branch protection matches the check-run context, which is the
#     job's `name:` string. Rename the job and protection keeps waiting for a
#     context nothing produces — the same permanent-pending state as (1). A
#     near-miss (`Helm unit test`) is indistinguishable from a typo in review.
#
#  WHAT THIS GUARD DOES NOT VERIFY, stated plainly rather than implied. It does
#  NOT read the live branch-protection list, so it cannot prove the context is
#  currently required. That copy lives in GitHub's configuration, not in this
#  repo, and reading it needs a token the drift job does not have. Verify it by
#  hand with:
#
#      gh api repos/tracebloc/client/branches/develop/protection \
#        --jq '.required_status_checks.contexts[]' | grep -x 'Helm unit tests'
#
#  So this guard covers the side that actually changes in a PR — the workflow —
#  and says so instead of claiming a gate it does not check (rule 7).
#
#  FAILS CLOSED (rule 3). A missing workflow file, an unparseable one, or zero
#  jobs found is a FINDING, not agreement: "cannot tell" must not read as "the
#  tier is gated".

set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

python3 - <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

#: The status-check context this tier reports under. ONE declaration in this
#: repo; the other copy is GitHub's protection config (see the header).
CONTEXT = "Helm unit tests"
WORKFLOW = Path(".github/workflows/helm-unit.yaml")
WORKFLOWS = Path(".github/workflows")
#: The command the gate must actually run. A required check that runs nothing is
#: worse than no check: it reports success forever.
MUST_RUN = "helm unittest ./client"

problems = []


def load(path):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as error:  # unparseable is a finding, not a skip
        problems.append(f"{path}: could not parse ({error})")
        return None


if not WORKFLOW.is_file():
    problems.append(
        f"{WORKFLOW} is missing. The chart tier has no dedicated workflow, so "
        f"the required context {CONTEXT!r} cannot be produced by anything."
    )
    print("\n".join(f"[FAIL] {p}" for p in problems))
    sys.exit(1)

doc = load(WORKFLOW)
if doc is None:
    print("\n".join(f"[FAIL] {p}" for p in problems))
    sys.exit(1)

# PyYAML reads a bare `on:` key as the boolean True.
triggers = doc.get("on", doc.get(True)) or {}
if not isinstance(triggers, dict):
    problems.append(
        f"{WORKFLOW}: the `on:` block is {type(triggers).__name__}, not a "
        "mapping — cannot tell whether pull_request is path-filtered"
    )
    triggers = {}

# ---- (1) the paths trap -------------------------------------------------
if "pull_request" not in triggers:
    problems.append(
        f"{WORKFLOW}: no `pull_request` trigger. A required check that never "
        "runs on a PR leaves it permanently pending."
    )
else:
    pr = triggers["pull_request"] or {}
    if isinstance(pr, dict) and "paths" in pr:
        problems.append(
            f"{WORKFLOW}: `pull_request` has a `paths:` filter. {CONTEXT!r} is "
            "a required check, and a path-filtered job never reports on a PR "
            "outside those paths — GitHub leaves it at 'Expected - waiting for "
            "status to be reported' and the PR is unmergeable forever "
            "(client#651/#657/#660, 2026-08-11). Remove the filter; the suite "
            "is ~4s."
        )

# `push` SHOULD keep its filter — pushes are not gated, so scoping is free.
push = triggers.get("push") or {}
if isinstance(push, dict) and push and "paths" not in push:
    problems.append(
        f"{WORKFLOW}: `push` lost its `paths:` filter. Not a correctness "
        "problem, but it was deliberate: pushes are not gated by required "
        "checks, so path-scoping there costs nothing and saves runner time."
    )

# ---- (2) the rename, and that the gate runs the suite -------------------
jobs = doc.get("jobs") or {}
if not jobs:
    problems.append(f"{WORKFLOW}: no jobs found — refusing to pass vacuously")

names = {}
for job_id, job in jobs.items():
    job = job or {}
    names[job_id] = job.get("name", job_id)

if CONTEXT not in names.values():
    problems.append(
        f"{WORKFLOW}: no job is named {CONTEXT!r} (found {sorted(names.values())}). "
        "Branch protection matches the job name as the check-run context, so a "
        "rename leaves protection waiting for a context nothing produces — the "
        "same permanent-pending state as the paths trap. Rename protection in "
        "the same change or put the name back."
    )
else:
    gate_id = next(i for i, n in names.items() if n == CONTEXT)
    steps = (jobs[gate_id] or {}).get("steps") or []
    runs = " ".join(str(s.get("run", "")) for s in steps if isinstance(s, dict))
    if MUST_RUN not in runs:
        problems.append(
            f"{WORKFLOW}: the {CONTEXT!r} job does not run {MUST_RUN!r}. A "
            "required check that does not execute the suite reports success "
            "forever, which is worse than not gating at all."
        )

# ---- context uniqueness across the whole workflow directory -------------
# Two jobs producing the same context makes protection ambiguous: it is
# satisfied by whichever reports, so the tier can be gated by the wrong job.
if not WORKFLOWS.is_dir():
    problems.append(f"{WORKFLOWS} is not a directory — cannot check for collisions")
else:
    producers = []
    seen_any = False
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        other = load(path)
        if not isinstance(other, dict):
            continue
        seen_any = True
        for job_id, job in (other.get("jobs") or {}).items():
            job = job or {}
            if job.get("name", job_id) == CONTEXT:
                producers.append(f"{path.name}:{job_id}")
    if not seen_any:
        problems.append(
            f"parsed no workflow in {WORKFLOWS} — that is what a broken walker "
            "looks like, and it must not read as 'no collisions'"
        )
    elif len(producers) > 1:
        problems.append(
            f"{CONTEXT!r} is produced by more than one job: {producers}. "
            "Protection is satisfied by whichever reports, so the tier may be "
            "gated by the wrong job."
        )

if problems:
    for problem in problems:
        print(f"[FAIL] {problem}")
    sys.exit(1)

print(
    f"helm-unittest-gated: {CONTEXT!r} is produced by exactly one job, runs "
    f"{MUST_RUN!r}, and is not path-filtered on pull_request."
)
PY
