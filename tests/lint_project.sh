#!/bin/bash
# shellcheck disable=SC2034
# The settings and the checks of the project for tests/lint.sh (CONVENTIONS.md): mcloud-conventions.

scripts=(tests/*.sh shared/util/*.sh)
dockerfiles=()
tools=(ruff)
# this repository is the source of the shared files
manifest=""

# project_checks: the sync in Python
project_checks() {
  section "python"
  run_check "ruff check" ruff check --no-cache .
  run_check "ruff format" ruff format --check --no-cache .
}
