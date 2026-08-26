#!/usr/bin/env bash
# =============================================================================
#  cluster.sh — k3d cluster creation, start, and kubeconfig merge
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
_cluster_exists() {
  # 1) JSON output (exact name match) when jq is available
  if command -v jq &>/dev/null; then
    local _json
    _json="$(k3d cluster list -o json 2>/dev/null || true)"
    if jq -e --arg n "$CLUSTER_NAME" '(.[] | select(.name == $n)) != null' >/dev/null 2>&1 <<<"$_json"; then
      return 0
    fi
  fi
  # 2) Table format: first column is cluster name (--no-headers)
  local _list
  _list="$(k3d cluster list --no-headers 2>/dev/null || true)"
  if awk -v n="$CLUSTER_NAME" '$1 == n { exit 0 } END { exit 1 }' <<<"$_list"; then
    return 0
  fi
  # 3) Fallback: any line whose first column equals CLUSTER_NAME (handles varying table layout)
  if grep -qE "^[[:space:]]*${CLUSTER_NAME}[[:space:]]" <<<"$(k3d cluster list 2>/dev/null || true)"; then
    return 0
  fi
  return 1
}

# Ensure host dirs exist so /tracebloc/data, /tracebloc/logs, /tracebloc/mysql exist inside nodes (HOST_DATA_DIR is mounted as /tracebloc).
# Only chmod the container data subdirs; do not make HOST_DATA_DIR or files like values.yaml world-readable.
_ensure_tracebloc_dirs() {
  mkdir -p "$HOST_DATA_DIR" "$HOST_DATA_DIR/logs" "$HOST_DATA_DIR/mysql"
  chmod -R 777 "$HOST_DATA_DIR/logs" "$HOST_DATA_DIR/mysql" 2>/dev/null || true
  # backend#743: the dataset dir goes under HOST_DATASET_DIR (a network mount,
  # bind-mounted at /tracebloc-data) when set, else stays local under HOST_DATA_DIR.
  local data_base="${HOST_DATASET_DIR:-$HOST_DATA_DIR}"
  mkdir -p "$data_base/data"
  chmod -R 777 "$data_base/data" 2>/dev/null || true
}

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
    * The cluster was created without the data mount. Recreate it:
      'k3d cluster delete ${CLUSTER_NAME}' then re-run this installer.
    * HOST_DATA_DIR changed since the cluster was created (currently ${HOST_DATA_DIR})."
    fi
  done

  rm -f "${HOST_DATA_DIR}/${marker}" 2>/dev/null || true
  log "Verified all ${CLUSTER_NAME} nodes see ${HOST_DATA_DIR} at /tracebloc."
}

# Modes the two SHARED hostPath dirs must end up with. Named constants because the
# same pair is spelled out in two other places — the Windows installer's
# $TB_SHARED_DIR_MODE/$TB_LOGS_DIR_MODE (scripts/install-k8s.ps1) and the chart's
# init-writable-data (client/templates/jobs-manager-deployment.yaml) — and the three
# have to be diffable by eye rather than drifting (#667, #673).
#
# Both get setgid (2) so new entries inherit the group. They differ in the sticky bit,
# deliberately:
#   data -> 2777  setgid + world-write, NO sticky. Sticky permits an unlink only by the
#                 entry's owner, the dir's owner, or root; `data delete` removes a tree
#                 the INGEST wrote (uid 65534) from a pod running as 65532, so sticky
#                 here makes the delete impossible — table dropped, files stranded (#667).
#   logs -> 3777  setgid + sticky. Nothing has to delete another writer's logs, so the
#                 /tmp-style protection costs nothing there.
TB_SHARED_DIR_MODE="2777"
TB_LOGS_DIR_MODE="3777"

# Echo the path:mode pairs this release needs, one per line — the same shape the Windows
# installer's Get-ReleaseDirsSpec and the chart's init-writable-data use, so the parity
# test can diff all three without re-deriving the layout (#673).
#
# backend#743: the dataset dir goes under HOST_DATASET_DIR (network mount) when set, else
# stays local. logs (and mysql, below) always stay on the local HOST_DATA_DIR.
_release_dirs_spec() {
  local release="$1"
  local base="$HOST_DATA_DIR/$release"
  local data_base="${HOST_DATASET_DIR:+$HOST_DATASET_DIR/$release}"
  data_base="${data_base:-$base}"
  printf '%s\n' "$data_base/data:$TB_SHARED_DIR_MODE" "$base/logs:$TB_LOGS_DIR_MODE"
}

# Pre-create the per-release host dirs the chart's hostPath PVs bind to.
# The PVs use /tracebloc/<release>/{data,logs,mysql}, which maps back to
# $HOST_DATA_DIR/<release>/{data,logs,mysql} on the host via the k3d -v mount.
# Without pre-creating these as the host user, kubelet's DirectoryOrCreate
# makes them root:root 0755 and the host user can't drop training data into
# /data/shared.
_ensure_release_dirs() {
  local release="$1"
  [[ -z "$release" ]] && return 0
  local base="$HOST_DATA_DIR/$release"
  # mysql is deliberately left on the flat recursive 777 this function has always used:
  # it has ONE writer (uid 999) and its own init container in the chart, and its datadir
  # permissions are the database's business — the same reason it is out of scope for the
  # Windows prep and for init-writable-data (#654, #673).
  mkdir -p "$base/mysql"
  chmod -R 777 "$base/mysql" 2>/dev/null || true
  local entry dir mode
  while IFS= read -r entry; do
    # Split on the LAST colon at both ends (%:* / ##*:), never the first: HOST_DATA_DIR is
    # a host path the operator chose and may legally contain a colon, while the mode never can.
    dir="${entry%:*}"; mode="${entry##*:}"
    mkdir -p "$dir"
    # No -R. The directory's own mode is what governs creation and unlink inside it;
    # recursing would stamp setgid/sticky onto every data FILE below, and on a dataset
    # tree it is a full walk for nothing. Best-effort, as before: a bind mount that
    # cannot represent POSIX modes must not abort the install (on Linux the chart's
    # init-writable-data fixes the same dirs again at pod start).
    chmod "$mode" "$dir" 2>/dev/null || true
  done < <(_release_dirs_spec "$release")
}

