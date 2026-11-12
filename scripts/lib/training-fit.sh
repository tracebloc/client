#!/usr/bin/env bash
# =============================================================================
#  training-fit.sh — the training envelope: its default size, the size carried
#  from an existing release, the machine's ceiling, and whether it fits beside
#  the platform (the fit verdict and the pre-create gate). install_client_helm
#  (install-client-helm.sh) and the cluster create path call them.
# =============================================================================

# ── Training-size default (option A; floored) ─────
# One knob. MEMORY is requests == limits; CPU is a request-only share weight
# with no limit, so on a CPU edge the pod is BURSTABLE, not Guaranteed QoS --
# see the L0.2 rationale at `_training_limits` below, which this header used to
# contradict outright.
#
# ON A GPU EDGE IT IS BestEffort, NOT BURSTABLE, and saying BURSTABLE flat here
# was the same overshoot this branch fixed in the schema, in the file it was not
# fixed for. `_gpu_request_value` emits
# `nvidia.com/gpu=1` / `amd.com/gpu=1`, and client-runtime's `_get_gpu_resources`
# returns ONLY that plus ephemeral-storage -- it never reads RESOURCE_REQUESTS /
# RESOURCE_LIMITS on that path. QoS is computed from cpu and memory alone
# (`isSupportedQoSComputeResource`), so both accumulators are empty and the pod
# lands in the worst class: first choice for OOM kill and eviction, on a node it
# shares with mysql and jobs-manager.
#
# THE TICKET IS CLOSED WITH THIS HALF UNFIXED, which is why it is written here
# rather than left as a reference. An earlier ticket raised both GPU BestEffort
# workloads; a fix covered the DEVICE-PLUGIN half (both DaemonSets are now
# Guaranteed) and the issue was closed, while the TRAINING-pod half stayed open
# and lost its record. `scripts/tests/pod-qos-class.py` asserts the shape from
# this side -- "gpu + ephemeral-storage only, no cpu/memory -> BestEffort" -- but
# the fix belongs in client-runtime.
#
# The old static default
# ("cpu=2,memory=8Gi") was wrong at both ends: dead on arrival on nodes under
# 8 GiB (the WSL2 field case, and a default Docker Desktop VM — nothing could
# ever schedule) and ~12% of a 64 GiB box. Precedence:
#   1. TRACEBLOC_TRAINING_RESOURCES  (explicit install-time override)
#   2. the installed release's current value — a `tracebloc resources set`
#      choice must survive re-install, never be clobbered back to a default
#   3. sized to this machine: LARGEST node allocatable − platform overhead
#      (~1 CPU / 3 GiB, the cli's constants; a pod schedules onto ONE node, so
#      summing nodes would over-count)
#   4. the contract FLOOR (tiny or undeterminable machines) — the fallback the
#      installer writes when it cannot do better. Was the 8Gi literal above,
#      which exceeded a default Docker Desktop and sat Pending forever, so
#      floored it. _TRAINING_DEFAULT is DERIVED from the embedded
#      floor constants (below, so it cannot drift from the contract).

# k8s cpu quantity -> millicores ("12" -> 12000, "11500m" -> 11500, "0.5" -> 500);
# empty on junk.
#
# The fractional-cores arm exists for _measured_system_requests:
# node allocatable is always serialised as whole cores or `m`, but a third-party
# system pod may request `0.5`, and a quantity this cannot read makes the whole
# measurement unusable rather than silently counting as zero. Digits after the
# point beyond the third are truncated (floored), never rounded up.
_cpu_to_milli() {
  local v="$1" whole frac
  case "$v" in
    *m) case "${v%m}" in ''|*[!0-9]*) : ;; *) printf '%s' "${v%m}" ;; esac ;;
    *.*)
      # `.5` and `5.` are valid quantities (Kubernetes reads them as 0.5 and 5),
      # so either side of the dot may be empty but not both -- and a glob
      # `[0-9]*` means ONE digit then anything, which is how the old arm
      # refused `.5` while its comment said otherwise (measured).
      whole="${v%%.*}"; frac="${v#*.}"
      case "$whole$frac" in ''|*[!0-9]*|*.*) return 0 ;; esac
      frac="${frac}000"; frac="${frac:0:3}"
      # `10#` -- a fraction like 050 would otherwise be read as octal; an empty
      # whole is 0.
      printf '%s' "$(( 10#${whole:-0} * 1000 + 10#$frac ))" ;;
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$(( v * 1000 ))" ;;
  esac
}
# k8s memory quantity -> bytes (binary Ki/Mi/Gi/Ti/Pi, decimal k/M/G/T/P, or
# plain bytes); empty on junk. The decimal arms were added for the same reason as
# the fractional-cores arm above: the chart and kubelet speak `Mi`, but a system
# pod may say `250M`, and an unreadable quantity must be a refusal, not a zero.
# The Pi/P arms exist because the retired PowerShell core had them and this did
# not: this reader replays
# scripts/tests/fixtures/quantity_vectors.json, so the grammar is held by a
# test, not by a comment claiming it.
_mem_to_bytes() {
  local v="$1" n
  case "$v" in
    *Ki|*Mi|*Gi|*Ti|*Pi) n="${v%??}" ;;
    *k|*M|*G|*T|*P)      n="${v%?}" ;;
    *)                   n="$v" ;;
  esac
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  case "$v" in
    *Ki) printf '%s' "$(( n * 1024 ))" ;;
    *Mi) printf '%s' "$(( n * 1024 * 1024 ))" ;;
    *Gi) printf '%s' "$(( n * 1024 * 1024 * 1024 ))" ;;
    *Ti) printf '%s' "$(( n * 1024 * 1024 * 1024 * 1024 ))" ;;
    *Pi) printf '%s' "$(( n * 1024 * 1024 * 1024 * 1024 * 1024 ))" ;;
    *k)  printf '%s' "$(( n * 1000 ))" ;;
    *M)  printf '%s' "$(( n * 1000 * 1000 ))" ;;
    *G)  printf '%s' "$(( n * 1000 * 1000 * 1000 ))" ;;
    *T)  printf '%s' "$(( n * 1000 * 1000 * 1000 * 1000 ))" ;;
    *P)  printf '%s' "$(( n * 1000 * 1000 * 1000 * 1000 * 1000 ))" ;;
    *)   printf '%s' "$n" ;;
  esac
}

