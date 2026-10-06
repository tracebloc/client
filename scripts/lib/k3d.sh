#!/usr/bin/env bash
# =============================================================================
#  k3d.sh — the k3d substrate: cluster presence, create and start, the
#  existing-cluster checks, the GPU node image, node-address pinning, the
#  kubeconfig merge and the API wait. Sourced directly after cluster.sh, whose
#  substrate-neutral helpers it calls. Stage 4 deletes it per OS (RFC-0175 D15).
# =============================================================================

# Exact cluster name match (avoids "tracebloc" matching "tracebloc2").
# Uses multiple detection methods so re-runs work on all distros (e.g. SUSE where
# jq may be missing or k3d list output format differs).
# Every probe below CAPTURES its own k3d listing and matches the captured value
# (#680's transform). Piping k3d straight into `awk … {exit}` / `grep -q` makes
# the consumer close the pipe on the FIRST matching line — which for our own
# cluster is usually line one — so k3d takes SIGPIPE, `set -o pipefail` turns the
# pipeline into 141, and inside these `if`s that reads as "no such cluster".
# That is a SECOND, independent route to the client#682 misclassification: the
# gate calls the machine fresh and offers a first-time install over a cluster
# that is present and running.
#
# Each capture sits INSIDE the probe that reads it, so a probe that never runs
# never shells out — the k3d call count is exactly what it was before this fix,
# and the common re-run (jq present, cluster found by probe 1) still costs one
# call. (Asad: an eager capture at the top made that path cost two.)
#
# EVERY probe here is BOUNDED (client#974, the bash twin of client#930). Each one
# already carried `2>/dev/null || true`, which handles k3d FAILING — and a WEDGED
# Docker daemon does not fail `k3d cluster list`, it BLOCKS, so that `|| true` was
# never reached. These probes sit on the MAIN install path, so the pre-fix shape
# parked a headless install right here with no output and nothing to kill it:
# exactly #930's shape, on the platform most internal installs use. Same
# distinction _docker_answers' header draws for a bare `docker info` (#741/#744):
# stopped fails, wedged hangs.
#
# BOUNDING A CALL CHANGES ITS TYPE, and this is where that bites (Bugbot High on
# client#984). Before the bound there were two outcomes — present, absent. After
# it there are THREE — present, absent, COULDN'T TELL — and the first cut of this
# fix collapsed the third into "absent". That is materially worse than the hang it
# replaced: `create_cluster` would then run `guard_leftover_data`, which PROMPTS
# about deleting an existing install's data, and `_create_new_cluster`, against a
# cluster that may still be running; and assess's gate would label the machine
# `fresh` and offer a first-time install over it. That is client#682's
# misclassification, which the header above was written about, and it is the same
# question LukasWodka blocked the PowerShell twin (#973) on: what does the main
# install path DO when the deadline fires?
#
# So the primitive is TRI-STATE, with the contract _k3d_cluster_running
# (gpu-nvidia.sh) already established in this codebase for the same reason —
# "a probe TIMEOUT isn't mistaken for 'not running'":
#   0 = PRESENT     (a probe answered and matched CLUSTER_NAME)
#   1 = ABSENT      (a probe answered and did not match)
#   2 = UNKNOWN     (every probe's READ failed — timed out, or k3d itself broke)
# Callers must decide what UNKNOWN means for THEM; nothing here decides for them.
#
# THREE PROBES OF ONE QUESTION would have made a per-probe deadline TRIPLE the
# worst case, so the chain is tightened in the same breath:
#   * probe 3's looser matcher runs against the text probe 2 ALREADY captured. It
#     tolerates a different table LAYOUT, not a different daemon, so it never
#     needed its own engine round-trip.
#   * probe 3 spends a real second read only when probe 2's read ERRORED — an
#     older k3d that does not know --no-headers — and never when it TIMED OUT
#     (124): the same wedged daemon cannot answer a retry, it can only eat another
#     deadline. A timeout ends the chain with a log line naming itself, which is
#     the finding support needs (the Windows twin keeps the same line).
# Worst case: 2 bounded reads with jq present, 1 without. Before: unbounded.
#
# macOS: these probes go through `_bounded`, which has held its deadline on a stock
# Mac (no timeout/gtimeout) since client-dev#1357 gave it a background-PID fallback
# (common.sh _tb_bounded_bg). Before that it ran the bare command there and a wedged
# daemon hung this function; the tri-state above is what made that degrade to
# UNKNOWN instead of misclassifying, and it still decides what a fired deadline means.
_cluster_presence() {
  local _read_ok=0            # did ANY probe's read actually answer?
  # 1) JSON output (exact name match) when jq is available
  if command -v jq &>/dev/null; then
    local _json _rc=0
    # `|| _rc=$?` (not a bare `; _rc=$?`) so a non-zero probe under the installer's
    # `set -e` captures the code instead of aborting (the #431 Bugbot form).
    _json="$(_bounded "${TB_K3D_LIST_TIMEOUT:-15}" k3d cluster list -o json 2>/dev/null)" || _rc=$?
    if [[ "$_rc" -eq 0 ]]; then
      # A READ THAT SUCCEEDED AND PARSES IS AUTHORITATIVE — BOTH WAYS, and it
      # RETURNS. Falling through on "parsed fine, no match" let probe 2's TIMEOUT
      # overwrite a definite ABSENT we already held, so a first-time install with
      # jq present reported UNKNOWN, took the reuse branch, and tried to START a
      # cluster the listing had just proved absent instead of creating one
      # (Bugbot High, client#984 round 2).
      #
      # The general rule this is an instance of: a definite answer from a read that
      # COMPLETED always wins over "couldn't tell" from a read that did not. Only
      # an UNPARSEABLE payload is inconclusive and falls through — which is the
      # reason the table probes exist at all (SUSE-era k3d whose JSON shape or
      # jq availability differed), and `jq -e` alone cannot tell "no match" from
      # "not JSON": both are non-zero. So the shape is checked first.
      if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$_json"; then
        if jq -e --arg n "$CLUSTER_NAME" '(.[] | select(.name == $n)) != null' >/dev/null 2>&1 <<<"$_json"; then
          return 0
        fi
        return 1
      fi
      # Parsed as something other than an array (or not at all): inconclusive, not
      # empty. Fall through to the table probes rather than call the cluster absent.
      #
      # AND IT DOES NOT SET `_read_ok` (Bugbot Medium, client#984 round 5). It used
      # to, which quietly re-armed the very collapse the final `(( _read_ok ))`
      # exists to prevent: this payload is INCONCLUSIVE — that is the whole reason
      # we fall through — so with both table reads then failing for a non-timeout
      # reason (k3d 127, a permission error), the function reached that test
      # holding a 1 it had not earned and returned ABSENT. Callers then ran
      # guard_leftover_data — which prompts, with delete among the options — and
      # _create_new_cluster, against a machine whose listing never once parsed.
      # `_read_ok` means "a read answered THE QUESTION", not "the engine emitted
      # bytes".
      log "k3d answered the JSON cluster listing with a payload that is not an array; falling back to the table listing."
    elif [[ "$_rc" -eq 124 ]]; then
      log "The k3d cluster listing (JSON form) timed out after ${TB_K3D_LIST_TIMEOUT:-15}s (is the Docker daemon responding?)."
      # A wedged engine cannot answer the table probes either, and each would cost
      # another full deadline. Report UNKNOWN now and let the caller decide.
      return 2
    fi
  fi
  # 2) Table format: first column is cluster name (--no-headers)
  local _list _lrc=0
  _list="$(_bounded "${TB_K3D_LIST_TIMEOUT:-15}" k3d cluster list --no-headers 2>/dev/null)" || _lrc=$?
  if [[ "$_lrc" -eq 124 ]]; then
    log "The k3d cluster listing (table form) timed out after ${TB_K3D_LIST_TIMEOUT:-15}s (is the Docker daemon responding?)."
    return 2
  fi
  # 3) A READ error (not an empty answer) is the one case worth a second engine
  #    round-trip: `--no-headers` is unsupported on some older k3d builds, and the
  #    header-ful listing still answers the question.
  if [[ "$_lrc" -ne 0 ]]; then
    local _trc=0
    _list="$(_bounded "${TB_K3D_LIST_TIMEOUT:-15}" k3d cluster list 2>/dev/null)" || _trc=$?
    if [[ "$_trc" -eq 124 ]]; then
      log "The k3d cluster listing (header-ful fallback) timed out after ${TB_K3D_LIST_TIMEOUT:-15}s (is the Docker daemon responding?)."
      return 2
    fi
    if [[ "$_trc" -eq 0 ]]; then _read_ok=1; else _list=""; fi
  else
    _read_ok=1
  fi
  if awk -v n="$CLUSTER_NAME" '$1 == n { exit 0 } END { exit 1 }' <<<"$_list"; then
    return 0
  fi
  # Layout-tolerant fallback matcher: any line whose first column equals
  # CLUSTER_NAME (handles a header row / varying table layout). Runs on the text
  # already in hand — no extra call.
  if grep -qE "^[[:space:]]*${CLUSTER_NAME}[[:space:]]" <<<"$_list"; then
    return 0
  fi
  # NOT MATCHED is only ABSENT if something actually READ. Every probe failing for
  # a non-timeout reason (no k3d on PATH, a permission error, a k3d that dies on
  # every invocation) is still "couldn't tell", and must not be reported as an
  # empty cluster list — that is the same collapse as the timeout, arriving
  # through a different door.
  (( _read_ok )) || {
    log "No k3d cluster listing could be read; cluster presence indeterminate."
    return 2
  }
  return 1
}

# _k3d_live_clusters -- for native k3s's D10 refusal (k3s.sh): the name of every k3d
# cluster on this machine, one per line, and 0; 1 when k3d is not installed or lists
# none; 2 when k3d is installed but its listing did not answer within
# TB_K3D_LIST_TIMEOUT (Docker wedged or not up yet); 3 when the listing FAILED fast,
# with k3d's last stderr line on stdout (a permission error on the Docker socket, a
# daemon that is down, a k3d that dies on every call). 2 and 3 are both "cannot
# tell", never "none": the caller refuses on either, but only 2 is "start Docker" --
# telling a user with a permission error to start a running daemon sends them the
# wrong way (client-dev#1606).
#
# A fast failure of `--no-headers` is retried once without it, as _cluster_presence
# does: some older k3d builds reject the flag, and the header-ful listing still
# answers. A timeout is not retried -- a wedged engine would cost a second deadline.
_k3d_live_clusters() {
  has k3d || return 1
  local list rc=0 errf msg
  errf="$(mktemp "${TMPDIR:-/tmp}/tracebloc-k3d-list-XXXXXX" 2>/dev/null)" || errf=/dev/null
  list="$(_bounded "${TB_K3D_LIST_TIMEOUT:-15}" k3d cluster list --no-headers 2>"$errf")" || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 124 ]]; then
    rc=0
    list="$(_bounded "${TB_K3D_LIST_TIMEOUT:-15}" k3d cluster list 2>"$errf")" || rc=$?
    # The header-ful table's first row is its column header, not a cluster.
    [[ "$rc" -ne 0 ]] || list="$(awk 'NR == 1 && $1 == "NAME" { next } { print }' <<<"$list")"
  fi
  if [[ "$rc" -ne 0 ]]; then
    msg=""
    [[ "$rc" -eq 124 || "$errf" == /dev/null ]] || msg="$(awk 'NF { l = $0 } END { print l }' "$errf" 2>/dev/null)"
    [[ "$errf" == /dev/null ]] || rm -f "$errf"
    [[ "$rc" -ne 124 ]] || return 2
    printf '%s\n' "${msg:-k3d cluster list exited ${rc} with no message}"
    return 3
  fi
  [[ "$errf" == /dev/null ]] || rm -f "$errf"
  list="$(awk 'NF { print $1 }' <<<"$list")"
  [[ -n "$list" ]] || return 1
  printf '%s\n' "$list"
}

# NO `_cluster_exists` BOOLEAN. There was one, and re-adding it is how this bug
# comes back: a boolean has two values and this question has three, so every
# caller that takes `if _cluster_exists` inherits somebody else's answer to "what
# does an unreadable engine mean here?" — and `! _cluster_exists` silently spells
# that answer "absent", which is the client#984 defect exactly. The two decision
# sites (create_cluster's leftover-data guard + create/reuse branch, assess's
# classifier) each read _cluster_presence and say out loud what UNKNOWN means for
# them. One seam, no parallel primitive (LukasWodka, client#984).

# Prove the nodes can actually SEE the host tree before anything writes to it.
#
# In hostpath mode every chart PV is a hostPath onto /tracebloc/<release>/…, and
# /tracebloc is the k3d bind mount of HOST_DATA_DIR. When that mount is not in
# effect, nothing fails: kubelet's `DirectoryOrCreate` fabricates the directory
# inside the node's own filesystem, the PVC Binds, the pod Runs, MySQL initialises
# a brand-new empty datadir and the dataset dir reads as zero rows. There is no
# event, no warning and no failed probe anywhere — the operator sees a healthy
# install that has quietly stopped using their data. On the next `cluster delete`
# it goes with the node.
#
# The obvious chart-side fix does not work: flipping the PVs to `type: Directory`
# so kubelet refuses is REJECTED BY THE API SERVER on any existing release —
# `spec.persistentvolumesource is immutable after creation` — so it fails the
# `helm upgrade` of every install that already has PVs (measured on k3s v1.36.3,
# release left in `failed`). Hence a probe here, before helm runs, where being
# wrong costs an error message instead of a broken upgrade.
#
# Fails CLOSED. "Cannot tell" is a finding, not a pass: an unreadable marker, a
# node we cannot exec into, or a node list we cannot obtain all block the install.
# Silently proceeding is precisely the failure this exists to end.
_verify_nodes_see_host_data() {
  [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]] && return 0

  local marker=".tracebloc-mount-probe"
  # Content, not just presence: a bind mount pointed at the WRONG host directory
  # still shows a file called .tracebloc-mount-probe from an earlier run. Only a
  # token this invocation minted proves we are looking at this host tree now.
  local token stamp
  stamp="$(date +%s 2>/dev/null || echo 0)"
  token="$$-${RANDOM}-${stamp}"
  printf '%s' "$token" > "${HOST_DATA_DIR}/${marker}" 2>/dev/null \
    || error "Can't write to ${HOST_DATA_DIR} — check the directory exists and you own it, then re-run."

  local nodes node seen
  # Selected by k3d's own LABELS, not by node name.
  #
  #   * `label=k3d.cluster=<name>` is an EXACT value match, so a same-prefixed
  #     sibling cluster cannot leak in. `name=k3d-<name>-` is an unanchored
  #     SUBSTRING match and would also list `k3d-<name>-dev-server-0`; if that
  #     sibling was created against a different HOST_DATA_DIR its nodes cannot see
  #     this token, and the probe would refuse THIS install while naming a node
  #     that is not ours. A false refusal is the one failure mode a fail-closed
  #     guard most has to avoid (@saqlainsyed007 on #817).
  #   * `k3d.role` says what each container IS, so the load balancer is excluded
  #     because it is a `loadbalancer` — not because its name happens to end in
  #     `-serverlb`. Role is k3d's declaration; the name suffix is our guess at it.
  #
  # Bounded: a WEDGED (as opposed to stopped) daemon never returns from a bare
  # `docker`, which would freeze a headless install right here with no further
  # output — the exact failure this guard exists to replace with a clear refusal
  # (Bugbot; same reason _docker_answers is bounded).
  #
  # `docker ps` lists RUNNING containers only: a created-but-stopped node cannot be
  # exec'd and must not be mistaken for one that passed.
  #
  # ONE QUERY PER ROLE, letting docker AND the two label filters, rather than one
  # query with `--format '{{.Names}} {{.Label "k3d.role"}}'` and an awk split. Bash
  # could use the quoted format safely — it passes an array and never re-joins —
  # but the PowerShell twin CANNOT: its $psi.Arguments joins the args and quotes any
  # whitespace-bearing value without escaping inner quotes, so that format arrives
  # with its quotes consumed and docker's Go template fails to parse, throwing a
  # FALSE REFUSAL on every Windows hostpath install (#817). Keeping both halves on
  # the shape the constrained one requires is what makes them diffable by eye; a
  # divergence here would be a twin gap nobody notices until Windows breaks.
  #
  # Bonus: no role parsing, and the load balancer is excluded by construction —
  # its role is `loadbalancer`, which is simply never queried.
  local role out st
  nodes=""
  for role in server agent; do
    # `|| st=$?` IS LOAD-BEARING, not a style choice. install-k8s.sh runs under
    # `set -euo pipefail` and shell options are global to the sourcing shell, so a
    # bare `out=$(...)` is a simple command whose status is the substitution's: when
    # docker errors, set -e exits AT THE ASSIGNMENT and everything below it —
    # including the fail-closed branch and the `rm -f` of the probe marker — is dead
    # code. The previous shape survived only because it ended in `|| true`.
    #
    # The operator would then get the ERR trap's generic record naming `docker ps`
    # instead of the refusal, and the marker left behind in HOST_DATA_DIR: precisely
    # the opaque failure this guard exists to replace. (@saadqbal on #817, measured
    # both call shapes; production calls this bare from create_cluster.)
    #
    # `st=0` first, because `|| st=$?` leaves st untouched on success.
    st=0
    out=$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker ps \
            --filter "label=k3d.cluster=${CLUSTER_NAME}" \
            --filter "label=k3d.role=${role}" \
            --format '{{.Names}}' 2>/dev/null) || st=$?
    # Fail closed per role: an EMPTY list is legitimate (AGENTS=0 has no agent), but
    # a docker that ERRORED tells us nothing and must not read as "none".
    if (( st != 0 )); then
      rm -f "${HOST_DATA_DIR}/${marker}" 2>/dev/null || true
      error "Couldn't list the nodes of cluster '${CLUSTER_NAME}' to check your data directory is visible inside it. Check 'docker ps' works, then re-run."
    fi
    [[ -n "$out" ]] && nodes+="${out}"$'\n'
  done
  if [[ -z "${nodes//[[:space:]]/}" ]]; then
    rm -f "${HOST_DATA_DIR}/${marker}" 2>/dev/null || true
    error "Couldn't list the nodes of cluster '${CLUSTER_NAME}' to check your data directory is visible inside it. Check 'docker ps' works, then re-run."
  fi

  for node in $nodes; do
    seen=$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker exec "$node" cat "/tracebloc/${marker}" 2>/dev/null || true)
    if [[ "$seen" != "$token" ]]; then
      rm -f "${HOST_DATA_DIR}/${marker}" 2>/dev/null || true
      error "Node '${node}' cannot see your data directory (${HOST_DATA_DIR}).

  Everything would appear to install, but the secure environment would store your
  data INSIDE the node instead of on this machine — and lose it when the cluster is
  recreated. Refusing to continue.

  Most likely causes:
    * Docker Desktop is not sharing this path. Add it under
      Settings -> Resources -> File sharing, then re-run.
    * The cluster was created without the data mount. Recreate it — releasing this
      machine's secure environment first, or deleting the cluster strands it on your
      dashboard: 'tracebloc delete --keep-data' (skip it if nothing is installed yet),
      then 'k3d cluster delete ${CLUSTER_NAME}' and re-run this installer.
    * HOST_DATA_DIR changed since the cluster was created (currently ${HOST_DATA_DIR})."
    fi
  done

  rm -f "${HOST_DATA_DIR}/${marker}" 2>/dev/null || true
  log "Verified all ${CLUSTER_NAME} nodes see ${HOST_DATA_DIR} at /tracebloc."
}

# Build a k3d config file that carries the proxy env vars as structured YAML
# entries, and echo its path. We use --config rather than --env KEY=VALUE@FILTER
# because k3d splits the --env flag on '@', which corrupts authenticated-proxy
# URLs (http://user:pass@host); the YAML env list has no such ambiguity, so
# credentials survive intact. NO_PROXY is always emitted (auto-augmented) when a
# proxy is present, so in-cluster traffic bypasses the proxy even if the host
# set only HTTP_PROXY. Echoes nothing when the host has no HTTP(S) proxy set.
# WHICH variables, and their values, come from cluster.sh's _node_proxy_env, the
# one definition native k3s reads too.
_write_k3d_proxy_config() {
  local pairs pair
  pairs="$(_node_proxy_env)"
  [[ -z "$pairs" ]] && return 0

  # mktemp -d with trailing X's is portable across GNU + BSD/macOS mktemp; a
  # plain file template with a '.yaml' suffix is not (BSD needs trailing X's),
  # and k3d/viper needs the '.yaml' extension to parse the config — so the file
  # lives inside a temp dir. Caller removes the dir.
  local td; td="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3d-XXXXXX")" || return 0
  local cfg="$td/config.yaml"
  {
    echo "apiVersion: k3d.io/v1alpha5"
    echo "kind: Simple"
    echo "env:"
    while IFS= read -r pair; do
      printf '  - envVar: "%s"\n    nodeFilters:\n      - all\n' "$pair"
    done <<<"$pairs"
  } > "$cfg"
  echo "$cfg"
}

