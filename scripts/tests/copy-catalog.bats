#!/usr/bin/env bats
# =============================================================================
#  copy-catalog.bats — the installer copy catalog.
#
#  Renders every stable piece of installer copy byte-exact (colour off) into
#  scripts/testdata/golden/, so the wording AND layout a user sees while
#  installing can be reviewed without running an install. Mirrors the CLI's
#  golden catalog (cli repo, internal/cli/testdata/golden/).
#
#  Two files, ordered like the run:
#    00-install.golden  — banner, the "2. Installing" roadmap, the six running
#                         step headers (titles read live from install-k8s.sh),
#                         and --help.
#    01-outcomes.golden — the state-branched final summary (connected / starting
#                         / bad creds / image pull / crash) + the reboot footer.
#
#  Copy that only streams mid-flow (interactive prompts, per-component progress,
#  the curl|bash bootstrap's "1. Downloading" section) isn't a stable screen and
#  isn't pinned here.
#
#  The tests fail on drift; regenerate after an intentional copy change:
#    TB_UPDATE_GOLDEN=1 bats scripts/tests/copy-catalog.bats
# =============================================================================
load test_helper

setup() {
  export NO_COLOR=1          # empty every tone → byte-exact plain copy
  # print_banner no-ops when TRACEBLOC_BANNER_SHOWN is set (the curl|bash
  # bootstrap exports it after drawing the banner). An inherited value would
  # blank both banner samples in emit_install and drift the golden — clear it
  # so the catalog always renders them (mirrors common.bats).
  unset TRACEBLOC_BANNER_SHOWN
  load_lib summary.sh        # common.sh (banner/roadmap/help/step_header) + summary.sh
  # Deterministic env for the copy-emitting functions (values a user never sees
  # under NO_COLOR affect only the silent log(), but set them so `set -u`-style
  # references never trip).
  OS=Linux; ARCH=amd64; CLUSTER_NAME=tracebloc; SERVERS=1; AGENTS=1
  GPU_VENDOR=none; TB_NAMESPACE=tracebloc; HOST_DATA_DIR="$HOME/.tracebloc"
  # The connected-state CTA is now PATH-aware (#371): pin the CLI as usable-now
  # so the catalog deterministically renders the happy-path "Run tracebloc to get
  # started." line, instead of drifting to "Open a new terminal" on an unset (or
  # inherited) flag.
  TB_CLI_USABLE_NOW=1
  # Stub the one live read the summary makes, so it's deterministic.
  _chart_version() { echo "1.9.5"; }
}

GOLDEN_DIR="${BATS_TEST_DIRNAME}/../testdata/golden"

# check_golden NAME — compare stdin against the golden file, or (re)write it
# when TB_UPDATE_GOLDEN is set. Byte-exact via file comparison (not $output,
# which strips trailing newlines).
check_golden() {
  local golden="${GOLDEN_DIR}/$1" actual="${BATS_TEST_TMPDIR}/$1"
  cat >"$actual"
  if [ -n "${TB_UPDATE_GOLDEN:-}" ]; then
    mkdir -p "$GOLDEN_DIR"
    cp "$actual" "$golden"
    return 0
  fi
  diff -u "$golden" "$actual"
}

# ── 00 install — what you see while it runs ──────────────────────────────────
emit_install() {
  cat <<'PROSE'
tracebloc installer — what you see while installing
===================================================
What scrolls past when you run the installer (curl | bash, or ./install-k8s.sh
directly). Shown byte-exact, colour off. The banner and the "2. Installing"
roadmap print once up front; then each step prints its running header. The
titles below are read live from install-k8s.sh, so they can't drift from what
the installer actually prints. Interactive prompts and per-component progress
stream during the run and aren't pinned here.
PROSE

  printf '\n$ ./install-k8s.sh   # banner (curl|bash pins a version; direct run omits it)\n'
  TB_VERSION="v1.9.5" print_banner
  printf '\n$ ./install-k8s.sh   # banner, direct run (no version suffix)\n'
  TB_VERSION="" print_banner

  printf '\n$ ./install-k8s.sh   # the plan, printed once before install begins\n'
  print_roadmap

  printf '\n$ ./install-k8s.sh   # the six running step headers (a-f), titles from install-k8s.sh\n'
  sed -nE 's/.*step_header ([a-f]) "([^"]*)".*/\1 \2/p' "${SCRIPTS_DIR}/install-k8s.sh" \
    | while read -r letter title; do step_header "$letter" "$title"; done

  printf '\n\n------------------------------------------------------------\n--help\n------------------------------------------------------------\n'
  printf '$ ./install-k8s.sh --help\n'
  print_help
}

@test "installer copy catalog: 00-install is current" {
  emit_install | check_golden 00-install.golden
}

# ── 01 outcomes — the final summary, one per end state ───────────────────────
emit_outcomes() {
  cat <<'PROSE'
tracebloc installer — the final summary
=======================================
The last thing you see. After applying the chart the installer waits for your
services and reports one of these end states (summary.sh, print_summary). Shown
byte-exact, colour off. The "your data never leaves this machine" trust claim
appears ONLY on a verified connection.
PROSE

  local state
  for state in connected starting bad_creds image_pull crash; do
    printf '\n$ (install finished — %s)\n' "$state"
    CLIENT_STATE="$state" print_summary 2>&1
  done

  printf '\n$ (connected, on macOS/Windows — the reboot footer differs)\n'
  OS=Darwin _reboot_note
}

@test "installer copy catalog: 01-outcomes is current" {
  emit_outcomes | check_golden 01-outcomes.golden
}
