# Makefile for tracebloc/client — uniform entry points (backend#1606).
#
# Every active tracebloc repo exposes the SAME three targets, so "run
# your tests before you push" stops being a rule you can only obey with
# per-repo tribal knowledge:
#
#   make check      lint + fast tests.   Budget: under 60 s.
#   make check-all  everything CI runs (bar the CI-only heavy suites).
#   make setup      install what those targets need, and a git pre-push hook
#                   that runs `make check` (skip once with --no-verify).
#
# This file is a THIN WRAPPER. Every command below is copied from the
# workflow that already runs it — standard-checks.yml, installer-tests.yaml
# and helm-ci.yaml. It introduces no new tool, no new config, and no new
# rule. When a workflow changes, change the matching line here.

.DEFAULT_GOAL := help

# The shellcheck file set from installer-tests.yaml's `static` job (a
# superset of standard-checks.yml's list), at the same `error` severity.
SHELLCHECK_FILES := \
	scripts/install.sh \
	scripts/install-k8s.sh \
	scripts/gen-manifest.sh \
	scripts/check-facts.sh \
	scripts/check-style.sh \
	scripts/resolve-ingestor-digest.sh \
	scripts/lib/*.sh \
	scripts/tests/check-drift.sh \
	scripts/tests/distro-prereqs.sh \
	scripts/tests/e2e-auto-upgrade.sh \
	scripts/tests/e2e-seal-check.sh \
	scripts/tests/e2e-full-seal.sh \
	scripts/tests/e2e-cluster.sh \
	scripts/tests/e2e-journey.sh \
	scripts/tests/e2e-proxy.sh \
	scripts/tests/lib/e2e-common.sh \
	scripts/tests/path-persist.sh \
	scripts/tests/chart-env-vocabulary.sh \
	scripts/tests/env-vocabulary-agreement.sh

# The bats total, DERIVED — never written down. It moves on most PRs that add a
# test, nothing enforces it, and the help text had drifted from its hardcoded
# 868 to a real 946 with nobody noticing. A number that is wrong is worse than
# no number, and re-hardcoding today's value only resets the drift clock.
#
# `=`, not `:=`: recursively expanded, so the grep runs only when `help` actually
# prints it. `make check` is the pre-push path with a sub-60 s budget and never
# pays for it. bats declares one test per `@test` at line start, so this matches
# `bats`'s own count exactly (verified: 946 = 946).
BATS_TEST_COUNT = $(shell grep -h '^@test' scripts/tests/*.bats 2>/dev/null | wc -l | tr -d ' ')

.PHONY: help
help:
	@echo "tracebloc/client — make targets"
	@echo
	@echo "  check       lint + fast checks (~4 s) — run this before every push"
	@echo "  check-all   everything CI runs locally, including the $(BATS_TEST_COUNT)-test bats suite"
	@echo "  setup       check for / point at the tools these targets need; installs the pre-push hook"
	@echo "  install-hooks  (re)install the git pre-push hook that runs 'make check'"
	@echo
	@echo "  individual: lint bats helm-lint helm-vocab helm-template helm-unittest drift"
	@echo
	@echo "  NOT here (CI-only, by name): the 9-distro prereq matrix, e2e-cluster"
	@echo "  (k3d), e2e-proxy (squid), path-persist, Pester, windows-e2e,"
	@echo "  e2e-journey, upgrade-e2e / seal-check-e2e / full-seal-e2e."

# ---- check: the pre-push tier ------------------------------------
#
# Measured at ~5 s (macOS): bash -n 0.1 s, shellcheck 3.2 s, the five
# drift guards 1.0 s, helm lint 0.7 s.
#
# The bats suite is deliberately NOT here. It is the repo's real unit
# suite and it takes ~2 min serially on macOS — three times over the
# budget — and it does not parallelise without GNU parallel, which is
# not a thing every dev machine has. Splitting it into a fast tier is
# real work, not a Makefile line, so it lives in `check-all` until
# someone does it. A `check` that quietly took two minutes would be a
# `check` nobody runs.
.PHONY: check
check: lint drift helm-lint helm-vocab
	@echo "==> check: green (bats + helm unit tests are in 'make check-all')"

.PHONY: check-all
check-all: lint drift helm-lint helm-vocab bats helm-template helm-unittest
	@echo "==> check-all: green"

# setup: no dependency is installed — this only tells you what is missing —
# but it does install a git pre-push hook that runs `make check` (backend#1606
# step 4), via the install-hooks target below.
.PHONY: setup
setup:
	@missing=""; \
	for t in bash shellcheck bats helm python3; do \
	  command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "missing:$$missing"; \
	  echo "  macOS: brew install shellcheck bats-core helm python"; \
	  echo "  Debian/Ubuntu: apt-get install shellcheck bats python3  (helm: https://helm.sh/docs/intro/install/)"; \
	  exit 1; \
	fi; \
	echo "==> setup: shellcheck, bats, helm and python3 are all present; run 'make check'"
	@$(MAKE) --no-print-directory install-hooks

# install-hooks: put a pre-push hook in place that runs `make check`, so the
# canon's "run the tests before you push" is carried by the tooling rather than
# by memory. Factored out of `setup` so it is independently runnable and
# testable, and so a contributor who only wants the hook need not rerun the
# full `make setup`.
#
# Honest by design: the hook catches FORGETTING, not defiance — `git push
# --no-verify` skips it and always will. And it refuses to clobber a pre-push
# hook that is already there and not ours (e.g. one the pre-commit framework
# manages), rather than silently stomping a contributor's setup.
#
# `git rev-parse --git-path hooks` (not a hard-coded `.git/hooks`) so it lands
# in the right place inside a linked worktree or a submodule, where the git dir
# is not `.git`.
.PHONY: install-hooks
install-hooks:
	@if ! git rev-parse --git-dir >/dev/null 2>&1; then \
	  echo "note: not a git checkout — skipping pre-push hook install"; \
	else \
	  hook="$$(git rev-parse --git-path hooks)/pre-push"; \
	  if [ -e "$$hook" ] && ! grep -q 'tracebloc pre-push hook' "$$hook" 2>/dev/null; then \
	    echo "note: $$hook already exists and is not ours — leaving it untouched."; \
	    echo "      add 'make check' to it, or remove it and re-run 'make install-hooks'."; \
	  else \
	    mkdir -p "$$(dirname "$$hook")" && \
	    printf '%s\n' \
	      '#!/bin/sh' \
	      '# tracebloc pre-push hook installed by make setup (backend#1606).' \
	      '# Runs make check so a push that would be red in CI is caught locally first.' \
	      '# It catches forgetting, not defiance: git push --no-verify skips it.' \
	      '#' \
	      '# Git exports GIT_DIR/GIT_WORK_TREE/etc into hook processes; a nested git' \
	      '# (e.g. Go buildvcs under go test) then fails in a linked worktree with' \
	      '# exit status 128. Clear them so make check runs as if from the shell.' \
	      'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY' \
	      'exec make check' > "$$hook" && \
	    chmod +x "$$hook" && \
	    echo "==> pre-push hook installed at $$hook" && \
	    echo "    'make check' now runs before each push (skip once with: git push --no-verify)"; \
	  fi; \
	fi

# ---- individual targets ------------------------------------------

# lint: standard-checks.yml `Lint` + installer-tests.yaml `static`.
# .bats files are bats DSL, not valid bash — they are exercised by
# actually running them in the `bats` target.
#
# The parse loop is `xargs -0 -n1`, NOT `while read -r -d ''`. Make runs
# recipes under /bin/sh, which on Debian and Ubuntu is dash, and dash
# rejects `read -d` outright — the loop body would never execute and the
# pipeline would still exit 0, so `make check` would cheerfully print
# "all shell scripts parse" having parsed nothing. GitHub Actions uses
# bash, so CI never showed it. xargs is POSIX, NUL-safe, and propagates
# a child failure as a non-zero exit. (Bugbot, #630.)
.PHONY: lint
lint:
	@find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
	@echo "all shell scripts parse"
	shellcheck --severity=error --shell=bash $(SHELLCHECK_FILES)

# lint-warnings: the advisory `--severity=warning` sweep, over the SAME file set
# (hence no second list). NOT part of `lint` and NOT a gate: the libs are sourced
# together as one program, so single-file shellcheck reports SC2034 "unused" for
# shared vars (CURL_SECURE, ARCH_DL, the colours) that common.sh defines and
# other libs consume. It is printed for visibility only.
#
# It exists as a target because installer-tests.yaml's `static` job used to run
# this sweep inline, and that job is gone; standard-checks.yml's `Lint` calls
# this so the visibility survives the move rather than being quietly dropped.
.PHONY: lint-warnings
lint-warnings:
	@shellcheck --severity=warning --shell=bash $(SHELLCHECK_FILES) || true

# drift: the repo's duplicated-declaration guards, and the ONLY declaration of
# that set. drift-checks.yaml's `Source-of-truth drift` job -- the one that is a
# REQUIRED check on develop and on main -- runs `make drift` and lists nothing
# itself, so a guard added here gates automatically and the pre-push hook and
# the merge gate cannot disagree about what "the drift guards" are.
#
# They could, and did. Until 2026-08-19 this target held gen-manifest /
# check-facts / check-style while the required job held check-drift, so each
# side gated exactly what the other did not: a stale manifest.sha256 was caught
# by the pre-push hook and NOT at the merge gate, because the job that ran R8
# (`Static analysis`) is required on no branch. Hence one list, here.
#
# All five are pure local file comparisons and all have a --write / regenerate
# mode named in their own output. ~2 s total; check-drift adds `helm template`
# (~1 s) and is the only one that wants a tool beyond bash + python3.
#
# env-vocabulary-agreement lives here, not in `helm-vocab`, because #715 moved
# it out of helm-ci's `Helm lint` into the required drift job; helm-ci's lint job
# calls `make helm-lint helm-vocab`, so keeping it there would silently put it
# back where #715 took it from.
# `|`-separated because each guard is a multi-word command; the recipe splits on
# it. One entry per guard, and this is the only place they are written down.
DRIFT_GUARDS := scripts/gen-manifest.sh --check|scripts/check-facts.sh --check|bash scripts/check-style.sh|bash scripts/tests/check-drift.sh|bash scripts/tests/env-vocabulary-agreement.sh

# Every guard RUNS even when an earlier one fails, and the target fails at the
# end if any did. Sequential `cmd1<newline>cmd2` recipe lines stop at the first
# failure, which means a stale manifest hides a terminology violation until you
# fix the manifest, push, and wait for CI again -- three round trips to learn two
# independent mechanical facts that took one second each to compute.
#
# This is NOT the fail-open shape. A failure here still fails the target and so
# reddens the REQUIRED `Source-of-truth drift` check; the guards are independent
# in their REPORTING, not in whether they block. (Contrast the bug this replaced:
# guards sharing one job's `timeout-minutes` reported `skipped` and blocked
# nothing.) `if [ "$$fail" -ne 0 ]` at the end is what keeps it closed -- a guard
# that cannot be reached still counts as a failure, because sh -c returns
# non-zero for a missing or non-executable script.
.PHONY: drift
drift:
	@guards='$(DRIFT_GUARDS)'; \
	fail=0; IFS='|'; for g in $$guards; do \
	  printf '\n==> %s\n' "$$g"; \
	  sh -c "$$g" || { fail=1; printf '!! FAILED: %s\n' "$$g"; }; \
	done; \
	unset IFS; \
	if [ "$$fail" -ne 0 ]; then \
	  printf '\ndrift: one or more guards FAILED (all were run — see !! lines above)\n'; \
	  exit 1; \
	fi; \
	printf '\ndrift: all guards green\n'

# digest-drift: the watcher on every mutable label that points at a pinned
# digest (backend#1853). NOT in `check`: it needs the network and a docker
# daemon, and it is knowingly RED today -- the ingestor's 0.8 float has moved
# off the pinned v0.8.2 digest, which is the whole finding. A red target in the
# pre-push tier trains people to skip the tier.
#
# It runs on the schedule in .github/workflows/digest-drift.yml. Its bats suite
# IS in `make bats`, because that part needs no network.
.PHONY: digest-drift
digest-drift:
	scripts/check-digest-drift.sh

# bats: standard-checks.yml `Unit tests` / installer-tests.yaml
# `unit-bash`. ~2 min serially.
.PHONY: bats
bats:
	bats scripts/tests/*.bats

# helm-lint: helm-ci.yaml `lint`.
.PHONY: helm-lint
helm-lint:
	@for f in client/ci/*-values.yaml; do \
	  echo "=== Linting client with $$f ==="; \
	  helm lint --strict ./client -f "$$f" || exit 1; \
	done
	helm lint --strict ./ingestor

# helm-vocab: helm-ci.yaml `lint` job's vocabulary step. The CLIENT_ENV and
# channelTags vocabularies are closed by a values.schema.json `enum` /
# `additionalProperties` plus a `fail` in tracebloc.clientEnv, and helm-unittest
# can assert NEITHER: it treats a schema violation as a plugin-level error
# rather than a template failure, and offers no way to skip validation and reach
# the helper. So the gates are exercised from outside the plugin. ~2 s.
#
# CHART vocabulary only. env-vocabulary-agreement.sh is in `drift`, not here --
# see that target for why (#715 moved it to the required drift gate, and
# helm-ci's lint job runs this target).
.PHONY: helm-vocab
helm-vocab:
	bash scripts/tests/chart-env-vocabulary.sh

# helm-template: helm-ci.yaml `template`. kubeconform is pinned by
# version AND digest in CI; rather than re-implement that download here,
# this renders every platform (which is the part that catches template
# breaks) and runs kubeconform only if you already have it.
.PHONY: helm-template
helm-template:
	@for p in aks bm eks oc; do \
	  echo "=== Rendering $$p ==="; \
	  helm template test-$$p ./client -f client/ci/$$p-values.yaml > /tmp/rendered-$$p.yaml || exit 1; \
	  if command -v kubeconform >/dev/null 2>&1; then \
	    kubeconform -strict -ignore-missing-schemas -summary /tmp/rendered-$$p.yaml || exit 1; \
	  fi; \
	done
	@command -v kubeconform >/dev/null 2>&1 \
	  || echo "note: kubeconform not on PATH — rendered only. CI also validates the manifests."

# helm-unittest: helm-ci.yaml `unittest`. Needs the plugin; the install
# command is the one CI uses, pinned to the same version.
.PHONY: helm-unittest
helm-unittest:
	@helm plugin list 2>/dev/null | grep -q unittest \
	  || { echo "helm-unittest plugin missing — install it with:"; \
	       echo "  helm plugin install https://github.com/helm-unittest/helm-unittest --version 0.5.2"; \
	       exit 1; }
	helm unittest ./client
