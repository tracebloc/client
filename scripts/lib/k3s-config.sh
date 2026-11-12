#!/usr/bin/env bash
# =============================================================================
#  k3s-config.sh — native k3s's configuration: the join token, the filesystem under
#  k3s's data, the write of config.yaml, the node name and the pod/service ranges
#
#  LINUX ONLY. Moved out of k3s.sh; install-k8s.sh sources it right after k3s.sh and
#  k3s-firewall.sh, and both bootstraps fetch it. Every function keeps the
#  `_native_k3s_` prefix; the renderer and the paths it writes stay in k3s.sh.
#  bash 3.2-safe; sourcing it has no side effects: constants and functions only.
# =============================================================================

# ── The join token ──────────────────────────────────────────
#
# k3s encrypts its datastore's bootstrap data with the server's join token. Given
# none, it reads <data-dir>/server/token, which it rewrites on every start
# (truncated, written again, never synced). A host that loses power, or a WSL distro
# whose disk is cut off, seconds after a start can find that file torn, and k3s then
# refuses its own data on every start after: "bootstrap data already found and
# encrypted with different token". The window is small where a filesystem writes a
# file's data before the metadata naming it (ext4 data=ordered or data=journal with
# barriers, xfs, btrfs), and nothing closes it under data=writeback, nobarrier, or
# mount options that cannot be read. So the token is pinned on every native host:
# written once to TB_K3S_TOKEN_PATH, and named by config.yaml's `token-file`, a file
# k3s reads and never writes. The macOS node pins its own (_mac_ct_node_token).

# The join token as this installer makes it, and as k3s makes its own when it is
# given none (util.Random(16)): 16 random bytes in hex.
TB_K3S_TOKEN_RE='^[0-9a-f]{32}$'
# What a k3s that cannot be repaired in place needs, said by every refusal that ends there.
TB_K3S_REINSTALL='run "tracebloc delete" (it removes k3s and its data), then install again'

# _native_k3s_pin_token -- the join token in TB_K3S_TOKEN_PATH (root, 0600) before
# config.yaml names it; the caller made its directory. As root, through tb_root.
#   - The file is there: it is the token. A run never makes another: one that cannot
#     be read, or is not a token, is refused by name and left as it is.
#   - It is not, and k3s has no data (no server/cred/passwd, no server/token under
#     TB_K3S_DATA_PATH): 16 new random bytes.
#   - It is not, on a k3s this installer set up before it pinned the token: the token
#     that k3s already has. k3s keeps it twice, as the user "server" in
#     server/cred/passwd and after "::server:" in server/token, and the two must
#     say the same.
#   Anything else is refused by name, never answered with a new token: data
#   encrypted with another token never starts again.
# The token goes to a scratch name beside the file, is synced, renamed over it, and
# the directory is synced: whatever the filesystem orders, a host that loses power
# finds no file or the whole one, never a torn one. A sudo that did not run is
# "cannot tell", never an absent file.
# Under --print the reads run as this user, who can see the file but not read it, and
# cannot see k3s's data: a file that is there is kept (the run writes nothing), and
# otherwise the writes are listed, the same ones a carried token makes.
# _native_k3s_pin_token runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__native_k3s_pin_token below is the function itself.
_native_k3s_pin_token() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__native_k3s_pin_token "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__native_k3s_pin_token() {
  local file="$TB_K3S_TOKEN_PATH" srv="${TB_K3S_DATA_PATH}/server" t="" passwd="" tok="" p="" tmp
  local how="$TB_K3S_REINSTALL"
  if tb_root test -e "$file"; then
    tb_root_planning && return 0
    t="$(tb_root cat "$file")" \
      || error "native k3s: ${file} cannot be read, so this run cannot tell k3s's join token, and it never makes a new one. Check that sudo can read it ('sudo cat ${file}'), then re-run."
    [[ "$t" =~ $TB_K3S_TOKEN_RE ]] \
      || error "native k3s: ${file} does not hold a join token this installer wrote, and this run never replaces it. Remove it ('sudo rm ${file}') and re-run: the run then reads the token back from k3s's data."
    return 0
  fi
  tb_root test -d / \
    || error "native k3s: sudo did not run, so this run cannot tell whether ${file} exists. Re-run the installer; it asks for the password once, at the start."
  if tb_root test -e "${srv}/cred/passwd" || tb_root test -e "${srv}/token"; then
    passwd="$(tb_root cat "${srv}/cred/passwd")" || passwd=""
    tok="$(tb_root cat "${srv}/token")" || tok=""
    p="$(awk -F, '$2 == "server" { print $1; exit }' <<<"$passwd")"
    if [[ "$tok" == *::server:* ]]; then t="${tok##*::server:}"; fi
    [[ -n "$p" && -n "$t" ]] \
      || error "native k3s: this k3s was set up before the installer pinned its join token, and the token could not be read from its data (${srv}/cred/passwd and ${srv}/token). This run never gives it a new one: k3s would then refuse its own data. Check that sudo can read both, then re-run. If k3s does not stay up ('sudo journalctl -u k3s'), it is refusing its own data, and it cannot be recovered without a reinstall: ${how}."
    [[ "$p" == "$t" && "$t" =~ $TB_K3S_TOKEN_RE ]] \
      || error "native k3s: this k3s holds two different join tokens, or one that is not a token (${srv}/cred/passwd and ${srv}/token), so this run cannot tell which one its data is encrypted with, and pins neither. If k3s does not stay up ('sudo journalctl -u k3s'), it is refusing its own data, and it cannot be recovered without a reinstall: ${how}."
  else
    t="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')" || t=""
    [[ "$t" =~ $TB_K3S_TOKEN_RE ]] || error "native k3s: /dev/urandom gave no join token for k3s."
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/tracebloc-k3s-XXXXXX")" || error "native k3s: could not create a temporary file for k3s's join token."
  if ! { printf '%s\n' "$t" > "$tmp" \
         && tb_root install -m 0600 "$tmp" "${file}.tmp" \
         && tb_root sync "${file}.tmp" \
         && tb_root mv -f "${file}.tmp" "$file" \
         && tb_root sync "${file%/*}"; }; then
    rm -f "$tmp"
    error "native k3s: could not write k3s's join token to ${file} and sync it. Check that sudo can write under ${file%/*}, then re-run."
  fi
  rm -f "$tmp"
}

