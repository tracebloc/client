#!/usr/bin/env bats
# The pull Secret every pod in the release pulls with, and the name jobs-manager
# stamps onto the TRAINING pods it spawns (backend#2119).
#
# WHY THESE EXIST
# client-runtime's job.yaml carried `imagePullSecrets: [{name: regcred}]` as a
# literal. This chart has never created a Secret by that name — it renders
# `<release>-regcred` — so the reference resolved on NO release: every training
# pod named a Secret the kubelet could not retrieve and fell back to an
# ANONYMOUS pull of the ~2.7GB training image. That defect survived because the
# chart had no rendering test for the pull-secret paths at all; the first version
# of the fix was verified by rendering it once by hand (client#751).
#
# These render the REAL chart with helm. A stubbed render would test the stub,
# and the whole question here is what helm emits for five different value
# shapes — including the two that must emit NOTHING, which is where a
# hand-check is least reliable.

CHART=""
VALUES=""
NS="tracebloc"

# A missing tool is a SKIP on a laptop and a FAILURE in CI.
#
# The first version of this file skipped unconditionally, and the only job that
# runs `scripts/tests/*.bats` — the required `Unit tests` job — had no helm. So
# all fourteen cases were silent skips: a wrong IMAGE_PULL_SECRET_NAME or Secret
# name would have shipped green past tests written to catch exactly that (Bugbot
# on client#751). In a required gate a skip is indistinguishable from a pass,
# which is the whole inert-verification class this repo keeps finding.
#
# `CI` is set to `true` by GitHub Actions on every runner.
require_tool() {
  command -v "$1" >/dev/null && return 0
  if [ "${CI:-}" = "true" ]; then
    echo "::error::$1 is missing in CI, so these chart-render assertions would" >&2
    echo "::error::be skipped rather than run. Install it in the job (see" >&2
    echo "::error::standard-checks.yml 'Set up Helm') instead of accepting a green skip." >&2
    return 1
  fi
  skip "$1 not installed (local run)"
}

setup() {
  # Set here rather than in setup_file: exports from setup_file do not reach the
  # test body in every bats version, and an empty $CHART makes helm fail with
  # "non-absolute URLs" — eleven confusing reds instead of one clear skip.
  CHART="${BATS_TEST_DIRNAME}/../../client"
  VALUES="${CHART}/ci/bm-values.yaml"
  require_tool helm || return 1
  require_tool python3 || return 1
  [ -d "$CHART" ] || {
    echo "chart directory not found at $CHART" >&2
    return 1
  }
  [ -f "$VALUES" ] || {
    echo "CI values file not found at $VALUES" >&2
    return 1
  }
}

# Render, or fail the test with helm's own message rather than an empty file.
render() {
  run helm template myrel "$CHART" -f "$VALUES" --namespace "$NS" "$@"
  [ "$status" -eq 0 ] || {
    echo "helm template failed: $output" >&2
    return 1
  }
  printf '%s\n' "$output"
}

# IMAGE_PULL_SECRET_NAME values in one container of the jobs-manager Deployment.
# Parsed as YAML, not grepped: the two containers each have their own env list,
# and a grep cannot tell which one it is looking at — the exact confusion that
# made the first count of this variable read 2 when the api container had 1.
env_values_in() {
  python3 -c '
import sys, yaml
want_container, want_key = sys.argv[1], sys.argv[2]
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not doc or doc.get("kind") != "Deployment":
        continue
    if "jobs-manager" not in doc["metadata"]["name"]:
        continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c["name"] != want_container:
            continue
        for e in (c.get("env") or []):
            if e["name"] == want_key:
                print(e.get("value"))
' "$1" "$2"
}

dockerconfig_secrets() {
  python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin.read()):
    if doc and doc.get("type") == "kubernetes.io/dockerconfigjson":
        print(doc["metadata"]["name"], doc["metadata"]["namespace"])
'
}

pull_secret_refs() {
  python3 -c '
import sys, yaml
names = set()
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "imagePullSecrets" and isinstance(v, list):
                names.update(x.get("name") for x in v if isinstance(x, dict))
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
for doc in yaml.safe_load_all(sys.stdin.read()):
    walk(doc)
for n in sorted(x for x in names if x):
    print(n)
'
}

