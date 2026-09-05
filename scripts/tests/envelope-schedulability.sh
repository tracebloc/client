#!/usr/bin/env bash
#
#  envelope-schedulability.sh — the envelope the installer writes must be
#  schedulable beside the chart's own control plane (backend#2870, DoD parts 1+2).
#
#  WHY THIS EXISTS
#  ---------------
#  backend#2870: the installer sized the training envelope as `allocatable - 3 GiB`
#  and nothing then asked whether that number could be scheduled beside what the
#  chart installs. It could not: the control plane requests 3136 MiB (from the
#  render) against the 3072 MiB reserve, so every install over-asked and the
#  training pod sat Pending. No test in this repo could see it, because every
#  test compared the installers to the CONTRACT and none compared the arithmetic
#  to a CLUSTER.
#
#  WHAT IT ASSERTS, and how it derives rather than restates (backend#1729 rule 1)
#  ----------------------------------------------------------------------------
#  The footprint is SUMMED FROM THE CHART, here, by running
#  control-plane-footprint.sh --print-footprint on the tree under test -- never a
#  written-down 3008/3136/3148. Then, through the REAL installer functions
#  (_resolve_training_size + _fit_training_envelope, sourced from the tree):
#
#    1. the installer's embedded footprint constants equal that render;
#    2. for EVERY single-node golden vector in the contract table, the envelope
#       written + chart footprint + system pods <= allocatable, on memory AND cpu;
#    3. the ticket's 8 GiB reproduction is REDUCED, with the arithmetic;
#    4. a machine where not even a 1-core / 1-GiB run fits is REFUSED;
#    5. a cpu-only overshoot reduces cpu alone (DoD part 5: cover cpu too);
#    6. a human's pin is never altered, only warned;
#    7. the release's own pods are excluded from the measured system sum (else a
#       re-install counts the control plane twice);
#    8. unreadable footprint constants, and an unreadable cluster under an
#       installer-chosen non-floor size, REFUSE (fail closed); the floor under an
#       unreadable cluster is written UNVERIFIED, not refused.
#
#  Plus a POSITIVE CONTROL: before the fit, at least one golden vector must
#  over-ask against the derived footprint -- otherwise this guard is asserting a
#  fit the arithmetic could never have failed, and reading green here would mean
#  nothing. If the chart ever shrinks under the reserve (backend#2461) that
#  control is reported, not failed: the fit becomes a no-op by construction.
#
#  FAILS CLOSED. No helm, no python3, no chart, a render that will not sum, an
#  empty vector table: exit 2 with the reason. "Cannot tell" is not a pass.
#
#  TB_SCHED_ROOT points it at another tree, which is how
#  envelope-schedulability-mutations.sh drives it against mutated COPIES and
#  proves every assertion above can actually go red.
#
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${TB_SCHED_ROOT:-$(cd "$here/../.." && pwd)}"
LIB="$root/scripts/lib"
VECTORS="$root/scripts/tests/fixtures/envelope_vectors.bash"
FOOTPRINT_GUARD="$root/scripts/tests/control-plane-footprint.sh"

die2() { echo "[ERROR] $*" >&2; echo "envelope-schedulability: CANNOT TELL" >&2; exit 2; }
for f in "$LIB/common.sh" "$LIB/install-client-helm.sh" "$VECTORS" "$FOOTPRINT_GUARD"; do
  [ -r "$f" ] || die2 "cannot read $f"
done
command -v helm >/dev/null 2>&1 || die2 "helm is required to render the chart footprint"
command -v python3 >/dev/null 2>&1 || die2 "python3 is required to sum the rendered requests"

# ── DERIVE the footprint from the chart under test ───────────────────────────
fp_out="$(TB_CP_FOOTPRINT_ROOT="$root" bash "$FOOTPRINT_GUARD" --print-footprint 2>/dev/null)" \
  || die2 "control-plane-footprint.sh refused to print a footprint for $root"
read -r FP_MIB FP_M _ <<< "$fp_out"
[[ "${FP_MIB:-}" =~ ^[0-9]+$ && "${FP_M:-}" =~ ^[0-9]+$ ]] || die2 "footprint guard printed '$fp_out'"
MIB=$(( 1024 * 1024 )); GIB=$(( 1024 * 1024 * 1024 ))
FP_B=$(( FP_MIB * MIB ))

# ── the installer, for real ──────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/install-client-helm.sh"
# Both are read by the sourced installer functions (log(), _existing_training_values,
# _measured_system_requests), not by this file -- hence the SC2034 opt-out.
# shellcheck disable=SC2034
LOG_FILE=/dev/null
# shellcheck disable=SC2034
TB_NAMESPACE=tracebloc
has() { return 0; }
helm() { return 1; }          # no installed release: nothing is carried

