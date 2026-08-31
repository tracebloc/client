#!/usr/bin/env python3
"""Compute each rendered pod's Kubernetes QoS class from the chart's own output.

WHY THIS EXISTS (backend#2872). Ten places in this org claimed a workload had
"Guaranteed QoS". Every one was false, and every one survived because
`status.qosClass` is computed by the API SERVER: `helm unittest` renders
manifests, so it structurally cannot express the class, and `grep qosClass
client/tests/` returned zero hits. The guard that did exist asserted *the values
believed to imply the class* -- which is how a claim about a class stays wrong for
months while its test tier stays green.

So this DERIVES the class with the same rule the kubelet uses
(`ComputePodQOS`, pkg/apis/core/v1/helper/qos), rather than restating a believed
outcome:

  Guaranteed  every container -- INIT CONTAINERS INCLUDED -- has requests and
              limits set and EQUAL for BOTH cpu and memory
  BestEffort  no container sets any request or limit at all
  Burstable   everything else

The init-container clause is the whole point. `jobs-manager` renders an
unresourced `init-writable-data` whenever hostPath.enabled=true (every
installer-provisioned edge), and `mysql` renders an unresourced
`mysql-format-guard` UNCONDITIONALLY -- so equalising cpu, the fix every earlier
comment implied, reaches Guaranteed for jobs-manager only on a CSI cluster and
for mysql nowhere. A checker that looked only at the main containers would agree
with the wrong comments.

Pod-level resources (KEP-2837, beta 1.36) are handled: `spec.resources` with
requests == limits yields Guaranteed even with unresourced init containers.
Measured on a real 1.36 cluster before being encoded here. When the chart adopts
them, this checker follows the class change rather than needing a rewrite.

Usage:  pod-qos-class.py <rendered.yaml>
Prints one `workload<TAB>class<TAB>reason` line per pod-bearing workload.
Exits non-zero on anything it cannot determine -- an unreadable render is
"cannot tell", not "agrees".
"""
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs pyyaml
    sys.stderr.write("pod-qos-class.py needs pyyaml\n")
    sys.exit(2)

POD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod")
DIMS = ("cpu", "memory")


def _norm(v):
    """Compare resource quantities as written.

    Deliberately a STRING comparison, not a unit-aware parse. Kubernetes'
    ComputePodQOS compares parsed quantities, so "1Gi" and "1024Mi" are equal to
    it and unequal here -- this checker is therefore stricter than the kubelet,
    never looser. A chart that writes the same budget in two different units
    would be reported as Burstable when the cluster says Guaranteed; that is a
    false alarm the expected table would catch immediately, and it is the safe
    direction to be wrong in. Parsing units would add an arithmetic surface whose
    own bugs would be silent.
    """
    return None if v is None else str(v).strip()


def pod_qos(pod_spec):
    """Return (class, reason). The single implementation of the rule -- the
    assertion and the mutation check in pod-qos-class.bats both call THIS, so
    breaking it reddens rather than being re-implemented inline (CLAUDE.md #9).
    """
    # Pod-level resources (KEP-2837) short-circuit the per-container walk, which
    # is exactly why they clear the unresourced-init-container blocker.
    pod_res = pod_spec.get("resources") or {}
    if pod_res:
        req, lim = pod_res.get("requests") or {}, pod_res.get("limits") or {}
        if all(_norm(req.get(d)) is not None and _norm(req.get(d)) == _norm(lim.get(d))
               for d in DIMS):
            return "Guaranteed", "pod-level resources, requests == limits on both dimensions"
        return "Burstable", "pod-level resources set but not equal on both dimensions"

    containers = list(pod_spec.get("initContainers") or []) + \
        list(pod_spec.get("containers") or [])
    if not containers:
        raise ValueError("a pod spec with no containers -- refusing to guess a class")

    any_set = False
    offenders = []
    for c in containers:
        r = c.get("resources") or {}
        req, lim = r.get("requests") or {}, r.get("limits") or {}
        if req or lim:
            any_set = True
        for d in DIMS:
            rv, lv = _norm(req.get(d)), _norm(lim.get(d))
            if rv is None or lv is None or rv != lv:
                offenders.append(f"{c['name']}:{d}(req={rv},lim={lv})")

    if not any_set:
        return "BestEffort", "no container sets any request or limit"
    if not offenders:
        return "Guaranteed", "every container has requests == limits on both dimensions"
    return "Burstable", "; ".join(offenders)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    with open(argv[1]) as fh:
        docs = list(yaml.safe_load_all(fh))
    rows = []
    for d in docs:
        if not d or d.get("kind") not in POD_KINDS:
            continue
        name = d.get("metadata", {}).get("name", "?")
        if d["kind"] == "Pod":
            spec = d.get("spec") or {}
        elif d["kind"] == "CronJob":
            spec = d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        else:
            spec = d["spec"]["template"]["spec"]
        cls, why = pod_qos(spec)
        rows.append((name, cls, why))
    if not rows:
        # Fail closed: zero pods parsed compares equal to zero pods parsed, which
        # is how an empty render passes a naive sweep (CLAUDE.md #3).
        sys.stderr.write("no pod-bearing workloads found in the render -- "
                         "refusing to report agreement\n")
        return 1
    for name, cls, why in sorted(rows):
        print(f"{name}\t{cls}\t{why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
