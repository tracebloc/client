#!/usr/bin/env bash
# =============================================================================
#  assess.sh — installer "stop-and-check" gate.
#
#  A re-run of the installer on a machine that is ALREADY set up should not drag
#  the user back through full provisioning. This module inspects the machine
#  READ-ONLY and classifies it, so main() can short-circuit a healthy box
#  straight to the `tracebloc` home screen (exit 0) instead of re-running every
#  step — while a fresh or half-set-up machine still runs the normal flow.
#
#  NON-MUTATING, with exactly ONE narrow exception named below. It must never
#  start the cluster, run helm, mint a credential, or write anything. Every
#  probe is read-only (`k3d cluster list`, `helm list`/`get values`,
#  `kubectl get`) and BOUNDED (short timeouts) so it can't hang, and it is
#  NEVER fatal.
#
#  THE EXCEPTION — one unprivileged, idempotent runtime nudge (#741). On macOS,
#  `runtime-down` may `open -a Docker` and wait up to 60s for the daemon. It is
#  carved out this narrowly on purpose, and the boundary is the point:
#
#    * unprivileged — a GUI app launch as the current user, no sudo, nothing a
#      reader could mistake for the privileged install path;
#    * idempotent — launching a running Docker Desktop is a no-op, so a re-run
#      cannot compound;
#    * bounded — a wall-clock deadline, and every liveness probe on that path
#      goes through `_docker_answers`, so a wedged daemon cannot hang assess;
#    * load-bearing — without it a stopped-but-installed Docker classifies
#      Tier 2 and demands an administrator password to start a runtime that is
#      already installed. Tier 0 was unreachable for exactly the machines it
#      was written for.
#
#  It does NOT lift the ban. `cluster-stopped` still only PRINTS — starting a
#  stopped k3d cluster is the mutation this header exists to forbid, and
#  `_assess_cluster_servers_running` explains why `_handle_existing_cluster` is
#  off-limits here. If you are adding a second exception, that is the moment to
#  question whether this file is still the right place for it. On ANY probe failure or uncertainty it
#  degrades toward "run the normal flow" — never toward a false "healthy". A
#  false healthy that skips a needed install is the worst possible outcome, so
#  "healthy" must be CERTAIN: cluster running AND a tracebloc release present AND
#  the core workload (jobs-manager) Ready AND the CLI present. Anything less is
#  degraded (partial) or fresh (nothing here yet), and both fall through.
#
#  Sets INSTALL_STATE (+ INSTALL_STATE_REASON, a short machine-readable tag of
#  what is off):
#    fresh    — no cluster, or a cluster with no tracebloc release.
#    healthy  — all four signals above true. The ONLY short-circuit.
#    degraded — a partial state (cluster stopped, workload not Ready, CLI
#               missing, or any other partial state).
#               A down container runtime is degraded/runtime-down: nothing below
#               it can be determined, so the machine must NOT be called fresh
#               (client#682).
#               cli-behind-latest is the ONE degraded reason where the
#               environment is fully healthy: it fires ONLY under an explicit
#               `tracebloc upgrade` (TB_UPGRADE_CLI) when the CLI is above the
#               floor but behind the latest release, so main() updates just the
#               CLI instead of handing off to a no-op (backend#2253).
# =============================================================================

# --force / --reinstall (or TRACEBLOC_FORCE_REINSTALL=1) bypasses the gate and
# runs the full flow. Defaulted here so the gate is safe to consult even if the
# arg scan never set it; main()'s arg parsing flips it to 1 on the flag.
: "${TB_FORCE_REINSTALL:=${TRACEBLOC_FORCE_REINSTALL:-0}}"

# Bound on the readiness probe's API call — short so a stopped/unreachable API
# can never make the gate hang. Overridable for tests.
: "${TB_ASSESS_KUBECTL_TIMEOUT:=5s}"

# Bound on the container-runtime reachability probe (seconds). `docker info`
# against a WEDGED daemon hangs forever, and this runs on every re-run.
: "${TB_ASSESS_DOCKER_TIMEOUT:=10}"