# THE CANNED CLUSTER, written down independently of the code that reads it
# (rule 9's corollary). Two k3s system pods on the one node (coredns and
# metrics-server, 100m/70Mi each), one with no requests, and four that MUST NOT
# count: the chart's own jobs-manager in the release namespace, its DaemonSet in
# the release-owned node-agents namespace, a Succeeded hook, and a Pending pod
# not on any node. Counted correctly the system sum is 140 MiB / 200 m.
SYS_MIB=140; SYS_M=200
PODS='kube-system|Running|node-a|100m/70Mi,|
kube-system|Running|node-a|100m/70Mi,|
kube-system|Running|node-a|/,|
tracebloc|Running|node-a|500m/1Gi,|
tracebloc-node-agents|Running|node-a|100m/512Mi,|
kube-system|Succeeded|node-a|1/2Gi,|
kube-system|Pending||1/2Gi,|'
NAMESPACES='default|
kube-system|
tracebloc|tracebloc
tracebloc-node-agents|tracebloc'
NODES=""
PODS_READABLE=1
kubectl() {
  case "$*" in
    *"get nodes"*--request-timeout=*)      [[ -n "$NODES" ]] || return 1; printf '%s\n' "$NODES" ;;
    *"get namespaces"*--request-timeout=*) printf '%s\n' "$NAMESPACES" ;;
    *"get pods"*--request-timeout=*)       (( PODS_READABLE )) || return 1; printf '%s\n' "$PODS" ;;
    *) return 1 ;;
  esac
}

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }

# Run the installer's two steps on a cluster state; leaves the _TB_* results set.
resolve_and_fit() {
  NODES="$1"
  unset TRACEBLOC_TRAINING_RESOURCES
  [[ -n "${2:-}" ]] && export TRACEBLOC_TRAINING_RESOURCES="$2"
  _resolve_training_size
  BEFORE="$_TB_TRAINING_SIZE"
  _fit_training_envelope
}
env_mem_b() { _mem_to_bytes "$(_envelope_dimension "$1" memory)"; }
env_cpu_m() { _cpu_to_milli "$(_envelope_dimension "$1" cpu)"; }

echo "== envelope schedulability (backend#2870) =="
echo "  chart footprint, derived from the render: ${FP_MIB} MiB / ${FP_M} m; canned system pods: ${SYS_MIB} MiB / ${SYS_M} m"

# 1. THE EMBED EQUALS THE RENDER.
if [[ "${_TB_CP_FOOTPRINT_MEM_BYTES:-}" == "$FP_B" && "${_TB_CP_FOOTPRINT_CPU_MILLI:-}" == "$FP_M" ]]; then
  ok "embedded footprint (${_TB_CP_FOOTPRINT_MEM_BYTES} B / ${_TB_CP_FOOTPRINT_CPU_MILLI} m) equals the chart render"
else
  bad "embedded footprint is ${_TB_CP_FOOTPRINT_MEM_BYTES:-unset} B / ${_TB_CP_FOOTPRINT_CPU_MILLI:-unset} m but the render sums to ${FP_B} B / ${FP_M} m -- run scripts/gen-footprint-embed.sh"
fi

