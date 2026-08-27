#!/usr/bin/env bash
#
#  helm-unittest-error-assertions.sh — a `failedTemplate` assertion may carry
#  `errorMessage` and nothing else, because helm-unittest 0.5.2 SILENTLY IGNORES
#  every other key under it (backend#2606).
#
#  WHY THIS EXISTS. `failedTemplate: {errorPattern: "..."}` reads, in review,
#  as "this specific refusal fired". It is not that. The plugin never looks at
#  the key: a pattern appearing NOWHERE in the output still passes, so the
#  assertion is exactly equivalent to a bare `failedTemplate: {}` — any failure
#  at all satisfies it. Such a test cannot tell you which refusal fired and goes
#  on passing after the refusal it names is reworded, moved, or replaced by a
#  different one.
#
#  MEASURED, NOT INFERRED. Two proofs, both re-run when this guard was written:
#    * `errorPattern: "ZZZ_THIS_STRING_APPEARS_NOWHERE_ZZZ"` on rbac_test.yaml's
#      perDatasetPvcs case: 19 passed, 19 total.
#    * `errorMessage` with the template's exact `fail` string, then that string
#      mutated in templates/rbac.yaml: 1 failed, 18 passed. Restored: 19 passed.
#  So `errorMessage` is honoured and `errorPattern` is not.
#
#  `--strict` IS NOT A SUBSTITUTE, and that was checked rather than assumed.
#  With `errorPattern` AND an invented `bogusKeyThatDoesNotExist` both set on one
#  assertion, `helm unittest --strict ./client` reported 19 passed, 19 total —
#  identical to the non-strict run. The plugin validates no key names here, which
#  is why the rule needs a guard outside the plugin and why the check below is
#  an ALLOWLIST of one key rather than a blocklist of the one we happened to
#  find: a typo (`errorMesage`) fails exactly as silently.
#
#  WHY NOT grep. `errorPattern` is named on purpose in several test-file
#  comments — including the ones this guard's own fix added, warning people off
#  it — so a text match on the token flags the warnings and not the violations.
#  This parses the YAML and looks at KEYS of a `failedTemplate` mapping, which is
#  the thing the rule is actually about (backend#1729 rule 1: derive the real
#  declaration, don't restate it).
#
#  FAILS CLOSED THREE WAYS (rule 3). Zero suite files found is a finding, not
#  agreement. An unparseable suite is a finding, not a skip. And zero
#  `failedTemplate` assertions reached across the whole tree is a finding too —
#  that is what a broken walker looks like, and it would otherwise read as a
#  clean sweep.
#
#  SCHEMA FAILURES ARE A SEPARATE CASE, deliberately left bare. A
#  values.schema.json rejection fails at CHART LOAD, before any template
#  renders; the plugin reports an "errored" test and `errorMessage` compares
#  against a template render error that never happened. Those assertions stay
#  `failedTemplate: {}` with a comment saying why. Pinning a schema message
#  needs a layer that can see it — `helm template` + grep on stderr, as
#  scripts/tests/chart-env-vocabulary.sh does.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== failedTemplate assertions carry errorMessage, or nothing =="

# DERIVED from the tree: every chart's helm-unittest suite, so an `ingestor/tests`
# suite added tomorrow is checked tomorrow. No file list lives in this script.
python3 - <<'PY'
import glob
import sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

# helm-unittest 0.5.2 honours exactly one key under `failedTemplate`. Everything
# else — errorPattern, or a typo — is accepted and never read.
HONOURED = {"errorMessage"}

files = sorted(glob.glob("*/tests/*_test.yaml"))
if not files:
    sys.exit("[ERROR] found ZERO helm-unittest suites matching */tests/*_test.yaml. "
             "Nothing was checked, and a guard that checks nothing passes — refusing.")

offenders = []
seen = 0

def walk(node, path, where):
    """Find every `failedTemplate:` mapping and report its non-honoured keys."""
    global seen
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}"
            if key == "failedTemplate":
                seen += 1
                if isinstance(value, dict):
                    for sub in value:
                        if sub not in HONOURED:
                            offenders.append(f"{where}: {here}.{sub}")
                elif value not in (None, {}):
                    offenders.append(
                        f"{where}: {here} is {type(value).__name__}, not a mapping "
                        "or an empty/bare assertion — this guard cannot read it")
            walk(value, here, where)
    elif isinstance(node, list):
        for i, item in enumerate(node):
            walk(item, f"{path}[{i}]", where)

for path in files:
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError) as exc:
        sys.exit(f"[ERROR] {path} could not be parsed ({exc}). 'cannot tell' is a "
                 "finding, not agreement — refusing to report green.")
    walk(doc, "", path)

if seen == 0:
    sys.exit(f"[ERROR] walked {len(files)} suite file(s) and reached ZERO "
             "`failedTemplate` assertions. That is what a broken walker looks "
             "like — refusing to report green.")

if offenders:
    for line in offenders:
        print(f"  [FAIL] {line}")
    sys.exit(
        "\n[ERROR] helm-unittest 0.5.2 SILENTLY IGNORES every key under "
        "`failedTemplate` except `errorMessage`, so each key above asserts "
        "NOTHING — the test passes on any failure whatsoever and reads in review "
        "like a precise assertion (backend#2606).\n"
        "  * a template `fail`: use `errorMessage:` with the EXACT full message "
        "from the template, and mutation-prove it (reword the template, watch "
        "the test redden, restore).\n"
        "  * a values.schema.json rejection: no message assertion can work — it "
        "fails at chart load, not at render. Use a bare `failedTemplate: {}` and "
        "a comment saying so, or assert the text outside the plugin with "
        "`helm template` + grep, as scripts/tests/chart-env-vocabulary.sh does.")

print(f"  [OK] {seen} failedTemplate assertion(s) across {len(files)} suite "
      f"file(s); every key present is in {sorted(HONOURED)}")
PY
