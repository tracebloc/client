#!/usr/bin/env bash
# =============================================================================
#  path-persist.sh — fresh-shell PATH-persistence guard for the tracebloc CLI
# -----------------------------------------------------------------------------
#  Runs INSIDE a plain distro container. Installs the tracebloc CLI via the
#  cli repo's own install.sh into a USER-LOCAL, OFF-PATH prefix, then — for each
#  shell present among bash/zsh/fish — opens a BRAND-NEW INTERACTIVE shell (the
#  kind a customer gets when they open a new terminal) and asserts:
#
#      tracebloc      resolves on PATH
#      tracebloc version   runs (exit 0)
#
#  Why this is the crux (and why no existing job catches it):
#    distro-prereqs.sh and e2e-cluster.sh both run their assertions in the SAME
#    shell process that ran the installer, so a CLI that only edits the *current*
#    PATH (or writes to the wrong rc file) still looks green to them. The real
#    customer opens a NEW terminal and types the documented next command.
#
#  Two things are load-bearing for this to actually produce a red/green signal
#  (both were missing in the first cut of this test — see client#310):
#
#    1. OFF-PATH PREFIX. install.sh only PERSISTS a PATH entry when the binary
#       lands somewhere that isn't already on PATH. As root it defaults to
#       /usr/local/bin, which is on every PATH — so no rc is ever written and
#       every shell resolves it trivially, even on a BROKEN installer. We pin
#       INSTALL_PREFIX to ~/.local/bin (a $HOME dir the installer always
#       persists, and which is not on any supported distro's default root PATH),
#       so a fresh shell can ONLY find the binary if the installer persisted it.
#
#    2. INTERACTIVE, PER-SHELL. install.sh persists to a SINGLE rc file chosen
#       from $SHELL (zsh→~/.zshrc, Linux bash→~/.bashrc, fish→config.fish). So we
#       run the installer once per shell with SHELL=<that shell>, then assert a
#       fresh INTERACTIVE shell of that kind — the one that reads that rc. A
#       non-interactive `bash -c` reads NO rc, and a *login* bash reads
#       ~/.profile (NOT the ~/.bashrc the installer writes on Linux); both
#       mis-model "open a new terminal", which on Linux is interactive non-login.
#
#  No cluster, no Docker, no credentials — pure install.sh behaviour. Cheap and
#  wide, so CI fans it out across the distro matrix (one container per distro;
#  this script iterates shells inside the container).
#
#  Configuration (env):
#    TRACEBLOC_CLI_REF   How to obtain cli/install.sh. Either:
#                          • a URL (https://…/install.sh)  → curl'd, or
#                          • a path to a local install.sh   → run directly.
#                        The local-path form lets the cli repo point this guard
#                        at the install.sh of the PR under test (cross-repo
#                        pre-merge gate). Default: see DEFAULT_CLI_REF below.
#    TRACEBLOC_CLI_VERSION  Optional. Passed to install.sh as `--version <tag>`.
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

# common.sh sets umask 077; a 077 binary under the prefix is still
# owner-executable, but relax to 022 so the install + any rc files it writes
# look like a real host (the installer itself relaxes to 022 around tool installs).
umask 022

# ── Where to get cli/install.sh ──────────────────────────────────────────────
# Default to the public release installer. cli#61's PATH-persist fix shipped in
# cli v0.3.1 and is in every release since (the served install.sh persists PREFIX
# to ~/.bashrc / ~/.zshrc / fish config), so `releases/latest` exercises the
# FIXED installer — this guard stays green on a good release and would go red if
# a future release regressed the PATH class. A cli-side caller overrides
# TRACEBLOC_CLI_REF with a local path to a PR's own install.sh for pre-merge
# cross-repo coverage (see cli install-path-persist.yml).
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

# ── Force a user-local, OFF-PATH prefix so persistence is actually exercised ──
# See the header (point 1): without this the test would pass on a broken
# installer. ~/.local/bin is a $HOME dir the installer ALWAYS persists.
export INSTALL_PREFIX="$HOME/.local/bin"

# ── Context banner ───────────────────────────────────────────────────────────
PRETTY="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" )"
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  path-persist (fresh-shell CLI guard)"
echo "  distro : ${PRETTY}"
echo "  arch   : $(uname -m)"
echo "  cli ref: ${CLI_REF}"
echo "  prefix : ${INSTALL_PREFIX} (off the default PATH — persistence required)"
echo "═══════════════════════════════════════════════════════════════════════"

# Precondition: the prefix must NOT already be on this image's PATH, or a fresh
# shell could resolve the binary WITHOUT any rc persistence and a green result
# would prove nothing (the vacuous-pass trap client#310 called out). Bail loudly.
case ":${PATH}:" in
  *":$INSTALL_PREFIX:"*)
    echo "RESULT: FAIL — $INSTALL_PREFIX is already on PATH in this image; the test can't attribute a pass to rc persistence."
    exit 1 ;;
esac

# ── Resolve install.sh to a local file ONCE ──────────────────────────────────
# install.sh re-fetches the binary per invocation, but we needn't re-download the
# SCRIPT for every shell.
INSTALLER=""
IS_TEMP_INSTALLER=0
case "$CLI_REF" in
  http://*|https://*)
    INSTALLER="$(mktemp)"; IS_TEMP_INSTALLER=1
    if ! curl -fsSL "$CLI_REF" -o "$INSTALLER"; then
      echo "RESULT: FAIL — could not download install.sh from ${CLI_REF}"; exit 1
    fi ;;
  *)
    if [[ ! -f "$CLI_REF" ]]; then
      echo "RESULT: FAIL — TRACEBLOC_CLI_REF is neither a URL nor an existing file: ${CLI_REF}"; exit 1
    fi
    INSTALLER="$CLI_REF" ;;