# ONE lookup of the installed release's carried training values, echoing
# "<size>|<provenance>" or NOTHING.
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
# helm re-serializes (`helm get values` strips quotes).
# Provenance is normalised here: anything unrecognised, including absent, is
# `unknown`, never a guess.
_existing_training_values() {
  local ns="${namespace:-}" out
  [[ -n "$ns" ]] || return 0
  # helm get has no request timeout, so gate it behind a BOUNDED probe: a
  # wedged API degrades to machine sizing / the static default instead of
  # hanging values generation. A missing namespace also means there
  # is no release to carry — skip the helm call entirely.
  kubectl get namespace "$ns" --request-timeout=5s >/dev/null 2>&1 || return 0
  # The stored values hold clientPassword and the chart's other secrets, so they are
  # read inside the pipe and never held: only the three keys below leave it. A trace
  # (bash -x, which the install log keeps) then shows "<size>|<provenance>", never
  # the values. pipefail: a helm that fails carries nothing. The awk reads to EOF
  # (no early exit), so helm is never SIGPIPE'd into a false failure.
  #
  # READ RESOURCE_REQUESTS, FALL BACK TO RESOURCE_LIMITS.
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
  #
  # Each key is its FIRST line, read whole; an empty RESOURCE_REQUESTS falls back to
  # LIMITS. No carried size prints nothing: nothing to attribute, the caller sizes
  # the machine.
  out="$(set -o pipefail; helm get values "$ns" -n "$ns" 2>/dev/null </dev/null | awk '
    function val(   v) { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(sprintf("%c", 34), "", v); return v }
    /^[[:space:]]*RESOURCE_REQUESTS:/   && !sr { sr = 1; req = val() }
    /^[[:space:]]*RESOURCE_LIMITS:/     && !sl { sl = 1; lim = val() }
    /^[[:space:]]*RESOURCE_PROVENANCE:/ && !sp { sp = 1; prov = val() }
    END {
      size = (req != "" ? req : lim)
      if (size == "") exit
      if (prov != "installer" && prov != "user") prov = "unknown"
      printf "%s|%s", size, prov
    }')" || return 0
  printf '%s' "$out"
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
# These four numbers used to be typed out
# here, again in the PowerShell core, and a third time in cli's set.go, with a
# fourth policy in client-runtime's node_sizing.py. Four copies, none derived
# from the others.
#
# They now come from ONE place — client-runtime/envelope_contract.json, whose
# arithmetic lives in node_sizing.envelope_from_allocatable. bash cannot parse
# JSON (jq is not a guaranteed prerequisite — see the helm-namespace note
# below) and the bootstrap is signed and must not fetch anything unsigned, so
# the constants are EMBEDDED here.
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
_TB_ENVELOPE_CONTRACT_VERSION=10
_TB_ENVELOPE_OVERHEAD_CPU_MILLI=650
_TB_ENVELOPE_OVERHEAD_MEM_BYTES=2516582400
_TB_ENVELOPE_FLOOR_CPU_MILLI=1000
_TB_ENVELOPE_FLOOR_MEM_BYTES=2147483648
# The ingestion Job's requests, one component of the overhead above. The fit
# verdict keeps them free beside the training run (_fit_verdict).
_TB_ENVELOPE_INGESTION_CPU_MILLI=0
_TB_ENVELOPE_INGESTION_MEM_BYTES=268435456
# ── end generated ───────────────────────────────────────────────────────────

# ── the chart's own control-plane footprint (GENERATED — do not hand-edit) ──
#
# What the chart's steady-state control plane REQUESTS -- every
# Deployment/StatefulSet/DaemonSet container, the scheduler's max(sum(app),
# max(init)) per pod, one-shot hook Jobs excluded -- summed from `helm template`
# by scripts/tests/control-plane-footprint.sh and embedded here by
# scripts/gen-footprint-embed.sh. The overhead constant above is what the
# envelope SUBTRACTS for the platform; this is what the platform actually ASKS
# the scheduler for, and since 2026-09 the two disagree (the footprint is larger).
# _fit_training_envelope compares the envelope against allocatable minus THIS,
# so a chart change that raises a request shrinks the envelope on the next
# install instead of leaving the training pod Pending.
#
# Embedded, not summed at install time, for the same reason as the block above:
# the runtime installer guarantees neither jq nor python3, and the bootstrap is
# signed. What keeps it honest is `scripts/gen-footprint-embed.sh --check` in
# `make drift` (the required Source-of-truth drift job): the value below must
# equal a fresh render of the chart in the same tree, or CI reddens.
_TB_CP_FOOTPRINT_MEM_BYTES=2248146944
_TB_CP_FOOTPRINT_CPU_MILLI=650
# The TRANSIENT the chart's CronJobs may have resident on top of the steady state
# (auto-upgrade + image-refresh, both Forbid, routinely co-resident), summed by
# `control-plane-footprint.sh --print-transient`. Not part of the
# per-node envelope overhead -- a CronJob pod is not a training pod's neighbour
# for long -- but part of what the VM beneath the nodes must hold for the
# smallest rung to stay schedulable at the moment both fire.
_TB_CP_TRANSIENT_MEM_BYTES=402653184
_TB_CP_TRANSIENT_CPU_MILLI=700
# ── end generated ───────────────────────────────────────────────────────────

# ── when the training envelope reserves that transient ──
#
# A training run lasts hours, so an hourly CronJob that has to wait for it stays
# Pending the whole run: on an 8.4 GiB / 10-CPU machine the auto-upgrade failed
# at its deadline behind one. _fit_verdict therefore reserves _TB_CP_TRANSIENT_*
# beside the chart's steady state -- but only on a node whose allocatable CPU is
# at least this much. Below it the envelope is today's and upgrades wait while a
# run trains: reserving 700 m there refuses a 2-core machine outright (1900 m
# allocatable leaves 350 m, under one core) and takes a core off every 4-core
# one. Hand-typed, not generated: a product threshold, not a chart fact.
_TB_CP_TRANSIENT_RESERVE_MIN_CPU_MILLI=8000

# ── k3s's own addons, as a FLOOR ──────────────────
#
# What k3s's bundled addons request on the node native k3s sets up: coredns
# 100m / 70Mi and metrics-server 100m / 70Mi (k3s's packaged manifests). k3s.sh's
# config drops traefik and servicelb, and the
# local-path-provisioner, where it is kept, requests nothing, so these two are
# the whole of it. Hand-typed, not generated: the numbers live in k3s's
# binary, not in this tree. A k3s bump that changes them is caught only by `tracebloc doctor`
# on a small machine -- which is how this was found.
#
# WHY A FLOOR. _fit_training_envelope already MEASURES the system pods -- but
# only the ones that are scheduled when values are generated. On a fresh native
# k3s the addons can still be Pending (no nodeName) or not yet created at that
# moment, so the measurement came back 0 and the envelope was checked against
# the chart alone. On a 2 vCPU / 7 GB machine that is 5250 MiB allocatable -
# 2112 MiB chart = 3138 MiB, which "fits" with nothing to spare; once
# the addons land, 2998 MiB is free and doctor says Not ready. The floor makes
# the fit count what WILL be on the node, whatever has been scheduled so far.
_TB_K3S_ADDON_MEM_BYTES=146800640
_TB_K3S_ADDON_CPU_MILLI=200

# Echo "<mem bytes> <cpu m>" -- the system-pod floor native k3s guarantees will be
# on the node -- or NOTHING when there is no known floor (a substrate this
# installer does not set up).
_system_requests_floor() {
  case "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" in
    k3s) ;;
    *) return 0 ;;
  esac
  printf '%s %s' "$_TB_K3S_ADDON_MEM_BYTES" "$_TB_K3S_ADDON_CPU_MILLI"
}

# ── the fallback training envelope (precedence step 4) ──────────────────────
# The contract FLOOR — cpu=1,memory=2Gi — DERIVED from the embedded floor
# constants so it cannot drift from envelope_contract.json. Written when the
# machine is unschedulable or unreadable. Was cpu=2,memory=8Gi, which exceeded a
# default Docker Desktop VM and left a fresh install Pending forever; the floor
# is the largest fallback that still fits the smallest host we support
# The bats suite pins it to the embedded floor.
_TRAINING_DEFAULT="cpu=$(( _TB_ENVELOPE_FLOOR_CPU_MILLI / 1000 )),memory=$(( _TB_ENVELOPE_FLOOR_MEM_BYTES / 1024 / 1024 / 1024 ))Gi"

# The historic fallback literal (pre-floor). FROZEN — NOT the current
# default — kept only so the carry gate in _resolve_training_size still
# RECOGNISES it: existing field installs carry cpu=2,memory=8Gi as their
# absence-of-a-choice default and must re-derive on re-install rather than
# freeze an unschedulable 8Gi. The current floor default is deliberately NOT
# matched by that gate — a human may legitimately `tracebloc resources set` the
# floor, and precedence step 2 says that choice must survive.
_TRAINING_DEFAULT_HISTORIC="cpu=2,memory=8Gi"

# The node line contract, in ONE place.
#
# Three whitespace-separated fields per node: allocatable cpu, allocatable
# memory, and `.spec.unschedulable`. Kubernetes declares Unschedulable with
# `omitempty`, so a normal node emits nothing for the third field and the line
# carries a trailing space; only a CORDONED node emits the literal `true`. The
# reader therefore tests for `true` rather than for emptiness.
#
# Extended from two fields to three later: the contract's
# skipped_nodes has always said `spec.unschedulable (cordoned)` is skipped, but
# neither installer ASKED the API for the field, so neither could honour it.
# The cluster states it is read on are pinned by the shared fixture,
# scripts/tests/fixtures/installer_parity.json.
_TB_NODE_JSONPATH='{range .items[*]}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{" "}{.spec.unschedulable}{"\n"}{end}'

