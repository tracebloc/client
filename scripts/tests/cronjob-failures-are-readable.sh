#!/usr/bin/env bash
#
#  cronjob-failures-are-readable.sh — every CronJob the charts render uses
#  `restartPolicy: Never`, so a failed tick leaves a Pod somebody can read
#  (backend#2620).
#
#  WHY THIS EXISTS. Kubernetes DELETES the Pod of an `OnFailure` Job once
#  `backoffLimit` is exhausted. `failedJobsHistoryLimit` retains the JOB and
#  cannot retain a Pod that no longer exists, so a repeatedly-failing CronJob
#  leaves a row of `Failed` Jobs and NO LOGS. The upstream docs say it plainly:
#  "your Pod running the Job will be terminated once the job backoff limit has
#  been reached. This can make debugging the Job's executable more difficult. We
#  suggest setting restartPolicy = 'Never'".
#
#  MEASURED, NOT THEORETICAL. A customer prod edge's `auto-upgrade` CronJob had
#  been failing hourly for 2.7 days. Five `Failed` Jobs were retained; every one
#  of their Pods was gone, and the namespace event window had rolled past the
#  first failure. The reason was UNRECOVERABLE FROM THE CLUSTER — the only
#  surviving evidence that anything was wrong at all was the CronJob's
#  `lastSuccessfulTime`, which nothing watches. Both of the chart's CronJobs
#  carried `OnFailure`, so this was a class, not an instance.
#
#  DERIVED, NOT RESTATED (backend#1729 rule 1). The CronJobs are read out of
#  RENDERED manifests, so a third CronJob added tomorrow is checked tomorrow.
#  This file holds no list of CronJob names.
#
#  SCOPED TO CronJob, AND THAT IS A DECISION. A one-shot `Job` loses its Pod the
#  same way, but a Helm hook Job's failure fails the release and is reported to
#  whoever ran it — somebody is already looking. A CronJob's failure is reported
#  to nobody and repeats forever, which is what makes unreadable logs fatal
#  rather than inconvenient. Widening this to `Job` would need that argument
#  made, not assumed.
#
#  FAILS CLOSED TWICE (rule 3). Zero CronJobs found is a finding, not agreement
#  — a render that produced none would otherwise pass by having nothing to
#  check. And every template declaring `kind: CronJob` must be REACHED by the
#  render matrix below; an unreached template is reported by name and fails,
#  rather than passing silently.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== CronJob failures leave a readable Pod =="

BASE=(--set clientId=x --set clientPassword=y --set storageClass.create=false)

# Value combinations chosen to render every CronJob. ALLOWED to be incomplete —
# the coverage check below turns an omission into a named failure, not a pass.
render_all() {
  helm template t client "${BASE[@]}"
  helm template t client "${BASE[@]}" --set telemetryCollector.enabled=true
  helm template t ingestor --set ingestConfig=placeholder
}

# The source-side denominator: every template declaring a CronJob. Read from the
# files, so it grows with the charts.
EXPECTED="$(grep -rlE '^kind: CronJob$' --include='*.yaml' \
  client/templates ingestor/templates 2>/dev/null | sort || true)"

CHK="$(mktemp -t cronjobpolicy.XXXXXX)"
trap 'rm -f "$CHK"' EXIT
cat >"$CHK" <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

expected = {l.strip() for l in open(sys.argv[1]) if l.strip()}

raw = sys.stdin.read()
chunks = []
for block in raw.split("\n---\n"):
    src = [l for l in block.splitlines() if l.startswith("# Source: ")]
    chunks.append((src[0][len("# Source: "):].strip() if src else None, block))

seen, offenders, missing = set(), [], []
for source, block in chunks:
    try:
        d = yaml.safe_load(block)
    except yaml.YAMLError as e:
        sys.exit(f"[ERROR] unparseable rendered document from {source}: {e}")
    if not d or d.get("kind") != "CronJob":
        continue
    if source is None:
        sys.exit("[ERROR] a rendered CronJob carries no `# Source:` line, so it "
                 "cannot be attributed to a template — refusing to report "
                 "coverage that cannot be computed")
    seen.add(source)
    name = (d.get("metadata") or {}).get("name", "<unnamed>")
    try:
        pod = d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    except (KeyError, TypeError) as e:
        sys.exit(f"[ERROR] {source}: CronJob {name} has no pod spec at "
                 f"spec.jobTemplate.spec.template.spec ({e}) — the shape this "
                 "guard reads has changed and it can no longer check anything")
    policy = pod.get("restartPolicy")
    if policy is None:
        missing.append(f"{source}: {name} states no restartPolicy (Kubernetes "
                       "defaults a Job's to OnFailure, so silence is the "
                       "defect)")
    elif policy != "Never":
        offenders.append(f"{source}: {name} uses restartPolicy: {policy}")

if not seen:
    sys.exit("[ERROR] the render matrix produced ZERO CronJobs. Nothing was "
             "checked, and a guard that checks nothing passes — refusing.")

unreached = sorted(expected - seen)
problems = offenders + missing

for line in problems:
    print(f"  [FAIL] {line}")
if unreached:
    for u in unreached:
        print(f"  [UNREACHED] {u} declares a CronJob no value combination in "
              "render_all() renders, so its restartPolicy is unchecked")

if problems or unreached:
    sys.exit(
        "\n[ERROR] a CronJob whose failures leave no Pod is unobservable by "
        "construction (backend#2620). Kubernetes deletes an OnFailure Job's Pod "
        "once backoffLimit is exhausted, so the Job is retained and its logs are "
        "not. Use `restartPolicy: Never`, or — if a CronJob genuinely needs "
        "OnFailure — make that argument at the declaration and narrow this guard "
        "deliberately rather than adding an exception list here.")

print(f"  [OK] {len(seen)} CronJob template(s) rendered, "
      f"{len(expected)} declared, all restartPolicy: Never")
PY

render_all | python3 "$CHK" <(printf '%s\n' "$EXPECTED")
