#!/usr/bin/env bats
# The rendered control-plane images and the image-refresh env flags are TWO
# consumers of ONE decision (tracebloc.pinFor: a digest pin is honoured only on
# the registry it was resolved against). This file does not restate the rule. It
# renders the chart and compares the two sides mechanically -- for each image,
# "the workload renders repo@digest" must equal "the CronJob says <IMAGE>_PINNED=1"
# and the PIN value must be the digest that was rendered -- across every
# registry/pin combination the rule distinguishes.
#
# WHY. When the two sides disagree the failure is silent and durable: the render
# floats an image the script skips as "pinned" (no reconcile, forever), or the
# render pins an image the script keeps trying to re-image. A flag computed from
# `.digest` alone -- the pre-fix shape -- reddens here on the first legacy-pin case.
#
# The comparator is proven live by a self-mutation below: a rendered file whose
# env is edited to disagree must fail it. An inert comparator and full agreement
# look identical in a log otherwise.

setup() {
  CHART="${BATS_TEST_DIRNAME}/../../client"
  TMP="$(mktemp -d)"
  A=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  B=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  C=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  D=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
}
teardown() { rm -rf "$TMP"; }

render() {
  helm template t "$CHART" --set clientId=x --set clientPassword=y \
    --set storageClass.create=false "$@" > "$TMP/r.yaml"
}

# agree [FILE] -- read both sides off ONE rendered manifest and compare.
# Exit 0 = every image agrees; 1 = a disagreement (printed); 2 = could not read
# a side (fail closed: an unreadable side is a finding, not agreement).
agree() {
  python3 - "${1:-$TMP/r.yaml}" <<'PYX'
import sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
def find(kind, name):
    for d in docs:
        if d.get("kind") == kind and d.get("metadata", {}).get("name") == name:
            return d
    return None
def container(doc, cname):
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c["name"] == cname:
            return c
    sys.exit(f"[ERROR] container {cname} not found in {doc['kind']}/{doc['metadata']['name']}")

jm = find("Deployment", "t-jobs-manager") or sys.exit("[ERROR] no jobs-manager Deployment rendered")
rp = find("Deployment", "t-requests-proxy") or sys.exit("[ERROR] no requests-proxy Deployment rendered")
rm = find("DaemonSet", "t-resource-monitor")  # may be disabled by values
cj = find("CronJob", "t-image-refresh")       # retired when every image is pinned

def rendered(image):
    return ("@sha256:" in image), (image.split("@", 1)[1] if "@" in image else "")

sides = {}  # image -> (render_pinned, render_digest)
sides["JOBS_MANAGER"] = rendered(container(jm, "api")["image"])
sides["PODS_MONITOR"] = rendered(container(jm, "pods-monitor-container")["image"])
if rm is not None:
    sides["RESOURCE_MONITOR"] = rendered(container(rm, "tracebloc-resource-monitor")["image"])
rp_pinned, rp_digest = rendered(container(rp, "proxy")["image"])

bad = []
if cj is None:
    # Retired CronJob: legitimate ONLY if every refreshed image is pinned in the
    # render -- otherwise a floating workload has no reconcile (the #569 trap).
    for k, (p, _) in sides.items():
        if not p:
            bad.append(f"CronJob retired but {k} renders a floating tag")
    print("CronJob: retired; all rendered images pinned" if not bad else "")
else:
    env = {e["name"]: e.get("value") for e in cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["env"]}
    for k, (p, dgst) in sides.items():
        flag = env.get(f"{k}_PINNED")
        pin = env.get(f"{k}_PIN")
        if flag not in ("0", "1"):
            sys.exit(f"[ERROR] {k}_PINNED unreadable: {flag!r}")
        if (flag == "1") != p:
            bad.append(f"{k}: render pinned={p} but {k}_PINNED={flag}")
        if pin != dgst:
            bad.append(f"{k}: render digest={dgst!r} but {k}_PIN={pin!r}")
        print(f"{k}: render pinned={p} digest={dgst[:19]!r} | env PINNED={flag} PIN={(pin or '')[:19]!r}")
    # requests-proxy: its env flag is the OWN-pin override; the Deployment renders
    # a digest iff that override is honoured OR the jobs-manager pin is honoured.
    rpf = env.get("REQUESTS_PROXY_PINNED")
    if rpf not in ("0", "1"):
        sys.exit(f"[ERROR] REQUESTS_PROXY_PINNED unreadable: {rpf!r}")
    expect = (rpf == "1") or sides["JOBS_MANAGER"][0]
    if rp_pinned != expect:
        bad.append(f"REQUESTS_PROXY: render pinned={rp_pinned} but own override={rpf} and jobs-manager pinned={sides['JOBS_MANAGER'][0]}")
    if rpf == "0" and rp_pinned and rp_digest != sides["JOBS_MANAGER"][1]:
        bad.append(f"REQUESTS_PROXY follows jobs-manager but renders {rp_digest} vs {sides['JOBS_MANAGER'][1]}")
    print(f"REQUESTS_PROXY: render pinned={rp_pinned} | own override={rpf}")
if bad:
    print("DISAGREEMENT:\n  " + "\n  ".join(bad))
    sys.exit(1)
print("AGREE")
PYX
}

