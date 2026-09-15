#!/usr/bin/env bash
# =============================================================================
#  measure-node-reservation.sh — what the kubelet and the container runtime
#  actually consume on an installer-provisioned k3d node, per platform.
# -----------------------------------------------------------------------------
#  WHY THIS EXISTS. On the nodes the installer provisions, `allocatable ==
#  capacity`: no kube-reserved, no system-reserved, no explicit memory eviction
#  threshold. So every consumer of allocatable (the training envelope, the
#  T-shirt ladder, jobs-manager admission) reads "the whole machine" as "what a
#  pod may have". Replacing that with a declared reservation is only honest if
#  the reservation is MEASURED, and measured on the platform it is written for:
#  a constant guessed once cannot be right on Docker Desktop, WSL2 and a bare
#  Linux host at the same time.
#
#  This harness is the measurement. It brings the cluster up through the
#  installer's own create_cluster() -- the same path e2e-cluster.sh exercises,
#  so the node under measurement IS the node a customer gets -- then samples
#  the kubelet's own accounting for two phases:
#
#    idle   nothing scheduled but the k3s system pods
#    load   a training-shaped cycle: pull of a real task image (2-8 GB), then a
#           pod that burns CPU, holds memory and emits logs for the phase
#
#  What is sampled, per node, every TB_MEASURE_INTERVAL_S seconds:
#    * /stats/summary systemContainers — `kubelet`, `runtime`, `pods`, `misc`
#      working set + rss + usageNanoCores. This is the accounting kube-reserved
#      is defined against, read from the kubelet itself.
#    * the node container's top-level cgroups (memory.current) as an
#      independent cross-check that does not depend on the kubelet's own
#      cgroup mapping (k3s maps kubelet and runtime to the same `/k3s` cgroup,
#      which is why the two rows usually agree).
#    * docker stats of the node container and of the k3d serverlb/tools
#      sidecars, which live in the VM but outside every node.
#  Plus once: capacity vs allocatable, and the live /configz reservation and
#  eviction settings (so the k3s STOCK disk thresholds are recorded from the
#  node, not from memory).
#
#  OUTPUT: one JSON record on stdout's last line and at TB_MEASURE_OUT, with
#  raw samples and a p50/p95/max summary per phase, node and container. The
#  record is the evidence a reservation is derived from; the derivation is
#  scripts/gen-node-reservation-embed.sh, which reads records, never this
#  script's stdout.
#
#  A "training-shaped" load is NOT a real experiment: no jobs-manager, no
#  Service Bus, no result upload. What it reproduces is the part that moves the
#  kubelet and runtime footprint -- an image pull and unpack of the real task
#  image, a long-running pod, log volume -- and the record says so.
#
#  Needs: docker, k3d, kubectl (installed by e2e_install_prereqs on Linux), jq.
#  Never touches the host kubeconfig or ~/.tracebloc: KUBECONFIG and
#  HOST_DATA_DIR are pointed at a scratch directory for the run.
#
#  WHICH PLATFORM A RECORD IS FOR IS DETECTED, NOT TYPED -- and WSL2 is the
#  reason the detection is not `uname -s`. On Windows the installer's k3d nodes
#  live inside the WSL2 VM, so the harness runs there, and `uname -s` inside WSL2
#  answers `Linux`. gen-node-reservation-embed.sh buckets records by exactly that
#  field, so a WSL2 run stamped from `uname` would not merely fail to produce a
#  `windows` row -- it would fold Windows' footprint into the MEASURED `linux`
#  reservation and move numbers a platform already depends on, with no error and
#  nothing red. See _measure_platform_os below.
#
#  Usage:  bash scripts/tests/measure-node-reservation.sh
#    TB_MEASURE_IDLE_S=300 TB_MEASURE_LOAD_S=300 TB_MEASURE_INTERVAL_S=15
#    TB_MEASURE_LOAD_IMAGE=docker.io/tracebloc/client-image_classification-cpu:prod
#    TB_MEASURE_OUT=<path>  TB_MEASURE_KEEP=1 (leave the cluster up)
#    TB_MEASURE_API_PORT=6560  (a second cluster on this engine holds 6550)
#    TB_MEASURE_PLATFORM=windows  (ASSERTS the detected platform; see below)
#
#  Measuring WINDOWS/WSL2 (backend#2460, the platform with no record yet). Run it
#  INSIDE the WSL2 distro of a Windows host whose Docker Desktop uses the WSL2
#  backend -- that VM is where the installer's k3d nodes live, so it is the node a
#  Windows customer gets. The host must be the measurement's only tenant: a second
#  k3d cluster on the same engine competes for CPU during the load phase, which
#  DEFLATES the cpu figure kubeReserved is derived from (the unsafe direction),
#  and its node container lands in the systemReserved cross-check as memory
#  "outside the nodes". So delete any installed cluster first.
#
#    wsl -d <distro>
#    curl -fsSL https://github.com/tracebloc/client/archive/<sha>.tar.gz | tar xz
#    cd client-<sha>
#    TB_MEASURE_PLATFORM=windows TB_MEASURE_OUT=$PWD/windows-amd64.json \\
#      bash scripts/tests/measure-node-reservation.sh
#
#  Then commit the record under scripts/spec/node-reservation/ and regenerate:
#  scripts/gen-node-reservation-embed.sh writes the `windows` row into BOTH
#  installers and adds `windows` to TB_KUBELET_RESERVATION_PLATFORMS. Until that
#  lands, Write-KubeletConfig writes no reservation on Windows and SAYS so --
#  unreserved and honest, never borrowing linux's numbers.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

