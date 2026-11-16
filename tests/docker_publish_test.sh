#!/bin/bash
# Tests of the scripts of .github/workflows/docker-publish.yml, run with make, git, docker and sleep stubs: the tags and
# the platforms of the image from VERSION and the Makefile, the push of a platform by digest (make push), the merge of
# the platforms, the move of the latest tag (the copy of the manifest is retried while ECR Public does not serve it yet,
# the tag is left to a newer commit of the branch).
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

python3 -c 'import yaml' 2> /dev/null || skip "requires python3 with PyYAML (tests/requirements-lint.txt)"
require_cmd jq

# the scripts of the steps: ${WORK}/<job>-<n>.sh
python3 - "$WORK" << 'EOF_PY'
import sys
import yaml

with open(".github/workflows/docker-publish.yml") as file:
    jobs = yaml.safe_load(file)["jobs"]
for job, name, script in [
    ("prepare", "The tags and the platforms of the image", "tags"),
    ("build", "Build and push the image (make push)", "push"),
    ("publish", "Merge the platforms into the image", "merge"),
    ("publish", "Move the latest tag of the branch", "latest"),
]:
    with open(f"{sys.argv[1]}/{script}.sh", "w") as out:
        out.write(next(step["run"] for step in jobs[job]["steps"] if step.get("name") == name))
EOF_PY

mkdir -p "${WORK}/bin"
record_stub sleep
# git ls-remote: the head of the branch is $HEAD_SHA
# shellcheck disable=SC2016
stub git 'printf "%s\trefs/heads/develop\n" "$HEAD_SHA"'
# docker: imagetools create fails the first $FAILURES times (the count in ${WORK}/copies)
stub docker "(IFS='|'; echo \"docker|\$*\") >> '${WORK}/calls.log'
copies=\$(( \$(cat '${WORK}/copies' 2> /dev/null || echo 0) + 1 ))
echo \"\$copies\" > '${WORK}/copies'
if (( copies <= FAILURES )); then
  echo 'ERROR: content at https://public.ecr.aws/v2/zebrunner/x/manifests/sha256:0 not found: not found' >&2
  exit 1
fi"

# run <script> <env...>: runs the script of a step with the stubs and the variables of GitHub, its output and status;
# the output variables in ${WORK}/output
run() {
  local script="$1"
  shift
  reset_calls
  rm -f "${WORK}/copies"
  : > "${WORK}/output"
  env PATH="${WORK}/bin:${PATH}" FAILURES=0 HEAD_SHA=abc1234def GITHUB_SHA=abc1234def GITHUB_REF=refs/heads/develop \
    GITHUB_REF_NAME=develop GITHUB_REPOSITORY=zebrunner/x GITHUB_OUTPUT="${WORK}/output" RUNNER_TEMP="${WORK}/runner" \
    "$@" bash -e "${WORK}/${script}.sh" 2>&1
}

# output <name>: an output variable of the last step
output() {
  sed -n "s/^$1=//p" "${WORK}/output"
}

# project <platforms> [new|old|none]: ${WORK}/project with VERSION and a Makefile whose make push takes PUSH_OUTPUT (new),
# does not (old, before the push by digest) or has no PLATFORMS (none)
# shellcheck disable=SC2016 # the variables of make
project() {
  rm -rf "${WORK}/project"
  mkdir -p "${WORK}/project"
  echo 3.1 > "${WORK}/project/VERSION"
  local platforms="PLATFORMS ?= $1" flags='--tag $(IMAGE_REPO):$(VERSION) --push'
  case "${2:-new}" in
  new) flags='$(PUSH_CACHE) $(PUSH_OUTPUT)' ;;
  none) platforms="" ;;
  esac
  {
    printf '%s\n' 'SHELL := /bin/bash' '.DEFAULT_GOAL := help' 'IMAGE_REPO ?= public.ecr.aws/zebrunner/x' \
      'VERSION ?= dev' "$platforms" 'PUSH_OUTPUT ?= --tag $(IMAGE_REPO):$(VERSION) --push' 'PUSH_CACHE ?='
    printf 'help:\n\t@echo help\npush:\n\t@[[ "$(VERSION)" != dev ]] || exit 1\n'
    printf '\tdocker buildx build --builder mcloud --platform $(PLATFORMS) --build-arg VERSION=$(VERSION) %s .\n' "$flags"
  } > "${WORK}/project/Makefile"
}