# ONE ranking of the cluster's nodes, shared by _machine_training_resources and
# _machine_training_ceiling.
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
# Extracted because the loop was written out TWICE, once per
# caller, and the cordon skip would have had to be added to both. Two copies of
# a selection rule is exactly how the (memory, cpu) / (cpu, memory) split above
# happened; one copy cannot drift from itself.
#
# The contract's skipped_nodes, both honoured here:
#   * spec.unschedulable (cordoned) — a cordoned node accepts no new pods, so
#     anchoring on one writes an envelope that cannot schedule. On a
#     heterogeneous cluster a cordoned LARGE node would otherwise win the
#     anchor outright and every training pod would sit Pending with no obvious
#     cause. The cordon skip matters on any cluster with a cordoned node.
#   * allocatable cpu or memory unparseable — skipped rather than coerced to 0,
#     so a node whose memory unit we do not speak cannot take the anchor and
#     drag a perfectly sizeable sibling down to the literal.
#
# Sets _TB_ANCHOR_CPU_MILLI / _TB_ANCHOR_MEM_BYTES and returns 0 when at least
# one node was measured; returns 1 when the cluster is unreadable or no node
# survived the skips. Callers must treat 1 as "I could not measure the machine",
# which is NOT the same as "the machine is too small".
_anchor_largest_schedulable() {
  has kubectl || return 1
  local lines cpu mem unsched cpu_m mem_b best_cpu=0 best_mem=0 seen=0
  # Bounded: a wedged API server must degrade to the static default, never
  # hang values generation.
  lines="$(kubectl get nodes --request-timeout=10s -o jsonpath="$_TB_NODE_JSONPATH" 2>/dev/null)" || return 1
  [[ -n "$lines" ]] || return 1
  while read -r cpu mem unsched; do
    [[ -n "$cpu" && -n "$mem" ]] || continue
    # Cordoned: skipped BEFORE ranking, so it can never win the anchor.
    # Written `!= ... || continue`, not `== ... && continue`: the latter
    # evaluates to 1 for every SCHEDULABLE node, which under the installer's
    # `set -euo pipefail` aborts the whole run (the shape the shared
    # `early-close` gate in tracebloc/org-config's code-quality.yml catches).
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

# Echo "cpu=N,memory=MMi" sized to the largest schedulable node, or nothing when
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
  # literal — larger than such a machine, a known bug; since
  # it is the contract floor, which fits. The fallback structure is
  # deliberately kept revertable — only the value it writes changed.
  { (( run_cpu_m >= _TB_ENVELOPE_FLOOR_CPU_MILLI )) \
    && (( run_mem_b >= _TB_ENVELOPE_FLOOR_MEM_BYTES )); } || return 0
  printf 'cpu=%d,memory=%dMi' "$(( run_cpu_m / 1000 ))" "$(( run_mem_b / 1024 / 1024 ))"
}