# --- the platform a record is FOR (backend#2460) ------------------------------
#
# DERIVED FROM THE ENVIRONMENT, NEVER TYPED, AND THE TWO MUST AGREE.
#
# gen-node-reservation-embed.sh buckets every record by `platform.os` and emits
# one kubeReserved/systemReserved pair per bucket. So the stamp is not a label on
# the record -- it selects which installed platform's reservation this run moves.
#
# `uname -s` cannot be that stamp. On Windows the installer's k3d nodes live in
# the WSL2 VM, so this harness runs INSIDE WSL2, where `uname -s` is `Linux`. A
# WSL2 run stamped from uname would silently merge Windows' footprint into the
# measured `linux` reservation -- a wrong number on a platform that already
# depends on it, produced by a green run.
#
# So: WSL2 detects as `Windows`, and TB_MEASURE_PLATFORM is an ASSERTION rather
# than an override. Setting it lets a caller (a workflow, a runbook) say which
# platform it believes it is measuring and be refused if the host disagrees; it
# can never make the record claim a platform this host is not. A detection this
# script does not recognise refuses too -- a record for an unknown platform is
# not a finding, it is a corruption waiting for whoever adds that platform.
_measure_in_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  local osrelease=/proc/sys/kernel/osrelease
  [[ -r "$osrelease" ]] && grep -qiE 'microsoft|wsl' "$osrelease" && return 0
  return 1
}

# Echoes the canonical platform key, or exits 2 saying why it will not guess.
_measure_platform_os() {
  local detected
  case "$(uname -s)" in
    Darwin) detected=Darwin ;;
    Linux)  if _measure_in_wsl; then detected=Windows; else detected=Linux; fi ;;
    *)      echo "measure: \`uname -s\` is '$(uname -s)', which this harness has no platform key for." >&2
            echo "measure: add it to _measure_platform_os AND to the installers' reservation table before measuring it -- a record stamped with a key no installer reads is a measurement nobody can apply." >&2
            exit 2 ;;
  esac
  local asserted="${TB_MEASURE_PLATFORM:-}"
  if [[ -n "$asserted" ]]; then
    # Case-insensitive compare; the canonical form is what gets stamped.
    if [[ "$(printf '%s' "$asserted" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$detected" | tr '[:upper:]' '[:lower:]')" ]]; then
      echo "measure: TB_MEASURE_PLATFORM='$asserted' but this host detects as '$detected'." >&2
      if [[ "$detected" == Windows ]]; then
        echo "measure: this is a WSL2 shell, so the record is a WINDOWS record -- that is the point of the detection." >&2
      fi
      echo "measure: refusing rather than stamping the platform you asked for: the stamp picks which installed reservation this record moves, and a wrong one silently rewrites a platform that is already measured." >&2
      exit 2
    fi
  fi
  printf '%s' "$detected"
}