# --- Corporate-proxy support (authenticated proxies + NO_PROXY hardening) ----
# Cluster-internal destinations that must NEVER be routed through a corporate
# proxy: loopback, all RFC1918 private ranges (covers the k3s pod CIDR
# 10.42.0.0/16, the service CIDR 10.43.0.0/16, the k3d docker network and node
# IPs in one shot), and the in-cluster DNS suffixes. Sending this traffic out to
# the proxy misroutes in-cluster calls AND makes `k3d cluster create --wait`
# hang. We union these into whatever NO_PROXY the host set. (A tenant that needs
# a *proxied* private-IP destination can narrow this; tracebloc itself only
# pulls from public registries + dials public api.tracebloc.io, so the broad
# bypass is safe for the isolated VM the client runs on.)
TB_NO_PROXY_DEFAULTS="localhost,127.0.0.1,0.0.0.0,169.254.169.254,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,.cluster.local,host.k3d.internal"

# Echo an effective NO_PROXY = host NO_PROXY/no_proxy ∪ TB_NO_PROXY_DEFAULTS,
# de-duplicated with first-seen order preserved (host entries first).
_augment_no_proxy() {
  local existing="${NO_PROXY:-${no_proxy:-}}"
  printf '%s,%s' "$existing" "$TB_NO_PROXY_DEFAULTS" \
    | awk -v RS=',' '{ gsub(/[ \t\r\n]/, ""); if ($0 != "" && !seen[$0]++) printf "%s%s", (n++ ? "," : ""), $0 }'
}

# Build a k3d config file that carries the proxy env vars as structured YAML
# entries, and echo its path. We use --config rather than --env KEY=VALUE@FILTER
# because k3d splits the --env flag on '@', which corrupts authenticated-proxy
# URLs (http://user:pass@host); the YAML env list has no such ambiguity, so
# credentials survive intact. NO_PROXY is always emitted (auto-augmented) when a
# proxy is present, so in-cluster traffic bypasses the proxy even if the host
# set only HTTP_PROXY. Echoes nothing when the host has no HTTP(S) proxy set.
_write_k3d_proxy_config() {
  local var have_http=""
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    [[ -n "${!var:-}" ]] && have_http=1
  done
  [[ -z "$have_http" ]] && return 0

  local no_proxy_val; no_proxy_val="$(_augment_no_proxy)"
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
    for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
      [[ -z "${!var:-}" ]] && continue
      printf '  - envVar: "%s=%s"\n    nodeFilters:\n      - all\n' "$var" "${!var}"
    done
    printf '  - envVar: "NO_PROXY=%s"\n    nodeFilters:\n      - all\n' "$no_proxy_val"
    printf '  - envVar: "no_proxy=%s"\n    nodeFilters:\n      - all\n' "$no_proxy_val"
  } > "$cfg"
  echo "$cfg"
}

# --- Corporate MITM CA trust for in-node containerd pulls (#424) --------------
# Proxy REACHABILITY reaches the nodes (above), but on a TLS-inspecting network
# the nodes still don't TRUST the corporate CA, so every in-node containerd pull
# (rancher/k3s, ghcr.io/k3d-io, tracebloc images) fails x509 — then masked into a
# root-cause-free "an image couldn't be pulled". When the operator supplies the
# CA bundle we mount it into every node and point containerd at it per-registry.

# The registries the cluster pulls from; behind a break-and-inspect proxy each
# needs the corporate CA to validate the intercepted cert.
TB_CA_REGISTRIES=(docker.io registry-1.docker.io auth.docker.io ghcr.io)