# The LIMITS half of a training envelope: memory only, never cpu.
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
# RESOURCE_LIMITS as the COMPLETE limits envelope. An older
# image MERGES the parsed pairs onto its built-in cpu=2,memory=8Gi literal, so
# an omitted `cpu` comes back as a 2-core LIMIT under a 7-core REQUEST -- which
# Kubernetes rejects outright, and the pod never schedules. Do not ship this
# chart to an edge whose client-runtime predates the limits ordering fix.
_training_limits() {
  local size="$1" out="" pair
  local IFS=,
  for pair in $size; do
    # TRIM FIRST. `case " cpu=7 " in cpu=*)` does NOT match, so an operator who
    # wrote `TRACEBLOC_TRAINING_RESOURCES="cpu=7, memory=29Gi"` would keep the
    # cpu limit -- silently, and in the dangerous direction. The retired
    # PowerShell core trimmed via `.Trim()`, so skipping it here was also a twin
    # DIVERGENCE: the same shared contract, two different control flows, which is
    # the same bug class as the other shared-contract copies. jobs-manager's own parser
    # strips too, so trimmed output is what it would have read anyway.
    pair="${pair#"${pair%%[![:space:]]*}"}"
    pair="${pair%"${pair##*[![:space:]]}"}"
    [[ -n "$pair" ]] || continue
    # CASE-INSENSITIVE, via character classes rather than `${pair,,}` — this
    # bootstrap has to run under macOS's bash 3.2, which has no case conversion.
    #
    # It was a twin DIVERGENCE: the PowerShell core's
    # `-like 'cpu=*'` was case-insensitive, so `CPU=7,memory=29Gi` dropped the
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
  # mirrors the requests side back and resurrects the very
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
# when the cluster is unreadable.
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
# cannot do better without measuring. That fallback is the
# contract floor, not the 8Gi literal, so it now FITS; the "read it, it is
# small" case likewise gets the honest remainder, which fits too.
#
# Node selection is the SAME _anchor_largest_schedulable the sizing path uses,
# so the warning the caller prints can never describe a different node than the
# value it wrote.
_machine_training_ceiling() {
  _anchor_largest_schedulable || return 0

  local run_cpu_m=$(( _TB_ANCHOR_CPU_MILLI - _TB_ENVELOPE_OVERHEAD_CPU_MILLI ))
  local run_mem_b=$(( _TB_ANCHOR_MEM_BYTES - _TB_ENVELOPE_OVERHEAD_MEM_BYTES ))
  (( run_cpu_m < 0 )) && run_cpu_m=0
  (( run_mem_b < 0 )) && run_mem_b=0

  # Memory in floored MiB, the contract's writing unit (v10): whole GiB threw
  # away up to 1023 MiB of the run's room.
  local cores=$(( run_cpu_m / 1000 ))
  local mib=$(( run_mem_b / 1024 / 1024 ))

  if (( run_cpu_m >= _TB_ENVELOPE_FLOOR_CPU_MILLI )) \
     && (( run_mem_b >= _TB_ENVELOPE_FLOOR_MEM_BYTES )); then
    printf 'cpu=%d,memory=%dMi|viable' "$cores" "$mib"
    return 0
  fi

  # Below the contract floor. Report the honest remainder when it is a
  # REQUESTABLE shape -- at least one whole core and one whole GiB. Reachable
  # only on macOS/Windows, where the memory preflight warns instead of failing.
  if (( cores >= 1 && mib >= 1024 )); then
    printf 'cpu=%d,memory=%dMi|undersized' "$cores" "$mib"
    return 0
  fi

  # A node WAS parsed and the remainder is not even a requestable shape (cpu=0 is
  # not a training request). Reported as its own verdict rather than as silence,
  # because silence here is indistinguishable from "I could not read the
  # cluster" -- and those must not be treated alike. Warning that a machine is
  # too small when we never managed to measure it is a fabrication, and the
  # caller used to do exactly that by re-probing `kubectl get nodes -o name`:
  # any listable node, including one whose allocatable would not parse or which
  # is not Ready yet, tripped the hard warning. The PowerShell core only flagged
  # it after a PARSED node, so the two disagreed on the same cluster -- the
  # divergence class the shared helper exists to remove.
  printf '|unschedulable'
  return 0
}

# The installed release's RESOURCE_PROVENANCE (nested under env:), or nothing.
# Same awk shape as _existing_training_resources — `helm get values` strips the
# quotes our values file writes.
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
# exists to delete.
#
# Sets, in the CALLER's scope (so a subshell cannot swallow them):
#   _TB_TRAINING_SIZE       "cpu=N,memory=MMi" (or the user's own)
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
  # sizing exists to fix. Only a value that differs from it survives.
  # Matched against the FROZEN historic literal, NOT _TRAINING_DEFAULT: since
  # the latter is the contract floor, which a human may deliberately
  # pin — and precedence step 2 says that choice must survive re-install, so the
  # gate must not re-derive it. A field install predating the floor still carries the
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

# The per-run training size for the generated values ("cpu=N,memory=MMi").
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

# _envelope_display SIZE -- a training envelope ("cpu=12,memory=10854Mi") as a person
# reads it: "12 CPU cores · 10.6 GB memory", GB in tenths to the nearest. Nothing when
# SIZE has no readable cpu and memory pair.
_envelope_display() {
  local cpu_m mem_b tenths cores gb unit="CPU cores"
  cpu_m="$(_cpu_to_milli "$(_envelope_dimension "${1:-}" cpu)")"
  mem_b="$(_mem_to_bytes "$(_envelope_dimension "${1:-}" memory)")"
  [[ "$cpu_m" =~ ^[0-9]+$ && "$mem_b" =~ ^[0-9]+$ ]] || return 0
  cores="$(( cpu_m / 1000 ))"
  if (( cpu_m % 1000 != 0 )); then cores="${cores}.$(( cpu_m % 1000 / 100 ))"; fi
  if [[ "$cores" == 1 ]]; then unit="CPU core"; fi
  tenths=$(( (mem_b / 1048576 * 10 + 512) / 1024 ))
  gb="$(( tenths / 10 ))"
  if (( tenths % 10 != 0 )); then gb="${gb}.$(( tenths % 10 ))"; fi
  printf '%s %s · %s GB memory' "$cores" "$unit" "$gb"
}

# The training envelope this run wrote, as _envelope_display reads it, for the summary:
# empty until step e writes one, and when it wrote none a run can schedule.
_TB_COMPUTE_SHOWN=""

# _compute_preview -- at the end of step c, the envelope step e is going to write, from
# the same resolution and fit, in a subshell so nothing it sets reaches step e. Nothing
# when the fit refuses it, cannot read the node, or finds no size a run can schedule.
_compute_preview() {
  (
    _resolve_training_size
    _fit_training_envelope
    case "${_TB_FIT_VERDICT:-}" in refused|unverified) exit 0 ;; esac
    (( ${_TB_TRAINING_UNSCHEDULABLE:-0} == 0 )) || exit 0
    _envelope_display "$_TB_TRAINING_SIZE"
  ) 2>>"${LOG_FILE:-/dev/null}" || true
}

# print_environment_created -- step c's last lines: the secure environment is there,
# and training has a size that fits it (_compute_preview). The size itself is the
# summary's Compute row.
print_environment_created() {
  local compute
  compute="$(_compute_preview)"
  success "Secure environment created"
  if [[ -n "$compute" ]]; then
    success "Compute resources configured"
  fi
}

# ── is the envelope actually schedulable here? ────────────────
#
# Everything above sizes the envelope against ALLOCATABLE and stops. Nothing then
# asked whether the number written can be scheduled beside what else runs on the
# node: the chart's own control plane (the embedded _TB_CP_FOOTPRINT_* constants,
# generated from the render by scripts/gen-footprint-embed.sh) plus the
# distribution's system pods (~140 MiB / 200 m of coredns and metrics-server on
# k3s). When this was written the chart requested 3136 MiB / 900 m -- MORE than
# the 3 GiB reserve the envelope subtracts -- so `allocatable - 3 GiB` over-asked
# at EVERY machine size and the training pod sat `Pending / Insufficient memory`
# while the installer printed `Training size: ...` and cli doctor said OK.
# The interim trim (chart 1.9.112) brought the control plane under the
# reserve, so today the fit below is a no-op on every golden vector; it stays
# because the constants are generated, not promised, and the next chart that
# out-requests the reserve should be reduced here rather than sit Pending again.
#
# The two functions below make the installer own that question at the moment it
# writes the envelope. The 3 GiB constant itself is not touched here: fixing the
# number is this is the check that makes a wrong number visible.

# The pod lines contract for _measured_system_requests. `|`-separated, NOT
# whitespace: a Pending pod has no nodeName, and `read` would collapse the empty
# field and shift every column right. Per pod:
#   <namespace>|<phase>|<nodeName>|<app requests>|<init requests>
# where each requests field is `cpu/memory,` repeated per container -- an empty
# cpu or memory reads as "no request", which is what Kubernetes means by it.
_TB_PODS_JSONPATH='{range .items[*]}{.metadata.namespace}{"|"}{.status.phase}{"|"}{.spec.nodeName}{"|"}{range .spec.containers[*]}{.resources.requests.cpu}{"/"}{.resources.requests.memory}{","}{end}{"|"}{range .spec.initContainers[*]}{.resources.requests.cpu}{"/"}{.resources.requests.memory}{","}{end}{"\n"}{end}'
# Namespaces and who owns them: `<name>|<meta.helm.sh/release-name>` per line.
_TB_NAMESPACES_JSONPATH='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}{end}'

# The raw value of ONE dimension of an envelope string: `_envelope_dimension
# "cpu=7, Memory=29Gi" memory` -> `29Gi`. Keys match case-insensitively and pairs
# are trimmed, the same tolerance _training_limits extends to a human-typed
# override. Echoes nothing when the key is absent. IFS is local to this function
# on purpose: a `local IFS` in the caller would leak into every `read` in the
# functions it calls next (bash scoping is dynamic).
_envelope_dimension() {
  local size="$1" want="$2" pair k
  local IFS=,
  for pair in $size; do
    pair="${pair#"${pair%%[![:space:]]*}"}"; pair="${pair%"${pair##*[![:space:]]}"}"
    k="${pair%%=*}"
    case "$want:$k" in
      cpu:[Cc][Pp][Uu]|memory:[Mm][Ee][Mm][Oo][Rr][Yy]) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
}

# The effective request of ONE pod's worth of `cpu/memory,` container fields:
# sum(app containers) for the first argument, max(init containers) for the
# second, per resource -- the scheduler's formula, the same one
# control-plane-footprint.sh applies to the render. Echoes "<mem bytes> <cpu m>"
# or NOTHING when a quantity is present but unreadable, which the caller must
# treat as "this measurement is unusable", never as zero.
_pod_effective_requests() {
  local apps="$1" inits="$2" field c m cm mm
  local app_m=0 app_c=0 init_m=0 init_c=0
  local IFS=,
  for field in $apps; do
    [[ -n "$field" ]] || continue
    c="${field%%/*}"; m="${field#*/}"
    cm=0; mm=0
    if [[ -n "$c" ]]; then cm="$(_cpu_to_milli "$c")"; [[ -n "$cm" ]] || return 0; fi
    if [[ -n "$m" ]]; then mm="$(_mem_to_bytes "$m")"; [[ -n "$mm" ]] || return 0; fi
    app_c=$(( app_c + cm )); app_m=$(( app_m + mm ))
  done
  for field in $inits; do
    [[ -n "$field" ]] || continue
    c="${field%%/*}"; m="${field#*/}"
    cm=0; mm=0
    if [[ -n "$c" ]]; then cm="$(_cpu_to_milli "$c")"; [[ -n "$cm" ]] || return 0; fi
    if [[ -n "$m" ]]; then mm="$(_mem_to_bytes "$m")"; [[ -n "$mm" ]] || return 0; fi
    # `if`, never `(( )) && x=`, as the last command of a loop body: the false
    # arm leaves the loop with status 1 (see _print_fit_lines).
    if (( cm > init_c )); then init_c=$cm; fi
    if (( mm > init_m )); then init_m=$mm; fi
  done
  if (( init_m > app_m )); then app_m=$init_m; fi
  if (( init_c > app_c )); then app_c=$init_c; fi
  printf '%s %s' "$app_m" "$app_c"
}

# What the pods ALREADY ON THE CLUSTER request, that the chart derivation does
# not already count. Sets _TB_SYS_MEM_BYTES / _TB_SYS_CPU_MILLI / _TB_SYS_NOTE and
# returns 0 when measured; returns 1 (and sets _TB_SYS_NOTE to say why) when the
# cluster could not be read or a quantity could not be parsed. The caller then
# verifies against the chart derivation alone AND SAYS SO -- an unreadable pod
# list is not a footprint of zero, but it is also not a reason to refuse an
# install on a cluster whose nodes we could read.
#
# EXCLUDED, because the chart derivation already counts them (a re-install would
# otherwise count the control plane twice): every pod in the release namespace
# -- the chart's own workloads AND the training pods jobs-manager spawns there,
# which are the very envelope being sized -- and every pod in a namespace whose
# `meta.helm.sh/release-name` annotation names this release (the node-agents
# namespace the chart creates for its DaemonSets). Pod templates carry only an
# `app` label, so ownership is read off the NAMESPACE, not the pod. Terminal
# pods (Succeeded/Failed) hold no reservation and are skipped; a pod with no
# nodeName is not on any node yet.
#
# PER NODE, then the MAX across nodes. A training pod takes everything from ONE
# node and this reader does not know which node the anchor is by name (the node
# contract is pinned to three fields). On the
# single-node edge this ticket is about the two are the same number; on a
# multi-node cluster the max is conservative -- it can only make the envelope
# smaller than strictly necessary, never larger than what schedules.
_measured_system_requests() {
  _TB_SYS_MEM_BYTES=0
  _TB_SYS_CPU_MILLI=0
  _TB_SYS_NOTE=""
  has kubectl || { _TB_SYS_NOTE="kubectl is not available"; return 1; }

  # Namespaces this release owns. Failing to read them is NOT fatal to the
  # measurement: only the release namespace is then excluded, which on a
  # re-install can over-count the node-agents DaemonSets -- the conservative
  # direction -- and the note says so.
  local own_ns="${namespace:-}" ns_lines ns owner
  if ns_lines="$(kubectl get namespaces --request-timeout=10s -o jsonpath="$_TB_NAMESPACES_JSONPATH" 2>/dev/null)"; then
    while IFS='|' read -r ns owner; do
      [[ -n "$ns" ]] || continue
      [[ "$owner" == "${namespace:-}" && -n "$owner" ]] || continue
      own_ns="$own_ns $ns"
    done <<< "$ns_lines"
  else
    _TB_SYS_NOTE="namespace ownership unreadable; only the release namespace was excluded"
  fi

  local lines
  lines="$(kubectl get pods --all-namespaces --request-timeout=10s -o jsonpath="$_TB_PODS_JSONPATH" 2>/dev/null)" \
    || { _TB_SYS_NOTE="the pod list could not be read"; return 1; }
  [[ -n "$lines" ]] || { _TB_SYS_NOTE="the pod list was empty"; return 1; }

  # Two parallel indexed arrays, not an associative one -- this must run under
  # macOS bash 3.2.
  local -a node_names=() node_mem=() node_cpu=()
  local phase node apps inits eff em ec i found pods=0
  while IFS='|' read -r ns phase node apps inits; do
    [[ -n "$ns" && -n "$node" ]] || continue
    case " $own_ns " in *" $ns "*) continue ;; esac
    case "$phase" in Succeeded|Failed) continue ;; esac
    eff="$(_pod_effective_requests "$apps" "$inits")"
    if [[ -z "$eff" ]]; then
      _TB_SYS_NOTE="a pod in ${ns} carries a request quantity this installer cannot parse (${apps}${inits})"
      return 1
    fi
    read -r em ec <<< "$eff"
    found=-1
    for i in "${!node_names[@]}"; do
      if [[ "${node_names[$i]}" == "$node" ]]; then found=$i; break; fi
    done
    if (( found < 0 )); then
      node_names+=("$node"); node_mem+=("$em"); node_cpu+=("$ec")
    else
      node_mem[$found]=$(( ${node_mem[$found]} + em ))
      node_cpu[$found]=$(( ${node_cpu[$found]} + ec ))
    fi
    pods=$(( pods + 1 ))
  done <<< "$lines"
  (( pods > 0 )) || { _TB_SYS_NOTE="no pod outside this release is scheduled yet"; return 1; }

  for i in "${!node_names[@]}"; do
    if (( ${node_mem[$i]} > _TB_SYS_MEM_BYTES )); then _TB_SYS_MEM_BYTES=${node_mem[$i]}; fi
    if (( ${node_cpu[$i]} > _TB_SYS_CPU_MILLI )); then _TB_SYS_CPU_MILLI=${node_cpu[$i]}; fi
  done
  [[ -n "$_TB_SYS_NOTE" ]] || _TB_SYS_NOTE="measured from ${pods} pod(s) across ${#node_names[@]} node(s)"
  return 0
}

