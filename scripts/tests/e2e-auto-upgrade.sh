#!/usr/bin/env bash
# =============================================================================
#  e2e-auto-upgrade.sh — fleet auto-upgrade non-regression gate
# -----------------------------------------------------------------------------
#  The fleet self-upgrades hourly via auto-upgrade-cronjob.yaml:
#      helm upgrade <rel> tracebloc/client --version <latest> --reset-then-reuse-values
#  and operators habitually run `helm upgrade --reuse-values` by hand. Both
#  replay OLD stored values against the NEW chart — the failure mode that has
#  repeatedly bitten this chart (nil-pointer templating on keys the stored
#  values predate; see requests_proxy_test.yaml / resource_monitor_test.yaml).
#
#  This gate installs the LAST PUBLISHED chart from gh-pages on a real k3d
#  cluster, then upgrades to the LOCAL working-tree chart through both flag
#  paths and asserts the contract that keeps the fleet safe:
#    1. `--reuse-values`            -> upgrade succeeds (nil-guards hold), the
#                                      egress lockdown does NOT engage by
#                                      accident, and the prod ingestor pin
#                                      matches the BASELINE release: absent when
#                                      the published chart predates the pin key,
#                                      replayed VERBATIM when it carries one —
#                                      never injected from the new chart's
#                                      defaults (documented limitation).
#    2. `--reset-then-reuse-values` -> upgrade succeeds, new defaults flow in
#                                      (egress gateway deploys, inert),
#                                      out-of-band image-refresh annotations
#                                      survive, AND the chart-default prod
#                                      ingestor pin lands on the already-
#                                      installed edge (backend#1245 — the thing
#                                      an install-time `-f` overlay could never
#                                      do, because a user-supplied value is
#                                      replayed verbatim forever).
#    3. flip the #102 lockdown flags + images.ingestor.prodPin=false
#                                   -> rule 2 drops, jobs-manager routes pods at
#                                      the gateway, canary floats off the pin.
#    4. the next plain auto-upgrade  -> the operator's overrides PERSIST.
#
#  Pods are NEVER waited on: the published images need real credentials to go
#  healthy, and the regression class this guards lives entirely in Helm
#  templating / values semantics. No secrets; stock GitHub runners.
#
#  Usage:  bash scripts/tests/e2e-auto-upgrade.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"
CHART_DIR="$HERE/../../client"

# Shared bring-up contract (isolation env + tool-install prereqs).
# shellcheck source=/dev/null
source "$HERE/lib/e2e-common.sh"
e2e_isolate_env tbupg
NS="tbupg"
REPO_NAME="tracebloc"
REPO_URL="https://tracebloc.github.io/client"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"
# shellcheck source=/dev/null
source "$LIB/preflight.sh"   # provides _pf_recheck_runtime_mem (called by create_cluster)

cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- assertion helpers (read live cluster state, not helm output) -----------
# Capture-then-match, NOT `kubectl … | grep -q` (backend#1778). grep -q closes
# the pipe on the FIRST match, so once the policy yaml outgrows the ~64KB pipe
# buffer kubectl takes SIGPIPE, pipefail makes the pipeline 141, and this helper
# reports "no external 443" for a policy that HAS it — a silent wrong answer in
# an assertion, which is worse than the abort the same shape causes elsewhere.
netpol_has_external_443() {
  local yaml
  yaml="$(kubectl get networkpolicy "${NS}-training-egress" -n "$NS" -o yaml)" || return 1
  grep -q 'cidr: 0.0.0.0/0' <<<"$yaml"
}

# Same class: `grep -m1` closes after the first match exactly as -q does.
jm_deploy() {
  local names
  names="$(kubectl get deploy -n "$NS" -o name)" || return 1
  grep -m1 'jobs-manager' <<<"$names"
}

jm_egress_proxy_url() {
  kubectl get -n "$NS" "$(jm_deploy)" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EGRESS_PROXY_URL")].value}'
}

# The digest prod ingestion Jobs are spawned from, read off the LIVE Deployment
# (backend#1245). This is the value the whole prod-reproducibility claim rests
# on, so assert it from the cluster rather than from `helm template`.
jm_ingestor_digest() {
  kubectl get -n "$NS" "$(jm_deploy)" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="INGESTOR_IMAGE_DIGEST")].value}'
}

