#!/usr/bin/env bash
#
#  env-vocabulary-agreement.sh — the CLIENT_ENV alias vocabulary is declared in
#  FOUR languages, and until this script nothing checked they agreed.
#
#  WHY THIS EXISTS (backend#1729, sweep 5)
#  --------------------------------------
#  backend#1729 names the class: "a verification written in the same vocabulary
#  as the thing it verifies cannot detect a vocabulary error." Its evidence was
#  366 chart tests covering dev/stg/prod/unset/unknown while NOT ONE set
#  `staging` — the alias the chart's own docs tell users to write.
#
#  That instance is fixed. This is the structural half: the same three
#  alias->canonical mappings are written out four separate times, in four
#  different languages, and each was fixed independently when it broke.
#
#    1  client/templates/_helpers.tpl   `$aliases := dict ...`  (Go template)
#    2  client/values.schema.json       the CLIENT_ENV `enum`   (JSON Schema)
#    3  scripts/lib/common.sh           `tb_client_env()`       (bash case)
#    4  scripts/install-k8s.ps1         `Get-TraceblocClientEnv` (PowerShell switch)
#
#  backend#1723 fixed the chart. backend#1745 fixed the bash installer, whose
#  own comment records the cost: "a raw `staging` fell through to the prod
#  branch, so verify_credentials() checked staging credentials against the
#  production backend and reported them invalid." Two of the four have already
#  drifted, separately, and been repaired separately.
#
#  So: add a seventh spelling to the template and the installers silently will
#  not reduce it -- which is backend#1745 reintroduced, in a repo that has
#  already paid for it once.
#
#  THIS SCRIPT DERIVES, IT DOES NOT RESTATE. It parses all four declarations and
#  compares them to each other. It deliberately holds no copy of the vocabulary:
#  a fifth hand-written list is the defect, not the fix (the lesson of
#  backend#1780 and backend#1828, where hand-copied declarations each claimed
#  the others kept them honest and nothing crossed the boundary).
#
#  It also asserts every accepted spelling is exercised by at least one
#  helm-unittest case, which is the specific gap #1729 measured.
#
#  READ-ONLY. Exit 0 clean, 1 disagreement, 2 cannot tell (fail closed).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

TPL="$root/client/templates/_helpers.tpl"
SCHEMA="$root/client/values.schema.json"
BASH_LIB="$root/scripts/lib/common.sh"
PS1_FILE="$root/scripts/install-k8s.ps1"
TESTS_DIR="$root/client/tests"

fail_closed() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }
for f in "$TPL" "$SCHEMA" "$BASH_LIB" "$PS1_FILE"; do
  [ -r "$f" ] || fail_closed "cannot read ${f#"$root"/} -- refusing to report agreement between declarations one of which was not read"
done
[ -d "$TESTS_DIR" ] || fail_closed "cannot read ${TESTS_DIR#"$root"/}"

# Reading the JSON Schema enum needs a JSON parser; per the repo's "no jq in
# installer scripts" rule that parser is python3 (see schema_accepted below).
# `make setup` does not install python3, so on the pre-push `make check` path a
# missing interpreter would otherwise surface below as "the schema has no enum" --
# a false schema-gap diagnosis. A missing tool is not a vocabulary change: fail
# here, loud and distinct, before any empty result can be read as a gap.
command -v python3 >/dev/null 2>&1 || fail_closed "python3 is required for this check -- it reads the CLIENT_ENV enum out of values.schema.json (which is JSON) and was not found on PATH. Install python3 or add it to 'make setup'; this is a missing tool, not a schema change."

# --- 1. the Go template's alias dict -------------------------------------
# `$aliases := dict "development" "dev" "staging" "stg" "production" "prod"`
tpl_pairs() {
  sed -n 's/.*\$aliases := dict \(.*\)-}}.*/\1/p' "$TPL" \
    | tr -d '"' \
    | awk '{ for (i = 1; i < NF; i += 2) print $i "=" $(i+1) }' \
    | sort
}

# --- 2. the JSON Schema enum (accepted spellings, not mappings) ----------
schema_accepted() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
node = d.get("properties", {}).get("env", {}).get("properties", {}).get("CLIENT_ENV", {})
vals = node.get("enum")
if vals is None:
    sys.exit(3)
for v in vals:
    if v != "":
        print(v)
' "$SCHEMA" | sort
}

# --- 3. bash tb_client_env() --------------------------------------------
bash_pairs() {
  awk '/^tb_client_env\(\)/ { inf = 1 }
       inf && /^\}/         { exit }
       inf && /printf/ {
         line = $0
         if (match(line, /^[[:space:]]*[a-z]+\)/)) {
           key = substr(line, RSTART, RLENGTH - 1); gsub(/[[:space:]]/, "", key)
           if (match(line, /printf '"'"'[a-z]+'"'"'/)) {
             val = substr(line, RSTART + 8, RLENGTH - 9)
             print key "=" val
           }
         }
       }' "$BASH_LIB" | sort
}

