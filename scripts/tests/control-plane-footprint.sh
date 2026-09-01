#!/usr/bin/env bash
#
#  control-plane-footprint.sh — how much memory and CPU the chart's own control
#  plane REQUESTS, summed from the rendered chart, ratcheted so it cannot grow
#  worse without a conscious decision (backend#2870, part of RFC-BACKEND-664).
#
#  WHY THIS EXISTS
#  ---------------
#  A training pod is sized `node_allocatable − overhead`, where `overhead` is a
#  single embedded constant (`_TB_ENVELOPE_OVERHEAD_MEM_BYTES`, 3 GiB) meant to
#  stand in for everything that is NOT the training pod: kubelet, the runtime,
#  and this chart's control plane. backend#2870's finding is that NOTHING sums
#  what the control plane actually requests, so nobody can tell whether that one
#  constant still covers it. Grep the three consumers for `3008`, `platform
#  footprint`, `control plane requests`: zero hits. The number was invisible.
#
#  Measured here by rendering the chart: the steady-state control plane requests
#  ~3136 MiB, already ABOVE the 3 GiB (3072 MiB) the envelope reserves for it.
#  That 64 MiB overshoot is the memory half of the reason a training pod on a
#  freshly-installed single-node edge can sit `Pending / Insufficient memory`
#  (backend#2870). CPU fits: 900m requested against a 1000m reserve.
#
#  WHAT THIS GUARD DOES, AND DELIBERATELY DOES NOT
#  -----------------------------------------------
#  It does NOT assert schedulability (`footprint <= overhead`). That assertion is
#  RED today by construction, and making it green needs measured, per-platform
#  kubelet reservations (backend#2460) and/or a control-plane request trim under
#  load (backend#2461) -- both empirical campaigns, neither a code change. Landing
#  a red gate would train people to skip the tier (org rule 4).
#
#  It RATCHETS instead: the footprint may not grow past the recorded ceiling. A
#  chart change that adds a component or raises a request -- making an already
#  tight fit worse, silently, on every edge -- reddens here and forces the author
#  to see the schedulability cost and bump the ceiling on purpose. It also REPORTS
#  the current gap against the reserve, so the number backend#2460/#2461 must
#  close is tracked rather than rediscovered.
#
#  IT DERIVES, IT DOES NOT RESTATE (backend#1729). The footprint is summed from
#  `helm template`, the ground truth of what installs; the reserve is parsed from
#  the installer's own embedded constant, not a second copy. The only written-down
#  numbers are the ratchet ceilings, and a ceiling is a bound to hold under, not a
#  restatement of the render -- raising a request is what moves it.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TB_CP_FOOTPRINT_ROOT lets this guard's own test point it at a fixture tree.
root="${TB_CP_FOOTPRINT_ROOT:-$(cd "$here/../.." && pwd)}"
chart="$root/client"
installer="$root/scripts/lib/install-client-helm.sh"

# THE RATCHET CEILINGS. Current measured steady-state control-plane requests,
# consistent across every client/ci/*-values.yaml profile (2026-09-01). A change
# that pushes the footprint above either of these must raise the ceiling in the
# same PR -- which is the moment to weigh whether the training envelope can still
# afford it. Overridable so the guard's own test can drive a lower ceiling and
# watch a real render breach it.
MEM_CEIL_MIB="${TB_CP_FOOTPRINT_MEM_CEIL:-3136}"
CPU_CEIL_MILLI="${TB_CP_FOOTPRINT_CPU_CEIL:-900}"

