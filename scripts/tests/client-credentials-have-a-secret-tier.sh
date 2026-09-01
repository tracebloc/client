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


# --- the RENAME refusal, same unreachable class (Bugbot, High, on client#911) ---
#
# `fullnameOverride` routes tracebloc.secretName, which is right for an install and
# unsafe for a rename: the lookup above misses under the new name, four credentials
# fall to their randAlphaNum tier and are minted fresh, and the kept MySQL PVC still
# holds the old ones. `helm upgrade` reports deployed and the database refuses every
# login. secrets.yaml refuses that case.
#
# It belongs in THIS file rather than the chart suite for the same structural reason
# as everything above: it is a `lookup`, so helm-unittest renders it away.
#
# THE FIRST VERSION OF THESE ASSERTIONS PINNED THE WRONG DESIGN, and that is worth
# recording because they passed while two thirds of the class was open. They asserted
# the refusal "keys on the UN-OVERRIDDEN name" and called that "the whole correctness
# of it". It was not: `<rel>-secrets` is a PROXY for the lockout, and it missed
# override A -> B (the probe looks for a name that was never live) and override A ->
# none (the `ne` gate makes the body unreachable). Both re-mint against the same kept
# PVC. A test that pins a proxy cements it -- Arturo's re-review of ea6568dc caught
# exactly that, and it is why assertion 4 below now forbids the name key outright.
code_all="$(grep -v '^[[:space:]]*#' "$TPL" 2>/dev/null || true)"

# 1. the refusal exists at all.
if ! grep -qF 'already has MySQL data' <<<"$code_all"; then
  fail "secrets.yaml no longer refuses to re-mint credentials over a live database.
    Any render that resolves to a Secret name the namespace does not have -- adding,
    changing or dropping fullnameOverride, or reinstalling over a kept PVC -- re-mints
    the generated credentials while the retained MySQL PVC holds the old ones:
    upgrade succeeds, database refuses every login."
fi
ok

# 2. it probes the PERSISTED DATA. This is the correctness of it: the MySQL PVC is
#    `mysql-pvc`, a constant that never follows the override and is retained by
#    resource-policy: keep, so its presence is what "there is already a database
#    here" means. Keying on any release-derived NAME instead is what missed two of
#    the three rename directions.
if ! grep -qE 'lookup "v1" "PersistentVolumeClaim" \.Release\.Namespace \(include "tracebloc\.mysqlPvc"' <<<"$code_all"; then
  fail "the refusal no longer probes the MySQL PVC, so it is back to inferring the
    lockout from a name. A name-keyed probe cannot see override A -> override B (it
    looks for a name that was never live) or a dropped override (the names are equal
    and the gate never opens), and both re-mint against retained data."
fi
ok

# 3. it gates on the CURRENT EFFECTIVE Secret being absent, so an ordinary upgrade --
#    PVC and Secret both present -- is never refused. Without this the guard would
#    fire on every upgrade of every release.
if ! grep -qE 'if and \$mysqlDataPresent \(not \$existingSecret\)' <<<"$code_all"; then
  fail "the refusal no longer gates on the current effective Secret being ABSENT, so
    it would fire on ordinary upgrades where nothing is being renamed at all."
fi
ok

# 4. THE OLD PROXY MUST STAY GONE. Re-introducing the name comparison reopens the two
#    directions it could not see, and it would do so while every other assertion here
#    still passed -- which is precisely how ea6568dc shipped looking complete.
if grep -qE '\$unoverriddenSecretName|ne \$secretName' <<<"$code_all"; then
  fail "the refusal is keyed on a release-derived Secret NAME again. That proxy misses
    override A -> override B and a dropped override; the invariant is 'persisted MySQL
    data exists and the Secret under the current effective name does not'."
fi
ok

if [ "$fails" -ne 0 ]; then
  echo "client-credentials-have-a-secret-tier: $fails failure(s) across $checks assertion(s)" >&2
  exit 1
fi
if [ "$checks" -lt 17 ]; then
  echo "client-credentials-have-a-secret-tier: only $checks assertion(s) ran; expected 17+.
  A collapsed run must not report success (rule 3)." >&2
  exit 1
fi
echo "client-credentials-have-a-secret-tier: OK ($checks assertions) — both credentials keep a live-Secret tier, consulted after values and before the hard failure."
