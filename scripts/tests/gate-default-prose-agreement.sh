#!/usr/bin/env bash
#
#  gate-default-prose-agreement.sh — a gate's docs must not contradict the
#  default the chart actually ships (backend#1528, found in review on #900).
#
#  THE DEFECT, as it happened. #900 flipped three `*ByEnv` gates from
#  `dev: false` to `dev: true`, baking dev's retired posture into the chart.
#  `values.yaml`'s own inline comments were updated. Six other places were not:
#  three `values.schema.json` descriptions and three `_helpers.tpl` doc headers
#  went on saying "false everywhere by default" / "False for dev, stg and prod"
#  / "DEFAULT FALSE EVERYWHERE".
#
#  ALL 29 DRIFT GUARDS STAYED GREEN, and that is the point of this file. The
#  schema is the operator-facing contract -- it is what `helm show values`
#  readers and editor tooling surface -- so the chart was shipping a document
#  that stated the OPPOSITE of what a default `dev` install renders, with CI
#  agreeing. Nothing compared prose to values, so nobody could have been told.
#
#  WHAT IS CHECKED, and why it is derived rather than listed. The gates are
#  enumerated FROM `values.yaml` -- every `*ByEnv` key and its per-env booleans
#  are parsed out, so a sixth gate added tomorrow is covered without touching
#  this file, and a hand-written list cannot drift away from the chart (rule 1).
#  For each gate, IF the shipped default for an env is `true`, THEN neither the
#  schema description nor the helper doc block may claim it is false there; and
#  vice versa. The claim patterns are the ones that actually appeared, matched
#  case-insensitively.
#
#  It is deliberately NOT a general prose checker. It answers one question --
#  "does any document assert a default this chart contradicts?" -- which is
#  decidable, rather than "is this prose accurate", which is not.
#
#  FAILS CLOSED (rule 3): an unreadable values.yaml or schema, a schema that
#  does not parse, a gate with no description, or zero gates parsed are all
#  FAILURES. "We could not read them" must never pass as "they agree" -- zero
#  compared pairs compare equal to zero compared pairs.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VALUES="$ROOT/client/values.yaml"
SCHEMA="$ROOT/client/values.schema.json"
HELPERS="$ROOT/client/templates/_helpers.tpl"

for f in "$VALUES" "$SCHEMA" "$HELPERS"; do
  [ -r "$f" ] || { echo "FAIL: $f unreadable -- cannot tell, which is a finding" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 1; }

python3 - "$VALUES" "$SCHEMA" "$HELPERS" <<'PY'
import json, re, sys

values_p, schema_p, helpers_p = sys.argv[1:4]

# ---- 1. DERIVE the gates and their shipped defaults from values.yaml -----
text = open(values_p).read().splitlines()
gates = {}
i = 0
while i < len(text):
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)ByEnv:\s*$', text[i])
    if m:
        gate, envs = m.group(1), {}
        j = i + 1
        while j < len(text) and re.match(r'^\s+\S', text[j]):
            mm = re.match(r'^\s+(\w+):\s*(true|false)\s*$', text[j])
            if mm:
                envs[mm.group(1)] = (mm.group(2) == "true")
            j += 1
        if envs:
            gates[gate] = envs
    i += 1

if not gates:
    print("FAIL: parsed ZERO *ByEnv gates from values.yaml -- fail closed, this "
          "is a finding and not agreement", file=sys.stderr)
    sys.exit(1)

# ---- 2. the schema descriptions, by key ---------------------------------
try:
    schema = json.load(open(schema_p))
except Exception as e:
    print(f"FAIL: {schema_p} does not parse as JSON ({e}) -- cannot tell", file=sys.stderr)
    sys.exit(1)

descs = {}
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if isinstance(v, dict) and isinstance(v.get("description"), str):
                descs.setdefault(k, v["description"])
            walk(v)
    elif isinstance(o, list):
        for x in o:
            walk(x)
walk(schema)

# ---- 3. the helper doc block for each gate ------------------------------
helpers = open(helpers_p).read()
def helper_doc(gate):
    # The {{/* ... */}} comment immediately preceding `define "tracebloc.<gate>"`.
    m = re.search(r'\{\{/\*((?:(?!\*/\}\}).)*)\*/\}\}\s*\{\{-\s*define\s+"tracebloc\.'
                  + re.escape(gate) + r'"', helpers, re.S)
    return m.group(1) if m else None

# ---- 4. compare -------------------------------------------------------
# Claim patterns, per direction. These are the shapes that actually shipped.
FALSE_CLAIMS = [
    r'false\s+everywhere',
    r'default\s+false',
    r'false\s+for\s+{env}\b',
    r'false\s+for\s+[\w,\s]*\b{env}\b',
]
TRUE_CLAIMS = [
    r'true\s+for\s+{env}\b',
    r'baked\s+on\s+for\s+{env}\b',
]

findings = []
checked = 0

for gate, envs in sorted(gates.items()):
    key = gate + "ByEnv"
    sources = {"values.schema.json:" + key: descs.get(key),
               "_helpers.tpl:tracebloc." + gate: helper_doc(gate)}

    if sources["values.schema.json:" + key] is None:
        findings.append(f"{key}: NO schema description -- fail closed; a gate the "
                        f"operator-facing contract does not describe cannot be "
                        f"checked, and that is a finding")
        continue

    for where, prose in sources.items():
        if prose is None:
            continue          # a gate may legitimately have no helper of that name
        low = " ".join(prose.lower().split())
        for env, shipped in sorted(envs.items()):
            checked += 1
            bad = TRUE_CLAIMS if not shipped else FALSE_CLAIMS
            word = "true" if not shipped else "false"
            for pat in bad:
                if re.search(pat.format(env=env), low):
                    excerpt = re.search(pat.format(env=env), low).group(0)
                    findings.append(
                        f"{where}: says {word!r} for {env} (matched {excerpt!r}) "
                        f"but values.yaml ships {key}.{env} = {str(shipped).lower()}")
                    break

if checked == 0:
    print("FAIL: compared ZERO gate/env pairs -- fail closed", file=sys.stderr)
    sys.exit(1)

if findings:
    print("gate-default-prose-agreement: FAIL", file=sys.stderr)
    for f in findings:
        print("  - " + f, file=sys.stderr)
    print(f"\n  {len(gates)} gate(s), {checked} gate/env pair(s) compared.\n"
          "  The schema is the operator-facing contract; a description that "
          "contradicts\n  the shipped default is worse than none. Update the prose "
          "in the same PR as\n  the default (repo CLAUDE.md).", file=sys.stderr)
    sys.exit(1)

print(f"gate-default-prose-agreement: OK -- {len(gates)} gate(s), {checked} "
      f"gate/env pair(s); no document contradicts a shipped default.")
PY
