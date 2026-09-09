#!/usr/bin/env bash
#
# gen-node-reservation-embed.sh — derive the kubelet node reservation each
# installer writes from the MEASUREMENT RECORDS, and embed it into both twins
# (backend#2460, RFC-BACKEND-664 §P3).
#
# THE CHAIN, and why every link is a file in this repo:
#
#   scripts/tests/measure-node-reservation.sh        brings a cluster up through
#     the installer's own create_cluster(), samples the kubelet's /stats/summary
#     idle and under a training-shaped load, writes ONE JSON record
#   scripts/spec/node-reservation/<os>-<arch>[-<host>].json   the records: raw
#     samples plus their p50/p95/max, the node's capacity/allocatable and live
#     /configz, the VM or host view outside the node containers
#   THIS SCRIPT                                       reads every record, applies
#     the policy below, writes the block between the GENERATED markers in
#     scripts/lib/cluster.sh and scripts/install-k8s.ps1
#   scripts/tests/kubelet-config-agreement.sh         the two blocks agree
#   scripts/tests/e2e-cluster.sh                      on a real cluster, capacity -
#     allocatable equals what the drop-in declares
#
# THE POLICY (the only judgement in the chain; everything else is arithmetic)
#
#   kubeReserved.memory   = ceil32Mi( 1.25 x max over every sample of the
#                           platform's records of (node working set - `pods`
#                           working set) )
#       What is reserved is everything on the node that is NOT a pod: k3s server
#       (kubelet, apiserver, scheduler, controller-manager, sqlite), containerd
#       and its shims. Measured on k3s v1.36.3 the kubelet's own `kubelet` and
#       `runtime` system containers both map to the /k3s cgroup and report ~120
#       MiB, while the node minus its pods is ~540 MiB idle and more under an
#       image pull -- the k3s server process sits outside /k3s. So the honest
#       figure is node minus pods, never the kubelet's self-report. Working set
#       (not memory.current) because page cache from an image unpack is
#       reclaimable and the kubelet's eviction signal is working set too.
#       MAX not p95: this is a cap the kubepods cgroup is set to, and an
#       under-reservation is a node OOM of the kind client#642 records.
#       1.25 headroom for what a 300 s window did not see; 32 MiB rounding so a
#       re-measurement that moves by a few MiB does not churn both installers.
#   kubeReserved.cpu      = ceil50m( 1.5 x p95 over the steady LOAD phase of
#                           (node usageNanoCores - `pods` usageNanoCores) )
#       A scheduling weight, not a cap, and CPU is compressible: what is
#       reserved is the daemons' SUSTAINED share while a training pod runs,
#       p95 with headroom. The image unpack burst (containerd decompressing a
#       2-8 GB image, most of a core for about a minute) is reported beside it
#       and deliberately NOT reserved: a transient a pod can yield to for a
#       minute is not capacity the node lacks, and reserving it would take a
#       whole core off every envelope for a burst that happens once per image.
#   systemReserved.memory = the envelope contract's vm_reserve.memory_bytes
#                           (scripts/tests/fixtures/envelope_contract.json,
#                           vendored from client-runtime, backend#2221)
#       What lives in the VM (macOS/WSL2) or on the host (Linux) OUTSIDE every
#       node container -- dockerd, the k3d serverlb and tools sidecars, the guest
#       kernel, on Linux the host OS. A k3d node's capacity is the WHOLE VM or
#       host (no --servers-memory cap is applied at create), so that memory is
#       counted in capacity and no pod can ever have it. The contract already
#       names this number, measured under backend#2221, so it is READ from the
#       vendored contract rather than measured a second time here -- the record's
#       own snapshot of the VM outside the nodes (MemTotal - MemAvailable - the
#       nodes' RSS) is printed beside it as a cross-check and WARNED about when it
#       exceeds the reserve, never silently accepted. On Docker Desktop that
#       snapshot is a floor, not a measurement: `--pid=host` does not see the
#       daemon, and another cluster on the same engine lands in it too.
#       If a node-memory cap is ever applied at create time, this must drop to
#       what the CAPPED node still shares the VM with, or it double-counts.
#   evictionHard.memory.available = 5% of PF_MIN_MEM_GB GiB, the smallest
#                           machine the preflight admits (scripts/lib/preflight.sh)
#       Policy, not footprint, so it is DERIVED from the floor declaration rather
#       than typed: the same fraction k3s applies to its disk thresholds. k3s
#       ships no memory threshold at all; the kubelet default is 100Mi.
#
#   Per platform (`darwin`, `linux`; `windows` when a WSL2 record exists), MAX
#   across that platform's records -- an arm64 and an amd64 record of one OS
#   yield one conservative value. A platform with NO record is NOT in the
#   platforms list and gets no reservation: extrapolating one is the guess this
#   ticket exists to retire.
#
# REFUSES (exit 1, nothing written) on: no records; a record that is not the
# harness's schema; a record whose load phase never ran (the image pull failed --
# an idle-only number is not the measurement the ticket asks for); a record whose
# stock /configz lacks either k3s disk eviction key (then the drop-in merge this
# design relies on cannot be confirmed for that k3s); a PF_MIN_MEM_GB that will
# not parse. "Cannot tell" is a finding.
#
# Usage:
#   scripts/gen-node-reservation-embed.sh            # re-embed from the records
#   scripts/gen-node-reservation-embed.sh --check    # verify, change nothing (CI)
#
# After a re-embed, regenerate scripts/manifest.sha256 (scripts/gen-manifest.sh):
# cluster.sh is bootstrap-fetched and its digest is pinned there.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RECORDS_DIR="scripts/spec/node-reservation"
BASH_FILE="scripts/lib/cluster.sh"
PS1_FILE="scripts/install-k8s.ps1"
PREFLIGHT="scripts/lib/preflight.sh"
CONTRACT="scripts/tests/fixtures/envelope_contract.json"