# tags <env...>: the step of the tags in ${WORK}/project
tags() {
  (cd "${WORK}/project" && run tags IMAGE_REPO= "$@")
}

section "the tags"
project linux/amd64,linux/arm64
out="$(tags)"
check "the step succeeds" "0" "$?"
check "the image" "public.ecr.aws/zebrunner/x:3.1-develop-abc1234" "$(output image)"
check "the repository of the image" "public.ecr.aws/zebrunner/x" "$(output image-repo)"
check "the tag" "3.1-develop-abc1234" "$(output tag)"
check "the latest tag" "3.1-develop-latest" "$(output latest)"
tags IMAGE_REPO=registry.example.com/y > /dev/null
check "the input image-repo" "registry.example.com/y:3.1-develop-abc1234" "$(output image)"
out="$(tags GITHUB_REF=refs/tags/v1 GITHUB_REF_NAME=v1)"
check "a tag of git: the step fails" "1" "$?"
check_contains "a tag of git: the error" "::error title=docker-publish::refs/tags/v1 is not a branch" "$out"
echo 3.1-rc > "${WORK}/project/VERSION"
out="$(tags)"
check "a VERSION that is not a release: the step fails" "1" "$?"
check_contains "a VERSION that is not a release: the error" "VERSION is the release in work, e.g. 3.1: '3.1-rc'" "$out"

section "the platforms of a Makefile with PUSH_OUTPUT"
project linux/amd64,linux/arm64
out="$(tags)"
check "the platforms" "linux/amd64,linux/arm64" "$(output platforms)"
check "pushed by digest" "true" "$(output by-digest)"
check "amd64 and arm64 on their runners, no QEMU" \
  '[{"platform":"linux/amd64","name":"linux-amd64","runner":"ubuntu-latest","qemu":false},{"platform":"linux/arm64","name":"linux-arm64","runner":"ubuntu-24.04-arm","qemu":false}]' \
  "$(output matrix)"
check_not_contains "no notice" "::notice" "$out"
project linux/amd64
tags > /dev/null
check "amd64 only" '[{"platform":"linux/amd64","name":"linux-amd64","runner":"ubuntu-latest","qemu":false}]' "$(output matrix)"
project "linux/amd64, linux/arm/v7"
tags > /dev/null
check "another platform: the spaces of the list are dropped" "linux/amd64,linux/arm/v7" "$(output platforms)"
check "another platform: QEMU on amd64" \
  '[{"platform":"linux/amd64","name":"linux-amd64","runner":"ubuntu-latest","qemu":false},{"platform":"linux/arm/v7","name":"linux-arm-v7","runner":"ubuntu-latest","qemu":true}]' \
  "$(output matrix)"
project "" none
out="$(tags)"
check "no PLATFORMS: the step fails" "1" "$?"
check_contains "no PLATFORMS: the error" "::error file=Makefile,title=docker-publish::PLATFORMS of make push" "$out"
check "no PLATFORMS: no outputs" "" "$(cat "${WORK}/output")"

section "the platforms of a Makefile without PUSH_OUTPUT"
project linux/amd64,linux/arm64 old
out="$(tags)"
check "the step succeeds" "0" "$?"
check "not pushed by digest" "false" "$(output by-digest)"
check "one make push of the platforms with QEMU" \
  '[{"platform":"linux/amd64,linux/arm64","name":"all","runner":"ubuntu-latest","qemu":true}]' "$(output matrix)"