# Write a k3d registries.yaml pointing containerd at the mounted CA for every
# registry in TRACEBLOC_CA_REGISTRIES, and echo its path. $1 = the CA path INSIDE the
# node (where the -v mount lands). Caller removes the temp dir.
#
# (Reunited with its function: the kubelet section above was inserted between the
# two, leaving this prose reading as documentation for `_write_kubelet_config`,
# whose contract is the opposite -- a fixed persistent path, no temp dir, nothing
# for a caller to clean up. Reviewer, client#912.)
_write_k3d_registries_config() {
  local node_ca="$1" td cfg
  td="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3d-reg-XXXXXX")" || return 1
  cfg="$td/registries.yaml"
  _render_registries_config "$node_ca" > "$cfg"
  echo "$cfg"
}

# _k3d_create_cluster -- step c on k3d; cluster.sh's create_cluster routes here.
_k3d_create_cluster() {
  log "Creating k3d cluster: '$CLUSTER_NAME'"

  # RFC 0001 #1221 (Tier 1): target the per-user ROOTLESS daemon, not a (missing)
  # system daemon. Slice 1 exports DOCKER_HOST during install, but create_cluster
  # can be re-entered by a caller that lost that export (the e2e harness, a bare
  # re-run), so re-assert it here whenever rootless is active. k3d and docker read
  # DOCKER_HOST from the environment and the `( k3d … ) &` subshell in
  # _create_new_cluster inherits it, so one export covers every call in this flow.
  # Guard XDG_RUNTIME_DIR (unset on some non-login sessions). No-op with the flag
  # off — the legacy host-daemon path is byte-for-byte unchanged.
  if _rootless_active; then
    export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
  fi

  # ONE tri-state read, used for BOTH decisions below (client#984). It used to be
  # two `_cluster_exists` calls, which cost two engine round-trips and — worse —
  # let a bounded read's THIRD outcome disappear into a boolean twice over.
  #   0 = present, 1 = absent, 2 = the engine did not answer.
  local _presence=0
  _cluster_presence || _presence=$?

  # Leftover-data guard (RFC-0003 D3, #376): a NEW cluster must not silently
  # adopt data from an earlier install. Skipped when the cluster already exists
  # — that path is an in-place reuse/upgrade and keeps its data by design (§3.3).
  #
  # ONLY on a DEFINITE absent (Bugbot High, client#984). This guard warns about
  # existing data and then PROMPTS — with delete among the options — so running it
  # because a listing timed out is the one outcome strictly worse than the hang
  # #974 removed: it offers to destroy the data of an install that is probably
  # still there. UNKNOWN skips it, exactly as a present cluster does.
  if [[ "$_presence" -eq 1 ]]; then
    guard_leftover_data
  fi

  # node-local (RFC-0003 Option C): no host data dirs, no bind-mount, no chmod —
  # data lives on k3s local-path inside the node. Only the hostpath model needs
  # the pre-created world-writable ~/.tracebloc dirs.
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    log "Storage mode: node-local — datasets live inside the cluster node (k3s local-path), not ~/.tracebloc; they are wiped on 'cluster delete'."
  fi
  _ensure_host_data_dirs

  # Docker is up now (unlike at preflight time), so re-check the runtime's real
  # memory budget — a too-small Docker VM (Mac/Win) surfaces before we build out.
  # Guarded: cluster.sh can be sourced without preflight.sh (e.g. the e2e harness).
  if declare -F _pf_recheck_runtime_mem >/dev/null 2>&1; then _pf_recheck_runtime_mem || true; fi

  # UNKNOWN takes the REUSE path, never the create path (Bugbot High, client#984).
  # `_create_new_cluster` runs `k3d cluster create` against a name that may already
  # be in use, on a machine we could not read; `_handle_existing_cluster` only
  # reads and, at worst, issues an idempotent `k3d cluster start --wait --timeout
  # 5m` that fails into "Couldn't start your existing secure environment. Check
  # Docker is running, then re-run." — bounded, and the right sentence for a wedged
  # engine. Explicit `case`, not `if _cluster_exists`, so the third outcome is
  # visible at the decision site instead of hidden inside a boolean.
  local _hrc=0
  case "$_presence" in
    0) _handle_existing_cluster || _hrc=$? ;;
    # NEUTRAL, AND IT PROMISES NOTHING ABOUT WHAT HAPPENS NEXT (saadqbal,
    # client#984 round 6). Two over-claims: _cluster_presence returns 2 for a
    # DEADLINE *and* for "every read failed" (`_read_ok=0`), so blaming the Docker
    # engine tells a user with a broken $HOME/.k3d or an unreadable kubeconfig to
    # go and look at a daemon that is perfectly healthy; and "nothing is created or
    # removed" is falsified by the rc-3 path below, which prompts about leftover
    # data and creates. `_cluster_presence`'s own L164 line and assess.sh's
    # `cluster-indeterminate` copy already word this condition neutrally.
    2) warn "Couldn't read the k3d cluster list for '$CLUSTER_NAME' — the listing either didn't complete or k3d couldn't answer it. Not assuming the environment is either present or absent: taking the path that reads again before it acts."
       _handle_existing_cluster || _hrc=$? ;;
    # `1)`, NOT `*)`. Creating was the DEFAULT arm, so any value the contract
    # grows next would land on the one branch that runs `k3d cluster create`
    # against a machine nobody classified — the destructive direction, reached by
    # default, which is this PR's own subject one level up (LukasWodka/saadqbal
    # nit, client#984). An unrecognised code now takes the same neutral route as
    # UNKNOWN, because that is exactly what it is.
    1) _create_new_cluster ;;
    *) warn "Couldn't classify this machine's k3d cluster state (the presence probe returned an unrecognised code $_presence) — treating it as unread and taking the path that reads again before it acts."
       _handle_existing_cluster || _hrc=$? ;;
  esac

  # rc 3 = the reuse path's OWN listing answered and proved the cluster ABSENT
  # (Bugbot High, client#984 round 5). Without this, an UNKNOWN first read locked
  # the run into "start a cluster that isn't there" — which fails, and `error`
  # exits — so a first-time machine with one slow listing could never install.
  # This IS a first-read ABSENT, learned one read later, so it runs the SAME two
  # steps in the SAME order the definite-absent path above does — the guard first
  # (a new cluster must not silently adopt an earlier install's data), the host
  # data dirs second.
  #
  # THE DIRS STEP HAS TO RUN AGAIN HERE, and an earlier version of this block
  # asserted the invariant in a comment while inverting it in the code
  # (LukasWodka, client#984 round 7). `_ensure_host_data_dirs` already ran above
  # the `case`, against whatever HOST_DATA_DIR held then; `guard_leftover_data`
  # may have `rm -rf`'d those very directories (wipe) or re-pointed
  # HOST_DATA_DIR at a path nothing has created yet (newdir). Its own header
  # carries the mechanism for both.
  #
  # EXHAUSTIVE over _handle_existing_cluster's contract (0 and 3; it `error`s out
  # rather than returning on a failed start). `if [[ … -eq 3 ]]` alone let every
  # OTHER non-zero fall silently through to the reconcile tail below, which is
  # the same "an outcome nobody wrote code for" shape as the bare call site this
  # round fixed — so an unrecognised code stops here instead.
  case "$_hrc" in
    0) ;;
    3) guard_leftover_data
       _ensure_host_data_dirs
       _create_new_cluster ;;
    *) error "The existing-cluster step returned an unrecognised status ($_hrc) and this run can't tell whether your secure environment is ready. Nothing further was changed; see the install log and re-run." ;;
  esac

  # Every path above ends with the cluster present, but only a fresh create
  # records it (in _create_new_cluster). A reused or adopted cluster would
  # otherwise leave the install record without its k3d-cluster artefact, and an
  # uninstall driven by the record would leave the cluster behind. Recording is
  # keyed on kind + id + path, so this is a no-op after a fresh create.
  tb_record_write k3d-cluster "$CLUSTER_NAME" ""

  ensure_cluster_autostart
  _merge_kubeconfig
  _export_host_no_proxy
  _wait_for_api

  # Both branches above are done, so every node container is up and the bind
  # mount (if any) is in effect — this is the first point where the question can
  # be answered, and it is still before helm writes anything. Deliberately AFTER
  # _handle_existing_cluster too: an adopted cluster is exactly the one that may
  # have been created without the mount.
  _verify_nodes_see_host_data

  # GPU nodes are up now (fresh from the GPU image, or a reused GPU-capable one),
  # so generate the native NVIDIA CDI spec inside them before helm rolls out the
  # device plugin (client#835). No-op unless GPU is wired; may fall back to CPU if
  # no node can produce a usable spec.
  _generate_node_cdi_specs
}

# Guarantee the cluster returns after a host reboot. On Linux this already works
# by default — k3d sets `--restart unless-stopped` on its node containers and the
# Docker install enables docker.service on boot — but we harden both so it holds
# even on a re-run where Docker was installed-but-disabled, or for an externally-
# created cluster. On macOS/Windows the restart policy is set too, but Docker
# Desktop must be configured to start on login (the summary tells the user).
# Opt out with TRACEBLOC_SKIP_AUTOSTART=1 (TRACEBLOC_NO_AUTOSTART until
# remove_by 2026-12-31; both are read, so an opt-out already set keeps working).
ensure_cluster_autostart() {
  if [[ -n "${TRACEBLOC_SKIP_AUTOSTART:-}" || -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then return 0; fi

  local nodes node _nodes_rc=0
  # BOUNDED (client#984, LukasWodka): this is a daemon read on the main install
  # path, and it ran unbounded while its `docker info` neighbours did not — the gap
  # check-style rule 5 could not see until it was widened past `info`.
  #
  # DO NOT `|| return 0` here (Bugbot Medium, off the client#1011 promotion
  # review): this read feeds ONLY the node restart-policy loop below, but the Linux
  # docker.service boot-enable further down does NOT depend on the node list.
  # Bailing out of the whole function on a 124 left the operator a finished
  # install whose docker.service was never enabled on boot — the cluster would
  # not come back after a reboot, with no warning. A failed/timed-out read means
  # "we couldn't enumerate nodes", so skip the loop (k3d already sets
  # --restart unless-stopped at create time, so the policy still holds — the same
  # rationale the Windows twin Set-ClusterAutostart states) and fall through to
  # the boot-enable step.
  nodes=$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker ps -a --filter "name=k3d-${CLUSTER_NAME}-" --format '{{.Names}}' 2>/dev/null) || _nodes_rc=$?
  if [[ "$_nodes_rc" -ne 0 ]]; then
    nodes=""
    log "Could not read k3d nodes for the restart policy (docker ps exit ${_nodes_rc}); leaving k3d's own --restart policy in place and continuing to the boot-enable step."
  fi
  if [[ -n "$nodes" ]]; then
    for node in $nodes; do
      # NOT the tools helper (client-dev#1370). k3d makes it `restart=no` on
      # purpose and recreates it on every `k3d cluster start`; it is the one
      # container on the cluster network with a DYNAMIC address, so brought back by
      # Docker ahead of the pinned nodes it can take one of their addresses and
      # stop a node from starting ("Address already in use").
      #
      # PUT BACK, not skipped (Bugbot on client-dev#1380): installers before this
      # one set unless-stopped on every k3d-<cluster>-* container, the helper
      # included, and a skip leaves that policy on an environment they touched.
      # Best effort, like the update below. The pin and the repair need no reset
      # of their own: both end in `k3d cluster start`, which replaces the helper
      # with a new restart=no container (measured on k3d v5.9.0: new container ID,
      # restart=no, after the old one had been set to unless-stopped).
      if [[ "$node" == "k3d-${CLUSTER_NAME}-tools" ]]; then
        docker update --restart no "$node" >/dev/null 2>&1 || true
        continue
      fi
      docker update --restart unless-stopped "$node" >/dev/null 2>&1 || true
    done
    log "Set restart=unless-stopped on k3d nodes so the cluster returns after a reboot."
  fi

  # On Linux, make sure Docker itself starts on boot. The fresh-install path only
  # enables docker.service when Docker was absent; this also covers the
  # installed-but-disabled re-run case. Idempotent.
  if [[ "$OS" == "Linux" ]] && has systemctl; then
    # Seed the reboot promise from the CURRENT on-boot state, not just from
    # whether *this* run flipped it: a normal Docker package install already
    # enables docker.service, so on the Tier 0 path (which deliberately never
    # runs `systemctl enable`) the cluster still returns on its own after a
    # reboot. `is-enabled` is an unprivileged read, so no sudo/password prompt.
    # Only the persistent "enabled" state survives a reboot — "enabled-runtime"
    # is transient and must NOT set the flag.
    # NOT on the rootless path (#478 / Bugbot): there the cluster runs on the
    # per-user rootless socket, so the SYSTEM docker.service's on-boot state says
    # nothing about whether the cluster returns — a system unit that happens to be
    # enabled (docker installed system-wide, user not in the group → they chose
    # rootless) would seed a false promise the rootless branch below then can't
    # honestly retract. On rootless, the user-scope enable+linger below are the
    # SOLE authority for the flag.
    if ! _rootless_active && [[ "$(systemctl is-enabled docker 2>/dev/null)" == "enabled" ]]; then
      TB_DOCKER_AUTOSTART=1
    fi

    if [[ "${INSTALL_TIER:-}" == "0" ]]; then
      # Tier 0 (a usable runtime already exists, no admin): do NOT sudo to enable
      # docker.service — we promised zero privileged steps, and a docker-group
      # user may have no sudo, so this would prompt for a password on /dev/tty
      # even behind the spinner (Bugbot #375). The k3d `--restart unless-stopped`
      # policy set above already returns the cluster after a reboot for the common
      # case; enabling docker.service on boot is the user's call.
      log "Tier 0: leaving Docker autostart to the user (no privileged step)."
    elif _rootless_active; then
      # Tier 1 rootless (RFC 0001 #1221): the daemon is a per-user systemd unit,
      # NOT the system docker.service — `sudo systemctl enable docker` would target
      # a unit that doesn't exist on this path (and demand a password we promised
      # not to need). Enable it in user scope, and enable linger so the user manager
      # (and thus the rootless daemon + cluster) starts at boot on a headless
      # training host with no active login session. Both best-effort: enabling
      # linger for one's own user generally needs no root, and the `--restart
      # unless-stopped` policy set above is what actually returns the cluster after
      # a reboot. The node loop above already ran against this same rootless daemon
      # (via DOCKER_HOST), so the reboot promise holds.
      # Attempt BOTH unconditionally (if-form, so a failure never trips set -e),
      # then only promise reboot-survival when BOTH succeed: on a headless host the
      # cluster returns on its own only if the user manager runs with no login
      # session (linger) AND its docker unit is enabled. Setting the flag
      # regardless would let summary.sh::_reboot_note promise a survival the host
      # can't deliver — the honesty rule the legacy `elif sudo … enable` path
      # already follows (only flags on success). #375/#458.
      local _user_enabled=0 _linger_ok=0
      if systemctl --user enable docker >/dev/null 2>&1; then _user_enabled=1; fi
      if loginctl enable-linger "$(id -un 2>/dev/null || printf '%s' "${USER:-}")" >/dev/null 2>&1; then _linger_ok=1; fi
      if [[ "$_user_enabled" == 1 && "$_linger_ok" == 1 ]]; then
        TB_DOCKER_AUTOSTART=1
        log "Tier 1 rootless: enabled the user Docker daemon on boot (systemctl --user enable + linger)."
      else
        # Defensive (Asad review): make the honesty guarantee local to this branch —
        # ensure no earlier state leaves a reboot-survival promise the rootless daemon
        # can't keep. The is-enabled seed above is already guarded off the rootless
        # path, so this is belt-and-suspenders, not the sole fix.
        TB_DOCKER_AUTOSTART=0
        log "Tier 1 rootless: boot autostart not fully enabled (user-service enable or linger unavailable); the --restart policy still applies while your user session is active."
      fi
    elif sudo systemctl enable docker >/dev/null 2>&1; then
      # docker.service will start on boot → the summary's reboot note can honestly
      # promise the cluster returns on its own (read in summary.sh::_reboot_note).
      TB_DOCKER_AUTOSTART=1
      log "Ensured docker.service is enabled on boot."
    fi
  fi
  return 0
}

_handle_existing_cluster() {
  CLUSTER_STATUS="0"
  # BOUNDED (client#974) and TRI-STATE (client#984). Both reads talk to the Docker
  # engine, and a wedged daemon blocks rather than fails them, so the
  # `2>/dev/null || true` / `|| echo "0"` fallbacks were unreachable.
  #
  # And a timeout is not "0 servers running". Collapsing it into that number is the
  # same defect as the one that cost this PR two rounds of review: it made the
  # installer PRINT "Cluster 'x' exists but is stopped", a claim about a machine it
  # could not read, on a run where the cluster is quite possibly up. The ACTION on
  # this branch is safe either way — `k3d cluster start` is idempotent on a running
  # cluster and bounded — so the fix is to keep the action and stop making the
  # claim. `_status_read_ok` carries the third state to the message below.
  # THREE read states, not two (Bugbot Medium, client#984 round 5): `answered`,
  # `stalled` (124 — the deadline), `failed` (anything else — the read COMPLETED
  # and k3d said no: permission denied, an unsupported flag, a broken kubeconfig).
  # Collapsing the last two wrote a millisecond failure up as a listing that
  # "didn't complete", which is the same defect as the one above with the sign
  # flipped, and the one saadqbal found across diagnose.sh's seven sites.
  #
  # `_row_found` is the fourth thing this read knows and used to throw away: a
  # listing that ANSWERED and contains no row for this cluster says the cluster is
  # ABSENT — authoritatively. See the AUTHORITATIVE ABSENT block below.
  local _status_read=answered _row_found=0 _rc=0
  if command -v jq &>/dev/null; then
    local _json
    _json="$(_bounded "${TB_K3D_LIST_TIMEOUT:-15}" k3d cluster list -o json 2>/dev/null)" || _rc=$?
    if [[ "$_rc" -eq 124 ]]; then
      _status_read=stalled
    elif [[ "$_rc" -ne 0 ]]; then
      _status_read=failed
    elif ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$_json"; then
      # THE SHAPE IS CHECKED FIRST, for the reason written out at _cluster_presence
      # L106-110 (saadqbal, client#984 round 6): `jq -e` cannot tell "no match"
      # from "not JSON" — `{}` exits 1, `null` 5, garbage 4, `[]` 1, all non-zero.
      # Without this gate every one of those landed as "the listing answered and
      # your cluster is not in it", with `_rc` 0 keeping `_status_read=answered` —
      # exactly the pair the AUTHORITATIVE ABSENT block below fires on. It would
      # then prompt about leftover data (delete among the options) and run
      # `k3d cluster create` against a name that may already exist, off a payload
      # that never parsed. Reachable without anything exotic: stdout carrying a k3d
      # notice ahead of the array, or an older k3d emitting `null` rather than `[]`.
      # _cluster_presence calls this same payload inconclusive; the two functions
      # must not reach opposite verdicts on one payload, least of all with this one
      # taking the destructive direction.
      _status_read=unparseable
      log "k3d answered the JSON cluster listing with a payload that is not an array; treating this machine's cluster state as unread rather than as absent."
    else
      if jq -e --arg n "$CLUSTER_NAME" 'any(.[]; .name == $n)' >/dev/null 2>&1 <<<"$_json"; then
        _row_found=1
        CLUSTER_STATUS=$(jq -r --arg n "$CLUSTER_NAME" '.[] | select(.name == $n) | .serversRunning // 0' 2>/dev/null <<<"$_json" || echo "0")
      fi
    fi
  else
    # Capture-then-match (#680): awk's `exit` closes the pipe on our cluster's
    # row, so k3d can take SIGPIPE and pipefail would abort the installer here —
    # mid-reconcile, with no message. Mirrors _assess_cluster_servers_running.
    local line _tbl
    _tbl="$(_bounded "${TB_K3D_LIST_TIMEOUT:-15}" k3d cluster list --no-headers 2>/dev/null)" || _rc=$?
    if [[ "$_rc" -eq 124 ]]; then
      _status_read=stalled
    elif [[ "$_rc" -ne 0 ]]; then
      _status_read=failed
    else
      # The ROW's existence and its server count are two different questions: a row
      # with `0/1` servers is a stopped cluster, no row at all is no cluster.
      #
      # `{ found = 1 } END { exit(...) }`, NOT `{ exit 0 } END { exit 1 }`: awk's
      # `exit` RUNS the END action, and END's own `exit 1` then wins — so the
      # familiar-looking form reports "no row" on a listing that plainly contains
      # one. (The same idiom sits in _cluster_presence, where it is masked by the
      # layout-tolerant `grep` immediately after it and therefore never noticed.)
      if awk -v n="$CLUSTER_NAME" '$1 == n { found = 1 } END { exit(found ? 0 : 1) }' <<<"$_tbl"; then
        _row_found=1
        line=$(awk -v n="$CLUSTER_NAME" '$1 == n { print $2; exit }' <<<"$_tbl")
        if [[ -n "$line" ]]; then
          CLUSTER_STATUS="${line%%/*}"
        fi
      fi
    fi
  fi
  CLUSTER_STATUS="${CLUSTER_STATUS:-0}"

  # ── AN AUTHORITATIVE ABSENT SUPERSEDES THE EARLIER "COULDN'T TELL" ──────────
  # Bugbot HIGH, client#984 round 5. create_cluster routes UNKNOWN here on
  # purpose — reuse is the direction that destroys nothing — but this function's
  # OWN listing may then answer, and "no row for this cluster" was normalised into
  # CLUSTER_STATUS=0, i.e. "exists but is stopped". `k3d cluster start` on a name
  # that does not exist fails, and `error` EXITS the installer. Net effect: a
  # first-time machine whose very first listing exceeded TB_K3D_LIST_TIMEOUT could
  # never install, however authoritatively the next read proved the cluster absent.
  #
  # This is BUGBOT.md rule (b) in the other order — a definite answer from a read
  # that COMPLETED beats "couldn't tell" from one that did not, whichever arrives
  # first. Reported to the caller (rc 3) rather than acted on here, because
  # creating a cluster is create_cluster's decision to make and it owes the
  # leftover-data guard on that path.
  if [[ "$_status_read" == "answered" && "$_row_found" -eq 0 ]]; then
    log "The k3d listing answered and this machine has no '$CLUSTER_NAME' cluster — a definite ABSENT, which supersedes the earlier listing that could not be read. Creating the environment instead of starting one that isn't there."
    return 3
  fi

  if [[ "$CLUSTER_STATUS" -gt "0" ]]; then
    success "Secure environment already running."
  else
    # THE MESSAGE distinguishes the three states even though the ACTION does not
    # need to (client#984). "exists but is stopped" is a CLAIM about the machine;
    # making it off an unreadable listing is the same defect this PR is about, and
    # on a run where the cluster may well be up it sends the operator looking in
    # the wrong place. `k3d cluster start` is idempotent on a running cluster and
    # bounded, so the safe action is identical either way — only the sentence
    # changes.
    case "$_status_read" in
      stalled)
        log "Couldn't read whether '$CLUSTER_NAME' is running (the k3d listing didn't complete within ${TB_K3D_LIST_TIMEOUT:-15}s) — attempting a start, which is a no-op if it is already up..." ;;
      failed)
        log "Couldn't read whether '$CLUSTER_NAME' is running (the k3d listing failed, exit $_rc — it answered, so this is k3d's own error and not a timeout; see the install log) — attempting a start, which is a no-op if it is already up..." ;;
      unparseable)
        log "Couldn't read whether '$CLUSTER_NAME' is running (k3d's JSON listing was not an array, so nothing could be concluded from it) — attempting a start, which is a no-op if it is already up..." ;;
      *)
        log "Cluster '$CLUSTER_NAME' exists but is stopped — starting it..." ;;
    esac
    # Capture the tool's raw stderr to the log and surface only a curated line on
    # failure — graceful failure, not a raw k3d dump before the closer (#577).
    # Bounded start (Bugbot): `k3d cluster start` waits for the server with no
    # deadline by default, so behind the log redirect a wedged Docker would hang a
    # headless install forever instead of reaching the curated error below. --wait
    # --timeout bounds it (parity with the Windows installer's 5-minute start
    # deadline) so a stuck start fails cleanly into that message.
    #
    # THE DOCKER ATTRIBUTION HERE IS DELIBERATE, and stays after `:944`'s was
    # dropped (LukasWodka, client#984 round 7, raised so the choice is visible
    # rather than reading as an oversight). The two sentences are about different
    # events. `:944` reports a failed *listing* — a read, which a broken
    # `$HOME/.k3d` or an unreadable kubeconfig fails just as readily as a wedged
    # engine, so naming Docker there sent people to inspect a healthy daemon.
    # This is a failed *start*: an ACTION, attempted with `--wait --timeout 5m`,
    # against containers that only the engine can bring up. A wedged or stopped
    # engine is the overwhelmingly common cause and the one the operator can do
    # something about, which is the same judgement `:929-931` records for
    # choosing this branch on UNKNOWN in the first place. "Check Docker is
    # running" is also advice rather than a diagnosis — it does not claim the
    # daemon is down, and the raw k3d stderr is in the install log either way.
    k3d cluster start "$CLUSTER_NAME" --wait --timeout 5m >> "${LOG_FILE:-/dev/null}" 2>&1 \
      || error "Couldn't start your existing secure environment. Check Docker is running, then re-run."
    success "Secure environment started."
  fi

  _check_existing_cluster_proxy
  _check_existing_cluster_ca
  _check_existing_cluster_bind
  _check_existing_cluster_dataset_mount
  _check_existing_cluster_kubelet_config
  _check_existing_cluster_storage_mode
  _check_existing_cluster_k8s_version
  _check_existing_cluster_node_count
  # GPU capability is fixed at create time: a reused CPU-only node can't run GPU
  # pods, so drop the GPU request here rather than strand jobs Pending (client#835).
  _check_existing_cluster_gpu
}