command -v helm >/dev/null 2>&1 || { echo "[ERROR] helm is required to render the chart footprint" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 is required to sum the rendered requests" >&2; exit 3; }
[ -d "$chart" ] || { echo "[ERROR] no chart at $chart -- refusing to report a footprint I could not render" >&2; exit 1; }
[ -f "$installer" ] || { echo "[ERROR] no installer at $installer -- cannot read the reserve to compare against" >&2; exit 1; }

# THE RESERVE, DERIVED from the installer's embedded constant, not restated. A
# `\b` word match on the exact assignment; missing it is a finding, not a pass.
reserve_bytes="$(sed -n 's/^_TB_ENVELOPE_OVERHEAD_MEM_BYTES=\([0-9]\{1,\}\).*/\1/p' "$installer" | head -1)"
reserve_cpu_milli="$(sed -n 's/^_TB_ENVELOPE_OVERHEAD_CPU_MILLI=\([0-9]\{1,\}\).*/\1/p' "$installer" | head -1)"
if [ -z "$reserve_bytes" ] || [ -z "$reserve_cpu_milli" ]; then
  echo "[ERROR] could not read _TB_ENVELOPE_OVERHEAD_{MEM_BYTES,CPU_MILLI} from $installer." >&2
  echo "        The reserve moved or was renamed; this guard compares against it and cannot 'cannot tell' into a pass." >&2
  exit 1
fi
reserve_mib=$(( reserve_bytes / 1024 / 1024 ))

profiles=("$chart"/ci/*-values.yaml)
[ -e "${profiles[0]}" ] || { echo "[ERROR] no client/ci/*-values.yaml to render against -- this guard would check nothing" >&2; exit 1; }

worst_mem=0
worst_cpu=0
fail=0
for vf in "${profiles[@]}"; do
  prof="$(basename "$vf" -values.yaml)"
  rendered="$(helm template be "$chart" --set image.tag=footprint-probe -f "$vf" 2>/dev/null || true)"
  if [ -z "$rendered" ]; then
    echo "[ERROR] $prof: the chart rendered nothing -- a footprint cannot be summed from an empty render." >&2
    fail=1
    continue
  fi
  summed="$(printf '%s' "$rendered" | python3 "$here/sum_control_plane_requests.py")"
  read -r mem cpu n <<<"$summed"
  if [ -z "${n:-}" ] || [ "${n:-0}" -eq 0 ]; then
    echo "[ERROR] $prof: rendered workloads carried ZERO resource requests -- the sum walked nothing, which is not the same as a footprint of zero." >&2
    fail=1
    continue
  fi
  echo "  $prof: control plane requests ${mem} MiB / ${cpu} m (from ${n} container(s))"
  (( mem > worst_mem )) && worst_mem=$mem
  (( cpu > worst_cpu )) && worst_cpu=$cpu
done

[ "$fail" -eq 0 ] || exit 1

# THE RATCHET.
if (( worst_mem > MEM_CEIL_MIB )); then
  echo "[ERROR] control-plane memory requests ${worst_mem} MiB exceed the recorded ceiling ${MEM_CEIL_MIB} MiB." >&2
  echo "        A chart change raised the footprint. Every MiB here is a MiB the training envelope loses on every edge," >&2
  echo "        and the footprint is ALREADY above the ${reserve_mib} MiB reserve (backend#2870). If the increase is intended," >&2
  echo "        raise TB_CP_FOOTPRINT_MEM_CEIL's default in this file -- and weigh whether backend#2460/#2461 must land first." >&2
  fail=1
fi
if (( worst_cpu > CPU_CEIL_MILLI )); then
  echo "[ERROR] control-plane cpu requests ${worst_cpu} m exceed the recorded ceiling ${CPU_CEIL_MILLI} m (backend#2870)." >&2
  echo "        Raise TB_CP_FOOTPRINT_CPU_CEIL's default in this file if intended." >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

# THE GAP, reported not asserted (see the header). Positive = the control plane
# already out-requests its reserve; that overshoot is what backend#2460 (measured
# kubelet reservation) and backend#2461 (control-plane trim) exist to close.
mem_gap=$(( worst_mem - reserve_mib ))
cpu_gap=$(( worst_cpu - reserve_cpu_milli ))
if (( mem_gap > 0 )); then
  echo "  note: the control plane requests ${worst_mem} MiB against a ${reserve_mib} MiB reserve -- ${mem_gap} MiB OVER."
  echo "        This is the memory half of the unschedulable gap (backend#2870); closing it is backend#2460/#2461, not this guard."
else
  echo "  note: control-plane memory ${worst_mem} MiB fits within the ${reserve_mib} MiB reserve (${mem_gap#-} MiB headroom)."
fi
(( cpu_gap > 0 )) \
  && echo "  note: control-plane cpu ${worst_cpu} m is ${cpu_gap} m OVER the ${reserve_cpu_milli} m reserve." \
  || echo "  note: control-plane cpu ${worst_cpu} m fits the ${reserve_cpu_milli} m reserve (${cpu_gap#-} m headroom)."

echo "control-plane-footprint: OK -- ${worst_mem} MiB / ${worst_cpu} m, at or under the recorded ceiling."
