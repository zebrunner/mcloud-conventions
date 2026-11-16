#!/bin/bash
# Tests of the step "Move the latest tag of the branch" of .github/workflows/docker-publish.yml: its script runs with git,
# docker and sleep stubs: the copy of the manifest is retried while ECR Public does not serve it yet, the tag is left to
# a newer commit of the branch.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

python3 -c 'import yaml' 2> /dev/null || skip "requires python3 with PyYAML (tests/requirements-lint.txt)"

python3 - > "${WORK}/latest.sh" << 'EOF'
import yaml

with open(".github/workflows/docker-publish.yml") as file:
    steps = yaml.safe_load(file)["jobs"]["publish"]["steps"]
print(next(step["run"] for step in steps if step.get("name") == "Move the latest tag of the branch"))
EOF

mkdir -p "${WORK}/bin"
record_stub sleep
# git ls-remote: the head of the branch is $HEAD_SHA
# shellcheck disable=SC2016
stub git 'printf "%s\trefs/heads/develop\n" "$HEAD_SHA"'
# docker: the copy fails the first $FAILURES times (the count in ${WORK}/copies)
stub docker "(IFS='|'; echo \"docker|\$*\") >> '${WORK}/calls.log'
copies=\$(( \$(cat '${WORK}/copies' 2> /dev/null || echo 0) + 1 ))
echo \"\$copies\" > '${WORK}/copies'
if (( copies <= FAILURES )); then
  echo 'ERROR: content at https://public.ecr.aws/v2/zebrunner/x/manifests/sha256:0 not found: not found' >&2
  exit 1
fi"

# latest <failures> [<head of the branch>]: runs the step, its output and status; the output variables in ${WORK}/output
latest() {
  reset_calls
  rm -f "${WORK}/copies"
  : > "${WORK}/output"
  PATH="${WORK}/bin:${PATH}" FAILURES="$1" HEAD_SHA="${2:-abc1234}" GITHUB_SHA=abc1234 GITHUB_REF=refs/heads/develop \
    GITHUB_REF_NAME=develop GITHUB_OUTPUT="${WORK}/output" IMAGE=public.ecr.aws/zebrunner/x:3.1-develop-abc1234 \
    LATEST=public.ecr.aws/zebrunner/x:3.1-develop-latest bash -e "${WORK}/latest.sh" 2>&1
}

section "the copy of the manifest"
output="$(latest 0)"
check "the tag is moved" "0" "$?"
check "one copy" "buildx|imagetools|create|--prefer-index=false|--tag|public.ecr.aws/zebrunner/x:3.1-develop-latest|public.ecr.aws/zebrunner/x:3.1-develop-abc1234" \
  "$(calls docker)"
check "moved=true" "moved=true" "$(cat "${WORK}/output")"
check "no wait" "" "$(calls sleep)"

section "ECR Public does not serve the pushed manifest yet"
output="$(latest 2)"
check "the tag is moved on the third attempt" "0" "$?"
check "three copies" "3" "$(calls docker | wc -l | tr -d ' ')"
check "the waits grow" "10
20" "$(calls sleep)"
check_contains "a failed attempt is a warning" "::warning title=docker-publish::the copy to public.ecr.aws/zebrunner/x:3.1-develop-latest failed (attempt 1), retried in 10 s" "$output"
check "moved=true after the retries" "moved=true" "$(cat "${WORK}/output")"

section "the manifest is never served"
output="$(latest 100)"
check "the step fails" "1" "$?"
check "six copies" "6" "$(calls docker | wc -l | tr -d ' ')"
check "150 s of waits" "150" "$(calls sleep | awk '{ sum += $1 } END { print sum }')"
check_contains "the error" "::error title=docker-publish::public.ecr.aws/zebrunner/x:3.1-develop-abc1234 is not copied to public.ecr.aws/zebrunner/x:3.1-develop-latest after 6 attempts" "$output"
check "no moved=true" "" "$(cat "${WORK}/output")"

section "a newer commit of the branch"
output="$(latest 0 def5678)"
check "the step succeeds" "0" "$?"
check "no copy" "" "$(calls docker)"
check "moved=false" "moved=false" "$(cat "${WORK}/output")"

finish