# ── The filesystem under k3s's data ─────────────────────────
#
# The pin above closes the torn token on every native host, whatever the filesystem
# does. Whether that host's filesystem would have kept the window small is still
# worth knowing: tracebloc's test cells measure their own hosts, never a customer's.
# So the install record has a field for it, k3s_data_fs
# (scripts/spec/install-record.schema.json), read the way those cells read it:
# findmnt on k3s's data path, and /proc/fs/jbd2 for whether a journal runs on its
# device. NOTHING WRITES IT YET: the CLI's reader refuses a field its own copy of the
# schema does not declare, so it learns the field first.
#
# Where /sys and /proc are, assigned here and never read from the environment, so a
# test can point the reads at a tree of its own.
_NATIVE_K3S_FS_ROOT=""

# _native_k3s_fs_journal TYPE OPTIONS JOURNAL -- whether the filesystem writes a
# file's data before the metadata naming it, one word of the schema's journal enum:
#   orders-data     xfs, btrfs; ext4 with a journal, data=ordered or data=journal,
#                   barriers on;
#   does-not-order  ext4 mounted data=writeback, nobarrier or barrier=0, or with no
#                   journal;
#   cannot-tell     any other filesystem (or none read), an ext4 whose journal could
#                   not be read, or whose options name no data= mode. Never a guess.
# OPTIONS is the mount's comma-separated options; JOURNAL is yes, no or unknown.
_native_k3s_fs_journal() {
  local type="$1" opts=",${2},"
  case "$type" in
    xfs | btrfs) echo orders-data; return 0 ;;
    ext4) ;;
    *) echo cannot-tell; return 0 ;;
  esac
  case "$opts" in
    *,data=writeback,* | *,nobarrier,* | *,barrier=0,*) echo does-not-order; return 0 ;;
  esac
  case "$3" in
    no) echo does-not-order; return 0 ;;
    yes) ;;
    *) echo cannot-tell; return 0 ;;
  esac
  case "$opts" in
    *,data=ordered,* | *,data=journal,*) echo orders-data ;;
    *) echo cannot-tell ;;
  esac
}

