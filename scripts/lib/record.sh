#!/usr/bin/env bash
# =============================================================================
#  record.sh — the install record: its stamped contract, the writer, and the
#  root copy. Sourced by install-k8s.sh.
# =============================================================================

# ── The installer contract: the install record ──────────────────────────────
#  Stamped from scripts/spec/install-record.schema.json, like substrate.sh's
#  substrate stamps, and held to it by install-contract.bats:
#    TB_INSTALL_RECORD_VERSION      properties.schema_version.const
#    TB_ARTEFACT_KINDS              $defs.artefact.properties.kind.enum, space-separated
#    TB_ARTEFACT_FLAGS              $defs.artefact's boolean properties, space-separated
#    TB_RECORD_USER_PATH            x-tracebloc-record.user-path (a leading ~ is $HOME)
#    TB_RECORD_ROOT_PATH            x-tracebloc-record.root-path (<user> is the login name)
#    TB_RECORD_LAST_IN_USE          x-tracebloc-last-in-use.kinds, space-separated
TB_INSTALL_RECORD_VERSION=1
TB_ARTEFACT_KINDS="k3d-cluster binary launch-agent launch-daemon helm-release k3s-install file firewall-rule wsl-distro logon-task kube-context group apple-container container-node job-data engine-bundles"
TB_ARTEFACT_FLAGS="created_by_prepare_host"
# shellcheck disable=SC2088  # a template: tb_record_path substitutes the ~, never the shell
TB_RECORD_USER_PATH="~/.tracebloc/install-record.json"
TB_RECORD_ROOT_PATH="/var/lib/tracebloc/<user>/install-record.json"
TB_RECORD_LAST_IN_USE="apple-container"

# ── Install record ──────────────────────────────────────────────────────────
#  What this install created, for an uninstall to remove exactly that. Written
#  as the install goes: tb_record_write KIND ID PATH [FLAG=true|false] records
#  one artefact the moment it exists, tb_record_drop KIND ID PATH takes one out
#  once it is gone, and tb_record_write alone refreshes the other fields. FLAG is
#  one boolean member the schema declares for an artefact
#  (TB_ARTEFACT_FLAGS: created_by_prepare_host, on a group). The writer reads its
#  previous output back: an artefact an earlier run recorded is kept
#  (_tb_record_artefacts, any layout), and so is a field this run has not decided
#  yet (_tb_record_prior, the writer's layout). No jq or python3 on this path.
#  Best-effort: a record that cannot be written is logged, never fatal.
#  Written only once main() has armed it, after the refusals, when the run is
#  committed to installing. Assigned here, never read from the environment: a
#  library function a unit test or a harness calls directly writes nothing.
#  cli-dev's install-record drift check and its delete e2e source this file at a
#  pinned ref and assign TRACEBLOC_RECORD_ARMED and TRACEBLOC_KUBE_CONTEXT after it.
TRACEBLOC_RECORD_ARMED=""
# _tb_record_armed -- true once main() (or a harness) has armed the writer.
_tb_record_armed() { [[ "${TRACEBLOC_RECORD_ARMED:-}" == "1" ]]; }
# Prepared mode (prepare-host on native k3s, 1.1g): the record belongs to the user
# the administrator named, never to the administrator who runs it. TB_RECORD_FOR_USER
# is that user's login name (the record's `user`, and the root copy's <user>),
# TB_RECORD_FOR_HOME their home from passwd, where their own copy goes, and
# TRACEBLOC_RECORD_HOME the private directory this process builds the record in. Set only by
# tb_record_for_user, and assigned here like TRACEBLOC_RECORD_ARMED, so the environment can
# never point a record at another user.
TB_RECORD_FOR_USER=""
TB_RECORD_FOR_HOME=""
TRACEBLOC_RECORD_HOME=""
# The key prepare-host records the NVIDIA runtime its GPU gate registered under, and
# that runtime (k3s-prepared.sh _native_k3s_prepared_finish sets it), for the named user's
# Tier 0 install to read (_native_k3s_gpu_adopt): that user cannot ask k3s's
# containerd. Assigned here, like TB_RECORD_FOR_USER, never read from the environment.
TB_RECORD_PREPARED_GPU_KEY="prepared_gpu_runtime"
TB_RECORD_PREPARED_GPU_RUNTIME=""
# The user copy: x-tracebloc-record.user-path, its leading ~ as $HOME (in prepared
# mode, as the directory the record is built in).
tb_record_path() { printf '%s%s' "${TRACEBLOC_RECORD_HOME:-${HOME:-}}" "${TB_RECORD_USER_PATH#\~}"; }

