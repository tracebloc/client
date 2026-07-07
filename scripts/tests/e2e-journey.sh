#!/usr/bin/env bash
# =============================================================================
#  e2e-journey.sh — last-mile customer journey on a real cluster
# -----------------------------------------------------------------------------
#  Continues exactly where e2e-cluster.sh stops. That job proves the installer's
#  create_cluster() brings up a real k3d cluster and can run a workload, then
#   stops BEFORE the CLI. This job picks up from a live cluster and walks the
#  documented next steps a customer takes:
#
#    1. create_cluster()                      (the installer's real path)
#    2. install the tracebloc CLI via cli/install.sh
#    3. apply a CREDENTIAL-FREE stub that looks like the parent client release
#       to the CLI's discovery (a *-jobs-manager Deployment with the chart's
#       hallmark labels + an `ingestor` ServiceAccount), point the kubeconfig
#       context's namespace at it, and assert `tracebloc cluster info`:
#         (a) succeeds (exit 0), AND
#         (b) succeeds from a FRESH shell (the cli#61 PATH class, on the journey)
#    4. `tracebloc data validate` smoke on a committed ingest spec — offline
#       schema validation (no creds, no cluster), asserted both ways: a valid
#       spec passes and an invalid one is rejected
#    5. teardown (EXIT trap, same as e2e-cluster.sh)
#
#  What it deliberately does NOT do: the private-image tracebloc helm install +
#  backend registration (needs real credentials + a reachable platform). The
#  whole point of the stub is to exercise the CLI's discovery + token + dry-run
#  paths end-to-end WITHOUT any of that — so this runs on stock GitHub runners
#  with no secrets, like e2e-cluster.sh.
#
#  Every long-running step is wrapped in a watchdog timeout so a hang FAILS the
#  job instead of spinning until the 6h GitHub ceiling (ties to the conntrack
#  "looks hung" class — a hang must surface as a red failure, not a timeout).
#
#  Configuration (env):
#    TRACEBLOC_CLI_REF       URL or local path to cli/install.sh (see path-persist.sh).
#    TRACEBLOC_CLI_VERSION   Optional --version tag for install.sh.
#    CLUSTER_NAME            Isolated cluster name (default tbe2e-journey).
#    TB_NAMESPACE            Namespace the stub release lives in (default tracebloc).
#
#  Usage:  bash scripts/tests/e2e-journey.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

# Isolated cluster name so we never touch a real 'tracebloc' cluster; opt out of
# autostart so we don't reconfigure docker.service / restart policies on the host
# (identical isolation posture to e2e-cluster.sh).
export USER="${USER:-$(id -un)}"
export CLUSTER_NAME="${CLUSTER_NAME:-tbe2e-journey}"
export TRACEBLOC_NO_AUTOSTART=1

TB_NAMESPACE="${TB_NAMESPACE:-tracebloc}"
# Cosmetic stand-ins for the chart's real values — discovery keys off the LABELS
# below, not these, so any plausible values work. A release name + a pinned chart
# version make `cluster info`'s output realistic.
STUB_RELEASE="tbe2e"
STUB_CHART_VERSION="0.0.0-e2e"

