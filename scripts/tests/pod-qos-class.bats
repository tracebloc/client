#!/usr/bin/env bats
# =============================================================================
#  pod-qos-class.bats — pin the QoS class of every workload this chart renders.
#
#  backend#2872: ten places claimed "Guaranteed QoS" and every one was false. They
#  survived because no test tier could assert a class -- `status.qosClass` is
#  computed by the API server, so `helm unittest` cannot express it, and
#  `grep qosClass client/tests/` returned nothing. What existed instead were
#  assertions on *the values believed to imply the class*, which is how a wrong
#  claim about a class stays green.
#
#  This renders the REAL chart (like chart-pull-secret.bats) and DERIVES the class
#  with the kubelet's own rule via pod-qos-class.py. The expected table below is
#  the point: a silent class change fails here instead of being discovered in a
#  ticket eight months later.
#
#  The table is asserted per (workload, hostPath mode) because the mode CHANGES
#  the answer -- jobs-manager renders an unresourced init container only when
#  hostPath.enabled=true. A single-mode check would have agreed with the wrong
#  comments on exactly the clusters the installer provisions.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CHART="${REPO_ROOT}/client"
  QOS="${BATS_TEST_DIRNAME}/pod-qos-class.py"
}

# _render <hostPathEnabled> <outfile> — render the chart with the placeholder
# credentials the chart requires. Fails the caller if helm fails: an unrendered
# chart must not read as "no findings".
_render() {
  local hp="$1" out="$2"; shift 2
  # "$@" carries any extra --set pairs. Added because the suite could not render the
  # GPU device plugins at all, so it never classified the chart's ONLY Guaranteed
  # pods (Bugbot, review on client#922).
  helm template t "$CHART" \
    --set "hostPath.enabled=${hp}" \
    --set storageClass.create=false \
    --set clientId=probe --set clientPassword=probe "$@" > "$out" 2>"${out}.err"
}

# _class_of <rendered> <workload-suffix> — the derived class for one workload.
_class_of() {
  python3 "$QOS" "$1" | awk -F'\t' -v w="$2" '$1 ~ w {print $2; exit}'
}

@test "hostPath edges (installer default): EVERY rendered workload matches the declared class" {
  local r="$BATS_TEST_TMPDIR/hostpath-on.yaml"
  _render true "$r" || return 1
  # DERIVED, NOT RESTATED. The expectation file is compared by set equality in both
  # directions, so a workload the chart starts rendering fails until someone
  # classifies it, and a stale row fails rather than being satisfied by nothing.
  # The previous version listed six names by hand while the chart rendered TEN --
  # auto-upgrade, image-refresh and the two check Jobs were classified and then
  # ignored (Bugbot, review on client#922; CLAUDE.md rule 1).
  run python3 "$QOS" "$r" --expect "${BATS_TEST_DIRNAME}/pod-qos-expect.hostpath.txt"
  [ "$status" -eq 0 ] || return 1
  # No workload is BestEffort. values.yaml claimed jobs-manager once was; it never
  # was (backend#2872), and a workload BECOMING BestEffort is a real regression --
  # an unresourced pod is the kernel OOM killer's first victim.
  ! python3 "$QOS" "$r" | grep -q 'BestEffort' || return 1
}

@test "CSI clusters (hostPath off): the class table is asserted separately, because the mode changes it" {
  local r="$BATS_TEST_TMPDIR/hostpath-off.yaml"
  _render false "$r" || return 1
  run python3 "$QOS" "$r" --expect "${BATS_TEST_DIRNAME}/pod-qos-expect.csi.txt"
  [ "$status" -eq 0 ] || return 1
}

@test "GPU device plugins are Guaranteed — the chart's only Guaranteed pods, per vendor" {
  # THE GAP THIS CLOSES: `_render` never enabled gpu.devicePlugin, so neither
  # nvidia-device-plugin-daemonset nor amdgpu-device-plugin-daemonset was ever
  # classified. They are Guaranteed — which is exactly what client#919 bought — so
  # stripping their resources would return them to BestEffort, leave every GPU
  # training pod Pending, and this guard would have stayed green.
  #
  # Per vendor, because the chart renders ONE plugin keyed on
  # gpu.devicePlugin.vendor: asserting only nvidia would leave the amd template
  # unclassified, which is the same partial-coverage mistake one level down.
  local v
  for v in nvidia amd; do
    local r="$BATS_TEST_TMPDIR/gpu-$v.yaml"
    _render true "$r" --set gpu.devicePlugin.enabled=true --set "gpu.devicePlugin.vendor=$v" || return 1
    run python3 "$QOS" "$r" --expect "${BATS_TEST_DIRNAME}/pod-qos-expect.gpu-$v.txt"
    [ "$status" -eq 0 ] || return 1
  done
}

