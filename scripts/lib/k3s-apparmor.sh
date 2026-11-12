#!/usr/bin/env bash
# =============================================================================
#  k3s-apparmor.sh — the AppArmor profile that names k3s's bundled runc
#
#  LINUX ONLY. Moved out of k3s.sh; install-k8s.sh sources it right
#  after k3s.sh and k3s-firewall.sh, and both bootstraps fetch it. Every function keeps the
#  `_native_k3s_` prefix, and it reads k3s.sh's constants (TB_K3S_DATA_PATH, TB_K3S_ETC_DIR).
#  bash 3.2-safe; sourcing it has no side effects: constants and functions only.
# =============================================================================

# ── AppArmor: k3s's bundled runc ──────────────────────────────────────────────
#
# k3s runs its own runc (${TB_K3S_DATA_PATH}/data/<hash>/bin/runc), which no distro
# AppArmor profile names, so it runs as plain `unconfined`. Where the kernel sets
# apparmor_restrict_unprivileged_unconfined=1 (Ubuntu 26.04's default), runc's
# change_onexec into containerd's profile is then converted to a STACK, every
# container is labelled `cri-containerd.apparmor.d//&unconfined`, and containerd's
# profile, which only lets a process signal its own label, denies every in-container
# signal: mysqld --initialize waits for ever on its own SIGTERM. A profile NAMED runc
# covering k3s's path gives runc a name, so the switch is a plain one again. The name
# is fixed: containerd's profile takes signals only from unconfined, runc, crun and
# itself, so under any other name runc can no longer stop a container.
#
# The distro's /etc/apparmor.d/runc defines the same profile name for its own paths.
# Ours attaches to those paths and k3s's, unconfined like the distro's, with the
# distro's local/runc include. It lives OUT of /etc/apparmor.d, so it never races
# the distro's at boot and no package owns or rewrites it. The k3s unit's drop-in
# re-loads it before every k3s start, and apt's hook after every package run (an
# apparmor update re-loads the distro's runc over it). A `dpkg -i` outside apt or a
# `systemctl reload apparmor` still puts the distro's back until k3s next starts.
#
# The record lists the profile alone (apparmor-runc, a path every tracebloc delete
# accepts); the drop-in and the hook sit at fixed paths its removal also takes, as
# the schema's file kind says.

# The profile file, the drop-in that re-loads it, apt's hook (written only where apt
# is), and the distro's profile it stands beside.
TB_K3S_APPARMOR_RUNC_PATH="/etc/tracebloc/apparmor-k3s-runc"
TB_K3S_APPARMOR_DROPIN_PATH="/etc/systemd/system/k3s.service.d/tracebloc-apparmor-runc.conf"
TB_K3S_APPARMOR_APT_HOOK_PATH="/etc/apt/apt.conf.d/99tracebloc-apparmor-runc"
TB_K3S_APPARMOR_DISTRO_RUNC_PATH="/etc/apparmor.d/runc"
# Where AppArmor's own profiles live: one there that attaches to k3s's runc under
# another name wins over ours by the longer match (_native_k3s_apparmor_rival).
TB_K3S_APPARMOR_D="/etc/apparmor.d"
# The profiles the kernel holds, one `name (mode)` per line (root reads it).
TB_K3S_APPARMOR_PROFILES="/sys/kernel/security/apparmor/profiles"
# The kernel's two answers. TEST SEAMS: TRACEBLOC_K3S_APPARMOR_ENABLED_FILE and
# TRACEBLOC_K3S_APPARMOR_RESTRICT_FILE replace them (read only, never run).
TB_K3S_APPARMOR_ENABLED_FILE="/sys/module/apparmor/parameters/enabled"
TB_K3S_APPARMOR_RESTRICT_FILE="/proc/sys/kernel/apparmor_restrict_unprivileged_unconfined"
# Where apparmor_parser may live. Assigned here, never read from the environment:
# the path is baked into hooks root runs.
_tb_k3s_aa_parsers="/usr/sbin/apparmor_parser /sbin/apparmor_parser"
_tb_k3s_aa_parser_owner=0

# _native_k3s_apparmor_runc_due -- true only when AppArmor is enabled (the module says
# Y) AND the kernel converts an unconfined change_onexec to a stack (the sysctl says
# 1). Anything else, an absent or unreadable file included, leaves the host alone:
# no other kernel stacks runc's switch, so no other host needs the profile.
_native_k3s_apparmor_runc_due() {
  local en rs
  en="$(cat "${TRACEBLOC_K3S_APPARMOR_ENABLED_FILE:-$TB_K3S_APPARMOR_ENABLED_FILE}" 2>/dev/null)" || return 1
  [[ "$en" == Y ]] || return 1
  rs="$(cat "${TRACEBLOC_K3S_APPARMOR_RESTRICT_FILE:-$TB_K3S_APPARMOR_RESTRICT_FILE}" 2>/dev/null)" || return 1
  [[ "$rs" == 1 ]]
}

