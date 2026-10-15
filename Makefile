# Project checks; `make check` runs the linters and the tests (CONVENTIONS.md)
SHELL := /bin/bash
VENV := .venv
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

.DEFAULT_GOAL := help
.PHONY: help check lint test sync-preview

help: ## this list
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

check: ## everything below but sync-preview, as CI runs it; every step runs, the failed ones fail the target
	@status=0; for target in lint test; do $(MAKE) --no-print-directory $$target || status=1; done; exit $$status

lint: $(VENV)/.installed ## the linters and the text file checks (tests/lint.sh), ruff
	tests/lint.sh

test: $(VENV)/.installed ## the tests of the sync, the logger and the debug mode (tests/*_test.sh)
	@status=0; for t in $(sort $(wildcard tests/*_test.sh)); do $$t || status=1; done; exit $$status

sync-preview: $(VENV)/.installed ## the changes the sync would make in the repositories, nothing is pushed
	python3 sync/sync.py

# The tools of tests/requirements-lint.txt in .venv; the hadolint-py wheel for macOS is broken, brew provides it there
$(VENV)/.installed: tests/requirements-lint.txt
	python3 -m venv $(VENV)
	@if [[ "$$(uname)" == Darwin ]]; then \
	  grep -v '^hadolint-py' tests/requirements-lint.txt > $(VENV)/requirements.txt; \
	else \
	  cp tests/requirements-lint.txt $(VENV)/requirements.txt; \
	fi
	$(VENV)/bin/pip install --quiet --disable-pip-version-check --requirement $(VENV)/requirements.txt
	@command -v hadolint > /dev/null || { echo "hadolint is missing: brew install hadolint"; exit 1; }
	touch $@