# 2. EVERY GOLDEN VECTOR, with the positive control.
# shellcheck source=/dev/null
source "$VECTORS"
[ "${#TB_ENVELOPE_VECTORS[@]}" -gt 0 ] || die2 "the golden-vector table is empty"
NEED_B=$(( FP_B + SYS_MIB * MIB )); NEED_M=$(( FP_M + SYS_M ))
over_before=0; checked=0
for row in "${TB_ENVELOPE_VECTORS[@]}"; do
  # The 4th field is the CONTRACT's expected resolver output; the golden-vector
  # replay in install-client-helm.bats pins that. Here the question is what
  # happens AFTER it, so the field is read and dropped.
  IFS='|' read -r label vcpu vmem _ <<< "$row"
  resolve_and_fit "$vcpu $vmem"
  alloc_m="$(_cpu_to_milli "$vcpu")"; alloc_b="$(_mem_to_bytes "$vmem")"
  if [[ -z "$alloc_m" || -z "$alloc_b" ]]; then
    # An unparseable node: the installer could not measure, so it must say
    # UNVERIFIED on the floor -- not refuse, not claim a fit.
    if [[ "$_TB_FIT_VERDICT" == "unverified" && "$_TB_TRAINING_SIZE" == "$_TRAINING_DEFAULT" ]]; then
      ok "${label}: unmeasurable node -> floor written UNVERIFIED"
    else
      bad "${label}: unmeasurable node -> verdict '${_TB_FIT_VERDICT}' size '${_TB_TRAINING_SIZE}' (want unverified floor)"
    fi
    continue
  fi
  checked=$((checked + 1))
  b_mem="$(env_mem_b "$BEFORE")"; b_cpu="$(env_cpu_m "$BEFORE")"
  if (( b_mem + NEED_B > alloc_b || b_cpu + NEED_M > alloc_m )); then over_before=$((over_before + 1)); fi
  case "$_TB_FIT_VERDICT" in
    refused)
      # Only legitimate when nothing requestable fits.
      if (( alloc_b - NEED_B < GIB || alloc_m - NEED_M < 1000 )); then
        ok "${label}: refused (fits $(( (alloc_b - NEED_B) / MIB )) MiB / $(( alloc_m - NEED_M )) m -- below 1 core / 1 GiB)"
      else
        bad "${label}: refused although $(( (alloc_b - NEED_B) / MIB )) MiB / $(( alloc_m - NEED_M )) m would fit"
      fi ;;
    fits|reduced)
      a_mem="$(env_mem_b "$_TB_TRAINING_SIZE")"; a_cpu="$(env_cpu_m "$_TB_TRAINING_SIZE")"
      if [[ -z "$a_mem" || -z "$a_cpu" ]]; then bad "${label}: written size '${_TB_TRAINING_SIZE}' unparseable"; continue; fi
      if (( a_mem + NEED_B <= alloc_b && a_cpu + NEED_M <= alloc_m && a_mem >= GIB && a_cpu >= 1000 && a_mem <= b_mem && a_cpu <= b_cpu )); then
        ok "${label}: ${BEFORE} -> ${_TB_TRAINING_SIZE} [${_TB_FIT_VERDICT}]: $(( a_mem / MIB )) + $(( NEED_B / MIB )) <= $(( alloc_b / MIB )) MiB, ${a_cpu} + ${NEED_M} <= ${alloc_m} m"
      else
        bad "${label}: ${BEFORE} -> ${_TB_TRAINING_SIZE} [${_TB_FIT_VERDICT}] does NOT fit: $(( a_mem / MIB )) + $(( NEED_B / MIB )) vs $(( alloc_b / MIB )) MiB, ${a_cpu} + ${NEED_M} vs ${alloc_m} m"
      fi ;;
    *) bad "${label}: unexpected verdict '${_TB_FIT_VERDICT}' on a measured node" ;;
  esac
done
if (( NEED_B > _TB_ENVELOPE_OVERHEAD_MEM_BYTES || NEED_M > _TB_ENVELOPE_OVERHEAD_CPU_MILLI )); then
  if (( over_before > 0 )); then
    ok "positive control: ${over_before}/${checked} measurable vectors over-asked BEFORE the fit (the defect is visible to this guard)"
  else
    bad "positive control: the platform out-requests the reserve, yet no vector over-asked before the fit -- this guard cannot see the defect it exists for"
  fi
else
  echo "  note  the platform (${NEED_B} B / ${NEED_M} m) now fits inside the reserve; the fit is a no-op by construction and the positive control does not apply"
fi

# 3. THE TICKET'S REPRODUCTION: an 8 GiB node.
resolve_and_fit "4 8Gi"
if [[ "$_TB_FIT_VERDICT" == "reduced" ]] && [[ "$_TB_FIT_LINES" == *"OVER"* ]] && [[ "$_TB_FIT_LINES" == *"reduced ${BEFORE} -> ${_TB_TRAINING_SIZE}"* ]]; then
  ok "8 GiB reproduction: ${BEFORE} -> ${_TB_TRAINING_SIZE}, arithmetic printed"
  printf '%s\n' "$_TB_FIT_LINES" | sed 's/^/        /'
else
  bad "8 GiB reproduction: verdict '${_TB_FIT_VERDICT}', ${BEFORE} -> ${_TB_TRAINING_SIZE}"
fi

# 4. REFUSAL when not even 1 core / 1 GiB fits.
resolve_and_fit "4 4Gi"
if [[ "$_TB_FIT_VERDICT" == "refused" && "$_TB_FIT_LINES" == *"not even a 1-core / 1-GiB run"* ]]; then
  ok "4 GiB node: refused, with the arithmetic"
else
  bad "4 GiB node: verdict '${_TB_FIT_VERDICT}' size '${_TB_TRAINING_SIZE}' (want refused)"
fi

# 5. CPU-ONLY overshoot: memory already fits (the GiB floor absorbed it), cpu does not.
resolve_and_fit "8 63928Mi"
a_mem="$(env_mem_b "$_TB_TRAINING_SIZE")"; b_mem="$(env_mem_b "$BEFORE")"
a_cpu="$(env_cpu_m "$_TB_TRAINING_SIZE")"; b_cpu="$(env_cpu_m "$BEFORE")"
if [[ "$_TB_FIT_VERDICT" == "reduced" ]] && (( a_mem == b_mem && a_cpu < b_cpu && a_cpu + NEED_M <= 8000 )); then
  ok "cpu-only overshoot: ${BEFORE} -> ${_TB_TRAINING_SIZE} (memory kept, cpu reduced)"
