#!/usr/bin/env bash
#
# gen-footprint-embed.sh — embed the chart's own control-plane footprint into the
# bash installer, derived from the render (backend#2870, DoD part 1).
#
# The installer checks the training envelope it is about to write against
# `allocatable - (chart footprint + measured system pods)`. The chart footprint
# is what `helm template` says the steady-state control plane requests, summed
# by scripts/tests/control-plane-footprint.sh. The installer cannot run that at
# install time -- it guarantees neither jq nor python3, and the bootstrap is
# signed -- so the pair is embedded as two constants, exactly as the envelope
# contract constants are (scripts/gen-envelope-embed.sh), and drift-guarded:
# `--check` runs in `make drift` (the required Source-of-truth drift job) and
# reddens the moment a chart change moves the render away from the embed.
#
# Usage:
#   scripts/gen-footprint-embed.sh              # re-embed from a fresh render
#   scripts/gen-footprint-embed.sh --check      # verify, change nothing (CI)
#
# After a re-embed, regenerate scripts/manifest.sha256 (scripts/gen-manifest.sh):
# install-client-helm.sh is bootstrap-fetched and its digest is pinned there.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

GUARD="scripts/tests/control-plane-footprint.sh"
BASH_FILE="scripts/lib/install-client-helm.sh"

CHECK=0
case "${1:-}" in
  '') ;;
  --check) CHECK=1 ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

[[ -f "$GUARD" ]] || { echo "[ERROR] $GUARD is missing -- nothing to derive the footprint from" >&2; exit 1; }
[[ -f "$BASH_FILE" ]] || { echo "[ERROR] $BASH_FILE is missing -- nothing to embed into" >&2; exit 1; }
# helm + python3 are build/CI-time dependencies only -- NEVER required on a
# customer machine, which is the whole reason the pair is embedded. The guard
# checks for both and refuses by name; we only need python3 for the rewrite.
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 is required to (re)embed the footprint" >&2; exit 1; }

# DERIVE. Capture-then-read: a guard that refuses (a breached ratchet, no helm,
# a failed render) prints nothing on stdout and exits non-zero, and that must
# be a refusal here too -- never an empty pair read as zero.
errf="$(mktemp "${TMPDIR:-/tmp}/footprint-embed.XXXXXX")"
if ! out="$(bash "$GUARD" --print-footprint 2>"$errf")"; then
  echo "[ERROR] could not derive the footprint: $(tail -1 "$errf" 2>/dev/null)" >&2
  rm -f "$errf"
  exit 1
fi
rm -f "$errf"
read -r MEM_MIB CPU_MILLI _ <<< "$out"
if [[ ! "${MEM_MIB:-}" =~ ^[0-9]+$ || ! "${CPU_MILLI:-}" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] the footprint guard printed '$out', not '<mem MiB> <cpu m>'" >&2
  exit 1
fi
MEM_BYTES=$(( MEM_MIB * 1024 * 1024 ))

_fail=0

# Read, compare and (unless --check) rewrite ONE `<NAME>=<digits>` assignment,
# anchored on the whole line. The same shape as gen-envelope-embed.sh's _set, for
# the same reason it does the whole job in python3 against a literal key: one
# escaping domain, so the string is never both an ERE and a Python literal.
# Exit codes: 0 = already correct or rewritten, 2 = no such assignment,
# 3 = present but wrong (only under --check).
_set() {
  local file="$1" key="$2" want="$3" rc=0 out
  out="$(CHECK="$CHECK" python3 - "$file" "$key" "$want" <<'PY'
import os
import re
import sys

path, key, want = sys.argv[1], sys.argv[2], sys.argv[3]
check = os.environ.get("CHECK") == "1"

with open(path, encoding="utf-8") as handle:
    src = handle.read()

pattern = re.compile(rf"^({re.escape(key)}=)(\S+)$", re.MULTILINE)
match = pattern.search(src)
if match is None:
    sys.exit(2)
if match.group(2) == want:
    sys.exit(0)
if check:
    print(match.group(2))
    sys.exit(3)

new, n = pattern.subn(rf"\g<1>{want}", src, count=1)
if n != 1:
    print(f"expected exactly one {key} assignment, replaced {n}", file=sys.stderr)
    sys.exit(1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(new)
PY
  )" || rc=$?

  case "$rc" in
    0) return 0 ;;
    2) echo "[ERROR] $file has no ${key} assignment to embed into" >&2; _fail=1 ;;
    3) echo "EMBED DRIFT: $file ${key}=${out}, the chart renders ${want}" >&2; _fail=1 ;;
    *) echo "[ERROR] failed to embed ${key} into $file" >&2; _fail=1 ;;
  esac
}

_set "$BASH_FILE" "_TB_CP_FOOTPRINT_MEM_BYTES" "$MEM_BYTES"
_set "$BASH_FILE" "_TB_CP_FOOTPRINT_CPU_MILLI" "$CPU_MILLI"

if (( _fail )); then
  if (( CHECK )); then
    echo "" >&2
    echo "The chart's control-plane footprint moved. Run scripts/gen-footprint-embed.sh" >&2
    echo "to re-embed, then scripts/gen-manifest.sh, and commit both -- and weigh what" >&2
    echo "the change costs the training envelope on every edge (backend#2870)." >&2
  fi
  exit 1
fi

if (( CHECK )); then
  echo "footprint embed matches the chart render (${MEM_MIB} MiB / ${CPU_MILLI} m)"
else
  echo "footprint embed regenerated from the chart render (${MEM_MIB} MiB / ${CPU_MILLI} m)"
fi