PLATFORM_OS="$(_measure_platform_os)"

# The seam the bats suite drives: resolve the platform, print it, run nothing.
# The test then exercises THE function the record is stamped from, not a copy of
# its rule (a re-implemented detector is how a guard goes on proving a regex
# nobody uses -- CLAUDE.md, "a mutation check must call the code under test").
if [[ -n "${TB_MEASURE_PRINT_PLATFORM:-}" ]]; then printf '%s\n' "$PLATFORM_OS"; exit 0; fi

# shellcheck source=/dev/null
source "$HERE/lib/e2e-common.sh"
e2e_isolate_env tbmeasure

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tb-measure-XXXXXX")"
export KUBECONFIG="$WORK/kubeconfig"
export HOST_DATA_DIR="${HOST_DATA_DIR:-$WORK/data}"
export TRACEBLOC_SKIP_LEFTOVER_GUARD=1
export TRACEBLOC_SKIP_PREFLIGHT=1

OUT="${TB_MEASURE_OUT:-$WORK/node-reservation.json}"
IDLE_S="${TB_MEASURE_IDLE_S:-300}"
LOAD_S="${TB_MEASURE_LOAD_S:-300}"
INTERVAL_S="${TB_MEASURE_INTERVAL_S:-15}"
LOAD_IMAGE="${TB_MEASURE_LOAD_IMAGE:-docker.io/tracebloc/client-image_classification-cpu:prod}"


# shellcheck source=/dev/null
source "$LIB/common.sh"
case "$(uname -s)" in
  Linux)  # shellcheck source=/dev/null
          source "$LIB/setup-linux.sh" ;;
  Darwin) # shellcheck source=/dev/null
          source "$LIB/setup-macos.sh" ;;
esac
# shellcheck source=/dev/null
source "$LIB/cluster.sh"
# shellcheck source=/dev/null
source "$LIB/preflight.sh"

# The installer pins the API port to 127.0.0.1:6550. A second cluster on the same
# engine (a real install, another harness) holds it, so the measurement can be
# given its own port WITHOUT editing the installer: the wrapper rewrites only
# that one create-time argument. Everything else k3d sees is the installer's.
if [[ -n "${TB_MEASURE_API_PORT:-}" ]]; then
  k3d() {
    local args=() a
    for a in "$@"; do args+=("${a/127.0.0.1:6550/127.0.0.1:${TB_MEASURE_API_PORT}}"); done
    command k3d "${args[@]}"
  }
fi

cleanup() {
  local rc=$?
  if [[ -z "${TB_MEASURE_KEEP:-}" ]]; then
    kubectl delete pod measure-load --ignore-not-found --wait=false >/dev/null 2>&1 || true
    # Bounded and never verdict-changing (client#979); the shared helper.
    e2e_cleanup_cluster
  fi
  return "$rc"
}
command -v jq >/dev/null 2>&1 || { echo "measure: jq is required" >&2; exit 2; }
has docker || { echo "measure: docker is required" >&2; exit 2; }
if ! has kubectl || ! has k3d; then
  # Linux runners ship neither; macOS dev boxes usually have both (Homebrew).
  [[ "$(uname -s)" == "Linux" ]] || { echo "measure: kubectl and k3d must be on PATH" >&2; exit 2; }
  e2e_install_prereqs
fi

SAMPLES="$WORK/samples.jsonl"
: > "$SAMPLES"

# Every fragment that reaches `jq --argjson` goes through this first: a read that
# came back empty, truncated, or as an error message becomes JSON `null` with a
# note, instead of aborting the whole run at the summary step. The first CI run
# did exactly that -- 37 sample rounds on three Linux runners, then "invalid JSON
# text passed to --argjson" and an empty record, because one fragment was not
# JSON. The samples are the evidence; the summary must never be able to lose them.
json_or_null() {
  local candidate="$1" what="$2"
  if [[ -n "$candidate" ]] && jq -e . >/dev/null 2>&1 <<<"$candidate"; then
    printf '%s' "$candidate"
  else
    echo "   note: ${what} was not JSON (recorded as null): ${candidate:0:120}" >&2
    printf 'null'
  fi
}