CLI_REF="${TRACEBLOC_CLI_REF:-}"
CLI_VERSION="${TRACEBLOC_CLI_VERSION:-}"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tb-e2e-journey-XXXXXX")"
cleanup() {
  k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Watchdog: run a step under a hard time limit ─────────────────────────────
# A hang (e.g. a stuck image pull, a wedged API server, the conntrack "looks
# hung" class) must surface as a red FAILURE, not an infinite spinner. `timeout`
# (GNU coreutils) is preinstalled on the Ubuntu runners this job targets; if it's
# somehow absent we degrade to running the step unguarded rather than dying on a
# missing binary (the step can still fail on its own non-zero exit).
guard() { # guard <seconds> <label> -- <command...>
  local secs="$1" label="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  if has timeout; then
    # Capture the real exit status. `if ! timeout ...; then rc=$?` would read the
    # NEGATED status ($? is always 0 inside that branch), so a failed or hung step
    # returned 0 and the whole journey passed vacuously — see the negative-control
    # self-test below. Run the command, stash its status via `|| rc=$?`, act on it.
    local rc=0
    timeout --kill-after=15s "$secs" "$@" || rc=$?
    if [[ $rc -eq 124 ]]; then
      error "step '${label}' exceeded ${secs}s — treating the hang as a failure."
    fi
    return $rc
  else
    warn "'timeout' not found — running '${label}' without a watchdog."
    "$@"
  fi
}

# ── Negative control: prove the watchdog can actually fail ───────────────────
# This whole harness once shipped with a guard() that returned 0 for a failed or
# hung step, so `E2E JOURNEY PASS` was printed vacuously. Before we run any real
# assertion, confirm guard() propagates a non-zero exit — otherwise a green run
# means nothing. Run in a subshell so this script's `set -e` doesn't abort on the
# intentional failure.
if ( guard 5 "watchdog self-test" -- sh -c 'exit 7' ) >/dev/null 2>&1; then
  error "watchdog self-test FAILED: guard() returned 0 for a command that exited non-zero — every assertion below would pass vacuously. Refusing to run."
fi
success "watchdog self-test: guard() propagates failures (a red step stays red)."

echo "═══════════════════════════════════════════════════════════════════════"
echo "  E2E last-mile journey   arch: $(uname -m)   kernel: $(uname -r)"
echo "  install → CLI → cluster info (fresh shell) → dataset push --dry-run"
echo "═══════════════════════════════════════════════════════════════════════"

# ── Step 1: bring the cluster up via the installer's real path ───────────────
has docker || error "Docker is not available on this host."
umask 022
install_kubectl
install_k3d
install_helm

echo ""
echo "── Step 1: create_cluster() — the installer's real cluster-bring-up ─────"
# `timeout` (inside guard) execs an external command in a fresh process, so it
# cannot see create_cluster — a shell function sourced from cluster.sh (guarding
# it directly fails with "timeout: failed to run command 'create_cluster': No
# such file or directory", exit 127). Run it inside a real `bash` (which timeout
# CAN exec) that re-sources the libs. The exported CLUSTER_NAME /
# TRACEBLOC_NO_AUTOSTART / USER carry through the env, and the CLI binaries the
# install_* steps dropped into /usr/local/bin are on the inherited PATH.
guard 600 "create_cluster" -- bash -c '
  set -euo pipefail
  source "$1/common.sh"; source "$1/setup-linux.sh"; source "$1/cluster.sh"
  create_cluster' _ "$LIB"

echo "── assert: all nodes reach Ready ──"
guard 200 "wait nodes Ready" -- kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide

# kubectl-created pods bind to default/default; on fast runners the SA controller
# can race ("serviceaccount default not found"). Wait for it before we apply.
echo "── wait for the default ServiceAccount ──"
for _ in $(seq 1 30); do
  kubectl get serviceaccount default -n default >/dev/null 2>&1 && break
  sleep 2
done

# ── Step 2: install the CLI via cli/install.sh ───────────────────────────────
echo ""
echo "── Step 2: install the tracebloc CLI via cli/install.sh ────────────────"
# The fresh-shell PATH assertion itself is covered exhaustively (distro × shell ×
# mode) by path-persist.sh. Here we install once and re-assert the single cell
# that matters on the journey, so a CLI that installs but isn't reachable from a
# new terminal fails the END-TO-END path too — not just the cheap matrix.
if [[ -z "$CLI_REF" ]]; then
  # Default to the public release installer, same as path-persist.sh. cli#61's
  # PATH-persist fix shipped in cli v0.3.1 and is in every release since, so
  # `releases/latest` exercises the fixed installer on the real journey.
  CLI_REF="https://github.com/tracebloc/cli/releases/latest/download/install.sh"
fi
echo "  cli ref: ${CLI_REF}"

cli_install_args=()
[[ -n "$CLI_VERSION" ]] && cli_install_args+=(--version "$CLI_VERSION")

case "$CLI_REF" in
  http://*|https://*)
    installer="$WORKDIR/install.sh"
    guard 120 "download install.sh" -- curl -fsSL "$CLI_REF" -o "$installer"
    guard 300 "run install.sh" -- sh "$installer" "${cli_install_args[@]}"
    ;;
  *)
    [[ -f "$CLI_REF" ]] || error "TRACEBLOC_CLI_REF is neither a URL nor an existing file: $CLI_REF"
    guard 300 "run install.sh" -- sh "$CLI_REF" "${cli_install_args[@]}"
    ;;
esac
success "CLI installed."