# A cluster born with more than one k3d node: every hostpath install made before
# tracebloc/client-dev#1418 got one server plus one agent by default. The node
# count is fixed at create time, so a re-run or `tracebloc upgrade` keeps both
# nodes, and Kubernetes keeps counting this machine's CPU and memory twice. This
# check only advises: it names the remedy, changes nothing and
# refuses nothing. The nodes are read from docker through _k3d_nodes, never from
# $SERVERS/$AGENTS, which only the k3d create path reads (shared-state.bats). A
# list that cannot be read means "cannot tell", so it stays silent rather than
# claiming a count.
_check_existing_cluster_node_count() {
  local role list line count=0
  for role in server agent; do
    list="$(_k3d_nodes "$role")" || return 0
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then count=$((count + 1)); fi
    done <<<"$list"
  done
  (( count > 1 )) || return 0
  echo ""
  warn "The existing '$CLUSTER_NAME' cluster has ${count} k3d nodes. Each one reports this whole machine as its capacity, so Kubernetes counts its CPU and memory ${count} times and can schedule more than the machine holds."
  hint "New installs create one node. A cluster's node count is fixed when it is created, so a re-run or an upgrade keeps it."
  hint "Unless you chose the second node on purpose (TRACEBLOC_AGENTS=1), reinstall as one node:"
  _recreate_cluster_hint
  echo ""
}

# The recreate remedy, printed from ONE place (backend#2077).
#
# Why it can't just be `k3d cluster delete`: the backend record for this machine
# is anchored to the identity of the CLUSTER — the kube-system namespace UID —
# which is born with the k3d cluster and dies with it. `k3d cluster delete` never
# calls the API, so the record keeps a cluster_id that will never exist again:
# the next run correctly mints a NEW secure environment and the old one is
# stranded on the dashboard for good. Nothing reaps it, and an orphan can later
# be picked as another machine's active pointer.
#
# `tracebloc delete` is the offboard that releases it: it revokes this machine's
# credential server-side (the record is kept as history, never hard-destroyed),
# uninstalls the Helm release, and tears down its own local cluster. The revoke
# is an API call, so it still works when the cluster itself is broken — which is
# the state at most of these call sites.
#
# --keep-data is not optional here. The plain form wipes ~/.tracebloc, which is
# HOST_DATA_DIR by default — the very data these call sites promise a recreate
# keeps. It also spares the stored login, so the re-run doesn't sign in again.
#
# The k3d line stays: `tracebloc delete` only tears down a cluster literally
# named `tracebloc` (the CLI's built-in name), so a custom CLUSTER_NAME still
# needs it — and on the default name it is simply a no-op.
#
# Advice, never run for the user: these sites are diagnosing a cluster, not
# offboarding one, and a machine that never finished provisioning has nothing to
# release (`tracebloc delete` says exactly that and exits) — hence the last line.
#
# $1 (optional): env assignments to prefix the re-run with, e.g.
#                "TB_STORAGE_MODE=node-local  ".
_recreate_cluster_hint() {
  local rerun_prefix="${1:-}"
  hint "Release this machine's secure environment BEFORE deleting the cluster — it is anchored to the"
  hint "cluster's identity, so deleting the cluster first strands it on your dashboard for good:"
  hint "  tracebloc delete --keep-data      (releases this secure environment; keeps your local data)"
  hint "  k3d cluster delete $CLUSTER_NAME  &&  ${rerun_prefix}re-run this installer."
  hint "  (nothing installed on this machine yet? then just the k3d line.)"
}

# k3s version is fixed when the cluster is created (baked into the node image);
# it can't be changed on a running cluster. A cluster created by an older/unpinned
# installer or with K8S_VERSION=latest keeps whatever k3s it was born with, EVEN
# ACROSS later correctly-pinned re-runs — the single best explanation for the #547
# incident, where a client ran k3s v1.35.5 while the pin was v1.29.4-k3s1 and every
# re-run silently reused the drifted cluster. Warn on drift with the recreate
# remedy so it's surfaced instead of reused. Silent no-op if Docker is down, the
# server can't be inspected, or the image isn't a parseable rancher/k3s:<tag>
# (e.g. a digest-only pin) — never false-warn.
_check_existing_cluster_k8s_version() {
  [[ -z "${K8S_VERSION:-}" || "$K8S_VERSION" == "latest" ]] && return 0
  local server_container="k3d-${CLUSTER_NAME}-server-0"
  local image
  # Bounded (installer rule: every docker/kubectl probe must have a deadline): both
  # healthy fast-paths call this, so a wedged Docker engine must not hang an
  # "already healthy" re-run after success is printed (#565 Bugbot). 124 on timeout
  # → the `|| return 0` makes it a silent no-op, same as an inspect failure.
  image=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "$server_container" --format '{{.Config.Image}}' 2>/dev/null) || return 0
  [[ -z "$image" ]] && return 0
  local running=""
  case "$image" in
    *rancher/k3s:*)
      running="${image##*rancher/k3s:}"   # strip up to the tag
      running="${running%%@*}"            # drop any @sha256:... digest suffix
      ;;
    *k3s-cuda:*)
      # GPU node image (client#835): its tag encodes the k3s pin as
      # <k3s>-cuda-<cuda-base>, so extract the k3s part and drift-check it too —
      # else a GPU cluster silently escapes this check and keeps a stale k3s across
      # a pin bump. An override tag lacking the -cuda- marker isn't parseable, so
      # don't guess. Mirrors the Windows twin's Test-K3sVersionDrift.
      local _cudatag="${image##*k3s-cuda:}"
      _cudatag="${_cudatag%%@*}"
      case "$_cudatag" in
        *-cuda-*) running="${_cudatag%%-cuda-*}" ;;
        *) return 0 ;;
      esac
      ;;
    *) return 0 ;;   # unexpected image ref — don't guess
  esac
  [[ -z "$running" ]] && return 0
  if [[ "$running" != "$K8S_VERSION" ]]; then
    echo ""
    warn "The existing '$CLUSTER_NAME' cluster runs k3s '$running', not the validated pin '$K8S_VERSION'."
    hint "k3s version is fixed when the cluster is created — it can't be changed on a running cluster."
    # backend#2448 made this the COMMON case rather than the exception: moving the
    # pin 1.29.4 -> 1.36.3 marks every pre-existing cluster as drifted, and for
    # those operators neither "older/unpinned installer" nor "K8S_VERSION=latest"
    # is what happened — their cluster simply predates the pin move. Naming only
    # the two original causes would tell most readers something untrue about
    # their own machine.
    hint "Either this cluster predates the current pin, or it was created by an unpinned installer / with K8S_VERSION=latest (#547). To move"
    hint "onto the validated version, recreate it:"
    _recreate_cluster_hint
    hint "  (hostpath mode keeps your data under ${HOST_DATA_DIR:-your data dir}; node-local mode loses in-cluster data on recreate.)"
    echo ""
  fi
}

# k3d bakes proxy env into containers at create time; it cannot be added to a
# running cluster. For each proxy var set on the host, verify the existing
# cluster has it, and warn (with the recreate remedy) on drift. Authenticated
# proxies are now propagated like any other var (via _write_k3d_proxy_config),
# so there is no longer a separate '@' bucket. Silent no-op if Docker isn't
# running, the server container can't be inspected, or no proxy env is set.
_check_existing_cluster_proxy() {
  local var candidates=()
  for var in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    [[ -n "${!var:-}" ]] && candidates+=("$var")
  done
  [[ ${#candidates[@]} -eq 0 ]] && return 0

  local server_container="k3d-${CLUSTER_NAME}-server-0"
  local cluster_env
  # BOUNDED (client#984): same daemon, same hazard as the four sibling inspects in
  # this file that already carry TB_DOCKER_INSPECT_TIMEOUT. `|| return 0` keeps an
  # unreadable node a silent no-op, which is this check's documented behaviour.
  cluster_env=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "$server_container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$cluster_env" ]] && return 0

  local missing=()
  for var in "${candidates[@]}"; do  # set-u-safe: the empty-candidates check above returns first
    # Here-string (#680): `grep -Eq` stops at the first match, so echo can take
    # SIGPIPE and pipefail would report a variable as MISSING when it is present,
    # producing a spurious "cluster is missing proxy env" warning.
    grep -Eq "^${var}=" <<<"$cluster_env" || missing+=("$var")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    warn "Host has proxy env set, but the existing '$CLUSTER_NAME' cluster is missing: ${missing[*]}."  # set-u-safe: inside the non-empty check
    hint "k3d bakes proxy settings into containers at create time — they can't be added to a running cluster."
    hint "If image pulls fail or in-cluster traffic misroutes, recreate the cluster:"
    _recreate_cluster_hint
    echo ""
  fi
}

# CA trust, like proxy, is baked into the nodes at create time (the -v mount +
# --registry-config). If the operator sets a CA bundle but the cluster already
# exists WITHOUT it, a re-run reuses the cluster and the x509 pulls persist — so
# the "set the CA and re-run" remedy silently does nothing. Warn and point at
# recreate (Bugbot #424). The path mirrors _create_new_cluster's mount destination.
_check_existing_cluster_ca() {
  [[ -n "${TRACEBLOC_CA_BUNDLE:-}" || -n "${CURL_CA_BUNDLE:-}" ]] || return 0
  local server_container="k3d-${CLUSTER_NAME}-server-0"
  local mounts
  mounts=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "$server_container" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$mounts" ]] && return 0
  # Exact whole-line match (mounts is newline-separated destinations): a longer
  # path that merely embeds the CA path as a substring is NOT our mount. Mirrors
  # the PS anchored `(?m)^…\s*$` check (Bugbot #424).
  if ! grep -qxF '/etc/ssl/certs/tracebloc-mitm-ca.crt' <<<"$mounts"; then
    echo ""
    warn "A CA bundle is set (TRACEBLOC_CA_BUNDLE/CURL_CA_BUNDLE), but the existing '$CLUSTER_NAME' cluster was created without it."
    hint "k3d bakes CA trust into the nodes at create time — it can't be added to a running cluster."
    hint "If in-cluster image pulls fail x509, recreate the cluster so the CA is applied:"
    _recreate_cluster_hint
    echo ""
  fi
}

# When `k3d cluster create` fails, one cause on a TLS-inspecting network is the
# HOST Docker daemon hitting x509 while pulling k3d's OWN runtime images
# (rancher/k3s, k3d-tools, k3d-proxy) — a different surface than the in-node CA
# trust (#424), which only covers containerd INSIDE the nodes. The node CA mount
# can't fix the host daemon, and this failure happens before any node boots, so
# the post-create _diagnose_not_ready never sees it. Detect x509 in the create
# output and name it with a platform-specific remedy (#474). No-op unless the
# output actually shows a TLS-verification failure.
_host_ca_create_hint() {
  local out="$1"
  # Herestring, not a pipe: under `set -o pipefail`, `grep -q` closes the pipe on
  # first match, and for output past the ~64KB pipe buffer (reachable on the
  # timeout path, which passes the full logs) printf takes SIGPIPE → the pipeline
  # exits non-zero → `|| return 0` would bail even though x509 matched (reviewer).
  grep -qiE 'x509|certificate signed by unknown authority|tls: failed to verify' <<<"$out" || return 0
  echo ""
  warn "The Docker daemon couldn't pull k3d's runtime images — TLS verification failed (x509)."
  hint "k3d pulls rancher/k3s, k3d-tools and k3d-proxy with the HOST Docker daemon, which does"
  hint "not use the in-node CA trust (TRACEBLOC_CA_BUNDLE) this installer configures — the daemon"
  hint "itself has to trust your corporate CA:"
  if [[ "${OS:-}" == "Linux" ]]; then
    hint "  Native Docker — add the CA to the system trust store (use your distro's path):"
    hint "    Debian/Ubuntu: sudo cp <corporate-ca>.pem /usr/local/share/ca-certificates/tracebloc-corp-ca.crt && sudo update-ca-certificates"
    hint "    RHEL/Fedora:   sudo cp <corporate-ca>.pem /etc/pki/ca-trust/source/anchors/tracebloc-corp-ca.crt && sudo update-ca-trust"
    hint "    then restart Docker: sudo systemctl restart docker"
    hint "  Docker Desktop for Linux — the daemon runs in a VM: add the CA to the system trust"
    hint "    store as above, then restart Docker Desktop (it re-reads the host trust store on start)."
  else
    hint "  Docker Desktop (macOS): the daemon runs in a VM the installer can't reach. Add the CA"
    hint "    to the macOS keychain and set it to 'Always Trust', then restart Docker Desktop —"
    hint "    it reads the host keychain on start."
    hint "  Colima (headless macOS): the daemon runs in a Lima VM that does NOT read the keychain —"
    hint "    add the CA inside the VM ('colima ssh', copy the PEM into the VM's trust store and"
    hint "    refresh it), then 'colima restart'."
  fi
  hint "  Details: docs/INSTALL.md (\"TLS-inspecting network\") and https://docs.docker.com/."
  echo ""
}

# An externally-created cluster may bind its API to 0.0.0.0 rather than the
# 127.0.0.1 this installer uses. _merge_kubeconfig normalizes the kubeconfig
# (→127.0.0.1) so reuse still works, but we warn so the user understands their
# cluster differs and how to rebuild it loopback-bound if a TLS/HTTP proxy still
# intercepts external kubectl. Silent no-op if the serverlb can't be inspected.
_check_existing_cluster_bind() {
  local binds
  binds=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "k3d-${CLUSTER_NAME}-serverlb" \
    --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostIp}} {{end}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$binds" ]] && return 0
  if grep -qw '0\.0\.0\.0' <<<"$binds" && ! grep -qw '127\.0\.0\.1' <<<"$binds"; then
    echo ""
    warn "The existing '$CLUSTER_NAME' cluster binds its API to 0.0.0.0 (created outside this installer)."
    hint "This installer binds clusters to 127.0.0.1; behind a corporate proxy a 0.0.0.0 bind can be intercepted."
    hint "Your kubeconfig is normalized to 127.0.0.1 so reuse works. If kubectl is still intercepted, rebuild it:"
    _recreate_cluster_hint
    echo ""
  fi
}

