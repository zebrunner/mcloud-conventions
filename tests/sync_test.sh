#!/bin/bash
# Tests of sync/sync.py with local target repositories: the shared files, the shared blocks, the checksums of
# .mcloud-conventions (the way tests/lint.sh checks them), no change on the second run, the files that are no longer
# shared, the other changes of a checkout, the push with a local origin and a gh stub, the errors, a target without the
# markers.
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

section "a file that is no longer shared"
sed -e 's/files: \[CONVENTIONS.md, tests\/lint.sh\]/files: [CONVENTIONS.md]/' \
  -e 's/blocks: \[.editorconfig, .gitignore, tests\/requirements-lint.txt\]/blocks: [.editorconfig, .gitignore]/' \
  "${WORK}/targets.yml" > "${WORK}/fewer.yml"
out="$(sync --config "${WORK}/fewer.yml" --repo test/image --local "test/image=${IMAGE}")"
check_contains "the removal is a change" "tests/lint.sh" "$out"
check "the synced file is removed" "false" "$([[ -e "${IMAGE}/tests/lint.sh" ]] && echo true || echo false)"
check "the manifest lists the shared files only" "CONVENTIONS.md files/util/logger.sh .editorconfig#block .gitignore#block " \
  "$(grep -v '^#' "${IMAGE}/.mcloud-conventions" | awk '{ print $2 }' | tr '\n' ' ')"
check "the block that is no longer shared stays" "$(block tests/requirements-lint.txt)" "$(block "${IMAGE}/tests/requirements-lint.txt")"
git_in "$IMAGE" checkout --quiet -- .
git_in "$IMAGE" clean --quiet -fd
# the first entry of the manifest: the rest of it is the new one
echo "project change" >> "${IMAGE}/CONVENTIONS.md"
git_in "$IMAGE" commit --quiet --all --message "a change of the project"
sed 's/files: \[CONVENTIONS.md, tests\/lint.sh\]/files: [tests\/lint.sh]/' "${WORK}/targets.yml" > "${WORK}/fewer.yml"
sync --config "${WORK}/fewer.yml" --repo test/image --local "test/image=${IMAGE}" > /dev/null
check_contains "a changed file that is no longer shared is kept" "project change" "$(cat "${IMAGE}/CONVENTIONS.md")"
check_not_contains "the kept file is not in the manifest" "CONVENTIONS.md" "$(grep -v '^#' "${IMAGE}/.mcloud-conventions")"
git_in "$IMAGE" checkout --quiet -- .
git_in "$IMAGE" clean --quiet -fd
echo "outside" > "${WORK}/outside.txt"
echo "$(sum "${WORK}/outside.txt")  ../outside.txt" >> "${IMAGE}/.mcloud-conventions"
sync --repo test/image --local "test/image=${IMAGE}" > /dev/null
check "a file outside of the repository is not removed" "true" "$([[ -e "${WORK}/outside.txt" ]] && echo true || echo false)"
git_in "$IMAGE" commit --quiet --all --message "sync again"

section "the other changes of a local checkout"
echo "notes" > "${IMAGE}/notes.txt"
echo "readme" > "${IMAGE}/README.md"
git_in "$IMAGE" add README.md
git_in "$IMAGE" commit --quiet --message "readme"
echo "work in progress" >> "${IMAGE}/README.md"
git_in "$IMAGE" add README.md
out="$(sync --repo test/image --local "test/image=${IMAGE}")"
check_contains "an untracked file and a staged change of another file are not the changes of the sync" \
  "test/image: up to date" "$out"

section "push"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
git clone --quiet --bare "$IMAGE" "${WORK}/origin.git"
# origin <git arguments...>: git in the bare origin of the target
origin() {
  git --git-dir="${WORK}/origin.git" "$@"
}
git_in "$IMAGE" remote add origin "${WORK}/origin.git"
base="$(git -C "$IMAGE" symbolic-ref --short HEAD)"
# gh: logs its calls; pr list prints the number of the open pull request of ${WORK}/open-pr
stub gh "echo \"gh \$*\" >> '${WORK}/calls.log'
if [[ \"\$1 \$2\" == 'pr list' ]]; then cat '${WORK}/open-pr' 2> /dev/null; fi
if [[ \"\$1 \$2\" == 'pr create' ]]; then echo https://github.com/test/image/pull/1; fi"
# push_sync: the sync of test/image with --push and the gh stub
push_sync() {
  git_in "$IMAGE" checkout --quiet "$base"
  PATH="${WORK}/bin:${PATH}" sync --repo test/image --local "test/image=${IMAGE}" --push
}
echo "drift" >> "${IMAGE}/CONVENTIONS.md"
git_in "$IMAGE" commit --quiet --message "a drift of a shared file" -- CONVENTIONS.md
out="$(push_sync)"
check_contains "the pull request is opened" "test/image: https://github.com/test/image/pull/1" "$out"
pushed="$(origin rev-parse mcloud-conventions-sync 2> /dev/null)"
check "the commit of the sync has its paths only, not the other changes of the checkout" "CONVENTIONS.md" \
  "$(origin diff --name-only mcloud-conventions-sync^ mcloud-conventions-sync 2> /dev/null | tr '\n' ' ' | sed 's/ $//')"
echo 1 > "${WORK}/open-pr"
reset_calls
out="$(push_sync)"
check_contains "the same files are not pushed again" "test/image: https://github.com/test/image/pull/1 (unchanged)" "$out"
check "the branch of the sync is kept" "$pushed" "$(origin rev-parse mcloud-conventions-sync)"
check_not_contains "the pull request is not edited" "gh pr edit" "$(cat "${WORK}/calls.log")"
git_in "$IMAGE" checkout --quiet "$base"
git_in "$IMAGE" reset --quiet --hard mcloud-conventions-sync
reset_calls
out="$(push_sync)"
check_contains "the pull request of a target that is up to date is closed" "test/image: up to date, closed the stale" "$out"
check_contains "the stale pull request and its branch" "gh pr close 1 --repo test/image --delete-branch" "$(cat "${WORK}/calls.log")"

section "errors"
out="$(sync --repo test/nope)"
check "an unknown repository is a usage error" "2" "$?"
check_contains "the unknown repository is reported" "unknown --repo test/nope" "$out"
sync --local test/image > /dev/null
check "a --local without the path is a usage error" "2" "$?"
mkdir -p "${WORK}/git-only"
ln -s "$(command -v git)" "${WORK}/git-only/git"
out="$(cd "$REPO" && PATH="${WORK}/git-only" "$(command -v python3)" sync/sync.py --config "${WORK}/targets.yml" \
  --repo test/image --local "test/image=${IMAGE}" --push 2>&1)"
check "a missing gh fails the sync" "1" "$?"
check_contains "the missing gh is reported" "test/image: FAIL: gh can't be run" "$out"

section "a target without the markers"
BROKEN="${WORK}/broken"
target "$BROKEN"
printf 'root = true\n' > "${BROKEN}/.editorconfig"
out="$(sync --repo test/broken --local "test/broken=${BROKEN}")"
status=$?
check_contains "the missing markers are reported" "test/broken: FAIL: test/broken/.editorconfig: one block between" "$out"
check "the sync fails" "1" "$status"

finish