# The working tree's chart-default prod pin — the value an auto-upgrade must
# push onto an already-installed edge. Scoped to the unique `prodDigest:` key so
# it can never pick up a sibling image's `digest:` leaf. yq-free (stock runner).
local_prod_digest() {
  awk -F'"' '/^[[:space:]]*prodDigest:[[:space:]]*"/ {print $2; exit}' "$CHART_DIR/values.yaml"
}

echo "═══════════════════════════════════════════════════════════════════════"
echo "  E2E auto-upgrade gate   arch: $(uname -m)   kernel: $(uname -r)"
echo "═══════════════════════════════════════════════════════════════════════"

# jq reads the baseline release's computed values (BASELINE_PROD_DIGEST).
# Preinstalled on GitHub-hosted runners; local runs must bring their own —
# fail fast here instead of a mid-run pipeline abort.
has jq || error "jq is required (it reads the baseline release's computed values)."
e2e_install_prereqs

echo "── create_cluster() — the installer's real cluster-bring-up path ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s
# Same race the seal-check harnesses guard (client#863): the published chart
# installed just below ALSO carries the resource-monitor preflight (client#823),
# so a fast runner can helm-install before k3s registers the metrics.k8s.io
# APIService and the preflight false-fails the release. Wait for it here too.
e2e_wait_for_metrics_apiservice

echo "── install the LAST PUBLISHED chart (what the fleet runs today) ──"
helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null
helm repo update >/dev/null
# Same idiom the auto-upgrade cronjob uses to pick the newest version.
PREV="$(helm search repo "${REPO_NAME}/client" -o yaml \
  | awk '/^[[:space:]]*version:/ {print $2; exit}')"
[ -n "$PREV" ] || fail "could not resolve the latest published chart version from $REPO_URL"
LOCAL_VERSION="$(awk '/^version:/ {print $2; exit}' "$CHART_DIR/Chart.yaml")"
echo "   published: $PREV   local working tree: $LOCAL_VERSION"

helm install "$NS" "${REPO_NAME}/client" --version "$PREV" \
  --namespace "$NS" --create-namespace \
  --set clientId=ci-e2e-upgrade \
  --set clientPassword=ci-e2e-upgrade \
  --set storageClass.provisioner=rancher.io/local-path

# The baseline (published) release's computed prod-ingestor pin, if any. This
# decides which era path 1 asserts. The boundary is the #383 promotion
# (2026-07-27) — the first PUBLISHED chart release to carry the
# images.ingestor.prodDigest default that #398 added to the chart source.
# Baselines published before it have no pin to replay (the pin must NOT
# arrive via --reuse-values); baselines since carry it in their computed
# values (the SAME pin must be replayed verbatim). Read it from the release,
# not from a date or version compare, so the test is correct in both eras.
# jq is guarded in the preflight above.
BASELINE_PROD_DIGEST="$(helm get values "$NS" -n "$NS" --all -o json \
  | jq -r '.images.ingestor.prodDigest // ""')"
echo "   baseline prod ingestor pin: ${BASELINE_PROD_DIGEST:-<none — pre-pin era>}"

# The baseline (published) release's RENDERED egress posture, captured the same
# way and for the same reason as the prod pin above: path 1's --reuse-values
# replays the baseline's computed values verbatim, so what it must assert is
# "unchanged from the baseline", NOT a hardcoded era. While the published
# baseline is still permissive this is the external-443 rule present + no
# EGRESS_PROXY_URL; once THIS chart (RFC-0003 D6 deny-by-default defaults) is
# the published baseline, --reuse-values replays lockdown instead — 443 gone,
# gateway routed. Read the posture from the installed baseline so the assertion
# is correct in both eras rather than tripping the moment the default flips
# (Bugbot on this PR).
if netpol_has_external_443; then BASELINE_EXTERNAL_443=1; else BASELINE_EXTERNAL_443=0; fi
BASELINE_EGRESS_PROXY_URL="$(jm_egress_proxy_url)"
echo "   baseline egress posture: external_443=$([ "$BASELINE_EXTERNAL_443" = 1 ] && echo present || echo absent) egress_proxy_url=${BASELINE_EGRESS_PROXY_URL:-<none>}"

