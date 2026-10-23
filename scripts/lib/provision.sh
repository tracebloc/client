#!/usr/bin/env bash
# =============================================================================
#  provision.sh — RFC-0001 #838: provision the client BEFORE Helm.
#
#  In the browser-auth path this installs the tracebloc CLI (FATAL — it mints the
#  credential), signs in (`tracebloc login`, the device flow), and `tracebloc
#  client create`s to mint the machine credential + derive the namespace. The
#  credential is written to a 0600 file by `--credential-file` and sourced here
#  (never printed), then handed to the Helm step via the SAME env contract
#  install_client_helm already consumes:
#      TRACEBLOC_CLIENT_ID + TRACEBLOC_CLIENT_PASSWORD + TB_NAMESPACE
#  (the namespace exported under both TB_NAMESPACE and its canonical
#  TRACEBLOC_NAMESPACE, see tb_export_namespace in common.sh)
#
#  DUAL-MODE (unchanged, one deprecation cycle): when the operator pre-supplies a
#  values file (TRACEBLOC_VALUES_FILE) or credentials (TRACEBLOC_CLIENT_ID +
#  TRACEBLOC_CLIENT_PASSWORD), browser sign-in is skipped and those paths feed
#  Helm as before. Unattended installs use dual-mode — the device-flow `login` is
#  interactive; a non-interactive enroll-token login is a CLI follow-up.
# =============================================================================

# _provisioning_preset: true when the operator already supplied a values file or
# credentials, so browser sign-in is skipped and install_client_helm uses them.
_provisioning_preset() {
  [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]] && return 0
  [[ -n "${TRACEBLOC_CLIENT_ID:-}" && -n "${TRACEBLOC_CLIENT_PASSWORD:-}" ]] && return 0
  return 1
}

# _create_plan — what `tracebloc client create` would do here, as its --plan line
# (action, id, namespace, name; tab-separated), or NO OUTPUT from a CLI without the
# flag or one that cannot answer. Side-effect free by the CLI's contract.
#
# It always exits 0; callers test the output (`[[ -n "$plan" ]]`). A "no plan" exit 1
# was recorded as a failure by the installer's ERR trap: `set -E` carries the trap
# into the `$(...)` of `if plan="$(...)"`, so every install against a CLI without
# --plan logged an error on the normal fallback (the class of backend#5025 O-103,
# see _summary_kubeconfig_hint). Both probes read /dev/null: under `curl | bash`
# the installer's stdin is the script itself, and a CLI that reads stdin would eat it.
_create_plan() {
  # Captured, not piped: under `set -o pipefail` grep -q exits on its first match,
  # which can SIGPIPE the writer mid-output and fail the probe (exit 141).
  local help
  help="$(tracebloc client create --help </dev/null 2>/dev/null || true)"
  [[ "$help" == *--plan* ]] || return 0
  tracebloc client create --plan </dev/null 2>>"${LOG_FILE:-/dev/null}" || true
  return 0
}

# _registration_machine_facts — where this machine runs, for `tracebloc client
# create` to send when it registers the client, so the dashboard can say so before
# the first heartbeat. The same detection the chart's heartbeat env gets
# (_detect_machine_kind / _detect_cloud_provider in install-client-helm.sh,
# _host_os_label in common.sh), into _TB_REG_MACHINE_KIND / _TB_REG_CLOUD_PROVIDER
# / _TB_REG_HOST_OS. Each is EMPTY when it cannot be read or its detector is not
# loaded, and the CLI then leaves it out of the registration. Always exits 0: a fact
# is not worth a registration. On Windows the distro's cluster run reads them here
# and hands them to the host's create (tb_wsl_handover_write in common.sh).
_registration_machine_facts() {
  _TB_REG_MACHINE_KIND=""; _TB_REG_CLOUD_PROVIDER=""; _TB_REG_HOST_OS=""
  if declare -F _prime_windows_host_identity >/dev/null 2>&1; then _prime_windows_host_identity || true; fi
  if declare -F _detect_machine_kind >/dev/null 2>&1; then _TB_REG_MACHINE_KIND="$(_detect_machine_kind 2>/dev/null)" || _TB_REG_MACHINE_KIND=""; fi
  if declare -F _detect_cloud_provider >/dev/null 2>&1; then _TB_REG_CLOUD_PROVIDER="$(_detect_cloud_provider 2>/dev/null)" || _TB_REG_CLOUD_PROVIDER=""; fi
  if declare -F _host_os_label >/dev/null 2>&1; then _TB_REG_HOST_OS="$(_host_os_label 2>/dev/null)" || _TB_REG_HOST_OS=""; fi
  log "Machine facts for the registration: kind=${_TB_REG_MACHINE_KIND:-unknown} cloud=${_TB_REG_CLOUD_PROVIDER:-none} os=${_TB_REG_HOST_OS:-not read}"
  return 0
}

