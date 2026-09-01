#!/usr/bin/env bash
# =============================================================================
#  install-client-helm.sh — Install Tracebloc client (steps 3 & 4)
#  Generates values from defaults + user prompts (workspace, clientId, clientPassword)
#  and GPU detection. Values file is written to HOST_DATA_DIR/values.yaml.
# =============================================================================

# Stamped from scripts/spec/facts.env by scripts/check-facts.sh — do not hand-edit.
# The Windows installer waits for the same APIService with the same TB_METRICS_WAIT_S
# knob (#553), so the two defaults are one fact, gated in CI (#435).
METRICS_WAIT_TIMEOUT=120

TRACEBLOC_HELM_REPO_URL="https://tracebloc.github.io/client"
TRACEBLOC_HELM_REPO_NAME="tracebloc"
TRACEBLOC_CHART_NAME="client"

_ensure_helm_runnable() {
  if helm version --short &>/dev/null; then
    return 0
  fi
  local helm_bin
  helm_bin="$(command -v helm 2>/dev/null)" || true
  if [[ -z "$helm_bin" || ! -f "$helm_bin" ]]; then
    error "Installation tools are not available. Re-run the installer."
  fi
  if [[ ! -x "$helm_bin" ]]; then
    log "Helm at $helm_bin is not executable — fixing permissions"
    if sudo chmod 755 "$helm_bin" 2>/dev/null; then
      log "Helm permissions fixed."
      return 0
    fi
    error "Could not fix tool permissions. Run manually: sudo chmod 755 $helm_bin"
  fi
  error "Installation tools could not be run. Try: sudo chmod 755 $helm_bin then re-run this script."
}

# ── Training-size default (backend#1236, option A; floored backend#2254) ─────
# One knob. MEMORY is requests == limits; CPU is a request-only share weight
# with no limit, so on a CPU edge the pod is BURSTABLE, not Guaranteed QoS --
# see the L0.2 rationale at `_training_limits` below, which this header used to
# contradict outright (backend#2872).
#
# ON A GPU EDGE IT IS BestEffort, NOT BURSTABLE, and saying BURSTABLE flat here
# was the same overshoot this branch fixed in the schema, in the file it was not
# fixed for (review on client#922). `_gpu_request_value` emits
# `nvidia.com/gpu=1` / `amd.com/gpu=1`, and client-runtime's `_get_gpu_resources`
# returns ONLY that plus ephemeral-storage -- it never reads RESOURCE_REQUESTS /
# RESOURCE_LIMITS on that path. QoS is computed from cpu and memory alone
# (`isSupportedQoSComputeResource`), so both accumulators are empty and the pod
# lands in the worst class: first choice for OOM kill and eviction, on a node it
# shares with mysql and jobs-manager.
#
# THE TICKET IS CLOSED WITH THIS HALF UNFIXED, which is why it is written here
# rather than left as a reference. backend#2871 raised both GPU BestEffort
# workloads; client#919 fixed the DEVICE-PLUGIN half (both DaemonSets are now
# Guaranteed) and the issue was closed, while the TRAINING-pod half stayed open
# and lost its record. `scripts/tests/pod-qos-class.py` asserts the shape from
# this side -- "gpu + ephemeral-storage only, no cpu/memory -> BestEffort" -- but
# the fix belongs in client-runtime.
#
# The old static default
# ("cpu=2,memory=8Gi") was wrong at both ends: dead on arrival on nodes under
# 8 GiB (the WSL2 field case, and a default Docker Desktop VM — nothing could
# ever schedule, backend#2254) and ~12% of a 64 GiB box. Precedence:
#   1. TRACEBLOC_TRAINING_RESOURCES  (explicit install-time override, client#308)
#   2. the installed release's current value — a `tracebloc resources set`
#      choice must survive re-install, never be clobbered back to a default
#   3. sized to this machine: LARGEST node allocatable − platform overhead
#      (~1 CPU / 3 GiB, the cli's constants; a pod schedules onto ONE node, and
#      k3d's server+agent are the same machine — summing would double-count)
#   4. the contract FLOOR (tiny or undeterminable machines) — the fallback the
#      installer writes when it cannot do better. Was the 8Gi literal above,
#      which exceeded a default Docker Desktop and sat Pending forever, so
#      backend#2254 floored it. _TRAINING_DEFAULT is DERIVED from the embedded
#      floor constants (below, so it cannot drift from the contract).

# k8s cpu quantity -> millicores ("12" -> 12000, "11500m" -> 11500); empty on junk.
_cpu_to_milli() {
  case "$1" in
    *m) printf '%s' "${1%m}" ;;
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$(( $1 * 1000 ))" ;;
  esac
}
# k8s memory quantity -> bytes (Ki/Mi/Gi or plain bytes); empty on junk.
_mem_to_bytes() {
  local v="$1"
  case "$v" in
    *Ki) printf '%s' "$(( ${v%Ki} * 1024 ))" ;;
    *Mi) printf '%s' "$(( ${v%Mi} * 1024 * 1024 ))" ;;
    *Gi) printf '%s' "$(( ${v%Gi} * 1024 * 1024 * 1024 ))" ;;
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$v" ;;
  esac
}

# ONE lookup of the installed release's carried training values, echoing
# "<size>|<provenance>" or NOTHING (backend#2220, Bugbot on #768).
#
# The two used to be read by two independent `helm get values` calls. That is
# fail-unsafe in BOTH directions, and each installer found a different half of
# it: on PowerShell a failed provenance read reported `installer` for a carried
# size, inviting a ladder to overrule a human; on bash a failed provenance read
# reported `unknown`, which consumers treat as a human pin — so an
# installer-sized edge was PERMANENTLY STRANDED as a deliberate choice, the very
# outcome scope bullet 4 exists to prevent.
#
# One lookup removes both: either it succeeds and the size and the marker come
# from the same read, or it fails and NOTHING is carried, so the caller machine-
# sizes and `installer` is then the correct verdict. They cannot disagree.
#
# Handles both the quoted form our values file writes and the unquoted form
# helm re-serializes (`helm get values` strips quotes — the #200 lesson).
# Provenance is normalised here: anything unrecognised, including absent, is
# `unknown`, never a guess.
_existing_training_values() {
  local ns="${TB_NAMESPACE:-}" out size prov
  [[ -n "$ns" ]] || return 0
  # helm get has no request timeout, so gate it behind a BOUNDED probe: a
  # wedged API degrades to machine sizing / the static default instead of
  # hanging values generation (Bugbot). A missing namespace also means there
  # is no release to carry — skip the helm call entirely.
  kubectl get namespace "$ns" --request-timeout=5s >/dev/null 2>&1 || return 0
  out="$(helm get values "$ns" -n "$ns" 2>/dev/null)" || return 0
  [[ -n "$out" ]] || return 0
  # READ RESOURCE_REQUESTS, FALL BACK TO RESOURCE_LIMITS (backend#2418, Bugbot
  # High on client#820).
  #
  # This used to read RESOURCE_LIMITS only, which was fine while both fields
  # held the same string. Since L0.2 the limits half is memory-only, so reading
  # it here breaks a REINSTALL two ways:
  #
  #   * the carried "size" comes back as `memory=29Gi`, and the caller writes
  #     that into RESOURCE_REQUESTS — silently DROPPING the cpu request, so the
  #     pod asks for no CPU share at all;
  #   * the historic-literal gate below compares against `cpu=2,memory=8Gi`, so
  #     a carried `memory=8Gi` no longer matches. The post-filter default is
  #     then mistaken for a deliberate human choice and the machine is never
  #     re-sized.
  #
  # RESOURCE_REQUESTS still carries the WHOLE envelope, so it is the field to
  # read. LIMITS remains the fallback for a release installed before requests
  # was written, or a chart-direct install that set only that key.
  size="$(printf '%s\n' "$out" | awk '
    /^[[:space:]]*RESOURCE_REQUESTS:/ {
      sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit
    }')"
  if [[ -z "$size" ]]; then
    size="$(printf '%s\n' "$out" | awk '
      /^[[:space:]]*RESOURCE_LIMITS:/ {
        sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit
      }')"
  fi
  # No carried size means nothing to attribute; the caller sizes the machine.
  [[ -n "$size" ]] || return 0
  prov="$(printf '%s\n' "$out" | awk '
    /^[[:space:]]*RESOURCE_PROVENANCE:/ {
      sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit
    }')"
  case "$prov" in
    installer|user) ;;
    *) prov="unknown" ;;
  esac
  printf '%s|%s' "$size" "$prov"
}

# The installed release's carried ENVELOPE (RESOURCE_REQUESTS, or LIMITS when
# that is absent), or nothing. Thin reader over the one shared lookup, kept
# because it is the tested, readable entry point.
_existing_training_resources() {
  local v
  v="$(_existing_training_values)"
  [[ -n "$v" ]] || return 0
  printf '%s' "${v%%|*}"
}

# ── envelope contract (GENERATED — do not hand-edit) ─────────────────────────
#
# backend#2220 / RFC-BACKEND-664 §P0. These four numbers used to be typed out
# here, again in install-k8s.ps1, and a third time in cli's set.go, with a
# fourth policy in client-runtime's node_sizing.py. Four copies, none derived
# from the others.
#
# They now come from ONE place — client-runtime/envelope_contract.json, whose
# arithmetic lives in node_sizing.envelope_from_allocatable. bash cannot parse
# JSON (jq is not a guaranteed prerequisite — see the helm-namespace note
# below) and the bootstrap is signed and must not fetch anything unsigned, so
# the constants are EMBEDDED here, exactly as the GPU node-image build inputs
# are embedded into install-k8s.ps1 (#616/#633).
#
# What keeps an embed honest is the drift guard, not the comment:
#   * scripts/tests/install-client-helm.bats replays the contract's golden
#     vectors through _machine_training_resources, so a constant edited here
#     and nowhere else reddens immediately;
#   * .github/workflows/envelope-contract-drift.yml re-checks the vendored
#     fixture against client-runtime at scripts/.client-runtime-ref.
#
# Regenerate after an upstream contract change:
#   scripts/gen-envelope-embed.sh
_TB_ENVELOPE_CONTRACT_VERSION=2
_TB_ENVELOPE_OVERHEAD_CPU_MILLI=1000
_TB_ENVELOPE_OVERHEAD_MEM_BYTES=3221225472
_TB_ENVELOPE_FLOOR_CPU_MILLI=1000
_TB_ENVELOPE_FLOOR_MEM_BYTES=2147483648
_TB_ENVELOPE_VM_RESERVE_MEM_BYTES=1073741824
_TB_ENVELOPE_NODE_MIN_CPU_MILLI=2000
_TB_ENVELOPE_NODE_MIN_MEM_BYTES=5368709120
# ── end generated ───────────────────────────────────────────────────────────

# ── the fallback training envelope (precedence step 4) ──────────────────────
# The contract FLOOR — cpu=1,memory=2Gi — DERIVED from the embedded floor
# constants so it cannot drift from envelope_contract.json. Written when the
# machine is unschedulable or unreadable. Was cpu=2,memory=8Gi, which exceeded a
# default Docker Desktop VM and left a fresh install Pending forever; the floor
# is the largest fallback that still fits the smallest host we support
# (backend#2254). The bats suite pins it to the embedded floor.
_TRAINING_DEFAULT="cpu=$(( _TB_ENVELOPE_FLOOR_CPU_MILLI / 1000 )),memory=$(( _TB_ENVELOPE_FLOOR_MEM_BYTES / 1024 / 1024 / 1024 ))Gi"

# The historic fallback literal (pre-backend#2254). FROZEN — NOT the current
# default — kept only so the carry gate in _resolve_training_size still
# RECOGNISES it: existing field installs carry cpu=2,memory=8Gi as their
# absence-of-a-choice default and must re-derive on re-install rather than
# freeze an unschedulable 8Gi. The current floor default is deliberately NOT
# matched by that gate — a human may legitimately `tracebloc resources set` the
# floor, and precedence step 2 says that choice must survive.
_TRAINING_DEFAULT_HISTORIC="cpu=2,memory=8Gi"

# The node line contract, in ONE place (backend#2237).
#
# Three whitespace-separated fields per node: allocatable cpu, allocatable
# memory, and `.spec.unschedulable`. Kubernetes declares Unschedulable with
# `omitempty`, so a normal node emits nothing for the third field and the line
# carries a trailing space; only a CORDONED node emits the literal `true`. Both
# readers therefore test for `true` rather than for emptiness.
#
# Extended from two fields to three under backend#2237: the contract's
# skipped_nodes has always said `spec.unschedulable (cordoned)` is skipped, but
# neither installer ASKED the API for the field, so neither could honour it.
# install-k8s.ps1's Get-TrainingResources carries the PowerShell copy of this
# string — the two are pinned to agree by the shared cluster-state fixture,
# scripts/tests/fixtures/installer_parity.json.
_TB_NODE_JSONPATH='{range .items[*]}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{" "}{.spec.unschedulable}{"\n"}{end}'

# ONE ranking of the cluster's nodes, shared by _machine_training_resources and
# _machine_training_ceiling (backend#2237).
#
# The anchor is the contract's ANCHOR_LARGEST: a training pod takes all its
# resources from ONE node, so this question is single-node by nature and must
# never sum across the cluster. The tie-break is (cpu, memory) — the contract's
# order, and a fix: this used to rank nodes (memory, cpu) while cli's nodeLarger
# ranked them (cpu, memory), so on a cluster of 8c/16Gi + 4c/32Gi the installer
# and `tracebloc resources set` anchored on DIFFERENT nodes and disagreed about
# the same machine. Nobody chose that; it fell out of two independent
# implementations.
#
# Extracted under backend#2237 because the loop was written out TWICE, once per
# caller, and the cordon skip would have had to be added to both. Two copies of
# a selection rule is exactly how the (memory, cpu) / (cpu, memory) split above
# happened; one copy cannot drift from itself.
#
# The contract's skipped_nodes, both honoured here:
#   * spec.unschedulable (cordoned) — a cordoned node accepts no new pods, so
#     anchoring on one writes an envelope that cannot schedule. On a
#     heterogeneous cluster a cordoned LARGE node would otherwise win the
#     anchor outright and every training pod would sit Pending with no obvious
#     cause. This is NOT a no-op on installer-provisioned clusters just
#     because they are 'single-node k3d' -- they are not: common.sh defaults
#     SERVERS=1 AGENTS=1, so the default topology is TWO nodes
#     (backend#2221). What makes the anchor tie-break a field no-op there
#     is that both k3d node containers report IDENTICAL figures, because
#     each reports the whole Docker VM -- which is the bug #2221 fixes.
#     The cordon skip itself matters on any cluster with a cordoned node.
#   * allocatable cpu or memory unparseable — skipped rather than coerced to 0,
#     so a node whose memory unit we do not speak cannot take the anchor and
#     drag a perfectly sizeable sibling down to the literal (Bugbot #766).
#
# Sets _TB_ANCHOR_CPU_MILLI / _TB_ANCHOR_MEM_BYTES and returns 0 when at least
# one node was measured; returns 1 when the cluster is unreadable or no node
# survived the skips. Callers must treat 1 as "I could not measure the machine",
# which is NOT the same as "the machine is too small".
_anchor_largest_schedulable() {
  has kubectl || return 1
  local lines cpu mem unsched cpu_m mem_b best_cpu=0 best_mem=0 seen=0
  # Bounded: a wedged API server must degrade to the static default, never
  # hang values generation (Bugbot).
  lines="$(kubectl get nodes --request-timeout=10s -o jsonpath="$_TB_NODE_JSONPATH" 2>/dev/null)" || return 1
  [[ -n "$lines" ]] || return 1
  while read -r cpu mem unsched; do
    [[ -n "$cpu" && -n "$mem" ]] || continue
    # Cordoned: skipped BEFORE ranking, so it can never win the anchor.
    # Written `!= ... || continue`, not `== ... && continue`: the latter
    # evaluates to 1 for every SCHEDULABLE node, which under the installer's
    # `set -euo pipefail` aborts the whole run (the shape the shared
    # `early-close` gate in tracebloc/.github's code-quality.yml catches).
    [[ "$unsched" != "true" ]] || continue
    cpu_m="$(_cpu_to_milli "$cpu")"
    mem_b="$(_mem_to_bytes "$mem")"
    [[ -n "$cpu_m" && -n "$mem_b" ]] || continue
    if (( seen == 0 )) || (( cpu_m > best_cpu )) \
       || { (( cpu_m == best_cpu )) && (( mem_b > best_mem )); }; then
      best_cpu=$cpu_m
      best_mem=$mem_b
    fi
    seen=1
  done <<< "$lines"
  (( seen == 1 )) || return 1
  _TB_ANCHOR_CPU_MILLI=$best_cpu
  _TB_ANCHOR_MEM_BYTES=$best_mem
}