# _native_k3s_apparmor_parser -- the absolute path of apparmor_parser, or 1 when none.
# Only root's own: a parser another user owns or may write is never run as root.
_native_k3s_apparmor_parser() {
  local p
  for p in $_tb_k3s_aa_parsers; do
    [[ -x "$p" ]] || continue
    if [[ -n "$(find "$p" -maxdepth 0 -user "$_tb_k3s_aa_parser_owner" ! -perm -0020 ! -perm -0002 2>/dev/null)" ]]; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# _native_k3s_apparmor_rival -- the profiles that could attach to k3s's runc under a
# name other than runc: they win by the longer match, and runc under them can no
# longer stop a container. Only attachments are read (`profile NAME PATH` or a bare
# `PATH`, its `{` on the line or the next), with the file's own @{VAR} definitions
# expanded and the AppArmor glob matched against k3s's runc path. One line each:
# sure<TAB>file<TAB>name when the kernel holds it and its literal prefix is at least
# as long as ours on that path (it wins), else unsure<TAB>file<TAB>name; a variable
# the file does not define, a file awk cannot read, and a loaded profile with runc in
# its name that no file here defines are unsure too. 1 when none.
_native_k3s_apparmor_rival() {
  local f out="" loaded name k rc res ours
  local cands=()
  ours="${TB_K3S_DATA_PATH}/data/"
  for f in "${TB_K3S_DATA_PATH}"/data/*/bin/runc; do [[ -e "$f" ]] && cands+=("$f"); done
  [[ ${#cands[@]} -gt 0 ]] || cands=("${TB_K3S_DATA_PATH}/data/0123456789abcdef/bin/runc")
  loaded="$(tb_root cat "$TB_K3S_APPARMOR_PROFILES" 2>/dev/null)" || loaded=""
  loaded="$(printf '%s\n' "$loaded" | sed 's/ ([a-z]*)$//')"
  for f in "$TB_K3S_APPARMOR_D"/*; do
    [[ -f "$f" ]] || continue
    rc=0
    # The loaded list goes in through the environment: awk -v refuses a newline (BSD awk).
    # set-u-safe: cands always holds at least the fallback path
    res="$(tb_aa_loaded="$loaded" LC_ALL=C awk -v file="$f" -v cands="${cands[*]}" -v ours="${#ours}" '
      BEGIN { loaded = ENVIRON["tb_aa_loaded"] }
      function g2re(g,   i, j, c, o, d, n) {
        o = "^"; d = 0; n = length(g)
        for (i = 1; i <= n; i++) {
          c = substr(g, i, 1)
          if (c == "*") { if (substr(g, i + 1, 1) == "*") { o = o ".*"; i++ } else o = o "[^/]*" }
          else if (c == "?") o = o "[^/]"
          else if (c == "{") { o = o "("; d++ }
          else if (c == "}" && d > 0) { o = o ")"; d-- }
          else if (c == "," && d > 0) o = o "|"
          else if (c == "[") { j = index(substr(g, i), "]"); if (j > 0) { o = o substr(g, i, j); i += j - 1 } else o = o "\\[" }
          else if (index(".+()|^$\\", c) > 0) o = o "\\" c
          else o = o c
        }
        return o "$"
      }
      # The literal prefix: everything before the first glob character.
      function litlen(g,   i, c) {
        for (i = 1; i <= length(g); i++) { c = substr(g, i, 1); if (index("*?[{", c) > 0) return i - 1 }
        return length(g)
      }
      # The alternatives of a {a,b} glob, one per line; AppArmor matches each alone.
      function expand(g,   i, c, d, ob, cb, parts, np, k, out, piece, st) {
        ob = index(g, "{"); if (ob == 0) return g "\n"
        d = 0
        for (i = ob; i <= length(g); i++) {
          c = substr(g, i, 1)
          if (c == "{") d++
          else if (c == "}") { d--; if (d == 0) { cb = i; break } }
        }
        if (!cb) return g "\n"
        np = 0; d = 0; st = ob + 1
        for (i = ob + 1; i <= cb; i++) {
          c = substr(g, i, 1)
          if (c == "{") d++
          else if (c == "}" && d > 0) d--
          else if ((c == "," && d == 0) || i == cb) { parts[++np] = substr(g, st, i - st); st = i + 1 }
        }
        out = ""
        for (k = 1; k <= np; k++) out = out expand(substr(g, 1, ob - 1) parts[k] substr(g, cb + 1))
        return out
      }
      function consider(h,   name, at, rest, q, k, vn, nc, cs, hit, alts, na, a, best, l, undef) {
        sub(/[ \t]+flags[ \t]*=[ \t]*\([^)]*\)$/, "", h)
        if (h ~ /^profile[ \t]/) {
          sub(/^profile[ \t]+/, "", h)
          if (h ~ /^"/) { name = substr(h, 2); q = index(name, "\""); rest = substr(name, q + 1); name = substr(name, 1, q - 1) }
          else { name = h; sub(/[ \t].*/, "", name); rest = substr(h, length(name) + 1) }
          sub(/^[ \t]+/, "", rest); at = rest
          if (at == "" && name ~ /^\//) at = name
        } else if (h ~ /^("?\/|@\{)/) { name = h; at = h }
        else return
        gsub(/"/, "", at); gsub(/"/, "", name)
        if (at == "" || name == "runc") return
        # A variable this file does not define (most come from tunables/global, such as
        # @{multiarch}) stands for any string: ** matches whatever it could expand to, so a
        # path that cannot match even then is no rival, and one that can stays unsure.
        undef = 0
        for (k = 0; k < 8 && match(at, /@\{[A-Za-z0-9_]+\}/); k++) {
          vn = substr(at, RSTART + 2, RLENGTH - 3)
          if (!(vn in vars)) { at = substr(at, 1, RSTART - 1) "**" substr(at, RSTART + RLENGTH); undef = 1; continue }
          at = substr(at, 1, RSTART - 1) "{" vars[vn] "}" substr(at, RSTART + RLENGTH)
        }
        if (at ~ /@\{/) { print "unsure\t" file "\t" name; return }
        nc = split(cands, cs, " "); na = split(expand(at), alts, "\n"); hit = 0; best = -1
        for (a = 1; a <= na; a++) {
          if (alts[a] == "") continue
          for (k = 1; k <= nc; k++) if (cs[k] != "" && cs[k] ~ g2re(alts[a])) { hit = 1; l = litlen(alts[a]); if (l > best) best = l }
        }
        if (!hit) return
        if (undef) { print "unsure\t" file "\t" name; return }
        if (index("\n" loaded "\n", "\n" name "\n") > 0 && best >= ours + 0) print "sure\t" file "\t" name
        else print "unsure\t" file "\t" name
      }
      { sub(/#.*/, ""); line = $0 }
      line ~ /^[ \t]*@\{[A-Za-z0-9_]+\}[ \t]*\+?=/ {
        v = line; sub(/^[ \t]*@\{/, "", v); nm = v; sub(/\}.*/, "", nm); sub(/^[^=]*=[ \t]*/, "", v)
        gsub(/[ \t]+$/, "", v); gsub(/[ \t]+/, ",", v); gsub(/"/, "", v)
        if (nm in vars) vars[nm] = vars[nm] "," v; else vars[nm] = v
        pend = ""; next
      }
      line ~ /^[ \t]*\{[ \t]*$/ { if (pend != "") consider(pend); pend = ""; next }
      line ~ /\{[ \t]*$/ {
        h = line; sub(/\{[ \t]*$/, "", h); sub(/^[ \t]+/, "", h); sub(/[ \t]+$/, "", h)
        consider(h); pend = ""; next
      }
      line ~ /^[ \t]*(profile[ \t]|"?\/|@\{)/ && line !~ /,[ \t]*$/ {
        pend = line; sub(/^[ \t]+/, "", pend); sub(/[ \t]+$/, "", pend); next
      }
      line !~ /^[ \t]*$/ { pend = "" }
    ' "$f" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
      out+="unsure"$'\t'"${f}"$'\t'"(this run could not read its profiles)"$'\n'
    else
      out+="${res}"$'\n'
    fi
  done
  while IFS= read -r name; do
    [[ "$name" == *runc* && "$name" != runc && "$name" != *//* ]] || continue
    k="profile[[:space:]]+\"?${name}\"?[[:space:]]"
    grep -qE "$k" "$TB_K3S_APPARMOR_D"/* 2>/dev/null && continue
    out+="unsure"$'\t'"(loaded, no file in ${TB_K3S_APPARMOR_D})"$'\t'"${name}"$'\n'
  done <<<"$loaded"
  out="$(printf '%s' "$out" | sed '/^$/d')"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# _native_k3s_apparmor_runc_render -- the profile: Ubuntu's own runc profile with
# k3s's runc added to its attachment, in AppArmor 4.0's syntax (24.04's parser).
_native_k3s_apparmor_runc_render() {
  printf '%s\n' \
    "# Written by the tracebloc installer (scripts/lib/k3s.sh); tracebloc delete removes it." \
    "# Ubuntu's runc profile (${TB_K3S_APPARMOR_DISTRO_RUNC_PATH}), extended to k3s's bundled runc." \
    "abi <abi/4.0>," \
    "include <tunables/global>" \
    "" \
    "profile runc /{usr/bin,usr/sbin,${TB_K3S_DATA_PATH#/}/data/*/bin}/runc flags=(unconfined) {" \
    "  userns," \
    "" \
    "  # Site-specific additions and overrides. See local/README for details." \
    "  include if exists <local/runc>" \
    "}"
}

# _native_k3s_apparmor_dropin_render PARSER -- k3s's systemd drop-in: re-load the
# profile before every k3s start. A failed load is logged and k3s starts anyway.
_native_k3s_apparmor_dropin_render() {
  printf '%s\n' \
    "# Written by the tracebloc installer (scripts/lib/k3s.sh); tracebloc delete removes it." \
    "# Re-loads the AppArmor profile for k3s's runc before k3s starts." \
    "[Unit]" \
    "After=apparmor.service" \
    "" \
    "[Service]" \
    "ExecStartPre=-${1} -r ${TB_K3S_APPARMOR_RUNC_PATH}"
}

# _native_k3s_apparmor_apt_hook_render PARSER -- apt's DPkg::Post-Invoke hook: re-load the
# profile once dpkg is done. Silent and exit 0 when the profile or the parser is gone.
_native_k3s_apparmor_apt_hook_render() {
  printf '%s\n' \
    "// Written by the tracebloc installer (scripts/lib/k3s.sh); tracebloc delete removes it." \
    "// Re-loads the AppArmor profile for k3s's runc: an apparmor package update re-loads the distro's runc profile over it." \
    "DPkg::Post-Invoke { \"if [ -r ${TB_K3S_APPARMOR_RUNC_PATH} ] && [ -x ${1} ]; then ${1} -r ${TB_K3S_APPARMOR_RUNC_PATH} || true; fi\"; };"
}

# _native_k3s_apparmor_stacked -- how many processes carry the stacked label, read as
# root from /proc (TB_K3S_APPARMOR_PROC, a test seam); 0 when none or unreadable.
TB_K3S_APPARMOR_PROC="/proc"
_native_k3s_apparmor_stacked() {
  local n
  # shellcheck disable=SC2016  # $1 is the inner sh's, on purpose
  n="$(tb_root sh -c 'cat "$1"/[0-9]*/attr/current 2>/dev/null | grep -c "//&unconfined"' sh "$TB_K3S_APPARMOR_PROC" 2>/dev/null)" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# _native_k3s_apparmor_runc -- step c's AppArmor step, before k3s starts: on a host
# _native_k3s_apparmor_runc_due names, refuse a rival profile by name, write the
# profile, the drop-in and (where apt is) apt's hook, record the profile, and load it.
# None of the three restarts k3s: the load is direct, and a restart would not restart
# a pod. Processes still stacked from before this run are named, with the remedy.
# Any other host: nothing.
_native_k3s_apparmor_runc() {
  local parser rivals sure unsure before stacked
  _native_k3s_apparmor_runc_due || return 0
  parser="$(_native_k3s_apparmor_parser)" \
    || error "This machine's AppArmor converts k3s's container start to a stacked profile, which stops every container from signalling itself (MySQL's first start then hangs), and no root-owned apparmor_parser, which loads the profile that prevents it, is installed. Install it ('sudo apt-get install apparmor'), then re-run the installer."
  if rivals="$(_native_k3s_apparmor_rival)"; then
    sure="$(printf '%s\n' "$rivals" | awk -F '\t' -v q="'" '$1 == "sure" { printf "profile %s%s%s in %s; ", q, $3, q, $2 }')"
    unsure="$(printf '%s\n' "$rivals" | awk -F '\t' -v q="'" '$1 == "unsure" { printf "profile %s%s%s in %s; ", q, $3, q, $2 }')"
    [[ -z "$unsure" ]] || warn "AppArmor: ${unsure} may attach to k3s's runc under a name other than runc, and this run cannot tell whether it wins over runc (a variable it can't expand, a profile the kernel doesn't hold or with a shorter literal prefix, or one loaded with no file here). If it does, runc can't stop k3s's containers; check its attachment."
    [[ -z "$sure" ]] || error "AppArmor: ${sure} attaches to k3s's runc (${TB_K3S_DATA_PATH}/data/<hash>/bin/runc) under a name other than runc, so it would win over the runc profile this installer loads, and runc could not stop k3s's containers. Check with whoever manages that profile whether it should cover k3s's runc; once it no longer does (or is named runc), re-run the installer."
  fi
  before="$TB_K3S_FILES_CHANGED"
  # The drop-in directory is made 0755 (systemd's own convention), never re-moded when it exists.
  { tb_root mkdir -p "${TB_K3S_APPARMOR_RUNC_PATH%/*}" \
      && { tb_root test -d "${TB_K3S_APPARMOR_DROPIN_PATH%/*}" || tb_root install -d -m 0755 "${TB_K3S_APPARMOR_DROPIN_PATH%/*}"; }; } \
    || error "native k3s: couldn't create ${TB_K3S_APPARMOR_RUNC_PATH%/*} or ${TB_K3S_APPARMOR_DROPIN_PATH%/*}. Check that sudo can write there, then re-run."
  _native_k3s_install_file 0644 "$TB_K3S_APPARMOR_RUNC_PATH" "$(_native_k3s_apparmor_runc_render)" \
    || error "native k3s: couldn't write ${TB_K3S_APPARMOR_RUNC_PATH}. Check that sudo can write there, then re-run."
  tb_record_write file apparmor-runc "$TB_K3S_APPARMOR_RUNC_PATH"
  TB_K3S_FILES_CHANGED=""
  _native_k3s_install_file 0644 "$TB_K3S_APPARMOR_DROPIN_PATH" "$(_native_k3s_apparmor_dropin_render "$parser")" \
    || error "native k3s: couldn't write ${TB_K3S_APPARMOR_DROPIN_PATH}. Check that sudo can write there, then re-run."
  # systemd reads a new or changed drop-in only after a daemon-reload.
  if [[ -n "$TB_K3S_FILES_CHANGED" ]]; then
    tb_root systemctl daemon-reload >>"${LOG_FILE:-/dev/null}" 2>&1 \
      || log "native k3s: 'systemctl daemon-reload' failed after writing ${TB_K3S_APPARMOR_DROPIN_PATH}; k3s's install script reloads systemd next."
  fi
  if tb_root test -d "${TB_K3S_APPARMOR_APT_HOOK_PATH%/*}"; then
    _native_k3s_install_file 0644 "$TB_K3S_APPARMOR_APT_HOOK_PATH" "$(_native_k3s_apparmor_apt_hook_render "$parser")" \
      || error "native k3s: couldn't write ${TB_K3S_APPARMOR_APT_HOOK_PATH}. Check that sudo can write there, then re-run."
  fi
  TB_K3S_FILES_CHANGED="$before"
  tb_root "$parser" -r "$TB_K3S_APPARMOR_RUNC_PATH" >>"${LOG_FILE:-/dev/null}" 2>&1 \
    || error "native k3s: '${parser} -r ${TB_K3S_APPARMOR_RUNC_PATH}' failed, so k3s's containers could not signal themselves on this machine. 'sudo ${parser} -r ${TB_K3S_APPARMOR_RUNC_PATH}' says why; it's safe to re-run this installer."
  log "native k3s: AppArmor profile 'runc' loaded for k3s's runc (${TB_K3S_APPARMOR_RUNC_PATH}; re-loaded by ${TB_K3S_APPARMOR_DROPIN_PATH} and, where apt is, ${TB_K3S_APPARMOR_APT_HOOK_PATH})."
  stacked="$(_native_k3s_apparmor_stacked)"
  if (( stacked > 0 )); then
    warn "${stacked} process(es) in k3s's containers started before this run and still carry the stacked AppArmor label, so they cannot signal themselves (a database's first start hangs). Their pods keep it until they restart; restarting k3s does not restart them."
    local ns="${namespace:-}"
    # On a re-run sign-in has not named it yet; the install record has, from the run before.
    if [[ -z "$ns" ]]; then
      ns="$(_tb_record_prior namespace "$(cat "$(tb_record_path)" 2>/dev/null)")"
      ns="${ns#\"}"; ns="${ns%\"}"; [[ "$ns" != null ]] || ns=""
    fi
    if [[ -n "$ns" ]]; then
      hint "The count is machine-wide. Restart the pods: 'sudo k3s kubectl delete pod --all -n ${ns}' and 'sudo k3s kubectl delete pod --all -n kube-system', or reboot this machine."
    else
      hint "The count is machine-wide. Restart the pods: 'sudo k3s kubectl get pods -A' names their namespaces; 'sudo k3s kubectl delete pod --all -n <each one>', or reboot this machine."
    fi
  fi
}