@test "defaults: nothing pinned on either side" {
  render
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"JOBS_MANAGER: render pinned=False"*"PINNED=0"* ]] || return 1
}

@test "INCIDENT: three legacy pins at the ghcr.io default -- render floats, env says unpinned, CronJob kept" {
  render --set images.jobsManager.digest=$A --set images.podsMonitor.digest=$B --set images.resourceMonitor.digest=$C
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"JOBS_MANAGER: render pinned=False"*"PINNED=0"* ]] || return 1
  [[ "$output" != *"CronJob: retired"* ]] || return 1
}

@test "three legacy pins under the docker.io rollback -- honoured on both sides, CronJob retired" {
  render --set images.traceblocRegistry=docker.io \
    --set images.jobsManager.digest=$A --set images.podsMonitor.digest=$B --set images.resourceMonitor.digest=$C
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"CronJob: retired"* ]] || return 1
}

@test "three pins declared on ghcr.io at the default -- honoured on both sides, CronJob retired" {
  render --set images.jobsManager.digest=$A --set images.jobsManager.digestRegistry=ghcr.io \
    --set images.podsMonitor.digest=$B --set images.podsMonitor.digestRegistry=ghcr.io \
    --set images.resourceMonitor.digest=$C --set images.resourceMonitor.digestRegistry=ghcr.io
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"CronJob: retired"* ]] || return 1
}

@test "three pins declared on docker.io at the ghcr.io default -- ignored on both sides" {
  render --set images.jobsManager.digest=$A --set images.jobsManager.digestRegistry=docker.io \
    --set images.podsMonitor.digest=$B --set images.podsMonitor.digestRegistry=docker.io \
    --set images.resourceMonitor.digest=$C --set images.resourceMonitor.digestRegistry=docker.io
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"RESOURCE_MONITOR: render pinned=False"*"PINNED=0"* ]] || return 1
}

@test "mirror + pins declared on the mirror host -- honoured on both sides" {
  render --set global.imageRegistry=mirror.example.com \
    --set images.jobsManager.digest=$A --set images.jobsManager.digestRegistry=mirror.example.com \
    --set images.podsMonitor.digest=$B --set images.podsMonitor.digestRegistry=mirror.example.com \
    --set images.resourceMonitor.digest=$C --set images.resourceMonitor.digestRegistry=mirror.example.com
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"CronJob: retired"* ]] || return 1
}

@test "mirror + legacy pins -- ignored on both sides (the mirror is not docker.io)" {
  render --set global.imageRegistry=mirror.example.com \
    --set images.jobsManager.digest=$A --set images.podsMonitor.digest=$B --set images.resourceMonitor.digest=$C
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"JOBS_MANAGER: render pinned=False"*"PINNED=0"* ]] || return 1
}

@test "empty knob + legacy pins -- ignored on both sides (empty means the ghcr.io default)" {
  render --set images.traceblocRegistry= \
    --set images.jobsManager.digest=$A --set images.podsMonitor.digest=$B --set images.resourceMonitor.digest=$C
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"PODS_MONITOR: render pinned=False"*"PINNED=0"* ]] || return 1
}

