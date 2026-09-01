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
import ast, os, re, sys

tests_dir, self_name = sys.argv[1], sys.argv[2]

# A source line that pulls in the yaml MODULE, in either idiom. `from yaml
# import ...` must count too, or a guard using it would be enumerated as a
# non-guard and silently skipped (reviewer PR#880).
IMPORT_YAML = re.compile(r'^[ \t]*(?:import\b[^\n]*\byaml\b|from[ \t]+yaml\b)', re.M)
# A file-level shell/bats gate that refuses before any python runs. Matched on
# COMMENT-STRIPPED lines so a mention inside a comment cannot exempt the file
# (Bugbot PR#880: a whole-file substring fails open). require_yaml_tooling must
# be a CALL, not the `require_yaml_tooling() {` definition (Bugbot PR#880: the
# helper carries no argument, so def and call look alike without the `(?!…\()`).
SHELL_GATE = re.compile(
    r"""require_pymodule[ \t]+yaml\b"""
    r"""|require_yaml_tooling\b(?![ \t]*\()"""
    r"""|python3[ \t]+-c[ \t]+['"]import yaml['"]""")
# Heredoc opener in any spelling — quoted, double-quoted, or bare, with an
# optional `-` (Bugbot PR#880: a future guard must not slip through on the
# spelling). A bare delimiter still yields a snippet; if it is not python it
# simply carries no yaml import and is ignored.
HEREDOC = re.compile(r"""<<-?[ \t]*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?""")

def has_shell_gate(lines):
    return any(SHELL_GATE.search(l.split("#", 1)[0]) for l in lines)

def extract_python(lines):
    # Best-effort: python embedded in quoted heredocs and single-quoted
    # `python3 -c '...'` strings. Only snippets that import yaml get checked.
    out, i, n = [], 0, len(lines)
    while i < n:
        # Detect openers on the COMMENT-STRIPPED line so a `<<'PY'` or `python3
        # -c '` that lives inside a comment (several guards quote one in their
        # header prose) does not open a bogus block (cf. bats-hygiene.bats).
        code = lines[i].split("#", 1)[0]
        h = HEREDOC.search(code)
        if h:
            delim, body, i = h.group(1), [], i + 1
            while i < n and lines[i].strip() != delim:
                body.append(lines[i]); i += 1
            out.append("\n".join(body)); i += 1; continue
        c = re.search(r"""python3[ \t]+-c[ \t]+(['"])""", code)
        if c:
            q = c.group(1)   # match the SAME quote that opened the -c string
            rest = lines[i][c.end():]
            if q in rest:
                out.append(rest[:rest.index(q)]); i += 1; continue
            body, i = [rest], i + 1
            while i < n:
                if q in lines[i]:
                    body.append(lines[i][:lines[i].index(q)]); i += 1; break
                body.append(lines[i]); i += 1
            out.append("\n".join(body)); continue
        i += 1
    return out

def _catches_import(handler):
    t = handler.type
    if t is None:
        return True  # bare `except:` catches ImportError too
    names = ([t.id] if isinstance(t, ast.Name)
             else [e.id for e in t.elts if isinstance(e, ast.Name)] if isinstance(t, ast.Tuple)
             else [])
    return any(nm in ("ImportError", "ModuleNotFoundError") for nm in names)

def _yaml_imports(tree):
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import) and any(a.name.split(".")[0] == "yaml" for a in node.names):
            found.add(node)
        elif isinstance(node, ast.ImportFrom) and (node.module or "").split(".")[0] == "yaml":
            found.add(node)
    return found

def snippet_ok(src):
    # True  = no yaml import here, OR every yaml import sits (lexically) inside a
    #         try whose except names ImportError/ModuleNotFoundError.
    # False = an unguarded yaml import, or yaml-bearing source we cannot parse
    #         (fail closed rather than guess).
    if not IMPORT_YAML.search(src):
        return True
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return False
    imports = _yaml_imports(tree)
    if not imports:
        return True
    guarded = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Try) and any(_catches_import(h) for h in node.handlers):
            for stmt in node.body:
                for sub in ast.walk(stmt):
                    if sub in imports:
                        guarded.add(sub)
    return imports <= guarded

guards, offenders = [], []
# `.py` IS IN THE FILTER, and it was the gap that let this class re-open.
# `extract_python` finds python EMBEDDED in shell — heredocs and `python3 -c`.
# The moment a guard's python moves into a standalone sidecar, there is no
# heredoc to find, and a filter of `.sh`/`.bats` never opens the file at all: the
# first `.py` sidecar in this tree (`fullname_override_assertions.py`,
# backend#2626) escaped the rule entirely, which is exactly the shape of "a check
# that is not connected to what it claims to check" this suite exists to stop.
# Every future sidecar would have got the same free pass.
#
# A sidecar needs no extraction — the whole file IS the snippet — so it is fed to
# `snippet_ok` directly.
for name in sorted(os.listdir(tests_dir)):
    if not (name.endswith(".sh") or name.endswith(".bats") or name.endswith(".py")):
        continue
    if name == self_name:          # this enforcer is not itself a guard-under-test
        continue
    body = open(os.path.join(tests_dir, name), encoding="utf-8", errors="replace").read()
    lines = body.splitlines()
    if name.endswith(".py"):
        # A python guard is not a shell file with python inside it: the whole file
        # IS the snippet. extract_python finds only EMBEDDED blocks, so feeding a
        # .py through it yields nothing and the file would land in the "import
        # present but not captured" branch -- failing closed on a guard that is
        # correctly wrapped.
        yaml_snips = [body] if IMPORT_YAML.search(body) else []
    else:
        yaml_snips = [s for s in extract_python(lines) if IMPORT_YAML.search(s)]
    raw_import = any(IMPORT_YAML.match(l) for l in lines)
    if not (raw_import or yaml_snips):     # not a yaml-importing guard
        continue
    guards.append(name)
    # A SIDECAR HAS NO SHELL TO GATE IT. `has_shell_gate` looks for a refusal in
    # the surrounding script; in a `.py` file the same text would be a comment or
    # a string, so honouring it here would exempt exactly the files this filter
    # was extended to cover.
    if not name.endswith(".py") and has_shell_gate(lines):
        continue
    if not yaml_snips:             # import present in the file but not captured — cannot verify
        offenders.append(name); continue
    if all(snippet_ok(s) for s in yaml_snips):
        continue
    offenders.append(name)

if not guards:
    sys.exit("[ERROR] found ZERO yaml-importing guards under scripts/tests — the "
             "enumeration is broken and a guard that checks nothing passes. Refusing.")

for o in offenders:
    print(f"  [FAIL] {o} imports the yaml module but does not guard it — a missing "
          f"PyYAML would surface as a ModuleNotFoundError traceback")

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
