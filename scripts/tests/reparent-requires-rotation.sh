#!/usr/bin/env bash
#
#  reparent-requires-rotation.sh — `bootstrapDbReparentByEnv` may only be
#  defaulted true where `rotateMysqlRootByEnv` is (backend#2738).
#
#  WHY. `bootstrapDbReparent` needs the MySQL root password, and there is no
#  generated default: jobs-manager AUTHENTICATES as root and never runs
#  `ALTER USER root`, so a random value would lock the minter out. The pin can
#  come from three places, and only one of them works for a DEFAULT:
#
#    1. an explicit .Values.bootstrapDbPassword  -- an operator action, so it
#       cannot be assumed by a default;
#    2. the live Secret                          -- empty on a fresh install and
#       in every `helm template`/dry-run, so a default relying on it breaks the
#       render for a first install;
#    3. DERIVED FROM THE ROTATION (backend#2738) -- when `rotateMysqlRoot` is on
#       the chart OWNS root's password, so the pin is the same secret under a
#       second name. This one renders everywhere, which is what makes baking
#       possible at all.
#
#  So a default pair of reparent=true / rotate=false has no third tier to fall
#  back on: it renders only where an operator has supplied a pin, and hard-fails
#  every other install of that environment. backend#2738 measured exactly that.
#
#  This guard exists because the failure is in a DEFAULT rather than in an
#  operator's values, so nobody sees it until a fresh install of that environment
#  is attempted -- possibly by a customer, on a chart release that is already out.
#  The template's own `fail` catches the case at render time; this catches it at
#  review time, which is the only point at which it is cheap.
#
#  DERIVED from values.yaml (rule 1): the environment set comes from the maps
#  themselves, never a hand-written list, so a fourth environment is covered the
#  day it is added.
#
#  FAILS CLOSED (rule 3): a missing values.yaml, unparseable YAML, or a missing
#  map is a FAILURE. "We could not read the gates" must never pass as "the gates
#  agree".
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VALUES="$ROOT/client/values.yaml"

[ -r "$VALUES" ] || { echo "FAIL: $VALUES unreadable -- cannot tell, which is a finding" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 1; }

python3 - "$VALUES" <<'PY'
import sys

try:
    import yaml
except ImportError:
    print("FAIL: PyYAML is required to read values.yaml", file=sys.stderr)
    sys.exit(1)

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        values = yaml.safe_load(fh)
except (OSError, yaml.YAMLError) as exc:
    print(f"FAIL: {path} is not readable YAML ({exc})", file=sys.stderr)
    sys.exit(1)

REPARENT = "bootstrapDbReparentByEnv"
ROTATE = "rotateMysqlRootByEnv"

missing = [k for k in (REPARENT, ROTATE) if not isinstance(values.get(k), dict)]
if missing:
    print(
        f"FAIL: {missing} is not a map in values.yaml. If a gate was renamed, this "
        "guard must be renamed with it rather than left comparing keys that are "
        "gone -- a check that examines nothing must not pass.",
        file=sys.stderr,
    )
    sys.exit(1)

def problems_for(reparent, rotate):
    """THE RULE, in one place. Returns a list of human-readable problems.

    Both the values.yaml check below and the self-cases call THIS function --
    never a re-implementation of it (rule 9). That matters here more than usual:
    with the shipped defaults `reparent` is false for every environment, so the
    pairing branch is UNREACHABLE from values.yaml alone and a mutation of it
    would not redden. The self-cases are what keep this guard non-vacuous until
    the day the first environment is baked on.
    """
    problems = []
    # The environment set is the UNION of both maps' keys, so an env declared in
    # one and forgotten in the other is a finding rather than a silent skip.
    for env in sorted(set(reparent) | set(rotate)):
        if env not in reparent:
            problems.append(f"{env!r} is in {ROTATE} but not in {REPARENT}")
        elif env not in rotate:
            problems.append(f"{env!r} is in {REPARENT} but not in {ROTATE}")
        elif reparent[env] and not rotate[env]:
            problems.append(
                f"{env!r} defaults {REPARENT}=true with {ROTATE}=false. The "
                "re-parent then has no pin it can derive: the live-Secret tier is "
                "empty on a fresh install and in every dry-run, so this default "
                "hard-fails the render for every install of that environment that "
                "does not set bootstrapDbPassword explicitly (backend#2738). "
                "Enable the rotation for that environment too, or leave the "
                "re-parent off."
            )
    return problems


# ---------------------------------------------------------------------------
#  Self-cases: the rule's own input domain, written down INDEPENDENTLY of the
#  matcher (rule 9's corollary -- never test a list against itself) and covering
#  every combination of the two booleans plus both asymmetries. Without these the
#  guard is vacuous today, because no shipped environment bakes the re-parent on.
# ---------------------------------------------------------------------------
SELF_CASES = [
    # (reparent, rotate, must_be_flagged, why)
    ({"e": True},  {"e": True},  False, "both baked on -- the derivable pair"),
    ({"e": False}, {"e": False}, False, "neither baked -- operator's call"),
    ({"e": False}, {"e": True},  False, "rotation alone is fine on its own"),
    ({"e": True},  {"e": False}, True,  "THE BUG: re-parent baked with no pin to derive"),
    ({"e": True},  {},           True,  "env missing from the rotation map"),
    ({},           {"e": True},  True,  "env missing from the re-parent map"),
]

self_failures = []
for rep, rot, must_flag, why in SELF_CASES:
    flagged = bool(problems_for(rep, rot))
    if flagged != must_flag:
        self_failures.append(
            f"case {why!r}: expected {'a finding' if must_flag else 'no finding'}, "
            f"got {'a finding' if flagged else 'no finding'}"
        )
if self_failures:
    print(
        "FAIL: the pairing rule does not behave as specified, so its verdict on "
        "values.yaml cannot be trusted:",
        file=sys.stderr,
    )
    for f in self_failures:
        print(f"  [x] {f}", file=sys.stderr)
    sys.exit(1)

reparent = values[REPARENT]
rotate = values[ROTATE]

envs = sorted(set(reparent) | set(rotate))
if not envs:
    print(
        f"FAIL: neither {REPARENT} nor {ROTATE} declares any environment, so this "
        "comparison would be vacuous.",
        file=sys.stderr,
    )
    sys.exit(1)

problems = problems_for(reparent, rotate)
if problems:
    print("FAIL: the re-parent and rotation gate defaults disagree:", file=sys.stderr)
    for p in problems:
        print(f"  [x] {p}", file=sys.stderr)
    sys.exit(1)

on = [e for e in envs if reparent[e]]
print(
    f"reparent-requires-rotation: OK -- {len(SELF_CASES)} self-case(s) and "
    f"{len(envs)} environment(s) checked ({', '.join(envs)}); "
    + (
        f"re-parent defaulted on for {on}, each with the rotation on."
        if on
        else "re-parent defaulted on for none, so nothing to pair yet."
    )
)
PY
