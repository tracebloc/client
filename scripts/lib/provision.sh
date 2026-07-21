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

# TB_TTY: where interactive prompts READ from. Under `curl | bash` stdin is the
# piped installer, not the keyboard, so reads must come from the controlling
# terminal. Overridable so tests can feed canned input on stdin (TB_TTY=/dev/stdin).
: "${TB_TTY:=/dev/tty}"

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
  local out="$1" loc="$2" src="${3:-auto}" errline l
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
  errline="$(grep -aE 'Error:|HTTP [0-9][0-9][0-9]|refused|timed? ?out|unauthorized|forbidden|denied' "$out" 2>/dev/null | head -4)"
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

provision_client() {
  # No step header here — main() prints "d) Registering this machine". The
  # tracebloc CLI was installed in step b (Install what tracebloc needs); this
  # step signs in and mints the machine credential using it.

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
  # Give the interactive device-flow sign-in the user's REAL terminal. This runs
  # after setup_log_file (`exec > >(tee …) 2>&1`), so the shell's stdout/stderr are
  # a pipe and — under `curl … | bash` — stdin is the install pipe; a bare
  # `tracebloc login` would then have no tty on any stream and can misrender or
  # fail (same class assess.sh's hand-off handles). Redirect all three to /dev/tty
  # when openable, else </dev/null (unattended reaches the dual-mode credential
  # path above, not here).
  if { : </dev/tty; } 2>/dev/null; then
    tracebloc login </dev/tty >/dev/tty 2>/dev/tty || error "Sign-in didn't complete — re-run the installer to try again."
  else
    tracebloc login </dev/null || error "Sign-in didn't complete — re-run the installer to try again."
  fi

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
        hint "  • Switch to this account →  remove the current client first:"
        hint "        k3d cluster delete ${CLUSTER_NAME:-tracebloc}   (wipes this client + its local data)"
        hint "      then re-run this installer"
        hint "  • Run both               →  install on a separate machine"
        echo ""
        error "Refusing to provision a second client on this machine. See the options above."
      elif [[ "$_own_rc" -eq 1 ]]; then
        log "installed client is in the legacy 'tracebloc' namespace (not listed by its slug); deferring ownership to client create + the Helm one-client guard, which key on clientId"
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
  # Name this machine, then provision. `client create` would prompt for the name
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
    # a test without a real /dev/tty doesn't abort; reads use TB_TTY.
    local _name_try _name_read_ok
    for _name_try in 1 2 3; do
      printf '\n  Name your secure environment (shown on your tracebloc dashboard): ' >/dev/tty 2>/dev/null || true
      _name_read_ok=1; IFS= read -e -r client_name <"$TB_TTY" || _name_read_ok=0
      # `read -e` gives readline line-editing so arrow keys move the cursor
      # instead of injecting ESC[D/ESC[A bytes; belt-and-suspenders, strip any
      # escape / paste-mode sequences that still slip in (same helper the
      # credential path uses) — otherwise they slug-ify into a garbage name like
      # "d-d-d-a-a-a" when passed to `client create` (customer-reported 2026-07-20).
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
  # --name is required; pass --location only when we have one (the CLI defaults it
  # otherwise). Build as an array so values with spaces survive intact.
  local -a _create_args=(client create --yes --name "$client_name" --credential-file "$cred_file")
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
  if ! ( umask 077; tracebloc "${_create_args[@]}" ) >"$_create_out" 2>&1; then
    cat "$_create_out" >>"${LOG_FILE:-/dev/null}" 2>/dev/null || true
    rm -f "$cred_file"   # remove any partial the failed create may have written
    _report_create_failure "$_create_out" "$client_location" "$client_location_source"
    rm -f "$_create_out"
    error "Couldn't provision the client. Re-run to retry — full log: ${LOG_FILE:-the install log}."
  fi
  cat "$_create_out" >>"${LOG_FILE:-/dev/null}" 2>/dev/null || true
  rm -f "$_create_out"
  [[ -f "$cred_file" ]] || error "client create did not write the credential file ($cred_file)."

  # The credential file is the sole source of truth for what was provisioned.
  # Clear any pre-existing values from the environment first: the mint case does
  # NOT write TRACEBLOC_CLIENT_ADOPTED, so a stale ADOPTED=1 left in the env would
  # otherwise misroute a fresh mint into the adopt branch and drop the just-minted
  # credential. Same reasoning for id/password/namespace — only the file wins.
  unset TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD TB_NAMESPACE TRACEBLOC_CLIENT_ADOPTED
  # shellcheck disable=SC1090
  source "$cred_file"
  rm -f "$cred_file"
  unset _PROVISION_CRED_FILE

  if [[ "${TRACEBLOC_CLIENT_ADOPTED:-}" == "1" ]]; then
    # Re-run on an already-registered cluster: no fresh credential was minted (the
    # existing one stands, write-only on the backend). Hand the adopted client id
    # (its UUID username) + namespace + the ADOPTED marker to install_client_helm,
    # which reconciles the existing release in place and heals a stale clientId to
    # this UUID — cli#125-era installs stored the numeric dashboard id, which can't
    # authenticate. Drop only the (absent) password: with no password, the partial
    # creds never reach the non-interactive install path, so the ADOPTED branch owns
    # this case. A rebuilt host with no local release still reconciles by discovery.
    info "This cluster is already registered (client ${TRACEBLOC_CLIENT_ID:-?}) — reconciling the existing install."
    unset TRACEBLOC_CLIENT_PASSWORD
    export TRACEBLOC_CLIENT_ID TB_NAMESPACE TRACEBLOC_CLIENT_ADOPTED
    return 0
  fi

  # Mint: hand the credential + the provisioned namespace to the Helm step. The
  # namespace MUST be the created client's slug (Q2: it equals the heartbeat-
  # reported namespace), so the minted value wins over any TB_NAMESPACE default.
  export TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD TB_NAMESPACE
  # The registered identity is the minted slug (= TB_NAMESPACE = the dashboard
  # name), e.g. "lukas-01" — not the raw typed name (which may be de-duplicated).
  success "Registered as \"${TB_NAMESPACE}\""
  log "Provisioned — credential handed to the install (not shown)."
}
