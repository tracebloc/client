#!/usr/bin/env python3
"""Sum the STEADY-STATE control-plane resource requests from a rendered chart.

Reads `helm template` output on stdin, prints "<mem_mib> <cpu_milli> <n_containers>".
Used by control-plane-footprint.sh (backend#2870); kept a separate file so the
render-and-sum can be unit-tested against a fixed manifest without helm.

STEADY STATE ONLY -- Deployment / StatefulSet / DaemonSet. Not Job / CronJob: the
egress-reachability and storage-assertions hooks are one-shot conformance runs
that exit, so they are not resident beside a training pod. A DaemonSet is one
replica per node; on the single-node edge backend#2870 is about, that is x1.
"""
import sys
import re
import yaml


def mib(v):
    if not v:
        return 0.0
    m = re.match(r'^(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti)?$', str(v))
    if not m:
        return 0.0
    unit = {'Ki': 1 / 1024, 'Mi': 1, 'Gi': 1024, 'Ti': 1024 * 1024}[m.group(2) or 'Mi']
    return float(m.group(1)) * unit


def milli(v):
    if not v:
        return 0.0
    v = str(v)
    return float(v[:-1]) if v.endswith('m') else float(v) * 1000


def main():
    mem = cpu = 0.0
    n = 0
    for d in yaml.safe_load_all(sys.stdin):
        if not d:
            continue
        if d.get('kind') not in ('Deployment', 'StatefulSet', 'DaemonSet'):
            continue
        reps = 1 if d.get('kind') == 'DaemonSet' else (d.get('spec', {}).get('replicas', 1) or 1)
        sp = d.get('spec', {}).get('template', {}).get('spec', {}) or {}
        for c in (sp.get('containers', []) or []) + (sp.get('initContainers', []) or []):
            req = (c.get('resources', {}) or {}).get('requests') or {}
            if req.get('memory') or req.get('cpu'):
                n += 1
            mem += mib(req.get('memory')) * reps
            cpu += milli(req.get('cpu')) * reps
    print(f"{mem:.0f} {cpu:.0f} {n}")


if __name__ == '__main__':
    main()
