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

provision_client() {
  step 3 5 "Sign in and provision this client"

  # "Minted this run" marker for install_client_helm's Step 5 — cleared up front so
  # a stale value inherited from the environment can't make Step 5 skip credential
  # verification. Only the mint path below sets it.
  unset TRACEBLOC_CLIENT_MINTED

  if _provisioning_preset; then
    info "Using the credentials you supplied — skipping browser sign-in."
    # Still install the CLI (non-fatal) so the operator has it for `data ingest`.
    install_tracebloc_cli
    return 0
  fi

  # Browser-auth path. The CLI is REQUIRED here (it mints the credential), so the
  # install is effectively FATAL — unlike the old post-Helm, non-fatal Step 5.
  install_tracebloc_cli
  # The CLI installer may drop the binary in ~/.local/bin (not yet on this
  # process's PATH); make it resolvable so the login/create calls below work.
  export PATH="${HOME}/.local/bin:${PATH}"
  has tracebloc || error "The tracebloc CLI is required to provision this client but isn't available after install. Install it (curl -fsSL ${TRACEBLOC_CLI_INSTALL_URL} | sh), open a new shell, and re-run."

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

  # Sign in (device flow — approve in a browser). Unattended installs use the
  # dual-mode credential path above.
  info "Sign in to tracebloc — approve this machine in your browser when prompted…"
  tracebloc login || error "Sign-in didn't complete — re-run the installer to try again."

  # Mint the client + derive the namespace. --credential-file writes the secret to
  # a 0600 file (never printed); we source it, hand it to Helm, then delete it (the
  # secret's durable home is the Helm/cluster secret — RFC §7.9).
  local cred_file="${HOST_DATA_DIR}/client-credential.env"
  # Register the path so install_cleanup removes it on ANY exit (error/signal)
  # between mint and the explicit removal below — the secret must never linger.
  _PROVISION_CRED_FILE="$cred_file"
  rm -f "$cred_file"
  # Name + location for this machine (RFC-0001 §6.4: "name this machine + confirm
  # its location"). `client create` would prompt for these, but we redirect its
  # output to the log below (the credential must never reach the terminal), so it
  # can't — and it hard-requires --name when it can't prompt. Collect them here and
  # pass explicitly. Precedence: env override (unattended) > interactive prompt on
  # /dev/tty (works under `curl | bash`, whose stdin isn't the terminal) > fail closed.
  local client_name="${TRACEBLOC_CLIENT_NAME:-}" client_location="${TRACEBLOC_CLIENT_LOCATION:-}"
  if [[ -z "$client_name" ]] && _prompt_tty; then
    printf '\n  Name this machine (shown on your tracebloc dashboard): ' >/dev/tty
    IFS= read -r client_name </dev/tty || true
    if [[ -z "$client_location" ]]; then
      printf '  Location zone for carbon reporting [e.g. DE, optional]: ' >/dev/tty
      IFS= read -r client_location </dev/tty || true
    fi
  fi
  # Trim surrounding whitespace from the (possibly typed) values.
  client_name="${client_name#"${client_name%%[![:space:]]*}"}"; client_name="${client_name%"${client_name##*[![:space:]]}"}"
  client_location="${client_location#"${client_location%%[![:space:]]*}"}"; client_location="${client_location%"${client_location##*[![:space:]]}"}"
  [[ -n "$client_name" ]] || error "A name for this machine is required to provision it. Re-run in a terminal to be prompted, or set TRACEBLOC_CLIENT_NAME (and optionally TRACEBLOC_CLIENT_LOCATION) for an unattended install."
  # --name is required; pass --location only when we have one (the CLI defaults it
  # otherwise). Build as an array so values with spaces survive intact.
  local -a _create_args=(client create --yes --name "$client_name" --credential-file "$cred_file")
  [[ -n "$client_location" ]] && _create_args+=(--location "$client_location")
  # umask 077 so the credential file lands 0600 even if a future CLI build
  # regresses on its explicit chmod — defense in depth (cli#104 already sets 0600).
  if ! ( umask 077; tracebloc "${_create_args[@]}" ) >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -f "$cred_file"   # remove any partial the failed create may have written
    error "Provisioning the client failed — see ${LOG_FILE:-the install log}. Re-run to retry."
  fi
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
    # existing one stands, write-only on the backend). Drop the partial creds and
    # let install_client_helm reconcile the existing release from the local
    # values.yaml (helm upgrade). A rebuilt host with no local values falls through
    # to its existing credential prompt/error — the R7 orphan-resume is a follow-up.
    info "This cluster is already registered (client ${TRACEBLOC_CLIENT_ID:-?}) — reconciling the existing install."
    unset TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD
    export TB_NAMESPACE
    return 0
  fi

  # Mint: hand the credential + the provisioned namespace to the Helm step. The
  # namespace MUST be the created client's slug (Q2: it equals the heartbeat-
  # reported namespace), so the minted value wins over any TB_NAMESPACE default.
  # MINTED=1 tells install_client_helm's Step 5 this credential was just created by
  # `client create` (valid by construction) and the client is "set to enroll" — so
  # Step 5 trusts the mint and skips the pre-verify that would otherwise 400 on the
  # not-yet-enrolled client. Adopt/dual-mode paths don't set it and still verify.
  export TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD TB_NAMESPACE
  export TRACEBLOC_CLIENT_MINTED=1
  info "Provisioned — credential handed to the install (not shown)."
}