# The image-GC drop-in is a create-time bind mount, so a cluster made before
# backend#2634 -- or by an older installer -- keeps the kubelet's stock 85/80
# thresholds forever, and a re-run used to print "Secure environment already
# running" without looking (Bugbot, Medium, on client#912). Every already-created
# edge is exactly the population this ticket is about.
#
# WARN, DO NOT REFUSE, and that is the deliberate difference from the dataset
# check above. A missing dataset mount puts customer data on ephemeral storage, so
# refusing is right there. A missing image-GC bound is the status quo everywhere
# today: erroring would turn every ordinary re-run on an existing cluster into a
# hard failure and strand operators mid-install. The remedy is a recreate at a
# time of their choosing, so this states the consequence and offers the hint.
#
# No-op when the node cannot be inspected -- consistent with its siblings, and the
# honest answer when the mount cannot be read at all.
_check_existing_cluster_kubelet_config() {
  local mounts
  # BOUNDED, because this now runs on the already-healthy fast paths (reviewer).
  # On the reuse path a wedged Docker was already stalling an install that had
  # nothing else to do; on a healthy re-run it would stall a machine that is
  # working, to print an advisory. Same bound its k3s sibling uses.
  mounts=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "k3d-${CLUSTER_NAME}-server-0" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$mounts" ]] && return 0
  if ! grep -qx "${TB_KUBELET_CONFIG_NODE_PATH}" <<<"$mounts"; then
    echo ""
    warn "The existing '$CLUSTER_NAME' cluster has no kubelet config mount, so its nodes keep the stock 85% image-GC threshold."
    hint "Training images are 2.7-11 GB each and floating tags leave the previous digest resident on every"
    hint "republish, so the node fills until garbage collection and disk-pressure eviction start DURING a"
    hint "training run. k3d bakes bind mounts in at create time, so this cannot be added to a running cluster."
    hint "The install will proceed. To bound the image store, recreate the cluster when convenient:"
    _recreate_cluster_hint
    echo ""
    return 0
  fi
  # backend#2460: the mount is there, but the FILE behind it may predate the node
  # reservation (every edge created between #2634 and this change). The kubelet
  # reads its config at start, so rewriting the host file in place would arm a
  # smaller allocatable on the node's next restart -- under pods that were sized
  # against the old one. Advise; do not rewrite. Only on a platform that HAS a
  # measured reservation: elsewhere the file could not carry one yet, and the
  # create path already says so. Silent when the file cannot be read -- "cannot
  # tell" must not read as "missing", the same rule the mounts check follows.
  _kubelet_reservation_measured "$(_kubelet_reservation_platform)" || return 0
  local cfg; cfg="$(_kubelet_config_path)"
  [[ -r "$cfg" ]] || return 0
  if ! grep -q '^kubeReserved:' "$cfg"; then
    echo ""
    warn "The existing '$CLUSTER_NAME' cluster's kubelet config carries no node reservation, so on its nodes allocatable still equals capacity."
    hint "The training envelope and jobs-manager's admission read allocatable as 'what a pod may have'; on this"
    hint "cluster it also contains the k3s server, containerd and the container runtime's own daemons. The"
    hint "install will proceed. To make allocatable honest, recreate the cluster when convenient:"
    _recreate_cluster_hint
    echo ""
  fi
}

# backend#743: the dataset bind mount (HOST_DATASET_DIR -> /tracebloc-data) is
# baked into the k3d nodes at create time (_create_new_cluster). k3d cannot add
# a bind mount to a RUNNING cluster, so re-using an existing cluster that lacks
# it would point the chart's `datasetPath: /tracebloc-data` PV at ephemeral
# in-node storage — datasets would silently land on disposable storage instead
# of the network export and vanish on a restart. Fail fast with the recreate
# remedy rather than installing a quietly-misrouted dataset volume. No-op when
# HOST_DATASET_DIR is unset or the node can't be inspected.
#
# (Reunited with its function: the image-GC advisory was inserted between the two,
# leaving "Fail fast with the recreate remedy" standing directly above a function
# that deliberately WARNS and continues. Someone would eventually have made the
# function match the comment and turned every ordinary re-run into a hard failure
# -- the outcome this change argues against at length. Reviewer, client#912.)
_check_existing_cluster_dataset_mount() {
  [[ -z "${HOST_DATASET_DIR:-}" ]] && return 0
  local mounts
  mounts=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "k3d-${CLUSTER_NAME}-server-0" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$mounts" ]] && return 0
  if ! grep -qx '/tracebloc-data' <<<"$mounts"; then
    echo ""
    warn "HOST_DATASET_DIR is set, but the existing '$CLUSTER_NAME' cluster has no /tracebloc-data bind mount."
    hint "k3d bakes bind mounts in at create time — they can't be added to a running cluster. Re-using this"
    hint "cluster would put datasets on ephemeral in-node storage (lost on a restart), not your network export."
    hint "Recreate the cluster so the dataset volume is bound (data under HOST_DATASET_DIR is untouched):"
    _recreate_cluster_hint
    echo ""
    error "Existing cluster is missing the dataset bind mount — refusing to install datasets onto ephemeral storage."
  fi
}

# The storage topology is baked into the cluster at create time and cannot be
# changed on a running cluster: hostpath mode bind-mounts HOST_DATA_DIR at
# /tracebloc and disables k3s local-storage; node-local mode does neither (it
# keeps local-storage so the `local-path` StorageClass provisions in-node). The
# generated chart values must match — reusing a cluster built for the OTHER mode
# silently breaks storage: a node-local install onto a hostpath cluster asks for
# a `local-path` StorageClass that was disabled (PVCs stay Pending), and a
# hostpath install onto a node-local cluster points hostPath PVs at an unmounted
# /tracebloc (datasets on ephemeral in-node storage). The /tracebloc bind mount
# is the discriminator: present ⟺ hostpath cluster. Fail fast with the recreate
# remedy. No-op when the node can't be inspected.
_check_existing_cluster_storage_mode() {
  local mounts
  mounts=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "k3d-${CLUSTER_NAME}-server-0" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$mounts" ]] && return 0

  local cluster_is_hostpath=false
  grep -qx '/tracebloc' <<<"$mounts" && cluster_is_hostpath=true
  local want="${TB_STORAGE_MODE:-node-local}"

  if [[ "$want" == "node-local" && "$cluster_is_hostpath" == true ]]; then
    echo ""
    # After the D15 flip (client#456) this branch fires on an unmodified re-run of
    # every pre-existing hostpath install, not just someone who asked for
    # node-local — so name the source and lead with the keep-your-cluster remedy
    # (set hostpath), not a recreate they never asked for (Bugbot High + review).
    if [[ "${TB_STORAGE_MODE_SOURCE:-default}" == "explicit" ]]; then
      warn "TRACEBLOC_STORAGE_MODE=node-local, but the existing '$CLUSTER_NAME' cluster was built for hostpath storage."
    else
      warn "node-local is the default now, but the existing '$CLUSTER_NAME' cluster was built for hostpath storage."
    fi
    hint "That cluster disabled k3s local-storage, so the 'local-path' StorageClass node-local needs does not exist — PVCs would stay Pending."
    hint "To keep using your existing hostpath cluster, just re-run with the old mode — no recreate needed:"
    hint "  TRACEBLOC_STORAGE_MODE=hostpath  re-run this installer."
    hint "Or, to move this cluster to node-local (storage topology is fixed at create time), recreate it:"
    _recreate_cluster_hint "TRACEBLOC_STORAGE_MODE=node-local  "
    echo ""
    error "Existing cluster's storage topology (hostpath) does not match node-local — set TRACEBLOC_STORAGE_MODE=hostpath to keep it, or recreate for node-local."
  elif [[ "$want" == "hostpath" && "$cluster_is_hostpath" == false ]]; then
    echo ""
    warn "TRACEBLOC_STORAGE_MODE=hostpath, but the existing '$CLUSTER_NAME' cluster was built for node-local storage."
    hint "That cluster has no /tracebloc bind mount, so hostPath volumes would land on ephemeral in-node storage"
    hint "(lost on 'cluster delete'), not ~/.tracebloc. Storage topology is fixed at create time; recreate to switch:"
    _recreate_cluster_hint
    echo ""
    error "Existing cluster's storage topology (node-local) does not match TRACEBLOC_STORAGE_MODE=hostpath — refusing to install datasets onto ephemeral storage."
  fi
}

# ── GPU node image (client#835) ──────────────────────────────────────────────
# The stock rancher/k3s node image is Alpine-based and ships NO NVIDIA container
# runtime, so GPU pods can never schedule on it — the node advertises 0
# nvidia.com/gpu even after the host Docker runtime is set and the device plugin
# is deployed. docker/k3s-cuda rebuilds the SAME pinned k3s on a CUDA base with the
# NVIDIA Container Toolkit + the `nvidia` RuntimeClass baked in, published to
# ghcr.io/tracebloc/k3s-cuda by .github/workflows/build-k3s-cuda.yaml. This is the
# Linux twin of the resolution the Windows installer already does
# (install-k8s.ps1's $K3S_CUDA_IMAGE): a full override wins, else derive the tag —
# which encodes BOTH the k3s pin and the CUDA base so a K8S_VERSION bump can never
# reuse a stale image (check-facts.sh enforces the sync) — re-homed onto a private
# mirror when one is configured (#585) or ghcr.io otherwise.
_gpu_node_image() {
  if [[ -n "${TRACEBLOC_K3S_CUDA_IMAGE:-}" ]]; then
    printf '%s' "$TRACEBLOC_K3S_CUDA_IMAGE"; return 0
  fi
  local repo="tracebloc/k3s-cuda:${K8S_VERSION}-cuda-${TB_CUDA_BASE_TAG}"
  # BARE host prefix: strip a pasted scheme AND any trailing slash(es), so a mirror
  # given as https://mirror.corp/ yields <host>/repo, not <host>//repo — the double
  # slash makes the host pre-pull (docker pull) fail and drops a credentialed GPU
  # install to CPU (Bugbot). Matches the Windows twin's `-replace '/+$',''`.
  local mirror="${TRACEBLOC_IMAGE_REGISTRY:-}"
  if [[ -n "$mirror" ]]; then
    local host="${mirror#*://}"
    while [[ "$host" == */ ]]; do host="${host%/}"; done
    printf '%s/%s' "$host" "$repo"
  else
    # backend#1867 pins the default GPU image, but the digest is NOT put in this ref.
    # A ref carrying BOTH a tag and a digest is a lie waiting to happen: docker resolves
    # it by DIGEST and never checks the tag, while everything downstream reads the TAG.
    # Measured on ghcr.io — `…/k3s-cuda:v9.9.9-k3s1-cuda-does-not-exist@sha256:<an
    # existing digest>` resolves SUCCESSFULLY, while the same tag alone is `not found`.
    # So a tag@digest default would turn a K8S_VERSION bump with no rebuild from an
    # honest 404 (the client#835 CPU fallback) into silently running the OLD k3s, with
    # _check_existing_cluster_k8s_version reading the new tag off the ref and staying
    # quiet — a worse failure than the one the pin was added to prevent (Bugbot High on
    # client#961). Pulling by TAG keeps that 404 honest.
    #
    # The pin is therefore enforced where it actually decides what runs: the pre-pull in
    # _create_new_cluster asserts that this tag resolved to facts.env's K3S_CUDA_DIGEST,
    # and drops to CPU if it did not. A republished tag can then never run unreviewed
    # bytes, which is what backend#1867 asked for, without any ref asserting a version
    # its content does not have.
    printf 'ghcr.io/%s' "$repo"
  fi
}

# Which host does `docker login` target for an image ref? Docker treats the first
# path segment as a REGISTRY only when it has a '.'/':' or is 'localhost'; otherwise
# the ref is a Docker Hub repo (owner/name) and login must target docker.io, not the
# owner segment — else creds for a private image go to the wrong endpoint (client#835).
# Mirrors the Windows twin's Get-RegistryHost.
_registry_host_for() {
  local first="${1%%/*}"
  case "$first" in
    *.*|*:*|localhost) printf '%s' "$first" ;;
    *)                 printf 'docker.io' ;;
  esac
}

# Can a node running $1 (a `docker inspect …Config.Image` value) schedule GPU pods?
# The default GPU image name carries `k3s-cuda:`, BUT an operator can override it
# (TRACEBLOC_K3S_CUDA_IMAGE) to a renamed / digest-only mirror ref that doesn't —
# so also accept an EXACT match against the image this run is configured to use.
# A stock rancher/k3s image — or an unreadable/empty one — is not GPU-capable and
# must fail safe to CPU rather than strand jobs Pending. Pure (string in, status
# out) so it is unit-testable without a live cluster. Mirrors the Windows twin's
# Test-NodeImageGpuCapable.
#
# NO fail-open on empty (the promise above): an empty/unreadable image returns 1 at
# the `-n` guard, before the exact-match tail — and even if it didn't, _gpu_node_image
# ALWAYS prints a non-empty host+repo (ghcr.io/… even with the pins unset), so the
# tail can never degrade into an empty==empty match (Asad review, client#835).
_node_image_gpu_capable() {
  local image="$1"
  [[ -n "$image" ]] || return 1
  case "$image" in *k3s-cuda:*) return 0 ;; esac
  [[ "$image" == "$(_gpu_node_image)" ]]
}

# Reconcile the GPU decision against a REUSED cluster (client#835). The GPU gate
# sets TRACEBLOC_GPU_WIRED=1 (hence --gpus=all) and the chart requests a GPU BEFORE we know
# whether this run creates the cluster or reuses one. GPU capability is fixed at
# create time (baked into the node image); it cannot be bolted onto a running
# cluster. A cluster first built in CPU mode — or by an installer predating #835 —
# has a stock rancher/k3s node (no NVIDIA runtime, no `nvidia` RuntimeClass), so
# writing GPU values against it strands every job Pending on a node that advertises
# 0 GPUs: exactly the failure #835 removes. So when GPU was requested but the reused
# node isn't GPU-capable, DISABLE GPU for this run (CPU fallback stays safe) and
# tell the user to recreate the cluster to get GPU. Bounded docker inspect
# (installer rule). No-op when GPU wasn't requested or the node can't be inspected
# (don't guess CPU on a transient probe failure — leave the request as-is).
_check_existing_cluster_gpu() {
  _gpu_wired || return 0
  local server_container="k3d-${CLUSTER_NAME}-server-0"
  local image
  image=$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "$server_container" --format '{{.Config.Image}}' 2>/dev/null) || return 0
  [[ -z "$image" ]] && return 0
  _node_image_gpu_capable "$image" && return 0
  # CPU-only node → drop the GPU request so the chart writes CPU values.
  TRACEBLOC_GPU_WIRED=0
  echo ""
  warn "GPU detected, but the existing '$CLUSTER_NAME' cluster runs a CPU-only node — running CPU mode so jobs aren't stranded Pending."
  hint "The k3s node image (and thus GPU capability) is fixed when the cluster is created; it can't be added to a running cluster."
  hint "To enable GPU on this machine, recreate the cluster:"
  _recreate_cluster_hint
  hint "  (hostpath mode keeps your data under ${HOST_DATA_DIR:-your data dir}; node-local mode loses in-cluster data on recreate.)"
  echo ""
}

# Fast-path GPU consistency (client#835, Bugbot High). The HEALTHY fast path
# (assess.sh) hands off and exits BEFORE the create/reuse GPU reconcile above and
# before detect_gpu, so a cluster whose LIVE release requests a GPU while its node
# advertises NONE — a pre-#835 install that wrote GPU chart values onto a stock
# rancher/k3s node, or a k3s-cuda node whose device plugin died — would keep every
# GPU job Pending while the control plane looks healthy, with no signal. GPU_VENDOR
# isn't known on this path, so ask the LIVE cluster instead: does it request an
# NVIDIA GPU (the k3s-cuda node image is NVIDIA-only; AMD runs on stock rancher/k3s)
# its node can't schedule? Warn with the recreate remedy (non-fatal; the client is up).
# Mirrors the Windows twin's Test-HealthyClusterGpuConsistent. Self-contained + jq-
# free so it needs no other lib. Bounded (macOS-safe via the cluster-info gate
# below); silent no-op when it can't tell (no helm/kubectl, API unreachable, or
# nothing requests a GPU).
_check_healthy_cluster_gpu_consistent() {
  has helm && has kubectl || return 0
  # macOS bound (backend#2685). helm has NO --request-timeout, and until client-dev#1357
  # `_bounded` ran the BARE command on a stock Mac (no timeout/gtimeout there), so the
  # `helm list`/`helm get values` below could hang a healthy re-run against a wedged
  # kube-apiserver. They are bounded now, but a dead API would still cost each its
  # full helm budget, so they stay gated on a SELF-bounding kubectl reachability probe (--request-timeout=5s is client-side and
  # coreutils-free); an unreachable API just means we can't tell, which is already this
  # guard's silent no-op. Same cluster-info gate diagnose.sh puts in front of its own
  # unbounded helm calls. (The kubectl get nodes + docker inspect further down both
  # carry their own bound — --request-timeout=5s, and _bounded matching detect_gpu's
  # sibling inspect at ~L912 — and are reached only after this probe proves the docker-
  # hosted API answers, so the daemon is live by the time the inspect runs.)
  kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 || return 0
  local list rel ns vals found_req=0
  # NAME + NAMESPACE are the first two columns (jq-free, mirrors detect_installed_client).
  # Release name == namespace for a tracebloc install (helm upgrade --install "$TB_NAMESPACE").
  # Full status set (#554 house rule): --deployed --failed --pending --uninstalling,
  # so a release wedged in a pending-*/uninstalling state (which may still request a
  # GPU) is never invisible to this check — same enumeration detect_installed_client uses.
  list="$(_bounded "${TB_HELM_LIST_TIMEOUT:-20}" helm list -A --deployed --failed --pending --uninstalling 2>/dev/null)" || return 0
  [[ -z "$list" ]] && return 0
  # Capture values IN-MEMORY (no temp file): a mktemp failure must not silently skip
  # the only place this mismatch is surfaced (Bugbot). here-string, not a pipe, so
  # grep -q closing early can't SIGPIPE a producer.
  while read -r rel ns _; do
    [[ -z "$rel" || "$rel" == "NAME" ]] && continue
    if vals="$(_bounded "${TB_HELM_VALUES_TIMEOUT:-20}" helm get values "$rel" -n "$ns" 2>/dev/null)"; then
      # Specifically an NVIDIA request (GPU_REQUESTS: "nvidia.com/gpu…"). This guard is
      # about the k3s-cuda node image, which ONLY NVIDIA uses — a healthy AMD install
      # legitimately requests amd.com/gpu on a stock rancher/k3s node, so matching any
      # non-empty request here would falsely warn every AMD re-run to recreate a
      # working cluster (Bugbot). amd.com/gpu and "" both correctly don't match.
      if grep -Eq '^[[:space:]]*GPU_REQUESTS:[[:space:]]*"?nvidia\.com/gpu' <<<"$vals"; then found_req=1; break; fi
    fi
  done <<<"$list"
  (( found_req )) || return 0   # no NVIDIA GPU request → not this guard's concern

  # It requests a GPU. Does the node ACTUALLY advertise one? A CUDA node with a dead
  # device plugin still advertises 0, so check allocatable directly — the same
  # authoritative signal verify_gpu uses. Unreadable/empty → treat as none.
  local alloc
  alloc="$(_bounded "${TB_KUBECTL_PROBE_TIMEOUT:-10}" kubectl get nodes \
            -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' \
            --request-timeout=5s 2>/dev/null || true)"
  [[ "$alloc" =~ [1-9] ]] && return 0   # a GPU is live → consistent

  # No GPU advertised — but the REMEDY depends on WHY (Bugbot). A stock (pre-#835)
  # node image is fixed at create time, so recreate IS the fix. A GPU-CAPABLE node
  # advertising 0 is a device-plugin/CDI problem — recreate would NOT help — so don't
  # give recreate advice there; leave it to the plugin rollout (mirrors the Windows
  # twin, which checks the node image). Only warn recreate when the image is CONFIRMED
  # stock; stay quiet when it's capable OR unreadable (don't guess).
  local image
  image="$(_bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect "k3d-${CLUSTER_NAME}-server-0" --format '{{.Config.Image}}' 2>/dev/null)" || image=""
  if [[ -z "$image" ]] || _node_image_gpu_capable "$image"; then
    log "Healthy cluster requests a GPU but the node advertises none; node image is ${image:-unreadable} — a device-plugin/CDI issue, not a recreate case; leaving it to the plugin rollout."
    return 0
  fi
  echo ""
  warn "The '$CLUSTER_NAME' cluster requests a GPU for jobs, but its node is a stock CPU-only image (${image}) — GPU jobs will sit Pending."
  hint "GPU capability is fixed at create time and can't be added to a running cluster. Recreate it to enable GPU:"
  _recreate_cluster_hint
  hint "  (hostpath mode keeps your data under ${HOST_DATA_DIR:-your data dir}; node-local mode loses in-cluster data on recreate.)"
  echo ""
}