# Verify -- and if it is ours, correct -- the envelope _resolve_training_size
# chose, against what this machine can actually schedule beside the platform.
#
# Reads _TB_TRAINING_SIZE and _TB_TRAINING_PROVENANCE. Sets, in the caller's
# scope:
#   _TB_FIT_VERDICT   fits | reduced | refused | pinned-over | unverified
#   _TB_FIT_CAUSE     on refused, what a person is told (_print_fit_refusal):
#                     memory | cpu | unreadable | broken
#   _TB_FIT_LINES     the arithmetic, one fact per line, for the caller to print
# and on `reduced` REWRITES _TB_TRAINING_SIZE to the largest whole-core /
# whole-MiB envelope that fits (never larger than what was chosen). The
# reduction can land below the contract floor while still being a requestable
# shape (>= 1 core, >= 1 GiB); that keeps the existing `undersized` semantics
# and sets _TB_TRAINING_UNDERSIZED so the caller warns.
#
# The verdicts, and who they apply to:
#   * installer-chosen (fresh or carried): fits, or reduced with the arithmetic,
#     or REFUSED when not even a 1-core/1-GiB run fits -- the caller must not
#     write the envelope. Refused too when the machine WAS measured but the
#     footprint constants are unreadable, or when the cluster cannot be read
#     and the chosen size is anything but the contract floor: an envelope this
#     installer picked and cannot verify is not written (fail closed).
#   * the contract floor with an unreadable cluster: `unverified`. It is the
#     smallest envelope the platform supports and the fallback that existed
#     before this check; the caller warns rather than refusing, so a cluster
#     whose nodes the installer may not list (restricted RBAC on a BYO cluster)
#     still installs, loudly.
#   * a human's choice (TRACEBLOC_TRAINING_RESOURCES, `tracebloc resources
#     set`, or an unattributable carry): never altered -- precedence rules 1
#     and 2 say a human choice survives. A pin that does not fit is
#     `pinned-over`, warned with the arithmetic; one the installer cannot
#     verify is `unverified`.
#
# Like the resolver, this emits NOTHING on stdout: _training_resources is
# captured with $(...), and text here would end up inside the value.
#
# Printing is the caller's job, through _print_fit_lines. That helper uses an
# `if`, not `[[ -n ]] && printer`, and ends in `return 0`: _TB_FIT_LINES can end
# in a newline, so the last `read` yields an empty line and a `&&` list leaves
# the loop with status 1. MEASURED on bash 3.2 and 5: such a loop survives
# `set -e` inline, but as the LAST statement of a function it makes the function
# return 1 and the caller's errexit fires -- here, on a machine whose envelope
# FITS, on the way to saying so. Same trap _anchor_largest_schedulable records.
_print_fit_lines() {   # $1 = printer: hint (on screen) or log (log file only); $2 = lines (default: _TB_FIT_LINES)
  local _l
  while IFS= read -r _l; do
    if [[ -n "$_l" ]]; then
      if [[ "$1" == "log" ]]; then log "envelope fit: $_l"; else "$1" "  $_l"; fi
    fi
  done <<< "${2-$_TB_FIT_LINES}"
  return 0
}

# The refusal, worded ONCE for both places it can fire: the fit
# after values generation and the estimate before the cluster is created. Same
# arithmetic lines, same remedy, same TRACEBLOC_TRAINING_RESOURCES way out -- so
# an operator refused early reads exactly what a late refusal would have said.
# $1 = the headline, $2 = the lines to print, $3 = the closing error,
# $4 = the cause (_TB_FIT_CAUSE), which picks the ✖ line and the remedy.
_print_fit_refusal() {
  # The addons k3s schedules beside the platform are part
  # of what the node must hold, so they are part of what the remedy asks for.
  local _rf _rf_mem=0 _rf_cpu=0
  _rf="$(_system_requests_floor)"
  if [[ -n "$_rf" ]]; then read -r _rf_mem _rf_cpu <<< "$_rf"; fi
  # The arithmetic is for machines and the log (e2e reads its grammar); a person
  # reads one ✖ line and, in the end block, what to do about its cause.
  tb_machine_lines warn "$1"
  tb_machine_lines _print_fit_lines hint "$2"
  tb_machine_lines hint "  The secure environment needs ~$(( (_TB_CP_FOOTPRINT_MEM_BYTES + _rf_mem + _TB_ENVELOPE_FLOOR_MEM_BYTES) / 1024 / 1024 )) MiB and $(( _TB_CP_FOOTPRINT_CPU_MILLI + _rf_cpu + _TB_ENVELOPE_FLOOR_CPU_MILLI )) m free on one node for the smallest run. To install anyway, set TRACEBLOC_TRAINING_RESOURCES=cpu=N,memory=MGi yourself."
  case "${4:-}" in
    memory)
      # The figure preflight's memory gate names (_pf_machine_need_gb).
      local _rf_gb=""
      if declare -F _pf_machine_need_gb >/dev/null 2>&1; then
        _rf_gb="$(_pf_machine_need_gb 2>/dev/null)" || _rf_gb=""
      fi
      if [[ "$_rf_gb" =~ ^[0-9]+(\.[0-9])?$ ]]; then
        tb_fail_next "Use a machine with at least ${_rf_gb} GB of memory." ""
      else
        tb_fail_next "Use a machine with more memory." ""
      fi
      error_said "Not enough memory to run a training" "$3"
      ;;
    cpu)
      # No core count: nothing derives a machine-core figure, and a restated one drifts.
      tb_fail_next "Use a machine with more CPU cores." ""
      error_said "Not enough CPU to run a training" "$3"
      ;;
    unreadable)
      tb_fail_next "It's safe to run the installer again:"
      error_said "Couldn't read this machine's resources" "$3"
      ;;
    *)
      # broken, and a refusal that names no cause: either way the installer is at fault.
      tb_fail_next "Run the latest installer:"
      error_said "This installer is broken" "$3"
      ;;
  esac
}

# FAIL CLOSED on the footprint: a blank or non-numeric embed is a broken
# installer, and nothing sensible can be verified against it. Shared by the fit
# and the pre-create estimate, so both refuse on the same condition. Returns 0
# (and sets the verdict) when it refused.
_fit_footprint_refused() {
  if [[ ! "${_TB_CP_FOOTPRINT_MEM_BYTES:-}" =~ ^[0-9]+$ || ! "${_TB_CP_FOOTPRINT_CPU_MILLI:-}" =~ ^[0-9]+$ ]]; then
    _TB_FIT_VERDICT="refused"; _TB_FIT_CAUSE="broken"
    _TB_FIT_LINES="the chart footprint constants (_TB_CP_FOOTPRINT_*) are missing or not numeric -- this installer cannot verify any envelope"
    return 0
  fi
  if [[ ! "${_TB_CP_TRANSIENT_MEM_BYTES:-}" =~ ^[0-9]+$ || ! "${_TB_CP_TRANSIENT_CPU_MILLI:-}" =~ ^[0-9]+$ || ! "${_TB_CP_TRANSIENT_RESERVE_MIN_CPU_MILLI:-}" =~ ^[0-9]+$ ]]; then
    _TB_FIT_VERDICT="refused"; _TB_FIT_CAUSE="broken"
    _TB_FIT_LINES="the hourly-job constants (_TB_CP_TRANSIENT_*) are missing or not numeric -- this installer cannot verify any envelope"
    return 0
  fi
  if [[ ! "${_TB_ENVELOPE_INGESTION_MEM_BYTES:-}" =~ ^[0-9]+$ || ! "${_TB_ENVELOPE_INGESTION_CPU_MILLI:-}" =~ ^[0-9]+$ ]]; then
    _TB_FIT_VERDICT="refused"; _TB_FIT_CAUSE="broken"
    _TB_FIT_LINES="the ingestion Job constants (_TB_ENVELOPE_INGESTION_*) are missing or not numeric -- this installer cannot verify any envelope"
    return 0
  fi
  return 1
}