# If anything after the sampling fails, the raw samples still get written to OUT
# as a partial record, so a broken summary costs a re-run of the summary, not of
# the measurement.
RECORD_WRITTEN=0
save_partial() {
  local rc=$?
  if [[ "$RECORD_WRITTEN" -eq 0 && -s "$SAMPLES" ]]; then
    jq -n --arg platform "$PLATFORM_OS" --arg arch "$(uname -m)" --arg why "the run aborted before the summary (exit $rc); raw samples preserved" \
      --slurpfile samples "$SAMPLES" '{schema_version: 1, partial: true, why: $why, platform: {os: $platform, arch: $arch}, samples: $samples}' > "$OUT" 2>/dev/null || cp "$SAMPLES" "${OUT%.json}.samples.jsonl"
    echo "PARTIAL RECORD (samples only): $OUT" >&2
  fi
  cleanup
  return "$rc"
}
trap save_partial EXIT

echo "═══════════════════════════════════════════════════════════════════════"
echo "  node reservation measurement   record for ${PLATFORM_OS}/$(uname -m) (shell: $(uname -s))   idle ${IDLE_S}s  load ${LOAD_S}s  every ${INTERVAL_S}s"
echo "═══════════════════════════════════════════════════════════════════════"

echo "── create_cluster() — the installer's real bring-up path ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide

nodes="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"