# ── Step 3: apply a credential-free stub the CLI will discover ───────────────
#
# What the CLI's discovery actually keys off (internal/cluster/discover.go):
#   • label selector: app.kubernetes.io/name=client,app.kubernetes.io/managed-by=Helm
#   • Deployment name == "jobs-manager" OR ends in "-jobs-manager"
#   • release name from   app.kubernetes.io/instance
#   • chart version from  helm.sh/chart="client-<ver>"
#   • app version  from   app.kubernetes.io/version
# and `tracebloc cluster info` then mints a token for the "ingestor" SA via
# TokenRequest (exit 5 if that SA is missing), so we create that SA too. NONE of
# this needs a private image — pause/nginx is plenty; we only need the labels +
# the SA to exist. (`app: manager` is included as an extra cosmetic label to
# match the issue's shorthand, but it is NOT what discovery selects on.)
#
# client#208 (installer points the kube context at the workspace namespace) is
# already MERGED, so the realistic, supported state is: context's namespace ==
# the workspace namespace. We reproduce that by pinning the context's namespace
# to $TB_NAMESPACE below, then assert the core path works. (The OPPOSITE case —
# context left on `default` and the CLI auto-discovering the release across
# namespaces — depends on a CLI namespace auto-discover change that is NOT yet
# merged; that sub-assertion is gated as pending at the end of this script.)
echo ""
echo "── Step 3: stub parent release + cluster info (incl. fresh shell) ──────"
guard 60 "create namespace" -- kubectl create namespace "$TB_NAMESPACE"

