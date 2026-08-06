# Makefile for tracebloc/client — uniform entry points (backend#1606).
#
# Every active tracebloc repo exposes the SAME three targets, so "run
# your tests before you push" stops being a rule you can only obey with
# per-repo tribal knowledge:
#
#   make check      lint + fast tests.   Budget: under 60 s.
#   make check-all  everything CI runs (bar the CI-only heavy suites).
#   make setup      install what those targets need.
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
	scripts/tests/path-persist.sh

.PHONY: help
help:
	@echo "tracebloc/client — make targets"
	@echo
	@echo "  check       lint + fast checks (~4 s) — run this before every push"
	@echo "  check-all   everything CI runs locally, including the 868-test bats suite"
	@echo "  setup       check for / point at the tools these targets need"
	@echo
	@echo "  individual: lint bats helm-lint helm-template helm-unittest drift"
	@echo
	@echo "  NOT here (CI-only, by name): the 9-distro prereq matrix, e2e-cluster"
	@echo "  (k3d), e2e-proxy (squid), path-persist, Pester, windows-e2e,"
	@echo "  e2e-journey, upgrade-e2e / seal-check-e2e / full-seal-e2e."

# ---- check: the pre-push tier ------------------------------------
#
# Measured at ~4 s (macOS): bash -n 0.1 s, shellcheck 3.2 s, the three
# drift guards 0.2 s, helm lint 0.7 s.
#
# The bats suite is deliberately NOT here. It is the repo's real unit
# suite (868 tests) and it takes ~2 min serially on macOS — three times
# over the budget — and it does not parallelise without GNU parallel,
# which is not a thing every dev machine has. Splitting it into a fast
# tier is real work, not a Makefile line, so it lives in `check-all`
# until someone does it. A `check` that quietly took two minutes would
# be a `check` nobody runs.
.PHONY: check
check: lint drift helm-lint
	@echo "==> check: green (bats + helm unit tests are in 'make check-all')"

.PHONY: check-all
check-all: lint drift helm-lint bats helm-template helm-unittest
	@echo "==> check-all: green"

# setup: no dependency is installed and no hook is added (hooks are a
# later step of backend#1606). This only tells you what is missing.
.PHONY: setup
setup:
	@missing=""; \
	for t in bash shellcheck bats helm; do \
	  command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "missing:$$missing"; \
	  echo "  macOS: brew install shellcheck bats-core helm"; \
	  echo "  Debian/Ubuntu: apt-get install shellcheck bats  (helm: https://helm.sh/docs/intro/install/)"; \
	  exit 1; \
	fi; \
	echo "==> setup: shellcheck, bats and helm are all present; run 'make check'"

# ---- individual targets ------------------------------------------

# lint: standard-checks.yml `Lint` + installer-tests.yaml `static`.
# .bats files are bats DSL, not valid bash — they are exercised by
# actually running them in the `bats` target.
.PHONY: lint
lint:
	@find scripts -type f -name '*.sh' -print0 \
	  | while IFS= read -r -d '' f; do bash -n "$$f" || exit 1; done
	@echo "all shell scripts parse"
	shellcheck --severity=error --shell=bash $(SHELLCHECK_FILES)

# drift: the three single-source guards from installer-tests.yaml's
# `static` job. All three are pure local file comparisons (~0.2 s) and
# all three have a --write / regenerate mode named in their own output.
.PHONY: drift
drift:
	scripts/gen-manifest.sh --check
	scripts/check-facts.sh --check
	bash scripts/check-style.sh

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
