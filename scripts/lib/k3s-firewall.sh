#!/usr/bin/env bash
# =============================================================================
#  k3s-firewall.sh — keep the native k3s API (6443) and the kubelet (10250)
#                    off the network with a persisted host firewall rule
#                    (RFC-0175 D4)
# =============================================================================
#
# k3d published the API on 127.0.0.1 only. Native k3s listens on *:6443 and
# *:10250, and `--bind-address=127.0.0.1` is not the fix: measured, CoreDNS never
# becomes ready, local-path and metrics-server crash-loop and pod DNS fails. So
# the host drops both ports unless the packet arrives on an interface in the
# allowlist (lo, cni0, flannel.1). An ALLOWLIST, not a denylist: a second NIC,
# Wi-Fi or a VPN interface that appears later is dropped, not missed.
#
# nft first, iptables + ip6tables second, and neither is a refusal: the install
# fails closed rather than starting an API nobody fenced. The rule lives in its
# own table (nft) or chain (iptables), persisted under /etc/tracebloc and loaded
# by a oneshot unit ordered before k3s.service, so it is up before the API ever
# listens. firewalld and ufw keep their own tables: a drop in any input-hook base
# chain drops the packet, so their accepts cannot reopen the port.
#
# No name here contains KUBE-, CNI- or flannel. The official k3s scripts strip
# iptables rules matching those (k3s-firewall.bats derives the patterns from the
# vendored upstream install.sh), so a rule named after neither survives them, and
# removing it is this lib's job, never k3s's. One allowlist LINE does carry
# `flannel.1` on the iptables path; the bats case names what that costs.
#
# Linux only. On macOS the node publishes 6443 on 127.0.0.1 and filters inside
# the node (D4, 2.1). Nothing sources this yet: 1.1e wires it into
# install-k8s.sh and the FILES arrays, and applies it before k3s first starts.
#
# UDP 8472 (flannel VXLAN) joins the port set once the first live run confirms
# the listener with `ss -ulpn` (decision 2026-10-01): a single node has no peer.

_NATIVE_K3S_FW_PORTS="6443 10250"
_NATIVE_K3S_FW_ALLOW="lo cni0 flannel.1"
_NATIVE_K3S_FW_TABLE="tracebloc"
_NATIVE_K3S_FW_CHAIN="TRACEBLOC-API"
_NATIVE_K3S_FW_DIR="/etc/tracebloc"
_NATIVE_K3S_FW_UNIT="tracebloc-firewall.service"
_NATIVE_K3S_FW_UNIT_DIR="/etc/systemd/system"

# Where the files are WRITTEN. Empty on a host; the bats suite points it at a
# temp dir, the way DESTDIR works. The rendered unit always names the real
# paths, so a test never renders a file a host would read differently.
TRACEBLOC_NATIVE_K3S_FW_ROOT="${TRACEBLOC_NATIVE_K3S_FW_ROOT:-}"

# _native_k3s_fw_pick — the firewall tool this host has, without refusing: `nft`,
# `iptables` (with ip6tables beside it), `v4-only` (iptables alone) or `none`.
# iptables counts only with ip6tables beside it: a v4-only fence leaves the API
# open on every v6 address the host has. The one reading of the host's tools:
# _native_k3s_fw_tool refuses the last two, and k3s.sh's step b installs nftables
# for them (_native_k3s_ensure_firewall_tool).
_native_k3s_fw_pick() {
  if has nft; then
    echo nft
  elif has iptables && has ip6tables; then
    echo iptables
  elif has iptables; then
    echo v4-only
  else
    echo none
  fi
}

# _native_k3s_fw_tool — print `nft` or `iptables`; refuse when neither is there.
_native_k3s_fw_tool() {
  case "$(_native_k3s_fw_pick)" in
    nft) echo nft ;;
    iptables) echo iptables ;;
    v4-only) error "ip6tables is missing, so the k3s API (6443) and the kubelet (10250) cannot be kept off IPv6. Install nftables (apt-get install nftables / dnf install nftables) and re-run." ;;
    *) error "Neither nft nor iptables is installed, so nothing can keep the k3s API (6443) and the kubelet (10250) off the network. Install nftables (apt-get install nftables / dnf install nftables) and re-run." ;;
  esac
}