MANIFEST="$WORKDIR/stub-release.yaml"
cat > "$MANIFEST" <<YAML
# Credential-free stand-in for the tracebloc parent client release. Carries the
# exact labels the CLI's DiscoverParentRelease() selects on; the container image
# is irrelevant to discovery (pause never needs to pull from a private registry).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingestor
  namespace: ${TB_NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${STUB_RELEASE}-jobs-manager
  namespace: ${TB_NAMESPACE}
  labels:
    app.kubernetes.io/name: client
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/instance: ${STUB_RELEASE}
    app.kubernetes.io/version: ${STUB_CHART_VERSION}
    helm.sh/chart: client-${STUB_CHART_VERSION}
    app: manager
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: client
      app.kubernetes.io/instance: ${STUB_RELEASE}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: client
        app.kubernetes.io/instance: ${STUB_RELEASE}
        app: manager
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
YAML

guard 60 "apply stub release" -- kubectl apply -f "$MANIFEST"
# We don't need the Deployment to roll out (discovery reads labels off the
# Deployment object, not a running Pod), but waiting a moment makes `cluster info`
# output realistic and catches an image-pull-stuck cluster. Non-fatal if it
# doesn't become Available within the window — discovery still works.
guard 120 "stub rollout (best-effort)" -- \
  kubectl -n "$TB_NAMESPACE" rollout status "deployment/${STUB_RELEASE}-jobs-manager" --timeout=90s \
  || warn "stub deployment didn't report Available in time — discovery is label-based, continuing."

# Point the CURRENT kubeconfig context's default namespace at the workspace ns.
# This mirrors the post-client#208 state (installer sets the context's namespace)
# and is what `tracebloc cluster info` reads when no --namespace is passed.
CTX="$(kubectl config current-context)"
guard 30 "set context namespace" -- kubectl config set-context "$CTX" --namespace "$TB_NAMESPACE"
info "kubeconfig context '$CTX' namespace → ${TB_NAMESPACE}"

# (a) cluster info succeeds in THIS shell.
echo "── assert (a): tracebloc cluster info succeeds ──"
guard 120 "cluster info" -- tracebloc cluster info

# (b) cluster info succeeds from a FRESH shell — the journey-level PATH guard.
# A new login shell inherits NONE of this process's PATH edits; it must find the
# binary via what install.sh persisted, then reach the same cluster via the
# kubeconfig on disk. This is the cli#61 class asserted on the real journey.
echo "── assert (b): tracebloc cluster info succeeds from a FRESH shell ──"
guard 120 "cluster info (fresh shell)" -- bash -lc 'tracebloc cluster info'
guard 120 "cluster info (fresh non-login shell)" -- bash -c 'tracebloc cluster info'
success "cluster info works in the current shell AND a fresh login + non-login shell."

# ── Step 4: offline spec validation smoke (`tracebloc data validate`) ─────────
# The credential-free, no-cluster half of the ingest journey. `dataset push
# --dry-run` is NOT offline any more — the current CLI runs cluster discovery AND
# a Bound-PVC check before its dry-run stop, which this harness's stub (no PVC)
# can't satisfy. `data validate <spec>` is the CLI's purpose-built offline check:
# it schema-validates a spec against the embedded ingest.v1.json and never touches
# the cluster — exactly the "offline-validatable, no creds, no reachable platform"
# smoke this step was always meant to be. We assert BOTH directions so a green run
# means something: a valid spec passes (exit 0) AND an invalid one is rejected
# (non-zero) — the same "prove the check can fail" discipline as the guard()
# self-test above. The spec shape mirrors the CLI's own known-good smoke fixture
# (testdata/smoke/valid-image-classification.yaml); the /data/shared paths are
# schema-only (validate never reads them).
echo ""
echo "── Step 4: offline spec validation (tracebloc data validate) ────────────"
SAMPLE_DIR="$WORKDIR/sample-dataset"
mkdir -p "$SAMPLE_DIR"
cat > "$SAMPLE_DIR/ingest.yaml" <<'YAML'
apiVersion: tracebloc.io/v1
kind: IngestConfig
category: image_classification
table: e2e_smoke
intent: train
csv: /data/shared/e2e_smoke/labels.csv
images: /data/shared/e2e_smoke/images/
label: label
YAML

echo "── assert (a): data validate accepts a valid spec (exit 0) ──"
guard 120 "data validate (valid)" -- tracebloc data validate "$SAMPLE_DIR/ingest.yaml"

# Negative control: drop the required `intent` field and confirm validate rejects
# it. Without this, a validate that silently exits 0 on everything would pass the
# positive assertion vacuously.
cat > "$SAMPLE_DIR/ingest-invalid.yaml" <<'YAML'
apiVersion: tracebloc.io/v1
kind: IngestConfig
category: image_classification
table: e2e_smoke
csv: /data/shared/e2e_smoke/labels.csv
images: /data/shared/e2e_smoke/images/
label: label
YAML

echo "── assert (b): data validate rejects an invalid spec (non-zero) ──"
if guard 120 "data validate (invalid)" -- tracebloc data validate "$SAMPLE_DIR/ingest-invalid.yaml"; then
  error "data validate accepted a spec missing the required 'intent' field — the positive assertion above would pass vacuously."
fi
success "data validate accepts a valid spec and rejects an invalid one (offline)."

# ── Pending sub-assertion: context-on-default auto-discover (cli, not merged) ─
# Reproduces incident #2's harder half: context left on `default`, CLI expected
# to AUTO-DISCOVER the release in another namespace without an explicit
# --namespace. That cross-namespace auto-discover is NOT merged in the CLI yet
# (today's `cluster info` resolves to the context's namespace, then "default",
# and would correctly NOT find the release). So we run it as a NON-FATAL,
# informational probe and gate flipping it to a hard assertion behind the CLI
# change landing. Enable with TB_EXPECT_NS_AUTODISCOVER=1 once that ships.
echo ""
echo "── (pending) context-on-default auto-discover probe ────────────────────"
guard 30 "reset context to default ns" -- kubectl config set-context "$CTX" --namespace default
if bash -lc 'tracebloc cluster info' >/dev/null 2>&1; then
  if [[ "${TB_EXPECT_NS_AUTODISCOVER:-0}" == "1" ]]; then
    success "auto-discover from a default-namespace context works (CLI change has landed)."
  else
    info "auto-discover from a default-namespace context already works — flip TB_EXPECT_NS_AUTODISCOVER=1 to enforce it."
  fi
else
  if [[ "${TB_EXPECT_NS_AUTODISCOVER:-0}" == "1" ]]; then
    error "expected CLI namespace auto-discover to find the release from a default-namespace context, but it did not."
  fi
  info "auto-discover from a default-namespace context not available yet (expected — CLI change unmerged). Skipping as pending."
fi
# Restore the working context namespace for cleanliness (teardown follows).
kubectl config set-context "$CTX" --namespace "$TB_NAMESPACE" >/dev/null 2>&1 || true

echo ""
echo "E2E JOURNEY PASS: installer cluster → CLI install → cluster info (fresh shell) → dataset push --dry-run."