@test "empty knob + pins declared on ghcr.io -- honoured on both sides" {
  render --set images.traceblocRegistry= \
    --set images.jobsManager.digest=$A --set images.jobsManager.digestRegistry=ghcr.io \
    --set images.podsMonitor.digest=$B --set images.podsMonitor.digestRegistry=ghcr.io \
    --set images.resourceMonitor.digest=$C --set images.resourceMonitor.digestRegistry=ghcr.io
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"CronJob: retired"* ]] || return 1
}

@test "mixed: one honoured, one legacy, one declared elsewhere -- each image agrees with itself" {
  render --set images.jobsManager.digest=$A --set images.jobsManager.digestRegistry=ghcr.io \
    --set images.podsMonitor.digest=$B \
    --set images.resourceMonitor.digest=$C --set images.resourceMonitor.digestRegistry=docker.io
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"JOBS_MANAGER: render pinned=True"*"PINNED=1"* ]] || return 1
  [[ "$output" == *"PODS_MONITOR: render pinned=False"*"PINNED=0"* ]] || return 1
  [[ "$output" == *"RESOURCE_MONITOR: render pinned=False"*"PINNED=0"* ]] || return 1
}

@test "requests-proxy: an ignored own pin follows an honoured jobs-manager pin, and the env agrees" {
  render --set images.jobsManager.digest=$A --set images.jobsManager.digestRegistry=ghcr.io \
    --set images.requestsProxy.digest=$D
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"REQUESTS_PROXY: render pinned=True | own override=0"* ]] || return 1
}

@test "requests-proxy: an honoured own pin is the override on both sides" {
  render --set images.requestsProxy.digest=$D --set images.requestsProxy.digestRegistry=ghcr.io
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"REQUESTS_PROXY: render pinned=True | own override=1"* ]] || return 1
}

@test "resourceMonitor: false -- the DaemonSet side is absent and the comparator skips it rather than inventing a verdict" {
  render --set resourceMonitor=false --set images.jobsManager.digest=$A
  run agree; echo "$output"; [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"RESOURCE_MONITOR:"* ]] || return 1
}

# --- the comparator is live -------------------------------------------------

@test "self-mutation: an env flag edited to disagree with the render is caught" {
  render --set images.jobsManager.digest=$A   # legacy pin at ghcr.io: render floats, env says 0
  grep -q 'name: JOBS_MANAGER_PINNED' "$TMP/r.yaml" || return 1
  python3 - "$TMP/r.yaml" "$TMP/m.yaml" <<'PYX'
import sys
s = open(sys.argv[1]).read()
needle = 'name: JOBS_MANAGER_PINNED\n                  value: "0"'
assert s.count(needle) == 1, "mutation anchor not found -- the mutation did not apply"
open(sys.argv[2], "w").write(s.replace(needle, needle.replace('"0"', '"1"')))
PYX
  ! cmp -s "$TMP/r.yaml" "$TMP/m.yaml" || return 1   # the mutation applied
  run agree "$TMP/m.yaml"; echo "$output"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"DISAGREEMENT"*"JOBS_MANAGER: render pinned=False but JOBS_MANAGER_PINNED=1"* ]] || return 1
}

@test "self-mutation: a PIN value edited away from the rendered digest is caught" {
  render --set images.jobsManager.digest=$A --set images.jobsManager.digestRegistry=ghcr.io
  python3 - "$TMP/r.yaml" "$TMP/m.yaml" "$A" <<'PYX'
import sys
s = open(sys.argv[1]).read()
needle = f'name: JOBS_MANAGER_PIN\n                  value: "{sys.argv[3]}"'
assert s.count(needle) == 1, "mutation anchor not found -- the mutation did not apply"
open(sys.argv[2], "w").write(s.replace(needle, needle.replace("aaaa", "ffff", 1)))
PYX
  ! cmp -s "$TMP/r.yaml" "$TMP/m.yaml" || return 1
  run agree "$TMP/m.yaml"; echo "$output"
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *"JOBS_MANAGER: render digest="*"but JOBS_MANAGER_PIN="* ]] || return 1
}

@test "fail closed: a manifest with no jobs-manager Deployment is an error, not agreement" {
  printf 'kind: ConfigMap\nmetadata:\n  name: x\n' > "$TMP/none.yaml"
  run agree "$TMP/none.yaml"
  [ "$status" -eq 1 ] || [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"no jobs-manager Deployment"* ]] || return 1
}