# --- 4. PowerShell Get-TraceblocClientEnv -------------------------------
ps1_pairs() {
  awk '/function Get-TraceblocClientEnv/ { inf = 1 }
       inf && /^\}/                      { exit }
       inf && /return/ {
         if (match($0, /"[a-z]+"[[:space:]]*\{[[:space:]]*return[[:space:]]*"[a-z]+"/)) {
           s = substr($0, RSTART, RLENGTH)
           n = split(s, parts, /"/)
           print parts[2] "=" parts[4]
         }
       }' "$PS1_FILE" | sort
}

findings=0
note() { findings=$((findings + 1)); printf '\nFINDING %d: %s\n' "$findings" "$1"; shift; for l in "$@"; do printf '  %s\n' "$l"; done; }

tpl="$(tpl_pairs)"
bsh="$(bash_pairs)"
ps1="$(ps1_pairs)"
# schema_accepted's python helper exits 3 only for a genuinely-absent enum, and 0
# with output when it is present. Any OTHER non-zero (a python3 that passed the
# preflight but then failed to run, malformed JSON, a mid-run read error) is a
# tooling/parse failure, NOT evidence the schema changed -- so keep the two
# diagnoses apart: a real missing enum is still reported as the closed-vocabulary
# finding, and a tooling gap is never misreported as one.
sch="$(schema_accepted)"; schema_rc=$?
if [ "$schema_rc" -eq 3 ]; then
  fail_closed "values.schema.json has no CLIENT_ENV enum -- the vocabulary is no longer closed there, which is a bigger finding than a disagreement"
elif [ "$schema_rc" -ne 0 ]; then
  fail_closed "could not read the CLIENT_ENV enum from values.schema.json (python3 exited $schema_rc) -- a tooling or parse failure, not evidence the schema changed; refusing to guess"
fi

# An empty parse must never read as "they agree". Every declaration that stopped
# matching is reported, because zero pairs compares equal to zero pairs.
[ -n "$tpl" ] || fail_closed "parsed NO alias pairs from _helpers.tpl; the parser is stale and every comparison below would be vacuous"
[ -n "$bsh" ] || fail_closed "parsed NO alias pairs from common.sh tb_client_env()"
[ -n "$ps1" ] || fail_closed "parsed NO alias pairs from install-k8s.ps1 Get-TraceblocClientEnv"
[ -n "$sch" ] || fail_closed "parsed NO accepted values from the schema enum"

printf 'CLIENT_ENV alias vocabulary, as declared by each of the four sources:\n'
printf '  _helpers.tpl      %s\n' "$(echo "$tpl" | tr '\n' ' ')"
printf '  common.sh         %s\n' "$(echo "$bsh" | tr '\n' ' ')"
printf '  install-k8s.ps1   %s\n' "$(echo "$ps1" | tr '\n' ' ')"
printf '  values.schema.json accepts: %s\n' "$(echo "$sch" | tr '\n' ' ')"

# --- the three reducers must agree exactly ------------------------------
if [ "$tpl" != "$bsh" ]; then
  note "the chart and the bash installer disagree about the alias mappings" \
    "_helpers.tpl: $(echo "$tpl" | tr '\n' ' ')" \
    "common.sh   : $(echo "$bsh" | tr '\n' ' ')" \
    "backend#1745 was exactly this: a spelling the chart reduced and the" \
    "installer did not, so verify_credentials() checked staging credentials" \
    "against the production backend and called them invalid."
fi
if [ "$tpl" != "$ps1" ]; then
  note "the chart and the PowerShell installer disagree about the alias mappings" \
    "_helpers.tpl   : $(echo "$tpl" | tr '\n' ' ')" \
    "install-k8s.ps1: $(echo "$ps1" | tr '\n' ' ')" \
    "A Windows install would resolve a different environment than the chart it" \
    "then deploys -- the same defect as #1745 on the other installer."
fi

# --- the schema must accept exactly canonical + aliases -----------------
canon="$(echo "$tpl" | cut -d= -f2 | sort -u)"
alias_keys="$(echo "$tpl" | cut -d= -f1 | sort -u)"
expected_accepted="$(printf '%s\n%s\n' "$canon" "$alias_keys" | sort -u)"
if [ "$sch" != "$expected_accepted" ]; then
  note "values.schema.json's enum is not exactly {canonical} + {aliases}" \
    "schema accepts: $(echo "$sch" | tr '\n' ' ')" \
    "derived from the template: $(echo "$expected_accepted" | tr '\n' ' ')" \
    "A spelling the schema accepts but no reducer maps reaches the template raw." \
    "A spelling a reducer maps but the schema rejects is unreachable, so the" \
    "reducer's branch is dead code that looks like support."
fi

# --- every accepted spelling must be exercised by a test ---------------
# This is the gap backend#1729 MEASURED: 366 cases, none setting `staging`.
while IFS= read -r spelling; do
  [ -n "$spelling" ] || continue
  n=$(grep -rhoE "CLIENT_ENV: *\"?${spelling}\"?[[:space:]]*$" "$TESTS_DIR" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -eq 0 ]; then
    note "no helm-unittest case sets CLIENT_ENV=$spelling" \
      "It is an accepted spelling, so a user can write it, and nothing renders" \
      "the chart with it. backend#1729 measured this exact gap: 366 cases" \
      "covering dev/stg/prod/unset/unknown and not one setting 'staging'," \
      "the alias the chart's own docs recommend." \
      "Fix: add a case to client/tests/ that sets env.CLIENT_ENV: $spelling."
  else
    printf 'ok    CLIENT_ENV=%-12s exercised by %s test case(s)\n' "$spelling" "$n"
  fi
done <<EOF
$sch
EOF

printf '\n'
if [ "$findings" -eq 0 ]; then
  echo "env vocabulary: all four declarations agree, and every accepted spelling is tested."
  exit 0
fi
echo "env vocabulary: $findings finding(s)."
echo "One vocabulary, four languages. Fix the declaration that is wrong -- and if"
echo "you are adding a spelling, add it in all four places and give it a test."
exit 1