else
  bad "cpu-only overshoot: verdict '${_TB_FIT_VERDICT}', ${BEFORE} -> ${_TB_TRAINING_SIZE}"
fi

# 6. A HUMAN'S PIN is warned, never altered.
resolve_and_fit "4 8Gi" "cpu=4,memory=16Gi"
if [[ "$_TB_FIT_VERDICT" == "pinned-over" && "$_TB_TRAINING_SIZE" == "cpu=4,memory=16Gi" && "$_TB_TRAINING_PROVENANCE" == "user" ]]; then
  ok "user pin cpu=4,memory=16Gi on an 8 GiB node: written as-is, verdict pinned-over"
else
  bad "user pin: verdict '${_TB_FIT_VERDICT}' size '${_TB_TRAINING_SIZE}' prov '${_TB_TRAINING_PROVENANCE}'"
fi
unset TRACEBLOC_TRAINING_RESOURCES

# 7. THE RELEASE'S OWN PODS are excluded from the measured sum.
NODES="4 8Gi"
if _measured_system_requests && (( _TB_SYS_MEM_BYTES == SYS_MIB * MIB && _TB_SYS_CPU_MILLI == SYS_M )); then
  ok "measured system pods: ${SYS_MIB} MiB / ${SYS_M} m -- release, node-agents, Succeeded and unscheduled pods excluded"
else
  bad "measured system pods: $(( ${_TB_SYS_MEM_BYTES:-0} / MIB )) MiB / ${_TB_SYS_CPU_MILLI:-0} m (want ${SYS_MIB} / ${SYS_M}); note: ${_TB_SYS_NOTE:-}"
fi

# 7b. Pods unreadable: chart-only, and the verdict SAYS so; still reduces.
PODS_READABLE=0
resolve_and_fit "4 8Gi"
if [[ "$_TB_FIT_VERDICT" == "reduced" && "$_TB_FIT_LINES" == *"NOT measured"*"chart derivation only"* ]]; then
  ok "pod list unreadable: verified against the chart derivation only, and said so (${BEFORE} -> ${_TB_TRAINING_SIZE})"
else
  bad "pod list unreadable: verdict '${_TB_FIT_VERDICT}'; lines: ${_TB_FIT_LINES}"
fi
PODS_READABLE=1

# 8. FAIL CLOSED.
saved="$_TB_CP_FOOTPRINT_MEM_BYTES"; _TB_CP_FOOTPRINT_MEM_BYTES=""
resolve_and_fit "4 8Gi"
if [[ "$_TB_FIT_VERDICT" == "refused" && "$_TB_FIT_LINES" == *"_TB_CP_FOOTPRINT_"* ]]; then
  ok "blank footprint constant: refused"
else
  bad "blank footprint constant: verdict '${_TB_FIT_VERDICT}'"
fi
_TB_CP_FOOTPRINT_MEM_BYTES="$saved"

resolve_and_fit ""   # nodes unreadable -> the resolver falls back to the floor
if [[ "$_TB_FIT_VERDICT" == "unverified" && "$_TB_TRAINING_SIZE" == "$_TRAINING_DEFAULT" ]]; then
  ok "unreadable cluster, floor fallback: written UNVERIFIED"
else
  bad "unreadable cluster, floor fallback: verdict '${_TB_FIT_VERDICT}' size '${_TB_TRAINING_SIZE}'"
fi

# A carried installer-chosen size above the floor, cluster unreadable: refuse.
helm() { printf 'env:\n  RESOURCE_REQUESTS: cpu=7,memory=29Gi\n  RESOURCE_PROVENANCE: installer\n'; }
kubectl_saved="$(declare -f kubectl)"
kubectl() { case "$*" in *"get namespace "*) return 0 ;; *) return 1 ;; esac; }
resolve_and_fit ""
if [[ "$_TB_FIT_VERDICT" == "refused" && "$BEFORE" == "cpu=7,memory=29Gi" && "$_TB_TRAINING_PROVENANCE" == "installer" ]]; then
  ok "carried installer size cpu=7,memory=29Gi, cluster unreadable: refused (cannot verify)"
else
  bad "carried installer size, cluster unreadable: verdict '${_TB_FIT_VERDICT}' before '${BEFORE}' prov '${_TB_TRAINING_PROVENANCE}'"
fi
eval "$kubectl_saved"
helm() { return 1; }

echo "envelope-schedulability: ${pass} ok, ${fail} failed"
if (( fail > 0 )); then
  echo "envelope-schedulability: FAILED" >&2
  exit 1
fi
echo "envelope-schedulability: OK -- every golden vector schedules beside the chart's ${FP_MIB} MiB / ${FP_M} m control plane"