echo "── simulate an image-refresh-managed annotation (must survive upgrades) ──"
kubectl annotate -n "$NS" "$(jm_deploy)" \
  "tracebloc.io/last-refreshed-jobs-manager-digest=sha256:e2e-sentinel" --overwrite

echo "── path 1: manual-operator habit — helm upgrade --reuse-values ──"
# Old stored values replayed against the new chart: every new key is absent and
# the nil-guards must hold. The egress posture must be REPLAYED FROM THE BASELINE
# VERBATIM — not moved by the new chart's defaults in either direction. That is
# baseline-derived (like the prod pin below), so the assertion holds whether the
# baseline is permissive (443 present, no gateway) or already deny-by-default
# (443 gone, gateway routed) once this chart is published.
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reuse-values
if [ "$BASELINE_EXTERNAL_443" = 1 ]; then
  netpol_has_external_443 || fail "--reuse-values dropped the baseline's external 443 rule (new deny-by-default default leaked in; --reuse-values must replay the baseline verbatim)"
else
  netpol_has_external_443 && fail "--reuse-values added an external 443 rule the deny-by-default baseline did not have (--reuse-values must replay the baseline verbatim)"
fi
[ "$(jm_egress_proxy_url)" = "$BASELINE_EGRESS_PROXY_URL" ] || fail "--reuse-values did not replay the baseline EGRESS_PROXY_URL verbatim: got '$(jm_egress_proxy_url)', want '${BASELINE_EGRESS_PROXY_URL:-<none>}' (new routeWorkloads default leaked in on this path)"
# Documented limitation, asserted so it stays a known quantity: plain
# --reuse-values replays the old release's COMPUTED values and ignores the new
# chart's defaults. What that means for the prod ingestor pin depends on the
# baseline era: a published release that predates images.ingestor.prodDigest
# has no key to replay, so the pin must NOT arrive; a release that already
# carries the pin must have it replayed VERBATIM — the baseline's digest, not
# the working tree's. Either way nothing may be injected from the new chart's
# defaults on this path. The fleet does not use this flag (path 2 does) — an
# operator upgrading by hand with it keeps exactly the values the edge had.
if [ -z "$BASELINE_PROD_DIGEST" ]; then
  [ -z "$(jm_ingestor_digest)" ] \
    || fail "--reuse-values unexpectedly applied a prod ingestor pin; the baseline release predates the key, so replayed computed values cannot contain it"
else
  [ "$(jm_ingestor_digest)" = "$BASELINE_PROD_DIGEST" ] \
    || fail "--reuse-values did not replay the baseline prod pin verbatim: got '$(jm_ingestor_digest)', want '$BASELINE_PROD_DIGEST' (stored computed values must win over new chart defaults on this path)"
fi
echo "   OK: upgrade succeeded, egress posture replayed from the baseline verbatim, ingestor pin matches the baseline era (${BASELINE_PROD_DIGEST:-floating})"

echo "── isolate path 2 from path 1's --reuse-values contamination (#459) ──"
# path 1's --reuse-values rewrote THIS release's recorded values to the baseline's FULL
# computed set — chart defaults (incl. any baseline prod pin) frozen as if user-supplied.
# Left in place, path 2's --reset-then-reuse-values would replay that stale baseline pin
# OVER the new chart default (the replay-contamination bug) and its assertion would pass
# only until a prodDigest bump. Reset the recorded values to just the genuine install-time
# overrides so paths 2-4 assert CLEAN-edge auto-upgrade behavior — the fleet's real
# contract on an edge no one hand-upgraded. (A contaminated REAL edge is a separate
# fleet-audit concern; remediation is exactly this: helm upgrade --reset-values, then
# re-apply the genuinely intended overrides.)
#
# Reset to the PUBLISHED chart ($PREV), NOT $CHART_DIR: the local chart's new defaults
# (the working-tree prod pin, the egress gateway) must arrive via path 2's upgrade, not be
# pre-applied here — otherwise path 2 becomes a same-version no-op whose assertions already
# hold from this step, and a --reset-then-reuse-values → --reuse-values regression would
# slip through (computed values would still carry the local pin). Resetting to the baseline
# keeps path 2 a genuine published→local upgrade that MUST pull the new defaults (#459 Bugbot).
helm upgrade "$NS" "${REPO_NAME}/client" --version "$PREV" --namespace "$NS" --reset-values \
  --set clientId=ci-e2e-upgrade \
  --set clientPassword=ci-e2e-upgrade \
  --set storageClass.provisioner=rancher.io/local-path