# _trim_label VALUE — VALUE without terminal escapes or surrounding white space.
_trim_label() {
  local v; v="$(_strip_paste_garbage "$1")"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# _host_machine_name — this host's short name, the machine name's default.
_host_machine_name() {
  local raw; raw="$(hostname 2>/dev/null || uname -n 2>/dev/null || true)"
  _trim_label "${raw%%.*}"
}

# _machine_labels REUSE_NS PLAN_ACTION — the machine name and provider `client
# create` sets, into _TB_MACHINE_NAME / _TB_CLIENT_PROVIDER: TRACEBLOC_MACHINE_NAME /
# TRACEBLOC_CLIENT_PROVIDER, else asked on a terminal, else the host's name and no
# provider. Only a run that mints a client asks or defaults (PLAN_ACTION, else
# `client create --plan`): a reused client keeps what `tracebloc machine set` stored,
# and gets only what the caller set. The CLI sends a value only when it is given.
_machine_labels() {
  local reuse="$1" action="$2" host
  _TB_MACHINE_NAME="$(_trim_label "${TRACEBLOC_MACHINE_NAME:-}")"
  _TB_CLIENT_PROVIDER="$(_trim_label "${TRACEBLOC_CLIENT_PROVIDER:-}")"
  [[ -n "$_TB_MACHINE_NAME" && -n "$_TB_CLIENT_PROVIDER" ]] && return 0
  [[ -z "$reuse" ]] || return 0
  [[ -n "$action" ]] || action="$(_create_plan | cut -s -f1)"
  if [[ "$action" != mint ]]; then
    log "Machine name and provider: only what was set (client create --plan: ${action:-no answer})"
    return 0
  fi
  host="$(_host_machine_name)"
  if _prompt_tty; then
    # Plain `read`, like the client name's: see that prompt for why. EOF or an empty
    # line takes the default; the name is never required.
    printf '\n  Name this machine and its provider (change them later with: tracebloc machine set)\n' >/dev/tty 2>/dev/null || true
    if [[ -z "$_TB_MACHINE_NAME" ]]; then
      printf '  Machine name%s: ' "${host:+ [${host}]}" >/dev/tty 2>/dev/null || true
      IFS= read -r _TB_MACHINE_NAME <"$TRACEBLOC_TTY" || true
      _TB_MACHINE_NAME="$(_trim_label "$_TB_MACHINE_NAME")"
    fi
    if [[ -z "$_TB_CLIENT_PROVIDER" ]]; then
      printf '  Provider, e.g. Azure or your lab (Enter to skip): ' >/dev/tty 2>/dev/null || true
      IFS= read -r _TB_CLIENT_PROVIDER <"$TRACEBLOC_TTY" || true
      _TB_CLIENT_PROVIDER="$(_trim_label "$_TB_CLIENT_PROVIDER")"
    fi
  fi
  [[ -n "$_TB_MACHINE_NAME" ]] || _TB_MACHINE_NAME="$host"
  log "Machine name: ${_TB_MACHINE_NAME:-none}; provider: ${_TB_CLIENT_PROVIDER:-none}"
  return 0
}

# _cli_supports_provisioning: does the installed CLI ship the browser-auth mint
# commands (`tracebloc login` + `tracebloc client create`)? install_tracebloc_cli
# pulls the latest RELEASE, which can lag this installer until the cli#104 release
# ships — so probe before committing to the path. `--help` is side-effect-free and
# cobra exits non-zero on an unknown command, so this cleanly tells old from new.
_cli_supports_provisioning() {
  tracebloc login --help >/dev/null 2>&1 || return 1
  tracebloc client create --help >/dev/null 2>&1 || return 1
  return 0
}

# _prompt_tty: true when we can interactively prompt on the controlling terminal.
# `client create`'s own prompt can't fire (we redirect its output to the log), and
# under `curl | bash` stdin isn't the terminal — so read /dev/tty directly. Split
# out as a function so tests can force the non-interactive path deterministically.
_prompt_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

# TRACEBLOC_TTY: where interactive prompts READ from. Under `curl | bash` stdin is the
# piped installer, not the keyboard, so reads must come from the controlling
# terminal. Overridable so tests can feed canned input on stdin (TRACEBLOC_TTY=/dev/stdin).
: "${TRACEBLOC_TTY:=/dev/tty}"

# _login_tty_ok: is /dev/tty openable for the sign-in's redirection? Split out
# as its own function (rather than reusing _prompt_tty) purely so tests can force
# either branch: _prompt_tty gates the PROMPTS below, and several tests force it
# on while having no real /dev/tty to redirect a child process onto.
_login_tty_ok() { { : </dev/tty; } 2>/dev/null; }

# _run_device_login: one `tracebloc login`, given the user's REAL terminal.
#
# This runs after setup_log_file (`exec > >(tee …) 2>&1`), so the shell's
# stdout/stderr are a pipe and — under `curl … | bash` — stdin is the install
# pipe; a bare `tracebloc login` would then have no tty on any stream and can
# misrender or fail (same class assess.sh's hand-off handles). Redirect all three
# to /dev/tty when openable, else </dev/null (unattended reaches the dual-mode
# credential path, not here).
#
# TRACEBLOC_INSTALLER tells the CLI it is not being run by hand, so it suppresses
# its own "run `tracebloc login`" recovery line: correct for someone who typed
# the command, wrong here, where a bare login would leave the client mint and the
# Helm install undone. _device_sign_in below owns the recovery advice (cli#517).
# It is a command prefix, not an export — no later CLI call should inherit it.
_run_device_login() {
  if _login_tty_ok; then
    TRACEBLOC_INSTALLER=1 tracebloc login </dev/tty >/dev/tty 2>/dev/tty
  else
    TRACEBLOC_INSTALLER=1 tracebloc login </dev/null
  fi
}

# SIGN_IN_ATTEMPTS: how many times the device sign-in may run — the initial
# attempt plus ONE in-place retry. Declared once and used as the loop bound AND
# the "is there a next attempt?" test below, so the two can't drift into
# disagreeing about how many tries there are.
: "${SIGN_IN_ATTEMPTS:=2}"

# _device_sign_in: sign in, with ONE in-place retry for a fresh code.
#
# The device code has a hard ten-minute deadline and the human approving it is
# reading a phone — a lapsed code is an ordinary outcome, not an exceptional one.
# Before cli#517 it cost a full installer re-run: everything already done (the
# prerequisites, the cluster) was thrown away over a missed prompt. This mirrors
# the name prompt's retry loop further down, for the same reason — an interactive
# step that can fail for a benign reason must not abort a long install.
#
# Exactly one retry, and only with a live terminal:
#   • a second failure is evidence of something other than a missed code, and a
#     retry loop there would just hide it behind a prompt nobody can satisfy;
#   • without a terminal there is nobody to hand a fresh code to, and a FAILED
#     read (rc != 0 = EOF / no live input) can't be fixed by re-prompting either.
# Both fall through to the same fatal error, whose advice is the ONLY next step
# printed — the CLI's own is suppressed above.
_device_sign_in() {
  local attempt
  for (( attempt = 1; attempt <= SIGN_IN_ATTEMPTS; attempt++ )); do
    _run_device_login && return 0
    if [[ "$attempt" -ge "$SIGN_IN_ATTEMPTS" ]] || ! _prompt_tty; then break; fi
    echo ""
    warn "Sign-in didn't complete — the code lapsed or wasn't approved."
    hint "Nothing is lost: the install is paused right here, not restarted."
    # The prompt WRITE is guarded (|| true) so a test without a real /dev/tty
    # doesn't abort; the read comes from TRACEBLOC_TTY, like every other prompt here.
    printf '\n  Press Enter for a fresh code (or Ctrl-C to stop): ' >/dev/tty 2>/dev/null || true
    IFS= read -r _ <"$TRACEBLOC_TTY" || break
    echo ""
  done
  error "Sign-in didn't complete — re-run the installer to try again."
}

# _detect_location_zone: best-effort ISO country code for where this machine
# physically runs, derived from the system timezone via the OS's OWN zone.tab —
# no network call (privacy-preserving for on-prem installs) and no embedded zone
# list to drift out of sync with the backend. For single-region countries the
# carbon zone IS the ISO code (DE, FR, US, GB…); the backend validates the final
# value and a miss surfaces via _report_create_failure. Prints "<CODE> <TZ>"
# (e.g. "DE Europe/Berlin") on success, nothing otherwise.
_detect_location_zone() {
  local tz="" zt code
  if [[ -n "${TZ:-}" ]]; then
    tz="$TZ"
  elif [[ -L /etc/localtime ]]; then
    tz="$(readlink /etc/localtime 2>/dev/null)"; tz="${tz#*/zoneinfo/}"
  elif [[ -r /etc/timezone ]]; then
    IFS= read -r tz </etc/timezone 2>/dev/null || tz=""
  fi
  # A real IANA zone looks like "Area/City"; ignore anything else (e.g. "UTC").
  [[ "$tz" == */* ]] || return 0
  for zt in /usr/share/zoneinfo/zone.tab /usr/share/zoneinfo/zone1970.tab; do
    [[ -r "$zt" ]] || continue
    code="$(awk -v tz="$tz" '$1 !~ /^#/ && $3 == tz {split($1,a,","); print a[1]; exit}' "$zt" 2>/dev/null)"
    if [[ -n "$code" ]]; then printf '%s %s\n' "$code" "$tz"; return 0; fi
  done
  return 0
}

# _report_create_failure LOGFILE LOCATION — surface the REAL reason `client create`
# failed on the terminal instead of a generic "see the log". Nothing sensitive is
# exposed: a failed create minted no credential, so its captured output holds only
# the error. Special-cases the commonest tripwire — an unrecognized carbon zone
# (e.g. a city like "berlin" typed instead of a zone code).
_report_create_failure() {
  local out="$1" loc="$2" src="${3:-auto}" errmatches errline l
  echo ""
  if grep -qiE 'location.*not a valid choice' "$out" 2>/dev/null; then
    warn "\"${loc:-that location}\" isn't a recognized carbon zone — the client wasn't created."
    # The rejected value came either from TRACEBLOC_CLIENT_LOCATION (an explicit
    # override the operator set) or from the silent timezone auto-derivation.
    # Blaming the timezone when the operator pinned the value reads as "the env
    # override was ignored", so word the fix hint to the actual source.
    if [[ "$src" == env ]]; then
      hint "That value came from TRACEBLOC_CLIENT_LOCATION; set it to a valid code"
      hint "(e.g. DE, FR, US, GB — all codes: https://api.electricitymap.org/v3/zones)"
      hint "and re-run."
    else
      hint "The zone is auto-derived from this machine's timezone; to pin one, set"
      hint "TRACEBLOC_CLIENT_LOCATION=<code> (e.g. DE, FR, US, GB — all codes:"
      hint "https://api.electricitymap.org/v3/zones) and re-run."
    fi
    return 0
  fi
  # `head -4` closes the pipe once grep has produced 4 matches; under pipefail
  # the substitution then yields 141 and errexit aborts _report_create_failure
  # before warn/hint print why provisioning failed -- its entire purpose.
  errmatches="$(grep -aE 'Error:|HTTP [0-9][0-9][0-9]|refused|timed? ?out|unauthorized|forbidden|denied' "$out" 2>/dev/null || true)"
  errline="$(head -4 <<<"$errmatches")"
  if [[ -n "$errline" ]]; then
    warn "The client couldn't be provisioned:"
    while IFS= read -r l; do [[ -n "$l" ]] && hint "$l"; done <<<"$errline"
  else
    warn "The client couldn't be provisioned."
  fi
}

# _account_owns_namespace NS — does the signed-in account's client list include a
# client whose namespace is NS? `client list` prints "…namespace=<ns>   location=…";
# match that field exactly. Namespace is the only stable join key between a local
# Helm release (which stores the UUID clientId + namespace) and the list (which
# shows the numeric dashboard id + namespace) — the two don't share an id.
# Returns: 0 = owned, 1 = list read OK but NS absent, 2 = couldn't read the list.
# Split out so the pre-flight can distinguish "not yours" (refuse) from
# "couldn't tell" (fall through to `client create`'s own idempotent logic).
_account_owns_namespace() {
  local ns="$1" out
  [[ -n "$ns" ]] || return 1
  out="$(tracebloc client list --plain 2>/dev/null)" || return 2
  grep -Eq "namespace=${ns}([[:space:]]|$)" <<<"$out"
}

# _show_create_notices FILE — print the parts of a successful `client create`'s
# output the user must see. Its output goes to the log (the credential path and
# trace lines are noise on screen), but some of it is a decision about THEIR
# client: a warning that this machine's previous client is being left behind,
# or that the existing client is being reconnected with a new credential
# (backend#5365). Before this, those lines reached only the log. Prints each
# block that starts with a `⚠` line or a `✔ Reconnecting` line, plus the plain
# hint lines under it; nothing else. The credential never appears in this output
# (it goes to the 0600 file), so the passthrough cannot leak it.
_show_create_notices() {
  local _f="$1"
  [[ -s "$_f" ]] || return 0
  sed $'s/\x1b\\[[0-9;]*m//g' "$_f" | awk '
    /^  ⚠ / || /^  ✔ Reconnecting / { show = 1; print; next }
    show && /^  Credential / { next }
    show && /^  [^ ✔⚠·]/ { print; next }
    { show = 0 }
  '
}

# ── a client ID with no password, on a terminal (backend#5025 O-13, client-dev#1504) ──
#
# The clients page's + creates a client and shows its ID and password once; its
# install command carries the ID (`curl … | TRACEBLOC_CLIENT_ID=<id> bash`) and
# never the password, which would land in shell history. Before this, an ID with
# no password was no preset at all: the installer signed in in the browser and
# registered a SECOND client, and the + client stayed Offline for good. Now the
# installer asks for that client's password here, without echoing it, and the
# preset path below installs that client: no device sign-in, no second client.
#
# Gated on a controlling terminal (_prompt_tty: /dev/tty readable and writable),
# NOT on `[[ -t 0 ]]`: under `curl … | bash` stdin is the piped installer, never
# the terminal, so a stdin check would never ask. With no terminal nothing
# changes (the ID alone is no preset, as before). The password and values-file
# presets, and the Windows installer's handed-over credential, never reach it.
# _provisioning_preset is deliberately left as it is: this only fills in the
# password it reads.
_provision_wants_preset_password() {
  [[ -z "${TRACEBLOC_VALUES_FILE:-}" && -z "${TRACEBLOC_STDIN_CRED_FILE:-}" ]] || return 1
  [[ -n "${TRACEBLOC_CLIENT_ID:-}" && -z "${TRACEBLOC_CLIENT_PASSWORD:-}" ]]
}

# Asks for the password (read -s from TRACEBLOC_TTY, up to 3 tries), checks it
# with verify_credentials when that is loaded, and sets TRACEBLOC_CLIENT_PASSWORD
# in this shell -- not exported, so no child process inherits it. A rejected
# password is asked again; an inactive account, three failures, or a terminal
# that gives no input (EOF) stop with the remedy. Never prints the password.
_provision_prompt_preset_password() {
  local _pw="" _try _rc _status
  info "Installing the client with ID ${TRACEBLOC_CLIENT_ID}."
  hint "Enter the client password shown when it was created (typing is hidden)."
  for _try in 1 2 3; do
    _pw=""
    printf '  Client password: ' >/dev/tty 2>/dev/null || true
    _rc=0; IFS= read -r -s _pw <"$TRACEBLOC_TTY" || _rc=1
    printf '\n' >/dev/tty 2>/dev/null || true
    # The same cleaning the typed-credential path applies (_sanitize_credential),
    # without trimming: a password is taken as it is.
    _pw="$(_strip_paste_garbage "$_pw")"
    if [[ -z "$_pw" ]]; then
      [[ "$_rc" -ne 0 ]] && break    # EOF / no interactive input -- asking again won't help
      warn "The client password cannot be empty."
      continue
    fi
    _status="unverified"
    if declare -F verify_credentials >/dev/null 2>&1; then
      _status="$(verify_credentials "$TRACEBLOC_CLIENT_ID" "$_pw")"
    fi
    case "$_status" in
      valid|unverified)
        TRACEBLOC_CLIENT_PASSWORD="$_pw"
        return 0 ;;
      inactive)
        error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      *)
        warn "That password was rejected for client ID ${TRACEBLOC_CLIENT_ID}." ;;
    esac
    _pw=""
  done
  error "No valid password for client ID ${TRACEBLOC_CLIENT_ID}. Copy it from the page where the client was created, or set TRACEBLOC_CLIENT_PASSWORD, then re-run."
}

provision_client() {
  # No step header here — main() prints "d) Registering this machine". The
  # tracebloc CLI was installed in step b (Install what tracebloc needs); this
  # step signs in and mints the machine credential using it.

  # The Windows installer's client run (tracebloc's WSL distro): main() read the
  # credential from stdin. The host hands over an id and a password either way, from
  # a client it registered on Windows or from a pair the operator supplied there, so
  # the line claims neither.
  if [[ -n "${TRACEBLOC_STDIN_CRED_FILE:-}" ]]; then
    info "Using the credential the Windows installer handed over."
    _provision_take_credential "$TRACEBLOC_STDIN_CRED_FILE"
    return 0
  fi
  # A client ID with no password, on a terminal: ask for it (backend#5025 O-13).
  # _prompt_tty only checks the node's mode; _login_tty_ok really opens it, so a
  # headless run (node present, no controlling terminal) keeps the browser sign-in.
  if _provision_wants_preset_password && _prompt_tty && _login_tty_ok; then
    _provision_prompt_preset_password
  fi
  if _provisioning_preset; then
    info "Using the credentials you supplied — skipping browser sign-in."
    return 0
  fi

  # Browser-auth path. The CLI (installed in step b) is REQUIRED here — it mints
  # the credential — so a missing CLI is FATAL. It may live in ~/.local/bin (not
  # yet on this process's PATH); make it resolvable before the login/create calls.
  export PATH="${HOME}/.local/bin:${PATH}"
  has tracebloc || error "The tracebloc CLI is required to provision this machine but isn't available. Install it (curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh), open a new shell, and re-run."

  # The browser-auth mint path needs a CLI new enough to ship `login` + `client
  # create` (cli#104). The installed CLI comes from the latest RELEASE, which may
  # predate this installer — so if it's too old, fall back to the proven manual-
  # credential path (install_client_helm prompts for an existing client's
  # credentials, exactly as before #838) instead of hard-failing on an unknown
  # `tracebloc login`. Once the CLI release lands, the probe passes and the
  # one-step browser flow takes over automatically.
  if ! _cli_supports_provisioning; then
    warn "This tracebloc CLI is too old to provision a client from the installer — falling back to manual sign-in."
    hint "Connect an existing client below, or upgrade the CLI later for one-step browser sign-in:"
    hint "  curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh"
    return 0
  fi

  # Sign in (device flow). `tracebloc login` PRINTS a URL + one-time code and
  # waits for approval — it does NOT auto-open a browser, so the copy says "open
  # the link" (print-only). The Open/Enter/code lines + the wait are the CLI's own
  # output; unattended installs use the dual-mode credential path above.
  echo ""
  echo -e "  Sign in to approve this machine — open the link in your browser"
  echo -e "  (on this or any device) and enter the code:"
  echo ""
  _device_sign_in
  # shellcheck disable=SC2034  # consumed cross-file by install-cli.sh (setup_example_use_case)
  TB_CLI_SIGNED_IN=1

  # Namespace of a client installed here that the signed-in account owns, when
  # the pre-flight below finds one: this run reconnects it rather than naming a
  # new one.
  local _reuse_ns=""

  # ── One-client-per-machine pre-flight (#303) ─────────────────────────────
  # `client create` below mints a fresh client whenever the backend can't match
  # THIS cluster to a client in the signed-in account — e.g. a pre-anchor client
  # whose cluster_id is still null, or one owned by a DIFFERENT account. If a
  # client is already installed here and the signed-in account doesn't own it,
  # that mint registers a brand-new client that never installs (the Helm-step
  # guard then refuses) — an orphan left on the dashboard. Catch it BEFORE minting.
  #
  # Only fires when a local release exists AND we can positively confirm the
  # account does NOT own it. A fresh machine (no release), an account that DOES
  # own the local client (create cleanly adopts), or an inconclusive list read all
  # fall through to `client create`'s own idempotent adopt/conflict handling — so
  # this never regresses the same-account re-run/upgrade path. Guarded on the
  # shared probe being present (a stale bootstrap may not have sourced it).
  if declare -F detect_installed_client >/dev/null 2>&1; then
    detect_installed_client
    # Fail CLOSED when we couldn't enumerate what's here (helm/API failure): the
    # NS check below can't distinguish "no client" from "couldn't tell", so minting
    # now could strand a SECOND client (the exact orphan this pre-flight prevents).
    # Same signal the Helm-step one-client guard keys on.
    if [[ "${INSTALLED_CLIENT_UNKNOWN:-0}" == 1 ]]; then
      echo ""
      warn "Couldn't determine whether a tracebloc client is already installed here."
      hint "tracebloc runs one client per machine. Registering a new client now could strand"
      hint "a second one if an existing client just couldn't be seen — usually the cluster API"
      hint "is briefly unreachable. Check it and re-run:"
      hint "  kubectl cluster-info"
      hint "  helm list -A"
      echo ""
      error "Refusing to provision without verifying what's already on this machine."
    fi
    if [[ -n "$INSTALLED_CLIENT_NS" ]]; then
      local _own_rc=0
      _account_owns_namespace "$INSTALLED_CLIENT_NS" || _own_rc=$?
      # rc 1 = list read OK but the installed client's namespace is absent from the
      # account. That's only proof of a FOREIGN client for a slug namespace. A
      # client installed under the legacy fixed `tracebloc` namespace is listed on
      # the dashboard under its minted slug (§838), so `client list` won't show
      # `tracebloc` even for the account's OWN older client — a skew
      # install_client_helm reconciles by clientId, the reliable key `client list`
      # doesn't expose here. So refuse only for a non-legacy namespace; for
      # `tracebloc`, defer to `client create` (adopts if it's yours, 409s if truly
      # cross-account) and the Helm-step one-client guard, which key on clientId.
      if [[ "$_own_rc" -eq 1 && "$INSTALLED_CLIENT_NS" != "tracebloc" ]]; then
        echo ""
        warn "This machine already runs a tracebloc client (namespace '${INSTALLED_CLIENT_NS}') that isn't in the account you just signed in as."
        hint "tracebloc runs one client per machine. Provisioning now would register a"
        hint "second client and strand it (it could never install here). Pick one:"
        hint "  • Repair / update it     →  sign in as the account that owns it, or re-run with that client's credentials"
        hint "  • Switch to this account →  release and remove the current client first:"
        _release_client_hint "        "
        hint "      then re-run this installer"
        hint "  • Run both               →  install on a separate machine"
        echo ""
        error "Refusing to provision a second client on this machine. See the options above."
      elif [[ "$_own_rc" -eq 1 ]]; then
        log "installed client is in the legacy 'tracebloc' namespace (not listed by its slug); deferring ownership to client create + the Helm one-client guard, which key on clientId"
      elif [[ "$_own_rc" -eq 0 ]]; then
        # The signed-in account owns the client installed here, so `client create`
        # below adopts it and keeps its name: asking for a new one would only
        # suggest a second client is about to be made (backend#5365).
        _reuse_ns="$INSTALLED_CLIENT_NS"
      fi
    fi
  fi

  # Mint the client + derive the namespace. --credential-file writes the secret to
  # a 0600 file (never printed); we source it, hand it to Helm, then delete it (the
  # secret's durable home is the Helm/cluster secret — RFC §7.9).
  local cred_file="${HOST_DATA_DIR}/client-credential.env"
  # Register the path so install_cleanup removes it on ANY exit (error/signal)
  # between mint and the explicit removal below — the secret must never linger.
  _PROVISION_CRED_FILE="$cred_file"
  rm -f "$cred_file"
  # Name this client, then provision. `client create` would prompt for the name
  # itself, but we redirect its output to the log below (the credential must never
  # reach the terminal), so it can't — collect the name here and pass it explicitly.
  # Precedence: TRACEBLOC_CLIENT_NAME (unattended) > interactive prompt on /dev/tty
  # (works under `curl | bash`, whose stdin isn't the terminal) > fail closed.
  #
  # Location is NEVER prompted (RFC-0001 §6.4 target spec; cli#137). The CLI's
  # `client create` now treats --location as optional, so we auto-derive the carbon
  # zone from the system timezone below (silent, no network) and, when detection
  # yields nothing, provision with NO location rather than asking. A pinned
  # TRACEBLOC_CLIENT_LOCATION still overrides for unattended installs.
  local client_name="${TRACEBLOC_CLIENT_NAME:-}" client_location="${TRACEBLOC_CLIENT_LOCATION:-}"
  if [[ -z "$client_name" && -n "$_reuse_ns" ]]; then
    # Reusing the client installed here: no prompt. The name only satisfies the
    # required --name; an adopt keeps the registered one.
    client_name="$_reuse_ns"
    info "Reconnecting your secure environment '${_reuse_ns}' — it's already installed here."
  elif [[ -z "$client_name" ]]; then
    # Nothing installed here, but the CLI may still reuse a client: one already
    # registered for this cluster (its install was removed), or this machine's own
    # client from a cluster that was rebuilt. Ask it (`client create --plan`,
    # side-effect free) and ask the user for a name only before a real mint.
    local _plan _plan_action _plan_ns _plan_name
    _plan="$(_create_plan)"
    if [[ -n "$_plan" ]]; then
      # -s: a line with no tab is no plan line. Without it `cut -f3` prints the
      # whole line, so a bare `adopt` would be taken for the namespace.
      _plan_action="$(printf '%s' "$_plan" | cut -s -f1)"
      _plan_ns="$(printf '%s' "$_plan" | cut -s -f3)"
      _plan_name="$(printf '%s' "$_plan" | cut -s -f4-)"
      log "client create --plan: ${_plan_action} ns=${_plan_ns}"
      if [[ -n "$_plan_ns" ]]; then
        case "$_plan_action" in
          adopt)
            client_name="$_plan_ns"; _reuse_ns="$_plan_ns"
            info "Found your secure environment '${_plan_name:-$_plan_ns}' — it's already registered for this machine."
            ;;
          reconnect)
            client_name="$_plan_ns"; _reuse_ns="$_plan_ns"
            info "Found your secure environment '${_plan_name:-$_plan_ns}' — reconnecting it to this machine's new cluster."
            ;;
        esac
      fi
    fi
  fi
  # Track where the location came from so a rejected-zone hint can name the real
  # source ("env" = pinned via TRACEBLOC_CLIENT_LOCATION, "auto" = timezone-derived).
  local client_location_source="auto"
  if [[ -z "$client_name" ]] && _prompt_tty; then
    # Read the name from the terminal, RETRYING on an empty line instead of
    # accepting it. A stray newline queued in the tty during the ~minute
    # browser-approval wait above (type-ahead) would otherwise be read as an
    # empty name and abort the install at the "name is required" error below
    # (customer-reported 2026-07-09). A FAILED read (rc!=0 = EOF / no live input,
    # e.g. a non-PTY ssh or IDE terminal) can't be fixed by re-prompting, so stop
    # and let that actionable error fire. The prompt WRITE is guarded (|| true) so
    # a test without a real /dev/tty doesn't abort; reads use TRACEBLOC_TTY.
    local _name_try _name_read_ok
    for _name_try in 1 2 3; do
      printf '\n  Name your secure environment (shown on your tracebloc dashboard): ' >/dev/tty 2>/dev/null || true
      _name_read_ok=1; IFS= read -r client_name <"$TRACEBLOC_TTY" || _name_read_ok=0
      # Plain `read` (NOT `read -e`): setup_log_file has already redirected this
      # process's stdout+stderr through `exec > >(tee …) 2>&1`, and readline
      # (`read -e`) echoes typed characters to stderr — so under the tee pipe the
      # live echo is delayed/garbled on exactly this interactive path. Kernel-tty
      # echo (plain read) is immune to that redirection. The actual garble fix is
      # the strip below: arrow keys inject ESC[D/ESC[A byte sequences that would
      # otherwise slug-ify into a garbage name like "d-d-d-a-a-a" when passed to
      # `client create` (customer-reported 2026-07-20). Same helper the credential
      # path uses.
      client_name="$(_strip_paste_garbage "$client_name")"
      client_name="${client_name#"${client_name%%[![:space:]]*}"}"; client_name="${client_name%"${client_name##*[![:space:]]}"}"
      [[ -n "$client_name" ]] && break       # captured a name (incl. a no-newline partial)
      [[ "$_name_read_ok" == 0 ]] && break    # EOF / no interactive input — retrying won't help
    done
  fi
  # Trim surrounding whitespace from the (possibly typed) values FIRST, so a
  # whitespace-only answer (spaces then Enter) counts as "unset" for the silent
  # fallback below instead of slipping through as a non-empty, doomed location.
  client_name="${client_name#"${client_name%%[![:space:]]*}"}"; client_name="${client_name%"${client_name##*[![:space:]]}"}"
  client_location="${client_location#"${client_location%%[![:space:]]*}"}"; client_location="${client_location%"${client_location##*[![:space:]]}"}"
  # A value surviving the trim came from TRACEBLOC_CLIENT_LOCATION (the only source
  # read so far); anything set below is timezone-derived, so the default stands.
  [[ -n "$client_location" ]] && client_location_source="env"

  # No location from TRACEBLOC_CLIENT_LOCATION: derive the carbon zone from the
  # system timezone silently — never prompted, matching the target spec. The
  # detected code is already whitespace-free. If detection also comes up empty we
  # leave client_location unset and provision with NO --location (cli#137 makes it
  # optional); a rejected zone still surfaces via _report_create_failure below
  # rather than failing blind here.
  if [[ -z "$client_location" ]]; then
    client_location="$(_detect_location_zone)"; client_location="${client_location%% *}"
  fi

  [[ -n "$client_name" ]] || error "A name for this client is required to provision it. Re-run in a terminal to be prompted, or set TRACEBLOC_CLIENT_NAME (and optionally TRACEBLOC_CLIENT_LOCATION) for an unattended install."
  _machine_labels "$_reuse_ns" "${_plan_action:-}"
  # --name is required; pass --location only when we have one (the CLI defaults it
  # otherwise). Build as an array so values with spaces survive intact.
  local -a _create_args=(client create --yes --name "$client_name" --credential-file "$cred_file")
  # The credential-rejected repair (backend#5365): the client runs here, so a plain
  # create adopts it and keeps the credential tracebloc refuses. Ask for a new one.
  if [[ "${INSTALL_STATE_REASON:-}" == credential-rejected ]]; then
    # Capture, then match: piping into a grep that quits early sends the CLI a
    # SIGPIPE, which pipefail reads as "no --reissue" (the early-close lint).
    local _create_help; _create_help="$(tracebloc client create --help </dev/null 2>/dev/null)" || _create_help=""
    if [[ "$_create_help" == *--reissue* ]]; then
      _create_args+=(--reissue)
      # shellcheck disable=SC2034  # consumed cross-file by install-client-helm.sh
      TRACEBLOC_CREDENTIAL_REISSUED=1
    else
      # Stop before the create (client-dev#1846): without --reissue it adopts the
      # running client and hands back the credential tracebloc refuses, and the run
      # would end "installed" with the machine still offline.
      error "This tracebloc CLI can't issue a new credential to a running client yet — update it and re-run the installer."
    fi
  fi
  [[ -n "$client_location" ]] && _create_args+=(--location "$client_location")
  # umask 077 so the credential file lands 0600 even if a future CLI build
  # regresses on its explicit chmod — defense in depth (cli#104 already sets 0600).
  # Capture the create's output so we can surface the ACTUAL failure reason on the
  # terminal (not just "see the log"). On success it's appended to the log and the
  # credential stays in its 0600 file, never on stdout; on failure nothing was
  # minted, so the captured text is safe to show.
  # Prefer mktemp; if it's unavailable, fall back INSIDE the install dir (which we
  # own and just wrote the 0600 credential into) rather than a predictable
  # world-writable /tmp path — that path is a symlink-clobber target under sudo.
  local _create_out; _create_out="$(mktemp 2>/dev/null)" || _create_out="${HOST_DATA_DIR}/.client-create.$$.out"
  # Where this machine runs and what it is called (_machine_labels above), handed to
  # the create in its environment (a CLI that predates the variables ignores them).
  _registration_machine_facts
  if ! ( umask 077
         TRACEBLOC_MACHINE_KIND="$_TB_REG_MACHINE_KIND" TRACEBLOC_CLOUD_PROVIDER="$_TB_REG_CLOUD_PROVIDER" \
           TRACEBLOC_HOST_OS="$_TB_REG_HOST_OS" TRACEBLOC_MACHINE_NAME="$_TB_MACHINE_NAME" \
           TRACEBLOC_CLIENT_PROVIDER="$_TB_CLIENT_PROVIDER" tracebloc "${_create_args[@]}" ) >"$_create_out" 2>&1; then  # set-u-safe: seeded with the client create verb
    cat "$_create_out" >>"${LOG_FILE:-/dev/null}" 2>/dev/null || true
    rm -f "$cred_file"   # remove any partial the failed create may have written
    _report_create_failure "$_create_out" "$client_location" "$client_location_source"
    rm -f "$_create_out"
    error "Couldn't provision the client. Re-run to retry — full log: ${LOG_FILE:-the install log}."
  fi
  cat "$_create_out" >>"${LOG_FILE:-/dev/null}" 2>/dev/null || true
  _show_create_notices "$_create_out"
  # A reconnect (the CLI reissued the existing client's credential) is handed
  # over like a mint; remember it so the summary below doesn't say "Registered".
  local _reconnected=0
  grep -q "Reconnecting this machine's existing client" "$_create_out" 2>/dev/null && _reconnected=1
  rm -f "$_create_out"
  [[ -f "$cred_file" ]] || error "client create did not write the credential file ($cred_file)."

  _provision_take_credential "$cred_file" "$_reuse_ns" "$_reconnected"
}

# provision_read_stdin_credential -- the Windows installer's client run hands this
# core the credential its host CLI's `client create --credential-file` wrote, on
# stdin (TRACEBLOC_CREDENTIAL_STDIN=1): never on the command line, which Windows
# lists, and never across drvfs (client-dev#1810 section 5). main() calls this first
# thing, so the bootstrap's write is always read. Kept only in the distro's client
# run (refuse_wsl_run's rule): read to EOF into a 0600 file in a fresh 0700
# directory (tb_scratch_dir, reaped on every exit) on the distro's own disk, named
# in _PROVISION_CRED_FILE so install_cleanup deletes it on any exit, and handed to
# step d in TRACEBLOC_STDIN_CRED_FILE. Anywhere else stdin is never read: by hand in a
# terminal a read would wait for a Ctrl-D nobody knows to type, and under
# `curl | bash` stdin is the rest of the bootstrap script. refuse_wsl_run refuses
# TRACEBLOC_CREDENTIAL_STDIN there by name. Refuses nothing itself: the substrate
# line comes first, so what it found wrong (a terminal on stdin, a TMPDIR on a
# Windows drive or one it cannot place, an empty stdin) goes in
# TB_STDIN_CRED_REFUSAL for refuse_wsl_run to raise after it. Prints nothing.
provision_read_stdin_credential() {
  local tmp="${TMPDIR:-/tmp}" dir="" file rc=0
  TRACEBLOC_STDIN_CRED_FILE=""; TB_STDIN_CRED_REFUSAL=""
  if ! tb_in_wsl_distro || [[ "${TRACEBLOC_WSL_PHASE:-}" != "client" ]]; then
    return 0
  fi
  if _provision_stdin_is_terminal; then
    TB_STDIN_CRED_REFUSAL="TRACEBLOC_CREDENTIAL_STDIN=1, but stdin is a terminal: no credential was handed to this run. Re-run the installer from Windows."
    return 0
  fi
  _probe_windows_drive "$tmp" || rc=$?
  case "$rc" in
    1) ;;
    0) TB_STDIN_CRED_REFUSAL="TMPDIR=${tmp} is on a Windows drive (drvfs), and the credential handed to this run is only ever written to the distro's own disk. Unset TMPDIR in the distro, then re-run the installer from Windows." ;;
    *) TB_STDIN_CRED_REFUSAL="This run cannot read which filesystem holds TMPDIR=${tmp}, so it cannot tell whether the credential handed to it would land on a Windows drive (drvfs). Check that /proc/self/mounts is readable in the distro, then re-run the installer from Windows." ;;
  esac
  if [[ -n "$TB_STDIN_CRED_REFUSAL" ]] || ! tb_scratch_dir dir tracebloc-credential; then
    [[ -n "$TB_STDIN_CRED_REFUSAL" ]] || TB_STDIN_CRED_REFUSAL="This run couldn't make a private directory under ${tmp} for the credential handed to it. Check that ${tmp} is writable in the distro, then re-run the installer from Windows."
    # Drained, never kept: stdin is the Windows installer's pipe here (not a
    # terminal, checked above), so its write ends and the refusal is what it reads.
    cat >/dev/null 2>&1 || true
    return 0
  fi
  file="${dir}/client-credential.env"
  _PROVISION_CRED_FILE="$file"
  if ! ( umask 077; cat >"$file" ); then
    TB_STDIN_CRED_REFUSAL="This run couldn't read the credential handed to it on stdin. Re-run the installer from Windows."
    return 0
  fi
  if [[ ! -s "$file" ]]; then
    TB_STDIN_CRED_REFUSAL="TRACEBLOC_CREDENTIAL_STDIN=1, but stdin was empty: no credential was handed to this run. Re-run the installer from Windows."
    return 0
  fi
  TRACEBLOC_STDIN_CRED_FILE="$file"
}

# _provision_stdin_is_terminal -- stdin is a terminal, not the Windows installer's
# pipe. A function so a case can be a terminal without one.
_provision_stdin_is_terminal() { [[ -t 0 ]]; }

# The keys a credential file carries: what `tracebloc client create
# --credential-file` writes (cli-dev writeClientCredential: the id, the password and
# both namespace spellings on a mint; the id, the namespaces and
# TRACEBLOC_CLIENT_ADOPTED=1 on an adopt), and the id and password alone the Windows
# installer hands over. _provision_read_credential sets these and no other name.
TB_CRED_KEYS="TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD TRACEBLOC_NAMESPACE TB_NAMESPACE TRACEBLOC_CLIENT_ADOPTED"

# _provision_read_credential FILE -- FILE's credential, read as data, never run as
# shell: a password holding `$`, a quote or a backtick is taken as it is, and a line
# that is not a credential sets nothing. KEY=value lines, split at the first `=`, the
# value verbatim but for one trailing CR (a file saved on Windows); blank lines and
# `#` lines are skipped. Refused: a line with no `=`, a key outside TB_CRED_KEYS, a
# key given twice, no TRACEBLOC_CLIENT_ID, or an id with neither a password nor
# TRACEBLOC_CLIENT_ADOPTED=1. A refusal returns 1 with the reason in
# _PROVISION_CRED_WHY, which names lines and keys and never a value.
_provision_read_credential() {
  local line key k ok n=0 seen=" "
  _PROVISION_CRED_WHY=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == "#"* ]] && continue
    if [[ "$line" != *=* ]]; then _PROVISION_CRED_WHY="line ${n} is not KEY=value"; return 1; fi
    key="${line%%=*}"; ok=0
    for k in $TB_CRED_KEYS; do [[ "$key" == "$k" ]] && ok=1; done
    if [[ "$ok" -ne 1 ]]; then _PROVISION_CRED_WHY="line ${n} names a key a credential does not carry"; return 1; fi
    case "$seen" in *" ${key} "*) _PROVISION_CRED_WHY="${key} is given twice"; return 1 ;; esac
    seen="${seen}${key} "
    printf -v "$key" '%s' "${line#*=}"
  done <"$1"
  [[ -n "${TRACEBLOC_CLIENT_ID:-}" ]] || { _PROVISION_CRED_WHY="it names no TRACEBLOC_CLIENT_ID"; return 1; }
  if [[ "${TRACEBLOC_CLIENT_ADOPTED:-}" != 1 && -z "${TRACEBLOC_CLIENT_PASSWORD:-}" ]]; then
    _PROVISION_CRED_WHY="it names a client id with no TRACEBLOC_CLIENT_PASSWORD"; return 1
  fi
  return 0
}

# _provision_take_credential FILE [REUSE_NS] [RECONNECTED] -- the one tail every
# credential goes through: the file `client create --credential-file` wrote, on this
# machine (provision_client) or on the Windows host and handed over on stdin
# (provision_read_stdin_credential). Reads FILE (_provision_read_credential), deletes
# it, and hands the client to the Helm step: the adopt branch, a mint, or, for an id
# and a password with no namespace, a preset. REUSE_NS is the namespace the
# pre-create check found installed here (it was announced then); RECONNECTED is 1
# when the CLI reissued the existing client's credential.
_provision_take_credential() {
  local cred_file="$1" _reuse_ns="${2:-}" _reconnected="${3:-0}"
  # The secure-environment name set for this install (common.sh resolved
  # TRACEBLOC_NAMESPACE into TB_NAMESPACE), kept for a preset, which names none.
  local _set_ns="${TB_NAMESPACE:-}"
  # The credential file is the sole source of truth for what was provisioned.
  # Clear any pre-existing values from the environment first: the mint case does
  # NOT write TRACEBLOC_CLIENT_ADOPTED, so a stale ADOPTED=1 left in the env would
  # otherwise misroute a fresh mint into the adopt branch and drop the just-minted
  # credential. Same reasoning for id/password/namespace — only the file wins.
  # TRACEBLOC_NAMESPACE is cleared WITH TB_NAMESPACE: it is the canonical
  # spelling of the same name, so a value the operator set before the mint
  # would otherwise outrank the minted slug for any alias-first reader.
  unset TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD TB_NAMESPACE TRACEBLOC_NAMESPACE TRACEBLOC_CLIENT_ADOPTED
  local read_rc=0
  _provision_read_credential "$cred_file" || read_rc=1
  rm -f "$cred_file"
  unset _PROVISION_CRED_FILE
  if [[ "$read_rc" -ne 0 ]]; then
    unset TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD TB_NAMESPACE TRACEBLOC_NAMESPACE TRACEBLOC_CLIENT_ADOPTED
    if [[ -n "${TRACEBLOC_STDIN_CRED_FILE:-}" && "$cred_file" == "$TRACEBLOC_STDIN_CRED_FILE" ]]; then
      TB_EXIT_REFUSED=1
      error "The credential the Windows installer handed over isn't one this installer reads (${_PROVISION_CRED_WHY}), so this machine was not registered. Re-run the installer from Windows."
    fi
    error "The credential file 'tracebloc client create' wrote isn't one this installer reads (${_PROVISION_CRED_WHY}). Update the tracebloc CLI (curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh), then re-run the installer."
  fi
  # The CLI writes TB_NAMESPACE today; read the canonical first so a CLI that
  # writes TRACEBLOC_NAMESPACE is honoured without another installer change.
  if [[ -n "${TRACEBLOC_NAMESPACE:-}" ]]; then TB_NAMESPACE="$TRACEBLOC_NAMESPACE"; fi

  if [[ "${TRACEBLOC_CLIENT_ADOPTED:-}" == "1" ]]; then
    # Re-run on an already-registered cluster: no fresh credential was minted (the
    # existing one stands, write-only on the backend). Hand the adopted client id
    # (its UUID username) + namespace + the ADOPTED marker to install_client_helm,
    # which reconciles the existing release in place and heals a stale clientId to
    # this UUID — cli#125-era installs stored the numeric dashboard id, which can't
    # authenticate. Drop only the (absent) password: with no password, the partial
    # creds never reach the non-interactive install path, so the ADOPTED branch owns
    # this case. A rebuilt host with no local release still reconciles by discovery.
    # Name it by namespace (= the dashboard handle), not the client's UUID login.
    # Said once: a reuse found by the pre-flight was announced before the create.
    [[ -n "$_reuse_ns" ]] || info "Reconnecting your secure environment '${TB_NAMESPACE:-${TRACEBLOC_NAMESPACE:-?}}' — it's already registered with tracebloc."
    unset TRACEBLOC_CLIENT_PASSWORD
    export TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_ADOPTED
    tb_export_namespace
    return 0
  fi

  # Mint: hand the credential + the provisioned namespace to the Helm step. The
  # namespace MUST be the created client's slug (Q2: it equals the heartbeat-
  # reported namespace), so the minted value wins over any TB_NAMESPACE default.
  export TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD
  # An id and a password with no namespace (what the Windows installer hands over) is
  # a preset, as credentials supplied in the environment are (_provisioning_preset):
  # install_client_helm picks the namespace, so there is no slug to announce. As for
  # that preset, it picks the name set for this install, else tracebloc: the clear
  # above was for a minted slug to win, and a preset has none. Without this, a name
  # set on Windows, which reaches the client run on its line, was dropped here.
  if [[ -z "${TB_NAMESPACE:-}" ]]; then
    if [[ -n "$_set_ns" ]]; then
      TB_NAMESPACE="$_set_ns"
      tb_export_namespace
    fi
    log "Credential handed to the install (not shown); the Helm step picks the namespace."
    return 0
  fi
  tb_export_namespace
  # The registered identity is the minted slug (= TB_NAMESPACE = the dashboard
  # name), e.g. "lukas-01" — not the raw typed name (which may be de-duplicated).
  [[ "$_reconnected" == 1 ]] || success "Registered as \"${TB_NAMESPACE}\""
  log "Provisioned — credential handed to the install (not shown)."
}
