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
#  WHICH DOCUMENTS. The question above says "any document", and until #900's
#  review it scanned two files, so the sentence claimed more than the mechanism
#  did -- rule 7, in the guard written to stop exactly this. It was green over
#  BOTH stale runbooks in the very PR that introduced them
#  (`client/MIGRATION.md`, `docs/migration-tools/rotate-mysql-root.md`), which
#  is how it was caught. The scanned set is now the schema, the helper doc
#  blocks, AND every markdown file under `client/` and `docs/` -- globbed, not
#  listed, so a runbook added tomorrow is covered without touching this file.
#  Markdown is scanned per PARAGRAPH, and only paragraphs naming the gate, so a
#  claim is read in the context that makes it a claim.
#
#  MARKDOWN IS NORMALISED BEFORE MATCHING, and that is load-bearing rather than
#  cosmetic. The drift that shipped reads "they are `false` for `dev`, `stg`
#  and `prod`" -- with backticks and bold markers inside the very span the
#  patterns have to cross. Matching raw text would have found nothing, i.e.
#  widening the scanned set would have been vacuous: a bigger corpus that
#  cannot see the sentence it was widened for. Emphasis and code markers are
#  stripped first, and `gate-default-prose-mutations.sh` -- a real file, armed
#  in DRIFT_GUARDS beside this one -- re-inserts the original stale sentence to
#  prove the finding is reachable, and re-inserts it a second time with the
#  normaliser disabled to prove the stripping is what makes it reachable. That
#  test did not exist when this paragraph first claimed it did (Bugbot, #900):
#  the mutations had been run by hand and never committed, which is this file's
#  own subject one level up. It also runs the guard from a path CONTAINING A
#  SPACE, so the word-splitting bug fixed just above cannot come back unseen.
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

# AN ARRAY, READ LINE BY LINE -- not a whitespace-split string.
#
# This was `MDFILES=$(find ...)` passed unquoted as `$MDFILES`, which word-splits
# on spaces. The primary dev checkout lives under `.../Claude File System/...`, so
# the guard tried to read `/Users/lukas/Documents/Claude` and failed closed with
# "cannot tell, which is a finding" on EVERY run.
#
# CI never saw it: GitHub runners check out to `/home/runner/work/client/client`,
# no spaces. And `shellcheck -S warning` -- the severity this repo gates on --
# does not flag it either, because SC2086 ("double quote to prevent word
# splitting") is severity INFO. So the guard was green in CI and permanently red
# on the one machine most likely to break what it guards.
MDFILES=()
while IFS= read -r _md; do
  [ -n "$_md" ] && MDFILES+=("$_md")
done < <(find "$ROOT/client" "$ROOT/docs" -name '*.md' -type f 2>/dev/null | sort)
if [ "${#MDFILES[@]}" -eq 0 ]; then
  echo "FAIL: found ZERO markdown files under client/ and docs/ -- fail closed; " \
       "an empty corpus agrees with everything" >&2
  exit 1
fi

python3 - "$VALUES" "$SCHEMA" "$HELPERS" "${MDFILES[@]}" <<'PY'
import json, re, sys

values_p, schema_p, helpers_p = sys.argv[1:4]
md_paths = sys.argv[4:]
# Repo root, derived from the values.yaml path we were handed, so labels are
# repo-relative and identical wherever the checkout lives.
root = values_p[: -len("/client/values.yaml")] if values_p.endswith("/client/values.yaml") else ""
if not md_paths:
    print("FAIL: no markdown files passed -- fail closed", file=sys.stderr)
    sys.exit(1)

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

# ---- 3b. markdown runbooks, per paragraph, normalised -------------------
# EMPHASIS AND CODE MARKERS ARE STRIPPED. The sentence that shipped stale reads
# "they are `false` for `dev`, `stg` and `prod`" -- the backticks sit inside the
# span every claim pattern has to cross, so raw matching finds nothing and the
# whole widening would be theatre. Strip *, _, ` and the markdown link syntax,
# then collapse whitespace, and match against that.
_MD_STRIP = re.compile(r"[*_`]+")
def norm(t):
    t = _MD_STRIP.sub("", t)
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", t)   # [text](url) -> text
    return " ".join(t.lower().split())

# ---- 3a. values.yaml's OWN comment blocks -------------------------------
# The file this guard derives truth FROM also asserts that truth in prose, and
# was the one document nothing compared (Bugbot, #900): `bootstrapDbReparent`'s
# header said "OFF everywhere by default" for a whole PR after dev was baked.
# Comment runs are grouped exactly as they are written -- consecutive `#` lines
# with no blank between -- so a claim is read as the paragraph it lives in.
#
# ATTRIBUTION IS SCOPED, and getting this wrong is how a widened guard turns
# into a noisy one. A comment run routinely NAMES several gates -- the
# re-parent's header cites `serviceDbAccounts` and `perExperimentDbCreds` as its
# preconditions -- so "any gate mentioned anywhere in the block" attributed the
# re-parent's own "OFF for stg" to serviceDbAccounts, which ships stg=true. That
# is a false positive, and a guard that cries wolf gets skipped (rule 4). A
# values.yaml comment run is therefore attributed to exactly ONE gate: the key
# it introduces, i.e. the next `<gate>:` / `<gate>ByEnv:` line after it.
prose_for = {}       # gate -> [(label, text)]
_run, _start = [], None
for n, line in enumerate(text + [""], 1):
    st = line.strip()
    if st.startswith("#"):
        if _start is None:
            _start = n
        _run.append(st.lstrip("#").strip())
        continue
    if _run:
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*?)(?:ByEnv)?:\s*$', st)
        if m and m.group(1) in gates:
            prose_for.setdefault(m.group(1), []).append(
                (f"client/values.yaml#L{_start}", " ".join(_run)))
    _run, _start = [], None

