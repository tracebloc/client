#!/usr/bin/env bash
#
# gen-envelope-embed.sh — re-embed the envelope contract constants into the two
# installers from the vendored contract (backend#2220, RFC-BACKEND-664 §P0).
#
# The contract's arithmetic lives in ONE place, client-runtime's
# node_sizing.envelope_from_allocatable, and its constants in
# client-runtime/envelope_contract.json. Neither installer can call it — bash
# has no guaranteed JSON parser and the bootstrap is signed, so it must not
# fetch anything unsigned at install time — so the constants are embedded and
# the embed is drift-guarded, the same trade the GPU node-image build inputs
# already make (#616/#633).
#
# Usage:
#   scripts/gen-envelope-embed.sh              # re-embed from the vendored fixture
#   scripts/gen-envelope-embed.sh --check      # verify, change nothing (CI)
#
# To adopt an upstream contract change: bump scripts/.client-runtime-ref,
# re-vendor scripts/tests/fixtures/envelope_contract.json from that ref, then
# run this script and commit all three.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTRACT="scripts/tests/fixtures/envelope_contract.json"
BASH_FILE="scripts/lib/install-client-helm.sh"
PS1_FILE="scripts/install-k8s.ps1"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

[[ -f "$CONTRACT" ]] || { echo "[ERROR] $CONTRACT is missing" >&2; exit 1; }

# Read the five values. python3 is a build/CI-time dependency only — it is
# NEVER required on a customer machine at install time, which is the whole
# reason the values get embedded rather than parsed live.
command -v python3 >/dev/null 2>&1 || {
  echo "[ERROR] python3 is required to regenerate the embed" >&2
  exit 1
}

read -r VERSION OVER_CPU OVER_MEM FLOOR_CPU FLOOR_MEM < <(python3 - "$CONTRACT" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
o, f = c["overhead"], c["floor"]
vals = [
    c["contract_version"],
    o["cpu_millicores"], o["memory_bytes"],
    f["cpu_millicores"], f["memory_bytes"],
]
for v in vals:
    if not isinstance(v, int) or v < 0:
        raise SystemExit(f"contract value is not a non-negative int: {v!r}")
print(*vals)
PY
)

_fail=0

# Read, compare and (unless --check) rewrite ONE `<prefix><NAME> = <digits>`
# assignment. The whole job is done in python3 against a LITERAL key, on purpose.
#
# It used to grep here and rewrite there, which meant one string had to be both
# an ERE pattern and a Python literal: the PowerShell prefix was passed with a
# leading backslash so grep would read the dollar as literal, and that same
# backslash then reached re.escape(), which searched for a backslash-dollar that
# is nowhere in install-k8s.ps1. --check still passed (grep was fine), so the
# gate looked healthy while the documented adopt path was broken: a real regen
# rewrote the bash installer, then died on the first PowerShell constant and
# left the two embeds disagreeing. Found by Bugbot on #766.
#
# One escaping domain now, and the mutating path is covered by a bats test that
# actually adopts a changed contract — the check-only tests could not have
# caught this, which is the real lesson.
#
# Exit codes: 0 = already correct or rewritten, 2 = no such assignment,
# 3 = present but wrong (only under --check).
_set() {
  local file="$1" prefix="$2" name="$3" want="$4" rc=0 out
  out="$(CHECK="$CHECK" python3 - "$file" "${prefix}${name}" "$want" <<'PY'
import os
import re
import sys

path, key, want = sys.argv[1], sys.argv[2], sys.argv[3]
check = os.environ.get("CHECK") == "1"

with open(path, encoding="utf-8") as handle:
    src = handle.read()

# Anchored on the whole line so a value appearing elsewhere is untouched, and
# tolerant of the aligned `=` the PowerShell block uses for readability.
pattern = re.compile(rf"^({re.escape(key)}[ \t]*=[ \t]*)(\S+)$", re.MULTILINE)
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
    0)
      # Already correct, or rewritten in place. The run's closing line reports
      # which of the two happened; a per-constant echo just adds noise.
      return 0
      ;;
    2)
      echo "[ERROR] $file has no ${prefix}${name} assignment to embed into" >&2
      _fail=1
      ;;
    3)
      echo "EMBED DRIFT: $file ${prefix}${name} = ${out}, contract says $want" >&2
      _fail=1
      ;;
    *)
      echo "[ERROR] failed to embed ${prefix}${name} into $file" >&2
      _fail=1
      ;;
  esac
}