created() {
  render --set dockerRegistry.create=true \
         --set dockerRegistry.server=https://index.docker.io/v1/ \
         --set dockerRegistry.username=u \
         --set dockerRegistry.password=p \
         --set dockerRegistry.email=e@x.io "$@"
}

# ---- the chart builds the Secret -------------------------------------------

@test "create: the injected name is the Secret the chart actually renders" {
  out="$(created)" || return 1
  # The property that was broken: the name jobs-manager stamps on training pods
  # must be a Secret that EXISTS in this render, not a plausible string.
  [ "$(printf '%s\n' "$out" | env_values_in api IMAGE_PULL_SECRET_NAME)" = "myrel-regcred" ] || return 1
  printf '%s\n' "$out" | dockerconfig_secrets | grep -qx "myrel-regcred ${NS}" || return 1
}

@test "create: every imagePullSecrets block names that same Secret" {
  out="$(created)" || return 1
  refs="$(printf '%s\n' "$out" | pull_secret_refs)"
  [ -n "$refs" ] || return 1
  # One distinct name across the whole release. A second name here is the
  # original defect in a new place: a pod referring to a Secret nobody made.
  [ "$(printf '%s\n' "$refs" | sort -u | wc -l | tr -d ' ')" = "1" ] || return 1
  [ "$(printf '%s\n' "$refs" | sort -u)" = "myrel-regcred" ] || return 1
}

# ---- the operator brings their own -----------------------------------------

@test "existingSecret: the name is the operator's, everywhere" {
  out="$(render --set dockerRegistry.existingSecret=regcred)" || return 1
  [ "$(printf '%s\n' "$out" | env_values_in api IMAGE_PULL_SECRET_NAME)" = "regcred" ] || return 1
  [ "$(printf '%s\n' "$out" | pull_secret_refs | sort -u)" = "regcred" ] || return 1
}

@test "existingSecret: the chart renders NO Secret, so it cannot overwrite it" {
  # The trap this split exists for. Gating the Secret template on "a pull
  # secret exists" instead of "the chart creates it" would have the chart write
  # the operator's Secret from credentials it does not have — turning a
  # supported config into a broken pull on the first upgrade.
  out="$(render --set dockerRegistry.existingSecret=regcred)" || return 1
  [ -z "$(printf '%s\n' "$out" | dockerconfig_secrets)" ] || return 1
}

# ---- public: the absence has to be real ------------------------------------

@test "public: no name is injected and no imagePullSecrets are rendered" {
  # Absence is the declaration of an anonymous pull, and client-runtime reads
  # it that way. If the variable appeared here with an empty or stale value the
  # runtime would set a pull secret nothing created — the defect, inverted.
  out="$(render)" || return 1
  [ -z "$(printf '%s\n' "$out" | env_values_in api IMAGE_PULL_SECRET_NAME)" ] || return 1
  [ -z "$(printf '%s\n' "$out" | pull_secret_refs)" ] || return 1
  [ -z "$(printf '%s\n' "$out" | dockerconfig_secrets)" ] || return 1
}

@test "create: false with no existingSecret is public, not half-configured" {
  out="$(render --set dockerRegistry.create=false)" || return 1
  [ -z "$(printf '%s\n' "$out" | env_values_in api IMAGE_PULL_SECRET_NAME)" ] || return 1
  [ -z "$(printf '%s\n' "$out" | pull_secret_refs)" ] || return 1
}

# ---- the contradiction is refused at BOTH layers ---------------------------

@test "create plus existingSecret is refused by the values schema" {
  run helm template myrel "$CHART" -f "$VALUES" --namespace "$NS" \
    --set dockerRegistry.create=true \
    --set dockerRegistry.server=https://index.docker.io/v1/ \
    --set dockerRegistry.username=u --set dockerRegistry.password=p \
    --set dockerRegistry.email=e@x.io \
    --set dockerRegistry.existingSecret=regcred
  [ "$status" -ne 0 ] || return 1
  # Anchored on text that is IDENTICAL across helm generations, because the
  # per-rule wording is not. Measured on both, for the same values:
  #
  #   3.15.4 (the CI pin)
  #     - dockerRegistry.create: dockerRegistry.create does not match: false
  #   4.1.1 (a current local build)
  #     - at '/dockerRegistry/create': value must be false
  #
  # The first version of this asserted `*"must be false"*` and went red in the
  # required Unit tests job the moment helm was installed there — a
  # version-specific string in an assertion, which is the same defect class as
  # a hand-copied constant (Bugbot on client#751, whose conclusion was right;
  # its stated cause, case-sensitivity on "Must be false", is not what 3.15.4
  # actually prints).
  #
  # The header line proves the SCHEMA layer refused rather than the template,
  # which is the distinction this test exists to make; `create` and `false`
  # together pin WHICH rule fired, so an unrelated schema failure — a missing
  # required value, say — cannot satisfy it.
  [[ "$output" == *"meet the specifications of the schema"* ]] || return 1
  printf '%s\n' "$output" | grep -qi "create" || return 1
  printf '%s\n' "$output" | grep -qi "false" || return 1
}