# Echo "cpu=N,memory=MGi" sized to the largest schedulable node, or nothing when
# the cluster is unreadable / the machine cannot give a run the contract floor.
#
# Node selection lives in _anchor_largest_schedulable; this function is the
# arithmetic and the rendering only.
_machine_training_resources() {
  _anchor_largest_schedulable || return 0
  local run_cpu_m=$(( _TB_ANCHOR_CPU_MILLI - _TB_ENVELOPE_OVERHEAD_CPU_MILLI ))
  local run_mem_b=$(( _TB_ANCHOR_MEM_BYTES - _TB_ENVELOPE_OVERHEAD_MEM_BYTES ))
  (( run_cpu_m < 0 )) && run_cpu_m=0
  (( run_mem_b < 0 )) && run_mem_b=0
  # Below the contract floor the machine is NOT VIABLE. Emit nothing and let
  # the caller fall back to _TRAINING_DEFAULT. That fallback used to be the 8Gi
  # literal — larger than such a machine, a known bug (backend#2220); since
  # backend#2254 it is the contract floor, which fits. The fallback structure is
  # deliberately kept revertable — only the value it writes changed.
  { (( run_cpu_m >= _TB_ENVELOPE_FLOOR_CPU_MILLI )) \
    && (( run_mem_b >= _TB_ENVELOPE_FLOOR_MEM_BYTES )); } || return 0
  printf 'cpu=%d,memory=%dGi' "$(( run_cpu_m / 1000 ))" "$(( run_mem_b / 1024 / 1024 / 1024 ))"
}

# The LIMITS half of a training envelope: memory only, never cpu (backend#2418,
# Utilization Ladder L0.2).
#
# WHY THE TWO HALVES DIFFER. CPU and memory are not the same kind of resource:
#
#   * CPU is time-shared. A `requests` with NO `limits` becomes a cgroup
#     `cpu.weight` -- a share of the machine under contention, and the whole
#     machine when nobody else wants it. With `requests == limits` it becomes a
#     `cpu.max` QUOTA instead, which throttles at the ceiling even on a
#     completely idle box. On an 8-core machine a run sized to 7 cores was
#     capped at 7 while the 8th sat idle, for no benefit to anyone.
#   * Memory is NOT time-shared. There is no "borrow it back": exceeding the
#     limit is an OOM kill. So `requests == limits` is the load-bearing safety
#     property and it does NOT move.
#
# Guaranteed QoS is lost by design -- a pod is Guaranteed only when every
# container has limits for both dimensions. That is the trade L0.2 makes: the
# memory guarantee is what mattered, and CPU burstability is what lets a second
# job exist at all.
#
# ORDERING CONSTRAINT, not optional: this requires a jobs-manager that treats
# RESOURCE_LIMITS as the COMPLETE limits envelope (client-runtime#388). An older
# image MERGES the parsed pairs onto its built-in cpu=2,memory=8Gi literal, so
# an omitted `cpu` comes back as a 2-core LIMIT under a 7-core REQUEST -- which
# Kubernetes rejects outright, and the pod never schedules. Do not ship this
# chart to an edge whose client-runtime predates #388.
_training_limits() {
  local size="$1" out="" pair
  local IFS=,
  for pair in $size; do
    # TRIM FIRST. `case " cpu=7 " in cpu=*)` does NOT match, so an operator who
    # wrote `TRACEBLOC_TRAINING_RESOURCES="cpu=7, memory=29Gi"` would keep the
    # cpu limit -- silently, and in the dangerous direction. The PowerShell twin
    # trims via `.Trim()`, so skipping it here is also a twin DIVERGENCE: the
    # same shared contract, two different control flows, which is the exact bug
    # class backend#2220 found five of. jobs-manager's own parser strips too, so
    # trimmed output is what it would have read anyway.
    pair="${pair#"${pair%%[![:space:]]*}"}"
    pair="${pair%"${pair##*[![:space:]]}"}"
    [[ -n "$pair" ]] || continue
    # CASE-INSENSITIVE, via character classes rather than `${pair,,}` — this
    # bootstrap has to run under macOS's bash 3.2, which has no case conversion.
    #
    # A twin DIVERGENCE otherwise (review on client#820): PowerShell's
    # `-like 'cpu=*'` is case-insensitive, so `CPU=7,memory=29Gi` dropped the
    # cpu limit on Windows and kept it on Linux/macOS. Same class as the
    # whitespace-trim divergence, and every parity fixture row is lowercase, so
    # nothing pinned it.
    case "$pair" in
      [Cc][Pp][Uu]=*) continue ;;
    esac
    out="${out:+$out,}$pair"
  done
  # Nothing survived the filter -- a cpu-only envelope, which is not something
  # to guess at. Return the INPUT UNCHANGED rather than an empty string: an
  # empty RESOURCE_LIMITS reads to jobs-manager as "unset", which since
  # client-runtime#388 mirrors the requests side back and resurrects the very
  # cpu limit this function exists to drop.
  #
  # `$size` itself is never empty on any reachable path: _training_resources'
  # four-way fallback chain (env override -> installed release -> machine sizing
  # -> the contract-floor literal) always yields a value. An empty input would
  # return empty here, and that is the honest answer -- there is nothing to say
  # about an envelope that does not exist.
  printf '%s' "${out:-$size}"
}

# Echo "<size>|viable" or "<size>|undersized" for the largest node, or NOTHING
# when the cluster is unreadable (backend#2220).
#
# The distinction this adds is the whole point: "I cannot see the machine" and
# "I can see it and it is too small" used to collapse into the same empty
# answer, so both fell through to the fallback literal. When that literal was
# cpu=2,memory=8Gi, on a machine with ~4 GiB allocatable it was LARGER THAN THE
# MACHINE, so every training pod stayed Pending forever -- and preflight lets
# exactly those machines install: it hard-fails below 5 GB on Linux and only
# WARNS on macOS/Windows (PF_MIN_MEM_GB=5), while its own comment notes a job's
# limit is ~8 GiB+. So the permitted band and the unschedulable band overlapped.
#
# Unreadable is still unreadable and still gets the fallback -- we genuinely
# cannot do better without measuring. Since backend#2254 that fallback is the
# contract floor, not the 8Gi literal, so it now FITS; the "read it, it is
# small" case likewise gets the honest remainder, which fits too.
#
# Node selection is the SAME _anchor_largest_schedulable the sizing path uses,
# so the warning the caller prints can never describe a different node than the
# value it wrote (backend#2237).
_machine_training_ceiling() {
  _anchor_largest_schedulable || return 0

  local run_cpu_m=$(( _TB_ANCHOR_CPU_MILLI - _TB_ENVELOPE_OVERHEAD_CPU_MILLI ))
  local run_mem_b=$(( _TB_ANCHOR_MEM_BYTES - _TB_ENVELOPE_OVERHEAD_MEM_BYTES ))
  (( run_cpu_m < 0 )) && run_cpu_m=0
  (( run_mem_b < 0 )) && run_mem_b=0

  local cores=$(( run_cpu_m / 1000 ))
  local gib=$(( run_mem_b / 1024 / 1024 / 1024 ))

  if (( run_cpu_m >= _TB_ENVELOPE_FLOOR_CPU_MILLI )) \
     && (( run_mem_b >= _TB_ENVELOPE_FLOOR_MEM_BYTES )); then
    printf 'cpu=%d,memory=%dGi|viable' "$cores" "$gib"
    return 0
  fi

  # Below the contract floor. Report the honest remainder when it is a
  # REQUESTABLE shape -- at least one whole core and one whole GiB. Reachable
  # only on macOS/Windows, where the memory preflight warns instead of failing.
  if (( cores >= 1 && gib >= 1 )); then
    printf 'cpu=%d,memory=%dGi|undersized' "$cores" "$gib"
    return 0
  fi

  # A node WAS parsed and the remainder is not even a requestable shape (cpu=0 is
  # not a training request). Reported as its own verdict rather than as silence,
  # because silence here is indistinguishable from "I could not read the
  # cluster" -- and those must not be treated alike. Warning that a machine is
  # too small when we never managed to measure it is a fabrication, and the
  # caller used to do exactly that by re-probing `kubectl get nodes -o name`:
  # any listable node, including one whose allocatable would not parse or which
  # is not Ready yet, tripped the hard warning. The PowerShell twin only flagged
  # it after a PARSED node, so the two disagreed on the same cluster -- the
  # divergence class client#766 exists to remove (Bugbot on #768).
  printf '|unschedulable'
  return 0
}

# ── the VM beneath the node containers (backend#2221) ────────────────────────
#
# Everything above answers "how much may one run have, given a NODE". On a k3d
# install that premise is false: the node containers are created with
# `NanoCpus=0 CpuQuota=0 Memory=0`, so each one honestly reports the WHOLE
# Docker VM and the default topology (SERVERS=1 AGENTS=1) tells Kubernetes the
# machine is twice its size. Measured on k3d v5.9.0 / k3s v1.35.5 / Docker
# 29.5.2: a 7.75 GiB VM presented as 15.50 GiB, byte-exactly 2.000x, and two
# pods at this installer's OWN derived envelope (cpu=9,memory=4Gi) both went
# Running on a 10 cpu / 7.75 GiB machine.
#
# Two asymmetries decide the shape of the fix, and both are measured:
#
#   MEMORY IS CAPPABLE, AT CREATE TIME ONLY. `k3d --servers-memory/
#   --agents-memory` works by bind-mounting a SYNTHETIC /proc/meminfo into the
#   node container (a "fakeowner" mount) -- not via the cgroup, which kubelet
#   never reads for capacity. `docker update --memory` on a running node moves
#   the cgroup and leaves /proc/meminfo alone, so capacity does not budge even
#   across a restart: an existing cluster cannot be capped in place.
#
#   CPU IS NOT CAPPABLE AT ALL. k3d 5.9.0 has no CPU flag, and neither
#   `--cpus` (a CFS quota) nor `--cpuset-cpus` reaches kubelet, because cadvisor
#   counts /sys/devices/system/cpu/present and /proc/cpuinfo and no cgroup
#   namespaces either. So the only lever that makes cpu honest is FEWER NODE
#   CONTAINERS -- the remedy the GPU path already chose for --gpus=all, which
#   collapses to a single node so one physical card is advertised once.
#
# Echo "nodes=N,cap=BYTES,cpu_honest=0|1,viable=0|1", or NOTHING when the VM is
# unreadable. Nothing means "I cannot answer" and a caller must not read it as
# one node: collapsing a cluster on a failed probe is worse than leaving the
# topology alone.
#
# The arithmetic is client-runtime/node_sizing.py::honest_topology; the
# constants are embedded above and the vectors replayed by
# scripts/tests/install-client-helm.bats. `requested` below 1 is a caller bug,
# not a machine state: it returns 1 with no output rather than inventing a
# topology (the PowerShell twin does the same).
_honest_topology() {
  local vm_cpu="$1" vm_mem="$2" requested="$3"
  [[ "$requested" =~ ^[0-9]+$ ]] || return 1
  (( requested >= 1 )) || return 1

  local vm_cpu_m vm_mem_b
  vm_cpu_m="$(_cpu_to_milli "$vm_cpu")"
  vm_mem_b="$(_mem_to_bytes "$vm_mem")"
  [[ -n "$vm_cpu_m" && -n "$vm_mem_b" ]] || return 0

  # The VM cannot give the node containers everything it has: the k3d serverlb
  # and tools containers, dockerd/containerd and the guest page cache all live
  # outside them. Capping to the last byte starves the runtime that runs them.
  local usable=$(( vm_mem_b - _TB_ENVELOPE_VM_RESERVE_MEM_BYTES ))
  (( usable < 0 )) && usable=0

  local fits=$(( usable / _TB_ENVELOPE_NODE_MIN_MEM_BYTES ))
  local nodes="$requested"
  (( fits < nodes )) && nodes=$fits
  # Never zero: "no cluster at all" is not this function's call to make. The
  # caller refuses on `viable=0`.
  (( nodes < 1 )) && nodes=1

  # Floored -- a cap that rounds UP is not a cap.
  local cap=$(( usable / nodes ))

  # cpu_honest is measured, not chosen: no cap makes capacity.cpu true on more
  # than one node container.
  local cpu_honest=0
  (( nodes == 1 )) && cpu_honest=1

  # One honest node needs the platform overhead AND the training floor. Below
  # that the VM cannot host a run whatever it is capped to.
  local viable=0
  if (( fits >= 1 )) && (( vm_cpu_m >= _TB_ENVELOPE_NODE_MIN_CPU_MILLI )); then
    viable=1
  fi

  printf 'nodes=%d,cap=%d,cpu_honest=%d,viable=%d' \
    "$nodes" "$cap" "$cpu_honest" "$viable"
}

# The installed release's RESOURCE_PROVENANCE (nested under env:), or nothing.
# Same awk shape as _existing_training_resources — `helm get values` strips the
# quotes our values file writes (the #200 lesson).
# The installed release's RESOURCE_PROVENANCE, or nothing. Thin reader over the
# same shared lookup, so it can never disagree with the size beside it.
_existing_training_provenance() {
  local v
  v="$(_existing_training_values)"
  [[ -n "$v" ]] || return 0
  printf '%s' "${v##*|}"
}

# Resolve the per-run training size AND who chose it, in one pass.
#
# Split out of _training_resources (which is now a thin wrapper over it) because
# the two answers come from the same branch decision and the caller needs both.
# Deriving them separately would mean either running the cluster probes twice or
# re-implementing the branch logic beside itself — the exact duplication
# backend#2220 exists to delete.
#
# Sets, in the CALLER's scope (so a subshell cannot swallow them):
#   _TB_TRAINING_SIZE       "cpu=N,memory=MGi"
#   _TB_TRAINING_PROVENANCE installer | user | unknown
#
# Why provenance is needed at all: RESOURCE_* has no unset state once helm's
# --reset-then-reuse-values has seen it, so an installer-written value and a
# deliberate `tracebloc resources set` are indistinguishable once the value
# differs from the historic literal. Without a marker, any future ladder that
# re-derives sizes would silently overrule human choices. With one, it can
# re-derive `installer` values and leave the rest alone.
_resolve_training_size() {
  _TB_TRAINING_SIZE=""
  _TB_TRAINING_PROVENANCE=""
  # Set when the machine is readable but below the training floor. The WARNING
  # lives in the caller, never here: _training_resources / _training_provenance
  # are captured with $(...) and their tests compare the whole output, so a warn
  # emitted from this function would corrupt every one of them.
  _TB_TRAINING_UNDERSIZED=0
  _TB_TRAINING_UNSCHEDULABLE=0

  # 1. An explicit install-time override IS a human choice, same as the CLI's.
  if [[ -n "${TRACEBLOC_TRAINING_RESOURCES:-}" ]]; then
    _TB_TRAINING_SIZE="$TRACEBLOC_TRAINING_RESOURCES"
    _TB_TRAINING_PROVENANCE="user"
    return 0
  fi

  # ONE lookup, both fields — see _existing_training_values. Calling the two
  # readers separately here would reintroduce exactly the split this fixes.
  local carried prev prev_prov
  carried="$(_existing_training_values)"
  prev="${carried%%|*}"
  [[ -n "$carried" ]] || prev=""
  # The historic static default was the ABSENCE of a choice, not a choice —
  # carrying it would keep the unschedulable 8Gi on exactly the machines this
  # sizing exists to fix (Bugbot). Only a value that differs from it survives.
  # Matched against the FROZEN historic literal, NOT _TRAINING_DEFAULT: since
  # backend#2254 the latter is the contract floor, which a human may deliberately
  # pin — and precedence step 2 says that choice must survive re-install, so the
  # gate must not re-derive it. A field install predating #2254 still carries the
  # 8Gi literal; that is what this recognises as a non-choice and re-sizes.
  if [[ -n "$prev" && "$prev" != "$_TRAINING_DEFAULT_HISTORIC" ]]; then
    _TB_TRAINING_SIZE="$prev"
    prev_prov="${carried##*|}"
    case "$prev_prov" in
      installer|user)
        # A marker already on the release is authoritative — preserve it, or a
        # re-install would quietly downgrade a `user` choice to `unknown`.
        _TB_TRAINING_PROVENANCE="$prev_prov"
        ;;
      *)
        # Carried forward from before this key existed. We genuinely cannot tell
        # who set it, and saying so is better than guessing: consumers treat
        # `unknown` as `user` and leave it alone.
        _TB_TRAINING_PROVENANCE="unknown"
        ;;
    esac
    return 0
  fi

  # 2. Sized to this machine, or 3. the static default — both are OUR choice.
  local ceiling
  ceiling="$(_machine_training_ceiling)"
  case "$ceiling" in
    *'|viable')
      _TB_TRAINING_SIZE="${ceiling%|viable}"
      ;;
    *'|undersized')
      # The machine is real and readable but below the training floor. Write the
      # honest remainder: it FITS, which the 8 GiB literal does not, so a run can
      # at least be scheduled and fail for a reason instead of sitting Pending.
      _TB_TRAINING_SIZE="${ceiling%|undersized}"
      _TB_TRAINING_UNDERSIZED=1
      ;;
    '|unschedulable')
      # Measured, and the machine cannot host even a 1-core/1-GiB run. Keep the
      # literal -- there is no honest number to write -- and let the caller warn.
      _TB_TRAINING_SIZE="$_TRAINING_DEFAULT"
      _TB_TRAINING_UNSCHEDULABLE=1
      ;;
    *)
      # We could not read the cluster (no kubectl, a wedged API, or nothing
      # parseable). Keep the historical default and stay SILENT about machine
      # size: we never measured it, so any claim about it would be invented.
      _TB_TRAINING_SIZE="$_TRAINING_DEFAULT"
      ;;
  esac
  _TB_TRAINING_PROVENANCE="installer"
  return 0
}

# The per-run training size for the generated values ("cpu=N,memory=MGi").
# Thin wrapper kept because it is the tested, readable entry point; the values
# generation calls _resolve_training_size directly so it gets both answers from
# a single pass of the cluster probes.
_training_resources() {
  _resolve_training_size
  printf '%s' "$_TB_TRAINING_SIZE"
}