CHECK=0
case "${1:-}" in
  '') ;;
  --check) CHECK=1 ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

for f in "$BASH_FILE" "$PS1_FILE" "$PREFLIGHT" "$CONTRACT"; do
  [[ -f "$f" ]] || { echo "[ERROR] $f is missing" >&2; exit 1; }
done
[[ -d "$RECORDS_DIR" ]] || { echo "[ERROR] $RECORDS_DIR is missing -- nothing to derive from" >&2; exit 1; }
# python3 is a build/CI-time dependency only -- never needed on a customer machine,
# which is the whole reason the values are embedded rather than computed live.
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 is required" >&2; exit 1; }

CHECK="$CHECK" python3 - "$RECORDS_DIR" "$BASH_FILE" "$PS1_FILE" "$PREFLIGHT" "$CONTRACT" <<'PY'
import glob, json, math, os, re, sys

records_dir, bash_file, ps1_file, preflight, contract_path = sys.argv[1:6]
check = os.environ.get("CHECK") == "1"
MIB = 1024 * 1024


def die(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def ceil_to(value, step):
    return int(math.ceil(value / step) * step)


def pct(values, p):
    values = sorted(values)
    if not values:
        return None
    return values[(len(values) - 1) * p // 100]


# ── the eviction threshold, derived from the preflight floor ────────────────
with open(preflight, encoding="utf-8") as fh:
    src = fh.read()
m = re.search(r'^PF_MIN_MEM_GB="\$\{PF_MIN_MEM_GB:-(\d+)\}"', src, re.M)
if not m:
    die(f"could not read PF_MIN_MEM_GB from {preflight}")
pf_min_gb = int(m.group(1))
eviction_mib = pf_min_gb * 1024 * 5 // 100

# ── systemReserved, from the vendored envelope contract ─────────────────────
with open(contract_path, encoding="utf-8") as fh:
    contract = json.load(fh)
vm_reserve = (contract.get("vm_reserve") or {}).get("memory_bytes")
if not isinstance(vm_reserve, int) or vm_reserve <= 0 or vm_reserve % MIB:
    die(f"{contract_path}: vm_reserve.memory_bytes is {vm_reserve!r}, not a positive whole number of MiB")
sys_mem = vm_reserve // MIB

# ── the records ─────────────────────────────────────────────────────────────
paths = sorted(glob.glob(os.path.join(records_dir, "*.json")))
if not paths:
    die(f"no records in {records_dir}")

per_platform = {}   # os -> list of (path, non_pod_ws_max, cpu_p95_load, system_outside)
provenance = []
for path in paths:
    with open(path, encoding="utf-8") as fh:
        rec = json.load(fh)
    if rec.get("schema_version") != 1:
        die(f"{path}: not a schema_version 1 record")
    platform = rec["platform"]["os"].lower()
    method = rec["method"]
    if not method.get("load_image_pulled"):
        die(f"{path}: the load phase never ran (image pull failed) -- an idle-only record is not the measurement")
    samples = rec.get("samples") or []
    if not samples:
        die(f"{path}: no samples")
    phases = {s["phase"] for s in samples}
    if "idle" not in phases or "load" not in phases:
        die(f"{path}: needs both an idle and a load phase, has {sorted(phases)}")
    for node in rec["nodes"]:
        eh = (node.get("configz") or {}).get("evictionHard") or {}
        for key in ("imagefs.available", "nodefs.available"):
            if key not in eh:
                die(f"{path}: node {node['node']} /configz evictionHard lacks {key}; the drop-in merge cannot be confirmed for this k3s")

    non_pod_ws = []
    cpu_load = []
    cpu_pull = []
    for s in samples:
        pods = next((c for c in s["system_containers"] if c["name"] == "pods"), None)
        nws = s["node_memory"].get("ws")
        if pods is None or nws is None or pods.get("ws") is None:
            continue
        non_pod_ws.append(nws - pods["ws"])
        if s.get("node_cpu_nano") is not None and pods.get("cpu_nano") is not None:
            non_pod_cpu = max(0, s["node_cpu_nano"] - pods["cpu_nano"])
            if s["phase"] == "load":
                cpu_load.append(non_pod_cpu)
            elif s["phase"] == "load-pull":
                cpu_pull.append(non_pod_cpu)
    if not non_pod_ws:
        die(f"{path}: no sample carried both a node working set and a pods working set")
    if not cpu_load:
        die(f"{path}: no steady load-phase sample carried cpu usage")

    # The VM/host outside every node, as a CROSS-CHECK of the contract's
    # vm_reserve: (MemTotal - MemAvailable) - sum of the nodes' RSS at their last
    # sample. RSS, not working set: MemAvailable already counts file cache as
    # available, so subtracting a working set that contains it would go negative.
    raw = (rec.get("vm_view_outside_nodes") or {}).get("raw", "")
    mem = {}
    for line in raw.splitlines():
        mm = re.match(r"^(MemTotal|MemAvailable):\s+(\d+) kB", line)
        if mm:
            mem[mm.group(1)] = int(mm.group(2)) * 1024
    if "MemTotal" not in mem or "MemAvailable" not in mem:
        die(f"{path}: vm_view_outside_nodes has no MemTotal/MemAvailable -- the systemReserved cross-check cannot run")
    last_rss_by_node = {}
    for s in samples:
        if s["node_memory"].get("rss") is not None:
            last_rss_by_node[s["node"]] = s["node_memory"]["rss"]
    outside = max(0, mem["MemTotal"] - mem["MemAvailable"] - sum(last_rss_by_node.values()))
    if outside > vm_reserve:
        print(f"WARNING: {path}: the VM/host outside the nodes used {outside / MIB:.0f} MiB at the end of the run, "
              f"MORE than the {vm_reserve // MIB} MiB the contract reserves for it -- re-measure on a quiet engine, "
              f"and if it holds, vm_reserve is the number to revisit upstream", file=sys.stderr)

    non_pod_rss = [s["node_memory"]["rss"] - next(c["rss"] for c in s["system_containers"] if c["name"] == "pods")
                   for s in samples
                   if s["node_memory"].get("rss") is not None
                   and any(c["name"] == "pods" and c.get("rss") is not None for c in s["system_containers"])]

    per_platform.setdefault(platform, []).append(
        (os.path.basename(path), max(non_pod_ws), pct(cpu_load, 95), outside,
         max(non_pod_rss) if non_pod_rss else None, max(cpu_pull) if cpu_pull else None)
    )

lines_bash, lines_ps1 = [], []
platforms = sorted(per_platform)


def emit(name, value, comment=None):
    lines_bash.append(f"{name}={value}")
    lines_ps1.append(f"${name} = {value}")


lines_bash.append(f'TB_KUBELET_RESERVATION_PLATFORMS="{" ".join(platforms)}"')
lines_ps1.append(f'$TB_KUBELET_RESERVATION_PLATFORMS = "{" ".join(platforms)}"')
for platform in platforms:
    rows = per_platform[platform]
    kube_mem = ceil_to(max(r[1] for r in rows) * 1.25 / MIB, 32)
    kube_cpu = ceil_to(max(r[2] for r in rows) * 1.5 / 1e6, 50)   # nanocores -> millicores
    key = platform.upper()
    for name in sorted(r[0] for r in rows):
        lines_bash.append(f"# {platform}: derived from {name}")
        lines_ps1.append(f"# {platform}: derived from {name}")
    emit(f"TB_KUBELET_KUBE_RESERVED_CPU_MILLI_{key}", kube_cpu)
    emit(f"TB_KUBELET_KUBE_RESERVED_MEM_MIB_{key}", kube_mem)
    emit(f"TB_KUBELET_SYSTEM_RESERVED_MEM_MIB_{key}", sys_mem)
    provenance.append((platform, rows, kube_cpu, kube_mem, sys_mem))
lines_bash.append(f"# systemReserved memory: the contract's vm_reserve ({contract_path}); evictionHard memory.available: 5% of PF_MIN_MEM_GB={pf_min_gb} GiB ({preflight})")
lines_ps1.append(f"# systemReserved memory: the contract's vm_reserve (scripts/tests/fixtures/envelope_contract.json); evictionHard memory.available: 5% of PF_MIN_MEM_GB={pf_min_gb} GiB (scripts/lib/preflight.sh)")
emit("TB_KUBELET_EVICTION_MEM_MIB", eviction_mib)

BASH_BEGIN = "# ── kubelet node reservation (GENERATED by scripts/gen-node-reservation-embed.sh — do not hand-edit) ──"
BASH_END = "# ── end generated reservation"
PS1_BEGIN = "# ── kubelet node reservation (GENERATED by scripts/gen-node-reservation-embed.sh — do not hand-edit) ──"
PS1_END = "# ── end generated reservation"


def splice(path, begin, end, body):
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    b = src.find(begin)
    e = src.find(end, b + 1 if b >= 0 else 0)
    if b < 0 or e < 0:
        die(f"{path}: the GENERATED reservation markers are missing")
    b_line_end = src.index("\n", b) + 1
    current = src[b_line_end:e]
    want = "".join(l + "\n" for l in body)
    if current == want:
        return False
    if check:
        print(f"EMBED DRIFT: {path} reservation block does not match the records", file=sys.stderr)
        for l in current.splitlines():
            print(f"  have: {l}", file=sys.stderr)
        for l in want.splitlines():
            print(f"  want: {l}", file=sys.stderr)
        return True
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src[:b_line_end] + want + src[e:])
    return True


changed_bash = splice(bash_file, BASH_BEGIN, BASH_END, lines_bash)
changed_ps1 = splice(ps1_file, PS1_BEGIN, PS1_END, lines_ps1)

for platform, rows, kube_cpu, kube_mem, sys_mem in provenance:
    for name, npw, cpu95, outside, nprss, pull in rows:
        rss = f"{nprss / MIB:.0f}" if nprss is not None else "?"
        pull_s = f"{pull / 1e6:.0f}" if pull is not None else "?"
        print(f"  {platform:<8} {name}: node-minus-pods working set max {npw / MIB:.0f} MiB (rss max {rss} MiB), "
              f"cpu p95 while the pod ran {cpu95 / 1e6:.0f} m (image-unpack burst max {pull_s} m, not reserved), "
              f"VM/host outside the nodes {outside / MIB:.0f} MiB")
    print(f"  {platform:<8} -> kubeReserved cpu={kube_cpu}m memory={kube_mem}Mi, systemReserved memory={sys_mem}Mi")
print(f"  evictionHard memory.available={eviction_mib}Mi (5% of PF_MIN_MEM_GB={pf_min_gb} GiB); systemReserved from vm_reserve={vm_reserve // MIB}Mi")
if check:
    if changed_bash or changed_ps1:
        print("\nRun scripts/gen-node-reservation-embed.sh to re-embed, then scripts/gen-manifest.sh.", file=sys.stderr)
        sys.exit(1)
    print(f"node reservation embed matches {len(paths)} record(s) in {records_dir}")
else:
    what = "rewritten" if (changed_bash or changed_ps1) else "already current"
    print(f"node reservation embed {what} from {len(paths)} record(s) in {records_dir}")
PY
