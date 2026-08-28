#!/usr/bin/env bash
#
#  client-credentials-have-a-secret-tier.sh — the tier the chart tests cannot
#  reach must not be silently deleted (backend#2571).
#
#  WHY A SOURCE GUARD AND NOT A CHART TEST. `clientId`/`clientPassword` resolve
#  three ways: explicit values, then the live Secret, then fail. The chart suite
#  covers tier 1 and tier 3 -- `client/tests/secrets_test.yaml` has
#  "resolves both credentials from values (tier 1)" and "fails when clientId
#  resolves from neither values nor an existing Secret".
#
#  It CANNOT cover tier 2, and that is structural rather than an oversight:
#  `lookup` returns an empty dict under `helm template`, which is how
#  helm-unittest renders. So the ONE tier this whole change exists for -- the
#  one that lets a credential stop entering release values -- is the one no
#  behavioural test in this repo can exercise. Deleting the `else if
#  $secretClientId` branch would leave 596 chart tests green and quietly return
#  every install to values-only.
#
#  "We cannot test it" is therefore not a reason to leave it unguarded; it is the
#  reason to pin the mechanism and say so out loud (CLAUDE.md rule 3, and rule 7:
#  the docstring in secrets.yaml claims a 3-tier resolution, so that claim should
#  be a machine check).
#
#  WHAT IS CHECKED, derived from the template rather than restated:
#    1. both credentials read the looked-up Secret at all;
#    2. both have a values-tier that is consulted BEFORE the Secret tier, so a
#       deliberate re-point still wins;
#    3. both still FAIL rather than defaulting -- these are backend-issued, so a
#       generated value would lock the minter out;
#    4. the Secret tier tests the DECODED VALUE, not merely key presence. `hasKey`
#       alone accepts `CLIENT_ID: ""`, and `minLength: 1` had to leave
#       values.schema.json for lookup to run at all, so this template is the only
#       layer left that can refuse an empty credential (Bugbot on #859).
#
#  FAILS CLOSED: an unreadable template, or a credential whose chain cannot be
#  found, is a FAILURE.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TPL="$ROOT/client/templates/secrets.yaml"

[ -r "$TPL" ] || { echo "FAIL: $TPL unreadable -- cannot tell, which is a finding" >&2; exit 1; }