# _native_k3s_data_fs [PATH] -- k3s_data_fs for PATH (TB_K3S_DATA_PATH), one line of
# JSON: {"type": ..., "options": ..., "journal": ...}. type and options are what
# findmnt said for the mount holding PATH, null when it said nothing; the journal is
# read for ext4 only, from jbd2's entry for the mount's device. A read that fails is
# null and cannot-tell, never absent.
_native_k3s_data_fs() {
  local path="${1:-$TB_K3S_DATA_PATH}" out type="" opts="" majmin="" dev="" journal=unknown jbd2
  if has findmnt; then
    # Capture, then the first line: findmnt prints a line per mount stacked over the
    # target, and a pipe into head would SIGPIPE it under pipefail (_pf_fstype).
    out="$(findmnt -nro FSTYPE,OPTIONS,MAJ:MIN --target "$path" 2>/dev/null || true)"
    read -r type opts majmin <<<"${out%%$'\n'*}" || true
  fi
  if [[ "$type" == ext4 && -n "$majmin" ]]; then
    jbd2="${_NATIVE_K3S_FS_ROOT}/proc/fs/jbd2"
    dev="$(readlink "${_NATIVE_K3S_FS_ROOT}/sys/dev/block/${majmin}" 2>/dev/null || true)"
    dev="${dev##*/}"
    if [[ -n "$dev" && -d "$jbd2" && -r "$jbd2" && -x "$jbd2" ]]; then
      journal=no
      if compgen -G "${jbd2}/${dev}-*" >/dev/null; then journal=yes; fi
    fi
  fi
  # _tb_json writes an empty value as null.
  printf '{"type": %s, "options": %s, "journal": "%s"}' \
    "$(_tb_json "$type")" "$(_tb_json "$opts")" "$(_native_k3s_fs_journal "$type" "$opts" "$journal")"
}

# _native_k3s_write_config MODE NODE_NAME CIDR_PAIR STORAGE_PATH CGROUP [CA_FILE]
#   -- write everything k3s reads at start, as root, with an explicit mode on every
#   path: /etc/rancher and /etc/rancher/k3s 0755; config.yaml 0600 (it names the
#   node and the ranges, and k3s keeps its own secrets beside it), or 0640 to the
#   daily user's private group, which then reads k3s.yaml too (D3); the kubelet
#   drop-in 0644 (the e2e readback reads it unprivileged); and, when CA_FILE is
#   given, the CA 0644 and registries.yaml 0600. The join token is pinned first
#   (_native_k3s_pin_token, 0600), so config.yaml never names a file that is not
#   there.
#
# The group is the prepared group on a prepared host (1.1g), and otherwise granted
# only when it is private (_native_k3s_kubeconfig_grant). config.yaml holds no
# secret, and k3s's kubectl reads it on every call, warning "permission denied" when
# it cannot (measured on the 1.1e VM). A shared group is never widened: both stay
# 0600, and the user is told the one-line remedy.
_native_k3s_write_config() {
  local mode="$1" name="$2" cidrs="$3" storage="$4" cgroup="$5" ca="${6:-}" cfg kubelet ca_body kgroup
  kgroup="$(_native_k3s_kubeconfig_grant)" \
    || error "native k3s: ${TB_K3S_CONFIG_PATH} exists but could not be read, so this run cannot tell which group it grants k3s's kubeconfig to. Check it with 'sudo cat ${TB_K3S_CONFIG_PATH}', then re-run."
  cfg="$(_native_k3s_render_config "$mode" "$name" "$cidrs" "$storage" "$cgroup" "$kgroup" "$TB_K3S_TOKEN_PATH" \
    "$(_native_k3s_selinux_confine "$mode")")" || return 1
  [[ "$cgroup" != v1 ]] || _native_k3s_cgroup_v1_notice
  kubelet="$(_render_kubelet_config)" || return 1
  tb_root install -d -m 0755 /etc/rancher || return 1
  tb_root install -d -m 0755 "$TB_K3S_ETC_DIR" || return 1
  _native_k3s_pin_token
  if [[ -n "$kgroup" ]]; then
    _native_k3s_install_file 0640 "$TB_K3S_CONFIG_PATH" "$cfg" "$kgroup" || return 1
  else
    _native_k3s_kubeconfig_shared_notice
    _native_k3s_install_file 0600 "$TB_K3S_CONFIG_PATH" "$cfg" || return 1
  fi
  _native_k3s_install_file 0644 "$TB_KUBELET_CONFIG_K3S_PATH" "$kubelet" || return 1
  if [[ -n "$ca" ]]; then
    ca_body="$(cat "$ca")" || return 1
    _native_k3s_install_file 0644 "$TB_K3S_CA_PATH" "$ca_body" || return 1
    _native_k3s_install_file 0600 "$TB_K3S_REGISTRIES_PATH" "$(_render_registries_config "$TB_K3S_CA_PATH")" || return 1
  fi
}

