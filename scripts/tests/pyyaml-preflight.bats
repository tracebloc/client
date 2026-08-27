#!/usr/bin/env bats
# pyyaml-preflight.bats — every guard that parses rendered YAML with python must
# PREFLIGHT the PyYAML module, so a runner without PyYAML gets a NAMED refusal
# instead of a bare ModuleNotFoundError traceback (Bugbot on client#869,
# backend#2686).
#
# WHY THIS EXISTS. The chart guards check `command -v python3` and then `import
# yaml` inside a heredoc. `command -v python3` proves the INTERPRETER exists, not
# the MODULE: on a runner with python3 but no PyYAML the import dies as an
# uncaught ModuleNotFoundError traceback — an opaque failure where the sibling
# helm-unittest-error-assertions.sh already gives `[ERROR] PyYAML required`. The
# fix is a one-line preflight; this file keeps the whole class fixed.
#
# DERIVED, NOT RESTATED. The guard list is grepped out of scripts/tests, so a
# yaml-parsing guard added tomorrow is checked tomorrow. This file holds no list
# of guard names — the denominator is the tree.
#
# FAILS CLOSED. Finding ZERO yaml-importing guards is a FINDING, not agreement:
# a broken enumeration would otherwise pass by having nothing to check.
#
# NEEDS NO HELM. The structural check reads source; the behavioural check runs
# helm-unittest-error-assertions.sh, which reaches its yaml import before it
# touches helm — so this suite is hermetic and runs in the mocked bats job.

setup() {
  TESTS_DIR="${BATS_TEST_DIRNAME}"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

# A PYTHONPATH entry whose `yaml` module raises ImportError on import, standing in
# for a runner where PyYAML is not installed. It is found before the real PyYAML
# because PYTHONPATH is prepended to sys.path.
_make_noyaml_dir() {
  local d="${BATS_TEST_TMPDIR}/noyaml"
  mkdir -p "$d"
  printf 'raise ImportError("simulated: PyYAML not installed")\n' > "$d/yaml.py"
  printf '%s' "$d"
}

@test "every yaml-importing guard preflights the PyYAML module (class rule, fails closed)" {
  run python3 - "$TESTS_DIR" "$(basename "$BATS_TEST_FILENAME")" <<'PY'
import os, re, sys

tests_dir, self_name = sys.argv[1], sys.argv[2]

# A line that pulls in the yaml MODULE, in either idiom (reviewer PR#880: the
# `from yaml import ...` form must count too, or a guard using it would be
# enumerated as a non-guard and silently skipped):
#   import yaml / import sys, yaml / import sys, yaml, posixpath   AND   from yaml import X
import_yaml = re.compile(r'^[ \t]*(?:import\b[^\n]*\byaml\b|from[ \t]+yaml\b)')
# A shell/bats-level preflight that gates the WHOLE file before any python runs:
#   require_pymodule yaml / require_yaml_tooling / a one-line `python3 -c 'import yaml'`.
shell_preflight = re.compile(
    r"""require_pymodule[ \t]+yaml|require_yaml_tooling|python3[ \t]+-c[ \t]+['"]import yaml""")
# The python-level idiom, checked STRUCTURALLY, not by substring (reviewer PR#880:
# a stray "PyYAML required" in a comment must not satisfy the rule). The import
# must sit inside a `try:` whose `except` names ImportError/ModuleNotFoundError.
try_open = re.compile(r'^[ \t]*try[ \t]*:')
except_import = re.compile(r'^[ \t]*except\b[^\n]*\b(?:ImportError|ModuleNotFoundError)\b')

def guarded_by_try(lines, i):
    up = any(try_open.match(lines[j]) for j in range(max(0, i - 5), i))
    down = any(except_import.match(lines[j]) for j in range(i + 1, min(len(lines), i + 6)))
    return up and down

guards, offenders = [], []
for name in sorted(os.listdir(tests_dir)):
    if not (name.endswith(".sh") or name.endswith(".bats")):
        continue
    if name == self_name:          # this enforcer is not itself a guard-under-test
        continue
    lines = open(os.path.join(tests_dir, name), encoding="utf-8", errors="replace").read().splitlines()
    hits = [i for i, l in enumerate(lines) if import_yaml.match(l)]
    if not hits:
        continue
    guards.append(name)
    if shell_preflight.search("\n".join(lines)):   # gated once, before python
        continue
    if all(guarded_by_try(lines, i) for i in hits):  # EVERY import wrapped
        continue
    offenders.append(name)

if not guards:
    sys.exit("[ERROR] found ZERO yaml-importing guards under scripts/tests — the "
             "enumeration is broken and a guard that checks nothing passes. Refusing.")

for o in offenders:
    print(f"  [FAIL] {o} imports the yaml module but never preflights it — a "
          f"missing PyYAML would surface as a ModuleNotFoundError traceback")

if offenders:
    sys.exit(f"\n[ERROR] {len(offenders)} of {len(guards)} yaml-importing guard(s) "
             "skip the PyYAML preflight (backend#2686). Wrap the import: import sys; "
             "try: import yaml; except ImportError: "
             'sys.exit("[ERROR] PyYAML required (pip install pyyaml)").')

print(f"  [OK] all {len(guards)} yaml-importing guard(s) preflight PyYAML")
PY
  echo "$output"
  [ "$status" -eq 0 ] || return 1
}

@test "missing PyYAML yields a named refusal, not a traceback (real guard)" {
  # helm-unittest-error-assertions.sh is the sibling the finding cites, and it
  # reaches its `import yaml` before it needs helm — so this exercises a REAL
  # guard's preflight with no helm on the runner.
  local noyaml; noyaml="$(_make_noyaml_dir)"
  PYTHONPATH="$noyaml" run bash "${TESTS_DIR}/helm-unittest-error-assertions.sh"
  echo "status=$status"
  echo "$output"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"PyYAML required"* ]] || return 1
  [[ "$output" != *"Traceback"* ]] || return 1
  [[ "$output" != *"ModuleNotFoundError"* ]] || return 1
}

@test "PyYAML present leaves the guard transparent (real guard)" {
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML not installed (local run)"
  run bash "${TESTS_DIR}/helm-unittest-error-assertions.sh"
  echo "status=$status"
  echo "$output"
  # Assert ONLY that the preflight does not fire when PyYAML is importable — NOT
  # the guard's full repo-wide verdict, so an unrelated helm-unittest defect in
  # the tree cannot turn this PyYAML-preflight test red (reviewer PR#880).
  [[ "$output" != *"PyYAML required"* ]] || return 1
}
