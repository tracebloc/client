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
  run python3 - "$TESTS_DIR" <<'PY'
import os, re, sys

tests_dir = sys.argv[1]
# Anything that pulls in the yaml module — `import yaml`, `import sys, yaml`,
# `import sys, yaml, posixpath`, or an inline `python3 -c '... import yaml'`.
imports_yaml = re.compile(r'\bimport\b[^\n]*\byaml\b')
# The accepted preflights, one per idiom in this tree:
#   - python-level: sys.exit("[ERROR] PyYAML required ...") after `except ImportError`
#   - .bats helper: require_pymodule yaml / require_yaml_tooling
#   - one-line shell probe: python3 -c 'import yaml'
preflight_signals = (
    "PyYAML required",
    "require_pymodule yaml",
    "require_yaml_tooling",
)
inline_probe = re.compile(r"""python3\s+-c\s+['"]import yaml""")

guards, offenders = [], []
for name in sorted(os.listdir(tests_dir)):
    if not (name.endswith(".sh") or name.endswith(".bats")):
        continue
    text = open(os.path.join(tests_dir, name), encoding="utf-8", errors="replace").read()
    if not imports_yaml.search(text):
        continue
    guards.append(name)
    if any(s in text for s in preflight_signals) or inline_probe.search(text):
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
             "skip the PyYAML preflight (backend#2686). Add the interpreter-then-"
             "module check the siblings use: import sys; try: import yaml; except "
             'ImportError: sys.exit("[ERROR] PyYAML required (pip install pyyaml)").')

print(f"  [OK] all {len(guards)} yaml-importing guard(s) preflight PyYAML")
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "missing PyYAML yields a named refusal, not a traceback (real guard)" {
  # helm-unittest-error-assertions.sh is the sibling the finding cites, and it
  # reaches its `import yaml` before it needs helm — so this exercises a REAL
  # guard's preflight with no helm on the runner.
  local noyaml; noyaml="$(_make_noyaml_dir)"
  PYTHONPATH="$noyaml" run bash "${TESTS_DIR}/helm-unittest-error-assertions.sh"
  echo "status=$status"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PyYAML required"* ]]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" != *"ModuleNotFoundError"* ]]
}

@test "PyYAML present leaves the guard transparent (real guard)" {
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "PyYAML not installed (local run)"
  run bash "${TESTS_DIR}/helm-unittest-error-assertions.sh"
  echo "status=$status"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PyYAML required"* ]]
}
