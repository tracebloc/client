#!/usr/bin/env bash
#
#  gate-byenv-resolution.sh — every `<gate>ByEnv` map must actually change the
#  render, for every CLIENT_ENV spelling the chart accepts (backend#1528).
#
#  THE DEFECT THIS EXISTS FOR. `perExperimentDbCreds` shipped with no `ByEnv`
#  map at all while every sibling gate had one -- so the flag backend#1528's
#  LAST step is gated on was the only one whose fleet posture the chart could
#  not record. A fleet taken to the per-experiment credential shape held that
#  fact solely in its stored release values; a values-resetting upgrade drops
#  it, and dropping it puts the account mint back on `edgeuser`, the account the
#  whole ticket exists to retire. Nothing failed. Nothing could have.
#
#  Adding the map is not enough on its own, which is the second half of why this
#  file exists. Two ways a map can be present and inert, both hit while writing
#  that change:
#
#    * the override key left as a literal `false` rather than null -- the helper
#      distinguishes "unset" from "explicitly false", so a literal reads as an
#      OPERATOR OVERRIDE and wins over every fleet default. The map parses, the
#      schema passes, and the map is dead.
#    * a nullable override key whose values.schema.json entry still says
#      `"type": "boolean"` -- helm then refuses the whole render, which a probe
#      that greps a render for a string reports as "the gate is off".
#
#  BOTH SIDES DERIVED, NEITHER RESTATED.
#
#    * The GATES come from values.yaml: every top-level key `X` that also has an
#      `XByEnv` sibling. Add a fourth gate and it is swept with no edit here.
#    * The ENVIRONMENTS come from the chart's own alias table in
#      `_helpers.tpl::tracebloc.clientEnv`, plus the canonical keys of each map.
#      A vocabulary gap is invisible to mutation coverage (CLAUDE.md rule 6), so
#      the input domain is taken from the producer's declared surface and all of
#      it is tested -- `staging` vs `stg` is exactly the miss backend#1723 was.
#
#  ALIAS NORMALIZATION IS COVERED BY THE SAME LOOP, not a second one. Each case
#  renders under the SPELLING while flipping the CANONICAL key, so if `staging`
#  failed to normalize to `stg` the lookup would miss, the render would not
#  change, and the flip assertion below would fail. A separate alias pass was
#  written first and deleted: it byte-compared the two renders with the spelling
#  sed'd out, which failed on every gate INCLUDING the two known-good ones --
#  a broken instrument reporting a chart-wide defect that was not there.
#
#  WHAT IS ASSERTED, and why it needs no per-gate table. For each gate and each
#  environment, the chart is rendered twice -- once with that environment's
#  entry forced true, once false -- and the two renders must DIFFER. That is the
#  property "this map reaches the templates", stated without knowing or caring
#  which env var, Secret or RBAC rule the gate happens to emit. A per-gate table
#  of observables would be a second copy of the templates, and would go stale
#  the first time a gate grew a new effect.
#
#  THE RENDER IS NONDETERMINISTIC, AND IGNORING THAT MADE THIS FILE VACUOUS.
#  `POD_TOKEN_SIGNING_SECRET`, `TB_META_PASSWORD` and `TB_INGEST_PASSWORD` are
#  generated per render, so two renders of the SAME inputs already differ by six
#  lines. A plain `cmp` therefore reported "differs" for every gate whatever the
#  flag did -- measured: with the call sites reverted to the raw value, and again
#  with the override key put back as a literal `false`, this guard still passed.
#  Both are the exact defects it exists to catch.
#
#  The fix is not a hand-written list of volatile keys -- that is a second copy
#  of the chart's secret-generation, and it goes stale the first time one is
#  added. Instead the noise is MEASURED: render the same inputs twice, take the
#  keys that differ, and require the true/false diff to touch at least one key
#  outside that set. Self-maintaining, and a new generated secret is absorbed
#  automatically rather than silently widening the blind spot.
#
#  Usage: bash scripts/tests/gate-byenv-resolution.sh
#
set -euo pipefail

cd "$(dirname "$0")/../.."
CHART="${CHART:-./client}"
VALUES_FILE="$CHART/values.yaml"
HELPERS="$CHART/templates/_helpers.tpl"

[ -f "$CHART/Chart.yaml" ] || { echo "FATAL: no chart at $CHART/Chart.yaml" >&2; exit 1; }
[ -r "$VALUES_FILE" ] || { echo "FATAL: cannot read $VALUES_FILE -- cannot tell, which is a finding" >&2; exit 1; }
[ -r "$HELPERS" ]     || { echo "FATAL: cannot read $HELPERS" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "FATAL: helm is required; a skip here is indistinguishable from a pass" >&2; exit 1; }

# PYYAML, PREFLIGHTED BEFORE ANY PYTHON RUNS -- the class rule every yaml-reading
# guard here obeys, enforced by `scripts/tests/pyyaml-preflight.bats` (Bugbot).
#
# Without it the discovery heredocs below die as a bare `ModuleNotFoundError`
# traceback on a runner that has python3 but not PyYAML, instead of the named
# refusal every sibling emits -- and the reader is left debugging a stack trace
# for a missing dependency. The spelling matters as much as the check: the class
# rule recognises `python3 -c 'import yaml'` as a file-level gate, so writing it
# any other way passes the runtime and fails the rule.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required to read $VALUES_FILE; a skip here is indistinguishable from a pass" >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo "FATAL: PyYAML required (python3 -m pip install pyyaml) -- this guard reads $VALUES_FILE, and cannot tell is a finding" >&2; exit 1; }

fails=0
checks=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok()   { checks=$((checks + 1)); }

