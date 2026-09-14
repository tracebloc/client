#!/usr/bin/env bash
#
# gen-installer-parity.sh — derive the contract half of
# scripts/tests/fixtures/installer_parity.json from envelope_contract.json and
# flatten the whole fixture into a sourceable bash table (client#772).
#
# Two jobs, one source of truth each:
#
#   1. Rows marked `"size_from": "contract"` describe a MACHINE-SIZED verdict.
#      Their `expect.size / limits / undersized / unschedulable` are not typed;
#      they are computed here from scripts/tests/fixtures/envelope_contract.json
#      (overhead, floor, the `largest` anchor rule) and written back into the
#      JSON. When the contract moves, run this script and the table follows —
#      the v2 -> v4 adoption (backend#2460) reddened Pester on 15 rows whose
#      answers had been hand-copied consequences of a 3 GiB overhead. Rows
#      without the marker pin a CARRIED or OVERRIDDEN literal by hand: those are
#      control flow, which is what this fixture exists to compare, not arithmetic.
#
#      The arithmetic below is a re-statement of node_sizing.py, so before it is
#      allowed to write anything it must reproduce EVERY golden vector in the
#      contract (single_node and multi_node/largest). A copy that has drifted
#      from the source of truth refuses to run rather than minting a table that
#      agrees with itself.
#
#      Each derived row also declares what branch it `covers` (viable |
#      undersized | unschedulable | unreadable | exact-floor). A contract move
#      that makes a row stop exercising its branch — 2c/4Gi clearing the floor
#      once the overhead dropped below 2 GiB — is refused here, not silently
#      demoted to one more viable row. `"nodes_from": "per_node_minimum"` writes
#      the node line from the contract, so the exact-floor row moves with it.
#
#   2. bats has no guaranteed JSON parser (jq is not a prerequisite — see the
#      helm-namespace note in lib/install-client-helm.sh), so the fixture is
#      flattened for the bash side exactly the way envelope_vectors.bash already
#      is. The Pester side reads the JSON directly.
#
# One fixture, two readers. If they ever disagree, one has drifted — which is
# the whole point of the file.
#
# Usage:
#   scripts/gen-installer-parity.sh           # derive + regenerate both files
#   scripts/gen-installer-parity.sh --check   # verify, change nothing (CI)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC="scripts/tests/fixtures/installer_parity.json"
OUT="scripts/tests/fixtures/installer_parity.bash"
CONTRACT="scripts/tests/fixtures/envelope_contract.json"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

