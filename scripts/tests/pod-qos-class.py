#!/usr/bin/env python3
"""Compute each rendered pod's Kubernetes QoS class from the chart's own output.

WHY THIS EXISTS (backend#2872). Six places in this org claimed a workload had
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

Pod-level resources (KEP-2837, beta 1.34) are handled: `spec.resources` with
requests == limits yields Guaranteed even with unresourced init containers.
Measured on a real 1.36 cluster before being encoded here. When the chart adopts
them, this checker follows the class change rather than needing a rewrite.

Usage:  pod-qos-class.py <rendered.yaml>
Prints one `workload<TAB>class<TAB>reason` line per pod-bearing workload.
Exits non-zero on anything it cannot determine -- an unreadable render is
"cannot tell", not "agrees".
"""
import re
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

    ONE EXCEPTION, and it is the looser direction: requests == limits == {cpu:
    "0", memory: "0"} derives Guaranteed here and is BestEffort on a cluster,
    because the kubelet treats a zero quantity as unset. Stated rather than
    handled -- no chart workload sets zero, and inventing a numeric special case
    would reintroduce the parse surface this function exists to avoid. If one
    ever does, the expected table is what catches it.
    """
    return None if v is None else str(v).strip()


def pod_qos(pod_spec):
    """Return (class, reason). The single implementation of the rule -- the
    assertion and the mutation check in pod-qos-class.bats both call THIS, so
    breaking it reddens. A mutation check that re-implements the rule inline
    proves only that its own copy works.
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
        # ONLY cpu and memory count toward the class. ComputePodQOS skips
        # anything `isSupportedQoSComputeResource` rejects, so a container whose
        # only requests are `nvidia.com/gpu` and `ephemeral-storage` -- which is
        # exactly what client-runtime's GPU path produces (backend#2871) -- has
        # EMPTY qos-relevant maps and the pod is BestEffort, not Burstable. The
        # first version of this checker counted any key and would have reported
        # those pods as Burstable: the same defect shape it exists to catch.
        if any(d in req or d in lim for d in DIMS):
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


def unresourced_inits(docs):
    """{workload: [init container names with no resources]} across the render.

    Split out so the expectation can assert the SET, not just that two known names
    appear. `init-mysql-data` could previously vanish with no test reddening
    (Bugbot, review on client#922) because the check only looked for names it
    already expected to find -- a membership test where a set comparison was needed.
    """
    out = {}
    for d in docs:
        if not d or d.get("kind") not in POD_KINDS:
            continue
        spec = _pod_spec(d)
        bare = [c["name"] for c in (spec.get("initContainers") or []) if not (c.get("resources") or {})]
        if bare:
            out[d["metadata"]["name"]] = sorted(bare)
    return out


def check_expectations(rows, inits, path):
    """Compare the render against a declared expectation file. Returns problems.

    THE POINT IS SET EQUALITY, NOT LOOKUP. The first version of this suite restated
    six workload names in a bats file; the chart renders TEN, so `auto-upgrade`,
    `image-refresh` and the two check Jobs were classified and then ignored -- a
    silent Burstable/Guaranteed change on any of them stayed green, which is the
    defect shape this guard exists to close -- derive, never restate.

    Format, one per line, `#` comments allowed:
        class   <workload>  <Guaranteed|Burstable|BestEffort>
        init    <workload>  <comma-separated unresourced init containers>
    """
    want_class, want_init = {}, {}
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 3 or parts[0] not in ("class", "init"):
                return [f"{path}:{lineno}: not `class|init <workload> <value>`: {line!r}"]
            kind, name, value = parts
            (want_class if kind == "class" else want_init)[name] = value

    problems = []
    got_class = {name: cls for name, cls, _ in rows}
    # BOTH directions. A missing row means a new workload nobody classified; an extra
    # row means a stale expectation still being "satisfied" by nothing.
    for name in sorted(set(got_class) - set(want_class)):
        problems.append(
            f"{name}: rendered and classified {got_class[name]}, but no `class` row "
            f"declares it. Add one — an unlisted workload is not covered by this guard."
        )
    for name in sorted(set(want_class) - set(got_class)):
        problems.append(f"{name}: declared in {path} but the chart renders no such workload")
    for name in sorted(set(got_class) & set(want_class)):
        if got_class[name] != want_class[name]:
            problems.append(
                f"{name}: QoS class is {got_class[name]}, expected {want_class[name]}"
            )

    got_init = {k: ",".join(v) for k, v in inits.items()}
    for name in sorted(set(got_init) | set(want_init)):
        g, w = got_init.get(name, ""), want_init.get(name, "")
        if g != w:
            problems.append(
                f"{name}: unresourced init containers are {g or '(none)'}, "
                f"expected {w or '(none)'} — this set decides whether Guaranteed is "
                f"reachable at all, so a change here is a behaviour change"
            )
    return problems


def _pod_spec(d):
    """The pod spec for any POD_KINDS document. One implementation, so the classifier
    and the init-container sweep can never disagree about where the spec lives."""
    if d["kind"] == "Pod":
        return d.get("spec") or {}
    if d["kind"] == "CronJob":
        return d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return d["spec"]["template"]["spec"]



def pod_bearing_sources(text):
    """Basenames of the templates that emitted a pod-bearing kind in this render.

    Reads the raw text, not the parsed docs: helm's `# Source:` line is a COMMENT
    and `yaml.safe_load_all` throws it away. Needed because the question "was this
    template ever classified?" cannot be answered from workload names -- a name
    does not say which file produced it, and a template that renders nothing
    contributes no name to notice the absence of.
    """
    out, src = set(), None
    for line in text.splitlines():
        m = re.match(r"^# Source: (.+)$", line)
        if m:
            src = m.group(1).split("/")[-1]
            continue
        m = re.match(r"^kind:\s*(\w+)\s*$", line)
        if m and m.group(1) in POD_KINDS and src:
            out.add(src)
    return out


def main(argv):
    if len(argv) == 3 and argv[2] == "--sources":
        # One basename per line, for the cross-mode coverage assertion in
        # pod-qos-class.bats. Fails closed on a render with no pod at all.
        with open(argv[1]) as fh:
            found = pod_bearing_sources(fh.read())
        if not found:
            sys.stderr.write("no pod-bearing template in this render -- "
                             "refusing to report coverage\n")
            return 1
        for s in sorted(found):
            print(s)
        return 0
    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != "--expect"):
        sys.stderr.write(__doc__)
        return 2
    with open(argv[1]) as fh:
        docs = list(yaml.safe_load_all(fh))
    rows = []
    for d in docs:
        if not d or d.get("kind") not in POD_KINDS:
            continue
        name = d.get("metadata", {}).get("name", "?")
        spec = _pod_spec(d)
        cls, why = pod_qos(spec)
        rows.append((name, cls, why))
    if not rows:
        # Fail closed: zero pods parsed compares equal to zero pods parsed, which
        # is how an empty render passes a naive sweep: zero parsed rows compares
        # equal to zero parsed rows, so "cannot tell" has to be a finding.
        sys.stderr.write("no pod-bearing workloads found in the render -- "
                         "refusing to report agreement\n")
        return 1
    for name, cls, why in sorted(rows):
        print(f"{name}\t{cls}\t{why}")

    if len(argv) == 4:
        problems = check_expectations(rows, unresourced_inits(docs), argv[3])
        if problems:
            sys.stderr.write("\n".join(f"  ✗ {p}" for p in problems) + "\n")
            sys.stderr.write(f"{len(problems)} expectation problem(s).\n")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