check_contains "a notice" "::notice file=Makefile,title=docker-publish::make push has no PUSH_OUTPUT" "$out"
project linux/amd64 old
tags > /dev/null
check "amd64 only: no QEMU" '[{"platform":"linux/amd64","name":"all","runner":"ubuntu-latest","qemu":false}]' "$(output matrix)"

# make: records its arguments, writes the digest $DIGEST into the --metadata-file of PUSH_OUTPUT
stub make "(IFS='|'; echo \"make|\$*\") >> '${WORK}/calls.log'
for arg in \"\$@\"; do
  if [[ \"\$arg\" =~ ^PUSH_OUTPUT=.*--metadata-file\ ([^ ]+) && -n \"\$DIGEST\" ]]; then
    printf '{\"containerimage.digest\": \"%s\"}\n' \"\$DIGEST\" > \"\${BASH_REMATCH[1]}\"
  fi
done"
digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"

# push <by digest> <env...>: the step of make push of linux/arm64
push() {
  rm -rf "${WORK}/runner"
  mkdir -p "${WORK}/runner"
  run push IMAGE_REPO=public.ecr.aws/zebrunner/x TAG=3.1-develop-abc1234 BY_DIGEST="$1" PLATFORM=linux/arm64 \
    NAME=linux-arm64 "${@:2}"
}

section "make push of a platform"
out="$(push true DIGEST="$digest_a")"
check "the step succeeds" "0" "$?"
check "make push of the platform, by digest, with its cache" \
  "push|VERSION=3.1-develop-abc1234|IMAGE_REPO=public.ecr.aws/zebrunner/x|PLATFORMS=linux/arm64|PUSH_OUTPUT=--output type=image,name=public.ecr.aws/zebrunner/x,push-by-digest=true,name-canonical=true,push=true --metadata-file ${WORK}/runner/metadata.json|PUSH_CACHE=--cache-from type=gha,scope=docker-publish-linux-arm64 --cache-to type=gha,mode=max,scope=docker-publish-linux-arm64,ignore-error=true" \
  "$(calls make)"
check "the digest for the publish job" "$digest_a" "$(cat "${WORK}/runner/digests/linux-arm64" 2> /dev/null)"
check_contains "the digest in a notice" "::notice title=docker-publish::linux/arm64: public.ecr.aws/zebrunner/x@${digest_a}" "$out"
out="$(push true DIGEST=)"
check "no digest: the step fails" "1" "$?"
check_contains "no digest: the error" "::error title=docker-publish::make push of linux/arm64 wrote no digest of the image" "$out"
check "no digest: no file" "" "$(ls "${WORK}/runner/digests" 2> /dev/null)"
out="$(push false)"
check "without PUSH_OUTPUT: the step succeeds" "0" "$?"
check "without PUSH_OUTPUT: make push of the Makefile" "push|VERSION=3.1-develop-abc1234|IMAGE_REPO=public.ecr.aws/zebrunner/x" \
  "$(calls make)"

# merge <failures> <platforms> <digests...>: the step of the merge with the digests of the platforms (linux-amd64,
# linux-arm64 in this order)
merge() {
  rm -rf "${WORK}/runner"
  mkdir -p "${WORK}/runner/digests"
  local names=(linux-amd64 linux-arm64) i=0
  for digest in "${@:3}"; do
    echo "$digest" > "${WORK}/runner/digests/${names[i]}"
    i=$((i + 1))
  done
  run merge FAILURES="$1" PLATFORMS="$2" IMAGE_REPO=public.ecr.aws/zebrunner/x \
    IMAGE=public.ecr.aws/zebrunner/x:3.1-develop-abc1234
}

section "the merge of the platforms"
out="$(merge 0 linux/amd64,linux/arm64 "$digest_a" "$digest_b")"
check "the step succeeds" "0" "$?"
check "one index of the platforms in their order" \
  "buildx|imagetools|create|--tag|public.ecr.aws/zebrunner/x:3.1-develop-abc1234|public.ecr.aws/zebrunner/x@${digest_a}|public.ecr.aws/zebrunner/x@${digest_b}" \
  "$(calls docker)"
merge 0 linux/amd64 "$digest_a" > /dev/null
check "one platform: its manifest is tagged" \
  "buildx|imagetools|create|--tag|public.ecr.aws/zebrunner/x:3.1-develop-abc1234|--prefer-index=false|public.ecr.aws/zebrunner/x@${digest_a}" \
  "$(calls docker)"
out="$(merge 0 linux/amd64,linux/arm64 "$digest_a")"
check "a platform without its digest: the step fails" "1" "$?"
check_contains "a platform without its digest: the error" "::error title=docker-publish::no digest of linux/arm64 from its build: ''" "$out"
check "a platform without its digest: no merge" "" "$(calls docker)"
out="$(merge 2 linux/amd64,linux/arm64 "$digest_a" "$digest_b")"
check "ECR Public does not serve a platform yet: merged on the third attempt" "0" "$?"
check "the waits grow" "10
20" "$(calls sleep)"
check_contains "a failed attempt is a warning" "::warning title=docker-publish::the merge into public.ecr.aws/zebrunner/x:3.1-develop-abc1234 failed (attempt 1), retried in 10 s" "$out"
out="$(merge 100 linux/amd64,linux/arm64 "$digest_a" "$digest_b")"
check "the platforms are never served: the step fails" "1" "$?"
check "six merges" "6" "$(calls docker | wc -l | tr -d ' ')"
check_contains "the platforms are never served: the error" "::error title=docker-publish::linux/amd64,linux/arm64 are not merged into public.ecr.aws/zebrunner/x:3.1-develop-abc1234 after 6 attempts" "$out"

# latest <failures> [<head of the branch>]: the step of the latest tag
latest() {
  run latest FAILURES="$1" HEAD_SHA="${2:-abc1234def}" IMAGE=public.ecr.aws/zebrunner/x:3.1-develop-abc1234 \
    LATEST=public.ecr.aws/zebrunner/x:3.1-develop-latest
}

section "the copy of the manifest"
out="$(latest 0)"
check "the tag is moved" "0" "$?"
check "one copy" "buildx|imagetools|create|--prefer-index=false|--tag|public.ecr.aws/zebrunner/x:3.1-develop-latest|public.ecr.aws/zebrunner/x:3.1-develop-abc1234" \
  "$(calls docker)"
check "moved=true" "moved=true" "$(cat "${WORK}/output")"
check "no wait" "" "$(calls sleep)"

section "ECR Public does not serve the pushed manifest yet"
out="$(latest 2)"
check "the tag is moved on the third attempt" "0" "$?"
check "three copies" "3" "$(calls docker | wc -l | tr -d ' ')"
check "the waits grow" "10
20" "$(calls sleep)"
check_contains "a failed attempt is a warning" "::warning title=docker-publish::the copy to public.ecr.aws/zebrunner/x:3.1-develop-latest failed (attempt 1), retried in 10 s" "$out"
check "moved=true after the retries" "moved=true" "$(cat "${WORK}/output")"

section "the manifest is never served"
out="$(latest 100)"
check "the step fails" "1" "$?"
check "six copies" "6" "$(calls docker | wc -l | tr -d ' ')"
check "150 s of waits" "150" "$(calls sleep | awk '{ sum += $1 } END { print sum }')"
check_contains "the error" "::error title=docker-publish::public.ecr.aws/zebrunner/x:3.1-develop-abc1234 is not copied to public.ecr.aws/zebrunner/x:3.1-develop-latest after 6 attempts" "$out"
check "no moved=true" "" "$(cat "${WORK}/output")"

section "a newer commit of the branch"
out="$(latest 0 def5678)"
check "the step succeeds" "0" "$?"
check "no copy" "" "$(calls docker)"
check "moved=false" "moved=false" "$(cat "${WORK}/output")"

finish