# One sample line per node: the kubelet's own accounting plus two cross-checks.
sample() {
  local phase="$1" node stats cg dstats now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for node in $nodes; do
    stats="$(kubectl get --raw "/api/v1/nodes/${node}/proxy/stats/summary" 2>/dev/null || true)"
    stats="$(json_or_null "$stats" "stats/summary on $node")"
    # Top-level cgroups inside the node container: `<name> <memory.current>`.
    cg="$(docker exec "$node" sh -c 'for d in /sys/fs/cgroup/*/; do n=$(basename "$d"); v=$(cat "$d/memory.current" 2>/dev/null || echo -); printf "%s %s\n" "$n" "$v"; done' 2>/dev/null \
          | jq -R -s 'split("\n") | map(select(length>0) | split(" ") | {key: .[0], value: (.[1] | tonumber? // null)}) | from_entries')"
    dstats="$(docker stats --no-stream --format '{{json .}}' "$node" 2>/dev/null | jq -c '{mem_usage: .MemUsage, cpu_perc: .CPUPerc}' 2>/dev/null || true)"
    cg="$(json_or_null "$cg" "cgroups on $node")"
    dstats="$(json_or_null "$dstats" "docker stats on $node")"
    jq -cn --arg phase "$phase" --arg node "$node" --arg t "$now" \
      --argjson stats "$stats" --argjson cg "$cg" --argjson dstats "$dstats" '
      {phase: $phase, node: $node, t: $t,
       system_containers: ($stats.node.systemContainers // [] | map({name, ws: .memory.workingSetBytes, rss: .memory.rssBytes, cpu_nano: .cpu.usageNanoCores})),
       node_memory: {ws: $stats.node.memory.workingSetBytes, available: $stats.node.memory.availableBytes, rss: $stats.node.memory.rssBytes},
       node_cpu_nano: $stats.node.cpu.usageNanoCores,
       pods: ($stats.pods // [] | length),
       cgroups: ($cg // {}), docker: ($dstats // {})}' >> "$SAMPLES" || echo "   note: a sample for $node could not be written" >&2
  done
}

run_phase() {
  local phase="$1" seconds="$2" end n=0
  end=$(( SECONDS + seconds ))
  while (( SECONDS < end )); do
    sample "$phase"; n=$((n + 1))
    sleep "$INTERVAL_S"
  done
  echo "   ${phase}: ${n} sample rounds"
}

echo "── phase: idle (${IDLE_S}s) ──"
# Let the k3s addons (coredns, metrics-server, local-path) settle first.
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=180s >/dev/null 2>&1 || true
sleep 20
run_phase idle "$IDLE_S"

echo "── phase: load (${LOAD_S}s) — pull ${LOAD_IMAGE}, then burn ──"
load_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# PROCESSES, not threads: Python threads share the GIL, so a threaded spinner
# burns one core however many it starts (the first darwin record shows exactly
# that -- pods at ~1.0 core on a 6-cpu node). One process per CPU is the load a
# real training run puts on the node's scheduler.
kubectl run measure-load --image="$LOAD_IMAGE" --restart=Never --command -- \
  python3 -u -c "
import os, time, multiprocessing, sys
hold = bytearray(1024*1024*1024)   # 1 GiB held for the whole run
for i in range(len(hold))[::4096]: hold[i] = 1
def spin():
    x = 0
    while True: x = (x * 31 + 7) % 1000003
procs = [multiprocessing.Process(target=spin, daemon=True) for _ in range(max(1, os.cpu_count() or 1))]
for p in procs: p.start()
t0 = time.time()
while time.time() - t0 < ${LOAD_S}:
    print('measure-load tick', int(time.time() - t0), 'x' * 200, flush=True); time.sleep(0.5)
for p in procs: p.terminate()
" >/dev/null
pull_ok=1
# Sample THROUGH the pull: containerd's unpack is the runtime's peak.
run_phase load-pull 0 >/dev/null || true
end=$(( SECONDS + 900 ))
while (( SECONDS < end )); do
  sample load-pull
  phase_now="$(kubectl get pod measure-load -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase_now" == "Running" || "$phase_now" == "Succeeded" || "$phase_now" == "Failed" ]] && break
  reason="$(kubectl get pod measure-load -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  if [[ "$reason" == "ErrImagePull" || "$reason" == "ImagePullBackOff" ]]; then pull_ok=0; break; fi
  sleep "$INTERVAL_S"
done
pull_finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( pull_ok )); then
  kubectl get pod measure-load -o wide
  run_phase load "$LOAD_S"
else
  echo "   load: image pull FAILED for ${LOAD_IMAGE} -- load phase NOT measured (recorded as a finding)"
  kubectl describe pod measure-load | tail -5 || true
fi
kubectl delete pod measure-load --ignore-not-found --wait=false >/dev/null 2>&1 || true

echo "── node facts: capacity vs allocatable, live /configz ──"
node_facts="$(for node in $nodes; do
  cfg="$(kubectl get --raw "/api/v1/nodes/${node}/proxy/configz" 2>/dev/null || true)"
  cfg="$(json_or_null "$cfg" "configz on $node")"
  nodejson="$(kubectl get node "$node" -o json 2>/dev/null || true)"
  nodejson="$(json_or_null "$nodejson" "node object $node")"
  jq -c --arg node "$node" --argjson cfg "$cfg" <<<"$nodejson" '
    {node: $node,
     capacity: .status.capacity, allocatable: .status.allocatable,
     kubelet_version: .status.nodeInfo.kubeletVersion, runtime: .status.nodeInfo.containerRuntimeVersion,
     os_image: .status.nodeInfo.osImage, kernel: .status.nodeInfo.kernelVersion, arch: .status.nodeInfo.architecture,
     configz: ($cfg // {} | {evictionHard: .kubeletconfig.evictionHard, evictionSoft: .kubeletconfig.evictionSoft,
               evictionMinimumReclaim: .kubeletconfig.evictionMinimumReclaim,
               kubeReserved: .kubeletconfig.kubeReserved, systemReserved: .kubeletconfig.systemReserved,
               enforceNodeAllocatable: .kubeletconfig.enforceNodeAllocatable,
               kubeletCgroups: .kubeletconfig.kubeletCgroups, runtimeCgroups: .kubeletconfig.systemCgroups,
               imageGCHighThresholdPercent: .kubeletconfig.imageGCHighThresholdPercent})}'
done | jq -s .)"