@test "create plus existingSecret is refused by the template when the schema is skipped" {
  # --skip-schema-validation exists, so the schema is a declaration and not a
  # gate. The template refusal is the gate, and it says which two values
  # collide rather than failing somewhere downstream on a name.
  #
  # The flag landed in helm 3.16 and CI pins v3.15.4, so this case self-skips
  # there — the same treatment and the same reason as the helper-backstop cases
  # in chart-env-vocabulary.sh. It runs for anyone local on 3.16+, and bumping
  # the CI pin turns it on with no change here. The SCHEMA half of this pair
  # (the test above) runs on every version, so the contradiction is never
  # unguarded; this case only proves the second layer.
  helm template --help 2>&1 | grep -q -- "--skip-schema-validation" || {
    skip "helm $(helm version --short 2>/dev/null) predates --skip-schema-validation (3.16)"
  }
  run helm template myrel "$CHART" -f "$VALUES" --namespace "$NS" \
    --skip-schema-validation \
    --set dockerRegistry.create=true \
    --set dockerRegistry.server=https://index.docker.io/v1/ \
    --set dockerRegistry.username=u --set dockerRegistry.password=p \
    --set dockerRegistry.email=e@x.io \
    --set dockerRegistry.existingSecret=regcred
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"contradict"* ]] || return 1
}

# ---- the passthrough cannot shadow a computed value ------------------------

@test "env.IMAGE_PULL_SECRET_NAME cannot shadow the computed name" {
  # `.Values.env` is copied into both containers wholesale, so a computed var
  # that is not excluded renders TWICE and the passthrough copy wins. For most
  # vars that is a slow pull; for this one client-runtime treats a name that
  # does not resolve as permanent and dead-letters the experiment, so a
  # shadowed value costs the run (Asad on client#751).
  out="$(render --set dockerRegistry.existingSecret=regcred \
                --set env.IMAGE_PULL_SECRET_NAME=shadowed)" || return 1
  [ "$(printf '%s\n' "$out" | env_values_in api IMAGE_PULL_SECRET_NAME)" = "regcred" ] || return 1
  # And inert in the container that never reads it, rather than sitting there.
  [ -z "$(printf '%s\n' "$out" | env_values_in pods-monitor-container IMAGE_PULL_SECRET_NAME)" ] || return 1
}

@test "no container renders any env key twice" {
  # The general form of the finding above, so the next computed var added
  # without an exclusion is caught here rather than in a review. Asserted
  # across every workload in the chart, not just jobs-manager.
  out="$(created --set env.IMAGE_PULL_SECRET_NAME=shadowed \
                 --set env.SOMETHING_HARMLESS=ok)" || return 1
  dupes="$(printf '%s\n' "$out" | python3 -c '
import sys, yaml, collections
bad = []
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not doc or not isinstance(doc, dict):
        continue
    kind = doc.get("kind")
    if kind not in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod"):
        continue
    spec = doc.get("spec") or {}
    pod = (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template")
           or spec.get("template") or {})
    podspec = (pod.get("spec") if pod else None) or (spec if kind == "Pod" else {})
    for group in ("initContainers", "containers"):
        for c in (podspec.get(group) or []):
            names = [e["name"] for e in (c.get("env") or [])]
            for name, n in collections.Counter(names).items():
                if n > 1:
                    where = kind + "/" + doc["metadata"]["name"] + ":" + c["name"]
                    bad.append(where + ":" + name + " x" + str(n))
print("\n".join(sorted(bad)))
')"
  if [ -n "$dupes" ]; then
    echo "env keys rendered more than once in one container:" >&2
    echo "$dupes" >&2
    return 1
  fi
}