# _native_k3s_config_value KEY [FILE] -- KEY's value in an existing config.yaml, quotes
# stripped; empty when the file has no such key. Returns 2 when FILE exists but cannot
# be read: a value that is there and unreadable is "cannot tell", never "absent".
_native_k3s_config_value() {
  local key="$1" cfg="${2:-$TB_K3S_CONFIG_PATH}" body line
  if ! _native_k3s_read test -e "$cfg"; then
    # `test -e` fails for a missing file AND for a sudo that did not run: only a root
    # read of a path that always exists tells them apart. sudo down is "cannot tell".
    _native_k3s_read test -d / || return 2
    return 0
  fi
  body="$(_native_k3s_read cat "$cfg")" || return 2
  line="$(printf '%s\n' "$body" | sed -n "s/^${key}:[[:space:]]*//p")"
  line="${line%%$'\n'*}"
  line="${line#\"}"; line="${line%\"}"
  printf '%s' "$line"
}

# ── Node name ─────────────────────────────────────────────────────────────────

# The node name a new install gets: TB_K3S_NODE_NAME_PREFIX and four
# random bytes in hex, e.g. tracebloc-3f9a01c2. Never the hostname, the user's name or
# a MAC address: the node name leaves the machine (client-runtime reports it to the
# backend as the heartbeat's hostname and as node_name, and `tracebloc doctor
# --diagnose` prints it), and a laptop's hostname often carries a person's name.
# TB_K3S_NODE_NAME_RE is its shape, built from the prefix.
TB_K3S_NODE_NAME_PREFIX="tracebloc-"
TB_K3S_NODE_NAME_RE="^${TB_K3S_NODE_NAME_PREFIX}[0-9a-f]{8}\$"

# _native_k3s_mint_node_name -- a new node name in TB_K3S_NODE_NAME_RE's shape, from
# /dev/urandom, the way _native_k3s_pin_token makes the join token. Returns 1 when
# /dev/urandom gave nothing usable.
_native_k3s_mint_node_name() {
  local id name
  id="$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')" || id=""
  name="${TB_K3S_NODE_NAME_PREFIX}${id}"
  [[ "$name" =~ $TB_K3S_NODE_NAME_RE ]] || return 1
  printf '%s\n' "$name"
}

# _native_k3s_node_exists CONFIG -- 0 when k3s already runs a node that CONFIG was
# written for, 1 when it runs none, 2 when this run cannot tell. Asked only when
# CONFIG names no node, so a yes is a config.yaml whose node-name went missing after
# the node was made:
#   - an adopted host: the administrator's k3s runs (_native_k3s_prepared_for_me).
#   - the macOS node: run-args beside CONFIG, which _mac_ct_ensure_node writes after
#     CONFIG and before it makes the node.
#   - otherwise: k3s's data holds a server (server/cred/passwd or server/token under
#     TB_K3S_DATA_PATH, read as _native_k3s_pin_token reads them). A sudo that did not
#     run is cannot tell, never "no node".
_native_k3s_node_exists() {
  local cfg="$1" srv="${TB_K3S_DATA_PATH}/server"
  [[ "${TB_K3S_ADOPTED:-}" != 1 ]] || return 0
  if [[ "${TB_K3S_ON_MAC:-}" == 1 ]]; then
    [[ -e "${cfg%/*}/run-args" ]] && return 0
    return 1
  fi
  if tb_root test -e "${srv}/cred/passwd" || tb_root test -e "${srv}/token"; then return 0; fi
  tb_root test -d / || return 2
  return 1
}