# --- the gates, read out of values.yaml -------------------------------------
GATES=$(python3 - "$VALUES_FILE" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    values = yaml.safe_load(fh)
print("\n".join(sorted(k for k in values if k + "ByEnv" in values)))
PY
)
if [ -z "$GATES" ]; then
  echo "FAIL: no '<gate>' + '<gate>ByEnv' pair found in $VALUES_FILE. Either the
      per-environment mechanism was removed, or this discovery drifted. Zero
      swept gates compares equal to zero swept gates (rule 3)." >&2
  exit 1
fi
ok

# --- the environments, read out of the chart's own alias table --------------
ENVS=$(python3 - "$HELPERS" "$VALUES_FILE" <<'PY'
import re, sys, yaml
helpers = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'\$aliases\s*:=\s*dict\s+(.+?)-\}\}', helpers, re.S)
if not match:
    sys.exit("could not find the $aliases dict in tracebloc.clientEnv")
tokens = re.findall(r'"([^"]+)"', match.group(1))
aliases = dict(zip(tokens[0::2], tokens[1::2]))
with open(sys.argv[2], encoding="utf-8") as fh:
    values = yaml.safe_load(fh)
canonical = set()
for key, value in values.items():
    if key.endswith("ByEnv") and isinstance(value, dict):
        canonical |= set(value)
if not canonical:
    sys.exit("no canonical environments found in any ByEnv map")
# alias -> canonical, and every canonical name itself
print("\n".join(f"{name} {aliases.get(name, name)}" for name in sorted(canonical | set(aliases))))
PY
)
[ -n "$ENVS" ] || { echo "FAIL: no CLIENT_ENV vocabulary derived" >&2; exit 1; }
ok

# Companion secrets for gates that REFUSE to render without one (measured:
# bootstrapDbReparent fails by design, because jobs-manager authenticates as
# root and there can be no generated default). Supplied for every render so a
# refusal cannot be mistaken for "the gate is off".
COMPANIONS=(--set bootstrapDbPassword=placeholderplaceholder
            --set mysqlRootPassword=placeholderplaceholder
            --set credmgrPassword=placeholderplaceholder)

render_to() {  # $1 = out file; rest = extra helm args. Non-zero on helm failure.
  local out="$1"; shift
  helm template gate "$CHART" \
    --set clientId=x --set clientPassword=x --set storageClass.create=false \
    "${COMPANIONS[@]}" "$@" >"$out" 2>&1
}

TRUE_OUT=$(mktemp); FALSE_OUT=$(mktemp); NOISE_A=$(mktemp); NOISE_B=$(mktemp); NOISE=$(mktemp)
trap 'rm -f "$TRUE_OUT" "$FALSE_OUT" "$NOISE_A" "$NOISE_B" "$NOISE"' EXIT INT TERM HUP

# The keys that differ between two renders of IDENTICAL inputs: generated
# secrets. Measured, not listed.
keys_of() { sed -n 's/^[-> <]*\([A-Za-z_][A-Za-z0-9_.-]*\):.*/\1/p' "$1" | sort -u; }
if ! render_to "$NOISE_A" --set env.CLIENT_ENV=dev || ! render_to "$NOISE_B" --set env.CLIENT_ENV=dev; then
  echo "FAIL: the baseline render failed, so render noise could not be measured
      and every comparison below would be untrustworthy (rule 3)." >&2
  exit 1
fi
diff "$NOISE_A" "$NOISE_B" > "$NOISE.raw" || true
keys_of "$NOISE.raw" > "$NOISE"
echo "render noise: $(wc -l < "$NOISE" | tr -d " ") volatile key(s) — $(paste -sd, - < "$NOISE")"
ok

while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  while IFS=' ' read -r spelling canonical; do
    [ -n "$spelling" ] || continue

    if ! render_to "$TRUE_OUT" --set "env.CLIENT_ENV=$spelling" --set "${gate}ByEnv.${canonical}=true"; then
      fail "$gate / CLIENT_ENV=$spelling: the ON render FAILED, so this gate is
      unverified rather than off:
$(sed 's/^/        /' "$TRUE_OUT" | tail -4)"
      continue
    fi
    if ! render_to "$FALSE_OUT" --set "env.CLIENT_ENV=$spelling" --set "${gate}ByEnv.${canonical}=false"; then
      fail "$gate / CLIENT_ENV=$spelling: the OFF render FAILED:
$(sed 's/^/        /' "$FALSE_OUT" | tail -4)"
      continue
    fi
    # A difference only in volatile keys is NOT evidence the flag did anything.
    signal=$(diff "$TRUE_OUT" "$FALSE_OUT" | grep -E '^[<>]' | grep -vFf "$NOISE" || true)
    if [ -z "$signal" ]; then
      fail "$gate: flipping ${gate}ByEnv.${canonical} changes NOTHING in the render
      for CLIENT_ENV=$spelling, outside the generated secrets that differ on
      every render anyway. The map is present and inert -- the templates read
      the raw value, or the override key is a literal instead of null, or no
      helper resolves it. That is a fleet posture the chart cannot record."
    fi
    ok
  done <<< "$ENVS"
done <<< "$GATES"

if [ "$fails" -ne 0 ]; then
  echo "gate-byenv-resolution: $fails failure(s) across $checks assertion(s)" >&2
  exit 1
fi
# A sweep that ran nothing is not a green sweep (rule 3). Three gates x six
# spellings is 18 flip checks plus 9 alias checks plus the two discovery
# assertions; anything far below that means discovery collapsed.
if [ "$checks" -lt 18 ]; then
  echo "gate-byenv-resolution: only $checks assertion(s) ran; expected 18+.
  Gate or environment discovery collapsed -- a shrunken sweep must not report
  success." >&2
  exit 1
fi
echo "gate-byenv-resolution: OK ($checks assertions)"