@test "the duplicate-env check can actually see a duplicate" {
  # Otherwise the test above passes on a parser that found no containers at
  # all, which is indistinguishable from a clean render (BUGBOT.md: an inert
  # check and real coverage look identical in a log). JOB_IMAGE_HOST has the
  # same unexcluded shape and is deliberately left that way — a slow pull is
  # recoverable — so it is the honest live proof that the parser reaches real
  # env lists.
  out="$(created --set env.JOB_IMAGE_HOST=shadowed)" || return 1
  count="$(printf '%s\n' "$out" | env_values_in api JOB_IMAGE_HOST | wc -l | tr -d ' ')"
  [ "$count" = "2" ] || {
    echo "expected JOB_IMAGE_HOST to render twice (it has no exclusion); got $count." >&2
    echo "If it was excluded on purpose, replace this canary with another one —" >&2
    echo "without a live duplicate, the check above proves nothing." >&2
    return 1
  }
}

# ---- RBAC must never name the operator's Secret -----------------------------

rbac_secret_names() {
  # resourceNames on every secrets rule, with the Role's namespace.
  python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin.read()):
    if not doc or doc.get("kind") not in ("Role", "ClusterRole"):
        continue
    ns = (doc.get("metadata") or {}).get("namespace", "-")
    for rule in (doc.get("rules") or []):
        if "secrets" not in (rule.get("resources") or []):
            continue
        for name in (rule.get("resourceNames") or []):
            print(ns, name, ",".join(sorted(rule.get("verbs") or [])))
'
}

@test "existingSecret: no Role grants rights on the operator's own Secret" {
  # The auto-upgrade Role in the GPU device-plugin namespace (kube-system by
  # default) pins get/update/patch/DELETE to a resourceNames list. Resolving it
  # through the release-wide name helper handed that ServiceAccount delete on a
  # bring-your-own dockerconfigjson the chart does not own (Bugbot, client#751).
  out="$(render --set dockerRegistry.existingSecret=regcred \
                --set gpu.devicePlugin.enabled=true \
                --set gpu.devicePlugin.vendor=nvidia)" || return 1
  names="$(printf '%s\n' "$out" | rbac_secret_names)" || return 1
  [ -n "$names" ] || {
    echo "no secrets resourceNames found at all — the parser is not reaching" >&2
    echo "the Roles, so this test would pass on any chart" >&2
    return 1
  }
  if printf '%s\n' "$names" | awk '{print $2}' | grep -qx "regcred"; then
    echo "a Role names the operator's Secret:" >&2
    printf '%s\n' "$names" >&2
    return 1
  fi
}

@test "existingSecret: the chart's own former mirror stays deletable" {
  # The other direction of the same rule. Switching a release from create: true
  # to existingSecret orphans the mirrored <release>-regcred, and Helm must be
  # able to delete it; a resourceNames list that followed existingSecret would
  # 403 on the orphan and stall every later auto-upgrade tick.
  out="$(render --set dockerRegistry.existingSecret=regcred \
                --set gpu.devicePlugin.enabled=true \
                --set gpu.devicePlugin.vendor=nvidia)" || return 1
  printf '%s\n' "$out" | rbac_secret_names \
    | grep -E "^\S+ myrel-regcred " | grep -q "delete" || {
      echo "no rule can delete myrel-regcred, so a create->existingSecret" >&2
      echo "migration leaves an orphan nothing is allowed to remove:" >&2
      printf '%s\n' "$out" | rbac_secret_names >&2
      return 1
    }
}

@test "create: the RBAC name still matches the Secret that is rendered" {
  # Splitting the two names must not desynchronise the ordinary path: the name
  # RBAC pins and the name the Secret carries have to be the same string.
  out="$(created --set gpu.devicePlugin.enabled=true \
                 --set gpu.devicePlugin.vendor=nvidia)" || return 1
  printf '%s\n' "$out" | dockerconfig_secrets | grep -q "^myrel-regcred " || return 1
  printf '%s\n' "$out" | rbac_secret_names | grep -qE "^\S+ myrel-regcred " || return 1
}