# Echo the operator's CA bundle path (absolute) when TRACEBLOC_CA_BUNDLE or
# CURL_CA_BUNDLE is set and readable. If a var is set but the file is unreadable,
# echo the offending var NAME and return 2 — the caller turns that into a hard
# error (a silent skip would drop them straight back into the x509 failure they
# set the var to fix). Empty stdout + return 0 when no CA var is set.
_resolve_ca_bundle() {
  local var val
  for var in TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE; do
    val="${!var:-}"; [[ -z "$val" ]] && continue
    # Require a readable regular FILE, not just -r: a directory of PEMs is readable
    # but would bind-mount over the single-file node path and containerd can't read
    # it as a ca_file — the silent "looks applied but still x509" case. Mirrors the
    # PS Resolve-CaBundle -PathType Leaf check (reviewer).
    if [[ ! -r "$val" || ! -f "$val" ]]; then echo "$var"; return 2; fi
    case "$val" in /*) : ;; *) val="$(cd "$(dirname "$val")" 2>/dev/null && pwd)/$(basename "$val")" ;; esac
    echo "$val"; return 0
  done
  return 0
}

# Wire the resolved corporate CA into the HOST tools that do NOT honor a CA env on
# their own (#583). git (OpenSSL-backed) honors GIT_SSL_CAINFO on Linux + macOS. The
# Go tools (cosign/helm) read SSL_CERT_FILE on LINUX only — on macOS Go uses the
# system Keychain and IGNORES SSL_CERT_FILE (Bugbot), so there the CA must live in the
# Keychain (or use the offline path, #584). curl ALREADY honors the user's own
# CURL_CA_BUNDLE natively, so we do NOT re-export it (it's replace-not-augment, and a
# corp-root-only bundle would drop the public roots). The k3d NODES are trusted
# separately at cluster-create (#424). Idempotent; no-op when no CA is configured;
# fails fast on a set-but-unreadable bundle. The announce names only what actually
# takes effect on this platform.
wire_ca_trust() {
  local ca rc=0
  ca="$(_resolve_ca_bundle)" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    error "$ca is set but its CA bundle file can't be read — fix its path/permissions and re-run."
  fi
  [[ -z "$ca" ]] && return 0
  # On macOS, wire NOTHING (same decision as Windows, and for the same reason):
  # Go reads the Keychain, not SSL_CERT_FILE, so exporting it helps neither
  # cosign nor helm — while OpenSSL-backed curl DOES honor it, replace-not-
  # augment, so a corp-root-only bundle would shrink download trust for zero
  # gain (Bugbot). And Apple's system git (SecureTransport) ignores
  # GIT_SSL_CAINFO, so claiming git trust from it was false — the clone that
  # matters most, Homebrew's own bootstrap, runs system git (Bugbot).
  if [[ "$OS" == "Darwin" ]]; then
    hint "On macOS, git, cosign and helm read the system Keychain, not a PEM file — add your company's CA to the login Keychain (or use the offline installer) so they trust the proxy."
    return 0
  fi
  # Only set trust vars the user hasn't already set: SSL_CERT_FILE and GIT_SSL_CAINFO
  # are replace-not-augment (Go / OpenSSL), so overwriting a fuller pre-set bundle with
  # a corp-root-only one would drop the public roots those tools need elsewhere (Bugbot).
  #
  # And SAY only what actually happened: a green "Trusting…" while every export was
  # skipped reported wiring that did not happen — masking a pre-set bundle that may
  # still lack the corporate CA (Bugbot). curl "downloads" trust the user's own
  # CURL_CA_BUNDLE, which we deliberately don't touch, so it is never claimed here.
  local wired="" kept=""
  # A var already pointing at OUR CA ($ca) -- whether the installer set it from
  # TRACEBLOC_CA_BUNDLE (the curl|bash path exports SSL_CERT_FILE before launching
  # install-k8s.sh) or the operator set it to the same file -- is WIRED, not a
  # foreign pre-set to keep-and-verify. Reporting it as "keeping your pre-set, verify
  # it" was misleading for a value the installer itself set, and hid the cosign/helm
  # wiring (Bugbot client#631). Only a DIFFERENT pre-set bundle takes the kept branch.
  # `-ef` compares by file identity, robust to relative/absolute/symlink differences.
  if [[ -z "${SSL_CERT_FILE:-}" || "${SSL_CERT_FILE}" -ef "$ca" ]]; then
    export SSL_CERT_FILE="$ca";  wired="cosign, helm"
  else
    kept="SSL_CERT_FILE (cosign/helm)"
  fi
  if [[ -z "${GIT_SSL_CAINFO:-}" || "${GIT_SSL_CAINFO}" -ef "$ca" ]]; then
    export GIT_SSL_CAINFO="$ca"; wired="${wired:+$wired and }git"
  else
    kept="${kept:+$kept and }GIT_SSL_CAINFO (git)"
  fi
  [[ -n "$wired" ]] && success "Trusting your company's certificate for $wired."
  [[ -n "$kept" ]]  && hint "Keeping your pre-set $kept — make sure that bundle includes your company's CA, or those tools will still fail x509."
  return 0
}

# Write a k3d registries.yaml pointing containerd at the mounted CA for every
# registry in TB_CA_REGISTRIES, and echo its path. $1 = the CA path INSIDE the
# node (where the -v mount lands). Caller removes the temp dir.
_write_k3d_registries_config() {
  local node_ca="$1" host td cfg
  td="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3d-reg-XXXXXX")" || return 1
  cfg="$td/registries.yaml"
  {
    echo "configs:"
    for host in "${TB_CA_REGISTRIES[@]}"; do
      printf '  "%s":\n    tls:\n      ca_file: "%s"\n' "$host" "$node_ca"
    done
  } > "$cfg"
  echo "$cfg"
}

# When a proxy is configured, ensure THIS installer's own kubectl/helm/curl
# bypass it for the cluster API (127.0.0.1) and the in-cluster ranges. Go
# already auto-bypasses loopback, but exporting NO_PROXY also covers helm/curl.
_export_host_no_proxy() {
  local var
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ -n "${!var:-}" ]]; then
      local aug; aug="$(_augment_no_proxy)"
      export NO_PROXY="$aug" no_proxy="$aug"
      return 0
    fi
  done
}

# ── Leftover-data guard (RFC-0003 §4 / D3, #376) ─────────────────────────────
# The installer used to `mkdir -p` its data dirs and silently adopt whatever was
# already there — data left by an earlier install (different layout, older
# version, custom dir) got picked up by the next install, so a "fresh" install
# was not guaranteed fresh. This guard detects real leftover data at install
# time and forces a choice instead of adopting it. It doubles as the migration
# prompt for the node-local transition (#367): existing ~/.tracebloc data is
# never silently stranded.
#
# Where prompts READ from (mirrors provision.sh/install-client-helm.sh so the
# curl|bash path can still prompt on the controlling terminal; overridable so
# tests can feed canned input via TB_TTY=/dev/stdin).
: "${TB_TTY:=/dev/tty}"

# True only when $TB_TTY can actually be OPENED for reading. A plain `-r` test is
# not enough: /dev/tty is world-readable even with no controlling terminal (CI,
# `curl|bash`), so `-r` would route those runs into the interactive branch where
# the `read` then fails immediately and the guard aborts with the generic abort
# text instead of the non-interactive guidance that lists --reuse-data/--wipe-data
# (Bugbot #384). Mirrors the openability probe assess.sh already uses.
_tty_usable() { { : <"$TB_TTY"; } 2>/dev/null; }

# Echo each dir under HOST_DATA_DIR that holds real client data — a MySQL data
# dir or a dataset dir with at least one file — across BOTH on-disk layouts:
# flat ($HOST_DATA_DIR/{mysql,data}) and per-release ($HOST_DATA_DIR/<rel>/…).
# Deliberately scoped to HOST_DATA_DIR only: HOST_DATASET_DIR may be a shared
# network mount other tools use, so the guard never scans or touches it. Empty
# dirs, values.yaml and install-*.log are not data and are ignored.
_leftover_data_dirs() {
  local base="${HOST_DATA_DIR:-}"
  [[ -n "$base" && -d "$base" ]] || return 0
  local -a candidates=("$base/mysql" "$base/data")
  local sub
  for sub in "$base"/*/; do
    # Skip symlinked per-release dirs: base is physically resolved (validate_config
    # uses `cd -P`), so a real subdir can't escape it — but a symlink could point
    # anywhere, and $base/<link>/mysql would let the wipe's rm -rf follow it
    # outside HOST_DATA_DIR (Bugbot #384). Not walking symlinks keeps scope honest.
    [[ -d "$sub" && ! -L "${sub%/}" ]] || continue
    # Skip the flat-layout data dirs themselves — they are already candidates
    # above. Descending into them would mislabel a real MySQL datadir's nested
    # `mysql` system schema ($base/mysql/mysql) as a second leftover root, which
    # confuses the prompt and doubles up wipe targets (Bugbot #384).
    case "${sub%/}" in "$base/mysql"|"$base/data") continue ;; esac
    candidates+=("${sub%/}/mysql" "${sub%/}/data")
  done
  local d
  for d in "${candidates[@]}"; do
    # ! -L: never treat a symlink as a data dir — it would let the wipe traverse
    # outside HOST_DATA_DIR (Bugbot #384). A symlinked data path is out of scope.
    [[ -d "$d" && ! -L "$d" ]] || continue

    # Fail closed on an unlistable dir: a root/container-owned mysql/data dir the
    # host user can't read/enter can't be proven empty, so treat it as a leftover
    # rather than mistake it for a clean slate and adopt it (Bugbot #384; same
    # ownership case the wipe path treats as fatal). This is the common shape —
    # the whole data dir is owned by the container uid. No temp file, so it can't
    # itself fail open (an earlier mktemp-based version could when mktemp failed).
    if [[ ! -r "$d" || ! -x "$d" ]]; then
      echo "$d"; continue
    fi

    # Readable dir → non-empty test. pipefail-safe AND portable (GNU + BSD/macOS:
    # no -quit): a `find | head -1 | grep` pipeline SIGPIPEs find once output
    # exceeds the pipe buffer (a real multi-table MySQL dir), and under the
    # installer's `set -o pipefail` that reads as "empty" — the exact leftover
    # this guard must catch. `read < <(find …)` keeps find's status out of the
    # check and short-circuits after one line. The `||` fallback (only reached
    # when no top-level file was read) captures find's stderr WITHOUT a temp file
    # — so an unreadable *sub*dir (Permission denied) is also caught, not skipped.
    if read -r _ < <(find "$d" -type f 2>/dev/null) \
       || [[ -n "$(find "$d" -type f 2>&1 >/dev/null)" ]]; then
      echo "$d"
    fi
  done
}