# Who chose the size _training_resources reports (installer | user | unknown).
_training_provenance() {
  _resolve_training_size
  printf '%s' "$_TB_TRAINING_PROVENANCE"
}

# YAML single-quoted-scalar escaping, in one place (Saqlain review, #443).
#
# A YAML single-quoted string escapes a quote by DOUBLING it: a'b -> 'a''b'.
# Both directions must build the replacement from a VARIABLE, never a `\'`
# literal: bash 3.2 (the macOS system bash) keeps the backslash in an escaped-quote
# REPLACEMENT, so "${v//\'/\'\'}" yields a\'\'b and corrupts the value. A variable
# expands to a bare quote on 3.2 and 4/5 alike. Verified on GNU bash 3.2.57:
#   input a'b -> escaped-literal form a\'\'b (WRONG) · variable form a''b (right)
#
# Keep these two as the ONLY place that rule is encoded — every credential written
# into or read back out of the generated values file goes through them, so the
# portability constraint can't drift between call sites.
_yaml_sq_escape() {                      # raw value -> body of a '...' scalar
  local _sq="'"
  printf '%s' "${1//$_sq/$_sq$_sq}"
}
_yaml_sq_unescape() {                    # body of a '...' scalar -> raw value
  local _sq="'"
  printf '%s' "${1//$_sq$_sq/$_sq}"
}

# _extract_yaml_value — value of top-level scalar key $2 in values file $1.
# CONTRACT: echoes nothing and returns 0 when the key is absent (or the file is
# unreadable). Callers rely on "empty means no value"; they must not have to
# distinguish absent-key from read-error, and none of them do.
_extract_yaml_value() {
  local file="$1" key="$2"
  local line
  # `|| line=""`: on an ABSENT key grep exits 1 and, under `set -o pipefail`,
  # that rc propagates out of the pipeline and out of the assignment — so under
  # `set -e` the installer would abort HERE and never reach the empty-check on
  # the next line, the very line that exists to handle "key not found" (#523).
  # Latent until now only because every call site wraps this in `$( )`, which
  # suspends errexit for the function body; a bare call aborts the install
  # mid-step. Same house idiom as assess.sh / common.sh `_chart_version`.
  #
  # NO `| head -1` on the pipeline: with head in play, a DUPLICATE key makes
  # head exit after the first line and SIGPIPE grep (141) — and under pipefail
  # `|| line=""` would then wipe the successfully captured value, so
  # detect_installed_client could miss a clientId and fail open toward
  # overwrite (Bugbot, #525). Capture every match, then take the first line in
  # the shell, where nothing can signal anything: grep's rc is 1 only when
  # there is genuinely no match.
  line=$(grep -E "^${key}:" "$file" 2>/dev/null) || line=""
  line="${line%%$'\n'*}"
  [[ -z "$line" ]] && return
  line="${line#*:}"
  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" == \'*\' ]]; then
    line="${line#\'}"
    line="${line%\'}"
    line="$(_yaml_sq_unescape "$line")"
  else
    line="${line#\"}"
    line="${line%\"}"
  fi
  # Defend against self-perpetuation: a previous corrupted save may have the
  # bracketed-paste markers and/or C0 controls (#168). _strip_paste_garbage
  # handles both. UTF-8 (0x80+) preserved.
  _strip_paste_garbage "$line"
}

# _client_id_from_secret — CLIENT_ID out of release $1's chart-managed Secret in
# namespace $2, or empty. THE SECOND PLACE THE ID CAN LIVE: backend#2571 lets
# clientId resolve from the Secret instead of release values, and the chart now
# recommends dropping it from values once it is there — so "no clientId in
# values" stopped meaning "not a client" and detect_installed_client has to look
# here before it may conclude anything.
# CONTRACT: echoes the id or nothing, and ALWAYS returns 0. Callers assign it
# inside `$( )`; a non-zero rc there would abort the installer under `set -e`
# (the same trap _extract_yaml_value documents above), and "couldn't read it" is
# a state the caller handles, not an error it should die on.
_client_id_from_secret() {
  local rel="$1" ns="$2" b64 out=""
  # kubectl is not guaranteed this early (the pre-provision pre-flight runs
  # before the cluster exists), and its absence is "couldn't read", not "absent".
  has kubectl || return 0
  # BOUNDED, because this call is now on the COMMON path (Bugbot, #859). Once
  # clientId is dropped from release values — which this chart recommends — every
  # scanned release reaches here, so an unbounded read against a wedged API would
  # hang a headless install or assess with no further output. kubectl's default
  # is no timeout at all; 5s matches the other existence probes in this repo
  # (install-k8s.ps1's namespace/daemonset/allocatable reads). A timeout exits
  # non-zero and is handled by the same `|| return 0` as any other unreadable
  # Secret: "couldn't read it" is a state the caller already knows how to treat,
  # and the caller's fail-closed path turns it into an unidentifiable client
  # rather than an absent one.
  b64="$(kubectl -n "$ns" get secret "${rel}-secrets" -o "jsonpath={.data.CLIENT_ID}" --request-timeout=5s 2>/dev/null)" || return 0
  [[ -n "$b64" ]] || return 0
  # -d is GNU/coreutils and modern macOS; -D is the older BSD spelling. Same
  # both-spellings idiom as scripts/tests/gpu-embed-drift.bats.
  out="$(printf '%s' "$b64" | base64 -d 2>/dev/null)" \
    || out="$(printf '%s' "$b64" | base64 -D 2>/dev/null)" \
    || out=""
  printf '%s' "$out"
  return 0
}

# detect_installed_client — report the tracebloc client already installed on this
# cluster, if any, via the globals INSTALLED_CLIENT_ID / INSTALLED_CLIENT_NS
# (both empty when none is found). Enumerate client-chart releases across ALL
# namespaces WITHOUT jq (not a guaranteed prerequisite): helm's NAME/NAMESPACE are
# the first two whitespace-free columns and the CHART column matches
# `client-<ver>`, the same jq-free parse _chart_version uses. Shared by the
# pre-provision ownership pre-flight (#303) and the Helm-step one-client guard so
# the two can never disagree on "what already runs here". Always returns 0. A
# missing helm just yields the empty (no-client) result — but a helm/API FAILURE
# is reported as INSTALLED_CLIENT_UNKNOWN=1 (not "no client"), so guards can fail
# CLOSED instead of silently overwriting a client they couldn't see. The id is
# read from release values first and from the release Secret second
# (_client_id_from_secret): since backend#2571 either place is legitimate, and a
# client-chart release that names an id in NEITHER is UNKNOWN, not absent.
detect_installed_client() {
  INSTALLED_CLIENT_ID=""; INSTALLED_CLIENT_NS=""; INSTALLED_CLIENT_UNKNOWN=0
  # No helm => nothing helm-installed here; a genuine (documented) "no client".
  has helm || return 0
  local _gvf _rel _ns _id _list _unreadable=0
  # A mktemp failure is an environment error, NOT proof of "no client here" — flag
  # UNKNOWN so the guards fail closed rather than skip. Fall back to a path in a
  # dir we own (never a predictable world-writable /tmp path under sudo) before
  # giving up.
  _gvf="$(mktemp 2>/dev/null)" || _gvf="${HOST_DATA_DIR:+${HOST_DATA_DIR}/.tb-detect-values.$$}"
  [[ -n "$_gvf" ]] || { INSTALLED_CLIENT_UNKNOWN=1; return 0; }
  # Capture `helm list`'s exit code: a FAILED enumeration (wedged/unreachable API,
  # kubeconfig glitch) must NOT read as "no client here" — that fails OPEN and lets
  # a re-install silently overwrite an existing client. `helm list` returns 0 with
  # empty output when there are genuinely no releases, so only a non-zero exit is
  # "unknown".
  # Name the states explicitly (#554): Helm 3 lists only deployed by default while
  # Helm 4 (the pinned v4.2.3) lists all — so relying on the default hides a wedged
  # client on one version or the other. We enumerate the full "a client is present"
  # set — deployed, failed, and every wedge state (pending-*, uninstalling) that
  # _recover_pending_helm_release knows how to clear — so a killed-mid-flight client
  # stays visible and the one-client guard can't wave through an overwrite.
  if ! _list="$(helm list -A --deployed --failed --pending --uninstalling 2>/dev/null)"; then
    INSTALLED_CLIENT_UNKNOWN=1; rm -f "$_gvf"; return 0
  fi
  while read -r _rel _ns; do
    [[ -z "$_rel" ]] && continue
    if helm get values "$_rel" -n "$_ns" > "$_gvf" 2>/dev/null; then
      _id="$(_extract_yaml_value "$_gvf" clientId)"
      # VALUES READABLE BUT NO clientId IS NO LONGER "not a client" (backend#2571,
      # Bugbot #859). clientId stopped being `required` and the chart now tells
      # operators to drop it from release values once the Secret carries it — so
      # under the new contract a perfectly live client legitimately has no
      # clientId in its values, and reading that as "not a match" let the
      # one-client guard wave through an install that re-points the machine.
      # Fall back to where the id now lives.
      [[ -z "$_id" ]] && _id="$(_client_id_from_secret "$_rel" "$_ns")"
      [[ -n "$_id" ]] && { INSTALLED_CLIENT_ID="$_id"; INSTALLED_CLIENT_NS="$_ns"; break; }
      # A client-chart release with no id in EITHER place is a client we cannot
      # NAME, not an absent one. Record it and keep scanning; if nothing else
      # names one, the fail-closed check below reports UNKNOWN.
      _unreadable=1
    else
      # Couldn't read THIS client release's values -> an UNIDENTIFIABLE client.
      # Record it and keep scanning (a later release may give a definitive id);
      # if none does, fail closed below rather than read it as "no client here".
      _unreadable=1
    fi
  done < <(printf '%s\n' "$_list" | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  # A client release existed but we couldn't read its clientId, and no OTHER
  # release gave a definitive id -> unknown (parity with the PowerShell guard's
  # $unreadableNs fail-closed path).
  [[ -z "$INSTALLED_CLIENT_ID" && "$_unreadable" == 1 ]] && INSTALLED_CLIENT_UNKNOWN=1
  rm -f "$_gvf"
  return 0
}

# _strip_paste_garbage now lives in common.sh (shared with provision.sh's client-
# name prompt); install-k8s.sh sources common.sh before this file, so it's in
# scope here for _sanitize_credential below.

# Sanitize a user-entered credential. Calls _strip_paste_garbage and notifies
# the user on stderr (NOT stdout — this function is called from inside $(...),
# so stdout is captured into the credential value itself).
_sanitize_credential() {
  local input="$1"
  local clean
  clean=$(_strip_paste_garbage "$input")
  if [[ "$clean" != "$input" ]]; then
    warn "Stripped non-printable / paste-mode characters from input." >&2
  fi
  printf '%s' "$clean"
}

# Sanitize workspace name to comply with DNS-1123 (lowercase, alphanumeric + hyphens)
_sanitize_workspace_name() {
  local input="$1"
  local sanitized
  sanitized=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  sanitized="${sanitized// /-}"
  sanitized="${sanitized//_/-}"
  sanitized=$(printf '%s' "$sanitized" | sed 's/[^a-z0-9-]//g')
  sanitized=$(printf '%s' "$sanitized" | sed 's/--*/-/g')
  sanitized=$(printf '%s' "$sanitized" | sed 's/^-//; s/-$//')
  if [[ -z "$sanitized" ]]; then
    sanitized="default"
  fi
  if [[ ${#sanitized} -gt 63 ]]; then
    sanitized="${sanitized:0:63}"
    sanitized=$(printf '%s' "$sanitized" | sed 's/-$//')
  fi
  printf '%s' "$sanitized"
}

# ── Credential verification (#717) ────────────────────────────────────────
# Resolve the backend base URL the same way jobs-manager does
# (client-runtime/controller.py: CLIENT_ENV → backend), defaulting to prod.
_backend_url() {
  # Reduce aliases FIRST (backend#1745): a raw `staging` fell through to the
  # prod branch, so verify_credentials() checked staging credentials against
  # the production backend and reported them invalid.
  case "$(tb_client_env "${CLIENT_ENV:-prod}")" in
    dev) printf 'https://dev-api.tracebloc.io/' ;;
    stg) printf 'https://stg-api.tracebloc.io/' ;;
    *)   printf 'https://api.tracebloc.io/' ;;
  esac
}

# Validate the entered Client ID / password against the backend's
# api-token-auth/ endpoint — the same call jobs-manager makes at runtime —
# using curl (already a dependency). Echoes: valid | invalid | inactive | unverified.
verify_credentials() {
  local client_id="$1" client_password="$2" backend code
  backend="$(_backend_url)"
  # SECURITY: never put the password on curl's argv — it would be world-readable
  # via `ps` / /proc/<pid>/cmdline for the request's lifetime, and tracebloc runs
  # on shared institutional/on-prem compute where a co-tenant could scrape it
  # (CWE-214). Feed it through stdin instead: `--data-urlencode password@-` reads
  # the value from stdin and URL-encodes it, so the secret never appears in the
  # process table. `printf '%s'` is a bash builtin (no fork, no argv exposure) and
  # emits no trailing newline (a here-string `<<<` would append one and corrupt
  # the password). The username (client_id, a UUID) isn't secret, so it stays inline.
  # curl_secure (not bare curl) pins the minimum TLS version: this request carries
  # the client's password, and a TLS-inspecting proxy in front of it would happily
  # negotiate whatever the client accepts (backend#1252). -m 60 keeps the tighter
  # deadline this call already had.
  code=$(printf '%s' "$client_password" | curl_secure -sS -m 60 -o /dev/null -w '%{http_code}' \
    --data-urlencode "username=${client_id}" \
    --data-urlencode "password@-" \
    "${backend}api-token-auth/" 2>/dev/null) || code="000"
  case "$code" in
    200) printf 'valid' ;;
    400) printf 'invalid' ;;
    401) printf 'inactive' ;;
    *)   printf 'unverified' ;;   # 429 throttled, 000 unreachable, 5xx, …
  esac
}

# ── Corporate-proxy passthrough into the chart (#242) ───────────────────────
# cluster.sh propagates the host's HTTP(S)_PROXY to the k3d *nodes* so
# containerd can pull images behind a corporate proxy (#166). But the client
# *workloads* — jobs-manager (api + pods-monitor), requests-proxy, the
# image-refresh / auto-upgrade cronjobs — only get proxy egress if the CHART
# renders it, and the chart's tracebloc.proxyEnv helper is driven by the SPLIT
# keys (HTTP_PROXY_HOST/_PORT/_USERNAME/_PASSWORD), not a raw HTTP_PROXY URL.
# Without them every backend-dialing pod CrashLoopBackOffs on api-token-auth/
# behind a corporate proxy (observed on a hospital / proxy-only tenant, 2026-06-09). This fills the workload half
# of #166 that node-level propagation alone missed.
#
# We deliberately emit the SPLIT form, not a raw env.HTTP_PROXY: on the released
# 1.6.0 chart a raw env.HTTP_PROXY with no HTTP_PROXY_HOST is dropped by the
# #236 proxy-key exclusion (the #238 regression). HTTP_PROXY_HOST drives
# proxyEnv and is correct on every released chart.
#
# Reads the first set of HTTP_PROXY/HTTPS_PROXY (upper- then lower-case);
# supports authenticated proxies (http://user:pass@host:port), splitting on the
# LAST '@' so a ':' or '@' inside the password is tolerated. Echoes YAML lines
# for the env: block (each prefixed with a newline, 2-space indent), or nothing
# when the host has no proxy set.
_chart_proxy_env_yaml() {
  local raw="" var
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ -n "${!var:-}" ]]; then raw="${!var}"; break; fi
  done
  [[ -z "$raw" ]] && return 0

  local rest="${raw#*://}"      # strip scheme
  rest="${rest%%/*}"            # strip any trailing /path
  local creds="" hostport="$rest" host port="" user="" pass=""
  if [[ "$rest" == *"@"* ]]; then
    creds="${rest%@*}"          # everything before the LAST '@'
    hostport="${rest##*@}"      # host:port after the LAST '@'
  fi
  host="${hostport%%:*}"
  [[ "$hostport" == *:* ]] && port="${hostport##*:}"
  [[ -z "$host" ]] && return 0
  if [[ -n "$creds" ]]; then
    user="${creds%%:*}"
    [[ "$creds" == *:* ]] && pass="${creds#*:}"
  fi

  printf '\n  HTTP_PROXY_HOST: "%s"' "$host"
  [[ -n "$port" ]] && printf '\n  HTTP_PROXY_PORT: "%s"' "$port"
  [[ -n "$user" ]] && printf '\n  HTTP_PROXY_USERNAME: "%s"' "$user"
  [[ -n "$pass" ]] && printf '\n  HTTP_PROXY_PASSWORD: "%s"' "$pass"
  # Pass the host's NO_PROXY through; tracebloc.proxyEnv unions it with the
  # cluster-internal bypass list (mirrors cluster.sh's node-side _augment_no_proxy).
  local hostnp="${NO_PROXY:-${no_proxy:-}}"
  [[ -n "$hostnp" ]] && printf '\n  NO_PROXY: "%s"' "$hostnp"
  return 0
}