# Generate the native NVIDIA CDI spec INSIDE each GPU node (client#835). The
# docker/k3s-cuda image sets nvidia-container-runtime to CDI mode, so in-node
# containerd injects a GPU into a pod only from a CDI spec — and the image's boot
# drop-in generates one only on WSL2 (/dev/dxg). On native Linux no spec exists, so
# even with the runtime present a GPU pod gets nothing and the NVML device plugin
# (which runs under the `nvidia` RuntimeClass) can't enumerate GPUs → the node never
# advertises nvidia.com/gpu. We generate it here, from the host, right after the
# nodes are up (their /dev/nvidia* are present via --gpus=all): `nvidia-ctk cdi
# generate` in its default (auto→nvml) mode writes /etc/cdi/nvidia.yaml, which
# persists in the node's writable layer across restarts and is regenerated on any
# recreate. The SPEC'S PRESENCE is the authority, never the generate exit code:
# `nvidia-ctk` can exit 0 having written nothing, and on a REUSED cluster a prior
# install's /etc/cdi/nvidia.yaml already makes the node GPU-capable — so a transient
# regeneration failure must not tear that down (Bugbot High). Only when NO node has
# a usable spec do we fall CLOSED to CPU (TRACEBLOC_GPU_WIRED=0) so the chart doesn't
# advertise a GPU pods can't use — the same standard the Windows CDI path applies.
# And a docker-ps that can't LIST the nodes is "cannot tell", not "no GPU": leave
# the request as-is rather than guess CPU on a probe failure (mirrors
# _check_existing_cluster_gpu). Bounded; best-effort per node.
_generate_node_cdi_specs() {
  _gpu_wired || return 0
  local role out st node any_ok=0 listed_ok=0
  local nodes=""
  for role in server agent; do
    st=0
    out=$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker ps \
            --filter "label=k3d.cluster=${CLUSTER_NAME}" \
            --filter "label=k3d.role=${role}" \
            --format '{{.Names}}' 2>/dev/null) || st=$?
    if (( st == 0 )); then
      listed_ok=1
      [[ -n "$out" ]] && nodes+="${out}"$'\n'
    fi
  done
  # Couldn't enumerate nodes at all (docker wedged/errored for every role) → don't
  # guess CPU; a pre-existing spec may well be in place. Leave the request untouched.
  if (( ! listed_ok )); then
    warn "Couldn't list cluster nodes to set up the GPU CDI spec — leaving the GPU request as-is; if GPU pods stay Pending, re-run."
    return 0
  fi
  for node in $nodes; do
    # (Re)generate best-effort — a tool that exits 0 having written nothing, or a
    # transient failure, must NOT decide the outcome. /etc/cdi is where containerd's
    # nvidia runtime reads specs; create it first (the CUDA base may not ship it).
    _bounded "${TB_GPU_CDI_TIMEOUT:-60}" docker exec "$node" \
      sh -c 'mkdir -p /etc/cdi && nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    # Presence is the authority: a spec written now OR by a prior install counts.
    if _bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker exec "$node" \
         test -s /etc/cdi/nvidia.yaml 2>/dev/null; then
      any_ok=1
      log "NVIDIA CDI spec present on node '${node}' (/etc/cdi/nvidia.yaml)."
    else
      warn "No usable NVIDIA CDI spec on node '${node}' — pods on it won't be able to use the GPU."
    fi
  done
  if (( ! any_ok )); then
    TRACEBLOC_GPU_WIRED=0
    warn "No cluster node has a usable NVIDIA CDI spec — running CPU mode so GPU jobs aren't stranded Pending."
    hint "Check the NVIDIA driver + 'docker run --rm --gpus all ${TB_CUDA_BASE_TAG:+nvidia/cuda:$TB_CUDA_BASE_TAG} nvidia-smi' works on this host."
    # GPU wiring is fixed at create time and this CPU cluster now looks healthy, so a
    # plain re-run fast-paths and can't retry GPU (Bugbot) — recreate to enable it.
    hint "Then recreate the cluster to enable GPU (a plain re-run won't retry it):"
    _recreate_cluster_hint
  fi
}

# _k3d_node_counts — settle SERVERS/AGENTS, k3d's --servers/--agents, right before
# the one `k3d cluster create` that reads them. They are k3d node counts and
# nothing else, so the defaults, the node-local forcing and the validation live
# here rather than in common.sh, where every substrate's code would read them.
#
# C1: local-path is RWO + WaitForFirstConsumer and provisions on a single node,
# but the shared data PVC is mounted by jobs-manager-spawned Jobs that could
# schedule on another node with no volume. So node-local forces single-node —
# and that means BOTH agents=0 AND servers=1: unlike a full k8s control plane,
# k3s server nodes are schedulable, so SERVERS>1 still yields multiple nodes the
# data PVC can't follow. Forcing agents=0 alone would leave that hole open. The
# forcing runs before the validation, as it did when both lived in common.sh.
#
# MORE THAN ONE SERVER OR AGENT IS REFUSED (backend#3536; Lukas, 2026-09-09:
# close the reachable path before the uncalled sizing code goes). Every k3d node
# is a container on this one machine and none is given a CPU or memory cap, so
# each reports the WHOLE machine as its capacity and the scheduler counts the
# machine once per node (backend#2221). The format checks run first, so a
# non-integer is named as one; the refusal compares strings, so no value can
# overflow it. install-k8s.ps1's Confirm-Config is the twin.
#
# ONE NODE BY DEFAULT ON HOSTPATH TOO (tracebloc/client-dev#1418). The default
# used to be one server plus one agent: two nodes, so the machine's CPU and memory
# were counted twice on every hostpath install that set nothing. AGENTS now
# defaults to 0. An explicit AGENTS=1 is still accepted, and
# it warns because it is exactly that double count. node-local forces 0 before
# the check, so the warning only ever reaches hostpath.
_k3d_node_counts() {
  SERVERS="${SERVERS:-1}"
  AGENTS="${AGENTS:-0}"
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    AGENTS=0
    SERVERS=1
  fi
  [[ "$SERVERS" =~ ^[1-9][0-9]*$ ]] || error "SERVERS must be a positive integer >= 1 (got '$SERVERS')"
  [[ "$AGENTS"  =~ ^[0-9]+$ ]]     || error "AGENTS must be a non-negative integer (got '$AGENTS')"
  [[ "$SERVERS" == 1 ]]        || error "SERVERS=$SERVERS is not supported: every k3d node reports this whole machine as its own capacity, so each extra node makes Kubernetes count the same CPU and memory again. Use one server: unset TRACEBLOC_SERVERS (and the older SERVERS)."
  [[ "$AGENTS" =~ ^0*[01]$ ]]  || error "AGENTS=$AGENTS is not supported: every k3d node reports this whole machine as its own capacity, so each extra node makes Kubernetes count the same CPU and memory again. Set TRACEBLOC_AGENTS to 0 (one node) or 1."
  if [[ "$AGENTS" =~ ^0*1$ ]]; then
    warn "AGENTS=$AGENTS adds a second k3d node. Both nodes report this whole machine as their capacity, so Kubernetes counts its CPU and memory twice and can schedule more than the machine holds. Unset TRACEBLOC_AGENTS (and the older AGENTS) for one node."
  fi
}