[[ -f "$SRC" ]] || { echo "[ERROR] $SRC is missing" >&2; exit 1; }
[[ -f "$CONTRACT" ]] || { echo "[ERROR] $CONTRACT is missing" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || {
  echo "[ERROR] python3 is required to regenerate the parity table" >&2
  exit 1
}

# Emits the derived JSON on stdout when $1 is "json", the bash table when it is
# "bash". Both come from ONE pass so they cannot disagree with each other.
_emit() {
  python3 - "$1" "$SRC" "$CONTRACT" <<'PY'
import json, sys

mode, src, contract_path = sys.argv[1:4]
with open(src) as fh:
    spec = json.load(fh)
with open(contract_path) as fh:
    contract = json.load(fh)

GIB = 1024 ** 3


def refuse(msg):
    raise SystemExit(f"gen-installer-parity: REFUSED -- {msg}")


# ── the contract's constants, read, never typed ────────────────────────────
OVH_C = contract["overhead"]["cpu_millicores"]
OVH_M = contract["overhead"]["memory_bytes"]
FLOOR_C = contract["floor"]["cpu_millicores"]
FLOOR_M = contract["floor"]["memory_bytes"]
PNM = contract["topology"]["per_node_minimum"]
CONTRACT_VERSION = contract["contract_version"]


def render(cores, gib):
    return f"cpu={cores},memory={gib}Gi"


# The literal both installers fall back to is the contract floor (backend#2254).
FLOOR_RENDER = render(FLOOR_C // 1000, FLOOR_M // GIB)


# ── the twins' parsers, mirrored (_cpu_to_milli / _mem_to_bytes) ────────────
def cpu_to_milli(v):
    if v.endswith("m"):
        n = v[:-1]
        return int(n) if n.isdigit() else None
    if "." in v:
        whole, _, frac = v.partition(".")
        if "." in frac or not (whole + frac).isdigit():
            return None
        frac = (frac + "000")[:3]
        return int(whole or "0") * 1000 + int(frac)
    return int(v) * 1000 if v.isdigit() else None


BINARY = {"Ki": 1024, "Mi": 1024 ** 2, "Gi": 1024 ** 3, "Ti": 1024 ** 4, "Pi": 1024 ** 5}
DECIMAL = {"k": 10 ** 3, "M": 10 ** 6, "G": 10 ** 9, "T": 10 ** 12, "P": 10 ** 15}


def mem_to_bytes(v):
    for suf, mult in BINARY.items():
        if v.endswith(suf):
            n = v[: -len(suf)]
            return int(n) * mult if n.isdigit() else None
    for suf, mult in DECIMAL.items():
        if v.endswith(suf):
            n = v[: -len(suf)]
            return int(n) * mult if n.isdigit() else None
    return int(v) if v.isdigit() else None


# ── the contract's rules: `largest` anchor, then overhead and floor ─────────
def anchor(nodes):
    """nodes: [(cpu, memory, unschedulable)] as the kubectl jsonpath lines carry
    them. Cordoned and unparseable nodes are skipped (contract.skipped_nodes);
    the anchor maximises (cpu_millicores, memory_bytes) lexicographically."""
    best = None
    for cpu, mem, unsched in nodes:
        if unsched == "true":
            continue
        c, m = cpu_to_milli(cpu), mem_to_bytes(mem)
        if c is None or m is None:
            continue
        if best is None or (c, m) > best:
            best = (c, m)
    return best


def envelope(cpu_m, mem_b):
    run_c = max(0, cpu_m - OVH_C)
    run_m = max(0, mem_b - OVH_M)
    cores, gib = run_c // 1000, run_m // GIB
    viable = run_c >= FLOOR_C and run_m >= FLOOR_M
    return run_c, run_m, cores, gib, viable


def verdict(nodes):
    """What _resolve_training_size / Get-TrainingResources must answer for a
    machine-sized row, and which branch that answer came from."""
    a = anchor(nodes)
    if a is None:
        # Nothing measured: the literal, and no claim about machine size.
        return {"size": FLOOR_RENDER, "undersized": False, "unschedulable": False}, "unreadable", None
    run_c, run_m, cores, gib, viable = envelope(*a)
    if viable:
        return {"size": render(cores, gib), "undersized": False, "unschedulable": False}, "viable", (run_c, run_m)
    if cores >= 1 and gib >= 1:
        return {"size": render(cores, gib), "undersized": True, "unschedulable": False}, "undersized", (run_c, run_m)
    return {"size": FLOOR_RENDER, "undersized": False, "unschedulable": True}, "unschedulable", (run_c, run_m)


def limits(size):
    # backend#2418 L0.2: RESOURCE_LIMITS is the size minus its cpu dimension.
    return ",".join(p for p in size.split(",") if p.split("=", 1)[0].strip().lower() != "cpu")


# ── prove the arithmetic against the contract before writing anything ───────
def prove():
    bad, seen = [], {"viable": 0, "non_viable": 0, "unparseable": 0, "cordoned": 0}
    for v in contract["vectors"]["single_node"]:
        exp = v["expected"]
        a = anchor([(v["allocatable_cpu"], v["allocatable_memory"], "")])
        if exp is None:
            seen["unparseable"] += 1
            if a is not None:
                bad.append(f"{v['label']}: contract says unparseable, this parser accepted it")
            continue
        if a is None:
            bad.append(f"{v['label']}: contract parsed it, this parser did not")
            continue
        run_c, run_m, cores, gib, viable = envelope(*a)
        got = {"cpu_millicores": cores * 1000, "memory_bytes": run_m, "viable": viable,
               "render_gi": {"cpu": str(cores), "memory": f"{gib}Gi"}}
        want = {k: exp[k] for k in got}
        if got != want:
            bad.append(f"{v['label']}: want {want} got {got}")
        seen["viable" if exp["viable"] else "non_viable"] += 1
    for v in contract["vectors"]["multi_node"]:
        nodes = [(n["cpu"], n["memory"], "true" if n.get("unschedulable") else "") for n in v["nodes"]]
        if any(u == "true" for _, _, u in nodes):
            seen["cordoned"] += 1
        largest = v["anchored"]["largest"]
        a = anchor(nodes)
        want_anchor = (largest["allocatable_cpu_millicores"], largest["allocatable_memory_bytes"])
        if a != want_anchor:
            bad.append(f"{v['label']}: anchor want {want_anchor} got {a}")
            continue
        run_c, run_m, cores, gib, viable = envelope(*a)
        exp = largest["expected"]
        got = {"cpu_millicores": cores * 1000, "memory_bytes": run_m, "viable": viable,
               "render_gi": {"cpu": str(cores), "memory": f"{gib}Gi"}}
        want = {k: exp[k] for k in got}
        if got != want:
            bad.append(f"{v['label']}: want {want} got {got}")
    if bad:
        refuse("the generator's arithmetic no longer reproduces envelope_contract.json's golden vectors:\n  "
               + "\n  ".join(bad))
    # A proof that ran over nothing is not a proof (backend#1729 rule 3).
    thin = [k for k, n in seen.items() if n == 0]
    if thin:
        refuse(f"the contract's vectors exercise none of: {', '.join(thin)} -- cannot prove the arithmetic")
    return seen


proven = prove()

# ── derive the contract half of every marked row ───────────────────────────
COVERS = ("viable", "undersized", "unschedulable", "unreadable", "exact-floor")

for row in spec["rows"]:
    label = row["label"]
    nodes_from = row.get("nodes_from")
    if nodes_from == "per_node_minimum":
        row["nodes"] = f"{PNM['cpu_millicores']}m {PNM['memory_bytes']}"
    elif nodes_from is not None:
        refuse(f"{label}: unknown nodes_from {nodes_from!r}")

    size_from = row.get("size_from")
    if size_from is None:
        if "covers" in row:
            refuse(f"{label}: `covers` is only meaningful on a size_from=contract row")
        continue
    if size_from != "contract":
        refuse(f"{label}: unknown size_from {size_from!r}")
    if row.get("override"):
        refuse(f"{label}: an install-time override is a human choice, not a contract-derived size")

    covers = row.get("covers")
    if covers not in COVERS:
        refuse(f"{label}: a size_from=contract row must declare covers in {COVERS}")

    nodes = []
    for line in row["nodes"].split(";"):
        parts = line.split()
        nodes.append(tuple((parts + ["", "", ""])[:3]))
    derived, branch, remainder = verdict(nodes)

    if covers == "exact-floor":
        if branch != "viable" or remainder != (FLOOR_C, FLOOR_M):
            refuse(f"{label}: declared covers=exact-floor but the remainder is {remainder}, "
                   f"not the floor ({FLOOR_C}, {FLOOR_M})")
    elif branch != covers:
        refuse(f"{label}: declared covers={covers} but the contract derives {branch} for nodes "
               f"{row['nodes']!r} -- pick a machine shape that still exercises that branch")

    e = row["expect"]
    e["size"] = derived["size"]
    e["undersized"] = derived["undersized"]
    e["unschedulable"] = derived["unschedulable"]
    e["limits"] = limits(derived["size"])

if mode == "json":
    sys.stdout.write(json.dumps(spec, indent=2, ensure_ascii=False) + "\n")
    sys.exit(0)

# ── the bash table ─────────────────────────────────────────────────────────
print("# GENERATED by scripts/gen-installer-parity.sh — do not hand-edit.")
print("# Source of truth: scripts/tests/fixtures/installer_parity.json (client#772)")
print("#")
print("# One row per cluster state. Fields, pipe-separated:")
print("#   label|nodes|carried|carried_provenance|override|size|provenance|undersized|unschedulable|limits")
print("#")
print("# `nodes` is semicolon-separated node lines, as kubectl's jsonpath emits them:")
print("# '<cpu> <memory>' plus an optional third field, '<spec.unschedulable>'.")
print("# Unschedulable is omitempty, so a schedulable node emits nothing there and")
print("# both readers see a two-field line -- which is why the pre-backend#2237 rows")
print("# below still carry two fields. Only a CORDONED node emits the literal 'true'.")
print("# `carried` is 'none', 'read-fails', 'read-empty',")
print("# or the RESOURCE_LIMITS value a previous release carries.")
print("# `limits` is what RESOURCE_LIMITS gets: `size` minus its cpu dimension")
print("# (backend#2418 L0.2). NOT the same string as `size` any more.")
print("#")
print("# Machine-sized rows (size_from=contract in the JSON) carry verdicts DERIVED")
print(f"# from envelope_contract.json (contract_version {CONTRACT_VERSION}: overhead")
print(f"# {OVH_C}m / {OVH_M // (1024 * 1024)} MiB, floor {FLOOR_C}m / {FLOOR_M // (1024 * 1024)} MiB),")
print(f"# after reproducing {proven['viable'] + proven['non_viable'] + proven['unparseable']} single-node and")
print(f"# {len(contract['vectors']['multi_node'])} multi-node golden vectors. Carried and overridden rows are hand-pinned.")
print(f"# schema_version {spec['schema_version']}")
print()
print("TB_PARITY_ROWS=(")
for row in spec["rows"]:
    e = row["expect"]
    fields = [
        row["label"],
        row["nodes"],
        row["carried"],
        row.get("carried_provenance", ""),
        row.get("override", ""),
        e["size"],
        e["provenance"],
        "1" if e["undersized"] else "0",
        "1" if e["unschedulable"] else "0",
        # schema_version 2 (backend#2418): the LIMITS half, which is no longer
        # the same string as `size`. A second shared contract between the twins,
        # and one a real divergence was already found in -- see verdict_fields.
        e["limits"],
    ]
    for f in fields:
        if "|" in f:
            raise SystemExit(f"field contains the delimiter: {f!r}")
    print('  "' + "|".join(fields) + '"')
print(")")

# backend#2460: the kubelet drop-in's reservation BEHAVIOUR both writers must
# show (the values are generated into the twins and held equal by the agreement
# guard; this is the shape, driven through each real writer).
kr = spec.get("kubelet_reservation")
if not kr:
    raise SystemExit("installer_parity.json has no kubelet_reservation section")


def arr(name, items):
    for it in items:
        if '"' in it:
            raise SystemExit(f"{name}: item contains a double quote: {it!r}")
    print(f"{name}=(")
    for it in items:
        print(f'  "{it}"')
    print(")")


print()
print("# kubelet drop-in reservation shape (backend#2460); see the JSON's kubelet_reservation.purpose")
print(f'TB_PARITY_RESERVATION_PLATFORMS_VAR="{kr["measured_platforms_variable"]}"')
print(f'TB_PARITY_RESERVATION_UNMEASURED_PROBE="{kr["unmeasured_probe_platform"]}"')
arr("TB_PARITY_RESERVATION_EMITTED_MEASURED", kr["emitted_for_a_measured_platform"])
arr("TB_PARITY_RESERVATION_NEVER_UNMEASURED", kr["never_emitted_for_an_unmeasured_platform"])
arr("TB_PARITY_RESERVATION_NEVER_RESTATED", kr["never_restated_from_k3s"])
arr("TB_PARITY_RESERVATION_ALWAYS", kr["always_emitted"])
PY
}

if (( CHECK )); then
  rc=0
  if ! diff -u "$SRC" <(_emit json) >/dev/null 2>&1; then
    echo "PARITY FIXTURE DRIFT: the contract-derived verdicts in $SRC do not follow $CONTRACT" >&2
    diff -u "$SRC" <(_emit json) | head -40 >&2 || true
    echo "" >&2
    rc=1
  fi
  if ! diff -u "$OUT" <(_emit bash) >/dev/null 2>&1; then
    echo "PARITY TABLE DRIFT: $OUT does not match $SRC" >&2
    diff -u "$OUT" <(_emit bash) | head -30 >&2 || true
    echo "" >&2
    rc=1
  fi
  if (( rc )); then
    echo "Run scripts/gen-installer-parity.sh to regenerate them." >&2
    exit 1
  fi
  echo "parity fixture follows $CONTRACT and the table matches $SRC"
else
  # Derive into the JSON first; the table is flattened from the derived JSON so
  # a single run leaves both current.
  _emit json > "$SRC.tmp" && mv "$SRC.tmp" "$SRC"
  _emit bash > "$OUT"
  echo "regenerated $SRC (contract-derived rows) and $OUT ($(grep -c '^  "' "$OUT") rows)"
fi