md_paragraphs = []   # (label, normalised text)
for mp in md_paths:
    try:
        raw = open(mp).read()
    except OSError as e:
        print(f"FAIL: {mp} unreadable ({e}) -- cannot tell, which is a finding",
              file=sys.stderr)
        sys.exit(1)
    rel = mp[len(root) + 1:] if root and mp.startswith(root + "/") else mp
    # ONE LINE AT A TIME, for the same attribution reason as above: a markdown
    # TABLE is a single paragraph, and its rows describe different gates. The
    # SECURITY.md identity table said, correctly, "On for `dev` via
    # `perExperimentDbCredsByEnv`, off for `stg`/`prod`" -- and paragraph
    # scoping charged that `off for stg` to serviceDbAccounts, three rows away.
    # Every real drift this guard has seen names its gate on the same line as
    # the claim, so the line is the honest unit.
    for n, line in enumerate(raw.splitlines(), 1):
        if line.strip():
            md_paragraphs.append((f"{rel}:{n}", norm(line)))

# ---- 4. compare -------------------------------------------------------
# Claim patterns, per direction. These are the shapes that actually shipped.
# THE VOCABULARY IS THE CHECK'S REAL SURFACE, and listing only the spellings
# that already shipped makes it a check for LAST TIME'S wording (Bugbot, #900).
# `false everywhere` was covered; the same sentence written `OFF everywhere` --
# which is what values.yaml actually said -- matched nothing. Both polarities
# now carry the off/on synonyms as well as the boolean words.
_OFF = r'(?:false|off|disabled)'
_ON = r'(?:true|on|enabled)'

# ONE SHAPE TABLE, BOTH POLARITIES DERIVED FROM IT (saqlainsyed007, #900).
#
# These were two hand-written lists and they had DRIFTED APART: the "off" side
# carried the LIST form `<pol> for dev, stg and prod`, the "on" side did not. So
# a stale ON-polarity claim in list form naming a still-off environment did not
# redden while its off-polarity twin did -- half a guard, in the direction
# nobody had needed yet. Deriving both from one table is the fix rather than
# adding the two missing entries, because a new shape now reaches both
# polarities and this asymmetry cannot come back.
#
# TWO LATENT BUGS SURFACED THE MOMENT THE ON-SIDE WAS COMPLETED, and both were
# already in the shipped off-side patterns -- unexercised, not absent:
#
#   1. THE LIST SPAN CROSSED THE OTHER POLARITY. `[\w,\s]*` between the
#      polarity word and the env happily spanned `true for dev, false for stg`,
#      reporting "says true for stg". Every one of these documents states BOTH
#      polarities in one sentence, so the greedy span made 18 false findings.
#      The span now refuses to cross the opposite polarity word or a second
#      `for`, which is what makes "true for dev, false for stg" parse the way a
#      reader parses it.
#   2. A BARE `default <pol>` HAS NO SCOPE. It named no environment, so it fired
#      for every env whose shipped value differed -- fine while everything was
#      false everywhere, wrong the moment one env was baked on. It is gone;
#      `default`/`defaults to`/`baked` are now a PREFIX on the two scoped
#      shapes, so a claim must still say *everywhere* or name an env.
_PRE = r'(?:default(?:s)?\s+(?:to\s+)?|baked\s+)?'
_SPAN = r'(?:(?!{opp}\b|for\b)[\w,\s])*'
_POLARITY_SHAPES = [
    _PRE + r'{pol}\s+(?:by\s+default\s+)?everywhere',
    _PRE + r'{pol}\s+(?:by\s+default\s+)?for\s+' + _SPAN + r'\b{{env}}\b',
]
FALSE_CLAIMS = [sh.format(pol=_OFF, opp=_ON) for sh in _POLARITY_SHAPES]
TRUE_CLAIMS = [sh.format(pol=_ON, opp=_OFF) for sh in _POLARITY_SHAPES]

# The derivation is the claim, so assert it rather than trusting it.
if len(FALSE_CLAIMS) != len(TRUE_CLAIMS) or len(FALSE_CLAIMS) != len(_POLARITY_SHAPES):
    print("FAIL: claim lists are no longer symmetric -- the derivation broke",
          file=sys.stderr)
    sys.exit(1)

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

    # Only paragraphs that NAME this gate: a claim is read in the context that
    # makes it a claim about this gate, never as loose prose anywhere in a file.
    needle = key.lower()
    alt = gate.lower()
    for label, para in md_paragraphs:
        if needle in para or alt in para:
            sources[label] = para
    for label, blk in prose_for.get(gate, []):
        sources[label] = norm(blk)

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