_create_new_cluster() {
  _k3d_node_counts

  # REFUSE AN UNFITTABLE HOST BEFORE ANYTHING EXISTS (backend#3535). The fit that
  # decides whether a training run can schedule beside the platform used to run
  # only at values generation -- after the `k3d cluster create` below -- so a
  # host it refused was left holding an empty cluster. The estimate asks the
  # same rule first; guarded because cluster.sh can be sourced without
  # install-client-helm.sh (the e2e harness).
  if declare -F _precreate_fit_gate >/dev/null 2>&1; then _precreate_fit_gate; fi

  # The tracebloc client is outbound-only: jobs-manager + pods-monitor dial out
  # to the platform, and every in-cluster Service is ClusterIP — mysql-client,
  # jobs-manager, requests-proxy-service and egress-proxy-service. (This comment
  # claimed "the only in-cluster Service (mysql-client)" until the chart was
  # counted: there are four, three of them explicitly `type: ClusterIP` and
  # mysql-client's by omission. The conclusion still holds — not one is a
  # LoadBalancer and the chart renders no Ingress — but the premise was wrong.)
  #
  # So we disable k3s components that exist solely to handle inbound traffic
  # or duplicate chart-provided resources:
  #   traefik        — no Ingress resources in the chart
  #   servicelb      — no LoadBalancer Services
  #   local-storage  — chart ships its own per-release StorageClass
  #
  # metrics-server is KEPT, and this is load-bearing rather than tidiness. Do not
  # add it to the list above as a footprint saving:
  #
  #   * At install time, client/templates/resource-monitor-daemonset.yaml
  #     `lookup`s the v1beta1.metrics.k8s.io APIService and `fail`s the release
  #     when it is absent. That aborts this install AND every subsequent
  #     auto-upgrade tick, since each one re-renders the same template.
  #   * If the API goes away AFTER install, the failure is silent, not loud.
  #     client-runtime's Node-deploy/resource_monitor.py builds NodeUtilisation
  #     as the first statement inside its `while True:` body, and that
  #     constructor reads metrics.k8s.io outside any try. The loop's handler
  #     catches Exception, logs and sleeps 5 s, and the DaemonSet declares no
  #     liveness or readiness probe — so the pod stays Running and looks healthy
  #     while send_heartbeat is never reached. Node telemetry just stops.
  #
  # (An earlier version of this comment said the DaemonSet "crash-loops with
  # 404s". It does not, and that mattered: a crash-loop is the failure you would
  # have noticed. Nobody watching pod restarts would ever see this one.)
  #
  # Note the flag and the RACE are two different problems, both about this same
  # APIService. #553/#757 added a bounded wait to each installer
  # (_wait_for_metrics_apiservice here, Wait-MetricsApiService on Windows, budget
  # stamped in scripts/spec/facts.env as METRICS_WAIT_TIMEOUT) because k3s applies
  # its bundled metrics-server slightly AFTER the API server reports ready, so a
  # fast host could render the chart inside that window. That wait falls through
  # non-fatally, by design — so disabling the component here is not something it
  # rescues: the wait would simply burn its whole budget and hand the install to
  # the chart's `fail`.
  #
  # Guarded by scripts/tests/cluster.bats (the exact disable set per storage
  # mode) and scripts/tests/k3s-components-agreement.sh (both installers agree,
  # and the chart coupling above still exists).
  K3D_ARGS=(
    cluster create "$CLUSTER_NAME"
    --servers "$SERVERS"
    --agents  "$AGENTS"
    --api-port 127.0.0.1:6550
  )
  # hostpath model: bind-mount ~/.tracebloc into every node and disable k3s
  # local-storage (the chart ships its own `manual` StorageClass for the
  # hostPath PVs). node-local model (RFC-0003 Option C): no host bind-mount, and
  # KEEP k3s local-storage so its `local-path` StorageClass provisions the
  # dataset volumes inside the node — data then dies with the cluster.
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    K3D_ARGS+=(
      --k3s-arg "--disable=traefik@server:*"
      --k3s-arg "--disable=servicelb@server:*"
    )
  else
    K3D_ARGS+=(
      -v "${HOST_DATA_DIR}:/tracebloc@all"
      --k3s-arg "--disable=traefik@server:*"
      --k3s-arg "--disable=servicelb@server:*"
      --k3s-arg "--disable=local-storage@server:*"
    )
  fi
  # cgroup v1 hosts (backend#2422). Kubernetes 1.35 flipped the kubelet's
  # `failCgroupV1` default to TRUE, so from k3s 1.35 the kubelet REFUSES TO START
  # on a cgroup v1 or hybrid host. That is not an exotic case for us: WSL2
  # defaults to hybrid cgroups, and RHEL 8 / CentOS 7 / Ubuntu 20.04 are cgroup v1
  # by default — i.e. the Windows laptops and hospital Linux boxes we install on.
  # k3s never sets the field, so the upstream default applies, and k3s documents
  # none of this: a customer would see only a bare upstream kubelet message with
  # no hint that an override exists.
  #
  # Set it proactively so the refusal is never reached. Verified on a real
  # v1.36.3+k3s1 cluster: k3s passes it through verbatim (`Running kubelet …
  # --fail-cgroupv1=false …`) and the node comes up Ready with no parse complaint.
  # On a cgroup v2 host — every current install — it is a no-op.
  #
  # GATED, and the gate is load-bearing: `--fail-cgroupv1` was ADDED in kubelet
  # 1.31. Passing it to a pre-1.31 kubelet is an unknown flag
  # and the kubelet would fail to start — i.e. an ungated version of this line
  # breaks every install. Note the `#v` strip: _version_lt reads a leading "v" as
  # 0 and would invert the comparison (see common.sh).
  #
  # `latest` is handled EXPLICITLY rather than by parse accident (#806 review).
  # It is the unsupported opt-out (#547) where k3d chooses the k3s version and we
  # cannot read it, so the choice is between a flag that is harmless from 1.31 and
  # a refusal that is fatal from 1.35 — and `latest` is the very path that produced
  # the v1.35.5 drift incident. `K3D_VERSION` is pinned at v5.9.0, whose default
  # k3s is 1.32 (above the flag's introduction, below the refusal), so emitting is
  # safe today and becomes correct the moment k3d's default crosses 1.35.
  #
  # Everything else non-numeric — empty, a digest-only pin — still skips, because
  # _version_lt reads a non-numeric component as 0 and therefore as below 1.31.
  # Empty only occurs in tests: common.sh defaults K8S_VERSION to the pin.
  # `@all`, NOT `@server:*`. AGENTS defaults to 0 now (_k3d_node_counts), but an
  # explicit AGENTS=1 on hostpath still creates an agent, and an agent runs a
  # kubelet too — scoping this to the server would leave the agent kubelet refusing
  # to start on a cgroup v1 host, so `--wait` fails or the cluster sits half-ready:
  # the exact refusal this block exists to prevent (#806 Bugbot, High). The
  # `--disable=` args above are `@server:*` because addon deployment is a
  # server-only concern; a kubelet arg is not, and the two must not be copied from
  # each other. `--kubelet-arg` is accepted by both `k3s server` and `k3s agent`.
  if [[ "${K8S_VERSION}" == "latest" ]] || ! _version_lt "${K8S_VERSION#v}" "1.31.0"; then
    K3D_ARGS+=(--k3s-arg "--kubelet-arg=fail-cgroupv1=false@all")
  fi

  # Image GC (backend#2634) and the node reservation (backend#2460), one file.
  # HARD-FAIL rather than continue: a silent skip leaves every edge on the stock
  # 85/80 thresholds -- the exact unbounded image store #2634 is about -- while
  # the install reports success, and nothing downstream can tell the difference.
  # Same posture as the CA bundle above, for the same reason.
  local _kubelet_cfg
  _kubelet_cfg="$(_write_kubelet_config)" \
    || error "Couldn't write the kubelet config to $(_kubelet_config_path) (disk full, the directory not writable, or a broken reservation embed -- see the line above). Re-run; without it the node would keep the stock 85% image-GC threshold and fill up during training."
  # backend#2460: a platform nobody has measured gets NO reservation, and the
  # operator is told rather than handed a number borrowed from another platform
  # (cluster.sh, said once per run).
  _kubelet_reservation_warn_unmeasured
  # `@all`, NOT `@server:*`: an agent runs a kubelet and pulls the same 2.7-11 GB
  # task images, so a server-only drop-in would leave agents unbounded -- the same
  # reasoning the cgroupv1 arg above records.
  K3D_ARGS+=(-v "${_kubelet_cfg}:${TB_KUBELET_CONFIG_NODE_PATH}@all")
  K3D_ARGS+=(--k3s-arg "--kubelet-arg=config=${TB_KUBELET_CONFIG_NODE_PATH}@all")

  # Bounded create (#426): --wait alone has no deadline, so a stalled image
  # pull (rate-limited registry, TLS-intercepting proxy) hangs the create
  # forever. k3d's own --timeout aborts it with a real error instead; the env
  # knob matches the Windows installer's TB_CREATE_TIMEOUT_MIN.
  local _create_timeout_min
  _create_timeout_min="$(tb_minutes_or "${TB_CREATE_TIMEOUT_MIN:-}" 15)"
  K3D_ARGS+=(--wait --timeout "${_create_timeout_min}m")

  # backend#743: bind-mount the customer's dataset volume (which may be a network
  # mount) at a DISTINCT cluster path so the chart's dataset PV can point there
  # while mysql + logs stay on the local /tracebloc tree. No-op when unset.
  [[ -n "${HOST_DATASET_DIR:-}" ]] && K3D_ARGS+=(-v "${HOST_DATASET_DIR}:/tracebloc-data@all")

  # GPU image pullability → CPU fallback (client#835, Bugbot High). Handing k3d a
  # k3s-cuda --image it can't pull or that doesn't run k3s (ghcr.io blocked, the tag
  # not yet published for this pin, a private registry needing auth, or a broken
  # override/mirror copy) would make `k3d cluster create` HARD-FAIL — regressing a
  # host that could still run CPU-only into a failed install. So on the HOST daemon:
  # log into a private registry (creds the operator set apply HERE — the node image
  # is pulled by the host daemon, not the kubelet, so a chart imagePullSecret can't
  # help), pre-pull, then verify the image actually runs k3s; on any failure drop the
  # GPU request (CPU fallback) with an actionable reason instead of aborting. k3d
  # reuses the cached image, so it is not wasted work. Mirrors the Windows twin's
  # Connect-GpuRegistry + Confirm-GpuImagePullable + Test-GpuImageRunsK3s. Skipped
  # for 'latest' (handled below) and the unit harness (empty K8S_VERSION);
  # TRACEBLOC_SKIP_GPU_IMAGE_PREPULL bypasses it (TB_SKIP_GPU_IMAGE_PREPULL
  # until remove_by 2026-12-31; both are read).
  if _gpu_wired && [[ -n "$K8S_VERSION" && "$K8S_VERSION" != "latest" \
      && -z "${TRACEBLOC_SKIP_GPU_IMAGE_PREPULL:-}" && -z "${TB_SKIP_GPU_IMAGE_PREPULL:-}" ]]; then
    local _prepull_image _prepull_min _gpu_ok=1 _gpu_fail_reason="" _pull_log="" _got_digest=""
    _prepull_image="$(_gpu_node_image)"
    _prepull_min="$(tb_minutes_or "${TB_GPU_PULL_TIMEOUT_MIN:-}" 15)"
    # Authenticate the host daemon to the image's registry first (mirrors
    # Connect-GpuRegistry): --password-stdin so the secret never lands in argv/ps.
    # Best-effort — a public image needs no login, and a failed login still tries an
    # unauthenticated pull before the CPU fallback below.
    if [[ -n "${TRACEBLOC_REGISTRY_USERNAME:-}" && -n "${TRACEBLOC_REGISTRY_PASSWORD:-}" ]]; then
      local _reg_host; _reg_host="$(_registry_host_for "$_prepull_image")"
      printf '%s' "${TRACEBLOC_REGISTRY_PASSWORD}" \
        | _bounded "${TB_DOCKER_LOGIN_TIMEOUT:-30}" docker login "$_reg_host" \
            --username "${TRACEBLOC_REGISTRY_USERNAME}" --password-stdin >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || warn "docker login to ${_reg_host} for the GPU image didn't succeed — trying an unauthenticated pull."
    fi
    # Capture the pull rather than sending it straight to LOG_FILE: the digest the tag
    # resolved to is only readable from `docker pull`'s own output on this host's image
    # store. Measured here: RepoDigests comes back EMPTY under the containerd image
    # store and `docker images --digests` prints nothing, so neither is usable; the
    # `Digest:` line is, and it still prints on a cache hit. Appended to LOG_FILE
    # below, so the log is unchanged.
    _pull_log="$(mktemp "${TMPDIR:-/tmp}/tracebloc-gpu-pull-XXXXXX" 2>/dev/null || echo /dev/null)"
    ( docker pull "$_prepull_image" >"$_pull_log" 2>&1 ) &
    spin "$!" "Fetching the GPU-capable runtime (${_prepull_image##*/})…" "$(( _prepull_min * 60 ))" || _gpu_ok=0
    [[ "$_pull_log" != /dev/null ]] && cat "$_pull_log" >>"${LOG_FILE:-/dev/null}" 2>/dev/null
    # Assert the tag resolved to the PINNED digest (backend#1867). Only for our own ghcr
    # default: an operator's TRACEBLOC_K3S_CUDA_IMAGE, or a mirror copy that legitimately
    # re-pushes under its own digest, has no pin of ours to compare against.
    if (( _gpu_ok )) && [[ -n "${TB_K3S_CUDA_DIGEST:-}" \
          && -z "${TRACEBLOC_K3S_CUDA_IMAGE:-}" && -z "${TRACEBLOC_IMAGE_REGISTRY:-}" ]]; then
      _got_digest="$(sed -n 's/^[Dd]igest: *\(sha256:[0-9a-f]\{64\}\).*/\1/p' "$_pull_log" 2>/dev/null)"
      _got_digest="${_got_digest%%$'\n'*}"   # first match; never `| head -1` (SIGPIPEs sed)
      if [[ -z "$_got_digest" ]]; then
        # CANNOT TELL. An unreadable digest is not agreement — but it is not a reason to
        # refuse the GPU either: we pulled by TAG, so the k3s version is still the
        # validated pin. Run unpinned and say so, rather than claim a check we did not make.
        warn "Couldn't read which digest ${_prepull_image} resolved to — running it UNPINNED this install."
        hint "The k3s version is still the validated pin; only the content check (facts.env K3S_CUDA_DIGEST) was skipped."
      elif [[ "$_got_digest" != "$TB_K3S_CUDA_DIGEST" ]]; then
        _gpu_ok=0
        _gpu_fail_reason="digest"
      fi
    fi
    [[ -n "$_pull_log" && "$_pull_log" != /dev/null ]] && rm -f "$_pull_log"
    # Verify the pulled image actually runs k3s (mirrors Test-GpuImageRunsK3s): a
    # mis-tagged/broken override or mirror copy passes the pull but then hard-fails
    # cluster-create. Run WITH --gpus so it exercises the exact create path (our image
    # bakes NVIDIA_DISABLE_REQUIRE, so it passes on any driver). Capture-then-match,
    # never `docker run | grep -q` — grep closing the pipe would SIGPIPE the run under
    # pipefail and read as a spurious failure.
    if (( _gpu_ok )); then
      local _ver_out
      _ver_out="$(_bounded "${TB_GPU_VERIFY_TIMEOUT:-90}" docker run --rm --gpus all "$_prepull_image" --version 2>/dev/null)" || _ver_out=""
      grep -qi k3s <<<"$_ver_out" || _gpu_ok=0
    fi
    if (( ! _gpu_ok )) && [[ "$_gpu_fail_reason" == "digest" ]]; then
      # The tag exists and pulled, but its content is not the reviewed, pinned image.
      # Refusing it is the POINT of the pin (backend#1867): a republished tag must not
      # put unreviewed bytes on a customer's GPU node. Kept distinct from a failed pull
      # so nobody chases network/creds for a supply-chain answer.
      TRACEBLOC_GPU_WIRED=0
      warn "The GPU node image no longer resolves to the pinned digest — installing CPU-only rather than running an unreviewed image."
      hint "Expected ${TB_K3S_CUDA_DIGEST}, but ${_prepull_image} resolved to ${_got_digest:-<unknown>}."
      hint "Either that tag was republished, or K8S_VERSION/CUDA_TAG moved without re-resolving K3S_CUDA_DIGEST in scripts/spec/facts.env."
      _recreate_cluster_hint
    elif (( ! _gpu_ok )); then
      TRACEBLOC_GPU_WIRED=0
      warn "Couldn't pull or validate the GPU node image (${_prepull_image}) — installing CPU-only so the cluster still comes up."
      hint "Make sure this host can pull AND run ${_prepull_image} (for a private registry set TRACEBLOC_IMAGE_REGISTRY + TRACEBLOC_REGISTRY_USERNAME/PASSWORD)."
      # The node image is fixed at create time and this CPU cluster now looks healthy,
      # so a plain re-run fast-paths and can't retry GPU (Bugbot) — recreate to enable it.
      hint "Then recreate the cluster to enable GPU (a plain re-run won't retry it):"
      _recreate_cluster_hint
    fi
  fi

  # Pin k3s at create time. common.sh defaults K8S_VERSION to the validated pin,
  # so a normal install ALWAYS passes --image; the version is fixed into the node
  # image and can't be changed later. An explicit K8S_VERSION=latest is an
  # unsupported opt-out that floats to k3d's OWN bundled default k3s — the exact
  # drift that stranded a client on v1.35.5 while the pin was v1.29.4 (#547) — so
  # honour it but warn loudly. (Empty only happens when cluster.sh is sourced
  # without common.sh, e.g. the unit harness; leave it a no-op there.)
  #
  # The GPU path swaps the stock rancher/k3s node for the GPU-capable k3s-cuda
  # image (client#835): same pinned k3s, plus the NVIDIA runtime + `nvidia`
  # RuntimeClass, because GPU capability is baked into the node at create time and
  # can't be bolted onto a running cluster. Gated on _gpu_wired so a CPU install is
  # byte-for-byte unchanged. Mirrors the Windows twin (install-k8s.ps1).
  if [[ "$K8S_VERSION" == "latest" ]]; then
    warn "K8S_VERSION=latest runs an UNVALIDATED k3s (k3d's bundled default), not the tested pin."
    hint "The chart is validated against a specific k3s release; 'latest' is unsupported and has stranded installs (#547)."
    hint "Unset K8S_VERSION (or pin it to a validated tag) to use the tested version."
    # 'latest' has no matching pinned k3s-cuda image to derive, and a stock k3s node
    # can't schedule GPU pods — so drop the request (it would otherwise strand every
    # job Pending on a node that advertises 0 GPUs).
    if _gpu_wired; then
      TRACEBLOC_GPU_WIRED=0
      warn "GPU disabled: K8S_VERSION=latest has no matching GPU node image — pin TRACEBLOC_K8S_VERSION to enable GPU."
    fi
  elif _gpu_wired && [[ -n "$K8S_VERSION" ]]; then
    local _gpu_image; _gpu_image="$(_gpu_node_image)"
    K3D_ARGS+=(--image "$_gpu_image")
    log "GPU node image: ${_gpu_image} (NVIDIA Container Toolkit + 'nvidia' RuntimeClass baked in)."
  elif [[ -n "$K8S_VERSION" ]]; then
    K3D_ARGS+=(--image "rancher/k3s:${K8S_VERSION}")
  fi

  # The one k3d GPU argument, derived from the gate every other GPU decision reads
  # (the reuse guard, the pre-pull and the 'latest' branch above may have just put
  # it back to 0), so the node's passthrough and the chart's GPU request agree.
  if _gpu_wired; then
    K3D_ARGS+=(--gpus=all)
    log "GPU flag(s) active: --gpus=all"
    log "Creating cluster with $SERVERS server(s) + $AGENTS agent(s) + GPU passthrough..."
  else
    log "Creating cluster with $SERVERS server(s) + $AGENTS agent(s) (CPU-only)..."
  fi
  echo -e "  ${DIM}Downloading the runtime that hosts your environment — a lightweight,${RESET}"
  echo -e "  ${DIM}self-contained Kubernetes that runs entirely on your machine.${RESET}"
  echo ""

  # Propagate corporate proxy env so k3s/containerd can reach external registries
  # behind an HTTP/HTTPS proxy (hospital/banking/government tenants). Passed via a
  # k3d --config file rather than --env: k3d splits --env on '@', which corrupts
  # authenticated-proxy URLs (http://user:pass@host), whereas the YAML env list in
  # a config file preserves them. NO_PROXY is auto-augmented with the cluster-
  # internal ranges so in-cluster traffic never traverses the proxy (which would
  # otherwise misroute it and hang `k3d cluster create --wait`). k3d merges the
  # --config env with these CLI flags (verified on k3d v5.8.3).
  local proxy_cfg
  proxy_cfg="$(_write_k3d_proxy_config)"
  if [[ -n "$proxy_cfg" ]]; then
    K3D_ARGS+=(--config "$proxy_cfg")
    log "Propagating proxy settings to k3d nodes (authenticated proxies supported; NO_PROXY auto-augmented)."
  fi

  # In-node CA trust for TLS-inspecting networks (#424): mount the operator's CA
  # bundle into every node and point containerd at it per-registry, so in-node
  # image pulls validate the intercepted certs instead of failing x509.
  local ca_bundle reg_cfg="" ca_rc=0
  local node_ca="/etc/ssl/certs/tracebloc-mitm-ca.crt"
  # `|| ca_rc=$?` (not a bare `;`): under `set -euo pipefail` a rc-2 from the
  # command substitution would trip errexit and exit before ca_rc/error below,
  # giving a bare exit instead of the "can't be read" guidance (Bugbot).
  ca_bundle="$(_resolve_ca_bundle)" || ca_rc=$?
  if [[ $ca_rc -eq 2 ]]; then
    error "$ca_bundle is set but its file can't be read — point it at your corporate CA bundle (PEM) and re-run."
  fi
  if [[ -n "$ca_bundle" ]]; then
    K3D_ARGS+=(-v "${ca_bundle}:${node_ca}@all")
    # Hard-fail if we can't write the registries.yaml: mounting the CA without the
    # --registry-config would leave containerd untrusting while we log success —
    # the operator would think the fix applied and still hit x509 (Bugbot).
    reg_cfg="$(_write_k3d_registries_config "$node_ca")" \
      || error "Couldn't write the k3d CA-trust registries config (temp dir/disk?). Re-run; the CA bundle was supplied so we won't proceed without wiring it in."
    K3D_ARGS+=(--registry-config "$reg_cfg")
    log "Trusting your network's TLS-inspection CA in the k3d nodes (from ${ca_bundle})."
  fi

  local create_out create_rc
  create_out="$(mktemp)"
  # Wrap the create in a spinner. k3d pulls the runtime image + boots the node
  # (1-2 min on first run) while printing nothing, which reads as a frozen
  # installer — the real fix here. Run it backgrounded and animate; spin() waits
  # for the PID, so create_rc is k3d's real exit code (captured WITHOUT tripping
  # `set -e`, so the 'already exists' reuse path, error dump, and temp-dir cleanup
  # below still run) and the proxy-config cleanup can't race the finished create.
  ( k3d "${K3D_ARGS[@]}" >"$create_out" 2>&1 ) &  # set-u-safe: K3D_ARGS is assigned the create verb above
  create_rc=0
  # Backstop deadline (#426): k3d's --timeout above should end a stuck create
  # itself; if k3d wedges past it (hung docker daemon), spin's deadline kills
  # it 5 minutes later and the error path below dumps the output.
  spin "$!" "Creating your secure environment…" "$(( (_create_timeout_min + 5) * 60 ))" || create_rc=$?
  [[ -n "$proxy_cfg" ]] && rm -rf "${proxy_cfg%/*}"
  [[ -n "$reg_cfg" ]] && rm -rf "${reg_cfg%/*}"
  if [[ $create_rc -ne 0 ]]; then
    if grep -qi "already exists\|a cluster with that name already exists" "$create_out" 2>/dev/null; then
      log "Cluster '$CLUSTER_NAME' already exists (detected from k3d message). Using existing cluster."
      rm -f "$create_out"
      # THE THIRD CALL SITE OF _handle_existing_cluster (LukasWodka, client#984
      # round 7). It grew rc 3 — "my own listing answered and there is no such
      # cluster" — in this change; the two sites in create_cluster (`:958`,
      # `:968`) were updated and this one was left bare. Under the installer's
      # `set -euo pipefail` that is not benign: install-k8s.sh:49 sets errexit,
      # nothing in the chain down to here is a condition context, and an `if`
      # BODY is not exempt — so a 3 exited the whole run with status 3 and no
      # curated message.
      #
      # AND CATCHING IT IS NOT ENOUGH: a bare `|| true` would fall through to the
      # `return 0` below, and create_cluster would then run
      # ensure_cluster_autostart, _merge_kubeconfig and _wait_for_api against a
      # cluster the listing just proved absent — 180s of `kubectl cluster-info`
      # ending in a bare failure.
      local _hrc=0
      _handle_existing_cluster || _hrc=$?
      if [[ "$_hrc" -ne 0 && "$_hrc" -ne 3 ]]; then
        # Exhaustive over the contract, for the same reason the create_cluster
        # `case` is: an outcome this site has no branch for must stop the run,
        # not slip through the `return 0` below into the reconcile tail.
        error "Adopting the existing '$CLUSTER_NAME' environment returned an unrecognised status ($_hrc); this run can't tell whether it is ready. See the install log and re-run."
      fi
      if [[ "$_hrc" -eq 3 ]]; then
        # This site cannot answer a 3 the way create_cluster does — by creating.
        # The create we JUST ran is the thing that said the name is taken, so a
        # retry gets the same refusal, forever. "create refuses the name" plus
        # "the listing has no row for it" is the half-created leftover this
        # function already documents two branches down (`:2200`): a stray
        # `k3d-$CLUSTER_NAME` network or volume outlives the cluster and keeps
        # holding the name. Same remedy, named here instead of guessed at.
        warn "k3d wouldn't create '$CLUSTER_NAME' because that name is already in use, but the k3d cluster listing has no '$CLUSTER_NAME' in it — leftovers from a half-created environment (usually a stray docker network or volume) are holding the name."
        _recreate_cluster_hint
        error "Couldn't create your secure environment: the name '$CLUSTER_NAME' is held by leftovers from an earlier attempt. Clear them with the k3d line above, then re-run."
      fi
      return 0
    fi
    if [[ "$create_rc" -eq 124 ]]; then
      # spin's backstop fired: k3d wedged past its own --timeout (typically a
      # hung Docker daemon) and was killed. Say so explicitly — the create log
      # is often EMPTY here, so without this the operator gets a bare failure
      # with no timeout hint (Bugbot #442). And killing k3d mid-create skips
      # its rollback: delete the partial cluster so a re-run doesn't adopt a
      # half-created environment via the "already exists" branch above
      # (parity with the Windows fix on #439).
      warn "Creating the environment timed out after $(( _create_timeout_min + 5 )) minutes."
      hint "Check that Docker is healthy and this machine can pull images, then re-run. (TB_CREATE_TIMEOUT_MIN raises the k3d bound.)"
      ( k3d cluster delete "$CLUSTER_NAME" >>"${LOG_FILE:-/dev/null}" 2>&1 ) &
      spin "$!" "Removing the partially created environment…" 120 \
        || warn "Couldn't remove the partial cluster - run 'k3d cluster delete $CLUSTER_NAME' before re-running."
    fi
    # Host-daemon x509 (k3d runtime image pull on a TLS-inspecting network, #474)
    # — name it before dumping the raw k3d error. Empty output (e.g. the timeout
    # kill above) simply produces no hint.
    _host_ca_create_hint "$(cat "$create_out" 2>/dev/null)"
    cat "$create_out" >> "${LOG_FILE:-/dev/null}" 2>/dev/null
    cat "$create_out" >&2
    rm -f "$create_out"
    exit "$create_rc"
  fi
  cat "$create_out" >> "${LOG_FILE:-/dev/null}" 2>/dev/null
  rm -f "$create_out"
  tb_record_write k3d-cluster "$CLUSTER_NAME" ""
  # No success line here — _wait_for_api prints the single "Secure environment
  # ready" once the API server actually answers (the true ready signal).
  log "k3d cluster '$CLUSTER_NAME' created."
  # Fix every node's address before the first Docker restart can reorder them
  # (client-dev#1370). Best effort; see the function.
  _pin_k3d_node_addresses_after_create
}

_merge_kubeconfig() {
  mkdir -p "${HOME}/.kube"
  export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

  # This merge is load-bearing, not cosmetic (client#732). The installer passes no
  # --kubeconfig/--context to `tracebloc client create`, and the CLI follows plain
  # kubectl precedence — so the secure environment is anchored to whatever context
  # is CURRENT when it is provisioned. This used to run with `>/dev/null 2>&1` and
  # no `||`: a failed merge left the previous current-context in place and the
  # install carried on, silently anchoring this machine to some other cluster (a
  # corporate EKS, a colleague's kind cluster). Capture the status, keep k3d's own
  # words for the message, and stop.
  #
  # Bounded: k3d reads the kubeconfig out of the server node through the Docker
  # daemon, so a wedged daemon would otherwise hang the install here with no
  # output at all (installer rule: every docker probe carries a deadline).
  # The context the user had selected BEFORE the switch below (backend#5025 O-19).
  # The switch is required (see above), but it was silent: someone who also works
  # on other clusters ran their next kubectl against this one. Read it now, so the
  # summary can say what changed and how to switch back. Best effort -- an
  # unreadable or empty context (a fresh machine) just means nothing to report.
  TB_PREV_KUBE_CONTEXT=""
  local prev_ctx=""
  prev_ctx="$(_bounded 10 kubectl config current-context 2>/dev/null)" || prev_ctx=""
  prev_ctx="${prev_ctx//[$'\r\n']/}"

  local merge_out merge_rc=0
  merge_out="$(_bounded "${TB_KUBECONFIG_MERGE_TIMEOUT:-60}" \
    k3d kubeconfig merge "$CLUSTER_NAME" \
      --kubeconfig-merge-default \
      --kubeconfig-switch-context 2>&1)" || merge_rc=$?
  if [[ $merge_rc -ne 0 ]]; then
    echo ""
    if [[ $merge_rc -eq 124 ]]; then
      warn "Pointing kubectl at '$CLUSTER_NAME' timed out after ${TB_KUBECONFIG_MERGE_TIMEOUT:-60}s (k3d couldn't read the cluster's kubeconfig)."
      hint "That usually means the Docker daemon is wedged — check 'docker ps' answers, then re-run."
    else
      warn "Couldn't point kubectl at the '$CLUSTER_NAME' cluster (k3d kubeconfig merge exited $merge_rc)."
    fi
    # if-form, not `[[ … ]] && hint`: under `set -e` an empty merge_out would make
    # the compound return 1 and abort HERE — swallowing the guidance below, which
    # is the whole point of this branch.
    # The timeout path in particular produces NO output; the guidance below must
    # print either way, which is what the "fails with no output" test pins.
    if [[ -n "$merge_out" ]]; then hint "k3d said: ${merge_out}"; fi
    hint "Stopping here on purpose: this machine's secure environment is registered against whichever"
    hint "cluster kubectl currently points at, so continuing would connect it to the wrong cluster."
    hint "Common causes: ${KUBECONFIG%%:*} isn't writable, the disk is full, or KUBECONFIG points somewhere unexpected."
    hint "  KUBECONFIG=${KUBECONFIG}"
    hint "Fix that (or merge it yourself with the command below), then re-run this installer:"
    hint "  k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-merge-default --kubeconfig-switch-context"
    echo ""
    error "kubectl was not pointed at '$CLUSTER_NAME' — refusing to continue against an unknown cluster."
  fi

  # Defensive normalization: k3d may still emit 0.0.0.0 server URLs into the
  # kubeconfig (older k3d versions, or pre-existing entries from previous
  # installs). Behind a corporate HTTP/HTTPS proxy, 0.0.0.0 gets intercepted
  # and kubectl fails. Anchored to `https://0.0.0.0:` so CIDR ranges and other
  # 0.0.0.0 occurrences elsewhere in the file are left untouched.
  #
  # KUBECONFIG can be colon-separated (kubectl path-list semantics); k3d's
  # --kubeconfig-merge-default writes into the first entry (or ~/.kube/config
  # if KUBECONFIG is unset). Target the same file or the rewrite would be
  # skipped by -f on multi-file layouts.
  local kc_target="${KUBECONFIG:-${HOME}/.kube/config}"
  kc_target="${kc_target%%:*}"
  if [[ -f "$kc_target" ]] && grep -q 'https://0\.0\.0\.0:' "$kc_target"; then
    sed -i.bak 's|https://0\.0\.0\.0:|https://127.0.0.1:|g' "$kc_target"
    rm -f "${kc_target}.bak"
    log "Normalized kubeconfig server URL: 0.0.0.0 → 127.0.0.1 in $kc_target (corporate-proxy safety)."
  fi

  # Confirm the ANCHOR, don't infer it from an exit code (client#732). What the
  # next steps actually depend on is that kubectl's current-context is this
  # cluster; a zero exit is evidence for that, not proof of it. k3d v5 (the pinned
  # K3D_VERSION) names the context it writes `k3d-<cluster>`, so the check compares
  # against the same thing --kubeconfig-switch-context sets — and if a future k3d
  # ever renamed it, this stops with the use-context command rather than silently
  # provisioning against whatever was current. Fail closed: a context we cannot READ
  # is not a context we can vouch for — "couldn't tell" and "wrong cluster" are the
  # same answer here, because both would provision against an unknown cluster.
  local want_ctx="k3d-${CLUSTER_NAME}" have_ctx ctx_rc=0
  have_ctx="$(_bounded 10 kubectl config current-context 2>/dev/null)" || ctx_rc=$?
  have_ctx="${have_ctx//[$'\r\n']/}"
  if [[ $ctx_rc -ne 0 || "$have_ctx" != "$want_ctx" ]]; then
    echo ""
    if [[ $ctx_rc -ne 0 ]]; then
      warn "k3d merged the '$CLUSTER_NAME' kubeconfig, but kubectl can't tell us which context is current."
    else
      warn "k3d merged the '$CLUSTER_NAME' kubeconfig, but kubectl's current context is '${have_ctx:-<none>}', not '$want_ctx'."
    fi
    hint "This machine's secure environment is registered against the CURRENT context, so continuing"
    hint "would connect it to that other cluster instead of the one this installer just prepared."
    hint "Select this cluster, then re-run this installer:"
    hint "  kubectl config use-context $want_ctx"
    hint "  KUBECONFIG=${KUBECONFIG}"
    echo ""
    error "kubectl is not pointed at '$CLUSTER_NAME' — refusing to continue against an unknown cluster."
  fi

  log "kubeconfig updated — kubectl now points to '$CLUSTER_NAME' (context $want_ctx)."
  TRACEBLOC_KUBE_CONTEXT="$want_ctx"
  if [[ -n "$prev_ctx" && "$prev_ctx" != "$want_ctx" ]]; then
    TB_PREV_KUBE_CONTEXT="$prev_ctx"
    log "kubectl's current context was '$prev_ctx' before this install; the summary says how to switch back."
  fi
  tb_record_write
}

