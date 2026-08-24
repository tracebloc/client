#!/usr/bin/env bash
#
#  collector-redaction-derived.sh — the Collector's redaction floor IS the one
#  declaration, and the vendored copy of that declaration is the bytes upstream
#  published (backend#2378).
#
#  THE PROBLEM THIS CLOSES. "Which strings must be scrubbed before a log leaves
#  a customer's cluster" used to exist as three hand-maintained copies across
#  two repositories with nothing derived from anything: client-runtime's
#  `_LOG_REDACTIONS`, the OTTL `replace_pattern` calls in
#  templates/telemetry-collector-configmap.yaml (a hand port of the first), and
#  a chart test holding hand-written fragments of the second. backend#1908 is
#  the receipt: the generic pattern anchored its keyword with `\b` on both
#  sides, so every environment-variable spelling of a secret leaked, in EVERY
#  copy, for as long as the copies existed, with passing tests on both sides.
#
#  WHAT IS DIFFERENT NOW. There is one declaration — client-runtime's
#  log_redactions.json — vendored here at client/log_redactions.json, and the
#  template GENERATES its statements from it. So this guard does not compare
#  regex text against regex text it holds itself (that was copy 3, and it agreed
#  with itself forever). It asks two questions neither side can answer alone:
#
#    1. Are the vendored bytes the bytes upstream published? Answered against
#       the sha256 in scripts/.log-redactions.sha256, copied from upstream's own
#       pin. No network and no credential: client-runtime is PRIVATE and
#       GITHUB_TOKEN is repo-scoped, and a fetch would fail on exactly the day
#       the network is what broke.
#    2. Is what the chart RENDERS the declaration? Answered by parsing the
#       rendered config — the real template's real output — and comparing the
#       ordered (pattern, replacement) pairs to the declaration. Re-hardcode a
#       statement in the template, or drop one, and this reddens.
#
#  WHAT IT CANNOT SEE, stated rather than implied: whether upstream has MOVED
#  ON. Nothing in this repository can read a private repo without a credential.
#  That residual is held on two other layers — client-runtime's own digest
#  tripwire, which reddens the moment the declaration changes there and names
#  the companion PR, and the weekly cross-repo job in
#  .github/workflows/envelope-contract-drift.yml, which diffs this vendored copy
#  against the ref pinned in scripts/.client-runtime-ref.
#
#  COMPLEMENTS, DOES NOT REPLACE, scripts/tests/collector-redaction-floor.sh.
#  That one asks the behavioural question — would a real secret survive? — with
#  specimens written independently of any pattern. This one asks the provenance
#  question. A declaration that is faithfully rendered and useless would pass
#  here and fail there; a working floor typed in by hand would pass there and
#  fail here.
#
#  FAILS CLOSED throughout. A missing vendored file, a missing or empty digest
#  pin, an unparseable render, or zero patterns found is a finding — never
#  "nothing to check, therefore fine". Steps 1 and 2 need no tooling beyond
#  python3 and therefore never skip.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client
DECLARATION="$CHART/log_redactions.json"
DIGEST_PIN="scripts/.log-redactions.sha256"

command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== collector redaction: vendored declaration =="

# ── 1 + 2: the vendored bytes are the bytes upstream published ───────────────
python3 - "$DECLARATION" "$DIGEST_PIN" <<'PY'
import hashlib
import json
import pathlib
import sys

declaration, pin = (pathlib.Path(p) for p in sys.argv[1:3])

if not declaration.is_file():
    sys.exit(f"[ERROR] {declaration} is missing. It is vendored from "
             "tracebloc/client-runtime and the Collector's redaction floor is "
             "generated from it — an absent declaration is a finding, not a "
             "chart without a feature.")
if not pin.is_file():
    sys.exit(f"[ERROR] {pin} is missing. It is the only local witness of WHICH "
             "version of the declaration this repo vendors, so without it "
             "nothing here can tell a faithful copy from an edited one.")

digest = ""
for line in pin.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        digest = line
        break
if not digest:
    sys.exit(f"[ERROR] {pin} carries no digest line — the first non-comment, "
             "non-blank line must be the sha256.")

actual = hashlib.sha256(declaration.read_bytes()).hexdigest()
if actual != digest:
    sys.exit(f"[ERROR] {declaration} is not the file {pin} pins.\n"
             f"          pinned {digest}\n"
             f"          actual {actual}\n"
             "        Either the vendored copy was hand-edited here — which is "
             "the drift this guard exists to catch, since the chart is not "
             "where this rule is declared — or an upstream adoption was landed "
             "without copying the new digest across. Re-vendor both files from "
             "tracebloc/client-runtime and bump scripts/.client-runtime-ref.")

contract = json.loads(declaration.read_text(encoding="utf-8"))
if not contract.get("redactions"):
    sys.exit(f"[ERROR] {declaration} declares no redactions, so the Collector "
             "would export captured logs unscrubbed.")

print(f"  ok: {declaration} matches {pin} "
      f"({len(contract['redactions'])} redaction(s), sha256 {digest[:12]}…)")
PY