# _native_k3s_fw_file nft|iptables — the rules file's path on a host.
_native_k3s_fw_file() {
  case "$1" in
    nft)      echo "$_NATIVE_K3S_FW_DIR/firewall.nft" ;;
    iptables) echo "$_NATIVE_K3S_FW_DIR/firewall.rules" ;;
    *) error "_native_k3s_fw_file: unknown tool '$1' (want nft or iptables)" ;;
  esac
}

# _native_k3s_fw_artefact nft|iptables — "<id><TAB><path>", what 1.1e records
# as the `firewall-rule` artefact and what 1.3's `delete` reads back.
_native_k3s_fw_artefact() {
  case "$1" in
    nft)      printf 'nft:inet %s\t%s/%s\n' "$_NATIVE_K3S_FW_TABLE" "$_NATIVE_K3S_FW_UNIT_DIR" "$_NATIVE_K3S_FW_UNIT" ;;
    iptables) printf 'iptables:%s\t%s/%s\n' "$_NATIVE_K3S_FW_CHAIN" "$_NATIVE_K3S_FW_UNIT_DIR" "$_NATIVE_K3S_FW_UNIT" ;;
    *) error "_native_k3s_fw_artefact: unknown tool '$1' (want nft or iptables)" ;;
  esac
}

# _native_k3s_fw_render nft|iptables — the ruleset, on stdout. Pure.
#
# nft: `table` then `delete table` then the definition makes `nft -f` replace the
# table atomically on every load (the idiom that works on nft before `destroy`).
# iptables: an iptables-restore file for BOTH families (it names no address), fed
# with --noflush so every other chain on the host is left alone.
_native_k3s_fw_render() {
  local p i ports="" allow=""
  for p in $_NATIVE_K3S_FW_PORTS; do ports="${ports:+$ports, }$p"; done
  for i in $_NATIVE_K3S_FW_ALLOW; do allow="${allow:+$allow, }\"$i\""; done
  case "$1" in
    nft)
      cat <<EOF
#!/usr/sbin/nft -f
# tracebloc: keep the k3s API and the kubelet off the network.
# Written by the tracebloc installer; \`tracebloc delete\` removes it.
table inet $_NATIVE_K3S_FW_TABLE
delete table inet $_NATIVE_K3S_FW_TABLE
table inet $_NATIVE_K3S_FW_TABLE {
	chain input {
		type filter hook input priority 0; policy accept;
		iifname { $allow } accept
		tcp dport { $ports } drop
	}
}
EOF
      ;;
    iptables)
      printf '# tracebloc: keep the k3s API and the kubelet off the network.\n'
      printf '# Written by the tracebloc installer; `tracebloc delete` removes it.\n'
      printf '# Loaded with iptables-restore --noflush AND ip6tables-restore --noflush.\n'
      printf '*filter\n'
      printf ':%s - [0:0]\n' "$_NATIVE_K3S_FW_CHAIN"
      printf -- '-F %s\n' "$_NATIVE_K3S_FW_CHAIN"
      for i in $_NATIVE_K3S_FW_ALLOW; do
        printf -- '-A %s -i %s -j RETURN\n' "$_NATIVE_K3S_FW_CHAIN" "$i"
      done
      printf -- '-A %s -p tcp -m multiport --dports %s -j DROP\n' "$_NATIVE_K3S_FW_CHAIN" "$(printf '%s' "$_NATIVE_K3S_FW_PORTS" | tr ' ' ',')"
      printf -- '-I INPUT 1 -j %s\n' "$_NATIVE_K3S_FW_CHAIN"
      printf 'COMMIT\n'
      ;;
    *) error "_native_k3s_fw_render: unknown tool '$1' (want nft or iptables)" ;;
  esac
}

