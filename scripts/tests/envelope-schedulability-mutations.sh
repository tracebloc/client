#!/usr/bin/env bash
#
#  envelope-schedulability-mutations.sh — proves envelope-schedulability.sh
#  actually catches the defects it was written for (backend#2870).
#
#  Rule 5: break the thing, watch the guard redden, restore. Rule 9: every case
#  copies the real tree into a fixture dir, mutates the COPY, and drives the REAL
#  guard via TB_SCHED_ROOT -- which in turn sources the REAL (mutated) installer
#  functions. Nothing here re-implements the fit rule; the oracle is the guard.
#
#  ANCHORS ARE ASSERTED APPLIED. A mutation whose anchor no longer matches
#  exactly once is a hard failure, not a skip: an inert mutation and real
#  coverage look identical in a log, which is the whole shape backend#1729
#  catalogued. The embed anchor below is the current literal on purpose -- a
#  re-embed after a chart change moves it, and this file must be re-aimed in the
#  same PR (BUGBOT.md: "a number changed without its consumers").
#
#  The fixture tree is a COPY, so a case that would corrupt an installer cannot.
#  Read-only with respect to the repo.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$here/../.." && pwd)"
GUARD="$SRC/scripts/tests/envelope-schedulability.sh"

[ -r "$GUARD" ] || { printf 'ERROR: cannot read %s\n' "$GUARD" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'ERROR: python3 is required to apply mutations\n' >&2; exit 2; }
command -v helm >/dev/null 2>&1 || { printf 'ERROR: helm is required (the guard renders the chart)\n' >&2; exit 2; }

pass=0; fail=0

# want: expected exit status. 0 clean, 1 violation, 2 cannot tell.
run_case() {
  local label="$1" file="$2" old="$3" new="$4" want="$5"
  local td; td="$(mktemp -d "${TMPDIR:-/tmp}/sched-mut-XXXXXX")" || { printf 'ERROR: mktemp\n' >&2; exit 2; }
  mkdir -p "$td/scripts/tests/fixtures"
  cp -R "$SRC/scripts/lib" "$td/scripts/lib"
  cp -R "$SRC/client" "$td/client"
  cp "$SRC/scripts/tests/control-plane-footprint.sh" "$td/scripts/tests/"
  cp "$SRC/scripts/tests/fixtures/envelope_vectors.bash" "$td/scripts/tests/fixtures/"

  if [ -n "$file" ]; then
    local target="$td/$file" n
    # COUNTED IN PYTHON, not `grep -cF`: grep counts matching LINES, and a
    # multi-line anchor would report more than the real occurrence count.
    n="$(TB_M_TARGET="$target" TB_M_OLD="$old" python3 -c 'import os;print(open(os.environ["TB_M_TARGET"],encoding="utf-8").read().count(os.environ["TB_M_OLD"]))' 2>/dev/null)" || n=0
    if [ "$n" -ne 1 ]; then
      printf '  %-62s ANCHOR MATCHED %sx (INERT MUTATION)\n' "$label" "$n"
      fail=$((fail + 1)); rm -rf "$td"; return
    fi
    TB_M_TARGET="$target" TB_M_OLD="$old" TB_M_NEW="$new" python3 - <<'PY'
import os
p, o, n = os.environ["TB_M_TARGET"], os.environ["TB_M_OLD"], os.environ["TB_M_NEW"]
s = open(p, encoding="utf-8").read()
assert s.count(o) == 1, "anchor drifted between check and write"
open(p, "w", encoding="utf-8").write(s.replace(o, n, 1))
PY
  fi

  TB_SCHED_ROOT="$td" bash "$GUARD" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq "$want" ]; then
    printf '  %-62s rc=%s (want %s)  caught\n' "$label" "$rc" "$want"; pass=$((pass + 1))
  else
    printf '  %-62s rc=%s (want %s)  VACUOUS\n' "$label" "$rc" "$want"; fail=$((fail + 1))
  fi
  rm -rf "$td"
}

LIB="scripts/lib/install-client-helm.sh"

printf 'baseline — an unmutated copy of the real tree must be clean:\n'
run_case "unmutated tree" "" "" "" 0

printf '\nthe fit arithmetic:\n'
run_case "footprint term dropped (the 8 GiB case passes silently)" "$LIB" \
  '  local need_mem_b=$(( fp_mem_b + sys_mem_b ))' \
  '  local need_mem_b=$(( sys_mem_b ))' 1
run_case "cpu dimension never fails (DoD part 5 uncovered)" "$LIB" \
  '  (( cpu_over <= 0 )) && cpu_fits=1' \
  '  cpu_fits=1' 1
run_case "reduction computed but never written" "$LIB" \
  '  _TB_TRAINING_SIZE="cpu=${new_cores},memory=${new_gib}Gi"' \
  '  : "cpu=${new_cores},memory=${new_gib}Gi"' 1
run_case "refusal downgraded: a 0-core envelope gets written" "$LIB" \
  '  if (( new_cores < 1 || new_gib < 1 )); then' \
  '  if false; then' 1

printf '\nwhose choice it is:\n'
run_case "a human pin gets reduced like an installer choice" "$LIB" \
  '  [[ "$prov" == "installer" ]] && ours=1' \
  '  ours=1' 1

printf '\nthe measured system pods:\n'
run_case "release-owned namespaces counted (control plane twice)" "$LIB" \
  '    case " $own_ns " in *" $ns "*) continue ;; esac' \
  '    :' 1
run_case "terminal pods counted as resident" "$LIB" \
  '    case "$phase" in Succeeded|Failed) continue ;; esac' \
  '    :' 1

printf '\nfail closed:\n'
run_case "blank footprint constant no longer refuses" "$LIB" \
  '  if [[ ! "${_TB_CP_FOOTPRINT_MEM_BYTES:-}" =~ ^[0-9]+$ || ! "${_TB_CP_FOOTPRINT_CPU_MILLI:-}" =~ ^[0-9]+$ ]]; then' \
  '  if false; then' 1
run_case "unreadable cluster writes a carried non-floor size" "$LIB" \
  '    if (( ours )) && [[ "$size" != "$_TRAINING_DEFAULT" ]]; then' \
  '    if false; then' 1

printf '\nthe embed:\n'
run_case "embedded footprint drifts from the render" "$LIB" \
  '_TB_CP_FOOTPRINT_MEM_BYTES=3288334336' \
  '_TB_CP_FOOTPRINT_MEM_BYTES=3221225472' 1

printf '\n%s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  echo "envelope-schedulability-mutations: FAILED -- a surviving mutation is a defect in the guard, not a nuisance" >&2
  exit 1
fi
echo "envelope-schedulability-mutations: OK -- every mutation reddened the guard"