_fit_training_envelope() {
  _TB_FIT_VERDICT=""
  _TB_FIT_CAUSE=""
  _TB_FIT_LINES=""
  _TB_FIT_INGEST_WAITS=0
  local size="${_TB_TRAINING_SIZE:-}" prov="${_TB_TRAINING_PROVENANCE:-}"
  local ours=0
  [[ "$prov" == "installer" ]] && ours=1

  # FAIL CLOSED on the footprint (see _fit_footprint_refused).
  if _fit_footprint_refused; then return 0; fi

  # The envelope's own two dimensions. Case-insensitive keys, trimmed pairs --
  # the same tolerance _training_limits extends to a human-typed override.
  local env_cpu_m env_mem_b
  env_cpu_m="$(_cpu_to_milli "$(_envelope_dimension "$size" cpu)")"
  env_mem_b="$(_mem_to_bytes "$(_envelope_dimension "$size" memory)")"

  # The machine. Unreadable is decided by who chose the size (see the header).
  if ! _anchor_largest_schedulable; then
    if (( ours )) && [[ "$size" != "$_TRAINING_DEFAULT" ]]; then
      _TB_FIT_VERDICT="refused"; _TB_FIT_CAUSE="unreadable"
      _TB_FIT_LINES="node allocatable could not be read, and ${size} is an installer-chosen envelope that cannot be verified without it"
    else
      _TB_FIT_VERDICT="unverified"
      _TB_FIT_LINES="node allocatable could not be read; ${size} was written without checking that it can schedule beside the platform"
    fi
    return 0
  fi
  local alloc_mem_b="$_TB_ANCHOR_MEM_BYTES" alloc_cpu_m="$_TB_ANCHOR_CPU_MILLI"

  if [[ -z "$env_cpu_m" || -z "$env_mem_b" ]]; then
    if (( ours )); then
      _TB_FIT_VERDICT="refused"; _TB_FIT_CAUSE="broken"
      _TB_FIT_LINES="the installer-chosen envelope '${size}' has no readable cpu and memory pair -- refusing to write what cannot be verified"
    else
      _TB_FIT_VERDICT="unverified"
      _TB_FIT_LINES="'${size}' has no readable cpu and memory pair, so its fit on this machine was not checked"
    fi
    return 0
  fi

  # What else the node must hold: the chart's control plane, plus whatever
  # system pods are already scheduled and are not the chart's.
  local sys_mem_b=0 sys_cpu_m=0 sys_how
  if _measured_system_requests; then
    sys_mem_b="$_TB_SYS_MEM_BYTES"; sys_cpu_m="$_TB_SYS_CPU_MILLI"
    sys_how="measured: ${_TB_SYS_NOTE}"
  else
    sys_how="NOT measured (${_TB_SYS_NOTE}); verified against the chart derivation only"
  fi
  # Native k3s: never count less than the addons k3s is about to
  # schedule (see _TB_K3S_ADDON_*). Per dimension, so
  # a measurement that already includes them -- or more -- is used as-is.
  local floor floor_mem_b floor_cpu_m
  floor="$(_system_requests_floor)"
  if [[ -n "$floor" ]]; then
    read -r floor_mem_b floor_cpu_m <<< "$floor"
    if (( sys_mem_b < floor_mem_b || sys_cpu_m < floor_cpu_m )); then
      if (( sys_mem_b < floor_mem_b )); then sys_mem_b=$floor_mem_b; fi
      if (( sys_cpu_m < floor_cpu_m )); then sys_cpu_m=$floor_cpu_m; fi
      sys_how="${sys_how}; raised to the k3s addon floor ($(( floor_mem_b / 1024 / 1024 )) MiB / ${floor_cpu_m} m: coredns + metrics-server, which may not be scheduled yet)"
    fi
  fi
  _fit_verdict "allocatable on the largest schedulable node" "$alloc_mem_b" "$alloc_cpu_m" \
    "$sys_mem_b" "$sys_cpu_m" "$sys_how" "$size" "$env_mem_b" "$env_cpu_m" "$ours" "$prov"
}