# _native_k3s_node_name_ok NAME -- NAME is one Kubernetes node name, a DNS-1123
# subdomain (TB_K3S_ANY_NODE_NAME_RE), so a list of two names (a space) or an empty
# answer is not one.
TB_K3S_ANY_NODE_NAME_RE='^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$'
_native_k3s_node_name_ok() {
  [[ "$1" =~ $TB_K3S_ANY_NODE_NAME_RE ]]
}

# _native_k3s_running_node_name -- the name of the one node this machine's k3s runs,
# read back from k3s itself; returns 1 when k3s does not say.
#   1. Its API: `kubectl get nodes` on k3s.yaml, as root (an adopted host: through the
#      prepared group, with no sudo); on the macOS node, asked inside the node
#      (mac-container.sh's _mac_ct_running_node_name).
#   2. When the API does not answer, on a host this run is root on: k3s's own record,
#      the kubelet's client certificate (agent/client-kubelet.crt under
#      TB_K3S_DATA_PATH), whose subject k3s writes as CN=system:node:<name> on every
#      start. Read with openssl, when the host has it.
# Anything but exactly one node name is no answer.
_native_k3s_running_node_name() {
  local name="" pem
  if [[ "${TB_K3S_ON_MAC:-}" == 1 ]]; then
    if declare -F _mac_ct_running_node_name >/dev/null 2>&1; then name="$(_mac_ct_running_node_name)" || name=""; fi
  else
    name="$(_native_k3s_read env KUBECONFIG="$TB_K3S_KUBECONFIG_PATH" "$TB_K3S_BIN_PATH" kubectl get nodes --request-timeout=5s -o 'jsonpath={.items[*].metadata.name}' 2>/dev/null)" || name=""
    if ! _native_k3s_node_name_ok "$name" && [[ "${TB_K3S_ADOPTED:-}" != 1 ]] && has openssl; then
      pem="$(tb_root cat "${TB_K3S_DATA_PATH}/agent/client-kubelet.crt" 2>/dev/null)" || pem=""
      name="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*CN=system:node:\([^,]*\).*/\1/p')" || name=""
    fi
  fi
  _native_k3s_node_name_ok "$name" || return 1
  printf '%s\n' "$name"
}

# _native_k3s_node_name [CONFIG] -- the node name, FROZEN at first install:
# local-path volumes are pinned to it, so a later rename would strand
# them. Once CONFIG (config.yaml) names a node, that name is returned, whatever made
# it: an install from before this keeps the hostname it was given. Otherwise a
# new install gets a new name (_native_k3s_mint_node_name), logged; the hostname is
# never read. Never a constant: the environment switcher shows it.
# When CONFIG names no node but k3s already runs one (_native_k3s_node_exists, or
# cannot tell), that node's name is read back from k3s (_native_k3s_running_node_name)
# and the caller freezes it in CONFIG again; a new name would be a new node. Returns 3
# when k3s does not say it, and 4 when no new name can be made: callers run it in a
# command substitution, so they end the run with _native_k3s_node_name_stop.
_native_k3s_node_name() {
  local cfg="${1:-$TB_K3S_CONFIG_PATH}" have rc=0 name
  have="$(_native_k3s_config_value node-name "$cfg")" || rc=$?
  [[ "$rc" -eq 0 ]] || error "native k3s: ${cfg} exists but could not be read, so the node name it froze cannot be kept. Check it with 'sudo cat ${cfg}', then re-run."
  if [[ -n "$have" ]]; then
    printf '%s\n' "$have"
    return 0
  fi
  rc=0; _native_k3s_node_exists "$cfg" || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    name="$(_native_k3s_running_node_name)" || return 3
    log "native k3s node name: '${name}' (read back from k3s; ${cfg} no longer named it)."
    printf '%s\n' "$name"
    return 0
  fi
  name="$(_native_k3s_mint_node_name)" || return 4
  log "native k3s node name: '${name}' (new; frozen in ${cfg} from here on)."
  printf '%s\n' "$name"
}