# Where the healthy-machine hand-off points the interactive home screen (see
# _assess_handoff). Mirrors provision.sh's TB_TTY so tests can redirect it to a
# real file instead of the controlling terminal.
: "${TB_TTY:=/dev/tty}"

# _assess_cluster_servers_running — echo the number of running servers for
# CLUSTER_NAME. This mirrors ONLY the read half of cluster.sh's
# _handle_existing_cluster; that function is off-limits here because it MUTATES
# (it starts a stopped cluster and runs drift checks). Single jq-free path — jq
# is NOT a guaranteed installer prerequisite (same rule as common.sh /
# install-client-helm.sh, Bugbot #284): read the k3d table's SERVERS column
# ("running/total") for an EXACT name match with awk. Echoes an integer; 0 on any
# error / when the cluster is absent.
_assess_cluster_servers_running() {
  local running="0" line
  # `|| line=""`: awk's `exit` closes the pipe, so under `set -o pipefail` a
  # SIGPIPE from k3d (141) — or any k3d failure — would otherwise propagate
  # non-zero out of the assignment and abort the installer under `set -e`.
  line="$(k3d cluster list --no-headers 2>/dev/null | awk -v n="$CLUSTER_NAME" '$1 == n { print $2; exit }')" \
    || line=""
  [[ -n "$line" ]] && running="${line%%/*}"
  [[ "$running" =~ ^[0-9]+$ ]] || running="0"
  printf '%s' "$running"
}

# _assess_workload_ready NS — are ALL the client's core workloads Ready in
# namespace NS? "Ready" MUST match the installer's OWN definition, so this
# iterates the SAME deployment set as wait_for_client_ready (summary.sh) via the
# shared _client_workload_deployments — mysql-client + jobs-manager +
# requests-proxy. A machine with jobs-manager up but requests-proxy (training
# egress) or mysql-client down is NOT healthy, and must reconcile rather than be
# told "already set up". Read-only + bounded via kubectl --request-timeout, so a
# stopped/unreachable API returns quickly instead of hanging. A Deployment is
# Ready when it reports >=1 readyReplicas; ANY one missing / erroring / zero =>
# not ready (return 1), which degrades toward the normal flow.
_assess_workload_ready() {
  local ns="$1" d ready
  [[ -n "$ns" ]] || return 1
  has kubectl || return 1
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    ready="$(kubectl get deployment "$d" -n "$ns" \
               --request-timeout="$TB_ASSESS_KUBECTL_TIMEOUT" \
               -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || return 1
    [[ "$ready" =~ ^[0-9]+$ ]] && [[ "$ready" -ge 1 ]] || return 1
  done < <(_client_workload_deployments "$ns")
  return 0
}

# _assess_runtime_down — is the container runtime installed but UNREACHABLE right
# now? (client#682) True only for the case with a one-sentence remedy: Docker is
# there, the daemon is not answering. Deliberately narrow —
#   • no docker binary at all  -> NOT down. That is a genuinely fresh machine and
#     the normal first-time flow is the right answer.
#   • docker answers           -> NOT down.
#   • docker present, refuses  -> down ONLY when the refusal is a connection
#     failure. "permission denied" (a Linux user outside the docker group) is a
#     different problem with a different fix, and belongs to the normal flow.
#   • docker present, wedged   -> down. A daemon that will not answer inside the
#     bound is not usable, and "start Docker" is still the right first move.
# Read-only and bounded, per the gate's never-hang contract.
_assess_runtime_down() {
  has docker || return 1
  local _out _rc=0
  # stderr only: the reason lives there, and dropping stdout keeps a healthy
  # `docker info` (hundreds of lines) out of memory. The assignment is the left
  # side of `&&`, so a non-zero docker cannot trip `set -e` here.
  _out="$(_bounded "$TB_ASSESS_DOCKER_TIMEOUT" docker info 2>&1 >/dev/null)" && return 1
  _rc=$?
  # 124 = the bound fired (timeout/gtimeout): a wedged daemon, treated as down.
  [[ "$_rc" -eq 124 ]] && return 0
  # Permission denied is checked FIRST and wins (Bugbot). The real Linux message
  # carries BOTH the permission wording AND a `dial unix …` clause:
  #   permission denied while trying to connect to the Docker daemon socket at
  #   unix:///var/run/docker.sock: Get "http://…/info": dial unix
  #   /var/run/docker.sock: connect: permission denied
  # so matching the connection phrases alone would classify a docker-group
  # problem as a down daemon — the exact confusion this function exists to
  # prevent. A negative match before the positive one is the only ordering that
  # survives an error string containing both.
  if grep -qiE 'permission denied' <<<"$_out"; then
    return 1
  fi
  # Herestring, not a pipe: `grep -q` exits on first match and a pipe's writer
  # would then take SIGPIPE, which `set -o pipefail` turns into a 141 the caller
  # never asked for (the same hazard _assess_cluster_servers_running guards).
  grep -qiE 'cannot connect to the docker daemon|is the docker daemon running|docker daemon is not running|dial unix|the system cannot find the file specified|open //./pipe/docker_engine' <<<"$_out"
}