# Comment-stripped: this template carries long explanatory blocks naming every
# branch below, so a raw scan would be satisfied by the prose that documents the
# mechanism rather than by the mechanism. Go templates comment with {{- /* ... */ -}},
# so the whole block is removed, not just single lines.
code=$(python3 - "$TPL" <<'PY'
import re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
# Drop every {{ /* ... */ }} block, however it is whitespace-trimmed.
print(re.sub(r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", "", raw, flags=re.S))
PY
)

[ -n "$code" ] || { echo "FAIL: stripping comments left nothing -- refusing to report agreement on an empty file" >&2; exit 1; }

fails=0
checks=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { checks=$((checks + 1)); }

# 0. THE LOOKUP ITSELF (Bugbot, client#891). Every per-credential check below
#    reads the DECODED value out of $existingSecret, and none of them requires
#    $existingSecret to have come from a live cluster read. Replacing the
#    `lookup` with `dict` -- or any empty stand-in -- left all 12 assertions
#    green and helm-unittest unchanged, because `lookup` is already empty under
#    `helm template`. That returns every install to values-only, which is the
#    one defect this whole guard exists to catch.
if ! grep -qE '\$existingSecret[[:space:]]*:?=[[:space:]]*\(?[[:space:]]*lookup "v1" "Secret"' <<<"$code"; then
  fail "\$existingSecret is no longer assigned from (lookup \"v1\" \"Secret\" ...),
    so the Secret tier reads out of something that is never populated from the
    cluster and every install silently falls back to values-only. No chart test
    can see this: \`lookup\` returns empty under \`helm template\` either way."
fi
ok

for cred in clientId clientPassword; do
  case "$cred" in
    clientId)       key="CLIENT_ID";       var='\$secretClientId' ;;
    clientPassword) key="CLIENT_PASSWORD"; var='\$secretClientPassword' ;;
  esac

  # 1. the Secret is read at all
  if ! grep -qE "index .*\"$key\".*b64dec" <<<"$code"; then
    fail "$cred no longer reads $key out of the looked-up Secret, so tier 2 is
      gone and every install is values-only again. No chart test can catch this:
      \`lookup\` is empty under \`helm template\`."
  fi
  ok

  # 4. the DECODED value decides, not key presence.
  #    Captured ONCE and reused by the order check below (@saqlainsyed007,
  #    client#891): existence and position are the same fact read twice, and a
  #    second grep of the same pattern can drift from the first.
  secret_hits=$(grep -nE "else if $var" <<<"$code" || true)
  if [ -z "$secret_hits" ]; then
    fail "$cred does not fall back to $var, so the looked-up value is read but
      never used"
  fi
  ok

  # 2. values first, Secret second -- order matters, so compare positions
  # CAPTURE THEN SLICE, never `| head -1 | cut` (Bugbot, client#891). Under
  # `set -euo pipefail` an early-closing `head` SIGPIPEs `grep`, and the `|| true`
  # that suppresses the 141 collapses it into the same empty string a real
  # no-match produces -- so the order check below either aborts the gate or
  # fail-closes on a live match, indistinguishably. The shared `early-close` job
  # forbids this shape tree-wide; the sibling guards already capture-then-slice.
  values_hits=$(grep -nE "if \.Values\.$cred" <<<"$code" || true)
  values_line=${values_hits%%:*}
  secret_line=${secret_hits%%:*}
  if [ -z "$values_line" ] || [ -z "$secret_line" ]; then
    fail "$cred: could not locate both tiers (values at '${values_line:-none}',
      Secret at '${secret_line:-none}') -- refusing to assume the order is right"
  elif [ "$values_line" -ge "$secret_line" ]; then
    fail "$cred consults the Secret before .Values.$cred, so an operator
      deliberately re-pointing at a different registered client would be
      overridden by the stored value"
  fi
  ok

  # 3. still fails rather than generating, and NOT MERELY that the string is
  #    present. An earlier version grepped for the `fail` text alone, and a
  #    mutation that added `$clientId = randAlphaNum 16` while leaving the `fail`
  #    unreachable behind `{{- if false -}}` slipped straight past it. So the rule
  #    is the one that actually matters: this credential must never be ASSIGNED a
  #    generated value.
  if ! grep -qE "fail \"$cred is required" <<<"$code"; then
    fail "$cred no longer fails when unresolvable"
  fi
  ok
  # BOTH ASSIGNMENT FORMS, AND A PARENTHESISED RHS (Bugbot, client#891). This
  # file declares with `:=` two lines above and assigns with `=`, and other
  # assignments in secrets.yaml wrap the right-hand side in parentheses -- so a
  # bare `=` with an unparenthesised RHS was blind to `$clientId := randAlphaNum 16`
  # and to `$clientId = (randAlphaNum 16)`, which is the exact evasion this rule
  # was rewritten to catch.
  if grep -qE "\\\$${cred}[[:space:]]*:?=[[:space:]]*\\(?[[:space:]]*(randAlphaNum|randAlpha|randNumeric|randAscii|uuidv4|derivePassword)" <<<"$code"; then
    fail "$cred is assigned a GENERATED value somewhere. These are
      BACKEND-ISSUED: a value the platform was never told to expect authenticates
      as nobody and locks the minter out -- which is why this is the one
      credential in this file with no randAlphaNum tier."
  fi
  ok

  # 5. the Secret tier guards on key PRESENCE for this credential specifically.
  #    Checked per credential: a single repo-wide grep for `hasKey` passed while
  #    one of the two had lost its guard, because the other still had one.
  if ! grep -qE "hasKey \\\$existingSecret\.data \"$key\"" <<<"$code"; then
    fail "$cred's Secret tier no longer guards on hasKey for $key, so a Secret
      lacking that key would index to nil rather than falling through to tier 3"
  fi
  ok
done


if [ "$fails" -ne 0 ]; then
  echo "client-credentials-have-a-secret-tier: $fails failure(s) across $checks assertion(s)" >&2
  exit 1
fi
if [ "$checks" -lt 13 ]; then
  echo "client-credentials-have-a-secret-tier: only $checks assertion(s) ran; expected 13+.
  A collapsed run must not report success (rule 3)." >&2
  exit 1
fi
echo "client-credentials-have-a-secret-tier: OK ($checks assertions) — both credentials keep a live-Secret tier, consulted after values and before the hard failure."