@test "a device plugin demoted to BestEffort FAILS (the regression client#919 fixed)" {
  # Non-vacuity for the test above, and it pins the actual regression: the plugin
  # shipped BestEffort before client#919. Strip the class from the expectation and
  # the check must refuse rather than shrug.
  local r="$BATS_TEST_TMPDIR/gpu-mut.yaml" e="$BATS_TEST_TMPDIR/gpu-mut.txt"
  _render true "$r" --set gpu.devicePlugin.enabled=true --set gpu.devicePlugin.vendor=nvidia || return 1
  sed 's/^class  nvidia-device-plugin-daemonset  Guaranteed/class  nvidia-device-plugin-daemonset  BestEffort/' \
    "${BATS_TEST_DIRNAME}/pod-qos-expect.gpu-nvidia.txt" > "$e"
  run python3 "$QOS" "$r" --expect "$e"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"QoS class is Guaranteed, expected BestEffort"* ]] || return 1
}

@test "an unclassified workload FAILS rather than being ignored (the guard is not vacuous)" {
  # Mutation-in-a-test: drop a row from the expectation and the check must refuse.
  # Without this, the set-equality claim above is untested and the file could drift
  # back to a partial list silently.
  local r="$BATS_TEST_TMPDIR/hp.yaml" e="$BATS_TEST_TMPDIR/partial.txt"
  _render true "$r" || return 1
  grep -v 't-image-refresh' "${BATS_TEST_DIRNAME}/pod-qos-expect.hostpath.txt" > "$e"
  run python3 "$QOS" "$r" --expect "$e"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"t-image-refresh"* ]] || return 1
  [[ "$output" == *"no \`class\` row declares it"* ]] || return 1
}

@test "a stale expectation row FAILS rather than passing on nothing" {
  local r="$BATS_TEST_TMPDIR/hp2.yaml" e="$BATS_TEST_TMPDIR/stale.txt"
  _render true "$r" || return 1
  cat "${BATS_TEST_DIRNAME}/pod-qos-expect.hostpath.txt" > "$e"
  printf 'class  t-workload-that-was-deleted  Burstable\n' >> "$e"
  run python3 "$QOS" "$r" --expect "$e"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"renders no such workload"* ]] || return 1
}

@test "a vanished unresourced init container FAILS (it decides whether Guaranteed is reachable)" {
  # init-mysql-data disappearing was invisible before: the old check tested that two
  # names APPEARED, which is a membership test where a set comparison was needed.
  local r="$BATS_TEST_TMPDIR/hp3.yaml" e="$BATS_TEST_TMPDIR/initdrift.txt"
  _render true "$r" || return 1
  sed 's/init-mysql-data,mysql-format-guard/mysql-format-guard/' \
    "${BATS_TEST_DIRNAME}/pod-qos-expect.hostpath.txt" > "$e"
  run python3 "$QOS" "$r" --expect "$e"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"unresourced init containers are"* ]] || return 1
}

@test "the unresourced init container is really there on hostPath edges (the blocker is not hypothetical)" {
  local r="$BATS_TEST_TMPDIR/hp-on.yaml"
  _render true "$r" || return 1
  run python3 "$QOS" "$r"
  [ "$status" -eq 0 ] || return 1
  # The REASON must name the init container, not just the class. A checker that
  # said "Burstable" for the wrong reason would agree with the comments this
  # ticket corrected.
  [[ "$output" == *"init-writable-data"* ]] || return 1
  [[ "$output" == *"mysql-format-guard"* ]] || return 1
}

# --- the derivation itself, exercised against constructed specs ---------------
# These drive the checker over constructed manifests, so the rule is tested
# independently of the chart. Without them, a checker that returned "Burstable"
# unconditionally would pass every assertion above — the chart has no Guaranteed
# pod, so the expected table cannot distinguish a working rule from a stuck one.

@test "derivation: requests == limits on both dimensions in every container -> Guaranteed" {
  # Driven through a temp manifest rather than by importing the module, which
  # also proves the file behaves the way CI invokes it.
  local f="$BATS_TEST_TMPDIR/guaranteed.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: g\nspec:\n  containers:\n  - name: c\n    resources:\n      requests: {cpu: "1", memory: 1Gi}\n      limits: {cpu: "1", memory: 1Gi}\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Guaranteed"* ]] || return 1
}

