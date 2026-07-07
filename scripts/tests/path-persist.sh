#!/usr/bin/env bash
# =============================================================================
#  path-persist.sh — fresh-shell PATH-persistence guard for the tracebloc CLI
# -----------------------------------------------------------------------------
#  Runs INSIDE a plain distro container. Installs the tracebloc CLI via the
#  cli repo's own install.sh, then — for every shell present among bash/zsh/fish
#  — spawns a BRAND-NEW login shell AND a BRAND-NEW non-login shell and asserts:
#
#      command -v tracebloc      resolves
#      tracebloc version         runs (exit 0)
#
#  Why this is the crux (and why no existing job catches it):
#    distro-prereqs.sh and e2e-cluster.sh both run their assertions in the SAME
#    shell process that ran the installer, so a CLI that only edits the *current*
#    PATH (or writes to the wrong rc file) still looks green to them. The real
#    customer opens a NEW terminal and types the documented next command. A fresh
#    NON-LOGIN bash sources ~/.bashrc — NOT ~/.profile / ~/.bash_profile — so an
#    installer that persists PATH only to ~/.profile passes "login" but FAILS
#    "non-login". That asymmetry is exactly the class this script exists to lock
#    down (it goes red on the pre-fix installer and green on the fixed one).
#
#  No cluster, no Docker, no credentials — pure install.sh behaviour. Cheap and
#  wide, so CI fans it out across the distro matrix (one container per distro;
#  this script iterates shells × modes inside the container).
#
#  Configuration (env):
#    TRACEBLOC_CLI_REF   How to obtain cli/install.sh. Either:
#                          • a URL (https://…/install.sh)  → curl'd, or
#                          • a path to a local install.sh   → run directly.
#                        The local-path form lets the cli repo point this guard
#                        at the install.sh of the PR under test (cross-repo
#                        pre-merge gate). Default: see TODO below.
#    TRACEBLOC_CLI_VERSION  Optional. Passed to install.sh as `--version <tag>`
#                        (handy to pin a tag when testing a URL installer).
#
#  Usage (inside a container, as root):
#    bash scripts/tests/path-persist.sh
#  Typically driven by CI:
#    docker run --rm -v "$PWD:/src:ro" -w /src <distro-image> \
#      bash scripts/tests/path-persist.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

# shellcheck source=/dev/null
source "$LIB/common.sh"   # colours, has(), info/success/warn/error helpers

# common.sh sets umask 077; a 077 binary under /usr/local/bin is still
# owner-executable, but relax to 022 so the install + any rc files it writes
# look like a real host (the installer itself relaxes to 022 around tool installs).
umask 022

# ── Where to get cli/install.sh ──────────────────────────────────────────────
# Default to the public release installer. cli#61's PATH-persist fix shipped in
# cli v0.3.1 and is in every release since (verified: the served install.sh
# persists PREFIX to ~/.bashrc / ~/.zshrc / fish config), so `releases/latest`
# now exercises the FIXED installer — this guard stays green on a good release
# and would go red if a future release regressed the PATH class. A cli-side
# caller overrides TRACEBLOC_CLI_REF with a local path to a PR's own install.sh
# for pre-merge cross-repo coverage (see cli install-path-persist.yml).
DEFAULT_CLI_REF="https://github.com/tracebloc/cli/releases/latest/download/install.sh"
CLI_REF="${TRACEBLOC_CLI_REF:-$DEFAULT_CLI_REF}"
CLI_VERSION="${TRACEBLOC_CLI_VERSION:-}"

# ── Make the container resemble a real host ──────────────────────────────────
# A customer reached install.sh via `curl | sh`, so curl always exists. Minimal
# base images may ship neither curl nor a shell beyond /bin/sh — install what we
# need so the run mirrors a real machine. We are root in the container.
_pm_install() { # install one or more packages with whatever PM exists; best-effort
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq "$@"
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "$@"
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q "$@"
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive --quiet install "$@"
  elif command -v apk     >/dev/null 2>&1; then apk add --no-cache "$@" >/dev/null
  elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm "$@" >/dev/null
  fi
}

# curl + ca-certificates are needed to fetch install.sh (and for install.sh to
# fetch the binary). coreutils gives sha256sum on minimal images (Alpine/SUSE).
command -v curl >/dev/null 2>&1 || _pm_install curl
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || _pm_install coreutils
# ca-certificates is name-stable across apt/dnf/zypper/apk; harmless if present.
_pm_install ca-certificates >/dev/null 2>&1 || true

# Install the extra shells we want to assert against, when their package exists
# for this distro. bash is assumed present (we're running under it). zsh + fish
# are best-effort: a distro without a fish package simply skips that row.
has zsh  || _pm_install zsh  >/dev/null 2>&1 || true
has fish || _pm_install fish >/dev/null 2>&1 || true

# ── Context banner ───────────────────────────────────────────────────────────
PRETTY="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" )"
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  path-persist (fresh-shell CLI guard)"
echo "  distro : ${PRETTY}"
echo "  arch   : $(uname -m)"
echo "  cli ref: ${CLI_REF}"
echo "═══════════════════════════════════════════════════════════════════════"

# ── Run cli/install.sh ───────────────────────────────────────────────────────
# We deliberately do NOT use `set -e` here: install.sh runs under its own
# `set -eu`, and we want to capture its exit status explicitly so a failed
# install reports as a clean FAIL line rather than aborting the banner/summary.
echo ""
echo "── installing the tracebloc CLI via cli/install.sh ─────────────────────"