# _native_k3s_node_name_stop RC [CONFIG] -- end the run where _native_k3s_node_name
# returned RC for CONFIG, in the caller's shell, so the end block says what to do.
_native_k3s_node_name_stop() {
  local cfg="${2:-$TB_K3S_CONFIG_PATH}"
  case "$1" in
    3) tb_fail_next "Start k3s if it is stopped, then run the installer again:"
       error_said "Can't tell which k3s node holds your data" "native k3s: ${cfg} no longer names this machine's k3s node, and k3s did not say its name. A new name would leave the node's volumes behind. Start k3s if it is stopped, then re-run. Or run \"tracebloc delete\", which deletes k3s and its data, then install again." ;;
    4) error_said "Couldn't make a name for this machine's k3s node" "native k3s: /dev/urandom gave no node name for k3s." ;;
    *) exit "$1" ;;
  esac
}

# ── Pod and service ranges ────────────────────────────────────────────────────

# _native_k3s_host_routes -- the host's IPv4 routes, one per line in the shape
# `ip -4 route show` prints them: "<dest>/<len> dev <iface>", or "default dev <iface>".
# Read from the kernel's own table, /proc/net/route (the main table, the one
# `ip -4 route show` lists), so the install needs no iproute2: tracebloc's WSL distro
# is Canonical's ubuntu-base and ships none, and 3.3's distro leg stopped here on
# `ip: command not found` (16 Oct, e2e run 38852163664). Returns 1 when the table
# cannot be read, its header is not the kernel's, or a line is not a route: never a
# partial answer. TEST SEAMS: TRACEBLOC_K3S_ROUTES_STUB, a file whose lines replace
# the whole answer; TRACEBLOC_K3S_PROC_ROUTE, the table's path.
_native_k3s_host_routes() {
  if [[ -n "${TRACEBLOC_K3S_ROUTES_STUB:-}" ]]; then
    cat "$TRACEBLOC_K3S_ROUTES_STUB"
    return
  fi
  local table="${TRACEBLOC_K3S_PROC_ROUTE:-/proc/net/route}" text header line iface dest gw flags refcnt use metric mask rest addr len
  text="$(cat "$table" 2>/dev/null)" || return 1
  header="${text%%$'\n'*}"
  read -r iface dest gw flags refcnt use metric mask rest <<<"$header"
  [[ "$iface" == Iface && "$dest" == Destination && "$mask" == Mask ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "$header" || -z "${line//[[:space:]]/}" ]] && continue
    read -r iface dest gw flags refcnt use metric mask rest <<<"$line"
    addr="$(_native_k3s_hex_ipv4 "$dest")" || return 1
    len="$(_native_k3s_hex_prefix_len "$mask")" || return 1
    if [[ "$addr" == 0.0.0.0 && "$len" == 0 ]]; then
      printf 'default dev %s\n' "$iface"
    else
      printf '%s/%s dev %s\n' "$addr" "$len" "$iface"
    fi
  done <<<"$text"
}

# _native_k3s_hex_ipv4 HEX -- an address as /proc/net/route writes it (eight hex
# digits, the bytes in the host's little-endian order) as a dotted quad.
_native_k3s_hex_ipv4() {
  local h="$1"
  [[ "$h" =~ ^[0-9A-Fa-f]{8}$ ]] || return 1
  printf '%d.%d.%d.%d\n' "$((16#${h:6:2}))" "$((16#${h:4:2}))" "$((16#${h:2:2}))" "$((16#${h:0:2}))"
}