# Verify the contamination is actually gone: `helm get values` WITHOUT --all reports only
# USER-SUPPLIED values, so a chart-default key like images.ingestor.prodDigest showing up
# there is exactly the past-–reuse-values fingerprint the issue describes. After the reset
# it must be absent — only the three genuine overrides remain (matches `netpol && fail`
# idiom: safe under set -e, jq's non-zero on absence is the non-final && operand).
helm get values "$NS" -n "$NS" -o json | jq -e '.images.ingestor.prodDigest // empty' >/dev/null 2>&1 \
  && fail "reset-values left images.ingestor.prodDigest in the user-supplied values — path 2 would not test a clean edge (#459)"
echo "   OK: recorded values reset to the genuine overrides — path 2 now tests a clean edge"

echo "── path 2: the fleet auto-upgrade — helm upgrade --reset-then-reuse-values ──"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values
netpol_has_external_443 && fail "auto-upgrade kept the external 443 rule (deny-by-default allowExternalHttps=false did not flow — RFC-0003 D6 / client-runtime#199)"
[ "$(jm_egress_proxy_url)" = "http://egress-proxy-service:3128" ] || fail "auto-upgrade did not inject EGRESS_PROXY_URL (routeWorkloads=true default did not flow — RFC-0003 D6 / client-runtime#199)"
kubectl get deploy "${NS}-egress-proxy" -n "$NS" >/dev/null \
  || fail "auto-upgrade did not deploy the egress gateway (new defaults did not flow)"
ANNOT="$(kubectl get -n "$NS" "$(jm_deploy)" \
  -o jsonpath='{.metadata.annotations.tracebloc\.io/last-refreshed-jobs-manager-digest}')"
[ "$ANNOT" = "sha256:e2e-sentinel" ] || fail "image-refresh annotation was clobbered by the upgrade"
DEPLOYED="$(helm list -n "$NS" --filter "^${NS}\$" -o yaml \
  | awk '/^[[:space:]]*chart:/ {print $2; exit}')"
[ "$DEPLOYED" = "client-${LOCAL_VERSION}" ] || fail "deployed chart is $DEPLOYED, expected client-${LOCAL_VERSION}"
# backend#1245 acceptance criterion: publishing a chart with an updated prod pin
# must change the digest on an ALREADY-INSTALLED edge. This upgrade is the exact
# command the fleet auto-upgrade CronJob runs, with no `-f` and no `--set`. The
# pin arriving here is what the old `-f values-prod.yaml` overlay could never
# do — an overlay value is user-supplied, so it would be replayed verbatim
# forever while the chart's copy was ignored.
# #459 RESOLVED (was the ERA NOTE tripwire): path 1's --reuse-values froze the baseline's
# full computed set (chart defaults as user-supplied), so this assertion used to hold only
# while the baseline pin and the working-tree pin coincided — the first prodDigest bump
# would trip it. We now RESET the recorded values above (path 2 runs on a clean edge), so
# the auto-upgrade genuinely resets to the new chart defaults and re-applies only real
# overrides: the working-tree pin lands here regardless of the baseline era, no false trip.
# (Contaminated REAL edges — ones an operator hand-upgraded with --reuse-values — stay a
# separate fleet-audit concern; the remediation is the reset performed above.)
WANT_DIGEST="$(local_prod_digest)"
[ -n "$WANT_DIGEST" ] \
  || fail "images.ingestor.prodDigest is empty in the working-tree chart — prod would silently lose its reproducibility pin"
GOT_DIGEST="$(jm_ingestor_digest)"
[ "$GOT_DIGEST" = "$WANT_DIGEST" ] \
  || fail "auto-upgrade did not push the prod ingestor pin onto the installed edge: got '${GOT_DIGEST:-<empty>}', want '$WANT_DIGEST' (backend#1245)"
echo "   OK: new defaults flowed in (deny-by-default: gateway routing + external-443 dropped), annotations survived"
echo "   OK: prod ingestor pin reached the installed edge ($WANT_DIGEST)"