# Read one line from $TB_TTY into the named variable, stripping bracketed-paste
# / CSI escape garbage (arrow keys, pastes survive `read -r`) and trimming
# surrounding whitespace — so a paste or a spaces-then-Enter can't smuggle
# control bytes into HOST_DATA_DIR or slip past a non-empty check. Mirrors the
# provision.sh client-name handling (_strip_paste_garbage + trim).
_read_sanitized() {
  local __prompt="$1" __var="$2" __in=""
  read -r -p "$__prompt" __in <"$TB_TTY" || __in=""
  __in="$(_strip_paste_garbage "$__in")"
  __in="${__in#"${__in%%[![:space:]]*}"}"; __in="${__in%"${__in##*[![:space:]]}"}"
  printf -v "$__var" '%s' "$__in"
}

# Delete the detected leftover data dirs. Only ever removes paths UNDER the
# already-validated HOST_DATA_DIR (validate_config guarantees it is under $HOME
# and not a system path) — never HOST_DATASET_DIR, never a system path. Returns
# non-zero if anything survived the wipe (e.g. root/container-owned MySQL files
# the host user can't remove) so the caller can fail closed instead of letting
# create_cluster adopt the survivors — a warn-and-proceed would silently break
# the "wipe means gone" guarantee.
_wipe_leftover_data() {
  # Belt-and-suspenders (Lukas review, #384): never wipe unless HOST_DATA_DIR is
  # a non-empty path strictly under $HOME — exactly what validate_config enforces.
  # This guards the rm below even if a future refactor ever calls the guard before
  # validate_config: an empty HOST_DATA_DIR would collapse the "$HOST_DATA_DIR"/*
  # case pattern to /* and defeat the scope check. Placed in the destructive
  # function itself so it holds for every caller, not just the current one.
  [[ -n "${HOST_DATA_DIR:-}" && "$HOST_DATA_DIR" == "$HOME"/* ]] \
    || error "Refusing to wipe: HOST_DATA_DIR is unset or not under \$HOME (got '${HOST_DATA_DIR:-}')."
  local d rc=0
  for d in "$@"; do
    case "$d" in
      "$HOST_DATA_DIR"/*)
        # Backstop for the symlink case (detection already skips symlinks): never
        # rm -rf a symlink — it would delete the target OUTSIDE HOST_DATA_DIR.
        if [[ -L "$d" ]]; then
          warn "Refusing to wipe symlink ${d} — it could point outside ${HOST_DATA_DIR}; remove it by hand."
          rc=1; continue
        fi
        log "Wiping leftover data: ${d}"
        rm -rf "$d" 2>/dev/null || true
        # Verify — do not trust rm's exit code alone.
        if [[ -e "$d" ]]; then
          warn "Could not remove ${d} — files may be owned by another user (root/container)."
          rc=1
        fi
        ;;
      *)
        warn "Refusing to wipe ${d} — outside ${HOST_DATA_DIR}."
        rc=1
        ;;
    esac
  done
  return "$rc"
}

# Guard entry point. Called from create_cluster ONLY when creating a NEW cluster
# (an existing cluster is an in-place reuse/upgrade whose data stays by design,
# §3.3). Resolves an action from TB_LEFTOVER_ACTION (set by --reuse-data /
# --wipe-data, or directly) or, failing that, an interactive prompt. When there
# is no terminal and no explicit action, it fails safe: abort, never adopt.
guard_leftover_data() {
  [[ -n "${TRACEBLOC_SKIP_LEFTOVER_GUARD:-}" ]] && return 0

  local -a found=()
  local d
  while IFS= read -r d; do [[ -n "$d" ]] && found+=("$d"); done < <(_leftover_data_dirs)
  [[ ${#found[@]} -eq 0 ]] && return 0   # clean slate — nothing to guard

  warn "Existing tracebloc data found under ${HOST_DATA_DIR}:"
  for d in "${found[@]}"; do hint "  • ${d}"; done
  # The "silently adopt" warning is true ONLY for hostpath. Under node-local (the
  # default since D15, client#456) a fresh install does NOT adopt this data — the
  # cluster starts empty in-node and the host data is stranded. Leading with the
  # adopt claim there would contradict the very next line (client#456 Bugbot).
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    hint "node-local storage keeps data inside the cluster node — a fresh install does NOT adopt this ~/.tracebloc data; it would be stranded, not used."
  else
    hint "A fresh install would silently adopt it, so it would not really be fresh."
  fi

  local action="${TB_LEFTOVER_ACTION:-}"
  if [[ -z "$action" ]]; then
    if _tty_usable; then
      prompt_header "How should the installer handle it?"
      if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
        # node-local can't adopt the host data (no /tracebloc bind-mount) — the
        # cluster starts empty in-node — so don't offer "reuse = adopt" here (#367).
        hint "  [r] keep  — leave the existing data on disk, unused (node-local starts empty; it is NOT adopted)"
      else
        hint "  [r] reuse — keep and adopt the existing data"
      fi
      hint "  [w] wipe  — delete it and start fresh"
      hint "  [n] new   — install into a different directory"
      hint "  [a] abort — stop and sort it out myself (default)"
      local reply=""
      _read_sanitized "  Choice [r/w/n/a]: " reply
      # Accept the word we SHOW: node-local relabels [r] to "keep", so r/reuse AND
      # k/keep must both map to the reuse action or a user typing the shown "keep"
      # would fall through to abort (Bugbot). Lowercase via tr (bash 3.2-safe — no
      # ${x,,}) so any casing works.
      local choice; choice=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
      case "$choice" in
        r|reuse|k|keep) action=reuse ;;
        w|wipe)         action=wipe ;;
        n|new)          action=newdir ;;
        *)              action=abort ;;
      esac
    else
      # Non-interactive with no explicit choice → fail safe. Describe --reuse-data
      # honestly per storage mode: under node-local it keeps the data on disk but
      # does NOT adopt it (the cluster starts empty in-node), matching the
      # interactive reuse branch below (Bugbot).
      local reuse_desc="adopt the existing data"
      [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]] && \
        reuse_desc="keep the data on disk, NOT adopted (node-local starts empty in-node)"
      error "Existing data found under ${HOST_DATA_DIR} and no choice was given (no terminal). Re-run with one of:
  --reuse-data                    ${reuse_desc}
  --wipe-data                     delete it and start fresh
  HOST_DATA_DIR=<new-path> ...    install into a different directory
  (or TRACEBLOC_SKIP_LEFTOVER_GUARD=1 to bypass this guard entirely)"
    fi
  fi

  case "$action" in
    reuse)
      if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
        # node-local starts empty in-node — the host data is NOT adopted (RFC-0003
        # §4 / #367). Keep the files on disk but say so plainly, so "reuse" never
        # silently claims an adoption that node-local can't actually do.
        warn "node-local storage can't adopt ${HOST_DATA_DIR} — the new cluster starts empty inside the node."
        hint "Your existing data is left on disk, untouched but unused. Re-ingest it after setup ('tracebloc data ingest'), or use hostpath storage (TB_STORAGE_MODE=hostpath) to keep using it in place."
        log "node-local: left ${HOST_DATA_DIR} on disk (NOT adopted — no host bind-mount)."
      else
        log "Reusing existing data under ${HOST_DATA_DIR} (user choice)."
      fi
      ;;
    wipe)
      # Fail closed: if any data survived the wipe, abort rather than fall
      # through to create_cluster, which would adopt the survivors and silently
      # break the "wipe means gone" guarantee.
      if ! _wipe_leftover_data "${found[@]}"; then
        error "Could not fully wipe existing data under ${HOST_DATA_DIR} — some files could not be removed (often root/container-owned MySQL files). Remove them manually (e.g. 'sudo rm -rf ${HOST_DATA_DIR}') and re-run, or choose a different directory. Refusing to proceed and adopt the leftovers."
      fi
      if [[ -n "${HOST_DATASET_DIR:-}" ]]; then
        hint "Left HOST_DATASET_DIR (${HOST_DATASET_DIR}) untouched — it is a shared mount, not wiped."
      fi
      log "Wiped leftover data under ${HOST_DATA_DIR} (user choice)."
      ;;
    newdir)
      local newdir=""
      _tty_usable && _read_sanitized "  New data directory (absolute or under \$HOME): " newdir
      [[ -n "$newdir" ]] || error "No new directory given — aborting."
      HOST_DATA_DIR="$newdir"
      # Re-resolve + re-validate the new path, then re-check it for leftovers too.
      if declare -F validate_config >/dev/null 2>&1; then validate_config; fi
      log "Switched HOST_DATA_DIR to ${HOST_DATA_DIR}; re-checking it for leftover data."
      guard_leftover_data
      ;;
    abort|*)
      error "Aborted — existing data under ${HOST_DATA_DIR} left untouched. Choose reuse / wipe / a new directory and re-run."
      ;;
  esac
}

create_cluster() {
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

  # Leftover-data guard (RFC-0003 D3, #376): a NEW cluster must not silently
  # adopt data from an earlier install. Skipped when the cluster already exists
  # — that path is an in-place reuse/upgrade and keeps its data by design (§3.3).
  if ! _cluster_exists; then
    guard_leftover_data
  fi

  # node-local (RFC-0003 Option C): no host data dirs, no bind-mount, no chmod —
  # data lives on k3s local-path inside the node. Only the hostpath model needs
  # the pre-created world-writable ~/.tracebloc dirs.
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    log "Storage mode: node-local — datasets live inside the cluster node (k3s local-path), not ~/.tracebloc; they are wiped on 'cluster delete'."
  else
    _ensure_tracebloc_dirs
  fi

  # Docker is up now (unlike at preflight time), so re-check the runtime's real
  # memory budget — a too-small Docker VM (Mac/Win) surfaces before we build out.
  # Guarded: cluster.sh can be sourced without preflight.sh (e.g. the e2e harness).
  if declare -F _pf_recheck_runtime_mem >/dev/null 2>&1; then _pf_recheck_runtime_mem || true; fi

  if _cluster_exists; then
    _handle_existing_cluster
  else
    _create_new_cluster
  fi

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
# Opt out with TRACEBLOC_NO_AUTOSTART=1.
ensure_cluster_autostart() {
  if [[ -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then return 0; fi

  local nodes node
  nodes=$(docker ps -a --filter "name=k3d-${CLUSTER_NAME}-" --format '{{.Names}}' 2>/dev/null) || return 0
  if [[ -n "$nodes" ]]; then
    for node in $nodes; do
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
  if command -v jq &>/dev/null; then
    CLUSTER_STATUS=$(k3d cluster list -o json 2>/dev/null | jq -r --arg n "$CLUSTER_NAME" '.[] | select(.name == $n) | .serversRunning // 0' 2>/dev/null || echo "0")
  else
    # Capture-then-match (#680): awk's `exit` closes the pipe on our cluster's
    # row, so k3d can take SIGPIPE and pipefail would abort the installer here —
    # mid-reconcile, with no message. Mirrors _assess_cluster_servers_running.
    local line _tbl
    _tbl="$(k3d cluster list --no-headers 2>/dev/null || true)"
    line=$(awk -v n="$CLUSTER_NAME" '$1 == n { print $2; exit }' <<<"$_tbl")
    if [[ -n "$line" ]]; then
      CLUSTER_STATUS="${line%%/*}"
    fi
  fi
  CLUSTER_STATUS="${CLUSTER_STATUS:-0}"

  if [[ "$CLUSTER_STATUS" -gt "0" ]]; then
    success "Secure environment already running."
  else
    log "Cluster '$CLUSTER_NAME' exists but is stopped — starting it..."
    # Capture the tool's raw stderr to the log and surface only a curated line on
    # failure — graceful failure, not a raw k3d dump before the closer (#577).
    # Bounded start (Bugbot): `k3d cluster start` waits for the server with no
    # deadline by default, so behind the log redirect a wedged Docker would hang a
    # headless install forever instead of reaching the curated error below. --wait
    # --timeout bounds it (parity with the Windows installer's 5-minute start
    # deadline) so a stuck start fails cleanly into that message.
    k3d cluster start "$CLUSTER_NAME" --wait --timeout 5m >> "${LOG_FILE:-/dev/null}" 2>&1 \
      || error "Couldn't start your existing secure environment. Check Docker is running, then re-run."
    success "Secure environment started."
  fi

  _check_existing_cluster_proxy
  _check_existing_cluster_ca
  _check_existing_cluster_bind
  _check_existing_cluster_dataset_mount
  _check_existing_cluster_storage_mode
  _check_existing_cluster_k8s_version
  # GPU capability is fixed at create time: a reused CPU-only node can't run GPU
  # pods, so drop the GPU request here rather than strand jobs Pending (client#835).
  _check_existing_cluster_gpu
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
  cluster_env=$(docker inspect "$server_container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$cluster_env" ]] && return 0

  local missing=()
  for var in "${candidates[@]}"; do
    # Here-string (#680): `grep -Eq` stops at the first match, so echo can take
    # SIGPIPE and pipefail would report a variable as MISSING when it is present,
    # producing a spurious "cluster is missing proxy env" warning.
    grep -Eq "^${var}=" <<<"$cluster_env" || missing+=("$var")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    warn "Host has proxy env set, but the existing '$CLUSTER_NAME' cluster is missing: ${missing[*]}."
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
  mounts=$(docker inspect "$server_container" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null) || return 0
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
  binds=$(docker inspect "k3d-${CLUSTER_NAME}-serverlb" \
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

# backend#743: the dataset bind mount (HOST_DATASET_DIR -> /tracebloc-data) is
# baked into the k3d nodes at create time (_create_new_cluster). k3d cannot add
# a bind mount to a RUNNING cluster, so re-using an existing cluster that lacks
# it would point the chart's `datasetPath: /tracebloc-data` PV at ephemeral
# in-node storage — datasets would silently land on disposable storage instead
# of the network export and vanish on a restart. Fail fast with the recreate
# remedy rather than installing a quietly-misrouted dataset volume. No-op when
# HOST_DATASET_DIR is unset or the node can't be inspected.
_check_existing_cluster_dataset_mount() {
  [[ -z "${HOST_DATASET_DIR:-}" ]] && return 0
  local mounts
  mounts=$(docker inspect "k3d-${CLUSTER_NAME}-server-0" \
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
  mounts=$(docker inspect "k3d-${CLUSTER_NAME}-server-0" \
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
      warn "TB_STORAGE_MODE=node-local, but the existing '$CLUSTER_NAME' cluster was built for hostpath storage."
    else
      warn "node-local is the default now (RFC-0003 D15), but the existing '$CLUSTER_NAME' cluster was built for hostpath storage."
    fi
    hint "That cluster disabled k3s local-storage, so the 'local-path' StorageClass node-local needs does not exist — PVCs would stay Pending."
    hint "To keep using your existing hostpath cluster, just re-run with the old mode — no recreate needed:"
    hint "  TB_STORAGE_MODE=hostpath  re-run this installer."
    hint "Or, to move this cluster to node-local (storage topology is fixed at create time), recreate it:"
    _recreate_cluster_hint "TB_STORAGE_MODE=node-local  "
    echo ""
    error "Existing cluster's storage topology (hostpath) does not match node-local — set TB_STORAGE_MODE=hostpath to keep it, or recreate for node-local."
  elif [[ "$want" == "hostpath" && "$cluster_is_hostpath" == false ]]; then
    echo ""
    warn "TB_STORAGE_MODE=hostpath, but the existing '$CLUSTER_NAME' cluster was built for node-local storage."
    hint "That cluster has no /tracebloc bind mount, so hostPath volumes would land on ephemeral in-node storage"
    hint "(lost on 'cluster delete'), not ~/.tracebloc. Storage topology is fixed at create time; recreate to switch:"
    _recreate_cluster_hint
    echo ""
    error "Existing cluster's storage topology (node-local) does not match TB_STORAGE_MODE=hostpath — refusing to install datasets onto ephemeral storage."
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
# populates K3D_GPU_FLAGS (=--gpus=all) and the chart requests a GPU BEFORE we know
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
  K3D_GPU_FLAGS=()
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
# isn't known on this path, so ask the LIVE cluster instead: does it request a GPU
# it can't schedule? Warn with the recreate remedy (non-fatal; the client is up).
# Mirrors the Windows twin's Test-HealthyClusterGpuConsistent. Self-contained + jq-
# free so it needs no other lib. Bounded; silent no-op when it can't tell (no
# helm/kubectl, or nothing requests a GPU).
_check_healthy_cluster_gpu_consistent() {
  has helm && has kubectl || return 0
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
      # A NON-EMPTY GPU_REQUESTS: means this release asks for a GPU (GPU_REQUESTS: ""
      # is CPU and must not match — the char after the optional quote must be real).
      if grep -Eq '^[[:space:]]*GPU_REQUESTS:[[:space:]]*"?[^"[:space:]]' <<<"$vals"; then found_req=1; break; fi
    fi
  done <<<"$list"
  (( found_req )) || return 0   # nothing requests a GPU → consistent, nothing to warn

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
# a usable spec do we fall CLOSED to CPU (clear K3D_GPU_FLAGS) so the chart doesn't
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
    K3D_GPU_FLAGS=()
    warn "No cluster node has a usable NVIDIA CDI spec — running CPU mode so GPU jobs aren't stranded Pending."
    hint "Check the NVIDIA driver + 'docker run --rm --gpus all ${TB_CUDA_BASE_TAG:+nvidia/cuda:$TB_CUDA_BASE_TAG} nvidia-smi' works on this host, then re-run."
  fi
}

_create_new_cluster() {
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
  # `@all`, NOT `@server:*`. AGENTS defaults to 1 (common.sh), and an agent runs a
  # kubelet too — scoping this to the server would leave the agent kubelet refusing
  # to start on a cgroup v1 host, so `--wait` fails or the cluster sits half-ready:
  # the exact refusal this block exists to prevent (#806 Bugbot, High). The
  # `--disable=` args above are `@server:*` because addon deployment is a
  # server-only concern; a kubelet arg is not, and the two must not be copied from
  # each other. `--kubelet-arg` is accepted by both `k3s server` and `k3s agent`.
  if [[ "${K8S_VERSION}" == "latest" ]] || ! _version_lt "${K8S_VERSION#v}" "1.31.0"; then
    K3D_ARGS+=(--k3s-arg "--kubelet-arg=fail-cgroupv1=false@all")
  fi

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
  # TB_SKIP_GPU_IMAGE_PREPULL bypasses it.
  if _gpu_wired && [[ -n "$K8S_VERSION" && "$K8S_VERSION" != "latest" && -z "${TB_SKIP_GPU_IMAGE_PREPULL:-}" ]]; then
    local _prepull_image _prepull_min _gpu_ok=1
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
    ( docker pull "$_prepull_image" >>"${LOG_FILE:-/dev/null}" 2>&1 ) &
    spin "$!" "Fetching the GPU-capable runtime (${_prepull_image##*/})…" "$(( _prepull_min * 60 ))" || _gpu_ok=0
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
    if (( ! _gpu_ok )); then
      K3D_GPU_FLAGS=()
      warn "Couldn't pull or validate the GPU node image (${_prepull_image}) — installing CPU-only so the cluster still comes up."
      hint "To enable GPU, make sure this host can pull AND run ${_prepull_image} (for a private registry set TRACEBLOC_IMAGE_REGISTRY + TRACEBLOC_REGISTRY_USERNAME/PASSWORD), then re-run."
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
      K3D_GPU_FLAGS=()
      warn "GPU disabled: K8S_VERSION=latest has no matching GPU node image — pin K8S_VERSION to enable GPU."
    fi
  elif _gpu_wired && [[ -n "$K8S_VERSION" ]]; then
    local _gpu_image; _gpu_image="$(_gpu_node_image)"
    K3D_ARGS+=(--image "$_gpu_image")
    log "GPU node image: ${_gpu_image} (NVIDIA Container Toolkit + 'nvidia' RuntimeClass baked in)."
  elif [[ -n "$K8S_VERSION" ]]; then
    K3D_ARGS+=(--image "rancher/k3s:${K8S_VERSION}")
  fi

  if [[ ${#K3D_GPU_FLAGS[@]} -gt 0 ]]; then
    K3D_ARGS+=("${K3D_GPU_FLAGS[@]}")
    log "GPU flag(s) active: ${K3D_GPU_FLAGS[*]}"
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
  ( k3d "${K3D_ARGS[@]}" >"$create_out" 2>&1 ) &
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
      _handle_existing_cluster
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
  # No success line here — _wait_for_api prints the single "Secure environment
  # ready" once the API server actually answers (the true ready signal).
  log "k3d cluster '$CLUSTER_NAME' created."
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
}

_wait_for_api() {
  local logfile="${LOG_FILE:-/tmp/tracebloc-spin.log}"
  # #562: how long to wait for the API to answer, in seconds. The old hard 60s
  # cap (max=30 × sleep 2) false-failed a slow/proxied laptop that was still
  # loading images on its first kubectl even though `k3d --wait` had returned.
  # Default raised to 180s and made env-tunable (TB_API_WAIT_S); re-running the
  # installer is always safe, so a timeout here is a retryable state in practice.
  local _budget_s
  case "${TB_API_WAIT_S:-}" in ''|*[!0-9]*) _budget_s=180 ;; *) _budget_s=$((10#${TB_API_WAIT_S})) ;; esac
  log "Waiting for API server to become ready (up to ${_budget_s}s)..."

  tput civis 2>/dev/null || true
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local f=0
  local _deadline=$(( $(date +%s) + _budget_s ))
  while [[ $(date +%s) -lt $_deadline ]]; do
    # --request-timeout bounds the call itself: the budget here is only re-checked
    # BETWEEN iterations, so an unbounded cluster-info against an API that accepts
    # the TCP connection but never responds (corporate-proxy intercept of
    # localhost, half-booted apiserver) would hang this gate forever.
    if kubectl cluster-info --request-timeout=5s &>/dev/null 2>&1; then
      printf "\r\033[K"
      tput cnorm 2>/dev/null || true
      success "Secure environment ready"
      return
    fi
    printf "\r  ${CYAN}%s${RESET} Starting your secure environment…" "${frames[f]}"
    f=$(( (f + 1) % ${#frames[@]} ))
    sleep 2
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true

  # Surface the actual kubeconfig path. KUBECONFIG can be colon-separated
  # (kubectl supports a list); point at the first entry — users with custom
  # multi-file layouts can adapt the sed command themselves.
  local kc="${KUBECONFIG:-${HOME}/.kube/config}"
  kc="${kc%%:*}"
  error "kubectl cluster-info failed for ${_budget_s}s. Cluster reports running, but the API is unreachable. It's safe to re-run this installer; on a slow or proxied machine, extend the wait with TB_API_WAIT_S=<seconds>. Possible causes:
   (a) Docker daemon stopped (run 'docker ps' to verify);
   (b) corporate HTTP/HTTPS proxy intercepting localhost — this installer auto-adds 127.0.0.1/localhost + private ranges to NO_PROXY; a custom proxy wrapper may still override it;
   (c) kubeconfig has 0.0.0.0 — try: sed -i.bak 's|0.0.0.0|127.0.0.1|g' ${kc} && rm ${kc}.bak"
}