# THE FIT RULE, over numbers only. Split out of
# _fit_training_envelope so the estimate that runs BEFORE the cluster is created
# (_precreate_fit_estimate) calls the rule itself rather than a copy of it:
# given what one node offers, what else it must hold, and the envelope, decide
# fits | reduced | refused | pinned-over and write the arithmetic. Everything
# about READING the machine stays in the callers.
#
# Args: ALLOC_LABEL ALLOC_MEM_B ALLOC_CPU_M SYS_MEM_B SYS_CPU_M SYS_HOW SIZE
#       ENV_MEM_B ENV_CPU_M OURS PROV
# Reads the embedded _TB_CP_FOOTPRINT_* (the caller has already refused a broken
# embed) and the contract floor. On a node with at least
# _TB_CP_TRANSIENT_RESERVE_MIN_CPU_MILLI allocatable it also reserves the hourly
# CronJobs' _TB_CP_TRANSIENT_*; below that, nothing changes. Sets _TB_FIT_VERDICT / _TB_FIT_LINES and, on
# `reduced`, _TB_TRAINING_SIZE (and _TB_TRAINING_UNDERSIZED) -- in the CALLER's
# scope, so a caller that must not leave a size behind shadows them with locals.
#
# The ingestion Job (_TB_ENVELOPE_INGESTION_*) is a data upload, which can start
# while a run trains. An installer-chosen run is sized to leave its requests
# free, but never below the contract floor in a dimension where the run alone
# would have reached it: a smaller run that never trains is worse than an upload
# that waits. Where the Job does not fit beside the size written -- that, or a
# human's pin -- _TB_FIT_INGEST_WAITS=1 so the caller says an upload waits for
# training. Whether the run itself fits or is refused is decided without it.
_fit_verdict() {
  local alloc_label="$1" alloc_mem_b="$2" alloc_cpu_m="$3" sys_mem_b="$4" sys_cpu_m="$5" sys_how="$6"
  local size="$7" env_mem_b="$8" env_cpu_m="$9" ours="${10}" prov="${11}"
  local fp_mem_b="$_TB_CP_FOOTPRINT_MEM_BYTES" fp_cpu_m="$_TB_CP_FOOTPRINT_CPU_MILLI"
  local mib=$(( 1024 * 1024 )) gib=$(( 1024 * 1024 * 1024 ))
  # The hourly CronJobs' transient, reserved only on a node large enough
  # (_TB_CP_TRANSIENT_RESERVE_MIN_CPU_MILLI).
  local tr_mem_b=0 tr_cpu_m=0 tr_part=""
  if (( alloc_cpu_m >= _TB_CP_TRANSIENT_RESERVE_MIN_CPU_MILLI )); then
    tr_mem_b="$_TB_CP_TRANSIENT_MEM_BYTES"; tr_cpu_m="$_TB_CP_TRANSIENT_CPU_MILLI"
    tr_part=" + hourly jobs (auto-upgrade, image refresh) $(( tr_mem_b / mib )) MiB / ${tr_cpu_m} m"
  fi
  local need_mem_b=$(( fp_mem_b + tr_mem_b + sys_mem_b ))
  local need_cpu_m=$(( fp_cpu_m + tr_cpu_m + sys_cpu_m ))
  local ing_mem_b="$_TB_ENVELOPE_INGESTION_MEM_BYTES" ing_cpu_m="$_TB_ENVELOPE_INGESTION_CPU_MILLI"
  _TB_FIT_INGEST_WAITS=0

  _TB_FIT_LINES="${alloc_label}: $(( alloc_mem_b / mib )) MiB / ${alloc_cpu_m} m"$'\n'
  _TB_FIT_LINES+="control plane (chart) $(( fp_mem_b / mib )) MiB / ${fp_cpu_m} m${tr_part} + system pods $(( sys_mem_b / mib )) MiB / ${sys_cpu_m} m = $(( need_mem_b / mib )) MiB / ${need_cpu_m} m (${sys_how})"$'\n'
  _TB_FIT_LINES+="envelope ${size} = $(( env_mem_b / mib )) MiB / ${env_cpu_m} m"$'\n'

  local mem_over=$(( env_mem_b + need_mem_b - alloc_mem_b ))
  local cpu_over=$(( env_cpu_m + need_cpu_m - alloc_cpu_m ))
  local mem_fits=0 cpu_fits=0
  (( mem_over <= 0 )) && mem_fits=1
  (( cpu_over <= 0 )) && cpu_fits=1
  if (( mem_fits )); then
    _TB_FIT_LINES+="memory: $(( env_mem_b / mib )) + $(( need_mem_b / mib )) = $(( (env_mem_b + need_mem_b) / mib )) MiB <= $(( alloc_mem_b / mib )) MiB ($(( -mem_over / mib )) MiB headroom)"$'\n'
  else
    _TB_FIT_LINES+="memory: $(( env_mem_b / mib )) + $(( need_mem_b / mib )) = $(( (env_mem_b + need_mem_b) / mib )) MiB > $(( alloc_mem_b / mib )) MiB ($(( mem_over / mib )) MiB OVER)"$'\n'
  fi
  if (( cpu_fits )); then
    _TB_FIT_LINES+="cpu: ${env_cpu_m} + ${need_cpu_m} = $(( env_cpu_m + need_cpu_m )) m <= ${alloc_cpu_m} m ($(( -cpu_over )) m headroom)"$'\n'
  else
    _TB_FIT_LINES+="cpu: ${env_cpu_m} + ${need_cpu_m} = $(( env_cpu_m + need_cpu_m )) m > ${alloc_cpu_m} m (${cpu_over} m OVER)"$'\n'
  fi

  # Does the ingestion Job fit beside this envelope as well?
  local ing_fits=0
  (( env_mem_b + need_mem_b + ing_mem_b <= alloc_mem_b && env_cpu_m + need_cpu_m + ing_cpu_m <= alloc_cpu_m )) && ing_fits=1
  local ing_part="ingestion Job (a data ingest) $(( ing_mem_b / mib )) MiB / ${ing_cpu_m} m"

  if (( mem_fits && cpu_fits && ing_fits )); then
    _TB_FIT_VERDICT="fits"
    _TB_FIT_LINES+="${ing_part}: fits beside the run"
    return 0
  fi

  if (( ! ours )); then
    if (( mem_fits && cpu_fits )); then
      _TB_FIT_VERDICT="fits"
      _TB_FIT_INGEST_WAITS=1
      _TB_FIT_LINES+="${ing_part}: does not fit beside ${size}, which was chosen by a human (${prov}) and is written as-is"
      return 0
    fi
    _TB_FIT_VERDICT="pinned-over"
    _TB_FIT_LINES+="this size was chosen by a human (${prov}), so it is written as-is; training pods will stay Pending on this machine until it is lowered"
    return 0
  fi

  # Ours: the largest whole-core / whole-MiB envelope that fits -- floored (a
  # ceiling that rounds up is not a ceiling), and never larger than what was
  # chosen in either dimension -- first beside the platform alone, then with
  # the ingestion Job's requests left free too.
  local fit_mem_b=$(( alloc_mem_b - need_mem_b )) fit_cpu_m=$(( alloc_cpu_m - need_cpu_m ))
  (( fit_mem_b < 0 )) && fit_mem_b=0
  (( fit_cpu_m < 0 )) && fit_cpu_m=0
  local new_mib=$(( fit_mem_b / mib )) new_cores=$(( fit_cpu_m / 1000 ))
  local old_mib=$(( env_mem_b / mib )) old_cores=$(( env_cpu_m / 1000 ))
  (( new_mib > old_mib )) && new_mib=$old_mib
  (( new_cores > old_cores )) && new_cores=$old_cores

  if (( new_cores < 1 || new_mib < gib / mib )); then
    _TB_FIT_VERDICT="refused"
    # Short of memory, the CPU too or not, is memory's; only CPU short is the CPU's.
    if (( new_mib < gib / mib )); then _TB_FIT_CAUSE="memory"; else _TB_FIT_CAUSE="cpu"; fi
    _TB_FIT_LINES+="what fits is $(( fit_mem_b / mib )) MiB / ${fit_cpu_m} m -- not even a 1-core / 1-GiB run; there is no honest envelope to write"
    return 0
  fi

  local ing_fit_mem_b=$(( fit_mem_b - ing_mem_b )) ing_fit_cpu_m=$(( fit_cpu_m - ing_cpu_m ))
  (( ing_fit_mem_b < 0 )) && ing_fit_mem_b=0
  (( ing_fit_cpu_m < 0 )) && ing_fit_cpu_m=0
  local ing_mib=$(( ing_fit_mem_b / mib )) ing_cores=$(( ing_fit_cpu_m / 1000 ))
  (( ing_mib > new_mib )) && ing_mib=$new_mib
  (( ing_cores > new_cores )) && ing_cores=$new_cores
  # Never below the floor for the Job's sake: per dimension, the run keeps
  # min(what fits alone, the floor) when leaving the Job free would cut deeper.
  local floor_mib=$(( _TB_ENVELOPE_FLOOR_MEM_BYTES / mib )) floor_cores=$(( _TB_ENVELOPE_FLOOR_CPU_MILLI / 1000 ))
  local keep_mib=$new_mib keep_cores=$new_cores
  (( keep_mib > floor_mib )) && keep_mib=$floor_mib
  (( keep_cores > floor_cores )) && keep_cores=$floor_cores
  (( ing_mib > keep_mib )) && keep_mib=$ing_mib
  (( ing_cores > keep_cores )) && keep_cores=$ing_cores
  if (( keep_mib * mib + need_mem_b + ing_mem_b > alloc_mem_b || keep_cores * 1000 + need_cpu_m + ing_cpu_m > alloc_cpu_m )); then
    _TB_FIT_INGEST_WAITS=1
  fi

  if (( mem_fits && cpu_fits && keep_mib == old_mib && keep_cores == old_cores )); then
    # Already as small as the floor allows: the size stands, the upload waits.
    _TB_FIT_VERDICT="fits"
    _TB_FIT_LINES+="${ing_part}: does not fit beside ${size}, which is already the smallest run this machine is given"
    return 0
  fi

  _TB_TRAINING_SIZE="cpu=${keep_cores},memory=${keep_mib}Mi"
  _TB_FIT_VERDICT="reduced"
  _TB_FIT_LINES+="reduced ${size} -> ${_TB_TRAINING_SIZE}: $(( alloc_mem_b / mib )) - $(( need_mem_b / mib )) = $(( fit_mem_b / mib )) MiB -> ${new_mib} MiB; ${alloc_cpu_m} - ${need_cpu_m} = ${fit_cpu_m} m -> ${new_cores} core(s)"
  if (( keep_mib != new_mib || keep_cores != new_cores )); then
    _TB_FIT_LINES+="; less the ${ing_part}: $(( ing_fit_mem_b / mib )) MiB -> ${keep_mib} MiB, ${ing_fit_cpu_m} m -> ${keep_cores} core(s) (never below the floor for it)"
  fi
  if (( _TB_FIT_INGEST_WAITS )); then
    _TB_FIT_LINES+=$'\n'"${ing_part}: does not fit beside ${_TB_TRAINING_SIZE} without cutting the run below the floor"
  else
    _TB_FIT_LINES+=$'\n'"${ing_part}: fits beside the run"
  fi
  if (( keep_cores * 1000 < _TB_ENVELOPE_FLOOR_CPU_MILLI || keep_mib * mib < _TB_ENVELOPE_FLOOR_MEM_BYTES )); then
    _TB_TRAINING_UNDERSIZED=1
  fi
  return 0
}