# =============================================================================
#  NODE ADDRESSES (client-dev#1370)
# =============================================================================
#
# WHAT GOES WRONG. k3d attaches its node containers to the cluster network with
# DYNAMIC addresses (IPAMConfig null), and a Docker restart hands them out again
# in whatever order the containers come back. k3s keeps the node's address in its
# Node object, and when the node returns on a DIFFERENT address k3s dies on every
# start with
#   failed to start networking: unable to initialize network policy controller:
#   error getting node subnet: failed to find interface with specified node ip
# The k3d 5.9 entrypoint then sits in `until kubectl uncordon …; do sleep 3; done`,
# so the server container stays Up, Docker's restart policy never fires, and
# `k3d cluster list` still reports 1/1. Measured on a Mac on 2026-09-29: the
# environment was dead for five days and the installer said "already running",
# then timed out 180 s later naming three causes that did not apply.
#
# THREE PARTS, ONE ROUTINE (_k3d_pin_addresses):
#   detect  — _k3s_node_state, gated on the API not answering: the node runs,
#             and its k3s process is gone or its latest k3s run ended on that error.
#   repair  — _ensure_k3s_node_addresses puts a failing node back on the address
#             its Node object records (the latest kube-proxy "Successfully
#             retrieved NodeIPs" line in `docker logs`; the failing runs print it
#             too, just before they die), pins the load balancer high, and starts.
#   prevent — _pin_k3d_node_addresses_after_create runs the same routine right
#             after create, with every node on the address it already has.
#
# WHY NOT `k3d cluster create --subnet auto`. Measured first (k3d v5.9.0, Docker
# 29.7.2, throwaway clusters): it gives SERVERS a static address and nothing
# else. The agent, the load balancer and the tools helper stay dynamic, and a
# dynamic container that comes back first takes the server's pinned address, so
# the server then fails to start at all ("Address already in use"): reproduced
# with the load balancer and with the agent. Every container that Docker restarts
# must be pinned, which that flag cannot do.
#
# Nothing here deletes anything: containers, volumes and the network all stay;
# only each container's attachment to its network is re-made with a fixed --ip.

# _k3s_log_facts — a k3s node's log on stdin; prints "<failed> <expected-ip>",
# both about the LATEST k3s run (from its last "Starting k3s v" line):
#   failed       1 when that run logged the node-address failure, else 0. Per run,
#                not per log: a node that failed once and has run cleanly since is
#                not failing.
#   expected-ip  the address in that run's "Successfully retrieved NodeIPs" line —
#                the Node object's address, the one k3s insists on (kube-proxy
#                prints it just before the failing run dies). Empty when that run
#                printed none. IPv4 only: the first address of a dual-stack list.
# THE SAME RUN, never an older one: the failure is a RACE, not a certainty —
# measured on a throwaway cluster, one swap in three came up healthy because the
# kubelet moved the Node to the new address first — so an older run's line can
# name an address the Node object no longer has, and putting the node back there
# would break it. No line in the failing run means "cannot tell", never "use the
# last one we saw".
# POSIX awk (mawk on Debian/Ubuntu, BSD awk on macOS); `failed` is printed FIRST
# so an empty address cannot shift it into the address slot on `read`.
_k3s_log_facts() {
  awk -v run="$_TB_K3S_RUN_MARK" -v fail="$_TB_K3S_NODEIP_FAIL" -v ips="$_TB_K3S_NODEIPS_MARK" '
    index($0, run)  { failed = 0; ip = "" }
    index($0, fail) { failed = 1 }
    index($0, ips)  { if (match($0, /NodeIPs=\["[0-9.]+"/)) ip = substr($0, RSTART + 10, RLENGTH - 11) }
    END { printf "%d %s\n", failed, ip }'
}

# _k3s_node_log_facts NODE — _k3s_log_facts over NODE's WHOLE log, bounded on
# every platform. Not a tail: a server stuck in the entrypoint's uncordon loop
# logs a refused connection every 3 s, so five days bury the failure 500k lines
# deep (measured: 528k lines, ~100 MB, parsed in ~6 s). Non-zero when the read
# itself failed — "cannot tell", never "no failure".
#
# The read goes through _bounded_capture into a file, NOT `_bounded … | awk`
# (Bugbot on client-dev#1420, "Mac log read has no deadline"). When that was
# written, `_bounded` ran the bare command on a stock Mac, which has no
# timeout/gtimeout; since client-dev#1357 both hold the deadline there, and the
# file stays for the PIPESTATUS reason below. This is the one read whose time
# grows with the log. The PowerShell twin already cuts it at the same deadline.
#
# No pipeline also means no PIPESTATUS (Bugbot on client-dev#1380, "Failed log
# read marked dead"). install-k8s.sh runs with `set -E` and an ERR trap, and on
# the macOS /bin/bash 3.2 the trap that fires for a failed pipeline resets
# PIPESTATUS: a read that failed came back 0 with "0 " (measured). The status
# comes straight from _bounded_capture: 124 when the deadline fired, the read's
# own code when it failed, 2 when no capture file could be made. Each is
# "cannot tell". The log sits in TMPDIR only for the parse, then is removed.
_k3s_node_log_facts() {
  local logf rc=0
  logf="$(mktemp "${TMPDIR:-/tmp}/tracebloc-logread-XXXXXX" 2>/dev/null)" || return 2
  _bounded_capture "${TB_DOCKER_LOGS_TIMEOUT:-90}" "$logf" docker logs "$1" || rc=$?
  if [[ "$rc" == 0 ]]; then
    _k3s_log_facts < "$logf" || rc=2
  fi
  rm -f "$logf"
  return "$rc"
}

# _k3s_running_in NODE — 0 when a k3s process runs in NODE, 1 when none does, 2
# when that cannot be read. Read from the HOST side (`docker top`), so it works
# while k3s is dead. Matches the COMMAND word itself (`/bin/k3s server`,
# `k3s agent`), never a substring: the containerd shims carry
# /run/k3s/containerd/… in their arguments and outlive k3s.
_k3s_running_in() {
  local out
  out="$(_bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker top "$1" 2>/dev/null)" || return 2
  awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "CMD" || $i == "COMMAND") col = i; next }
       col && ($col == "k3s" || $col ~ /\/k3s$/) { found = 1 }
       END { if (!col) exit 2; exit (found ? 0 : 1) }' <<<"$out"
}

# _k3d_nodes ROLE — this cluster's containers of one k3d role, one per line.
# By k3d's LABELS, one query per role, never by name — the reasoning is
# _verify_nodes_see_host_data's (an exact cluster match, and a format the
# PowerShell twin can pass unchanged). `-a`: a node that is restarting counts.
_k3d_nodes() {
  _bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker ps -a \
    --filter "label=k3d.cluster=${CLUSTER_NAME}" \
    --filter "label=k3d.role=$1" \
    --format '{{.Names}}' 2>/dev/null
}

# _k3d_node_addr NODE — "running|network|address|pinned" for NODE on the network
# k3d's own label names (derived, not "k3d-$CLUSTER_NAME"). address and pinned are
# empty when there is none. Raw-string (backtick) template keys, so no argument
# carries a double quote — the constraint of the PowerShell twin.
_k3d_node_addr() {
  _bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect -f \
    '{{$n := index .Config.Labels `k3d.cluster.network`}}{{.State.Running}}|{{$n}}|{{with index .NetworkSettings.Networks $n}}{{.IPAddress}}|{{with .IPAMConfig}}{{.IPv4Address}}{{end}}{{end}}' \
    "$1" 2>/dev/null
}

# _k3d_net_layout NET — the network's IPv4 subnet + gateway and who is on it:
#   subnet <cidr> <gateway>
#   member <container> <address>/<prefix>
_k3d_net_layout() {
  _bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker network inspect -f \
    '{{range .IPAM.Config}}subnet {{.Subnet}} {{.Gateway}}{{println}}{{end}}{{range .Containers}}member {{.Name}} {{.IPv4Address}}{{println}}{{end}}' \
    "$1" 2>/dev/null
}