# ── 3: what the chart renders IS the declaration ─────────────────────────────
# The render half needs helm. A dev box may not have it; every CI job that runs
# this one does (`azure/setup-helm`, pinned identically in drift-checks.yaml,
# helm-ci.yaml and envelope-contract-drift.yml).
#
# SO THE SKIP IS SCOPED TO A DEV BOX, and is an ERROR anywhere it would make a
# green check into a claim nobody proved. Bugbot found the first instance of
# exactly that on this PR: a workflow step named "the rendered redaction floor
# matches the vendored declaration", in a job that had no helm, going green
# having compared nothing. `REQUIRE_HELM=1` forces the strict path; `CI` (which
# GitHub Actions always sets) turns it on by itself, so a future removal of a
# `Set up Helm` step reddens rather than quietly halving this guard.
if ! command -v helm >/dev/null 2>&1; then
  if [ -n "${REQUIRE_HELM:-}" ] || [ -n "${CI:-}" ]; then
    echo "[ERROR] helm is not installed, so the render comparison cannot run —" >&2
    echo "        and 'cannot tell' is a finding here, not a pass. This guard is" >&2
    echo "        only half of itself without it: the vendored bytes were checked," >&2
    echo "        what the chart actually renders was not. Add the pinned" >&2
    echo "        azure/setup-helm step to this job, or unset CI/REQUIRE_HELM if" >&2
    echo "        you are deliberately running the provenance half alone." >&2
    exit 1
  fi
  echo "[SKIP] helm not installed — the render comparison did not run (the "
  echo "       vendored-bytes check above did). Set REQUIRE_HELM=1 to make this "
  echo "       a failure."
  exit 0
fi

CHK="$(mktemp -t redaction-derived.XXXXXX)"
HELM_ERR="$(mktemp -t redaction-helm.XXXXXX)"
trap 'rm -f "$CHK" "$HELM_ERR"' EXIT
cat >"$CHK" <<'PY'
import json
import pathlib
import re
import sys

import yaml

declaration = json.loads(
    pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
)
declared = [(r["pattern"], r["replacement"]) for r in declaration["redactions"]]

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms = [d for d in docs
       if d.get("kind") == "ConfigMap" and "telemetry-collector" in d["metadata"]["name"]]
if len(cms) != 1:
    sys.exit(f"[ERROR] expected exactly one Collector ConfigMap, found {len(cms)} "
             "— cannot check what cannot be located")

cfg = yaml.safe_load(cms[0]["data"]["config.yaml"])
processor = (cfg.get("processors") or {}).get("transform/redaction")
if not processor:
    sys.exit("[ERROR] the rendered config has no `transform/redaction` processor, "
             "so nothing scrubs a captured log before it is exported")

statements = []
for block in processor.get("log_statements") or []:
    statements.extend(block.get("statements") or [])

# TWO levels of escaping, and getting this wrong weakens the comparison rather
# than breaking it. A YAML plain scalar does not process backslashes, so what
# the YAML parser returns still carries the OTTL string literal's own escaping
# (`\\s` for `\s`, `\"` for `"`). OTTL resolves that when it parses the
# statement; this must do the same before comparing to the declaration, whose
# JSON decoding already produced the bare regex.
STATEMENT = re.compile(
    r'replace_pattern\(\s*body\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)'
)


def unescape(literal):
    return literal.replace('\\\\', '\\').replace('\\"', '"')


rendered = []
for statement in statements:
    match = STATEMENT.search(statement)
    if not match:
        sys.exit(f"[ERROR] a redaction statement is not a two-argument "
                 f"replace_pattern(body, ...) call and so cannot be compared to "
                 f"the declaration: {statement!r}")
    rendered.append((unescape(match.group(1)), unescape(match.group(2))))

if not rendered:
    sys.exit("[ERROR] no `replace_pattern(body, ...)` statements in the rendered "
             "redaction processor — zero parsed is a broken guard, not a clean "
             "bill of health")

if rendered != declared:
    missing = [p for p in declared if p not in rendered]
    extra = [p for p in rendered if p not in declared]
    print("[ERROR] the rendered Collector config is not the vendored "
          "declaration:", file=sys.stderr)
    for pattern, replacement in missing:
        print(f"          declared but NOT rendered: {pattern!r} -> "
              f"{replacement!r}", file=sys.stderr)
    for pattern, replacement in extra:
        print(f"          rendered but NOT declared: {pattern!r} -> "
              f"{replacement!r}", file=sys.stderr)
    if not missing and not extra:
        print("          same pairs, different ORDER — redaction is applied in "
              "sequence and a reordering can change what a later pattern sees",
              file=sys.stderr)
    print("        The statements are generated from client/log_redactions.json "
          "by templates/telemetry-collector-configmap.yaml. A hand-written "
          "replace_pattern in that template is the defect this guard names.",
          file=sys.stderr)
    sys.exit(1)

print(f"  ok: all {len(rendered)} rendered statement(s) are the declared "
      "redactions, in order")
PY

# helm's stderr is CAPTURED, not discarded. The template's `fail` strings name
# the cause and the fix by hand ("... is missing from the chart ... restore it
# and check scripts/.log-redactions.sha256"); `2>/dev/null` rendered every one
# of them unreachable. Worse, it made the guard MISDIRECT: step 1 checks the
# declaration on DISK and prints `ok`, so an operator saw `ok: ...matches...`
# one line above `found 0 ConfigMaps` and went hunting through the ConfigMap
# template, while the actual cause was that helm could not READ the file (a
# .helmignore entry — the exclusion the template's own comment calls out).
# Reproduced end to end before and after. Never a fail-open (pipefail still
# exits 1); purely which file the 2am reader is sent to.
# (Reported by @saadqbal on client#803.)
if ! helm template t "$CHART" \
  --set clientId=x --set clientPassword=y \
  --set storageClass.create=false \
  --set telemetryCollector.enabled=true 2>"$HELM_ERR" | python3 "$CHK" "$DECLARATION"; then
  # Only the kubeconfig-permissions noise is filtered; everything else helm said
  # reaches the operator. `|| true` because grep exits 1 on no match, and an
  # empty stderr must not turn this into a different failure than the real one.
  grep -v '^WARNING: Kubernetes configuration file is' "$HELM_ERR" >&2 || true
  exit 1
fi

echo "collector redaction derived: green"
