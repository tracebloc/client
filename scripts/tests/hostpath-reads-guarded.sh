#!/usr/bin/env bash
#
#  hostpath-reads-guarded.sh — every read of a `.Values.hostPath` SUBKEY in
#  client/templates goes through `(default dict .Values.hostPath)`, so a render
#  that inherits a nil `hostPath` survives (backend#2910).
#
#  WHY THIS EXISTS, MEASURED. `hostPath` is a map added to values.yaml after the
#  first releases shipped. `helm upgrade --reuse-values` from a release that
#  predates the key carries no `hostPath`, so `.Values.hostPath` is nil at render
#  time. A bare `.Values.hostPath.enabled` then dies with
#  "nil pointer evaluating interface {}.enabled" and kills the WHOLE render —
#  reproduced on develop with:
#
#    helm template t client/ --set hostPath=null \
#      --set storageClass.create=false --set clientId=x --set clientPassword=y
#    Error: client/templates/shared-images-pvc.yaml:3 ... nil pointer ...
#
#  Nine reads across six templates were bare; the chart's own convention at the
#  other sites is `(default dict .Values.hostPath).<key>`, which turns a nil
#  hostPath into an empty dict and reads the subkey as a nil-but-not-a-panic.
#
#  DERIVED, NOT RESTATED (backend#1729 rule 1). This guard holds NO list of the
#  nine files. It greps the tree for the ONE textual signature an unguarded read
#  has and a guarded one cannot: the substring `.Values.hostPath.` — a subkey
#  read where a `.` immediately follows `hostPath`. The guarded form is
#  `(default dict .Values.hostPath).enabled`: a `)` sits between `hostPath` and
#  the `.`, so that substring never appears in it. A bare truthiness test
#  (`.Values.hostPath` with no subkey) is nil-safe and, having no trailing `.`,
#  is likewise not matched. So a template added tomorrow with a new bare read is
#  caught tomorrow, and un-guarding any current site reddens this guard — the
#  mutation test the acceptance asks for, without a path list to keep in sync.
#
#  FAILS CLOSED (backend#1729 rule 3). If the tree the guard reasons about is
#  gone — templates dir moved, or every `.Values.hostPath` reference removed —
#  the offender grep would find nothing and pass VACUOUSLY. So the denominator
#  (any `.Values.hostPath` reference at all) is asserted non-empty first: zero is
#  "I cannot see the code I guard", which is a failure, not agreement.
#
#  SCOPE. Templates only — that is where `.Values` reads render. `hostPath:` in
#  values.yaml / ci values is DATA, not a read, and correctly unmatched. A prose
#  comment that spells the unsafe form `.Values.hostPath.enabled` would trip this;
#  none do today, and a comment advertising the panicking form is worth rewriting
#  anyway.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

DIR="client/templates"
[ -d "$DIR" ] || { echo "FAIL: $DIR not found — cannot check what I cannot read" >&2; exit 1; }

echo "== hostPath subkey reads are guarded =="

# Denominator: every `.Values.hostPath` reference (guarded, bare, or offending).
# grep exits 1 on no-match, and under `errexit`+`pipefail` that aborts the
# `denom=$(…)` assignment BEFORE the count is judged — losing the fail-closed
# diagnostic below (the exit stays 1, but silently). `|| true` on the pipeline
# absorbs the no-match so the explicit count check owns the zero case. Zero
# references means the surface this guard exists for is gone — fail closed
# rather than report green on an empty sweep.
denom=$(grep -rEo '\.Values\.hostPath' "$DIR" | wc -l | tr -d ' ' || true)
if [ "$denom" -eq 0 ]; then
  echo "FAIL: no \`.Values.hostPath\` reference in $DIR at all." >&2
  echo "      Either the templates moved or hostPath handling was removed — this" >&2
  echo "      guard is now blind and must be updated or deleted deliberately, not" >&2
  echo "      left to pass vacuously." >&2
  exit 1
fi

# Offenders: a subkey read where `.` immediately follows `hostPath`. This is the
# unguarded form and ONLY the unguarded form (see header).
offenders=$(grep -rn --fixed-strings '.Values.hostPath.' "$DIR" || true)

if [ -n "$offenders" ]; then
  echo "" >&2
  echo "FAIL: unguarded \`.Values.hostPath.<key>\` read(s) — these nil-pointer and" >&2
  echo "      kill the render under \`helm upgrade --reuse-values\` from a release" >&2
  echo "      predating the hostPath key (backend#2910):" >&2
  printf '%s\n' "$offenders" | sed 's/^/        /' >&2
  echo "" >&2
  echo "      Route each through the chart convention:" >&2
  echo "        .Values.hostPath.enabled   ->   (default dict .Values.hostPath).enabled" >&2
  echo "      (in a ternary/other bool context, append \`| default false\` so the" >&2
  echo "       nil subkey coerces to a bool)." >&2
  exit 1
fi

echo "hostPath subkey reads are guarded: green — $denom \`.Values.hostPath\` reference(s), none unguarded"