echo "── path 3: operator OPTS OUT of the deny-by-default lockdown + opts a canary off the prod pin ──"
# Every --set value is the OPPOSITE of the chart default on purpose (Bugbot on
# this PR): now that deny-by-default ships, re-setting the lockdown values would
# just match the defaults, so path 4 could not tell a preserved override from a
# plain default replay. So opt a fleet fully out — routeWorkloads=false (stop
# routing egress through the gateway) AND allowExternalHttps=true (re-open the
# direct external-443 rule) — both genuine overrides, so path 4 becomes a real
# test that --reset-then-reuse-values keeps each opt-out instead of the next
# hourly auto-upgrade silently re-locking a fleet that deliberately opted out.
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values \
  --set egressProxy.routeWorkloads=false \
  --set networkPolicy.training.allowExternalHttps=true \
  --set images.ingestor.prodPin=false
netpol_has_external_443 \
  || fail "operator opt-out did NOT re-open the external 443 rule (allowExternalHttps=true was ignored)"
[ -z "$(jm_egress_proxy_url)" ] \
  || fail "operator opt-out did NOT stop gateway routing (routeWorkloads=false was ignored — EGRESS_PROXY_URL still injected)"
[ -z "$(jm_ingestor_digest)" ] \
  || fail "prodPin=false did not float the canary edge back onto the ingestor tag (backend#1245)"
echo "   OK: rule 2 re-opened + gateway routing off by the opt-out, canary floats"

echo "── path 4: the NEXT hourly auto-upgrade must preserve both opt-outs ──"
# Both overrides are user-supplied and OPPOSITE the chart default, so
# --reset-then-reuse-values must replay them: an operator who opted a fleet out
# of the lockdown (or floated a canary) must not be silently reverted to the
# deny-by-default / re-pinned by the next hourly upgrade.
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values
netpol_has_external_443 \
  || fail "auto-upgrade reverted the operator's allowExternalHttps=true opt-out back to the deny-by-default (override lost)"
[ -z "$(jm_egress_proxy_url)" ] \
  || fail "auto-upgrade re-injected EGRESS_PROXY_URL, reverting the operator's routeWorkloads=false opt-out (override lost)"
[ -z "$(jm_ingestor_digest)" ] \
  || fail "auto-upgrade re-pinned an edge the operator had opted out with prodPin=false (override lost)"
echo "   OK: the operator's egress opt-outs (routing + external-443) and canary opt-out persist across auto-upgrades"

echo "── path 5: client credentials resolve from the existing Secret (backend#2571) ──"
#  THE ONLY PLACE THIS MECHANISM CAN BE TESTED. secrets.yaml resolves
#  clientId/clientPassword as: values -> the live Secret via `lookup` -> fail.
#  `lookup` is INERT under helm-unittest, so the unit suite cannot observe tier 2
#  at all: deleting the entire tier-2 branch leaves all 30 unit tests green
#  (measured). Without this path, the central mechanism of #2571 ships unverified.
#
#  `--reset-values` discards every user-supplied value, so clientId/clientPassword
#  are genuinely ABSENT on this upgrade. If they still appear in the Secret
#  afterwards, the lookup is the only thing that could have supplied them — helm
#  has nothing left to replay. That is what makes this an assertion about tier 2
#  rather than about --reuse-values.
secret_key() {   # $1 = key name -> decoded value from the release Secret
  kubectl -n "$NS" get secret "${NS}-secrets" -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d
}
[ "$(secret_key CLIENT_ID)" = "ci-e2e-upgrade" ] \
  || fail "baseline Secret has no/unexpected CLIENT_ID — cannot meaningfully test tier 2"

helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-values \
  --set storageClass.provisioner=rancher.io/local-path \
  || fail "upgrade with clientId/clientPassword ABSENT failed — tier 2 (existing-Secret resolution) is broken (backend#2571)"

[ "$(secret_key CLIENT_ID)" = "ci-e2e-upgrade" ] \
  || fail "CLIENT_ID changed or vanished after an upgrade that omitted it — tier 2 must preserve it, not regenerate or drop it"
[ "$(secret_key CLIENT_PASSWORD)" = "ci-e2e-upgrade" ] \
  || fail "CLIENT_PASSWORD changed or vanished after an upgrade that omitted it — tier 2 must preserve it"