esac
cleanup() { [[ "$IS_TEMP_INSTALLER" == 1 && -n "$INSTALLER" ]] && rm -f "$INSTALLER"; }
trap cleanup EXIT

install_args=()
[[ -n "$CLI_VERSION" ]] && install_args+=(--version "$CLI_VERSION")

# ── Per-shell mechanics ──────────────────────────────────────────────────────
# Run the installer with SHELL pointing at the target shell so it persists to
# THAT shell's rc (see header point 2), capturing its exit status explicitly (no
# `set -e` here — install.sh runs under its own `set -eu`).
install_for_shell() { # $1=shell name; sets $install_rc
  install_rc=0
  SHELL="$(command -v "$1")" sh "$INSTALLER" "${install_args[@]}" || install_rc=$?
}

# A brand-new INTERACTIVE shell reads the user rc the installer wrote. `</dev/null`
# stops it blocking on stdin; stderr is dropped (an interactive shell without a
# tty emits harmless "no job control" notices).
resolves_interactive() { # $1=shell
  case "$1" in
    bash) bash -ic 'command -v tracebloc >/dev/null 2>&1' </dev/null >/dev/null 2>&1 ;;
    zsh)  zsh  -ic 'command -v tracebloc >/dev/null 2>&1' </dev/null >/dev/null 2>&1 ;;
    fish) fish -ic 'type -q tracebloc'                     </dev/null >/dev/null 2>&1 ;;
  esac
}
version_interactive() { # $1=shell
  case "$1" in
    bash) bash -ic 'tracebloc version >/dev/null 2>&1' </dev/null >/dev/null 2>&1 ;;
    zsh)  zsh  -ic 'tracebloc version >/dev/null 2>&1' </dev/null >/dev/null 2>&1 ;;
    fish) fish -ic 'tracebloc version >/dev/null 2>&1' </dev/null >/dev/null 2>&1 ;;
  esac
}
# A brand-new NON-INTERACTIVE shell reads NO user rc, so it must NOT resolve the
# binary (which lives only in the off-PATH prefix). If it DOES, the prefix leaked
# onto the base PATH and the positive assertion would be meaningless — so this is
# a per-shell negative control. (Skipped for fish: `fish_add_path` writes a
# universal variable and `fish -c` still sources config.fish, so a fresh
# non-interactive fish legitimately resolves it; the global precondition above
# covers fish.)
resolves_noninteractive() { # $1=shell
  case "$1" in
    bash) bash -c 'command -v tracebloc >/dev/null 2>&1' </dev/null >/dev/null 2>&1 ;;
    zsh)  zsh  -c 'command -v tracebloc >/dev/null 2>&1' </dev/null >/dev/null 2>&1 ;;
  esac
}

# ── Install-per-shell → fresh-interactive-shell assertion ────────────────────
echo ""
echo "── install (SHELL=<shell>) → fresh INTERACTIVE shell resolves + runs ────"

fail=0
tested=0
for sh in bash zsh fish; do
  if ! has "$sh"; then
    printf '  · %-5s skipped (shell not installed on %s)\n' "$sh" "${PRETTY}"
    continue
  fi
  tested=$((tested + 1))

  install_for_shell "$sh"
  if [[ $install_rc -ne 0 ]]; then
    printf '  ✖ %-5s install.sh (SHELL=%s) exited %s\n' "$sh" "$sh" "$install_rc"
    fail=1; continue
  fi

  # Negative control (bash/zsh): a fresh non-interactive shell must NOT find it.
  if [[ "$sh" != fish ]] && resolves_noninteractive "$sh"; then
    printf '  ✖ %-5s %s is reachable from a fresh NON-interactive shell — prefix leaked onto the base PATH; a pass would not prove persistence\n' "$sh" "tracebloc"
    fail=1; continue
  fi

  # Positive: a fresh INTERACTIVE shell (reads the persisted rc) resolves + runs.
  if ! resolves_interactive "$sh"; then
    printf '  ✖ %-5s tracebloc NOT on PATH in a fresh interactive shell (installer did not persist to its rc)\n' "$sh"
    fail=1; continue
  fi
  if ! version_interactive "$sh"; then
    printf '  ✖ %-5s resolved but `tracebloc version` failed in a fresh interactive shell\n' "$sh"
    fail=1; continue
  fi
  printf '  ✔ %-5s resolves + runs from a fresh interactive shell (rc persistence works)\n' "$sh"
done
echo "───────────────────────────────────────────────────────────────────────"

if [[ $tested -eq 0 ]]; then
  # bash is always present (we run under it), so this should never happen; guard
  # anyway so a pathological image can't make the job pass by testing nothing.
  echo "RESULT: FAIL — no shells were available to test on ${PRETTY}"
  exit 1
fi

if [[ $fail -ne 0 ]]; then
  echo "RESULT: FAIL — tracebloc was not reachable from a fresh interactive shell on ${PRETTY}"
  echo "        (the install put the binary somewhere a new terminal doesn't see —"
  echo "         this is the cli#61 PATH-persistence class.)"
  exit 1
fi
echo "RESULT: PASS — install.sh persists PATH so tracebloc resolves + runs from a fresh interactive shell on ${PRETTY}"