_set "$BASH_FILE" "_TB_ENVELOPE_" "CONTRACT_VERSION"    "$VERSION"
_set "$BASH_FILE" "_TB_ENVELOPE_" "OVERHEAD_CPU_MILLI"  "$OVER_CPU"
_set "$BASH_FILE" "_TB_ENVELOPE_" "OVERHEAD_MEM_BYTES"  "$OVER_MEM"
_set "$BASH_FILE" "_TB_ENVELOPE_" "FLOOR_CPU_MILLI"     "$FLOOR_CPU"
_set "$BASH_FILE" "_TB_ENVELOPE_" "FLOOR_MEM_BYTES"     "$FLOOR_MEM"

_set "$PS1_FILE" '$script:TbEnvelope' "ContractVersion"   "$VERSION"
_set "$PS1_FILE" '$script:TbEnvelope' "OverheadCpuMilli"  "$OVER_CPU"
_set "$PS1_FILE" '$script:TbEnvelope' "OverheadMemBytes"  "$OVER_MEM"
_set "$PS1_FILE" '$script:TbEnvelope' "FloorCpuMilli"     "$FLOOR_CPU"
_set "$PS1_FILE" '$script:TbEnvelope' "FloorMemBytes"     "$FLOOR_MEM"

# ── the golden-vector table for the bats suite ───────────────────────────────
#
# bats has no guaranteed jq either, so the contract's vectors are flattened into
# a sourceable bash array. Each row is:
#
#     <label>|<allocatable_cpu>|<allocatable_memory>|<expected installer output>
#
# where the expected output is what _machine_training_resources must PRINT —
# "cpu=N,memory=MGi" for a viable machine, and the empty string for a machine
# below the contract floor or with unparseable allocatable (the installer emits
# nothing and the caller falls back).
VECTORS="scripts/tests/fixtures/envelope_vectors.bash"

_emit_vectors() {
  python3 - "$CONTRACT" <<'PY'
import json, sys

contract = json.load(open(sys.argv[1]))


def installer_output(expected):
    """What the installer prints for this case: viable -> the pair, else ""."""
    if expected is None or not expected["viable"]:
        return ""
    r = expected["render_gi"]
    return f"cpu={r['cpu']},memory={r['memory']}"


print("# GENERATED by scripts/gen-envelope-embed.sh — do not hand-edit.")
print("# Golden vectors from client-runtime/envelope_contract.json")
print(f"# (contract v{contract['contract_version']}, "
      f"pin: scripts/.client-runtime-ref).")
print("#")
print("# <label>|<allocatable cpu>|<allocatable memory>|<expected output>")
print("TB_ENVELOPE_VECTORS=(")
for v in contract["vectors"]["single_node"]:
    print(f'  "{v["label"]}|{v["allocatable_cpu"]}|'
          f'{v["allocatable_memory"]}|{installer_output(v["expected"])}"')
print(")")
print()
print("# Multi-node cases pin the ANCHOR_LARGEST selection rule — the part that")
print("# was never written down. Rows are:")
print("#   <label>|<node lines, newline-escaped as \\n>|<expected output>")
print("TB_ENVELOPE_ANCHOR_VECTORS=(")
for v in contract["vectors"]["multi_node"]:
    live = [n for n in v["nodes"] if not n.get("unschedulable")]
    if not live:
        continue
    lines = "\\n".join(f"{n['cpu']} {n['memory']}" for n in live)
    largest = v["anchored"]["largest"]
    print(f'  "{v["label"]}|{lines}|{installer_output(largest["expected"])}"')
print(")")
PY
}

if (( CHECK )); then
  if [[ ! -f "$VECTORS" ]]; then
    echo "EMBED DRIFT: $VECTORS is missing" >&2
    _fail=1
  elif ! diff -u "$VECTORS" <(_emit_vectors) >/dev/null; then
    echo "EMBED DRIFT: $VECTORS no longer matches the contract's vectors" >&2
    diff -u "$VECTORS" <(_emit_vectors) | head -30 >&2 || true
    _fail=1
  fi
else
  _emit_vectors > "$VECTORS"
  echo "  regenerated $VECTORS"
fi

if (( _fail )); then
  if (( CHECK )); then
    echo "" >&2
    echo "Run scripts/gen-envelope-embed.sh to re-embed, then regenerate" >&2
    echo "scripts/manifest.sha256 (scripts/gen-manifest.sh)." >&2
  fi
  exit 1
fi

if (( CHECK )); then
  echo "envelope embed matches $CONTRACT (contract v$VERSION)"
else
  echo "envelope embed regenerated from $CONTRACT (contract v$VERSION)"
fi
