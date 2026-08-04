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
netpol_has_external_443() {
  kubectl get networkpolicy "${NS}-training-egress" -n "$NS" -o yaml \
    | grep -q 'cidr: 0.0.0.0/0'
}

jm_deploy() {
  kubectl get deploy -n "$NS" -o name | grep -m1 'jobs-manager'
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

echo "── simulate an image-refresh-managed annotation (must survive upgrades) ──"
kubectl annotate -n "$NS" "$(jm_deploy)" \
  "tracebloc.io/last-refreshed-jobs-manager-digest=sha256:e2e-sentinel" --overwrite

echo "── path 1: manual-operator habit — helm upgrade --reuse-values ──"
# Old stored values replayed against the new chart: every new key is absent.
# The nil-guards must hold, and the lockdown must NOT engage by accident.
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reuse-values
netpol_has_external_443 || fail "--reuse-values upgrade dropped the external 443 rule (lockdown engaged by accident)"
[ -z "$(jm_egress_proxy_url)" ] || fail "--reuse-values upgrade injected EGRESS_PROXY_URL (routing engaged by accident)"
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
echo "   OK: upgrade succeeded, lockdown stayed off, ingestor pin matches the baseline era (${BASELINE_PROD_DIGEST:-floating})"

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
netpol_has_external_443 || fail "auto-upgrade dropped the external 443 rule (allowExternalHttps default did not flow)"
[ -z "$(jm_egress_proxy_url)" ] || fail "auto-upgrade injected EGRESS_PROXY_URL (routeWorkloads should default false)"
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
echo "   OK: new defaults flowed in (gateway deployed, inert), annotations survived"
echo "   OK: prod ingestor pin reached the installed edge ($WANT_DIGEST)"

echo "── path 3: operator flips the #102 lockdown + opts a canary off the prod pin ──"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values \
  --set egressProxy.routeWorkloads=true \
  --set networkPolicy.training.allowExternalHttps=false \
  --set images.ingestor.prodPin=false
netpol_has_external_443 && fail "lockdown flip did NOT drop the external 443 rule"
[ "$(jm_egress_proxy_url)" = "http://egress-proxy-service:3128" ] \
  || fail "lockdown flip did not point jobs-manager at the egress gateway"
[ -z "$(jm_ingestor_digest)" ] \
  || fail "prodPin=false did not float the canary edge back onto the ingestor tag (backend#1245)"
echo "   OK: rule 2 dropped, training pods route via the gateway, canary floats"

echo "── path 4: the NEXT hourly auto-upgrade must preserve both overrides ──"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values
netpol_has_external_443 && fail "auto-upgrade after the flip re-opened the external 443 rule (override lost)"
[ "$(jm_egress_proxy_url)" = "http://egress-proxy-service:3128" ] \
  || fail "auto-upgrade after the flip lost EGRESS_PROXY_URL (override lost)"
# The canary opt-out is user-supplied, so --reset-then-reuse-values must replay
# it: an edge deliberately floated must not be silently re-pinned by the next
# hourly upgrade.
[ -z "$(jm_ingestor_digest)" ] \
  || fail "auto-upgrade re-pinned an edge the operator had opted out with prodPin=false (override lost)"
echo "   OK: the operator's lockdown and canary opt-out persist across auto-upgrades"

echo ""
echo "E2E PASS: ${PREV} -> ${LOCAL_VERSION} upgrades safe on both flag paths; #102 flip engages and persists;"
echo "          prod ingestor pin propagates to an installed edge and honours the prodPin opt-out."