# _assess_cli_bin — the tracebloc CLI to interrogate, or non-zero when there is
# none. Counts a binary in ~/.local/bin (where the CLI installer drops it when
# /usr/local/bin isn't writable) even if THIS shell's PATH predates that dir —
# the same place provision.sh / install-cli.sh resolve it.
_assess_cli_bin() {
  has tracebloc && { printf 'tracebloc'; return 0; }
  if [[ -x "${HOME}/.local/bin/tracebloc" ]]; then
    printf '%s' "${HOME}/.local/bin/tracebloc"
    return 0
  fi
  return 1
}

# _assess_cli_present — is the tracebloc CLI available at all?
_assess_cli_present() {
  _assess_cli_bin >/dev/null
}

# _version_lt moved to common.sh (backend#2422): cluster.sh needs it to gate a
# kubelet flag on the k3s pin, and assess.sh is sourced CONDITIONALLY by
# install-k8s.sh (`[[ -f ]]`, for stale checkouts) while common.sh is not. A
# second copy here would be the restated-rule defect, so there is exactly one.
# assess.sh's callers get it because install-k8s.sh sources common.sh first and
# the bats helper's `load_lib` chains common.sh.

# _assess_cli_outdated — is the installed CLI below the floor the installer will
# actively repair? (client#707)
#
# The floor is 0.10.0 because that is the release where the CLI gained its own
# update nudge. At or above it a user can keep themselves current; below it
# NOTHING on the machine can tell them they are behind — the cluster auto-
# upgrades hourly around a host binary that never moves. A field machine sat on
# v0.5.1 for five weeks that way.
#
# It is a FLOOR, not a "must be latest": the installer repairs users up to the
# point where the CLI maintains itself, and then stops caring. That keeps this
# free (no network call on every run) and means the constant never needs raising.
: "${TB_CLI_MIN_VERSION:=0.10.0}"

_assess_cli_outdated() {
  local bin ver
  bin="$(_assess_cli_bin)" || return 1     # absent — cli-missing already covers it
  # No pipe: `tracebloc version | head -1` would let head close the pipe first,
  # and pipefail turns that into a 141 the caller never asked for (backend#1778).
  ver="$("$bin" version 2>/dev/null || true)"
  ver="${ver%%$'\n'*}"                     # first line
  ver="${ver#* }"; ver="${ver%% *}"        # "tracebloc 0.10.5 (darwin/arm64)" -> "0.10.5"
  ver="${ver#v}"
  # FAIL OPEN on anything unparseable. A version we cannot read is not evidence
  # of staleness, and treating it as outdated would reinstall the CLI on every
  # single run — worse than the staleness this exists to fix.
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  _version_lt "$ver" "$TB_CLI_MIN_VERSION"
}