# _native_k3s_fw_render_unit nft|iptables — the oneshot unit, on stdout. Pure.
# After the distro firewall units (a `flush ruleset` in them would otherwise
# remove the table we just loaded), before k3s (the API never listens unfenced).
# The iptables jump is removed first, so a restart never stacks a second one.
_native_k3s_fw_render_unit() {
  local file
  file=$(_native_k3s_fw_file "$1") || return 1
  cat <<EOF
# tracebloc: load the host firewall rule that keeps the k3s API (6443) and the
# kubelet (10250) off the network, before k3s starts.
# Written by the tracebloc installer; \`tracebloc delete\` removes it.
[Unit]
Description=tracebloc host firewall (k3s API and kubelet off the network)
After=nftables.service firewalld.service
Before=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
EOF
  case "$1" in
    nft)
      printf 'ExecStart=/usr/bin/env nft -f %s\n' "$file"
      ;;
    iptables)
      printf "ExecStartPre=-/bin/sh -c 'while iptables -D INPUT -j %s 2>/dev/null; do :; done; while ip6tables -D INPUT -j %s 2>/dev/null; do :; done'\n" "$_NATIVE_K3S_FW_CHAIN" "$_NATIVE_K3S_FW_CHAIN"
      printf 'ExecStart=/usr/bin/env iptables-restore --noflush %s\n' "$file"
      printf 'ExecStart=/usr/bin/env ip6tables-restore --noflush %s\n' "$file"
      ;;
  esac
  printf '\n[Install]\nWantedBy=multi-user.target\n'
}

# _native_k3s_fw_install_file MODE DEST — stdin to DEST (under TRACEBLOC_NATIVE_K3S_FW_ROOT)
# at MODE. The core runs under umask 077, so the mode is always explicit. Written
# to a temp file first and moved with `install`, so a reader never sees half.
_native_k3s_fw_install_file() {
  local mode="$1" dest="$TRACEBLOC_NATIVE_K3S_FW_ROOT$2" tmp
  tmp=$(mktemp) || error "could not create a temporary file for $2"
  if ! cat >"$tmp"; then rm -f "$tmp"; error "could not render $2"; fi
  if ! sudo mkdir -p "$(dirname "$dest")" || ! sudo install -m "$mode" "$tmp" "$dest"; then
    rm -f "$tmp"
    error "could not write $2"
  fi
  rm -f "$tmp"
}

# _native_k3s_fw_status [nft|iptables] — print `present`, `absent` or
# `cannot tell` and return 0, 1 or 2. Re-runs and 1.3's `doctor` read it, so a
# table a distro `flush ruleset` removed is seen. `present` means the live rule
# still drops both ports; a table or chain that is there but no longer does is
# `absent`, because re-applying is the fix for both. Each probe's status is
# taken with `|| rc=$?`: the installer runs under `set -e`, where a bare
# `out=$(failing); rc=$?` exits before the answer is printed.
_native_k3s_fw_status() {
  local tool="${1:-}" out rc p fam
  if [ -z "$tool" ]; then
    tool=$(_native_k3s_fw_tool 2>/dev/null) || { echo "cannot tell"; return 2; }
  fi
  case "$tool" in
    nft)
      rc=0; out=$(sudo nft list table inet "$_NATIVE_K3S_FW_TABLE" 2>&1) || rc=$?
      if [ "$rc" -ne 0 ]; then
        case "$out" in
          *"No such file or directory"*) echo absent; return 1 ;;
          *) echo "cannot tell"; return 2 ;;
        esac
      fi
      case "$out" in *"hook input"*) ;; *) echo absent; return 1 ;; esac
      for p in $_NATIVE_K3S_FW_PORTS; do
        case "$out" in *"$p"*) ;; *) echo absent; return 1 ;; esac
      done
      case "$out" in *" drop"*) ;; *) echo absent; return 1 ;; esac
      ;;
    iptables)
      for fam in iptables ip6tables; do
        rc=0; out=$(sudo "$fam" -S "$_NATIVE_K3S_FW_CHAIN" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
          case "$out" in
            *"No chain"*|*"does not exist"*) echo absent; return 1 ;;
            *) echo "cannot tell"; return 2 ;;
          esac
        fi
        case "$out" in *"--dports $(printf '%s' "$_NATIVE_K3S_FW_PORTS" | tr ' ' ',')"*"DROP"*) ;; *) echo absent; return 1 ;; esac
        if ! sudo "$fam" -C INPUT -j "$_NATIVE_K3S_FW_CHAIN" >/dev/null 2>&1; then echo absent; return 1; fi
      done
      ;;
    *) echo "cannot tell"; return 2 ;;
  esac
  echo present
}