install_args=()
[[ -n "$CLI_VERSION" ]] && install_args+=(--version "$CLI_VERSION")

install_rc=0
case "$CLI_REF" in
  http://*|https://*)
    # Download to a temp file then run, mirroring how the client installer
    # invokes the CLI installer (download → run), rather than `curl | sh`
    # (which hides curl's exit code behind sh's under pipefail).
    installer="$(mktemp)"
    if curl -fsSL "$CLI_REF" -o "$installer"; then
      sh "$installer" "${install_args[@]}" || install_rc=$?
    else
      echo "  ✖ could not download install.sh from ${CLI_REF}"
      install_rc=1
    fi
    rm -f "$installer"
    ;;
  *)
    # Treat as a local path (the cross-repo caller mounts the PR's install.sh).
    if [[ -f "$CLI_REF" ]]; then
      sh "$CLI_REF" "${install_args[@]}" || install_rc=$?
    else
      echo "  ✖ TRACEBLOC_CLI_REF is neither a URL nor an existing file: ${CLI_REF}"
      install_rc=1
    fi
    ;;
esac

if [[ $install_rc -ne 0 ]]; then
  echo ""
  echo "RESULT: FAIL — cli/install.sh exited ${install_rc} on ${PRETTY} (install itself failed)"
  exit 1
fi
success "install.sh completed (exit 0)"

# Sanity: the installer may have placed the binary in ~/.local/bin (the fallback
# when /usr/local/bin isn't writable). That's a legitimate install — the WHOLE
# point of this test is that the installer must make it reachable from a fresh
# shell regardless of where it landed. We do NOT add anything to PATH ourselves:
# discovering it from a pristine shell is the assertion.

# ── The fresh-shell assertion (the mechanism) ────────────────────────────────
# For one shell + mode, spawn a brand-new shell of that kind and check that BOTH
# `command -v tracebloc` resolves AND `tracebloc version` runs. Returns 0/1 and
# prints a single PASS/FAIL cell line. Crucially, each invocation is a fresh
# process: it reads only the rc files that shell+mode actually reads on startup,
# so it faithfully reproduces "customer opens a new terminal".
assert_cell() {
  local sh="$1" mode="$2"
  local found="" ver_rc=0

  case "$sh:$mode" in
    bash:login)    found="$(bash -lc 'command -v tracebloc' 2>/dev/null)"; bash -lc 'tracebloc version >/dev/null 2>&1' || ver_rc=$? ;;
    bash:nonlogin) found="$(bash  -c 'command -v tracebloc' 2>/dev/null)"; bash  -c 'tracebloc version >/dev/null 2>&1' || ver_rc=$? ;;
    zsh:login)     found="$(zsh  -lc 'command -v tracebloc' 2>/dev/null)"; zsh  -lc 'tracebloc version >/dev/null 2>&1' || ver_rc=$? ;;
    zsh:nonlogin)  found="$(zsh   -c 'command -v tracebloc' 2>/dev/null)"; zsh   -c 'tracebloc version >/dev/null 2>&1' || ver_rc=$? ;;
    # fish reads ~/.config/fish/config.fish for BOTH login and non-login
    # interactive shells, but a fresh non-interactive `fish -c` still sources it,
    # so the login/non-login split is meaningful for parity with bash/zsh. fish's
    # `command -v` and `command -s` both work; use -v for portability.
    fish:login)    found="$(fish -lc 'command -v tracebloc' 2>/dev/null)"; fish -lc 'tracebloc version >/dev/null 2>&1' || ver_rc=$? ;;
    fish:nonlogin) found="$(fish  -c 'command -v tracebloc' 2>/dev/null)"; fish  -c 'tracebloc version >/dev/null 2>&1' || ver_rc=$? ;;
    *) echo "  ✖ ${sh} (${mode}): unknown shell/mode"; return 1 ;;
  esac

  if [[ -z "$found" ]]; then
    printf '  ✖ %-5s %-9s tracebloc NOT on PATH in a fresh shell\n' "$sh" "($mode)"
    return 1
  fi
  if [[ $ver_rc -ne 0 ]]; then
    printf '  ✖ %-5s %-9s found at %s but `tracebloc version` exited %s\n' "$sh" "($mode)" "$found" "$ver_rc"
    return 1
  fi
  printf '  ✔ %-5s %-9s %s\n' "$sh" "($mode)" "$found"
  return 0
}

echo ""
echo "── fresh-shell resolution (login + non-login) ──────────────────────────"

fail=0
tested=0
for sh in bash zsh fish; do
  if ! has "$sh"; then
    printf '  · %-5s %-9s skipped (shell not installed on %s)\n' "$sh" "(both)" "${PRETTY}"
    continue
  fi
  for mode in login nonlogin; do
    tested=$((tested + 1))
    assert_cell "$sh" "$mode" || fail=1
  done
done
echo "───────────────────────────────────────────────────────────────────────"

if [[ $tested -eq 0 ]]; then
  # bash is always present (we run under it), so this should never happen; guard
  # anyway so a pathological image can't make the job pass by testing nothing.
  echo "RESULT: FAIL — no shells were available to test on ${PRETTY}"
  exit 1
fi

if [[ $fail -ne 0 ]]; then
  echo "RESULT: FAIL — tracebloc was not reachable from a fresh shell on ${PRETTY}"
  echo "        (the install put the binary somewhere a new terminal doesn't see —"
  echo "         this is the cli#61 PATH-persistence class.)"
  exit 1
fi
echo "RESULT: PASS — tracebloc resolves + runs from every fresh shell on ${PRETTY}"