# _image_mirror_yaml — emit the top-level chart values that point every image the
# chart pulls at a private registry mirror (#585 / restricted-network installs).
# TRACEBLOC_IMAGE_REGISTRY sets global.imageRegistry: the chart's
# global.imageRegistry convention re-homes tracebloc/*, the spawned ingestor and
# training-job images, and the alpine/* + ubuntu/squid utility images onto that
# host, so an air-gapped / mirror-only network pulls nothing from a public
# registry. When the mirror needs authentication, TRACEBLOC_REGISTRY_USERNAME /
# TRACEBLOC_REGISTRY_PASSWORD also mint the chart's imagePullSecret
# (dockerRegistry), whose server defaults to the mirror host. Emits nothing when
# no mirror is configured, so a default install's values are unchanged.
_image_mirror_yaml() {
  local mirror="${TRACEBLOC_IMAGE_REGISTRY:-}"
  local reg_user="${TRACEBLOC_REGISTRY_USERNAME:-}"
  local reg_pass="${TRACEBLOC_REGISTRY_PASSWORD:-}"
  [[ -z "$mirror" && -z "$reg_user" && -z "$reg_pass" ]] && return 0

  # global.imageRegistry is a BARE host (mirror.corp.example[:port]) — it becomes the
  # prefix of every image reference, so strip a pasted scheme to keep <host>/repo
  # well-formed.
  local mirror_host="${mirror#*://}"

  if [[ -n "$mirror_host" ]]; then
    printf '\nglobal:\n  imageRegistry: '\''%s'\''\n' "$(_yaml_sq_escape "$mirror_host")"
  fi
  if [[ -n "$reg_user" || -n "$reg_pass" ]]; then
    # dockerRegistry.server is the imagePullSecret's auths key and the chart schema
    # REQUIRES it whenever create is true (format:uri), so it must ALWAYS be
    # emitted here. Precedence: an explicit TRACEBLOC_REGISTRY_SERVER wins (e.g. a
    # registry whose auth realm differs from the image host); else derive
    # https://<mirror-host> when a mirror is set; else fall back to Docker Hub so
    # creds-only (authenticate to docker.io, no mirror) still renders a valid
    # secret instead of a schema error.
    local server="${TRACEBLOC_REGISTRY_SERVER:-}"
    if [[ -z "$server" ]]; then
      if [[ -n "$mirror_host" ]]; then
        server="https://$mirror_host"
      else
        server="https://index.docker.io/v1/"
      fi
    fi
    printf '\ndockerRegistry:\n  create: true\n'
    printf '  server: '\''%s'\''\n' "$(_yaml_sq_escape "$server")"
    printf '  username: '\''%s'\''\n' "$(_yaml_sq_escape "$reg_user")"
    printf '  password: '\''%s'\''\n' "$(_yaml_sq_escape "$reg_pass")"
    printf '  email: '\''%s'\''\n' "$(_yaml_sq_escape "${TRACEBLOC_REGISTRY_EMAIL:-}")"
  fi
  return 0
}

# _resolve_chart_ref — resolve the chart reference (local dev path or remote repo)
# and set `chart_ref` in the caller's scope (bash dynamic scope). Extracted so a
# fresh install and an adopt reconcile resolve it identically. Logging is a side
# effect only — never command-substitute this (that would capture the log lines).
_resolve_chart_ref() {
  if [[ -n "${TRACEBLOC_CHART_PATH:-}" ]]; then
    [[ -d "$TRACEBLOC_CHART_PATH" ]] || error "TRACEBLOC_CHART_PATH not found: $TRACEBLOC_CHART_PATH"
    chart_ref="$TRACEBLOC_CHART_PATH"
    info "Dev mode: using local chart at $chart_ref"
    log "Using local chart: $chart_ref"
  else
    # Capture-then-match (backend#1778): `helm repo list | grep -q` lets grep
    # close the pipe on its first hit, helm takes SIGPIPE and pipefail makes it
    # 141 — which the `if !` reads as "repo absent" and re-runs `helm repo add`
    # on the next line. That line is unguarded, and `helm repo add` fails when
    # the name already exists with a different URL, so the misbranch escalates
    # into an aborted install under `set -e`.
    local _helm_repos
    _helm_repos="$(helm repo list 2>/dev/null || true)"
    if ! grep -q "^${TRACEBLOC_HELM_REPO_NAME}[[:space:]]" <<<"$_helm_repos"; then
      log "Adding Helm repo: $TRACEBLOC_HELM_REPO_URL"
      helm repo add "$TRACEBLOC_HELM_REPO_NAME" "$TRACEBLOC_HELM_REPO_URL" >> "${LOG_FILE:-/dev/null}" 2>&1
    fi
    log "Updating Helm repos..."
    helm repo update >> "${LOG_FILE:-/dev/null}" 2>&1
    chart_ref="$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME"
  fi
}

# _recover_pending_helm_release — auto-clear a wedged pending-* release before a
# helm upgrade/install (#554). A helm process killed mid-operation (Ctrl-C, OOM,
# host reboot, laptop sleep) leaves the release stuck in a transient state; every
# subsequent `helm upgrade --install` then fails with "another operation is in
# progress" — exit 1, NOT 124 — a permanent wedge that no re-run can clear on its
# own. Detect that state and clear it so the caller's helm op can proceed.
#
#   $1 = release name   $2 = namespace
#   $3 = mode: "full" (default) or "no-destroy" (see below)
#
# Reads the STATUS: line of `helm status` (jq-free on purpose — parsed the same
# way the auto-upgrade cronjob does, whose alpine/helm image ships without jq):
#   deployed / failed / superseded / uninstalled / "" → healthy or absent; no-op
#   pending-upgrade / pending-rollback → roll back to the last deployed revision
#   pending-install                    → revision 1 never deployed; there is no
#                                        good revision to roll back to, so remove
#                                        the half-installed release (matches the
#                                        first-install manual remedy we already
#                                        print). Safe for data: the chart renders
#                                        helm.sh/resource-policy: keep on every
#                                        PVC/namespace, and helm reads that from
#                                        the STORED rev-1 manifest, so uninstall
#                                        leaves the PVCs in place (docs/MIGRATIONS).
#   uninstalling                       → a killed `helm uninstall`; finish it.
#
# mode="no-destroy" (the adopt/reconcile path, #554 Bugbot): rollback is still
# performed (non-destructive — it restores a deployed revision, so the reconcile's
# --reuse-values stays valid), but the destructive uninstall branch is REFUSED
# (returns 1). Adopt reuses the release's STORED credential (the account password
# is write-only on the backend and lives only in that release); uninstalling a
# pending-install there would silently drop it. Better to fail closed with a
# manual remedy than to auto-destroy the sole copy of the credential.
#
# Returns 0 when the release is clear (or was already), non-zero when recovery was
# attempted and FAILED, or was refused under no-destroy — the caller must fail
# closed rather than march into the same wedge.
_recover_pending_helm_release() {
  local _rel="$1" _ns="$2" _mode="${3:-full}" _status
  # Bound the status READ (#554 Bugbot): every helm/kubectl probe in this installer
  # must be bounded so a wedged/unreachable API can't hang a headless run — and
  # this read gates everything below, so bounding it bounds the whole recovery. A
  # timeout (or any error) yields an empty status → no-op → we hand off to the
  # bounded upgrade, which surfaces the API failure with its own deadline. The
  # mutating ops below are NOT wrapped in a kill-based bound on purpose: SIGKILLing
  # a helm rollback/uninstall midway would recreate the very pending-* wedge we are
  # clearing. rollback is a fast metadata write (and only runs once this read has
  # proven the API responsive); uninstall is bounded gracefully by helm's own
  # --wait --timeout.
  # Capture the whole `helm status`, then parse it from a here-string — NEVER
  # through an early-exit awk pipeline. Under `set -o pipefail` awk's `exit`
  # SIGPIPEs helm (rc 141) as it writes the rest of the status body, and the
  # `|| _status=""` guard would then WIPE a perfectly good parse, silently
  # skipping recovery (#554 Bugbot; same SIGPIPE-under-pipefail lesson as
  # _extract_yaml_value). Here-string parsing can't signal anything.
  local _status_out
  _status_out="$(_bounded 30 helm status "$_rel" -n "$_ns" 2>/dev/null)" || _status_out=""
  _status="$(awk '/^STATUS:/ {print $2; exit}' <<<"$_status_out")"
  case "$_status" in
    pending-upgrade|pending-rollback)
      warn "A previous helm operation on '$_rel' was interrupted (status: $_status)."
      info "Rolling back '$_rel' to the last working release before continuing…"
      if ! helm rollback "$_rel" -n "$_ns" >> "${LOG_FILE:-/dev/null}" 2>&1; then
        warn "Automatic rollback of '$_rel' failed."
        return 1
      fi
      log "Recovered '$_rel' from $_status via helm rollback."
      ;;
    pending-install|uninstalling)
      warn "A previous helm operation on '$_rel' was interrupted (status: $_status)."
      if [[ "$_mode" == no-destroy ]]; then
        # Clearing pending-install/uninstalling can only be done by uninstalling
        # (a never-deployed revision can't be rolled back), which would drop this
        # client's stored credential — refuse on the reconcile path (#554 Bugbot).
        # rollback is NOT a remedy for these states, so print the credential-safe
        # manual path instead.
        warn "Clearing '$_rel' (status: $_status) needs an uninstall, which would drop this client's write-only stored credential — refusing to auto-recover it here."
        hint "Recover by hand without losing the credential:"
        hint "  helm -n $_ns get values $_rel   # save clientPassword first — it can't be re-fetched"
        hint "  helm -n $_ns uninstall $_rel    # then re-run the installer"
        return 1
      fi
      info "Clearing the half-finished release '$_rel' before continuing…"
      if ! helm uninstall "$_rel" -n "$_ns" --wait --timeout 5m >> "${LOG_FILE:-/dev/null}" 2>&1; then
        warn "Automatic cleanup of '$_rel' failed."
        return 1
      fi
      log "Recovered '$_rel' from $_status via helm uninstall."
      ;;
    ''|deployed|failed|superseded|uninstalled)
      : # healthy or absent — nothing to recover
      ;;
    *)
      log "helm status of '$_rel' is '$_status'; no pending-state recovery needed."
      ;;
  esac
  return 0
}

# _gpu_request_value — the GPU resource a spawned training pod should request,
# keyed to the vendor (backend#2033). Each vendor advertises its card as a different
# Kubernetes resource, so the request key must match: nvidia.com/gpu for nvidia,
# amd.com/gpu for amd, empty (→ CPU) otherwise. Single source of truth so the
# values-write path (install_client_helm) and the adopt/reconcile path
# (_reconcile_adopted_client) can never disagree — the reconcile path reused the
# release's stored values and kept an AMD edge on an empty request, training on
# CPU while the node's GPU read "verified".
#
# NVIDIA is additionally gated on the GPU being WIRED into the cluster (client#835,
# _gpu_wired): requesting nvidia.com/gpu on a node that advertises 0 GPUs strands
# every job Pending, so a detected-but-not-wired NVIDIA host requests nothing (CPU).
# AMD has no k3d wiring step (it uses the device plugin only), so it stays keyed on
# detection.
_gpu_request_value() {
  case "${GPU_VENDOR:-}" in
    nvidia) if _gpu_wired; then printf 'nvidia.com/gpu=1'; fi ;;
    amd)    printf 'amd.com/gpu=1' ;;
    *)      printf '' ;;
  esac
  return 0
}

# _reconcile_adopted_client — RFC-0001 §7.2 adopt path. provision_client (Step 3)
# sets TRACEBLOC_CLIENT_ADOPTED=1 when `tracebloc client create` matched this cluster
# to an EXISTING client on the account (get-or-create keyed on the cluster). Adopt
# issues no new password — the existing one stands (write-only on the backend) — so
# there is nothing to prompt for or verify. Reconcile the live release in place,
# reusing its stored credential, and heal the stored clientId to the adopted UUID:
# installs from the cli#125 window stored the numeric dashboard id, which can't
# authenticate. Returns 0 on a successful reconcile; non-zero (caller falls back to
# the normal connect flow) when no live tracebloc release is found to reconcile.
_reconcile_adopted_client() {
  # provision_client (Step 3) hands over the adopted client id (UUID) + the marker on
  # adopt (no password — the existing credential stands). Find the live client release
  # and reconcile it in place. Enumerate it the same jq-free way the one-per-machine
  # guard does — the full deployed/failed/pending-*/uninstalling set (#554), so a
  # release wedged by a killed helm op is discovered instead of adopt falling through
  # to a password prompt it can't satisfy. One client per machine, so take the first.
  local _rel="" _ns="" _r _n
  while read -r _r _n; do
    [[ -n "$_r" ]] && { _rel="$_r"; _ns="$_n"; break; }
  done < <(helm list -A --deployed --failed --pending --uninstalling 2>/dev/null | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  if [[ -z "$_rel" ]]; then
    warn "This client is already registered, but no live tracebloc release was found here to reconcile — continuing with a normal connect."
    return 1
  fi

  TB_NAMESPACE="$_ns"
  info "This machine already runs a tracebloc client — reconciling '${_rel}' (namespace '${_ns}') in place."

  _ensure_helm_runnable

  # backend#2146: the arch gate belongs on the adopt path too, BEFORE the engine is
  # deployed. Reconcile reuses the release's stored values (--reuse-values), so the
  # engine that will run is whatever the release already pins — read THAT (never a
  # fresh resolution, which could pick 8.4 on an arm64 host while Helm keeps the
  # release's amd64-only 5.7) and ask the same question the normal install path
  # asks. Without it, an arm64 host with no amd64 emulation adopting a 5.7 release
  # reported success and then CrashLooped: preflight had classified the machine as
  # fresh-8.4, so its early gate waved it through. existing-release is the accurate
  # reason (a live Helm release, not host files — see _assert_engine_runs_on_this_arch).
  if _release_pins_mysql_84 "$_rel" "$_ns"; then
    TB_MYSQL_ENGINE_RESOLVED="8.4"
  else
    TB_MYSQL_ENGINE_RESOLVED="5.7"
  fi
  TB_MYSQL_ENGINE_REASON="existing-release"
  _assert_engine_runs_on_this_arch

  local chart_ref=""
  _resolve_chart_ref

  # Reconcile in place, reusing the release's stored values (clientPassword +
  # install-time config). Prefer --reset-then-reuse-values (Helm >= 3.14: reset to
  # chart defaults, then re-apply the stored user values, picking up new chart
  # defaults); fall back to --reuse-values on older Helm.
  local _reuse="--reuse-values" _upgrade_help
  # Capture-then-match (backend#1778): `helm upgrade --help | grep -q` lets grep
  # close the pipe on its first hit, helm takes SIGPIPE and pipefail makes the
  # pipeline 141 — the `&&` then reads that as "flag unsupported" and the
  # reconcile silently keeps --reuse-values, so new chart defaults are never
  # picked up. helm's help is several KB written in chunks, and the flag sorts
  # early in the list, so this is the losing shape. `case` also drops the
  # `A && B` set -e subtlety this line used to carry.
  _upgrade_help="$(helm upgrade --help 2>/dev/null || true)"
  case "$_upgrade_help" in
    *'--reset-then-reuse-values'*) _reuse="--reset-then-reuse-values" ;;
  esac

  # Heal the stored clientId to the adopted UUID when provision_client handed one
  # over (export TRACEBLOC_CLIENT_ID on the adopt path): a cli#125-era install stored
  # the numeric dashboard id, which can't authenticate, and --reuse-values alone
  # would preserve it (the reused password is still correct). With no id (rebuilt
  # host / R7 orphan) reconcile WITHOUT a heal rather than bail — the existing
  # credential stands. Built as an array so the optional --set is bash-3.2 safe.
  local _args=(upgrade "$_rel" "$chart_ref" --namespace "$_ns" "$_reuse" --cleanup-on-fail)
  local _uuid; _uuid="$(_sanitize_credential "${TRACEBLOC_CLIENT_ID:-}")"
  [[ -n "$_uuid" ]] && _args+=(--set "clientId=$_uuid")

  # GPU keys are NOT --reuse-values-safe (backend#2033 + client#835). --reuse-values
  # carries forward a prior release's env.GPU_REQUESTS/GPU_LIMITS/RUNTIME_CLASS_NAME
  # and its gpu.devicePlugin block, so an adopted release keeps a STALE GPU decision:
  # a vendor-changed edge trains on the wrong resource, and an NVIDIA edge dropped to
  # CPU (reuse guard / CDI setup cleared K3D_GPU_FLAGS) keeps requesting a GPU and
  # strands jobs Pending while the summary says CPU. FORCE the GPU keys to THIS run's
  # decision — the SAME values the fresh write chooses (_gpu_request_value +
  # runtime_class) — mirroring the Windows twin's adopt-path --set-string. --set-string
  # so helm doesn't type-infer the value's '='/'/' or read dots as key navigation, and
  # it overrides the reused value; empty deliberately clears a stale request
  # (client-runtime#80: an explicit "" means "no GPU here").
  local _gpu_val _rtc=""
  _gpu_val="$(_gpu_request_value)"
  if _gpu_wired; then _rtc="nvidia"; fi
  _args+=(--set-string "env.GPU_REQUESTS=$_gpu_val"
          --set-string "env.GPU_LIMITS=$_gpu_val"
          --set-string "env.RUNTIME_CLASS_NAME=$_rtc")
  # Reconcile the device-plugin block too, matching the fresh write, so a stale one
  # can't linger: nvidia only when wired (needs the baked RuntimeClass), amd on
  # detection, else disabled.
  if _gpu_wired; then
    _args+=(--set "gpu.devicePlugin.enabled=true"
            --set "gpu.devicePlugin.vendor=nvidia"
            --set-string "gpu.devicePlugin.nvidia.runtimeClassName=nvidia")
  elif [[ "${GPU_VENDOR:-}" == "amd" ]]; then
    _args+=(--set "gpu.devicePlugin.enabled=true" --set "gpu.devicePlugin.vendor=amd")
  else
    _args+=(--set "gpu.devicePlugin.enabled=false")
  fi

  # node-local (RFC-0003 Option C) has no hostPath dirs to pre-create.
  [[ "${TB_STORAGE_MODE:-node-local}" != "node-local" ]] && _ensure_release_dirs "$_ns"

  # #554: clear any pending-* wedge left by a previously killed helm op before we
  # upgrade — otherwise this reconcile just fails with "another operation is in
  # progress". no-destroy: reconcile REUSES the release's stored credential (the
  # account password is write-only on the backend and lives only here), so only a
  # non-destructive rollback is allowed; a pending-install/uninstalling wedge is
  # refused rather than auto-uninstalled, which would drop that sole copy (#554
  # Bugbot). Fail closed with a manual remedy if recovery couldn't clear it.
  if ! _recover_pending_helm_release "$_rel" "$_ns" no-destroy; then
    # For a refused pending-install/uninstalling wedge the helper already printed
    # the credential-safe manual path; add a generic pointer for the other cases.
    hint "Confirm the release state, then re-run:  helm -n $_ns status $_rel"
    error "Reconcile blocked by an interrupted previous helm operation. Check the log for details: ${LOG_FILE:-}"
  fi

  # Reconcile blocks too — same spinner treatment (RFC-0002 §2), bounded so a
  # wedged kube-apiserver can't hang it forever (#426).
  local _helm_timeout_min
  _helm_timeout_min="$(tb_minutes_or "${TB_HELM_TIMEOUT_MIN:-}" 10)"
  local _helm_rc=0
  spin_cmd_bounded "$(( _helm_timeout_min * 60 ))" "Reconciling the existing client…" helm "${_args[@]}" || _helm_rc=$?
  if [[ "$_helm_rc" -ne 0 ]]; then
    # A helm op killed partway (timeout=124, or an in-progress wedge=exit 1) can
    # leave the release pending-*. The next run auto-recovers
    # (_recover_pending_helm_release), but name the manual unwedge too — on exit
    # 1, not only the 124 timeout (#554, extends Bugbot #442).
    hint "If a re-run reports 'another operation is in progress', unwedge the release first:"
    hint "  helm -n $_ns rollback $_rel    (returns to the previous, working release)"
    error "Reconcile of the existing client failed. Check the log for details: ${LOG_FILE:-}"
  fi

  kubectl config set-context --current --namespace "$_ns" >/dev/null 2>&1 || true
  return 0
}