# _native_k3s_hex_prefix_len HEX -- a netmask as /proc/net/route writes it, as a
# prefix length. Returns 1 for a mask whose bits are not contiguous: no route can
# carry one, so it is a table this cannot read.
_native_k3s_hex_prefix_len() {
  local h="$1" n len=0
  [[ "$h" =~ ^[0-9A-Fa-f]{8}$ ]] || return 1
  n=$(( (16#${h:6:2} << 24) | (16#${h:4:2} << 16) | (16#${h:2:2} << 8) | 16#${h:0:2} ))
  while (( n & 0x80000000 )); do
    len=$((len + 1))
    n=$(( (n << 1) & 0xFFFFFFFF ))
  done
  (( n == 0 )) || return 1
  printf '%s\n' "$len"
}

# _native_k3s_cidr_overlap A B -- true when the IPv4 ranges A and B share an address.
# A bare address is a /32. Returns 2 when either cannot be read as a range.
_native_k3s_cidr_overlap() {
  local a="$1" b="$2" an bn al=32 bl=32 m mask
  [[ "$a" == */* ]] && al="${a#*/}"
  [[ "$b" == */* ]] && bl="${b#*/}"
  an="$(_ipv4_to_int "${a%/*}")" || return 2
  bn="$(_ipv4_to_int "${b%/*}")" || return 2
  [[ "$al" =~ ^[0-9]+$ && "$bl" =~ ^[0-9]+$ ]] || return 2
  (( al <= 32 && bl <= 32 )) || return 2
  m=$(( al < bl ? al : bl ))
  mask=0
  (( m > 0 )) && mask=$(( (0xFFFFFFFF << (32 - m)) & 0xFFFFFFFF ))
  (( (an & mask) == (bn & mask) ))
}

# _native_k3s_pick_cidrs [CONFIG] -- the "<cluster-cidr> <service-cidr>" pair for this
# host. An existing CONFIG keeps its pair: pods and services already carry addresses
# from it. Otherwise the first pair in TRACEBLOC_K3S_CIDR_PAIRS that no host route overlaps --
# on native Linux the pod routes land on the host, so a collision misroutes the host's
# own traffic. When every pair overlaps a route, the install is refused and the routes
# are named; so is a route this cannot read.
_native_k3s_pick_cidrs() {
  local cfg="${1:-$TB_K3S_CONFIG_PATH}" have_c have_s rc=0 routes pair dest cidr hits all="" line f1 f2 rest
  have_c="$(_native_k3s_config_value cluster-cidr "$cfg")" || rc=$?
  [[ "$rc" -eq 0 ]] && { have_s="$(_native_k3s_config_value service-cidr "$cfg")" || rc=$?; }
  [[ "$rc" -eq 0 ]] || error "native k3s: ${cfg} exists but could not be read, so the pod and service ranges it holds cannot be kept. Check it with 'sudo cat ${cfg}', then re-run."
  if [[ -n "$have_c" && -n "${have_s:-}" ]]; then
    printf '%s %s\n' "$have_c" "$have_s"
    return 0
  fi
  routes="$(_native_k3s_host_routes)" || error "native k3s: couldn't read this machine's routes (/proc/net/route), so it cannot tell which pod and service ranges are free. Check that /proc is mounted and readable, then re-run."
  for pair in "${TRACEBLOC_K3S_CIDR_PAIRS[@]}"; do  # set-u-safe: TRACEBLOC_K3S_CIDR_PAIRS is a file-scope constant
    hits=""
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # A multipath route continues on indented `nexthop via ...` lines: its
      # destination is on the line above, which was already checked.
      [[ "$line" == [[:space:]]* || "$line" == nexthop* ]] && continue
      # The destination is the first field, or the second after a route type.
      read -r f1 f2 rest <<<"$line"
      case "$f1" in
        unicast|local|broadcast|multicast|throw|unreachable|prohibit|blackhole|nat) dest="${f2:-}" ;;
        *) dest="$f1" ;;
      esac
      [[ "$dest" == "default" || -z "$dest" ]] && continue
      for cidr in $pair; do
        rc=0
        _native_k3s_cidr_overlap "$cidr" "$dest" || rc=$?
        case "$rc" in
          0) hits="${hits:+${hits}, }${dest} (overlaps ${cidr})"; break ;;
          1) ;;
          *) error "native k3s: couldn't read the host route '${line}', so it cannot tell whether it overlaps ${cidr}. Refusing to guess." ;;
        esac
      done
    done <<<"$routes"
    if [[ -z "$hits" ]]; then
      log "native k3s pod and service ranges: ${pair% *} and ${pair#* }."
      printf '%s\n' "$pair"
      return 0
    fi
    all="${all:+${all}; }${pair}: ${hits}"
  done
  error "native k3s: every pod and service range this installer can use overlaps a route on this machine (${all}). Free one of those ranges, then re-run."
}

# _native_k3s_cgroup_version -- v2 when the unified hierarchy is mounted at the
# cgroup root (it has cgroup.controllers), else v1, which covers hybrid hosts too.
# TRACEBLOC_K3S_CGROUP_ROOT is the TEST SEAM: point it at a directory with or without that file.
_native_k3s_cgroup_version() {
  if [[ -f "${TRACEBLOC_K3S_CGROUP_ROOT:-/sys/fs/cgroup}/cgroup.controllers" ]]; then
    printf 'v2'
  else
    printf 'v1'
  fi
}