# _native_k3s_fw_apply — write the rules and the unit, enable it, load the rule
# NOW through the unit (one code path for boot and install), and prove it took.
_native_k3s_fw_apply() {
  local tool file aid apath
  tool=$(_native_k3s_fw_tool) || return 1
  file=$(_native_k3s_fw_file "$tool") || return 1
  _native_k3s_fw_render "$tool" | _native_k3s_fw_install_file 0600 "$file" || return 1
  _native_k3s_fw_render_unit "$tool" | _native_k3s_fw_install_file 0644 "$_NATIVE_K3S_FW_UNIT_DIR/$_NATIVE_K3S_FW_UNIT" || return 1
  if ! sudo systemctl daemon-reload || ! sudo systemctl enable "$_NATIVE_K3S_FW_UNIT" >/dev/null 2>&1; then
    error "could not enable $_NATIVE_K3S_FW_UNIT, so the firewall rule would not survive a reboot"
  fi
  if ! sudo systemctl restart "$_NATIVE_K3S_FW_UNIT"; then
    error "$_NATIVE_K3S_FW_UNIT failed to load $file (see: journalctl -u $_NATIVE_K3S_FW_UNIT)"
  fi
  if [ "$(_native_k3s_fw_status "$tool")" != present ]; then
    error "$_NATIVE_K3S_FW_UNIT ran, but the rule is not live -- the k3s API would listen unfenced"
  fi
  IFS=$'\t' read -r aid apath < <(_native_k3s_fw_artefact "$tool")
  success "Firewall rule loaded: $aid ($apath)"
  log "firewall-rule $aid $apath"
}

# _native_k3s_fw_remove [nft|iptables] — the inverse, for re-runs and tests.
# D12's `delete` belongs to 1.3 and reads the recorded artefact instead.
_native_k3s_fw_remove() {
  local tool="${1:-}" fam aid apath
  if [ -z "$tool" ]; then tool=$(_native_k3s_fw_tool) || return 1; fi
  sudo systemctl disable --now "$_NATIVE_K3S_FW_UNIT" >/dev/null 2>&1 || :
  case "$tool" in
    nft)
      if sudo nft list table inet "$_NATIVE_K3S_FW_TABLE" >/dev/null 2>&1; then
        sudo nft delete table inet "$_NATIVE_K3S_FW_TABLE" || error "could not delete the nft table inet $_NATIVE_K3S_FW_TABLE"
      fi
      ;;
    iptables)
      for fam in iptables ip6tables; do
        while sudo "$fam" -D INPUT -j "$_NATIVE_K3S_FW_CHAIN" 2>/dev/null; do :; done
        if sudo "$fam" -S "$_NATIVE_K3S_FW_CHAIN" >/dev/null 2>&1; then
          sudo "$fam" -F "$_NATIVE_K3S_FW_CHAIN" && sudo "$fam" -X "$_NATIVE_K3S_FW_CHAIN" \
            || error "could not delete the $fam chain $_NATIVE_K3S_FW_CHAIN"
        fi
      done
      ;;
    *) error "_native_k3s_fw_remove: unknown tool '$tool' (want nft or iptables)" ;;
  esac
  sudo rm -f "$TRACEBLOC_NATIVE_K3S_FW_ROOT$_NATIVE_K3S_FW_UNIT_DIR/$_NATIVE_K3S_FW_UNIT" \
             "$TRACEBLOC_NATIVE_K3S_FW_ROOT$(_native_k3s_fw_file "$tool")"
  sudo systemctl daemon-reload || :
  if [ "$(_native_k3s_fw_status "$tool")" != absent ]; then
    error "the firewall rule is still live after removal"
  fi
  IFS=$'\t' read -r aid apath < <(_native_k3s_fw_artefact "$tool")
  info "Firewall rule removed: $aid ($apath)"
  log "firewall-rule removed $aid $apath"
}