@test "derivation: ONE unresourced init container demotes an otherwise-Guaranteed pod" {
  local f="$BATS_TEST_TMPDIR/init-demote.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: d\nspec:\n  initContainers:\n  - name: bare\n  containers:\n  - name: c\n    resources:\n      requests: {cpu: "1", memory: 1Gi}\n      limits: {cpu: "1", memory: 1Gi}\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Burstable"* ]] || return 1
  [[ "$output" == *"bare:cpu"* ]] || return 1
}

@test "derivation: pod-level resources reach Guaranteed DESPITE an unresourced init container" {
  # KEP-2837, beta in 1.36 — measured on a real cluster before being encoded.
  # This is the assertion that makes pod-level resources the only route for
  # installer edges, rather than a preference.
  local f="$BATS_TEST_TMPDIR/podlevel.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  resources:\n    requests: {cpu: "1", memory: 512Mi}\n    limits: {cpu: "1", memory: 512Mi}\n  initContainers:\n  - name: bare\n  containers:\n  - name: c\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Guaranteed"* ]] || return 1
  [[ "$output" == *"pod-level"* ]] || return 1
}

# BOTH dimensions must be checked, and no chart pod exercises this: every pod
# here has cpu req != lim, so a checker that ignored MEMORY entirely would agree
# with the expected table above. Found by mutation Q2 — the table alone could not
# see the gap (CLAUDE.md #6: mutation coverage cannot see a vocabulary gap, so
# derive the input domain instead).
@test "derivation: cpu equal but MEMORY unequal is still Burstable" {
  local f="$BATS_TEST_TMPDIR/mem-unequal.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: m\nspec:\n  containers:\n  - name: c\n    resources:\n      requests: {cpu: "1", memory: 512Mi}\n      limits: {cpu: "1", memory: 1Gi}\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Burstable"* ]] || return 1
  [[ "$output" == *"c:memory"* ]] || return 1
}

# The mirror: memory equal, cpu unequal. Together the two pin that NEITHER
# dimension may be dropped from the rule.
@test "derivation: memory equal but CPU unequal is still Burstable" {
  local f="$BATS_TEST_TMPDIR/cpu-unequal.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  containers:\n  - name: c\n    resources:\n      requests: {cpu: "1", memory: 1Gi}\n      limits: {cpu: "2", memory: 1Gi}\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Burstable"* ]] || return 1
  [[ "$output" == *"c:cpu"* ]] || return 1
}

@test "derivation: no requests and no limits anywhere -> BestEffort" {
  local f="$BATS_TEST_TMPDIR/besteffort.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: b\nspec:\n  containers:\n  - name: c\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"BestEffort"* ]] || return 1
}

@test "fails closed: a render with no workloads is a finding, not agreement" {
  local f="$BATS_TEST_TMPDIR/empty.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: nothing\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"refusing to report agreement"* ]] || return 1
}

# ONLY cpu and memory count toward the class. This is not pedantry: it is the
# difference between "Burstable" and "BestEffort" for every GPU training pod
# client-runtime spawns (backend#2871), whose container requests
# `nvidia.com/gpu` and `ephemeral-storage` and NEITHER cpu nor memory. A checker
# that counted any resource key would call those Burstable and quietly agree that
# they are fine.
@test "derivation: gpu + ephemeral-storage only, no cpu/memory -> BestEffort" {
  local f="$BATS_TEST_TMPDIR/gpu-only.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: g\nspec:\n  containers:\n  - name: c\n    resources:\n      requests: {nvidia.com/gpu: "1", ephemeral-storage: 20Gi}\n      limits: {nvidia.com/gpu: "1", ephemeral-storage: 20Gi}\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"BestEffort"* ]] || return 1
}

# The mirror, so the rule is not simply "ignore everything unknown": a pod that
# sets cpu/memory AND extended resources is still classified on cpu/memory.
@test "derivation: extended resources alongside equal cpu/memory -> still Guaranteed" {
  local f="$BATS_TEST_TMPDIR/gpu-plus.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: g\nspec:\n  containers:\n  - name: c\n    resources:\n      requests: {cpu: "1", memory: 1Gi, nvidia.com/gpu: "1"}\n      limits: {cpu: "1", memory: 1Gi, nvidia.com/gpu: "1"}\n' > "$f"
  run python3 "$QOS" "$f"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Guaranteed"* ]] || return 1
}