# _assess_cli_behind_latest — for an EXPLICIT `tracebloc upgrade` only, is the
# installed CLI behind the LATEST release (as opposed to below the mandatory-
# reinstall floor)? This is the gap backend#2253 closed: the floor above stops at
# 0.10.0, but the CLI's own update nudge fires against latest, so a CLI at e.g.
# 0.10.5 with latest 0.10.8 was nagged on every command while `tracebloc upgrade`
# — which re-runs this installer — found the machine "healthy" and changed
# nothing. The nag named a command that could not carry it out.
#
# GATED on TB_UPGRADE_CLI so it is INERT on every ordinary installer run. That
# matters twice over: it keeps this classifier free (no "what is latest?" lookup
# on a normal run — the property _assess_cli_outdated's floor was chosen to
# preserve), and it means a routine re-run is never reclassified by it. The
# comparison itself does NO network: `tracebloc upgrade` already resolved latest
# and passed it as TB_CLI_LATEST, so this is a pure version compare.
#
# Fail SAFE toward updating: under an explicit upgrade an unknown/unparseable
# latest (a copy-pasted manual retry carries the flag but not the version) or an
# unreadable installed version means "we cannot prove you are current" -> update,
# which is exactly what the user asked for. Only a latest we can read AND that the
# installed CLI already meets returns "not behind".
_assess_cli_behind_latest() {
  [[ "${TB_UPGRADE_CLI:-0}" == 1 ]] || return 1
  local bin ver latest
  bin="$(_assess_cli_bin)" || return 1     # absent — cli-missing already covers it
  ver="$("$bin" version 2>/dev/null || true)"
  ver="${ver%%$'\n'*}"                     # first line
  ver="${ver#* }"; ver="${ver%% *}"        # "tracebloc 0.10.5 (darwin/arm64)" -> "0.10.5"
  ver="${ver#v}"
  latest="${TB_CLI_LATEST:-}"; latest="${latest#v}"
  # Can't prove current (missing/unparseable latest, or unreadable version) -> update.
  [[ "$latest" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
  [[ "$ver"    =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
  _version_lt "$ver" "$latest"
}

# _assess_release_pending NS — true when a release in NS is wedged (pending-* or
# uninstalling: a killed helm op, #554). Names both states so it doesn't depend on
# the pinned helm's default listing. `helm list -q` is jq-free; bounded per the
# installer's never-hang contract.
_assess_release_pending() {
  local _ns="$1" _out _rc=0
  [[ -n "$_ns" ]] || return 1
  _out="$(_bounded 15 helm list -n "$_ns" --pending --uninstalling -q 2>/dev/null)" || _rc=$?
  # A failed/timed-out probe is uncertainty, not "no wedge" — degrade rather than
  # let the caller fast-path to healthy (this module never fails open to healthy).
  [[ "$_rc" -ne 0 ]] && return 0
  [[ -n "$_out" ]]
}

# _assess_classify — set INSTALL_STATE (+ INSTALL_STATE_REASON). Pure read-only
# detection; no mutation, never fatal.
_assess_classify() {
  INSTALL_STATE="fresh"
  INSTALL_STATE_REASON="no-cluster"

  # Is the container runtime even reachable? This MUST come before the cluster
  # probe (client#682). `_cluster_exists` is a boolean whose three probes all
  # swallow stderr and return 1, so a down daemon is indistinguishable from an
  # empty machine — and a laptop that merely needs Docker started was told it had
  # nothing installed and offered a full first-time install. install-k8s.ps1 has
  # carried the tri-state version of this contract since #557; bash never did.
  # DEGRADED, not blocked: the normal flow already knows how to start a stopped
  # runtime (install_docker_desktop launches Docker Desktop and waits;
  # install_docker_engine brings up the Linux service), and create_cluster then
  # reconciles the existing cluster. Stopping here would trade one bad outcome
  # for another — it would take away a step that works today. The bug is the
  # CLAIM, not the flow: "first time on this machine" over a machine whose
  # environment we simply could not see.
  if _assess_runtime_down; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="runtime-down"
    return 0
  fi

  # No engine or no cluster => first-time setup. (has k3d short-circuits before
  # _cluster_exists so a machine without k3d doesn't shell out at all.)
  if ! has k3d || ! _cluster_exists; then
    INSTALL_STATE="fresh"; INSTALL_STATE_REASON="no-cluster"
    return 0
  fi

  # A cluster exists — but is it RUNNING? Check this via the cheap read-only k3d
  # probe BEFORE any Helm call. detect_installed_client below runs `helm list -A`
  # / `helm get values`, which are UNBOUNDED and talk to the k8s API — on a
  # stopped cluster (after a reboot or a manual stop) that API is down, so Helm
  # would hang for a long time (breaking the gate's "bounded, never-hang"
  # contract) and, when it finally failed, mislabel the machine as
  # `fresh`/`cluster-no-release`. Probing servers first keeps Helm off a dead API
  # and makes `cluster-stopped` actually reachable on real re-runs.
  local servers; servers="$(_assess_cluster_servers_running)"
  if [[ "$servers" -lt 1 ]]; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cluster-stopped"
    return 0
  fi

  # Cluster is running (live API). Is a tracebloc release installed on it? Reuse
  # the shared jq-free probe (sets INSTALLED_CLIENT_NS) so this can never disagree
  # with the Helm-step / #303 ownership guards on "what runs here". A running
  # cluster with no release is still a first-time client setup.
  local ns=""
  if declare -F detect_installed_client >/dev/null 2>&1; then
    detect_installed_client
    ns="$INSTALLED_CLIENT_NS"
  fi
  if [[ -z "$ns" ]]; then
    INSTALL_STATE="fresh"; INSTALL_STATE_REASON="cluster-no-release"
    return 0
  fi

  # A pending-* wedge (killed helm op, #554) usually keeps its prior revision Ready,
  # so it would fast-path to healthy and skip recovery. Degrade so the normal flow
  # runs and _recover_pending_helm_release clears it.
  if _assess_release_pending "$ns"; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="pending-wedge"
    return 0
  fi

  # Cluster running + release present -> healthy or degraded. Require CERTAINTY on
  # every remaining signal for "healthy"; anything less degrades to the normal
  # flow, which reconciles the specific layer that is off. The readiness probe
  # talks to a live API (and is bounded regardless). ANY of the client's core
  # workloads not Ready => degraded.
  if ! _assess_workload_ready "$ns"; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="workload-not-ready"
    return 0
  fi

  # Env is up and Ready, but the CLI is missing => degraded (the normal flow
  # reinstalls the CLI).
  if ! _assess_cli_present; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cli-missing"
    return 0
  fi

  # Present, but too old to keep itself current (client#707). Without this the
  # healthy fast-path pins a user to whatever CLI they first installed, forever
  # and silently — the ONE thing on the machine that no auto-upgrade reaches.
  if _assess_cli_outdated; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cli-outdated"
    return 0
  fi

  # Above the floor, but an explicit `tracebloc upgrade` and behind the latest
  # release (backend#2253). A DISTINCT reason from cli-outdated so main() updates
  # ONLY the CLI — a small, isolated download — instead of either doing nothing
  # (the old healthy no-op) or dragging a healthy box through a full reinstall.
  # Ordered AFTER the floor check so a below-floor CLI stays cli-outdated (a
  # mandatory full reinstall), and inert on ordinary runs because
  # _assess_cli_behind_latest gates itself on TB_UPGRADE_CLI.
  if _assess_cli_behind_latest; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cli-behind-latest"
    return 0
  fi

  INSTALL_STATE="healthy"; INSTALL_STATE_REASON="ns:${ns}"
  return 0
}

# _assess_handoff — hand a healthy machine to the tracebloc home screen, then
# exit 0. We deliberately do NOT `exec` so the EXIT trap (install_cleanup) still
# runs its cleanup. The CLI may live in ~/.local/bin and not yet be on this
# shell's PATH, so put that dir on PATH first (mirrors provision.sh). If
# `tracebloc` is somehow still unresolvable, fall back to a short status line so
# a healthy re-run always ends cleanly at exit 0.
_assess_handoff() {
  # This exits 0 having run no install step, so the outcome event must say
  # `skipped`, not `succeeded` (backend#1907) — otherwise the success count
  # grows with every re-run on a machine nothing happened to, and the failure
  # rate quietly falls for a reason that has nothing to do with installs.
  if declare -F telemetry_run_skipped >/dev/null 2>&1; then
    telemetry_run_skipped
  fi
  success "Already set up on this machine — no need to run the installer again."
  export PATH="${HOME}/.local/bin:${PATH}"
  if has tracebloc; then
    echo ""
    # Bare invocation -> the home screen; the user lands on their status. Give it
    # the user's REAL terminal on ALL THREE streams. Unlike install.sh's bootstrap
    # hand-off (which runs BEFORE any redirect), main() has already called
    # setup_log_file — `exec > >(tee …) 2>&1` — so this shell's stdout/stderr are a
    # pipe to `tee`, and its stdin is the install pipe under `curl … | bash`. An
    # interactive TUI needs a tty on stdout/stderr too, not just stdin: point all
    # three at the terminal ($TB_TTY, /dev/tty) when it's openable (bypassing tee
    # for the interactive screen, exactly as the bootstrap does), else fall back to
    # </dev/null and leave stdout/stderr on the tee pipe (non-interactive / CI —
    # never the input pipe). Deliberately NO `exec` (see above) so the EXIT trap
    # still runs. `|| true` keeps a non-zero render from flipping our exit code — a
    # healthy machine exits 0.
    if { : <"$TB_TTY"; } 2>/dev/null; then
      tracebloc <"$TB_TTY" >"$TB_TTY" 2>"$TB_TTY" || true
    else
      tracebloc </dev/null || true
    fi
    exit 0
  fi
  info "Open the tracebloc home screen any time with:  tracebloc"
  exit 0
}

# assess_existing_install — the gate. Called from main() after print_banner and
# before the roadmap / Step 1. READ-ONLY, never fatal. On a healthy machine it
# short-circuits (hand-off + exit 0). On fresh / degraded it prints a warm
# one-liner and RETURNS 0 so main() runs the normal flow to set up (fresh) or
# reconcile (degraded).
# _assess_handle_runtime_down — the runtime is installed but not answering.
#
# This used to be one info() line: "Docker isn't running yet — starting it, then
# checking your environment." Nothing in that path started anything. The branch
# printed the sentence and fell through to `return 0`, the probe then found no
# usable runtime, and macOS classified Tier 2 — the admin-password path — for a
# machine whose Docker only needed launching. The only `open -a Docker` in the
# tree sat behind that password prompt, so the installer could not start Docker
# without first taking a password it needed solely because Docker was stopped.
#
# A message that names an action the code does not take is worse than no
# message: it is what the user quotes back when the install fails, and it sends
# the reader looking for a bug in the start logic rather than at its absence.
# So this either DOES the thing or does not claim it.
_assess_handle_runtime_down() {
  # macOS with Docker Desktop actually installed: a GUI app launch, no
  # privileges. If it comes up, the probe that runs next sees a live runtime and
  # hands this machine to Tier 0.
  #
  # The _docker_app_installed test is part of the CONDITION, not just of the
  # nudge. Announcing "starting it" and then discovering there is no app to
  # start reproduces this function's own bug one level down — and the failure
  # copy would go on to say "Open Docker Desktop" to someone who does not have
  # it, e.g. a Colima-only headless Mac (Bugbot, #741).
  if [[ "${OS:-}" == "Darwin" ]] \
     && declare -F _try_start_docker_desktop >/dev/null 2>&1 \
     && declare -F _docker_app_installed >/dev/null 2>&1 \
     && _docker_app_installed; then
    info "Docker isn't running yet — starting it, then checking your environment."
    if _try_start_docker_desktop; then
      success "Docker is running"
      log "runtime-down: Docker came up; the probe will classify from a live runtime"
      return 0
    fi
    # Honest about the failure, and specific about what it costs: without a
    # running Docker this machine takes the privileged path.
    warn "Couldn't start Docker automatically."
    hint "Open Docker Desktop, wait until it reports \"running\", then re-run this installer."
    hint "Continuing — but setting up a container runtime from here needs an administrator password."
    log "runtime-down: could not start Docker; falling through to the privileged path"
    return 0
  fi

  # Everywhere else — a Mac with no Docker Desktop to launch, or a platform
  # where starting the daemon needs privileges we will not ask for here. Do not
  # claim to be starting anything.
  #
  # And say what happens NEXT. "Start it, then re-run" on its own reads as "this
  # run is over", while the installer is in fact about to carry on into the
  # privileged flow — guidance contradicting the very next thing on screen. The
  # macOS failure branch above names its continue; so does this one.
  info "Docker isn't running, and this installer can't start it for you."
  hint "Start your container runtime, then re-run this installer for the shortest path."
  hint "Continuing — but setting one up from here needs an administrator password."
  log "runtime-down: OS=${OS:-?}, no unprivileged way to start the runtime; continuing"
  return 0
}

assess_existing_install() {
  # --force / --reinstall (or the env override): skip the gate entirely.
  if [[ "${TB_FORCE_REINSTALL:-0}" == 1 ]]; then
    log "assess: --force/--reinstall set — bypassing the stop-and-check gate."
    return 0
  fi

  _assess_classify
  log "assess: INSTALL_STATE=${INSTALL_STATE} reason=${INSTALL_STATE_REASON:-}"

  # backend#2253: an explicit `tracebloc upgrade` on a box that is healthy on
  # every axis EXCEPT that its CLI is behind latest. Do NOT hand off (that no-op
  # is the bug) and do NOT run the degraded ceremony below — RETURN so main()
  # updates just the CLI. Kept out of the case switch on purpose: this file stays
  # a read-only classifier, and the CLI-install mutation lives in main() (next to
  # create_cluster / install_client_helm), not behind assess.sh's non-mutating
  # contract.
  if [[ "$INSTALL_STATE" == "degraded" && "${INSTALL_STATE_REASON:-}" == "cli-behind-latest" ]]; then
    return 0
  fi

  case "$INSTALL_STATE" in
    healthy)
      echo ""
      # A healthy cluster can still be running a DRIFTED k3s (born unpinned, on an
      # older installer, or with K8S_VERSION=latest) — the #547 STEADY STATE. This
      # fast-path hands off and exits before _handle_existing_cluster, so its
      # reuse-path drift check never runs; surface the warning here too so a
      # healthy-but-drifted client still sees the recreate guidance (Bugbot #565).
      declare -F _check_existing_cluster_k8s_version >/dev/null 2>&1 && _check_existing_cluster_k8s_version
      # Same rationale for GPU (client#835): this fast path exits before the
      # create/reuse GPU reconcile, so a cluster that requests a GPU its node can't
      # schedule (a pre-#835 install on a stock node) would strand every GPU job
      # Pending with no signal. Surface the recreate guidance here too.
      declare -F _check_healthy_cluster_gpu_consistent >/dev/null 2>&1 && _check_healthy_cluster_gpu_consistent
      _assess_handoff        # prints the "already set up" line, runs `tracebloc`, exit 0
      ;;
    degraded)
      echo ""
      case "$INSTALL_STATE_REASON" in
        runtime-down)       _assess_handle_runtime_down ;;
        cluster-stopped)    info "Your secure environment is stopped — starting it and finishing setup." ;;
        workload-not-ready) info "Your secure environment is still starting up — finishing setup." ;;
        cli-missing)        info "The tracebloc CLI isn't installed yet — setting it up." ;;
        cli-outdated)       info "Your tracebloc CLI is out of date — updating it." ;;
        pending-wedge)      info "A previous update was interrupted — recovering it and finishing setup." ;;
        *)                  info "Your secure environment is only partly set up — finishing setup." ;;
      esac
      echo ""
      return 0               # fall through to the normal flow to reconcile
      ;;
    fresh|*)
      # Only the truly-empty machine gets a first-time header; a cluster that
      # merely lacks a release proceeds without ceremony.
      if [[ "$INSTALL_STATE_REASON" == "no-cluster" ]]; then
        info "Setting up your secure environment on this machine for the first time."
        echo ""
      fi
      return 0               # today's normal flow
      ;;
  esac
}