# TB_TTY is where interactive credential prompts READ from. Under `curl … | bash`
# stdin is the piped script, not the terminal, so an unredirected `read` hits EOF
# and (under set -e) aborts the installer with an opaque failure — read the
# controlling terminal directly instead. Overridable so tests can feed canned
# input on stdin (TB_TTY=/dev/stdin).
: "${TB_TTY:=/dev/tty}"

# _tty_available: true when there's a terminal we can prompt on (TB_TTY readable).
# Mirrors provision.sh's _prompt_tty; defined locally because provision.sh is
# sourced conditionally and AFTER this file, so its helper may not exist when
# install_client_helm runs.
_tty_available() { [[ -r "$TB_TTY" ]]; }

# _no_interactive_creds_die: abort with actionable env-var guidance when we can't
# collect credentials interactively. Covers BOTH no-terminal-at-all AND a
# readable-but-dead-input tty (non-PTY ssh, an IDE terminal, a drained/queued
# tty): _tty_available only checks `-r`, so a `read <"$TB_TTY"` can still hit EOF
# and would otherwise abort opaquely under set -e (Bugbot / #326 review) — the
# same failure class the TB_TTY change set out to remove. Mirrors provision.sh,
# whose name read breaks on rc!=0 and falls through to the same guidance.
_no_interactive_creds_die() {
  error "No credentials supplied and no terminal to prompt on.
  Set TRACEBLOC_CLIENT_ID and TRACEBLOC_CLIENT_PASSWORD (find them at
  $(_dashboard_url)), then re-run — under \`curl … | bash\` the
  prompt cannot read your input."
}

# _download_services_progress NS — render an honest N-of-M count bar as the
# client's container images pull onto the node (the "services download" in step
# e). The only TRUTHFUL per-unit signal is how many containers report a populated
# imageID (image present) out of the total the pods declare — never a fabricated
# aggregate percentage. Best-effort, BOUNDED, and NON-FATAL: it must never block
# or fail the install — the authoritative readiness gate is wait_for_client_ready
# (step f). Skipped entirely when TB_NO_SERVICE_PROGRESS is set (the bats suite,
# where kubectl is mocked and a poll loop would hang) or kubectl is unavailable.
# Detect a PERMANENT image-pull failure among the namespace's pods, so the progress
# copy can tell the truth instead of "still downloading" (#425). On a visible pull
# failure it prints the concrete pod status line(s) + the matching pull event and
# returns 0; when no pull failure is visible it prints nothing and returns 1.
# Bounded + non-fatal; mirrors summary.sh::_diagnose_not_ready's pull signals but is
# self-contained so it needs no cross-lib sourcing.
_pull_failure_detail() {
  local ns="$1" kube_timeout="${TB_PROGRESS_KUBECTL_TIMEOUT:-5s}" pods bad events pull_fail
  has kubectl || return 1
  [[ -n "$ns" ]] || return 1
  pods="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" 2>/dev/null || true)"
  bad="$(printf '%s\n' "$pods" | grep -iE 'ImagePullBackOff|ErrImagePull|InvalidImageName' || true)"
  [[ -n "$bad" ]] || return 1
  events="$(kubectl get events -n "$ns" --request-timeout="$kube_timeout" 2>/dev/null || true)"
  # Scope to the PULL-failure events only (like summary.sh::_diagnose_not_ready and the
  # PowerShell path) — never a bare x509/TLS match: kubectl prints one event per line,
  # so an x509 on a pull-failure line is already captured here, while an UNRELATED x509
  # event elsewhere in the ns must not, via tail, displace the real reason (#425 Bugbot).
  pull_fail="$(printf '%s\n' "$events" | grep -iE 'failed to pull|ErrImagePull' | tail -n 3 || true)"
  # Cap the failing-pod lines (like the PowerShell path's Select-Object -First 3) so a
  # cluster with many stuck pods doesn't print a wall of indented lines (reviewer).
  # Herestring, NOT `printf … | head -n 3`: under `set -o pipefail` head closes the
  # pipe after its 3rd line, so a namespace with enough stuck pods to push `$bad`
  # past the ~64KB pipe buffer makes printf take SIGPIPE → the pipeline exits 141 →
  # with errexit live this function aborts HERE and drops the scoped pull event
  # below — the one actionable line (x509 / blocked registry / auth). Measured on
  # bash 5.2.21 + coreutils 9.4: 65,622 bytes is already enough. `<<<` reads from a
  # temp file, so there is no writer left to signal and no `|| true` to mask it.
  head -n 3 <<< "$bad"
  [[ -n "$pull_fail" ]] && printf '%s\n' "$pull_fail"
  return 0
}

# Pure: pick the honest end-of-progress outcome (#425). Prints one token:
#   done       — every container has an image (pulled >= total)
#   failed     — a permanent pull failure is visible (has_fail non-empty)
#   downloading— no failure, but pulls demonstrably progressed (max_pulled > 0)
#   stalled    — nothing pulled and no failure signal yet (pods stuck Pending, etc.)
# A permanent failure NEVER maps to "downloading", so it can't be sold as background
# progress. Kept pure so the decision is unit-testable without a live cluster.
_progress_end_message() {
  local pulled="$1" total="$2" max_pulled="$3" has_fail="$4"
  if (( pulled >= total )); then printf 'done'; return; fi
  if [[ -n "$has_fail" ]];  then printf 'failed'; return; fi
  if (( max_pulled > 0 ));   then printf 'downloading'; return; fi
  printf 'stalled'
}

_download_services_progress() {
  local ns="$1"
  if [[ -n "${TB_NO_SERVICE_PROGRESS:-}" ]]; then return 0; fi
  has kubectl || return 0
  [[ -n "$ns" ]] || return 0

  # Every kubectl call is bounded with --request-timeout so a wedged/unreachable
  # API can never make the poll BLOCK — the between-iteration deadline check below
  # only fires if kubectl actually returns, so an unbounded call would hang step e
  # forever despite TB_PULL_TIMEOUT. Overridable; mirrors assess.sh's bounded probe.
  local kube_timeout="${TB_PROGRESS_KUBECTL_TIMEOUT:-5s}"

  # Establish the total container count once the pods are scheduled (bounded).
  local total=0 tries=0
  while (( tries < 15 )); do
    total="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" \
      -o jsonpath='{range .items[*].spec.containers[*]}{"x"}{end}' 2>/dev/null \
      | tr -cd 'x' | wc -c | tr -d ' ')" || total=0
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    if (( total > 0 )); then break; fi
    tries=$(( tries + 1 )); sleep 2
  done
  if (( total < 1 )); then return 0; fi   # never saw pods — skip the bar silently

  local deadline pulled=0 max_pulled=0
  deadline=$(( $(date +%s) + ${TB_PULL_TIMEOUT:-300} ))
  tput civis 2>/dev/null || true
  while :; do
    pulled="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" \
      -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' 2>/dev/null \
      | grep -c '.')" || pulled=0
    [[ "$pulled" =~ ^[0-9]+$ ]] || pulled=0
    if (( pulled > total )); then pulled=$total; fi
    if (( pulled > max_pulled )); then max_pulled=$pulled; fi
    count_bar "$pulled" "$total" "services"
    if (( pulled >= total )); then break; fi
    if (( $(date +%s) >= deadline )); then break; fi
    sleep 2
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true

  # Tell the truth on timeout: a permanent pull failure (x509/blocked registry/auth)
  # must NOT be sold as "downloading in the background" (#425). Classify, then print
  # copy that matches reality; the authoritative diagnosis still follows in the
  # readiness gate + summary.
  local fail_detail="" outcome
  if (( pulled < total )); then fail_detail="$(_pull_failure_detail "$ns" || true)"; fi
  outcome="$(_progress_end_message "$pulled" "$total" "$max_pulled" "$fail_detail")"
  case "$outcome" in
    done)
      success "Downloaded — ${total} services" ;;
    failed)
      # Soften the wording (reviewer): ImagePullBackOff can also be a transient blip /
      # registry 429 that kubelet keeps retrying, so wait_for_client_ready may still
      # reach "connected" — don't state an absolute that a later ✔ could contradict.
      warn "Some images look stuck pulling — this usually needs action, not just more time:"
      printf '%s\n' "$fail_detail" | sed 's/^/      /'
      info "Likely a blocked registry, an untrusted TLS-inspection CA, or auth — see the diagnosis below." ;;
    downloading)
      info "Services are still downloading — they'll finish starting in the background." ;;
    stalled)
      info "Services haven't started pulling yet — see the diagnosis below if this persists." ;;
  esac
  return 0
}

# ── MySQL engine channel (backend#723, decision A2 2026-08-05) ─────────────
# The chart's frozen 5.7 digest pin stays the default for every existing
# install; FRESH installs may opt into the multi-arch 8.4 engine. `auto`
# picks 8.4 only on a fresh arm64 install — the one cohort 5.7 actually hurts
# (amd64-only image under emulation). Anything that smells like existing
# state stays 5.7: an existing release, real mysql datadir content on the
# host (legacy or per-release layout), or nothing at all to suggest 8.4.
# A previous opt-in stays sticky across re-runs (the values file is
# regenerated every run, so it is re-derived from the old file first). The
# chart's mysql-format-guard init container backstops whatever this
# heuristic misses — a wrong pick fails loudly before mysqld starts, it
# never opens a datadir with the wrong engine.
#   TB_MYSQL_ENGINE=auto|5.7|8.4    explicit value always wins (default auto)
# Reads (bash dynamic scope, set by install_client_helm before the call):
# values_file, existing_id, HOST_DATA_DIR, TB_NAMESPACE, ARCH.
# Sets: TB_MYSQL_ENGINE_RESOLVED.
#
# Two of those inputs are `local`s of install_client_helm, which has NOT run at
# preflight time — so the helpers below derive them, and preflight's arch gate
# (backend#2047) calls the same helpers rather than restating the paths.
# Content test for a host mysql datadir, FAIL-CLOSED on unlistable dirs
# (mirrors _leftover_data_dirs, and the same Bugbot ownership case): a
# uid-999/root-owned dir the host user can't read/enter cannot be proven
# empty — treat it as content, so `auto` keeps 5.7 rather than opting a
# reused datadir into 8.4 that the format guard would then refuse to boot.
# Symlinks are never trusted as data (same stance as the leftover guard).
_mysql_dir_has_content() {
  local d="$1"
  [[ -d "$d" && ! -L "$d" ]] || return 1   # absent -> no content
  [[ -r "$d" && -x "$d" ]] || return 0     # unlistable -> fail closed
  [[ -n "$(ls -A "$d" 2>/dev/null)" ]]
}

# The generated values file install_client_helm reads (for the sticky 8.4
# check) and writes. Factored out of the `local values_file=…` it used to be so
# a caller running BEFORE install_client_helm — preflight's arch gate — resolves
# the same file instead of restating the path. A restated path would silently
# stop seeing an existing 8.4 opt-in the day this one moves.
_client_values_file() { echo "${TRACEBLOC_VALUES_FILE:-${HOST_DATA_DIR}/values.yaml}"; }

# The namespace this install will use when nothing else has determined one yet
# (an existing release can override it later — see install_client_helm). Same
# reason as above: preflight needs the per-release datadir path, which is
# HOST_DATA_DIR/<namespace>/mysql.
_client_default_namespace() { _sanitize_workspace_name "${TB_NAMESPACE:-tracebloc}"; }

# Whether the values on STDIN pin the MySQL 8.4 engine — i.e. the engine that will
# ACTUALLY run is 8.4. Reads STDIN so a caller streams a file (`< values.yaml`)
# rather than slurping it (the 60k-line fixture behind backend#1778). The ONE
# reader three callers share so they cannot drift on what "pins 8.4" means: the
# sticky rule below, the dev-mode TRACEBLOC_VALUES_FILE arch gate, and the
# adopt-reconcile arch gate (both backend#2146).
#
# STRUCTURAL, not a fixed line window (Asad, client#833 review). The chart's own
# client/values.yaml documents the 8.4 opt-in in a COMMENT several lines below the
# real `tag:` — literally `#   tag: "8.4"` — so a `grep -A N` is wrong in BOTH
# directions: too narrow misses the real tag and refuses a legitimate 8.4 opt-in on
# arm64; too wide reads that DECOY comment as the pin and skips the gate on a 5.7
# default (fail OPEN). So walk the indent-delimited mysqlClient block, drop comment
# and blank lines (the decoy goes with them), and read the real `tag:`/`digest:` by
# EXACT value — "8.40"/"8.4.1" are not 8.4. Handles the quoted form our heredoc
# writes (tag: "8.4") and the unquoted form `helm get values` re-serializes
# (tag: 8.4 — the #200 quote-stripping lesson).
#
# DIGEST WINS OVER TAG (Bugbot, client#833). tracebloc.image renders
# repository@<digest> when a digest is set and ignores the tag entirely, and the
# default pin is the amd64-only 5.7 image. So `tag: "8.4"` with a NON-empty digest
# actually runs whatever that (opaque sha256) digest is — which we cannot decode —
# not 8.4. Report 8.4 ONLY when tag is 8.4 AND the digest is AFFIRMATIVELY empty:
# the documented opt-in is exactly `tag: "8.4"` + `digest: ""`, which is how our own
# heredoc writes it. A set digest is treated as "not provably 8.4" so the 5.7 arch
# gate runs — fail closed, refuse rather than CrashLoop.
#
# AN ABSENT DIGEST IS NOT AN EMPTY ONE (Bugbot High, backend#2638 / client#838).
# This reader is fed PARTIAL views: `_release_pins_mysql_84` reads `helm get values`
# WITHOUT `--all`, which omits chart defaults, and a dev-mode overlay can carry only
# `mysqlClient.tag`. In both, the chart-default `digest` (the amd64-only 5.7 pin) is
# still what renders — `tracebloc.image` makes it win over the tag — yet the digest
# line is nowhere on STDIN. Treating that missing line as `digest: ""` reported a
# real 8.4 pin, skipped the 5.7 arch gate, and CrashLooped the amd64-only image on
# arm64. So we require the digest key to actually APPEAR and be empty (`sawdigest`);
# a digest we never saw is "not provably cleared" → not 8.4 → the 5.7 gate runs.
# (We deliberately do NOT switch the caller to `helm get values --all`: coalescing
# can re-default an operator's explicit `digest: ""` back to the chart's 5.7 pin,
# which would false-REFUSE a genuine 8.4 reconcile. Reading only supplied values and
# demanding an explicit empty digest is the fail-closed direction that costs nothing
# real — our heredoc always writes the explicit `digest: ""`.)
#
# Reads to EOF and decides in END — it never exits on first match, so a producer
# piping in (helm get values) is never SIGPIPE'd (backend#1778; the trap an early
# `exit`/`grep -q` would spring).
_values_pin_mysql_84() {
  awk '
    # 8.4 iff tag is 8.4 AND the digest was SEEN and is empty. sawdigest guards the
    # "absent digest is not an empty one" rule (backend#2638): a digest we never saw
    # on STDIN may still be a non-empty chart default that wins over the tag.
    function flush() { if (inblk && tag == "8.4" && sawdigest && digest == "") found = 1 }
    /^[[:space:]]*#/ { next }                      # comment line — drops the decoy
    /^[[:space:]]*$/ { next }                      # blank line
    { match($0, /^[[:space:]]*/); indent = RLENGTH }
    !inblk {
      if ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/) { inblk=1; base=indent; tag=""; digest=""; sawdigest=0 }
      next
    }
    {
      if (indent <= base) {                        # dedented out of the block
        flush()                                    # decide this block before leaving it
        inblk = ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/)
        if (inblk) { base=indent; tag=""; digest=""; sawdigest=0 }
        next
      }
      if ($0 ~ /^[[:space:]]*tag:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*tag:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)             # strip an inline comment
        gsub(/"/, "", v)                           # strip quotes (quoted or not)
        sub(/[[:space:]]+$/, "", v)
        tag = v
      } else if ($0 ~ /^[[:space:]]*digest:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*digest:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/"/, "", v)
        sub(/[[:space:]]+$/, "", v)
        digest = v
        sawdigest = 1                              # the key is present (empty or not)
      }
    }
    END { flush(); exit(found ? 0 : 1) }
  '
}

