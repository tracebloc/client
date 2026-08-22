#!/usr/bin/env bash
#
#  node-jsonpath-agreement.sh — the two installers ASK the API server for the
#  same node fields, and one of them is spec.unschedulable (backend#2237).
#
#  WHY THIS EXISTS. The envelope sizing skips cordoned nodes, and both twins
#  implement that skip. Every test of that skip mocks `kubectl` and injects the
#  node lines directly:
#
#    bats   — kubectl() { printf '16 64Gi true\n4 16Gi \n'; }
#    Pester — Mock kubectl { @("16 64Gi true", "4 16Gi ") }
#
#  So the tests exercise the PARSER and never the QUERY. Revert either jsonpath
#  to the two-field form it had before backend#2237 and the field simply stops
#  arriving: `unsched` is empty for every node, the skip never fires, a cordoned
#  node takes the anchor again -- and the whole mocked suite stays GREEN, because
#  the mocks go on supplying a field the real query no longer requests.
#
#  Measured, not assumed. With both jsonpaths reverted and both skips left in
#  place, installer-parity.bats, installer-parity.Tests.ps1 and the ANCHOR_LARGEST
#  replay all passed. That is the backend#1729 shape exactly: a mechanism that
#  looks like it verifies the cordon rule while being disconnected from the half
#  that fetches the data. This guard is the connection.
#
#  DERIVED, NOT RESTATED. No jsonpath is written down here. Both are PARSED out
#  of the installers and compared to each other. The bash and PowerShell twins
#  genuinely cannot share code -- one is a sourced bash lib, the other a signed
#  standalone PowerShell bootstrap that must not fetch anything at install time
#  -- so the string is unavoidably written twice. What is NOT unavoidable is the
#  two copies drifting: this makes byte-identity a machine check rather than a
#  comment asking reviewers to look.
#
#  FAILS CLOSED. A jsonpath that cannot be found in either file is a FINDING, not
#  a pass. Two absences compare equal, and "I could not read the declaration" must
#  never be reported as "the declarations agree".
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

BASH_SRC="scripts/lib/install-client-helm.sh"
PS1_SRC="scripts/install-k8s.ps1"

echo "== node jsonpath agreement =="

fail=0

for f in "$BASH_SRC" "$PS1_SRC"; do
  [[ -f "$f" ]] || { echo "[ERROR] $f is missing -- cannot compare" >&2; exit 1; }
done

# Pull the node-sizing jsonpath out of each installer. Anchored on the
# distinctive '{range .items[*]}{.status.allocatable.cpu}' opening so the GPU
# probes -- which query allocatable."nvidia.com/gpu" and are a different
# question -- cannot be picked up by accident.
#
# Capture-then-slice rather than `grep ... | head -1`: piping into an
# early-closing reader under this file's `set -euo pipefail` aborts the guard on
# SIGPIPE, which scripts/tests/pipefail-early-close.bats forbids tree-wide. (It
# caught this line on the first full run -- the house idiom is the pure-bash
# first-line slice below.)
_extract() {
  local all=""
  all="$(grep -oE "\{range \.items\[\*\]\}\{\.status\.allocatable\.cpu\}[^']*" "$1")" || true
  printf '%s' "${all%%$'\n'*}"
}

BASH_JP="$(_extract "$BASH_SRC")"
PS1_JP="$(_extract "$PS1_SRC")"

if [[ -z "$BASH_JP" ]]; then
  echo "[FAIL] no node-sizing jsonpath found in $BASH_SRC" >&2
  echo "       Expected a '{range .items[*]}{.status.allocatable.cpu}...' template." >&2
  echo "       If it moved or changed shape, FIX THIS GUARD -- an unreadable" >&2
  echo "       declaration must not be reported as agreement." >&2
  fail=1
fi
if [[ -z "$PS1_JP" ]]; then
  echo "[FAIL] no node-sizing jsonpath found in $PS1_SRC" >&2
  echo "       Expected a '{range .items[*]}{.status.allocatable.cpu}...' template." >&2
  fail=1
fi

if (( fail )); then
  echo "" >&2
  echo "node jsonpath agreement: FAILED (could not read one or both declarations)" >&2
  exit 1
fi

echo "  bash: $BASH_JP"
echo "  ps1 : $PS1_JP"

# 1. The two installers must ask for exactly the same thing.
if [[ "$BASH_JP" != "$PS1_JP" ]]; then
  echo "" >&2
  echo "[FAIL] the two installers request DIFFERENT node fields." >&2
  echo "       $BASH_SRC:" >&2
  echo "         $BASH_JP" >&2
  echo "       $PS1_SRC:" >&2
  echo "         $PS1_JP" >&2
  echo "" >&2
  echo "       They size the same machine and must measure it identically." >&2
  echo "       backend#2220 shipped five twin divergences found one at a time;" >&2
  echo "       this is the cheap end of that class." >&2
  fail=1
fi

# 2. Both must request spec.unschedulable, or the cordon skip is dead code and
#    the contract's skipped_nodes rule is unenforceable at runtime.
for pair in "$BASH_SRC|$BASH_JP" "$PS1_SRC|$PS1_JP"; do
  src="${pair%%|*}"
  jp="${pair#*|}"
  case "$jp" in
    *'{.spec.unschedulable}'*) ;;
    *)
      echo "" >&2
      echo "[FAIL] $src does not request {.spec.unschedulable}." >&2
      echo "       envelope_contract.json's skipped_nodes declares" >&2
      echo "         \"spec.unschedulable (cordoned)\"" >&2
      echo "       a node the sizing SKIPS. Without the field in the jsonpath the" >&2
      echo "       skip can never fire: a cordoned node takes the anchor and the" >&2
      echo "       installer writes an envelope that cannot schedule, leaving" >&2
      echo "       training pods Pending with no obvious cause (backend#2237)." >&2
      echo "" >&2
      echo "       NOTE the mocked suites CANNOT catch this -- they inject node" >&2
      echo "       lines directly, so they keep supplying a field the real query" >&2
      echo "       stopped asking for. That is why this guard exists." >&2
      fail=1
      ;;
  esac
done

if (( fail )); then
  echo "" >&2
  echo "node jsonpath agreement: FAILED" >&2
  exit 1
fi

echo "node jsonpath agreement: both installers request identical node fields, including spec.unschedulable"