# _k3d_high_ip CIDR TAKEN… — the highest free host address of an IPv4 CIDR,
# skipping every address in TAKEN. The load balancer lives there, far from
# Docker's dynamic allocations, which start at the bottom: pinned low, the k3d
# tools helper that `k3d cluster start` brings up first takes the address and the
# load balancer then fails "Address already in use" (hit on 2026-09-29).
_k3d_high_ip() {
  local cidr="$1"; shift
  local len="${cidr#*/}" net size top n t taken=" $* "
  case "$len" in ''|*[!0-9]*) return 1 ;; esac
  (( len >= 8 && len <= 29 )) || return 1
  net="$(_ipv4_to_int "${cidr%/*}")" || return 1
  size=$(( 1 << (32 - len) ))
  net=$(( net - net % size ))
  top=$(( net + size - 2 ))
  for (( n = top; n > top - 16 && n > net + 1; n-- )); do
    t="$(_int_to_ipv4 "$n")"
    [[ "$taken" == *" $t "* ]] && continue
    printf '%s\n' "$t"
    return 0
  done
  return 1
}

# _k3s_node_state NODE — the detector, for one k3s node. Prints
#   "<verdict> <network> <current-address> <expected-address>"   (- when unknown)
#   ok          k3s runs (a live k3s trumps any old log line)
#   swapped     k3s is not running, its latest run failed on the node address,
#               and the address that run recorded differs from the one the
#               container has now (or it has none): REPAIRABLE
#   unreadable  it failed on the node address, but the failing run recorded no
#               address, so there is nothing to put it back to (fail closed)
#   dead        k3s is not running, and its log was read and shows no such failure
#   stopped     the container is not running and its log shows no such failure
#   unknown     the facts could not be read -- including a running node whose log
#               read failed or timed out: that could be a swap, so it is not `dead`
#               (which a repair would pin on the address it has now)
_k3s_node_state() {
  local node="$1" line running="" net="" cur="" _pinned alive=1 facts failed="" exp="" logread=0
  if ! line="$(_k3d_node_addr "$node")"; then
    printf 'unknown - - -\n'; return 0
  fi
  IFS='|' read -r running net cur _pinned <<<"$line"
  _ipv4_to_int "$cur" >/dev/null || cur=""        # docker prints "invalid IP" when stopped
  if [[ "$running" == "true" ]]; then
    alive=0; _k3s_running_in "$node" || alive=$?
  fi
  # A live k3s trumps any old log line, and costs no log read (the API may be down
  # for a reason that is not this one — a proxy — with every node healthy).
  if [[ "$alive" -eq 0 ]]; then
    printf 'ok %s %s -\n' "${net:--}" "${cur:--}"; return 0
  fi
  if facts="$(_k3s_node_log_facts "$node")"; then
    logread=1
    read -r failed exp <<<"$facts"
    _ipv4_to_int "$exp" >/dev/null || exp=""
  fi

  # REPAIR ONLY ON THE FAILURE LINE. A dead k3s on a moved address is not proof
  # on its own (the node may have died of something else after surviving a move),
  # and the failing run always prints the line before it goes.
  local verdict
  if [[ "$failed" == "1" ]]; then
    if [[ -z "$exp" ]]; then verdict=unreadable
    elif [[ "$exp" != "$cur" ]]; then verdict=swapped
    else verdict=dead                               # failed on an address it HAS: not a move
    fi
  elif [[ "$running" != "true" ]]; then
    verdict=stopped
  elif [[ "$alive" -eq 2 || "$logread" -eq 0 ]]; then
    verdict=unknown                                 # no k3s, and a log that could not be read
  else
    verdict=dead
  fi
  printf '%s %s %s %s\n' "$verdict" "${net:--}" "${cur:--}" "${exp:--}"
}

# _k3d_pin_addresses NET LB_SPEC NODE_SPEC… — give each container a FIXED address
# on NET and bring the cluster back. A SPEC is "container=address"; LB_SPEC may be
# empty (a cluster made with --no-lb). NODE_SPECs go servers first, and name EVERY
# k3s node of the cluster (_k3d_pin_plan refuses a plan that leaves one out).
#
# ORDER, all of it load-bearing:
#   1. stop the cluster: an address can only be re-assigned on a stopped container.
#   2. disconnect EVERY container before connecting any: in a swap, each address
#      is held by the other container until both are released.
#   3. connect each one with its fixed --ip.
#   4. `k3d cluster start --wait` starts everything, the nodes included; never a
#      `docker start` first. Docker rebuilds /etc/hosts on every start, and k3d
#      writes its host aliases back (host.k3d.internal, the name a proxy on the host
#      is reached by) only into the nodes it starts itself (measured on k3d v5.9.0):
#      a node started by `docker start` came back without them, and the squid E2E's
#      image pulls through the host's proxy died there. What that ordering protected
#      against -- a dynamic container taking a stopped node's pinned address -- is
#      now refused up front by _k3d_pin_plan: every k3s node is pinned, and none on
#      the address k3d's tools helper, which it starts first, will take.
# Status: 0 every container runs on its address; 1 nothing was changed (the stop
# failed, and the cluster runs as it did); 2 it was stopped and came back, but not
# every container on its address (a refused --ip is rolled back to a dynamic one,
# so none is left off its network); 3 it was stopped and did NOT come back -- k3d
# cluster start failed or a container is not running. The caller decides which of
# those is fatal; 3 always is, since the environment is down.
_k3d_pin_addresses() {
  local net="$1" lbspec="$2"; shift 2
  local spec c ip line running cur _n _p back=1 pinned=1
  local logf="${LOG_FILE:-/dev/null}"
  if ! _bounded "${TB_K3D_STOP_TIMEOUT:-180}" k3d cluster stop "$CLUSTER_NAME" >>"$logf" 2>&1; then
    # A stop that failed part-way can leave some containers down: bring the
    # cluster back before reporting "nothing changed", and say so if it isn't.
    log "k3d cluster stop '$CLUSTER_NAME' failed; no address was changed. Starting it again in case it stopped part-way."
    _bounded "${TB_K3D_START_TIMEOUT:-360}" k3d cluster start "$CLUSTER_NAME" --wait --timeout 5m >>"$logf" 2>&1 || return 3
    return 1
  fi
  for spec in "$@" ${lbspec:+"$lbspec"}; do
    c="${spec%%=*}"
    _bounded "${TB_DOCKER_NET_TIMEOUT:-30}" docker network disconnect "$net" "$c" >>"$logf" 2>&1 \
      || log "docker network disconnect $net $c failed (not attached?); connecting it anyway."
  done
  for spec in "$@" ${lbspec:+"$lbspec"}; do
    c="${spec%%=*}"; ip="${spec#*=}"
    if ! _bounded "${TB_DOCKER_NET_TIMEOUT:-30}" docker network connect --ip "$ip" "$net" "$c" >>"$logf" 2>&1; then
      pinned=0
      log "Could not attach $c to $net at $ip; re-attaching it with a dynamic address so it is not left off its network."
      _bounded "${TB_DOCKER_NET_TIMEOUT:-30}" docker network connect "$net" "$c" >>"$logf" 2>&1 \
        || log "Re-attaching $c to $net failed as well."
    fi
  done
  # Bounded on top of k3d's own --timeout: that one covers the wait for the nodes,
  # not a Docker daemon that stops answering underneath k3d.
  _bounded "${TB_K3D_START_TIMEOUT:-360}" k3d cluster start "$CLUSTER_NAME" --wait --timeout 5m >>"$logf" 2>&1 \
    || { back=0; log "k3d cluster start '$CLUSTER_NAME' failed after re-attaching its nodes."; }
  for spec in "$@" ${lbspec:+"$lbspec"}; do
    c="${spec%%=*}"; ip="${spec#*=}"
    running=""; cur=""
    if line="$(_k3d_node_addr "$c")"; then IFS='|' read -r running _n cur _p <<<"$line"; fi
    if [[ "$running" != "true" ]]; then
      back=0
      log "$c is not running after the re-attach."
    elif [[ "$cur" != "$ip" ]]; then
      pinned=0
      log "$c runs on ${cur:-no address}, not on $ip, after the re-attach."
    fi
  done
  [[ "$back" -eq 1 ]] || return 3
  [[ "$pinned" -eq 1 ]] || return 2
  return 0
}

# _k3d_node_image NODE — the image NODE runs, for the address check below (it is
# on the machine: the node was created from it).
_k3d_node_image() {
  _bounded "${TB_DOCKER_INSPECT_TIMEOUT:-10}" docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null
}

# _k3d_static_ip_check NET ADDR IMAGE — can this Docker Engine give a container a
# fixed address on NET at all? 0 yes, 1 no (the engine said so), 2 cannot tell.
# Docker Engine 28 and earlier refuse `--ip` on a network whose subnet Docker
# picked itself, which is how k3d makes one without --subnet ("user specified IP
# address is supported only when connecting to networks with user configured
# subnets"; measured on 27.5.1 and 28.5.2, while 29.7.2 accepts it). Asked of the
# engine rather than read off its version: `docker create` validates the address
# and nothing is started. The container it creates is this check's own, and is
# removed again.
_k3d_static_ip_check() {
  local net="$1" addr="$2" image="$3" name out rc=0
  [[ -n "$image" ]] || return 2
  name="tb-ipcheck-$$-$RANDOM"
  out="$(_bounded "${TB_DOCKER_NET_TIMEOUT:-30}" docker create --pull never --name "$name" --network "$net" --ip "$addr" "$image" true 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    _bounded "${TB_DOCKER_NET_TIMEOUT:-30}" docker rm "$name" >/dev/null 2>&1 \
      || log "Could not remove the address-check container $name (it never ran): docker rm $name"
    return 0
  fi
  log "Fixed-address check on $net (docker create --ip $addr) exited $rc: $out"
  [[ "$out" == *"user configured subnets"* ]] && return 1
  return 2
}

# _k3d_pin_plan — shared by repair and prevent: reads the network layout for the
# node specs in "$@" (container=address), refuses what cannot be pinned safely, and
# prints the load balancer's spec ("" when the cluster has none) on success.
# Refusals go to stdout as "refuse <reason>": status 2 when THIS Docker Engine
# cannot pin addresses on the network at all, 1 for every other refusal.
_k3d_pin_plan() {
  local net="$1" lb="$2"; shift 2
  local layout kind a b subnet="" gw="" members="" ours=" " nodes=" " n spec c ip seen=" " holder lbip=""
  layout="$(_k3d_net_layout "$net")" || { printf 'refuse the layout of network %s could not be read\n' "$net"; return 1; }
  while read -r kind a b; do
    case "$kind" in
      subnet) [[ -z "$subnet" ]] && _ipv4_to_int "${a%/*}" >/dev/null && { subnet="$a"; gw="$b"; } ;;
      member) members="$members$a=${b%/*} " ;;
    esac
  done <<<"$layout"
  [[ -n "$subnet" ]] || { printf 'refuse network %s has no IPv4 subnet\n' "$net"; return 1; }
  local lo hi sz plen="${subnet#*/}"
  case "$plen" in ''|*[!0-9]*) printf 'refuse network %s has an unreadable subnet %s\n' "$net" "$subnet"; return 1 ;; esac
  (( plen >= 8 && plen <= 29 )) || { printf 'refuse network %s is a /%s, too small to pin addresses in\n' "$net" "$plen"; return 1; }
  lo="$(_ipv4_to_int "${subnet%/*}")"; sz=$(( 1 << (32 - plen) )); lo=$(( lo - lo % sz )); hi=$(( lo + sz - 1 ))
  # Everything k3d labels as this cluster's (the tools helper is `noRole`); any
  # other container on the network is someone else's and is never moved. A role
  # that cannot be listed is a refusal: "ours" decides whose address is whose.
  local list
  for n in server agent loadbalancer noRole; do
    list="$(_k3d_nodes "$n")" || { printf 'refuse the %s containers could not be listed\n' "$n"; return 1; }
    while read -r c; do
      [[ -n "$c" ]] || continue
      ours="$ours$c "
      [[ "$n" == server || "$n" == agent ]] && nodes="$nodes$c "
    done <<<"$list"
  done
  for spec in "$@"; do
    c="${spec%%=*}"; ip="${spec#*=}"
    n="$(_ipv4_to_int "$ip")" || { printf 'refuse %s would get %s, which is not an address\n' "$c" "$ip"; return 1; }
    (( n > lo && n < hi )) || { printf 'refuse %s would get %s, outside the network %s\n' "$c" "$ip" "$subnet"; return 1; }
    [[ "$ip" != "$gw" ]] || { printf 'refuse %s would get %s, the network gateway\n' "$c" "$ip"; return 1; }
    [[ "$seen" != *" $ip "* ]] || { printf 'refuse two nodes would share %s\n' "$ip"; return 1; }
    seen="$seen$ip "
    for holder in $members; do
      if [[ "${holder#*=}" == "$ip" && "$ours" != *" ${holder%%=*} "* ]]; then
        printf 'refuse %s is in use by %s, which is not part of this environment\n' "$ip" "${holder%%=*}"
        return 1
      fi
    done
  done
  # EVERY k3s node, or none. `k3d cluster start` starts them all, and a node left
  # dynamic can take the address of a pinned one that has not started yet: a
  # stopped container's fixed address is not reserved for it.
  for c in $nodes; do
    [[ " $* " == *" $c="* ]] || { printf 'refuse %s is not running on an address this installer could read, so it cannot be given a fixed one, and k3d would start it on a dynamic address another node may need\n' "$c"; return 1; }
  done
  # THE TOOLS HELPER. `k3d cluster start` brings it up before any node, on a
  # dynamic address: the lowest one no running container holds, which with the
  # cluster stopped is the lowest host address that is neither the gateway nor
  # someone else's. A node pinned there loses it and fails "Address already in use".
  local t tools_ip="" foreign
  for (( t = lo + 1; t < hi; t++ )); do
    ip="$(_int_to_ipv4 "$t")"
    [[ "$ip" == "$gw" ]] && continue
    foreign=0
    for holder in $members; do
      [[ "${holder#*=}" == "$ip" && "$ours" != *" ${holder%%=*} "* ]] && { foreign=1; break; }
    done
    [[ "$foreign" -eq 0 ]] && { tools_ip="$ip"; break; }
  done
  [[ -z "$tools_ip" || "$seen" != *" $tools_ip "* ]] \
    || { printf 'refuse k3d starts its tools helper first, on %s, the address a node needs\n' "$tools_ip"; return 1; }
  local taken="$gw"
  for holder in $members; do taken="$taken ${holder#*=}"; done
  if [[ -n "$lb" ]]; then
    # A load balancer ALREADY pinned in the top half (an earlier repair, or one done
    # by hand) keeps its address: moving it again buys nothing.
    local line _r _nn _c pinned=""
    if line="$(_k3d_node_addr "$lb")"; then IFS='|' read -r _r _nn _c pinned <<<"$line"; fi
    n="$(_ipv4_to_int "$pinned" 2>/dev/null)" || n=""
    if [[ -n "$n" ]] && (( n >= lo + sz / 2 && n < hi )) && [[ "$seen" != *" $pinned "* ]]; then
      lbip="$pinned"
    else
      # shellcheck disable=SC2086
      lbip="$(_k3d_high_ip "$subnet" $taken $seen)" || { printf 'refuse no free address is left at the top of %s for the load balancer\n' "$subnet"; return 1; }
    fi
  fi
  # CAN THIS ENGINE PIN AT ALL? Asked last, with an address nothing holds.
  local probe img rc=0
  # shellcheck disable=SC2086
  probe="$(_k3d_high_ip "$subnet" $taken $seen $lbip)" || probe="${lbip:-${seen# }}"
  probe="${probe%% *}"
  img="$(_k3d_node_image "${1%%=*}")" || img=""
  _k3d_static_ip_check "$net" "$probe" "$img" || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'refuse this Docker Engine cannot give a container a fixed address on network %s\n' "$net"; return 2 ;;
    *) printf 'refuse could not check that this Docker Engine can give a container a fixed address on network %s\n' "$net"; return 1 ;;
  esac
  printf '%s\n' "${lb:+$lb=$lbip}"
}

# _manual_pin_hint NET LB NODE=ADDR… — the repair, spelled out for an operator,
# for the cases this installer refuses to do itself.
_manual_pin_hint() {
  local net="$1" lb="$2" spec; shift 2
  hint "To put it back by hand (nothing is deleted):"
  hint "  k3d cluster stop $CLUSTER_NAME"
  [[ -n "$lb" ]] && hint "  docker network disconnect $net $lb"
  for spec in "$@"; do hint "  docker network disconnect $net ${spec%%=*}"; done
  for spec in "$@"; do hint "  docker network connect --ip ${spec#*=} $net ${spec%%=*}"; done
  [[ -n "$lb" ]] && hint "  docker network connect --ip <a free address at the top of the network> $net $lb"
  hint "  k3d cluster start $CLUSTER_NAME"
}

# _ensure_k3s_node_addresses — the reuse path's check, run at the start of the API
# wait. Silent unless the API does not answer, and it ACTS only on positive
# evidence: a node whose k3s is gone or failed on the node address, with a
# recorded address that differs from its current one.
_ensure_k3s_node_addresses() {
  _api_answers && return 0

  # Every k3s node's verdict. A repair pins EVERY node (see _k3d_pin_plan): `ok`
  # and `dead` ones on the address they have (for them the repair doubles as the
  # prevention), `swapped` ones on the address their Node object records. A node
  # that is stopped or could not be read has no address to pin, so a repair that
  # needs it is refused rather than guessed.
  local role node st verdict net cur exp netname="" lb="" specs_s="" specs_a=""
  local swapped="" unreadable="" dead="" rc=0 list servers=0 servers_ok=0
  for role in server agent; do
    rc=0; list="$(_k3d_nodes "$role")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log "The API did not answer and this cluster's $role nodes could not be listed (exit $rc); leaving it to the API wait."
      return 0
    fi
    while read -r node; do
      [[ -n "$node" ]] || continue
      st="$(_k3s_node_state "$node")"
      read -r verdict net cur exp <<<"$st"
      log "k3s node check: $node $st"
      if [[ "$net" != "-" && -z "$netname" ]]; then netname="$net"; fi
      if [[ "$role" == server ]]; then
        servers=$((servers + 1))
        [[ "$verdict" == ok ]] && servers_ok=$((servers_ok + 1))
      fi
      case "$verdict" in
        ok|dead)
          if [[ "$cur" != "-" ]]; then
            if [[ "$role" == server ]]; then specs_s="$specs_s $node=$cur"; else specs_a="$specs_a $node=$cur"; fi
          fi
          if [[ "$verdict" == dead && "$role" == server ]]; then dead="$dead $node"; fi ;;
        swapped)    if [[ "$role" == server ]]; then specs_s="$specs_s $node=$exp"; else specs_a="$specs_a $node=$exp"; fi
                    swapped="$swapped $node:$cur:$exp" ;;
        unreadable) unreadable="$unreadable $node" ;;
      esac
    done <<<"$list"
  done
  # Positive evidence that the earlier finding is gone: every server runs k3s.
  if [[ "$servers" -gt 0 && "$servers_ok" -eq "$servers" ]]; then TRACEBLOC_K3S_NODE_FINDING=""; fi

  local first
  if [[ -n "$unreadable" ]]; then
    first="${unreadable# }"; first="${first%% *}"
    warn "Kubernetes inside '$first' stops on every start: its network address changed (usually after a Docker restart), and the address it is registered at can't be read from its log, so this installer won't guess one."
    hint "The registered address is in the last 'Successfully retrieved NodeIPs' line of:"
    hint "  docker logs $first 2>&1 | grep 'Successfully retrieved NodeIPs' | tail -1"
    _manual_pin_hint "${netname:-k3d-$CLUSTER_NAME}" "k3d-${CLUSTER_NAME}-serverlb" "$first=<that address>"
    error "Stopped without changing anything: the address '$first' needs could not be read."
  fi

  if [[ -z "$swapped" ]]; then
    if [[ -n "$dead" ]]; then
      first="${dead# }"; first="${first%% *}"
      TRACEBLOC_K3S_NODE_FINDING="Kubernetes is not running inside '$first': the container is up, its k3s process is not, and nothing restarts it. Its last lines: docker logs --tail 50 $first. Restarting the environment often clears this: k3d cluster stop $CLUSTER_NAME && k3d cluster start $CLUSTER_NAME"
      log "k3s node check: $TRACEBLOC_K3S_NODE_FINDING"
    fi
    return 0
  fi

  local s c was want
  for s in $swapped; do
    c="${s%%:*}"; was="${s#*:}"; was="${was%%:*}"; want="${s##*:}"
    warn "Kubernetes inside '$c' stops on every start: after a Docker restart it came back on ${was/#-/no address}, but it is registered at $want and refuses any other address."
  done

  # The load balancer holds, in the usual swap, the very address the server needs,
  # so a listing that could not be read is a refusal, not "there is none".
  rc=0; lb="$(_k3d_nodes loadbalancer)" || rc=$?
  lb="${lb%%$'\n'*}"
  local plan lbname
  if [[ "$rc" -ne 0 ]]; then
    plan="refuse the load balancer could not be listed (exit $rc)"; rc=1
  else
    # shellcheck disable=SC2086
    plan="$(_k3d_pin_plan "$netname" "$lb" $specs_s $specs_a)" || rc=$?
  fi
  lbname="${lb:-k3d-${CLUSTER_NAME}-serverlb}"
  if [[ "$rc" -eq 2 ]]; then
    hint "Can't move it back automatically: ${plan#refuse }."
    hint "Docker Engine 29 can. Update Docker, then re-run this installer."
    error "Stopped without changing anything: this Docker Engine can't restore the addresses."
  elif [[ "$rc" -ne 0 ]]; then
    hint "Can't move it back automatically: ${plan#refuse }."
    # shellcheck disable=SC2086
    _manual_pin_hint "${netname:-k3d-$CLUSTER_NAME}" "$lbname" $specs_s $specs_a
    error "Stopped without changing anything: the addresses could not be restored safely."
  fi
  log "Re-pinning node addresses:${specs_s}${specs_a}${plan:+ $plan}"
  # shellcheck disable=SC2086
  ( _k3d_pin_addresses "$netname" "$plan" $specs_s $specs_a ) &
  rc=0; spin "$!" "Moving your secure environment's nodes back to their addresses (nothing is deleted)…" 900 || rc=$?
  case "$rc" in
    0)
      TRACEBLOC_K3S_NODE_FINDING=""
      success "Secure environment repaired: its nodes are back on the addresses Kubernetes expects, and fixed there." ;;
    1)
      # shellcheck disable=SC2086
      _manual_pin_hint "$netname" "$lbname" $specs_s $specs_a
      error "Couldn't stop your secure environment to move its nodes back, so nothing was changed (see the install log)." ;;
    2)
      # shellcheck disable=SC2086
      _manual_pin_hint "$netname" "$lbname" $specs_s $specs_a
      error "Couldn't put your secure environment's nodes back on their addresses. It is running again, on the addresses Docker gave it (see the install log)." ;;
    *)
      hint "It was stopped for the move and did not start again. Start it with:"
      hint "  k3d cluster start $CLUSTER_NAME"
      hint "then re-run this installer."
      error "Your secure environment was stopped to move its nodes back and did not start again (see the install log)." ;;
  esac
}

# _pin_k3d_node_addresses_after_create — prevention: fix every node on the address
# it was just given, and the load balancer high, before a Docker restart can
# reorder them. BEST EFFORT: a cluster that could not be pinned still works on the
# addresses Docker gave it, and the reuse path's check repairs one a later restart
# breaks — so a read that fails skips quietly and a pin that fails warns.
_pin_k3d_node_addresses_after_create() {
  local role node line running net cur _p netname="" lb="" specs="" list plan rc=0
  for role in server agent; do
    list="$(_k3d_nodes "$role")" || { log "Node addresses not pinned: couldn't list the $role nodes."; return 0; }
    while read -r node; do
      [[ -n "$node" ]] || continue
      line="$(_k3d_node_addr "$node")" || { log "Node addresses not pinned: couldn't read $node."; return 0; }
      IFS='|' read -r running net cur _p <<<"$line"
      if [[ "$running" != "true" || -z "$net" ]] || ! _ipv4_to_int "$cur" >/dev/null; then
        log "Node addresses not pinned: $node is not running on a readable address ($line)."
        return 0
      fi
      netname="$net"; specs="$specs $node=$cur"
    done <<<"$list"
  done
  [[ -n "$specs" ]] || { log "Node addresses not pinned: no k3s nodes listed for '$CLUSTER_NAME'."; return 0; }
  # A load balancer that could not be listed is a skip, not "there is none": nodes
  # pinned beside a still-dynamic load balancer are the measured failure (it
  # starts first and takes a node's address), worse than pinning nothing.
  lb="$(_k3d_nodes loadbalancer)" || { log "Node addresses not pinned: couldn't list the load balancer."; return 0; }
  lb="${lb%%$'\n'*}"
  # Every refusal -- including an engine that cannot pin on this network at all --
  # is a quiet skip: the cluster runs as it did before this step existed.
  # shellcheck disable=SC2086
  if ! plan="$(_k3d_pin_plan "$netname" "$lb" $specs)"; then
    log "Node addresses not pinned: ${plan#refuse }."
    return 0
  fi
  log "Pinning node addresses:${specs}${plan:+ $plan}"
  # shellcheck disable=SC2086
  ( _k3d_pin_addresses "$netname" "$plan" $specs ) &
  spin "$!" "Fixing your secure environment's network addresses…" 900 || rc=$?
  # Three different outcomes, three different messages (Bugbot on client-dev#1380):
  # only "nothing was changed" and "back up on Docker's addresses" are true
  # enough for "it works as it is"; a cluster this step stopped and could not
  # start again is down, and the install stops here saying how to start it.
  case "$rc" in
    0) ;;
    1) warn "Couldn't give your secure environment's nodes fixed network addresses, so nothing was changed. It works as it is, but a Docker restart could reorder them; re-running this installer repairs that." ;;
    2) warn "Couldn't give your secure environment's nodes fixed network addresses. It is running on the addresses Docker gave it, but a Docker restart could reorder them; re-running this installer repairs that." ;;
    *)
      hint "It was stopped to fix its network addresses and did not start again. Start it with:"
      hint "  k3d cluster start $CLUSTER_NAME"
      hint "then re-run this installer."
      error "Your secure environment did not start again after its network addresses were fixed (see the install log)." ;;
  esac
}

_wait_for_api() {
  # #562: how long to wait for the API to answer, in seconds. The old hard 60s
  # cap (max=30 × sleep 2) false-failed a slow/proxied laptop that was still
  # loading images on its first kubectl even though `k3d --wait` had returned.
  # Default raised to 180s and made env-tunable (TB_API_WAIT_S); re-running the
  # installer is always safe, so a timeout here is a retryable state in practice.
  local _budget_s
  _budget_s="$(_api_wait_budget_s)"
  log "Waiting for API server to become ready (up to ${_budget_s}s)..."

  # BEFORE the long wait (client-dev#1370): a node whose k3s died on a moved
  # address never comes back on its own, so the wait below could only time out.
  # A no-op when the API answers; repairs a swapped address; fails closed when the
  # address to restore cannot be read.
  #
  # AND AGAIN every TB_NODE_CHECK_EVERY_S while the API stays silent. Measured on
  # a throwaway cluster: for the first 10-30 s after the swap k3s FLAPS — the
  # container restarts once, k3s comes up, the API answers for a moment, then k3s
  # dies for good. A one-shot check that lands in that window sees a live k3s (or
  # an answering API) and passes, and the wait then runs out its whole budget.
  TRACEBLOC_K3S_NODE_FINDING=""
  _ensure_k3s_node_addresses
  local _every
  case "${TB_NODE_CHECK_EVERY_S:-}" in ''|*[!0-9]*) _every=30 ;; *) _every=$((10#${TB_NODE_CHECK_EVERY_S})) ;; esac
  local _next_check=$(( $(date +%s) + _every ))

  _tb_progress_start "Starting your secure environment…"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local f=0
  local _deadline=$(( $(date +%s) + _budget_s )) _t0
  while [[ $(date +%s) -lt $_deadline ]]; do
    # --request-timeout bounds the call itself: the budget here is only re-checked
    # BETWEEN iterations, so an unbounded cluster-info against an API that accepts
    # the TCP connection but never responds (corporate-proxy intercept of
    # localhost, half-booted apiserver) would hang this gate forever.
    if _api_answers; then
      _tb_progress_end
      success "Secure environment ready"
      return
    fi
    if [[ $(date +%s) -ge $_next_check ]]; then
      _tb_progress_clear
      # The re-check's own time is not the API's (the desk on client-dev#1380): a
      # repair inside it runs `k3d cluster start --wait`, bounded at 360 s, so
      # charged to the 180 s budget it ended the wait before the API it had just
      # fixed could answer. The deadline moves by what the check took. That stays
      # finite: the probe and a 2 s sleep are charged between any two checks.
      _t0=$(date +%s)
      _ensure_k3s_node_addresses
      _deadline=$(( _deadline + $(date +%s) - _t0 ))
      _next_check=$(( $(date +%s) + _every ))
    fi
    _tb_progress_frame "${frames[f]}" "Starting your secure environment…"
    f=$(( (f + 1) % ${#frames[@]} ))
    sleep 2
  done
  _tb_progress_end

  # Surface the actual kubeconfig path. KUBECONFIG can be colon-separated
  # (kubectl supports a list); point at the first entry — users with custom
  # multi-file layouts can adapt the sed command themselves.
  local kc="${KUBECONFIG:-${HOME}/.kube/config}"
  kc="${kc%%:*}"
  # A cause the node check ESTABLISHED replaces the list of guesses below.
  if [[ -n "${TRACEBLOC_K3S_NODE_FINDING:-}" ]]; then
    error "kubectl cluster-info failed for ${_budget_s}s. ${TRACEBLOC_K3S_NODE_FINDING}"
  fi
  error "kubectl cluster-info failed for ${_budget_s}s. Cluster reports running, but the API is unreachable. It's safe to re-run this installer; on a slow or proxied machine, extend the wait with TRACEBLOC_API_WAIT_S=<seconds>. Possible causes:
   (a) Docker daemon stopped (run 'docker ps' to verify);
   (b) corporate HTTP/HTTPS proxy intercepting localhost — this installer auto-adds 127.0.0.1/localhost + private ranges to NO_PROXY; a custom proxy wrapper may still override it;
   (c) kubeconfig has 0.0.0.0 — try: sed -i.bak 's|0.0.0.0|127.0.0.1|g' ${kc} && rm ${kc}.bak"
}