# How k3s wires the kubelet on THIS version: its own drop-in directory (if any),
# and the kubelet command line. This decides whether a tracebloc reservation
# belongs in `--kubelet-arg=config=` (the #2634 mechanism) or in k3s's
# `kubelet.conf.d/` -- a config-dir drop-in merges AFTER the --config file, so
# whichever holds k3s's defaults wins over the other for the same map.
#
# The kubelet command line is captured whole and then sliced with awk -- never
# piped into grep -m1: under errexit+pipefail an early-closing reader can SIGPIPE
# its writer and fail the pipeline (the repo's early-close guard). NO COMMENTS
# INSIDE the $( ) below: bash 3.2 (macOS) does not skip comment text while it
# scans for the closing paren, so a backtick or apostrophe in one breaks the
# parse of the whole file -- measured, the hard way, on this block.
wiring="$(for node in $nodes; do
  confd="$(docker exec "$node" sh -c 'd=/var/lib/rancher/k3s/agent/etc/kubelet.conf.d; if [ -d "$d" ]; then for f in "$d"/*; do echo "=== $f"; cat "$f"; done; else echo "no kubelet.conf.d"; fi' 2>/dev/null || echo unreadable)"
  cmdlines="$(docker exec "$node" sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < "$p/cmdline" 2>/dev/null; echo; done' 2>/dev/null || echo unreadable)"
  cmdline="$(awk '/--config/ && /kubelet/ {print; exit}' <<<"$cmdlines")"
  jq -cn --arg node "$node" --arg confd "$confd" --arg cmdline "$cmdline" '{node: $node, kubelet_conf_d: $confd, k3s_cmdline: $cmdline}'
done | jq -s . 2>/dev/null || true)"
wiring="$(json_or_null "$wiring" "kubelet wiring")"
node_facts="$(json_or_null "$node_facts" "node facts")"

# The VM (macOS/WSL2) or host (Linux) beneath the nodes: what is used OUTSIDE
# every node container. MemTotal - MemAvailable is what the kernel says is in
# use; minus the node containers' cgroups that is dockerd, the k3d sidecars, the
# guest kernel and (on Linux) the host OS -- the system-reserved population.
vm_raw="$(docker run --rm --pid=host alpine:3.20 sh -c 'grep -E "^(MemTotal|MemAvailable|MemFree)" /proc/meminfo; echo ---; ps -o pid,rss,comm 2>/dev/null | sort -k2 -n -r' 2>/dev/null || true)"
# The top 15 processes by RSS, sliced from the capture rather than piped into head.
vm_raw="$(awk 'NR<=19' <<<"$vm_raw")"
vm_view="$(jq -R -s '{raw: .}' <<<"$vm_raw" 2>/dev/null || true)"
vm_view="$(json_or_null "$vm_view" "vm view")"

k3d_version_all="$(k3d version 2>/dev/null || true)"
k3d_version="${k3d_version_all%%$'\n'*}"
# docker info fields are rendered by Go templates into a JSON literal by hand,
# so a value with a quote or a newline in it (an OperatingSystem string on some
# distros) would break it -- validated like everything else.
vm_info="$(docker info --format '{"ncpu": {{.NCPU}}, "mem_total": {{.MemTotal}}, "server_version": "{{.ServerVersion}}", "operating_system": "{{.OperatingSystem}}", "kernel": "{{.KernelVersion}}"}' 2>/dev/null || true)"
vm_info="$(json_or_null "$vm_info" "docker info")"
sidecars="$(docker stats --no-stream --format '{{json .}}' "k3d-${CLUSTER_NAME}-serverlb" "k3d-${CLUSTER_NAME}-tools" 2>/dev/null | jq -s 'map({name: .Name, mem_usage: .MemUsage})' 2>/dev/null || true)"
sidecars="$(json_or_null "$sidecars" "sidecar stats")"
# EVERY container on the engine, so a second cluster sharing the VM shows up in
# the record instead of silently inflating the outside-the-nodes cross-check.
all_containers="$(docker stats --no-stream --format '{{json .}}' 2>/dev/null | jq -s 'map({name: .Name, mem_usage: .MemUsage, cpu_perc: .CPUPerc})' 2>/dev/null || true)"
all_containers="$(json_or_null "$all_containers" "all-container stats")"

