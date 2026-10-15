#!/bin/bash
# Tests of sync/sync.py with local target repositories: the shared files, the shared blocks, the checksums of
# .mcloud-conventions (the way tests/lint.sh checks them), no change on the second run, a target without the markers.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

python3 -c 'import yaml' 2> /dev/null || skip "requires python3 with PyYAML (tests/requirements-lint.txt)"

# git_in <dir> <git arguments...>: git with an identity in a target repository
git_in() {
  git -C "$1" -c user.name=test -c user.email=test@example.com "${@:2}"
}

# target <dir>: a target repository with the markers of the shared blocks and a project part after them
target() {
  mkdir -p "$1/tests"
  printf '# >>> mcloud-conventions old\nold = true\n# <<< mcloud-conventions\n\n[*.java]\nindent_size = 4\n' > "$1/.editorconfig"
  printf '# >>> mcloud-conventions old\n.old\n# <<< mcloud-conventions\ntarget\n' > "$1/.gitignore"
  printf '# >>> mcloud-conventions old\nold==1.0\n# <<< mcloud-conventions\nextra==2.0\n' > "$1/tests/requirements-lint.txt"
  git init --quiet "$1"
  git_in "$1" add --all
  git_in "$1" commit --quiet --message init
}

# sync <arguments...>: the output of sync/sync.py with the test targets
sync() {
  python3 sync/sync.py --config "${WORK}/targets.yml" "$@" 2>&1
}

# block <file>: the shared block of a file, the marker lines included
block() {
  sed -n '/^# >>> mcloud-conventions/,/^# <<< mcloud-conventions/p' "$1"
}

# sum <path>[#block]: the SHA-256 like tests/lint.sh computes it
sum() {
  local file="${1%#block}"
  if [[ "$1" == *"#block" ]]; then
    block "$file" | shasum -a 256 | cut -d ' ' -f 1
  else
    shasum -a 256 < "$file" | cut -d ' ' -f 1
  fi
}

cat > "${WORK}/targets.yml" << 'EOF'
groups:
  all:
    files: [CONVENTIONS.md, tests/lint.sh]
    blocks: [.editorconfig, .gitignore, tests/requirements-lint.txt]
  shell-image:
    files:
      - shared/util/logger.sh: util/logger.sh
repos:
  test/image:
    groups: [all, shell-image]
    paths:
      util/: files/util/
  test/broken:
    groups: [all]
EOF
IMAGE="${WORK}/image"
target "$IMAGE"

section "first sync"
out="$(sync --repo test/image --local "test/image=${IMAGE}")"
check_contains "the changes are shown" "test/image: changes:" "$out"
check "CONVENTIONS.md is copied" "$(cat CONVENTIONS.md)" "$(cat "${IMAGE}/CONVENTIONS.md")"
check "the paths of the repository are applied" "$(cat shared/util/logger.sh)" "$(cat "${IMAGE}/files/util/logger.sh" 2> /dev/null)"
check "the mode is kept" "true" "$([[ -x "${IMAGE}/tests/lint.sh" ]] && echo true || echo false)"
for file in .editorconfig .gitignore tests/requirements-lint.txt; do
  check "the shared block of ${file}" "$(block "$file")" "$(block "${IMAGE}/${file}")"
done
check_contains "the project part of .editorconfig is kept" "[*.java]" "$(cat "${IMAGE}/.editorconfig")"
check_contains "the project part of .gitignore is kept" "target" "$(tail -1 "${IMAGE}/.gitignore")"
check_contains "the project part of the requirements is kept" "extra==2.0" "$(cat "${IMAGE}/tests/requirements-lint.txt")"

section "manifest"
manifest="${IMAGE}/.mcloud-conventions"
check_contains "the source is recorded" "# synced from zebrunner/mcloud-conventions@" "$(cat "$manifest" 2> /dev/null)"
entries="$(grep -v '^#' "$manifest" | awk '{ print $2 }' | tr '\n' ' ')"
check "every shared file and block is listed" \
  "CONVENTIONS.md tests/lint.sh files/util/logger.sh .editorconfig#block .gitignore#block tests/requirements-lint.txt#block " "$entries"
mismatches="$(cd "$IMAGE" && grep -v '^#' .mcloud-conventions | while read -r expected path; do
  [[ "$(sum "$path")" == "$expected" ]] || echo "$path"
done)"
check "the checksums are the ones tests/lint.sh computes" "" "$mismatches"

section "second sync"
git_in "$IMAGE" add --all
git_in "$IMAGE" commit --quiet --message sync
check_contains "nothing to change" "test/image: up to date" "$(sync --repo test/image --local "test/image=${IMAGE}")"
check "the manifest is not rewritten" "" "$(git -C "$IMAGE" status --porcelain)"
echo "local change" >> "${IMAGE}/tests/lint.sh"
check_contains "a local change of a shared file is reverted" "test/image: up to date" "$(sync --repo test/image --local "test/image=${IMAGE}")"
check "the shared file is the one of the source again" "$(cat tests/lint.sh)" "$(cat "${IMAGE}/tests/lint.sh")"

section "a target without the markers"
BROKEN="${WORK}/broken"
target "$BROKEN"
printf 'root = true\n' > "${BROKEN}/.editorconfig"
out="$(sync --repo test/broken --local "test/broken=${BROKEN}")"
status=$?
check_contains "the missing markers are reported" "test/broken: FAIL: test/broken/.editorconfig: one block between" "$out"
check "the sync fails" "1" "$status"

finish