# Whether the live Helm release <rel> in namespace <ns> runs the MySQL 8.4 engine,
# read from its STORED values — adopt/reconcile keeps those via --reuse-values, so
# this is the engine that will actually run, not a fresh resolution. Bounded the
# way _existing_training_values bounds its read: `helm get values` has no request
# timeout, so gate it behind a bounded namespace probe and let a wedged API degrade
# to "not 8.4" (→ the 5.7 arch gate) instead of hanging. Unreadable is deliberately
# fail-closed: refuse an arm64 reconcile we cannot prove is 8.4 rather than report
# success and CrashLoop (the stance backend#2146 is about).
_release_pins_mysql_84() {
  local _rel="$1" _ns="$2" _vals
  [[ -n "$_rel" && -n "$_ns" ]] || return 1
  kubectl get namespace "$_ns" --request-timeout=5s >/dev/null 2>&1 || return 1
  _vals="$(helm get values "$_rel" -n "$_ns" 2>/dev/null || true)"
  _values_pin_mysql_84 <<<"$_vals"
}

# The engine decision itself, with NO logging and NO globals set, so a second
# caller can ask this rule a question instead of restating it (backend#2047:
# preflight's arch gate refused a fresh arm64 install that this rule was about
# to serve natively). Echoes "<engine> <reason>" — always exit 0, the reason
# carries the verdict:
#   5.7|8.4 explicit      an explicit TB_MYSQL_ENGINE=<value>
#   invalid <value>        TB_MYSQL_ENGINE is not auto|5.7|8.4
#   8.4 sticky             this machine already opted into 8.4
#   5.7 existing-release   a live Helm release (helm list), data format unknown
#   5.7 existing-datadir   real mysql datadir content on this host (non-empty)
#   5.7 amd64              fresh install on amd64 — keep the pinned 5.7 image
#   8.4 fresh              fresh install on non-amd64 — native multi-arch engine
_mysql_engine_decision() {
  local requested="${TB_MYSQL_ENGINE:-auto}"
  case "$requested" in
    5.7|8.4) echo "${requested} explicit"; return 0 ;;
    auto) ;;
    *) echo "invalid ${requested}"; return 0 ;;
  esac
  # Sticky: an edge that opted into 8.4 stays there on every later re-run.
  # _values_pin_mysql_84 streams the file (never slurps it), skips comments, and
  # reads to EOF — it owns the structural-vs-window and SIGPIPE reasoning
  # (backend#2146, backend#1778).
  if [[ -f "${values_file:-}" ]] && _values_pin_mysql_84 < "${values_file}"; then
    echo "8.4 sticky"; return 0
  fi
  # Never auto-flip existing state: a found release or real datadir content
  # means a 5.7-format datadir may exist, and 8.4 refuses to open it. Two
  # DISTINCT triggers, ordered MOST-SPECIFIC FIRST because their remedy differs:
  #
  #   datadir content — a non-empty mysql data directory on this host (the probe
  #     tests for content, NOT format). Checked first: when files exist the reason
  #     is 'existing-datadir' whether or not a release is also present, because
  #     there IS data here and a clean start means clearing the data dir (a
  #     release-only "uninstall" remedy would leave those files to re-pin 5.7 on
  #     the next run). An UNLISTABLE dir counts as content (fail closed; see the
  #     helper).
  #
  #   existing_id — a live Helm release from detect_installed_client (helm list
  #     -A + clientId) with NO host datadir files, e.g. TB_STORAGE_MODE=node-local
  #     where both probes are empty. Reason 'existing-release': 5.7 stays the safe
  #     default, but the gate must not claim host 5.7 data — and "uninstall the
  #     release" is a COMPLETE fresh-start remedy here precisely because no files
  #     remain to re-trigger the gate.
  #
  # The empty dirs _ensure_tracebloc_dirs just created don't count — only files.
  if _mysql_dir_has_content "${HOST_DATA_DIR:-/nonexistent}/mysql" \
    || _mysql_dir_has_content "${HOST_DATA_DIR:-/nonexistent}/${TB_NAMESPACE:-}/mysql"; then
    echo "5.7 existing-datadir"
    return 0
  fi
  if [[ -n "${existing_id:-}" ]]; then
    echo "5.7 existing-release"
    return 0
  fi
  case "${ARCH:-$(uname -m)}" in
    x86_64|amd64) echo "5.7 amd64" ;;
    *)            echo "8.4 fresh" ;;
  esac
}

# Dev-mode (TRACEBLOC_VALUES_FILE) engine resolution — DELIBERATELY not the auto
# rule above. When the caller supplies a values file, install_client_helm deploys
# it AS-IS and never generates the mysqlClient override the normal path writes, so
# the engine that RUNS is simply what the file declares: 8.4 iff it affirmatively
# pins 8.4 (_values_pin_mysql_84), else the chart default, which is the amd64-only
# 5.7 image. _mysql_engine_decision answers "8.4 fresh" for a fresh arm64 host
# PRECISELY because the normal path would generate that 8.4 override — one dev-mode
# never writes. Consulting the auto rule for a dev-mode install is what let
# backend#2854 pass preflight (auto -> 8.4 fresh, native, no gate) and then refuse
# after the cluster was already up (dev-mode -> 5.7). This helper is the ONE reader
# both the step-e install path and preflight's early arch gate share, so the two
# cannot drift. Fail-closed: a missing/unreadable file reads as 5.7 (refuse rather
# than false-pass). Echoes "<engine> values-file".
_devmode_engine_decision() {
  local vf="${TRACEBLOC_VALUES_FILE:-}"
  if [[ -n "$vf" && -f "$vf" ]] && _values_pin_mysql_84 < "$vf"; then
    echo "8.4 values-file"
  else
    echo "5.7 values-file"
  fi
}

# The logging wrapper around the rule above: sets TB_MYSQL_ENGINE_RESOLVED and
# narrates the choice. Kept separate so the rule can be consulted without
# emitting an install-time log line (preflight would otherwise log the engine
# choice minutes before the engine is chosen).
_resolve_mysql_engine() {
  local decision engine reason
  decision="$(_mysql_engine_decision)"
  engine="${decision%% *}"; reason="${decision#* }"
  if [[ "$engine" == "invalid" ]]; then
    error "TB_MYSQL_ENGINE must be 'auto', '5.7' or '8.4' (got '${reason}')"
  fi
  TB_MYSQL_ENGINE_RESOLVED="$engine"
  # WHY, not just what: the arch gate below needs to name the real cause, and
  # "existing datadir" vs "you asked for 5.7" are different fixes.
  TB_MYSQL_ENGINE_REASON="$reason"
  case "$reason" in
    explicit) log "MySQL engine: ${engine} (explicit TB_MYSQL_ENGINE)" ;;
    sticky)   log "MySQL engine: 8.4 (kept from this machine's existing values.yaml)" ;;
    fresh)    log "MySQL engine: 8.4 (fresh install on ${ARCH:-$(uname -m)} — native multi-arch engine, backend#723)" ;;
  esac
}

# ── The arch gate, asked where the engine is actually known (backend#2047) ────
# preflight's _pf_arch asks the same question early (that is the fast-fail), but
# it runs before the Helm release and the per-release namespace are known — so an
# existing edge can still look fresh there and only resolve to the amd64-only 5.7
# image here. Without this second ask, letting the fresh case through preflight
# would let that edge proceed to an exec-format CrashLoop with no earlier signal.
# Same conditions as _pf_arch: non-amd64, no emulation, no escape hatch — with a
# PER-OS emulation probe (binfmt on Linux, the Rosetta/Docker smoke on macOS).
#
# macOS IS covered here (client#756). This comment used to say the opposite —
# "this gate is Linux-only … deliberately out of scope" — and stayed behind when
# the Darwin arm landed below, which reads as "macOS is ungated" to anyone who
# trusts the prose over the code (backend#2208). On macOS this is the ONLY late
# gate: the early assert_amd64_emulation runs before helm, so it can only GUESS
# the engine and optimistically skips on an 8.4 guess; here the engine is
# resolved for real, and this is the fail-closed backstop that skip depends on.
#
# It probes the real host, so anything calling install_client_helm under test
# must declare OS/ARCH rather than inherit the machine — see install-client-helm.bats::setup.
_assert_engine_runs_on_this_arch() {
  [[ "${TB_MYSQL_ENGINE_RESOLVED:-}" == "5.7" ]] || return 0
  [[ -z "${TRACEBLOC_ALLOW_ARM64:-}" ]] || return 0
  case "${ARCH:-$(uname -m)}" in x86_64|amd64) return 0 ;; esac
  # arm64 + 5.7 needs amd64 emulation. Check it PER OS — binfmt on Linux, the
  # Rosetta/Docker smoke on macOS (binfmt does not exist there). This gate runs on
  # macOS too now (client#756): assert_amd64_emulation runs BEFORE helm and can
  # only GUESS the engine (existing_id needs a live release), so it optimistically
  # skips on an 8.4 guess. Here the engine is resolved for real — so on an arm64
  # Mac that actually resolved to 5.7 (an existing release the early gate could not
  # see) we re-verify emulation and refuse if it is missing. This is the fail-closed
  # backstop the early skip depends on.
  case "${OS:-}" in
    Linux)
      amd64_emulation_available && return 0
      ;;  # fall through to the Linux (binfmt) reason-messages below
    Darwin)
      declare -F _macos_amd64_emulation_ok >/dev/null 2>&1 && _macos_amd64_emulation_ok && return 0
      # Emulation missing (or the smoke helper somehow absent): the macOS Rosetta
      # remedy, then exit. Do NOT fall through to the binfmt messages below.
      declare -F _macos_amd64_refusal >/dev/null 2>&1 && _macos_amd64_refusal
      error "MySQL 5.7 is required here, but amd64 emulation could not be verified on this Apple Silicon Mac — enable Rosetta and re-run (or set TRACEBLOC_ALLOW_ARM64=1 to override)." ;;
    *)
      return 0 ;;  # unknown OS: no emulation model — do not gate
  esac
  # LINUX ONLY past here. Name the actual cause. `explicit`, `existing-release`,
  # `existing-datadir` and the dev-mode `values-file` (its own `*)` arm below) can
  # reach here (`sticky`/`fresh` resolve to 8.4, `amd64` was returned above), but
  # the reason is matched rather than assumed: a future reason must not inherit a
  # claim about this host's data that may be false.
  case "${TB_MYSQL_ENGINE_REASON:-}" in
    explicit)
      warn "TB_MYSQL_ENGINE=5.7 was requested, and the MySQL 5.7 image is amd64-only — it cannot run on ${ARCH}."
      hint "Drop TB_MYSQL_ENGINE (or set TB_MYSQL_ENGINE=8.4) to use the native multi-arch 8.4 engine — fresh data directories only."
      hint "To keep 5.7, enable amd64 emulation and re-run:"
      hint "  docker run --privileged --rm tonistiigi/binfmt --install amd64"
      error "MySQL 5.7 was requested explicitly and cannot run on ${ARCH} without amd64 emulation." ;;
    existing-release)
      warn "An existing tracebloc release is installed here, so the install keeps the MySQL 5.7 engine as a data-safety default — and that image is amd64-only."
      hint "Whether this release's data is actually 5.7-format cannot be told from here: the release is detected via 'helm list', not the data directory. 5.7 is kept because 8.4 cannot open a 5.7-format datadir if one exists."
      hint "Keep the existing release — enable amd64 emulation, then re-run:"
      hint "  docker run --privileged --rm tonistiigi/binfmt --install amd64"
      hint "Or start fresh on the native 8.4 engine — this needs BOTH the release AND its retained data removed. 'helm uninstall' alone is not enough: the MySQL volume is annotated 'helm.sh/resource-policy: keep', so it survives the uninstall, and 8.4 cannot open a 5.7-format datadir, which that retained volume may be (the next run resolves to 8.4 and fails the format guard after cluster setup). Delete the retained MySQL PVC (and any host data directory) as well before re-running."
      error "MySQL 5.7 (kept for the existing release) cannot run on ${ARCH} without amd64 emulation." ;;
    existing-datadir)
      warn "This host holds existing MySQL 5.7 data, so the install must keep the MySQL 5.7 engine — and that image is amd64-only."
      hint "This is a data-format constraint, not an architecture one: MySQL 8.4 runs natively on ${ARCH}, but it cannot open a 5.7-format datadir (MySQL upgrades only in stages, 5.7 → 8.0 → 8.4)."
      hint "Keep this data — enable amd64 emulation, then re-run:"
      hint "  docker run --privileged --rm tonistiigi/binfmt --install amd64"
      hint "Or start fresh on the native 8.4 engine — uninstall any existing release, then install into an empty data directory (the existing files keep the install on 5.7):"
      hint "  --data-dir=/path/to/new/empty/dir"
      error "MySQL 5.7 is required by the existing data on this host and cannot run on ${ARCH} without amd64 emulation." ;;
    *)
      warn "This install resolved to the MySQL 5.7 engine (${TB_MYSQL_ENGINE_REASON:-unknown reason}), and that image is amd64-only — it cannot run on ${ARCH}."
      hint "Enable amd64 emulation and re-run:"
      hint "  docker run --privileged --rm tonistiigi/binfmt --install amd64"
      error "MySQL 5.7 cannot run on ${ARCH} without amd64 emulation." ;;
  esac
}