# Percentiles over the raw samples, per phase / node / systemContainer.
summary="$(jq -s '
  def pct(p): sort | if length == 0 then null else .[(length - 1) * p / 100 | floor] end;
  def stats: {n: length, p50: pct(50), p95: pct(95), max: (max // null)};
  [ .[] | . as $s | (.system_containers // [])[] | {phase: $s.phase, node: $s.node, name, ws, cpu_nano} ]
  | group_by([.phase, .node, .name])
  | map({phase: .[0].phase, node: .[0].node, container: .[0].name,
         working_set_bytes: (map(.ws | select(. != null)) | stats),
         cpu_nanocores: (map(.cpu_nano | select(. != null)) | stats)})' "$SAMPLES" 2>/dev/null || true)"
cg_summary="$(jq -s '
  def pct(p): sort | if length == 0 then null else .[(length - 1) * p / 100 | floor] end;
  [ .[] | . as $s | ((.cgroups // {}) | to_entries[]) | {phase: $s.phase, node: $s.node, cgroup: .key, v: .value} ]
  | map(select(.v != null))
  | group_by([.phase, .node, .cgroup])
  | map({phase: .[0].phase, node: .[0].node, cgroup: .[0].cgroup, memory_current_bytes: {n: length, p50: (map(.v) | pct(50)), p95: (map(.v) | pct(95)), max: (map(.v) | max)}})' "$SAMPLES" 2>/dev/null || true)"
summary="$(json_or_null "$summary" "system-container summary")"
cg_summary="$(json_or_null "$cg_summary" "cgroup summary")"

jq -n \
  --arg platform "$PLATFORM_OS" --arg arch "$(uname -m)" --arg host_kernel "$(uname -r)" \
  --arg k3d "$k3d_version" --arg k3s "$K8S_VERSION" \
  --arg servers "${SERVERS:-1}" --arg agents "${AGENTS:-1}" \
  --arg load_image "$LOAD_IMAGE" --argjson pull_ok "$pull_ok" \
  --arg load_started "$load_started" --arg pull_finished "$pull_finished" \
  --arg idle_s "$IDLE_S" --arg load_s "$LOAD_S" --arg interval_s "$INTERVAL_S" \
  --argjson vm "$vm_info" --argjson nodes "$node_facts" --argjson sidecars "$sidecars" \
  --argjson vm_view "$vm_view" --argjson wiring "$wiring" --argjson all_containers "$all_containers" \
  --argjson summary "$summary" --argjson cg_summary "$cg_summary" \
  --slurpfile samples "$SAMPLES" '
  {schema_version: 1,
   measured_at: (now | todate),
   platform: {os: $platform, arch: $arch, host_kernel: $host_kernel, docker: $vm},
   cluster: {k3d: $k3d, k3s_image_tag: $k3s, servers: ($servers|tonumber), agents: ($agents|tonumber)},
   method: {idle_s: ($idle_s|tonumber), load_s: ($load_s|tonumber), interval_s: ($interval_s|tonumber),
            load: "training-shaped, not a real experiment: pull + unpack of the task image below, then a pod holding 1 GiB, one spinning process per CPU, ~2 log lines/s",
            load_image: $load_image, load_image_pulled: ($pull_ok == 1),
            load_started: $load_started, pull_finished: $pull_finished},
   nodes: $nodes,
   vm_sidecars_outside_nodes: $sidecars,
   vm_view_outside_nodes: $vm_view,
   every_container_on_the_engine: $all_containers,
   k3s_kubelet_wiring: $wiring,
   summary: {system_containers: $summary, cgroups: $cg_summary},
   samples: $samples}' > "$OUT"
RECORD_WRITTEN=1

echo ""
echo "── summary (working set bytes, per phase / node / container) ──"
jq -r '.summary.system_containers[] | "\(.phase)\t\(.node)\t\(.container)\tp50=\(.working_set_bytes.p50)\tp95=\(.working_set_bytes.p95)\tmax=\(.working_set_bytes.max)\tcpu_p95=\(.cpu_nanocores.p95)"' "$OUT" | column -t
echo ""
jq -r '.nodes[] | "\(.node)\tcapacity mem=\(.capacity.memory) cpu=\(.capacity.cpu)\tallocatable mem=\(.allocatable.memory) cpu=\(.allocatable.cpu)\tevictionHard=\(.configz.evictionHard)\tkubeReserved=\(.configz.kubeReserved)"' "$OUT"
echo ""
echo "MEASUREMENT RECORD: $OUT"
