#!/bin/bash
# Tests of shared/patch/completion.sh, the patch/completion.sh of mcloud and mcloud-agent: the words passed to
# `<program> __complete`, the candidates of the current word, the udids with a colon, the programs that may not run.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

COMPLETION_SH="${REPO}/shared/patch/completion.sh"
export COMPLETION_SH

# the program: it logs its arguments and answers with fixed candidates
mkdir -p "${WORK}/farm"
cat > "${WORK}/farm/zebrunner-farm" << 'PROGRAM'
#!/bin/bash
printf '%s\n' "$*" > "${0%/*}/args"
[[ "$1" == "__complete" ]] || exit 1
printf '%s\n' status start stop restart down Pixel_7 192.168.1.50:5555 192.168.1.51:5555 --rolling
PROGRAM
chmod 755 "${WORK}/farm/zebrunner-farm"
export PROGRAM="${WORK}/farm/zebrunner-farm"

# complete <command line>: the replies of bash for the command line with the cursor at its end, one per line
complete_bash() {
  LINE="$1" bash -c '
    source "$COMPLETION_SH"
    COMP_LINE="$LINE"
    COMP_POINT=${#LINE}
    # the words of bash: split also at : and =
    read -r -a COMP_WORDS <<< "$(sed -E "s/([:=])/ \1 /g" <<< "$LINE")"
    [[ "$LINE" == *" " ]] && COMP_WORDS+=("")
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    _zebrunner_complete
    printf "%s\n" "${COMPREPLY[@]}"
  '
}

section "registration"
check "zebrunner.sh, ./zebrunner.sh and zebrunner-farm are completed" \
  "complete -o default -F _zebrunner_complete zebrunner.sh
complete -o default -F _zebrunner_complete zebrunner-farm
complete -o default -F _zebrunner_complete ./zebrunner.sh" "$(bash -c 'source "$COMPLETION_SH"; complete -p' | sort -r)"

section "words"
check "the commands of the first word" "start
status
stop" "$(complete_bash "${PROGRAM} st" | sort)"
check "the index and the words after the program" "__complete 1 st" "$(cat "${WORK}/farm/args")"
check "a new word after a space" "__complete 2 start " "$(
  complete_bash "${PROGRAM} start " > /dev/null
  cat "${WORK}/farm/args"
)"
check "the options" "--rolling" "$(complete_bash "${PROGRAM} restart --r")"
check "a udid with a colon: the reply after the colon of bash" "5555" "$(complete_bash "${PROGRAM} start 192.168.1.50:5")"
check "two udids with the same prefix" "192.168.1.50:5555
192.168.1.51:5555" "$(complete_bash "${PROGRAM} start 192.168.1.5")"
check "no candidate" "" "$(complete_bash "${PROGRAM} xyz")"
check "a glob in the line is not expanded" "__complete 2 start *" \
  "$(
    cd "$WORK" && complete_bash "${PROGRAM} start *" > /dev/null
    cat "${WORK}/farm/args"
  )"
check "a program of the PATH" "Pixel_7" "$(PATH="${WORK}/farm:${PATH}" complete_bash "zebrunner-farm start Pix")"
# the ~ of the command line as typed
# shellcheck disable=SC2088
check "a program in ~" "Pixel_7" "$(HOME="$WORK" complete_bash "~/farm/zebrunner-farm start Pix")"

section "safety"
rm -f "${WORK}/farm/args"
chmod 775 "${WORK}/farm/zebrunner-farm"
check "a program writable by the group is not run" "" "$(complete_bash "${PROGRAM} st")"
chmod 757 "${WORK}/farm/zebrunner-farm"
check "a program writable by the others is not run" "" "$(complete_bash "${PROGRAM} st")"
check "neither of them ran" "false" "$([[ -e "${WORK}/farm/args" ]] && echo true || echo false)"
chmod 755 "${WORK}/farm/zebrunner-farm"
check "a missing program" "" "$(complete_bash "${WORK}/none/zebrunner.sh st")"
check "a program that fails" "" "$(complete_bash "${PROGRAM%/*}/../farm/zebrunner-farm x" | grep -v '^$')"

section "zsh"
if command -v zsh > /dev/null 2>&1; then
  check_contains "zsh registers the completion with bashcompinit" "-F _zebrunner_complete" \
    "$(HOME="$WORK" zsh -fc 'source "$COMPLETION_SH"; print -r -- ${_comps[zebrunner-farm]}' 2>&1 | tail -1)"
  check "zsh completes the words" "start status stop" \
    "$(LINE="${PROGRAM} st" HOME="$WORK" zsh -fc 'source "$COMPLETION_SH"; COMP_LINE="$LINE"; COMP_POINT=${#LINE}; COMP_WORDS=(x st); COMP_CWORD=1; _zebrunner_complete; print -r -- "${COMPREPLY[*]}"' 2>&1 | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
else
  skip_check "zsh" "requires zsh"
fi

finish