# The login name the record is written for: the named user in prepared mode, else
# the user this process runs as.
_tb_record_user() {
  if [[ -n "${TB_RECORD_FOR_USER:-}" ]]; then printf '%s' "$TB_RECORD_FOR_USER"; return 0; fi
  id -un 2>/dev/null || printf '%s' "${USER:-}"
}

# tb_record_for_user USER HOME -- prepared mode: from here this process's record is
# USER's. It is built in a private scratch directory, seeded with USER's own record
# when they have one, so an artefact an earlier install recorded is kept. Every write
# then copies it to USER's own record path under HOME, written as USER
# (_tb_record_user_copy), and to the root copy keyed on USER. Fails when the scratch
# directory cannot be made.
tb_record_for_user() {
  local u="$1" h="$2" scratch=""
  [[ -n "$u" && "$h" == /* ]] || return 1
  tb_scratch_dir scratch tracebloc-record || return 1
  mkdir -p "${scratch}/.tracebloc" || return 1
  TB_RECORD_FOR_USER="$u"; TB_RECORD_FOR_HOME="$h"; TRACEBLOC_RECORD_HOME="$scratch"
  _tb_record_as_user "$u" cat "${h}${TB_RECORD_USER_PATH#\~}" > "$(tb_record_path)" 2>/dev/null \
    || rm -f "$(tb_record_path)"
  return 0
}

# _tb_record_as_user USER CMD... -- CMD as USER, never prompting: tb_root_as, which
# goes through sudo when this process can sudo without a password (preflight_sudo
# primed it), else through runuser when it is root. The sudo() shadow cannot do
# this: as root it runs its arguments as a command.
_tb_record_as_user() {
  local u="$1"; shift
  tb_root_as "$u" "$@"
}

# _tb_record_user_copy REC -- prepared mode: REC to the named user's own record path
# under their home, written AS that user under umask 077, so the directory comes out
# 0700 and the file 0600, both theirs, and root never writes into a directory the
# user controls. Logged, never fatal, like every record write: prepare-host reads
# the copy back at its end.
_tb_record_user_copy() {
  [[ -n "${TB_RECORD_FOR_USER:-}" && -n "${TB_RECORD_FOR_HOME:-}" ]] || return 0
  local dst="${TB_RECORD_FOR_HOME}${TB_RECORD_USER_PATH#\~}"
  # shellcheck disable=SC2016  # $1 is the inner sh's, on purpose
  if _tb_record_as_user "$TB_RECORD_FOR_USER" sh -c 'umask 077 && mkdir -p "${1%/*}" && cat > "$1.tmp" && mv -f "$1.tmp" "$1"' sh "$dst" < "$1" 2>/dev/null; then
    return 0
  fi
  log "Install record: couldn't write ${TB_RECORD_FOR_USER}'s copy ${dst}."
  return 0
}

# The root copy for login name $1: x-tracebloc-record.root-path with <user> filled
# in. TRACEBLOC_RECORD_ROOT_DIR, a test seam, replaces the directory above <user>.
_tb_record_root_path() {
  printf '%s/%s%s' "${TRACEBLOC_RECORD_ROOT_DIR:-${TB_RECORD_ROOT_PATH%%/<user>*}}" "$1" "${TB_RECORD_ROOT_PATH#*<user>}"
}

# $1 as a JSON string literal, or null when empty.
_tb_json() {
  if [[ -z "${1:-}" ]]; then printf 'null'; return 0; fi
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# The JSON literal a previous write left for top-level KEY ($1) in record text $2.
_tb_record_prior() {
  local v
  v="$(printf '%s\n' "$2" | sed -n "s/^  \"$1\": \(.*[^,]\),\{0,1\}\$/\1/p")"
  printf '%s' "${v%%$'\n'*}"
}

# Top-level field KEY ($1): this run's value ($2) wins, else the value the
# previous write left in record text $3, else null.
_tb_record_field() {
  local p; p="$(_tb_record_prior "$1" "${3:-}")"
  if [[ -n "${2:-}" ]]; then _tb_json "$2"; return 0; fi
  printf '%s' "${p:-null}"
}

# _tb_record_artefacts -- the artefacts of the record text on stdin, one per line
# in the writer's own form (_tb_record_render), so a record reformatted or with
# its keys reordered (jq, an editor, json.dump(indent=2)) keeps every artefact
# and the kind+id+path match still finds it. Fails when the text holds anything
# it cannot read as a record of declared artefact members: the caller must not
# rewrite what it could not read. No text, no artefacts.
_tb_record_artefacts() {
  LC_ALL=C awk -v flags="$TB_ARTEFACT_FLAGS" '
    { text = text $0 "\n" }
    function lex(s,   n, i, j, c) {
      n = length(s); i = 1; nt = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
        if (c == "\"") {
          for (j = i + 1; j <= n; j++) {
            c = substr(s, j, 1)
            if (c == "\\") { j++; continue }
            if (c == "\"" || c == "\n") break
          }
          if (j > n || c != "\"") return 0
          tok[++nt] = substr(s, i, j - i + 1); i = j + 1; continue
        }
        if (index("{}[]:,", c)) { tok[++nt] = c; i++; continue }
        for (j = i; j <= n && index("{}[]:,\" \t\r\n", substr(s, j, 1)) == 0; j++) ;
        tok[++nt] = substr(s, i, j - i); i = j
      }
      return 1
    }
    function scalar(t) { return substr(t, 1, 1) == "\"" || t == "true" || t == "false" || t == "null" }
    # value(p) -- the token after the value starting at p, or 0 when it is not one.
    function value(p,   d) {
      if (scalar(tok[p]) || tok[p] ~ /^-?[0-9]/) return p + 1
      if (tok[p] != "{" && tok[p] != "[") return 0
      for (d = 0; p <= nt; p++) {
        if (tok[p] == "{" || tok[p] == "[") d++
        else if (tok[p] == "}" || tok[p] == "]") { if (--d == 0) return p + 1 }
      }
      return 0
    }
    # artefact(p) -- one artefact object at p printed in the writer form; the token
    # after it, or 0.
    function artefact(p,   k, v, f, nf, i, line) {
      if (tok[p++] != "{") return 0
      split("", m)
      while (tok[p] != "}") {
        k = tok[p]; v = tok[p + 2]
        if (k !~ /^"[a-z_]+"$/ || tok[p + 1] != ":" || !scalar(v) || (k in m)) return 0
        m[k] = v; p += 3
        if (tok[p] == ",") p++
        else if (tok[p] != "}") return 0
      }
      if (!("\"kind\"" in m) || !("\"id\"" in m) || !("\"path\"" in m) || !("\"created_at\"" in m)) return 0
      line = "{\"kind\": " m["\"kind\""] ", \"id\": " m["\"id\""] ", \"path\": " m["\"path\""] ", "
      nf = split(flags, f, " ")
      for (i = 1; i <= nf; i++) {
        k = "\"" f[i] "\""
        if (k in m) { line = line k ": " m[k] ", "; delete m[k] }
      }
      line = line "\"created_at\": " m["\"created_at\""] "}"
      delete m["\"kind\""]; delete m["\"id\""]; delete m["\"path\""]; delete m["\"created_at\""]
      for (k in m) return 0
      out[++no] = line
      return p + 1
    }
    END {
      if (!lex(text)) exit 1
      if (nt == 0) exit 0
      if (tok[1] != "{") exit 1
      p = 2
      while (tok[p] != "}") {
        if (substr(tok[p], 1, 1) != "\"" || tok[p + 1] != ":") exit 1
        if (tok[p] == "\"artefacts\"") {
          if (seen++ || tok[p + 2] != "[") exit 1
          p += 3
          while (tok[p] != "]") {
            if (!(p = artefact(p))) exit 1
            if (tok[p] == ",") p++
            else if (tok[p] != "]") exit 1
          }
          p++
        } else if (!(p = value(p + 2))) exit 1
        if (tok[p] == ",") p++
        else if (tok[p] != "}") exit 1
      }
      if (p != nt) exit 1
      for (i = 1; i <= no; i++) print out[i]
    }'
}

tb_record_write() {
  # The record's home is tb_record_path's: in prepared mode the scratch directory,
  # so a prepare-host run with HOME unset (systemd, cloud-init, env -i) still records.
  _tb_record_armed && [[ -n "${TRACEBLOC_RECORD_HOME:-${HOME:-}}" ]] || return 0
  local rec dir now prior="" arts="" root_copy prepared_for prepared_gpu k3s_data_fs=""
  rec="$(tb_record_path)"; dir="${rec%/*}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$dir" 2>/dev/null || { log "Install record: couldn't create ${dir}; not recorded."; return 0; }
  if [[ -f "$rec" ]]; then prior="$(cat "$rec" 2>/dev/null || true)"; fi
  if ! arts="$(printf '%s\n' "$prior" | _tb_record_artefacts)"; then
    log "Install record: couldn't read the artefacts in ${rec}; left as it is${1:+, ${1} ${2:-} not recorded}."
    return 0
  fi
  if [[ -n "${1:-}" ]]; then
    # A kind the schema does not declare would make the whole record invalid, so
    # it is refused by name and the record keeps what it had.
    case " ${TB_ARTEFACT_KINDS} " in
      *" $1 "*) ;;
      *) log "Install record: '${1}' is not an artefact kind the schema declares; not recorded."; return 0 ;;
    esac
    # FLAG: one boolean member the schema declares, NAME=true|false. Anything else
    # would make the whole record invalid, so it is refused by name like a kind.
    local flag=""
    if [[ -n "${4:-}" ]]; then
      local name="${4%%=*}" val="${4#*=}"
      if [[ "$name" == *[!a-z_]* || " ${TB_ARTEFACT_FLAGS} " != *" ${name} "* || ( "$val" != true && "$val" != false ) ]]; then
        log "Install record: '${4}' is not a NAME=true|false flag the schema declares; ${1} not recorded."; return 0
      fi
      flag="\"${name}\": ${val}, "
    fi
    # Keyed on kind + id + path, never the flag: a re-run that finds it already
    # recorded keeps the first line, its created_at and its flag. For a kind whose
    # last entry is the one in use (TB_RECORD_LAST_IN_USE), that line also moves to
    # the end, so a downgrade to a version recorded earlier is what the record
    # names last.
    local key line kept="" rest=""
    key="{\"kind\": $(_tb_json "$1"), \"id\": $(_tb_json "${2:-}"), \"path\": $(_tb_json "${3:-}"), "
    if [[ -n "${_tb_record_dropping:-}" ]]; then
      # tb_record_drop: every line under the key goes, and nothing is added.
      while IFS= read -r line; do
        [[ "$line" == "$key"* ]] || rest="${rest:+${rest}$'\n'}${line}"
      done <<<"$arts"
      arts="$rest"
    else
      case "$arts" in
        *"$key"*)
          case " ${TB_RECORD_LAST_IN_USE} " in
            *" $1 "*)
              while IFS= read -r line; do
                if [[ "$line" == "$key"* ]]; then kept="${kept:+${kept}$'\n'}${line}"; else rest="${rest:+${rest}$'\n'}${line}"; fi
              done <<<"$arts"
              arts="${rest:+${rest}$'\n'}${kept}" ;;
          esac ;;
        *) arts="${arts:+${arts}$'\n'}${key}${flag}\"created_at\": \"${now}\"}" ;;
      esac
    fi
  fi
  local substrate
  substrate="$(_tb_json "$TRACEBLOC_SUBSTRATE_RESOLVED")"
  # root_copy: the root copy's path once one exists. The previous write's value
  # stands until this run writes the copy; the first write that does re-renders
  # the user copy with it and copies again, so the two copies stay identical.
  root_copy="$(_tb_record_field root_copy "" "$prior")"
  # prepared_for: the user an administrator prepared this host for. Only prepared mode
  # (tb_record_for_user, prepare-host) names one; that user's own later writes keep the
  # previous write's value; any other record has none, so the key is left out.
  if [[ -n "${TB_RECORD_FOR_USER:-}" ]]; then prepared_for="$(_tb_json "$TB_RECORD_FOR_USER")"
  else prepared_for="$(_tb_record_prior prepared_for "$prior")"; fi
  # prepared_gpu_runtime, beside it: in prepared mode this run's value or null, never
  # the previous write's, so a prepare-host re-run that wires no GPU takes it away.
  # The user's own later writes keep it; any other record has none.
  if [[ -n "${TB_RECORD_FOR_USER:-}" ]]; then prepared_gpu="$(_tb_json "${TB_RECORD_PREPARED_GPU_RUNTIME:-}")"
  else prepared_gpu="$(_tb_record_prior "$TB_RECORD_PREPARED_GPU_KEY" "$prior")"; fi
  # k3s_data_fs: the filesystem under native k3s's data directory,
  # read afresh on every write of a native k3s install on Linux, the WSL distro
  # included, by k3s.sh's reader. A Mac writes none: the Mac's node runs
  # tracebloc's pinned VM image.
  if [[ "${OS:-}" == Linux && "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == k3s ]] && declare -F _native_k3s_data_fs >/dev/null 2>&1; then
    k3s_data_fs="$(_native_k3s_data_fs)"
  fi
  _tb_record_put "$rec" "$(_tb_record_render "$substrate" "$prior" "$arts" "$now" "$root_copy" "$prepared_for" "$k3s_data_fs" "$prepared_gpu")" || return 0
  _TB_RECORD_ROOT_WRITTEN=""
  _tb_record_root_copy "$rec"
  if [[ -n "$_TB_RECORD_ROOT_WRITTEN" && "$(_tb_json "$_TB_RECORD_ROOT_WRITTEN")" != "$root_copy" ]]; then
    root_copy="$(_tb_json "$_TB_RECORD_ROOT_WRITTEN")"
    _tb_record_put "$rec" "$(_tb_record_render "$substrate" "$prior" "$arts" "$now" "$root_copy" "$prepared_for" "$k3s_data_fs" "$prepared_gpu")" || return 0
    _tb_record_root_copy "$rec"
  fi
  _tb_record_user_copy "$rec"
  return 0
}

# tb_record_drop KIND ID PATH -- the artefact tb_record_write recorded under KIND ID
# PATH is gone: its line leaves both copies, through tb_record_write's own read, key
# and write (the local reaches it, as bash scopes it into its callees).
tb_record_drop() {
  local _tb_record_dropping=1
  tb_record_write "$1" "${2:-}" "${3:-}"
}

# The record's text: SUBSTRATE ($1) and ROOT_COPY ($5) as JSON literals, the
# previous write's text ($2), its artefact lines ($3) and the time ($4). PREPARED_FOR
# ($6), K3S_DATA_FS ($7), PREPARED_GPU ($8) and K3D_CLEARED ($9), JSON literals, are
# written only when there is one.
_tb_record_render() {
  local out line n i
  out="{
  \"schema_version\": ${TB_INSTALL_RECORD_VERSION},
  \"substrate\": $1,
  \"user\": $(_tb_record_field user "$(_tb_record_user)" "$2"),
  \"cluster_name\": $(_tb_record_field cluster_name "${cluster_name:-}" "$2"),
  \"kube_context\": $(_tb_record_field kube_context "$(_tb_kube_context)" "$2"),
  \"data_dir\": $(_tb_record_field data_dir "${host_data_dir:-}" "$2"),
  \"namespace\": $(_tb_record_field namespace "${namespace:-}" "$2"),
  \"installer_version\": $(_tb_record_field installer_version "${TB_VERSION:-}" "$2"),
  \"root_copy\": $5,"
  if [[ -n "${6:-}" ]]; then out+=$'\n  "prepared_for": '"$6"','; fi
  if [[ -n "${8:-}" ]]; then out+=$'\n  "'"${TB_RECORD_PREPARED_GPU_KEY}"'": '"$8"','; fi
  if [[ -n "${7:-}" ]]; then out+=$'\n  "k3s_data_fs": '"$7"','; fi
  if [[ -n "${9:-}" ]]; then out+=$'\n  "k3d_cleared": '"$9"','; fi
  out+="
  \"updated_at\": \"$4\","
  if [[ -z "$3" ]]; then
    out+=$'\n  "artefacts": []\n}'
  else
    out+=$'\n  "artefacts": ['
    n="$(printf '%s\n' "$3" | wc -l | tr -d ' ')"; i=0
    while IFS= read -r line; do
      i=$((i + 1))
      out+=$'\n    '"$line"
      if [[ "$i" -lt "$n" ]]; then out+=","; fi
    done <<<"$3"
    out+=$'\n  ]\n}'
  fi
  printf '%s' "$out"
}

# Write record text $2 to the user copy $1 atomically. Non-zero (logged) when it
# could not; the caller stops there.
_tb_record_put() {
  local tmp
  tmp="$(mktemp "${1%/*}/.install-record.XXXXXX" 2>/dev/null)" || { log "Install record: couldn't write in ${1%/*}; not recorded."; return 1; }
  if printf '%s\n' "$2" >"$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null
  log "Install record: couldn't write ${1}; not recorded."
  return 1
}

# Linux keeps a root copy for sudo and headless uninstalls, at
# x-tracebloc-record.root-path (/var/lib/tracebloc/<user>/install-record.json).
# Written only as root, or with a sudo that needs no password; Tier 0 promised no
# administrator rights and gets none. Never prompts, never fails the install.
# Sets _TB_RECORD_ROOT_WRITTEN to the copy's path when this call wrote it.
_tb_record_root_copy() {
  [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] || return 0
  [[ "${INSTALL_TIER:-}" != "0" ]] || return 0
  local user="${TB_RECORD_FOR_USER:-}" dst
  [[ -n "$user" ]] || user="$(id -un 2>/dev/null)" || return 0
  [[ -n "$user" ]] || return 0
  dst="$(_tb_record_root_path "$user")"
  if tb_root_n true 2>/dev/null; then
    if { tb_root_n mkdir -p "${dst%/*}" && tb_root_n cp "$1" "$dst"; } 2>/dev/null; then _TB_RECORD_ROOT_WRITTEN="$dst"
    else log "Install record: couldn't write the root copy ${dst}."; fi
  fi
  return 0
}

# The root copy's path for this user. Fails when the user has no name.
_tb_record_root_copy_path() {
  local user
  user="$(id -un 2>/dev/null)" || return 1
  [[ -n "$user" ]] || return 1
  _tb_record_root_path "$user"
}

# Whether this process can reach the root copy at all: it is root, or its sudo
# needs no password. Never prompts.
_tb_record_root_access() {
  [[ "$(id -u 2>/dev/null)" == "0" ]] && return 0
  _have_sudo_bin && _real_sudo -n true 2>/dev/null
}

# _tb_record_root_run CMD... -- CMD as root: directly when this is root, else
# through the password-free sudo _tb_record_root_access found.
_tb_record_root_run() {
  if [[ "$(id -u 2>/dev/null)" == "0" ]]; then "$@"; return; fi
  _real_sudo -n "$@"
}