echo "   OK: credentials recovered from the live Secret with no values supplied"

#  AN EMPTY KEY MUST READ AS ABSENT, not as resolved (Bugbot, #859). `minLength: 1`
#  had to leave values.schema.json so lookup could run, so the template is the only
#  layer left that can refuse a blank credential -- and `hasKey` alone would have
#  accepted one and shipped it into the pods. Blank the key in the live Secret, then
#  upgrade with no values: this must FAIL, and it must fail naming clientId.
kubectl -n "$NS" patch secret "${NS}-secrets" --type merge \
  -p '{"data":{"CLIENT_ID":""}}' >/dev/null \
  || fail "could not blank CLIENT_ID to test the empty-key path"
_empty_key_err="$(mktemp)"
if helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-values \
     --set storageClass.provisioner=rancher.io/local-path >/dev/null 2>"$_empty_key_err"; then
  fail "an EMPTY CLIENT_ID in the Secret was accepted as resolved -- blank credentials would ship to the pods (#859)"
fi
grep -q "clientId is required and could not be resolved" "$_empty_key_err" \
  || fail "the empty-key upgrade failed for the WRONG reason: $(tr -d '\n' < "$_empty_key_err")"
rm -f "$_empty_key_err"
echo "   OK: an empty Secret key reads as absent and is refused, naming clientId"

#  Restore the credential so anything after this point sees a healthy release.
kubectl -n "$NS" patch secret "${NS}-secrets" --type merge \
  -p "{\"data\":{\"CLIENT_ID\":\"$(printf '%s' ci-e2e-upgrade | base64 | tr -d '\n')\"}}" >/dev/null \
  || fail "could not restore CLIENT_ID after the empty-key check"
[ "$(secret_key CLIENT_ID)" = "ci-e2e-upgrade" ] || fail "CLIENT_ID not restored after the empty-key check"

# ── backend#2879: the existing-datadir root-rotation guard ───────────────────
#  This release was installed with rotation OFF (prod default), so its Secret has
#  no MYSQL_ROOT_PASSWORD and `mysql-pvc` already exists — the exact "datadir
#  predates the rotation" state the guard refuses. Turning the gate on would mint
#  a new root password the live database was never told about (the entrypoint
#  reads MYSQL_ROOT_PASSWORD only at FRESH init), so root would authenticate with
#  neither value and the fleet would lose MySQL auth. This is the guard's LIVE arm
#  (backend#2879 + backend#2892). The guard now has three refuse arms: two are
#  cluster-less — an offline render, or a declared datadir — and ARE unit-tested
#  (helm-unittest renders without a cluster; secrets_test.yaml). This one is
#  different: an existing `mysql-pvc` found by `lookup` on a real cluster.
#  helm-unittest cannot mock `lookup`, so only a live upgrade like this exercises
#  it — deleting the arm-1 `lookup`, or the ack term, is what reddens HERE.
echo "── backend#2879: rotateMysqlRoot on an existing datadir refuses without the ack ──"
[ -z "$(secret_key MYSQL_ROOT_PASSWORD)" ] \
  || fail "precondition: this release must have no MYSQL_ROOT_PASSWORD before the rotation guard check"
_guard_err="$(mktemp)"
if helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values \
     --set rotateMysqlRoot=true >/dev/null 2>"$_guard_err"; then
  fail "rotateMysqlRoot=true was accepted on an EXISTING datadir — the guard did not fire (backend#2879); the mint would break root auth (1045)"
fi
grep -q "rotate-mysql-root.md" "$_guard_err" \
  || fail "the rotation upgrade failed for the WRONG reason (it must name the runbook): $(tr -d '\n' < "$_guard_err")"
rm -f "$_guard_err"
[ -z "$(secret_key MYSQL_ROOT_PASSWORD)" ] \
  || fail "a REFUSED render still mutated the Secret — a failed guard must not mint (backend#2879)"
echo "   OK: the flip is refused at render time, naming the runbook, Secret untouched"