# #553: give the bundled metrics-server APIService a bounded window to register
# before helm renders. On a freshly created k3d cluster k3s applies its bundled
# metrics-server (and the v1beta1.metrics.k8s.io APIService) shortly AFTER the
# API server is ready; `k3d cluster create --wait` only gates on node/serverlb
# readiness, not bundled addons. The resource-monitor DaemonSet template calls
# `{{ fail }}` at render time if that APIService isn't registered yet, so on a
# slow WSL2/laptop helm can render in that window and abort the WHOLE install.
# Best-effort: if the APIService never registers here we fall through and let
# the chart's render-time guard produce its actionable error, so a genuinely
# missing metrics-server is still caught (issue's preferred option (a)).
_wait_for_metrics_apiservice() {
  # Skipped entirely under the bats suite (TB_NO_SERVICE_PROGRESS, set in setup())
  # or when kubectl is unavailable — same guard the neighbouring network-y step
  # _download_services_progress uses. Without this the poll loop below would
  # `sleep 3` up to the full ${TB_METRICS_WAIT_S:-120}s in every mocked
  # install_client_helm test (kubectl absent on the CI runner just makes each
  # `kubectl get` fail instantly, so the loop still burns its whole deadline),
  # blowing the job's 10-min deadline. Real installs never set the flag and
  # always have kubectl, so the wait is unchanged for them.
  [[ -n "${TB_NO_SERVICE_PROGRESS:-}" ]] && return 0
  has kubectl || return 0
  local _timeout_s="${TB_METRICS_WAIT_S:-}"
  case "$_timeout_s" in ''|*[!0-9]*) _timeout_s="$METRICS_WAIT_TIMEOUT" ;; *) _timeout_s=$((10#$_timeout_s)) ;; esac
  local _deadline=$(( SECONDS + _timeout_s ))
  while (( SECONDS < _deadline )); do
    if kubectl get apiservice v1beta1.metrics.k8s.io --request-timeout=10s >/dev/null 2>&1; then
      # Registered — give it a moment to also report Available, but don't fail
      # the install if it's merely slow to become ready; the DaemonSet only
      # needs the APIService present at render time.
      kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io \
        --timeout=30s >/dev/null 2>&1 || true
      log "metrics.k8s.io APIService registered — proceeding with helm install."
      return 0
    fi
    sleep 3
  done
  log "metrics.k8s.io APIService not registered after ${_timeout_s}s — proceeding; the chart guards if metrics-server is genuinely absent."
  return 0
}

# client#564: label + annotate a pre-existing, Helm-unowned GPU device-plugin
# DaemonSet (left by the old imperative `kubectl apply`) so `helm upgrade
# --install` adopts it in place instead of failing with "exists and cannot be
# imported into the current release". Best-effort, bounded, idempotent, and
# gated on the GPU path — GPU is optional, so nothing here may abort the install.
_adopt_orphaned_gpu_device_plugin() {
  [[ "${GPU_VENDOR:-}" == "nvidia" || "${GPU_VENDOR:-}" == "amd" ]] || return 0
  local ns="kube-system" ds
  case "${GPU_VENDOR}" in
    nvidia) ds="nvidia-device-plugin-daemonset" ;;
    amd)    ds="amdgpu-device-plugin-daemonset" ;;
  esac
  # Probe for a pre-#564 imperative leftover. Distinguish "absent" (fresh host —
  # the chart just creates it) from a live API error: a wedged/slow API must NOT
  # be read as "absent", because a leftover-but-unadopted DaemonSet then makes
  # `helm upgrade --install` die with "exists and cannot be imported" and abort
  # the whole (otherwise GPU-optional) install. --request-timeout bounds the probe.
  # `|| rc=$?` (not `; rc=$?`): under set -e a bare assignment from a non-zero
  # command substitution aborts the script before the branch below runs — a
  # NotFound on a fresh GPU host would kill step e (client#564 / Bugbot).
  local probe rc=0
  probe=$(kubectl get daemonset "$ds" -n "$ns" -o name --request-timeout=5s 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then
    case "$probe" in
      ""|*NotFound*|*"not found"*) return 0 ;;  # absent — nothing to adopt
      *) warn "Could not check for a pre-existing GPU device plugin ${ds} (API error); skipping adoption. If a non-Helm ${ds} exists in ${ns}, remove it before install: kubectl delete daemonset ${ds} -n ${ns}"
         return 0 ;;
    esac
  fi
  log "Adopting pre-existing GPU device plugin ${ds} into the Helm release (client#564 migration)"
  # Adoption must actually succeed — a swallowed label/annotate failure leaves an
  # unowned DS that collides with the release. If it fails, remove the orphan so
  # the chart recreates a clean Helm-owned copy (the plugin is stateless; a brief
  # re-roll is fine and keeps GPU optional) rather than bricking the install.
  if kubectl label daemonset "$ds" -n "$ns" \
       app.kubernetes.io/managed-by=Helm --overwrite --request-timeout=10s \
       >> "${LOG_FILE:-/dev/null}" 2>&1 \
     && kubectl annotate daemonset "$ds" -n "$ns" \
       "meta.helm.sh/release-name=${TB_NAMESPACE}" \
       "meta.helm.sh/release-namespace=${TB_NAMESPACE}" \
       --overwrite --request-timeout=10s \
       >> "${LOG_FILE:-/dev/null}" 2>&1; then
    return 0
  fi
  warn "Could not adopt ${ds} into the Helm release; removing the orphan so the chart can recreate it."
  kubectl delete daemonset "$ds" -n "$ns" --timeout=30s --ignore-not-found \
    >> "${LOG_FILE:-/dev/null}" 2>&1 \
    || warn "Failed to remove orphaned ${ds}; if the install aborts with 'exists and cannot be imported', delete it manually: kubectl delete daemonset ${ds} -n ${ns}"
  return 0
}

install_client_helm() {
  # Step e (Install tracebloc) — main() prints the "e) Installing tracebloc"
  # header. The credential + namespace were provisioned in step d
  # (provision_client) or supplied via dual-mode (TRACEBLOC_CLIENT_ID/PASSWORD or
  # TRACEBLOC_VALUES_FILE). This step renders the values, runs Helm, and shows the
  # services download; the final connect + summary is step f.
  # node-local (RFC-0003 Option C): data lives inside the node, so skip the
  # world-writable ~/.tracebloc/{data,logs,mysql} dirs; just ensure the base dir
  # exists for values.yaml + the install log.
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    mkdir -p "$HOST_DATA_DIR"
  else
    _ensure_tracebloc_dirs
  fi
  local values_file; values_file="$(_client_values_file)"

  # ── Dev-mode override: caller-supplied values file ───────────────────────
  # When TRACEBLOC_VALUES_FILE is set, skip prompts and values.yaml generation
  # and use the provided file as-is. Used for local testing against an
  # unreleased chart (pair with TRACEBLOC_CHART_PATH).
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    [[ -f "$TRACEBLOC_VALUES_FILE" ]] || error "TRACEBLOC_VALUES_FILE not found: $TRACEBLOC_VALUES_FILE"
    values_file="$TRACEBLOC_VALUES_FILE"
    TB_NAMESPACE="${TB_NAMESPACE:-tracebloc}"
    info "Dev mode: using caller-provided values file"
    log "Using values file: $values_file (namespace: $TB_NAMESPACE)"
    # backend#2146: gate the arch on the dev-mode path too, BEFORE helm deploys.
    # We install the caller's file as-is, so the engine that will run is whatever
    # the file declares — read THAT (do NOT re-resolve: a fresh resolution could
    # pick 8.4 while the file leaves the amd64-only 5.7 default in place) and ask
    # the same question the normal path asks below. The SAME helper backs
    # preflight's early arch gate, so the two can't drift and refuse at different
    # steps (backend#2854).
    local _dm_decision; _dm_decision="$(_devmode_engine_decision)"
    TB_MYSQL_ENGINE_RESOLVED="${_dm_decision%% *}"
    TB_MYSQL_ENGINE_REASON="${_dm_decision#* }"
    _assert_engine_runs_on_this_arch
  else

  local use_existing=""
  local default_client_id=""
  local default_client_password=""

  # Non-interactive credentials (RFC-0001 Phase 0): set TRACEBLOC_CLIENT_ID +
  # TRACEBLOC_CLIENT_PASSWORD to provision without typing the secret inline
  # (CI / automation / golden images). Verified the same way as the prompt.
  local _noninteractive_creds=0
  if [[ -n "${TRACEBLOC_CLIENT_ID:-}" && -n "${TRACEBLOC_CLIENT_PASSWORD:-}" ]]; then
    _noninteractive_creds=1
  fi

  if [[ "$_noninteractive_creds" == 0 && -f "$values_file" && "${TRACEBLOC_CLIENT_ADOPTED:-}" != 1 ]] && _tty_available; then
    hint "Previous configuration found."
    while true; do
      read -r -p "  Use previous settings as defaults? [Y/n]: " use_existing <"$TB_TTY" || _no_interactive_creds_die
      use_existing="$(echo "${use_existing}" | tr '[:upper:]' '[:lower:]')"
      [[ "$use_existing" == "y" || "$use_existing" == "yes" || "$use_existing" == "n" || "$use_existing" == "no" || -z "$use_existing" ]] && break
      warn "Please enter y or n."
    done
    if [[ "$use_existing" == "y" || "$use_existing" == "yes" || -z "$use_existing" ]]; then
      default_client_id=$(_extract_yaml_value "$values_file" "clientId")
      default_client_password=$(_extract_yaml_value "$values_file" "clientPassword")
      [[ -n "$default_client_id" ]] && log "Using existing clientId as default."
      [[ -n "$default_client_password" ]] && log "Using existing clientPassword as default."
    fi
  fi

  # ── Namespace (fixed; not prompted) ──────────────────────────────────────
  # The on-prem client is one-per-machine and is identified to the backend by
  # its credentials (clientId), not by this name — so we don't ask the user to
  # invent one. It's just the local k8s namespace / Helm release name.
  # Advanced / GitOps setups can override with TB_NAMESPACE=<name>.
  TB_NAMESPACE=$(_client_default_namespace)

  # RFC-0001 §7.2 — a re-run on an already-connected client must reconcile in place,
  # not re-provision. Step 3 marks that case with TRACEBLOC_CLIENT_ADOPTED=1 (+ the
  # UUID, no password). Honor it: reconcile the live release silently — no credential
  # prompt, no verify, no duplicate. Only if there's no live release to reconcile do
  # we fall through to the normal connect flow below.
  if [[ "${TRACEBLOC_CLIENT_ADOPTED:-}" == 1 ]] && _reconcile_adopted_client; then
    success "tracebloc installed"
    log "Reconciled adopted client in namespace '$TB_NAMESPACE'"
    return 0
  fi

  if [[ "$_noninteractive_creds" == 1 ]]; then
    # Credentials supplied via env — verify once, no prompt, no re-prompt.
    TB_CLIENT_ID=$(_sanitize_credential "$TRACEBLOC_CLIENT_ID")
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TRACEBLOC_CLIENT_PASSWORD")
    [[ -n "$TB_CLIENT_ID" && -n "$TB_CLIENT_PASSWORD" ]] || \
      error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD must be non-empty."
    info "Verifying credentials with tracebloc…"
    case "$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")" in
      valid)      success "Credentials verified." ;;
      invalid)    error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD was rejected by tracebloc — check it at $(_dashboard_url) and re-run." ;;
      inactive)   error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified) warn "Couldn't reach tracebloc to verify credentials right now — continuing (the client will stay offline if they are wrong)." ;;
    esac
  else

  # We must prompt for credentials, but there may be no terminal to prompt on
  # (typically `curl … | bash`, where stdin is the piped script). Fail here with
  # an actionable message rather than aborting opaquely under set -e. The
  # per-read `|| _no_interactive_creds_die` guards below catch the harder case
  # this cheap check can't: a tty that is readable (`-r`) but yields no input.
  if ! _tty_available; then
    _no_interactive_creds_die
  fi

  prompt_header "Connect this machine to a tracebloc client."
  hint "A client links your secure environment to the tracebloc"
  hint "platform so other collaborators can submit models for evaluation."
  echo ""
  hint "Already have one? Enter its credentials below — or set"
  hint "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD to skip this prompt."
  hint "Need one? Create it (free) at:"
  echo -e "    ${BOLD}${WHITE}$(_dashboard_url)${RESET}"
  echo ""

  # Collect + verify credentials. The entered Client ID / password are checked
  # against the backend (the same api-token-auth/ call jobs-manager makes)
  # before we deploy, so a wrong credential is caught here — with a re-prompt —
  # instead of surfacing later as a silently crash-looping pod.
  local _cred_attempt=0 _cred_max=5 _cred_status
  while true; do
    if [[ -n "$default_client_id" ]]; then
      read -r -p "  Client ID [${default_client_id}]: " TB_CLIENT_ID_INPUT <"$TB_TTY" || _no_interactive_creds_die
      TB_CLIENT_ID="${TB_CLIENT_ID_INPUT:-$default_client_id}"
    else
      read -r -p "  Client ID: " TB_CLIENT_ID <"$TB_TTY" || _no_interactive_creds_die
    fi
    TB_CLIENT_ID=$(_sanitize_credential "$TB_CLIENT_ID")
    if [[ -z "$TB_CLIENT_ID" ]]; then warn "Client ID cannot be empty."; continue; fi

    if [[ -n "$default_client_password" ]]; then
      read -r -s -p "  Client password [press Enter to keep existing]: " TB_CLIENT_PASSWORD_INPUT <"$TB_TTY" || _no_interactive_creds_die
      echo ""
      TB_CLIENT_PASSWORD="${TB_CLIENT_PASSWORD_INPUT:-$default_client_password}"
    else
      read -r -s -p "  Client password: " TB_CLIENT_PASSWORD <"$TB_TTY" || _no_interactive_creds_die
      echo ""
    fi
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TB_CLIENT_PASSWORD")
    if [[ -z "$TB_CLIENT_PASSWORD" ]]; then warn "Client password cannot be empty."; continue; fi

    info "Verifying credentials with tracebloc…"
    _cred_status=$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")
    case "$_cred_status" in
      valid)
        success "Credentials verified."
        break ;;
      invalid)
        warn "That Client ID / password was rejected by tracebloc — please re-enter."
        hint "Find your credentials at $(_dashboard_url)" ;;
      inactive)
        error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified)
        warn "Couldn't reach tracebloc to verify your credentials right now — continuing."
        hint "If they are wrong, your client will stay offline at $(_dashboard_url) after install."
        break ;;
    esac

    _cred_attempt=$((_cred_attempt + 1))
    if [[ $_cred_attempt -ge $_cred_max ]]; then
      error "Too many failed attempts. Double-check your credentials at $(_dashboard_url) and re-run."
    fi
    # Force an active re-entry on retry (don't silently reuse a rejected default).
    default_client_id=""; default_client_password=""
  done
  fi

  # ── One-client-per-machine guard ─────────────────────────────────────────
  # A machine runs exactly one tracebloc client: it shares this cluster and the
  # host's CPU/RAM/GPU, and the platform counts each client as separate
  # capacity. If a DIFFERENT client is already installed here, a re-install
  # would silently re-point the machine — so we stop and let the operator
  # decide. The same clientId is a normal re-run/upgrade and passes through.
  # Check ANY namespace: a fresh install lands in `tracebloc`, but an install
  # from an older installer version may be in a different namespace. The jq-free
  # enumeration lives in detect_installed_client (shared with the #303 pre-provision
  # pre-flight so the two can't disagree on what's installed here).
  local existing_id="" existing_ns=""
  detect_installed_client
  existing_id="$INSTALLED_CLIENT_ID"; existing_ns="$INSTALLED_CLIENT_NS"
  # Fail CLOSED when we couldn't enumerate what's here (API/helm failure): refuse
  # rather than risk overwriting a client the guard simply couldn't see.
  if [[ "${INSTALLED_CLIENT_UNKNOWN:-0}" == 1 ]]; then
    echo ""
    warn "Couldn't determine which tracebloc client (if any) is already installed here."
    hint "tracebloc runs one client per machine, so the installer won't risk overwriting"
    hint "an existing client it can't see — usually the cluster API is briefly unreachable."
    hint "Check it and re-run:"
    hint "  kubectl cluster-info"
    hint "  helm list -A"
    echo ""
    error "Refusing to install without verifying what's already on this machine."
  fi
  if [[ -n "$existing_id" && "$existing_id" != "$TB_CLIENT_ID" ]]; then
    echo ""
    warn "This machine already runs the tracebloc client '${existing_id}' (namespace '${existing_ns}')."
    hint "tracebloc runs one client per machine — it shares this cluster and host"
    hint "resources, and the platform counts each client as separate capacity."
    echo ""
    hint "You entered a different Client ID ('${TB_CLIENT_ID}'). Pick one:"
    hint "  • Repair / update '${existing_id}'  →  re-run with that same Client ID"
    hint "  • Switch to '${TB_CLIENT_ID}'        →  remove the current client first:"
    hint "        k3d cluster delete ${CLUSTER_NAME:-tracebloc}   (wipes this client + its local data)"
    hint "      then re-run this installer"
    hint "  • Run both clients                   →  install on a separate machine"
    echo ""
    error "Refusing to replace the existing client. See the options above."
  fi

  # Same client, but already installed under a DIFFERENT namespace — e.g. a release
  # from an older installer that used the fixed `tracebloc` namespace, before #838
  # began deriving the namespace from the minted client slug. Upgrade THAT release
  # in place rather than installing a second one under the new namespace: the
  # platform counts each release as separate capacity, so a fork would silently
  # double-book this host (and orphan the original). Reuse the existing namespace;
  # an intentional namespace move is a delete-then-reinstall, not a silent fork.
  if [[ -n "$existing_id" && "$existing_id" == "$TB_CLIENT_ID" && -n "$existing_ns" && "$existing_ns" != "$TB_NAMESPACE" ]]; then
    log "Client '${existing_id}' already installed in namespace '${existing_ns}'; upgrading it in place instead of creating '${TB_NAMESPACE}'."
    info "Updating the existing client (namespace '${existing_ns}')."
    TB_NAMESPACE="$existing_ns"
  fi

  # Both credentials go into SINGLE-quoted YAML scalars through the shared
  # escaper. clientId used to be interpolated raw into a DOUBLE-quoted scalar
  # (clientId: "$TB_CLIENT_ID"), where a `"` or `\` in the value would corrupt the
  # generated values file — the same bug class as the password, and unguarded:
  # _sanitize_credential only strips paste/non-printable characters. In practice
  # verify_credentials gates it to UUIDs, so this is hardening rather than a live
  # break, but the interpolation itself is now safe (Saqlain review, #443).
  TB_CLIENT_ID_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_ID")"
  TB_CLIENT_PASSWORD_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_PASSWORD")"

  # ── GPU request + runtime class (backend#2033 + client#835) ───────────────
  # Request a GPU for training jobs, keyed to the vendor's scheduler resource
  # (_gpu_request_value → nvidia.com/gpu / amd.com/gpu; empty = CPU). For NVIDIA
  # that value is gated on the GPU being WIRED into the cluster (inside
  # _gpu_request_value): requesting nvidia.com/gpu on a node that advertises 0
  # strands every job Pending (the pre-#835 Linux bug), so gate on what PROVISIONS
  # the GPU, not bare detection. NVIDIA training pods also run under the `nvidia`
  # RuntimeClass (baked into the GPU node image) so the node's containerd invokes
  # the NVIDIA runtime; AMD needs no RuntimeClass. A request this fixed single-node
  # cluster can't satisfy is safe: SINGLE_NODE below tells jobs-manager to downgrade
  # a Pending GPU pod to CPU rather than strand it (client-runtime#92). Mirrors the
  # Windows twin.
  local gpu_val runtime_class=""
  gpu_val="$(_gpu_request_value)"
  if _gpu_wired; then runtime_class="nvidia"; fi
  if [[ -n "$gpu_val" ]]; then
    log "${GPU_VENDOR} GPU wired — GPU_LIMITS/GPU_REQUESTS=${gpu_val}${runtime_class:+, RUNTIME_CLASS_NAME=${runtime_class}}"
  elif [[ "${GPU_VENDOR:-}" == "nvidia" ]]; then
    warn "NVIDIA GPU detected but not wired into this cluster — running CPU-only (GPU_LIMITS/GPU_REQUESTS left empty)."
  else
    log "No GPU wired for training jobs — GPU_LIMITS and GPU_REQUESTS left empty"
  fi

  # ── GPU device plugin (client#564) ────────────────────────────────────────
  # Enable the Helm-managed device-plugin DaemonSet whenever a GPU vendor is
  # detected — the same condition under which deploy_gpu_device_plugin used to
  # apply the upstream manifest imperatively (bash: gpu-plugins.sh). The chart
  # now owns it, so it's reconciled on upgrade and removed on `helm uninstall`
  # instead of lingering. CPU-only installs emit nothing → the chart default
  # (disabled) stands. The matching GPU *request* (gpu_val) is wired per-vendor
  # above — nvidia.com/gpu or amd.com/gpu (backend#2033).
  #
  # NVIDIA (client#835): the plugin must run under the `nvidia` RuntimeClass so it
  # can init NVML on native Linux — the plugin pod otherwise runs under the default
  # runtime, sees no GPU, and registers 0. So it is enabled only when the GPU is
  # actually wired (a stock CPU node has no `nvidia` RuntimeClass, which would leave
  # the pod unschedulable). AMD is unchanged: its plugin needs no k3d flag or
  # RuntimeClass, so it stays gated on bare detection.
  local gpu_block=""
  if _gpu_wired; then
    gpu_block="$(printf 'gpu:\n  devicePlugin:\n    enabled: true\n    vendor: nvidia\n    nvidia:\n      runtimeClassName: nvidia\n')"
    log "Helm-managed GPU device plugin enabled (vendor=nvidia, runtimeClassName=nvidia)"
  elif [[ "${GPU_VENDOR:-}" == "amd" ]]; then
    gpu_block="$(printf 'gpu:\n  devicePlugin:\n    enabled: true\n    vendor: amd\n')"
    log "Helm-managed GPU device plugin enabled (vendor=amd)"
  fi

  # backend#723 A2: pick the MySQL engine for this install (before the heredoc
  # below is rendered; see _resolve_mysql_engine for the full decision rules).
  _resolve_mysql_engine
  # backend#2047: and only now is it knowable whether this host can run the
  # engine that rule picked. Ordering, not duplication — the arch question is
  # asked against the resolved engine, never ahead of it.
  _assert_engine_runs_on_this_arch

  # ── Write generated values.yaml ─────────────────────────────────────────
  log "Writing values to $values_file"

  # Translate a corporate proxy on the host into the chart's split proxy keys so
  # every egress-needing workload inherits it (see _chart_proxy_env_yaml). Empty
  # when the host has no proxy — the env: block is then unchanged.
  local proxy_env_yaml
  proxy_env_yaml="$(_chart_proxy_env_yaml)"
  [[ -n "$proxy_env_yaml" ]] && log "Corporate proxy detected on host — propagating to client workloads via chart values."

  # Private registry mirror (#585): re-home every image onto TRACEBLOC_IMAGE_REGISTRY
  # for restricted-network / air-gapped installs. Empty when unset (values unchanged).
  local image_mirror_yaml
  image_mirror_yaml="$(_image_mirror_yaml)"
  if [[ -n "${TRACEBLOC_IMAGE_REGISTRY:-}" ]]; then
    log "Image registry mirror configured — pulling all images from ${TRACEBLOC_IMAGE_REGISTRY}."
    [[ -n "${TRACEBLOC_REGISTRY_USERNAME:-}" ]] && log "Mirror credentials provided — minting an imagePullSecret for the mirror."
  fi

  # backend#1236 (option A): size the default training budget to this machine.
  # One pass, both answers (backend#2220) — the probes are bounded but not free,
  # and calling the two wrappers separately would run them twice.
  local training_size training_provenance
  _resolve_training_size
  training_size="$_TB_TRAINING_SIZE"
  training_provenance="$_TB_TRAINING_PROVENANCE"
  log "Training size: ${training_size} (adjust any time with 'tracebloc resources set')"
  # The warning belongs HERE, not in the resolver: the resolver's output is
  # captured with $(...) by _training_resources / _training_provenance, so a warn
  # emitted there would end up inside the value.
  if (( ${_TB_TRAINING_UNDERSIZED:-0} == 1 )); then
    warn "This machine is below the size a training run wants: ${training_size} is all that is left after the platform's reservation."
    hint "The client will install and run, but training jobs may be killed for memory. ~16 GB of RAM is the recommendation for training locally."
  elif (( ${_TB_TRAINING_UNSCHEDULABLE:-0} == 1 )); then
    warn "This machine is too small to host a training run at all; keeping the default ${training_size}."
    hint "Training jobs will stay Pending until this edge has more memory — the client itself will still run, ingest and report."
  fi

  # CREATE IT EMPTY AND 0600 *BEFORE* THE CREDENTIAL GOES IN (backend#2571).
  # The heredoc below creates the file at the PROCESS umask, and the chmod used to
  # come after its EOF -- so under any umask but 077 the file existed
  # world-readable for the duration of the write, with clientPassword already in
  # it. Ordering was the whole defect: a mode fixed one line too late is not a mode.
  #
  # `>` on an EXISTING file truncates without touching its mode, so the heredoc
  # then writes into a file that is already 0600. The window that remains is on an
  # EMPTY file, which is what makes it harmless rather than merely shorter.
  #
  # It only ever touches the file the installer GENERATES: this whole branch is the
  # `else` of the TRACEBLOC_VALUES_FILE dev-mode override, so a caller's own values
  # file is never chmodded underneath them.
  : > "$values_file" || error "Could not create $values_file"
  chmod 600 "$values_file" 2>/dev/null || true
  cat <<EOF > "$values_file"
