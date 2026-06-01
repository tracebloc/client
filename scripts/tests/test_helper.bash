#!/usr/bin/env bash
# Shared helpers + mock scaffolding for the installer bats suite.
# The installer libs are side-effect-safe to `source` (no top-level install
# logic); only install-k8s.sh runs main(), which the tests never source.

LIB_DIR="${BATS_TEST_DIRNAME}/../lib"
SCRIPTS_DIR="${BATS_TEST_DIRNAME}/.."

# Source common.sh (logging helpers, colours, has/retry) + an optional target lib.
load_lib() {
  # shellcheck source=/dev/null
  source "${LIB_DIR}/common.sh"
  if [ -n "${1:-}" ]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/$1"
  fi
  LOG_FILE=/dev/null   # make log() a silent sink during tests
}

# Record a mock invocation (one line per call) for later assertions.
record()     { printf '%s\n' "$*" >>"${MOCK_CALLS:-/dev/null}"; }
mock_calls() { cat "${MOCK_CALLS:-/dev/null}" 2>/dev/null; }