#  The ack flag is the documented escape hatch (the operator will run the manual
#  ALTER USER in the same window): the SAME upgrade must now render and mint. This
#  is what proves the guard's `not .Values.mysqlRootRotationAcknowledged` term is
#  wired — deleting it leaves this red because the flag would no longer matter.
echo "── backend#2879: mysqlRootRotationAcknowledged clears the guard and the mint proceeds ──"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values \
  --set rotateMysqlRoot=true --set mysqlRootRotationAcknowledged=true >/dev/null \
  || fail "the acknowledged rotation upgrade was refused — the ack flag must let the render through (backend#2879)"
[ -n "$(secret_key MYSQL_ROOT_PASSWORD)" ] \
  || fail "the acknowledged upgrade rendered but minted no MYSQL_ROOT_PASSWORD — the ack path must still generate the value"
echo "   OK: with the ack, the render passes and a root password is minted"

# ── backend#947: a born-rotated edge STAYS rotated on its next baked-default upgrade
#  This is the one-way door @LukasWodka caught. The ack upgrade just above rendered
#  rotation ON, so it also laid down the mysql-root-rotated marker ConfigMap. That
#  marker is the whole fix: it lets tracebloc.bakedRootRotationOn tell a born-rotated
#  edge from an existing un-rotated one, which the mysql-pvc alone cannot (the chart
#  creates that PVC on first install, so it is present from the second render on for
#  BOTH). Without the marker, the next auto-upgrade under the BAKED default resolves
#  rotate/reparent OFF, secrets.yaml drops MYSQL_ROOT_PASSWORD, root's generated
#  password is lost (1045) and the mint reverts to edgeuser — the retirement undone.
#  --reset-values clears the explicit rotateMysqlRoot=true from the ack step so this
#  upgrade takes the BAKED path (CLIENT_ENV defaults to prod == rotateMysqlRootByEnv
#  true); clientId etc. resolve from the live Secret (backend#2571). Deleting the
#  marker `lookup` arm of bakedRootRotationOn — or the marker template — reddens HERE.
echo "── backend#947: born-rotated edge stays rotated + keeps its password on baked upgrade ──"
kubectl -n "$NS" get configmap mysql-root-rotated >/dev/null 2>&1 \
  || fail "the rotation-on render did not create the mysql-root-rotated marker (backend#947); bakedRootRotationOn cannot then tell a born-rotated edge from an un-rotated one"
_born="$(secret_key MYSQL_ROOT_PASSWORD)"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-values \
  --set storageClass.provisioner=rancher.io/local-path >/dev/null \
  || fail "the baked-default upgrade of a born-rotated edge was refused (backend#947)"
[ "$(secret_key MYSQL_ROOT_PASSWORD)" = "$_born" ] \
  || fail "MYSQL_ROOT_PASSWORD changed or was dropped on a born-rotated edge's baked-default upgrade (backend#947 one-way door): before='$_born' after='$(secret_key MYSQL_ROOT_PASSWORD)'. The marker must keep rotation on and tier-2 must preserve the value."
[ -n "$(secret_key DB_BOOTSTRAP_PASSWORD)" ] \
  || fail "DB_BOOTSTRAP_PASSWORD dropped on a born-rotated edge's baked-default upgrade — jobs-manager would revert to minting as edgeuser (backend#947)"
echo "   OK: marker present, rotate stayed on under the baked default, root password preserved"

# ── backend#3189: a PRE-MARKER rotated edge STAYS rotated on its baked-default upgrade
#  The one-way door the born-rotated test above closes assumes the marker is present.
#  But fleets rotated under the EARLIER serviceDbAccountsByEnv / rotateMysqlRootByEnv
#  bake did so BEFORE the marker mechanism shipped, so they carry a baked
#  MYSQL_ROOT_PASSWORD with NO marker. bakedRootRotationOn's marker/PVC/cluster arms
#  all read "not rotated" for them, so without the backend#3189 Secret-probe arm the
#  next auto-upgrade drops MYSQL_ROOT_PASSWORD and jobs-manager reverts to the
#  root-equivalent edgeuser -- a SILENT loss of root on an already-rotated fleet.
#  Simulate exactly that state by DELETING the marker off the born-rotated edge above
#  (its Secret still holds the minted root password), then take the same baked-default
#  path. Deleting the `$secret`/`$bakedRoot` arm of bakedRootRotationOn -- or the
#  marker-backfill it drives -- reddens HERE.
echo "── backend#3189: pre-marker rotated edge (baked root, no marker) stays rotated ──"
_premarker_root="$(secret_key MYSQL_ROOT_PASSWORD)"
[ -n "$_premarker_root" ] \
  || fail "precondition: the born-rotated edge must still hold MYSQL_ROOT_PASSWORD before the pre-marker check"
