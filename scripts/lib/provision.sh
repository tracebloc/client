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

provision_client() {
  step 3 5 "Sign in and provision this client"

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
  if ! tracebloc client create --yes --credential-file "$cred_file" >>"${LOG_FILE:-/dev/null}" 2>&1; then
    rm -f "$cred_file"   # remove any partial the failed create may have written
    error "Provisioning the client failed — see ${LOG_FILE:-the install log}. Re-run to retry."
  fi
  [[ -f "$cred_file" ]] || error "client create did not write the credential file ($cred_file)."

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
  export TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD TB_NAMESPACE
  info "Provisioned — credential handed to the install (not shown)."
}