# ── the fit, estimated BEFORE the cluster exists ──────────────
#
# The fit above runs when the values are generated, which is AFTER the cluster is
# created. A host that cannot hold even a 1-core / 1-GiB run beside the platform
# got the right verdict there -- and was left with an empty cluster to remove by
# hand. Every fact the refusal rests on is already known before anything is
# created, so this asks the same question first:
#
#   * what one node will offer: its memory and CPU (on Linux the host's; on a
#     Mac the node VM's; in WSL the WSL VM's), minus the node reservation this platform's
#     kubelet is about to be given (cluster.sh's generated TRACEBLOC_KUBELET_* block),
#     subtracted the way the kubelet subtracts it: capacity - kubeReserved -
#     systemReserved - evictionHard. An UNMEASURED platform gets no
#     reservation, here as on the node, and the arithmetic says so;
#   * what the node must hold: the embedded chart footprint, plus the k3s addon
#     floor (_system_requests_floor) -- the addons do not exist yet, but they
#     will, and the post-create fit never counts less than that floor
#     So this is still never PESSIMISTIC: it never
#     refuses a host the post-create fit would accept, and the fit after create
#     stays the authority for everything else (system pods beyond the addons);
#   * the envelope: the contract floor, the size the installer writes when a
#     machine cannot be sized. Refusal does not depend on it -- the fit refuses
#     only when what is left beside the platform is under one core or one GiB
#     -- so the floor asks exactly that.
#
# The decision is _fit_verdict itself, the rule the post-create fit applies, so
# the two cannot drift (rules 1 and 9); install-client-helm.bats drives both over
# one canned-host table and asserts the estimate never refuses what the fit
# accepts.
#
# NEVER REFUSES WHAT THE FIT WOULD NOT: a size from TRACEBLOC_TRAINING_RESOURCES
# is a human's, which the fit warns about (pinned-over) and never refuses; a
# caller's own TRACEBLOC_VALUES_FILE never meets the fit at all; an unreadable
# runtime is "cannot tell", not "too small". All three are `skipped`.
#
# Args: VM_MEM_BYTES VM_CPU_MILLI. Sets _TB_PRECREATE_VERDICT
# (refused | clear | skipped), _TB_PRECREATE_CAUSE (the fit's _TB_FIT_CAUSE, on
# refused) and _TB_PRECREATE_LINES. Leaves _TB_FIT_* and
# _TB_TRAINING_SIZE as it found them: the real fit must not inherit a verdict or
# a reduced size from an estimate.
_precreate_fit_estimate() {
  _TB_PRECREATE_VERDICT=""
  _TB_PRECREATE_CAUSE=""
  _TB_PRECREATE_LINES=""
  local vm_mem_b="${1:-}" vm_cpu_m="${2:-}"
  if [[ -n "${TRACEBLOC_TRAINING_RESOURCES:-}" ]]; then
    _TB_PRECREATE_VERDICT="skipped"
    _TB_PRECREATE_LINES="TRACEBLOC_TRAINING_RESOURCES is set: the size is a human's choice, which the fit warns about and never refuses"
    return 0
  fi
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    _TB_PRECREATE_VERDICT="skipped"
    _TB_PRECREATE_LINES="TRACEBLOC_VALUES_FILE is set: this install writes no training envelope, so there is nothing to fit"
    return 0
  fi
  if [[ ! "$vm_mem_b" =~ ^[0-9]+$ || ! "$vm_cpu_m" =~ ^[0-9]+$ ]] || (( vm_mem_b == 0 || vm_cpu_m == 0 )); then
    _TB_PRECREATE_VERDICT="skipped"
    _TB_PRECREATE_LINES="the container runtime's memory and CPU could not be read, so nothing is refused here; the fit after the cluster is created decides"
    return 0
  fi

  # Shadowed: the rule writes these in its caller's scope.
  local _TB_FIT_VERDICT="" _TB_FIT_CAUSE="" _TB_FIT_LINES="" _TB_TRAINING_SIZE="$_TRAINING_DEFAULT" _TB_TRAINING_UNDERSIZED=0 _TB_FIT_INGEST_WAITS=0
  if _fit_footprint_refused; then
    _TB_PRECREATE_VERDICT="refused"
    _TB_PRECREATE_CAUSE="$_TB_FIT_CAUSE"
    _TB_PRECREATE_LINES="$_TB_FIT_LINES"
    return 0
  fi

  local mib=$(( 1024 * 1024 ))
  local platform="unknown" res_mem_b=0 res_cpu_m=0 res_how kc="" km="" ks=""
  if declare -F _kubelet_reservation_platform >/dev/null 2>&1; then
    platform="$(_kubelet_reservation_platform)"
  fi
  if declare -F _kubelet_reservation_measured >/dev/null 2>&1 && _kubelet_reservation_measured "$platform"; then
    if ! read -r kc km ks < <(_kubelet_reservation_values "$platform" 2>/dev/null) || [[ -z "$ks" ]]; then
      _TB_PRECREATE_VERDICT="skipped"
      _TB_PRECREATE_LINES="the ${platform} node reservation cannot be read (a broken generated block, which the create path refuses on its own)"
      return 0
    fi
    res_cpu_m="$kc"
    res_mem_b=$(( (km + ks + TRACEBLOC_KUBELET_EVICTION_MEM_MIB) * mib ))
    res_how="the ${platform} node reservation (kubeReserved ${km} MiB / ${kc} m, systemReserved ${ks} MiB, eviction ${TRACEBLOC_KUBELET_EVICTION_MEM_MIB} MiB)"
  else
    res_how="no node reservation (none is measured for platform '${platform}', so the node will report allocatable == capacity)"
  fi
  local alloc_mem_b=$(( vm_mem_b - res_mem_b )) alloc_cpu_m=$(( vm_cpu_m - res_cpu_m ))
  if (( alloc_mem_b < 0 )); then alloc_mem_b=0; fi
  if (( alloc_cpu_m < 0 )); then alloc_cpu_m=0; fi

  # The addons the post-create fit will count whether or not they are scheduled
  # by then (its floor), so a host refused only because of them is refused here,
  # before there is a cluster to delete.
  local sys_mem_b=0 sys_cpu_m=0 sys_how floor
  floor="$(_system_requests_floor)"
  if [[ -n "$floor" ]]; then
    read -r sys_mem_b sys_cpu_m <<< "$floor"
    sys_how="the k3s addon floor ($(( sys_mem_b / mib )) MiB / ${sys_cpu_m} m: coredns + metrics-server, which the fit after create counts too); other system pods do not exist until the cluster does"
  else
    sys_how="NOT counted: the k3s addons do not exist until the cluster does, so this estimate can only be optimistic"
  fi

  local env_cpu_m env_mem_b
  env_cpu_m="$(_cpu_to_milli "$(_envelope_dimension "$_TRAINING_DEFAULT" cpu)")"
  env_mem_b="$(_mem_to_bytes "$(_envelope_dimension "$_TRAINING_DEFAULT" memory)")"
  _fit_verdict \
    "estimated allocatable per node, before the cluster exists (runtime $(( vm_mem_b / mib )) MiB / ${vm_cpu_m} m, minus ${res_how})" \
    "$alloc_mem_b" "$alloc_cpu_m" "$sys_mem_b" "$sys_cpu_m" \
    "$sys_how" \
    "$_TRAINING_DEFAULT" "$env_mem_b" "$env_cpu_m" 1 installer
  _TB_PRECREATE_LINES="$_TB_FIT_LINES"
  if [[ "$_TB_FIT_VERDICT" == "refused" ]]; then
    _TB_PRECREATE_VERDICT="refused"
    _TB_PRECREATE_CAUSE="$_TB_FIT_CAUSE"
  else
    _TB_PRECREATE_VERDICT="clear"
  fi
  return 0
}

# The gate native k3s runs before a new k3s's first step (k3s.sh
# _native_k3s_create_cluster). Reads the node's size through preflight.sh's runtime
# readers and refuses with the fit's own message shape.
#
# On native k3s (TRACEBLOC_SUBSTRATE_RESOLVED=k3s) the readers answer from the host, which
# is the node (preflight.sh), and the reservation is the `linux_k3s` key's,
# measured on native k3s. On macOS they answer the node's size, the
# VM mac-container.sh's rule gives, and the key is `unknown` until darwin_k3s is
# measured (2.1 part 5b). In tracebloc's WSL distro they read the distro's own
# /proc, which is the WSL VM's size, and the key is `windows_k3s`, a row 3.3's
# Windows cell measures. This gate is the first step of the
# create path that knows the key, so a table without that row is said here,
# once per run (cluster.sh).
_precreate_fit_gate() {
  local kb="" ncpu=""
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]] && declare -F _kubelet_reservation_warn_unmeasured >/dev/null 2>&1; then
    _kubelet_reservation_warn_unmeasured
  fi
  if declare -F _pf_runtime_mem_kb >/dev/null 2>&1; then kb="$(_pf_runtime_mem_kb)"; fi
  if declare -F _pf_runtime_ncpu >/dev/null 2>&1; then ncpu="$(_pf_runtime_ncpu)"; fi
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  [[ "$ncpu" =~ ^[0-9]+$ ]] || ncpu=0
  _precreate_fit_estimate "$(( kb * 1024 ))" "$(( ncpu * 1000 ))"
  case "$_TB_PRECREATE_VERDICT" in
    refused)
      _print_fit_refusal \
        "This machine cannot schedule a training beside the platform, so the cluster is not created:" \
        "$_TB_PRECREATE_LINES" \
        "Refusing before creating the cluster, so there is no cluster to delete." \
        "$_TB_PRECREATE_CAUSE"
      ;;
    clear)   _print_fit_lines log "$_TB_PRECREATE_LINES" ;;
    *)       log "pre-create fit estimate skipped: ${_TB_PRECREATE_LINES}" ;;
  esac
  return 0
}