# ============================================================
# Generated by tracebloc installer — client configuration
# ============================================================

env:
$([ -n "${CLIENT_ENV:-}" ] && printf '  CLIENT_ENV: "%s"\n' "$(tb_client_env "$CLIENT_ENV")")${proxy_env_yaml}
  # Training size: how much CPU/RAM each training run gets. Sized to this
  # machine at install — largest node minus ~1 CPU / 3 GiB platform overhead —
  # unless TRACEBLOC_TRAINING_RESOURCES is set or the installed release already
  # carries a choice (backend#1236, option A).
  #
  # THE TWO HALVES ARE NOT THE SAME STRING any more (backend#2418, L0.2):
  # requests carries cpu AND memory, limits carries memory ONLY. CPU is
  # time-shared, so a request with no limit is a share weight rather than a
  # quota that throttles on an idle machine; memory is not time-shared, so
  # requests == limits stays. See _training_limits for the full reasoning and
  # for the client-runtime#388 ordering constraint.
  RESOURCE_LIMITS: "$(_training_limits "${training_size}")"
  RESOURCE_REQUESTS: "${training_size}"
  # Who chose the pair above (backend#2220). Bookkeeping only — it never changes
  # the envelope. "unknown" means the value was carried forward from before this
  # key existed and is genuinely unattributable, so consumers treat it as "user".
  RESOURCE_PROVENANCE: "${training_provenance}"
  GPU_LIMITS: "$gpu_val"
  GPU_REQUESTS: "$gpu_val"
  # nvidia when the GPU is wired (client#835): jobs-manager threads it into every
  # spawned pod so the node's containerd invokes the NVIDIA runtime; "" on CPU.
  RUNTIME_CLASS_NAME: "$runtime_class"
  # client-runtime#92: installer-provisioned k3d is a fixed single-host cluster
  # that cannot autoscale, so jobs-manager applies the hard CPU-or-GPU rule —
  # a Pending GPU pod is downgraded to CPU rather than waiting for a GPU node
  # that will never arrive.
  SINGLE_NODE: "true"
$([ -n "${HOST_DATASET_DIR:-}" ] && printf '  HOST_UID: "%s"\n  HOST_GID: "%s"\n' "$(id -u)" "$(id -g)")
$(if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
cat <<'STORAGE'
# RFC-0003 Option C — node-local: use k3s's built-in local-path StorageClass.
# No hostPath PVs, so dataset volumes are provisioned inside the k3d node and
# are destroyed by `cluster delete` rather than left as host files.
storageClass:
  create: false
  name: local-path

hostPath:
  enabled: false

# node-local is a single schedulable node (common.sh forces AGENTS=0, SERVERS=1),
# so the single-replica PDBs would be undrainable here. hostPath.enabled=false
# would otherwise misclassify this as multi-node, so declare the topology
# explicitly to skip those PDBs and keep the node drainable (client#560).
singleNode: true
STORAGE
else
cat <<'STORAGE'
storageClass:
  create: true
  name: client-storage-class
  provisioner: manual
  allowVolumeExpansion: true
  parameters: {}

hostPath:
  enabled: true
STORAGE
[ -n "${HOST_DATASET_DIR:-}" ] && printf '  datasetPath: /tracebloc-data\n'
fi)
$(if [[ "${TB_MYSQL_ENGINE_RESOLVED:-5.7}" == "8.4" ]]; then
cat <<'MYSQL84'

# MySQL engine opt-in (backend#723, decision A2): this install runs the
# multi-arch 8.4 engine natively — fresh datadirs only; the chart's
# mysql-format-guard init container refuses a mismatched datadir. Explicit
# tag + empty digest: the chart's 5.7 reproducibility pin stays for installs
# on the default engine. Sticky across installer re-runs; override with
# TB_MYSQL_ENGINE=5.7|8.4.
images:
  mysqlClient:
    tag: "8.4"
    digest: ""
MYSQL84
fi)
${gpu_block:+$gpu_block
}pvc:
  mysql: 2Gi
  logs: 10Gi
  data: 50Gi

pvcAccessMode: ReadWriteOnce

clusterScope: true
${image_mirror_yaml}
clientId: '$TB_CLIENT_ID_ESCAPED'
clientPassword: '$TB_CLIENT_PASSWORD_ESCAPED'

EOF

  # DEFENCE IN DEPTH, AND THEN A CHECK -- not a silent best-effort. This line used
  # to be the only protection and it could not fail: a chmod that did not apply
  # left a live clientPassword world-readable and said nothing, and no test
  # asserted the mode. The telemetry spool has exactly such a test
  # (telemetry.bats, "the spool is 0600 under the umask the installer can actually
  # be holding"); this file, which holds a credential, had none.
  #
  # POSIX `ls -ldn`, NEVER GNU-only `stat -c` -- BSD rejects `-c` silently, which
  # is the bug hostpath-prep.bats:181 stands as a regression guard for.
  #
  # WARN RATHER THAN error, deliberately. chmod genuinely cannot apply on a
  # HOST_DATA_DIR living on a filesystem without POSIX modes (exFAT, some
  # Windows/WSL mounts), and refusing to install there would trade a readable file
  # for no tracebloc at all. So it names the mode it actually found and continues:
  # an operator can act on "-rw-r--r--", they cannot act on silence.
  chmod 600 "$values_file" 2>/dev/null || true
  local _vf_mode; _vf_mode="$(ls -ldn "$values_file" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$_vf_mode" in
    -rw-------*) : ;;
    "")          warn "Could not read the mode of $values_file -- it holds a live credential; check that other users cannot read it." ;;
    *)           warn "$values_file is $_vf_mode, not -rw------- . It holds your clientPassword in cleartext; restrict it with: chmod 600 $values_file" ;;
  esac
  log "Values file written to $values_file"
  fi

  _ensure_helm_runnable

  # ── Resolve chart reference: local path (dev) or remote repo (default) ──
  local chart_ref=""
  _resolve_chart_ref

  echo ""
  log "Installing $TB_NAMESPACE from $chart_ref in namespace '$TB_NAMESPACE'..."

  # What the user is about to see download (the "e) Installing tracebloc" body).
  echo -e "  ${DIM}Downloading the tracebloc services — a training runner that runs models${RESET}"
  echo -e "  ${DIM}on your data, a data manager, a live monitor, and a local database. They${RESET}"
  echo -e "  ${DIM}run entirely on your machine; your data never leaves it.${RESET}"
  echo ""

  # Pre-create per-release hostPath dirs so they're owned by the host user, not
  # root:root from kubelet's DirectoryOrCreate. See _ensure_release_dirs.
  # node-local (RFC-0003 Option C) has no hostPath dirs to pre-create.
  [[ "${TB_STORAGE_MODE:-node-local}" != "node-local" ]] && _ensure_release_dirs "$TB_NAMESPACE"

  # #553: wait out the metrics-server APIService registration race before helm
  # renders the resource-monitor DaemonSet (whose template hard-fails if the
  # metrics API isn't registered yet). Bounded + best-effort. The outer spinner
  # deadline must never truncate the configured inner wait, so derive it from
  # TB_METRICS_WAIT_S (same parse as _wait_for_metrics_apiservice) plus slack for
  # the post-registration `kubectl wait --for=Available` (30s) and jitter.
  local _metrics_wait_s="${TB_METRICS_WAIT_S:-}"
  case "$_metrics_wait_s" in ''|*[!0-9]*) _metrics_wait_s="$METRICS_WAIT_TIMEOUT" ;; *) _metrics_wait_s=$((10#$_metrics_wait_s)) ;; esac
  spin_cmd_bounded "$(( _metrics_wait_s + 60 ))" "Waiting for the metrics API to register…" \
    _wait_for_metrics_apiservice || true

  # The chart install blocks ~10-15s (render + apply + image pull), so run it
  # behind a spinner instead of a frozen terminal — spin_cmd_bounded streams
  # helm output to $LOG_FILE and, on failure, tails the log to stderr. Honours
  # RFC-0002 §2 "progress on every wait"; the deadline stops a wedged
  # kube-apiserver from hanging the install forever (#426).
  local _helm_timeout_min
  _helm_timeout_min="$(tb_minutes_or "${TB_HELM_TIMEOUT_MIN:-}" 10)"

  # #554: clear any pending-* wedge left by a previously killed helm op (Ctrl-C,
  # OOM, reboot) before we upgrade — otherwise this run just fails with "another
  # operation is in progress" (exit 1) and the machine stays wedged across every
  # re-run. The release name equals the namespace on the normal install path.
  # Fail closed if recovery itself couldn't clear it.
  if ! _recover_pending_helm_release "$TB_NAMESPACE" "$TB_NAMESPACE"; then
    hint "Couldn't automatically clear the interrupted release. Recover it by hand, then re-run:"
    hint "  first install:  helm -n $TB_NAMESPACE uninstall $TB_NAMESPACE    (removes only the half-installed release)"
    hint "  upgrade:        helm -n $TB_NAMESPACE rollback $TB_NAMESPACE     (returns to the previous release)"
    error "Client installation blocked by an interrupted previous helm operation. Check the log for details: ${LOG_FILE:-}"
  fi

  # client#564 migration: an earlier install applied the GPU device plugin with
  # an imperative `kubectl apply` (unowned by Helm). If that DaemonSet survived a
  # `helm uninstall` — the exact litter #564 is about — this fresh install would
  # now fail with "exists and cannot be imported into the current release". Label
  # + annotate any such orphan for Helm adoption so the chart takes it over IN
  # PLACE (no GPU blip), instead of colliding. Best-effort + bounded + idempotent:
  # a missing DS or a kubectl hiccup must never block the install (GPU is
  # optional). Only runs on the GPU path; a no-op everywhere else.
  _adopt_orphaned_gpu_device_plugin

  local _helm_rc=0
  spin_cmd_bounded "$(( _helm_timeout_min * 60 ))" "Installing the tracebloc client…" \
    helm upgrade --install "$TB_NAMESPACE" "$chart_ref" \
    --namespace "$TB_NAMESPACE" \
    --create-namespace \
    --cleanup-on-fail \
    --values "$values_file" || _helm_rc=$?
  if [[ "$_helm_rc" -ne 0 ]]; then
    # A helm op killed partway (timeout=124, or an in-progress wedge=exit 1) can
    # leave the release pending-*. The next run auto-recovers
    # (_recover_pending_helm_release), but name the manual unwedge too — on exit
    # 1, not only the 124 timeout (#554, extends Bugbot #442).
    hint "If a re-run reports 'another operation is in progress', unwedge the release first:"
    hint "  first install:  helm -n $TB_NAMESPACE uninstall $TB_NAMESPACE    (removes only the half-installed release)"
    hint "  upgrade:        helm -n $TB_NAMESPACE rollback $TB_NAMESPACE     (returns to the previous release)"
    error "Client installation failed. Check the log for details: ${LOG_FILE:-}"
  fi

  # Point the kubeconfig's current context at the client namespace, so kubectl and
  # the tracebloc CLI default to it with no -n / --namespace flag. Best-effort:
  # a failure here must not abort an otherwise-successful install.
  kubectl config set-context --current --namespace "$TB_NAMESPACE" >/dev/null 2>&1 || true

  # Honest N-of-M count bar as the service images pull onto the node. Best-effort +
  # bounded + non-fatal — the real readiness gate is step f (wait_for_client_ready).
  _download_services_progress "$TB_NAMESPACE"

  success "tracebloc installed"
  log "Values file: $values_file"
}