kubectl -n "$NS" delete configmap mysql-root-rotated >/dev/null 2>&1 \
  || fail "could not delete the marker to simulate a pre-marker rotated edge (backend#3189)"
kubectl -n "$NS" get configmap mysql-root-rotated >/dev/null 2>&1 \
  && fail "precondition: the marker must be absent to simulate a pre-marker rotated edge (backend#3189)"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-values \
  --set storageClass.provisioner=rancher.io/local-path >/dev/null \
  || fail "the baked-default upgrade of a pre-marker rotated edge was refused (backend#3189)"
[ "$(secret_key MYSQL_ROOT_PASSWORD)" = "$_premarker_root" ] \
  || fail "MYSQL_ROOT_PASSWORD changed or was DROPPED on a pre-marker rotated edge's baked-default upgrade (backend#3189 silent root loss): before='$_premarker_root' after='$(secret_key MYSQL_ROOT_PASSWORD)'. The baked root in the live Secret must keep bakedRootRotationOn on and tier-2 must preserve the value."
[ -n "$(secret_key DB_BOOTSTRAP_PASSWORD)" ] \
  || fail "DB_BOOTSTRAP_PASSWORD dropped on a pre-marker rotated edge's baked-default upgrade -- jobs-manager would revert to minting as edgeuser (backend#3189)"
kubectl -n "$NS" get configmap mysql-root-rotated >/dev/null 2>&1 \
  || fail "the pre-marker upgrade did not BACKFILL the mysql-root-rotated marker (backend#3189); the edge must converge onto the rename-safe marker signal after one rotation-on render"
echo "   OK: baked root detected, rotate stayed on with no marker, password preserved, marker backfilled"

#  Restore rotation-off so the rest of the run sees the baseline release, mirroring
#  the empty-key check's restore discipline. An explicit rotateMysqlRoot=false
#  bypasses the helper/marker (the deliberate operator override), so this still
#  clears the key even though the marker persists (resource-policy: keep).
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values \
  --set rotateMysqlRoot=false --set mysqlRootRotationAcknowledged=false >/dev/null \
  || fail "could not restore rotation-off after the backend#2879 guard check"
[ -z "$(secret_key MYSQL_ROOT_PASSWORD)" ] \
  || fail "MYSQL_ROOT_PASSWORD not cleared after turning rotation back off"
echo "   OK: rotation restored to off; Secret back to baseline"

# ── acceptance (b): the token rename does not wedge an edge already collecting ──
#  backend#2625. The published chart wrote the Collector's ingest token under the
#  fixed `tracebloc-telemetry-token`; this working tree writes a release-scoped name.
#  An edge already collecting holds ONLY the legacy Secret at upgrade time, so the
#  daemonset pre-flight has to accept it or it refuses the upgrade — the backend#2400
#  deadlock in a new costume. That guard is a `lookup`-backed `fail`, invisible to
#  `helm template` (telemetry_collector_test.yaml says as much), so it can only be
#  exercised against a live cluster — here. The check is namespace-isolated and reaps
#  itself, so it rides this cluster without touching the ${NS} release above.
echo "── acceptance (b): legacy token name still satisfies the Collector pre-flight ──"
# `--require`: a cluster is live here, so the check must RUN, not self-skip. Without
# it a skip would exit 0 and the PASS line below would claim (b) was verified when it
# never ran — the silent no-op the "no silent caps" rule exists to prevent.
bash "$HERE/telemetry-token-migration.sh" --require \
  || fail "the telemetry token pre-flight rejected the legacy Secret name (or could not run) — renaming to a release-scoped token would wedge an edge already collecting (backend#2625)"

echo ""
echo "E2E PASS: ${PREV} -> ${LOCAL_VERSION} upgrades safe on both flag paths; #102 flip engages and persists;"
echo "          prod ingestor pin propagates to an installed edge and honours the prodPin opt-out;"
echo "          client credentials resolve from the existing Secret with no values supplied (#2571);"
echo "          the release-scoped token rename accepts the legacy name mid-migration (#2625)."
