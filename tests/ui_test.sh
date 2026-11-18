#!/bin/bash
# Tests of shared/patch/ui.sh, the patch/ui.sh of mcloud and mcloud-agent: the colors, the glyphs and the width for the
# terminal and the locale, the banner, the sections, the statuses, the callouts, the help and the spinner.
# the code in single quotes runs in a child bash after sourcing ui.sh: its variables expand there
# shellcheck disable=SC2016
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

UI_SH=shared/patch/ui.sh
export UI_SH
ESC=$'\033'

# ui <code> [<VAR=value>...]: the output of the code after sourcing ui.sh (not a terminal) with a UTF-8 locale and 80
# columns, the variables override them
ui() {
  env -u NO_COLOR -u UI_COLOR -u UI_ASCII -u LC_ALL -u LC_CTYPE -u COLORTERM LANG=en_US.UTF-8 COLUMNS=80 TERM=xterm \
    "${@:2}" bash -c '. "$UI_SH"; '"$1"
}

# max_width <text>: the columns of the longest line of a text without colors
max_width() {
  local line max=0
  while IFS= read -r line; do
    [[ ${#line} -le "$max" ]] || max=${#line}
  done <<< "$1"
  echo "$max"
}

section "terminal"
check "no colors without a terminal" "0" "$(ui 'echo "$UI_COLOR_ON"')"
check "UI_COLOR=always forces the colors" "1" "$(ui 'echo "$UI_COLOR_ON"' UI_COLOR=always)"
check "UI_COLOR=never turns them off" "0" "$(ui 'echo "$UI_COLOR_ON"' UI_COLOR=never)"
check "the colors of 256 by default" "${ESC}[38;5;148m" "$(ui 'printf "%s" "$UI_ACCENT"' UI_COLOR=always)"
check "the 24-bit colors with COLORTERM=truecolor" "${ESC}[38;2;163;230;53m" \
  "$(ui 'printf "%s" "$UI_ACCENT"' UI_COLOR=always COLORTERM=truecolor)"
check_not_contains "no escape without colors" "$ESC" "$(ui 'ui_banner X 1; ui_section a 1/2; ui_ok a; ui_summary 1 2 3')"
if command -v script > /dev/null 2>&1; then
  if [[ "$(uname)" == "Darwin" ]]; then
    tty_run() { script -q /dev/null bash -c "$1"; }
  else
    tty_run() { script -qec "bash -c '$1'" /dev/null; }
  fi
  check "the colors on a terminal" "1" "$(TERM=xterm tty_run '. "$UI_SH"; echo "$UI_COLOR_ON"' | tr -dc '0-9')"
  check "no colors on a terminal with NO_COLOR" "0" \
    "$(NO_COLOR=1 TERM=xterm tty_run '. "$UI_SH"; echo "$UI_COLOR_ON"' | tr -dc '0-9')"
  check "no colors on a terminal with TERM=dumb" "0" "$(TERM=dumb tty_run '. "$UI_SH"; echo "$UI_COLOR_ON"' | tr -dc '0-9')"
else
  skip_check "the colors on a terminal" "requires script"
fi

section "glyphs"
check "Unicode with a UTF-8 locale" "1" "$(ui 'echo "$UI_UNICODE"')"
check "LC_ALL comes before LANG" "1" "$(ui 'echo "$UI_UNICODE"' LC_ALL=en_US.UTF-8 LANG=C)"
check "ASCII with LANG=C" "0" "$(ui 'echo "$UI_UNICODE"' LANG=C)"
check "ASCII without a locale" "0" "$(ui 'echo "$UI_UNICODE"' LANG=)"
check "UI_ASCII=true forces ASCII" "0" "$(ui 'echo "$UI_UNICODE"' UI_ASCII=true)"
check "the heavy line of Unicode" $'\xe2\x94\x81' "$(ui 'printf "%s" "$UI_HEAVY"')"
all_ascii="$(ui 'ui_banner X 1; ui_section a; ui_warn a b; ui_callout warn a; ui_prompt a b; ui_usage a;
  ui_help_group a; ui_help_cmd a b c; ui_summary 1 2 3; ui_spin a true' LANG=C)"
check "only ASCII without a UTF-8 locale" "" "$(LC_ALL=C tr -d '\000-\177' <<< "$all_ascii")"

section "width"
check "the width of 80 columns" "76" "$(ui 'echo "$UI_WIDTH"')"
check "at most 80 columns" "76" "$(ui 'echo "$UI_WIDTH"' COLUMNS=200)"
check "the width of a narrow terminal" "56" "$(ui 'echo "$UI_WIDTH"' COLUMNS=60)"
check "at least 40" "40" "$(ui 'echo "$UI_WIDTH"' COLUMNS=20)"
check "the heavy line is the width" "  $(printf '%76s' '' | tr ' ' '=')" "$(ui 'ui_banner X | tail -1' LANG=C)"

section "banner and sections"
banner="$(ui 'ui_banner "MCloud Agent" "v3.2.0"')"
check_contains "the badge and the product" "[ ZEBRUNNER ] MCloud Agent" "$banner"
check "the version at the right" "78 v3.2.0" "$(sed -n 2p <<< "$banner" | awk '{ print length($0), $NF }')"
check "the colored badge" "${ESC}[48;5;148m${ESC}[38;5;232m${ESC}[1m ZEBRUNNER ${ESC}[0m" \
  "$(ui 'ui_badge ZEBRUNNER' UI_COLOR=always)"
section_line="$(ui 'ui_section "Doctor host" "2/3"' LANG=C | sed -n 2p)"
check_contains "the title of a section in upper case" "[ DOCTOR HOST ] " "$section_line"
check "the counter of a section at the right" "78 2/3" "$(awk '{ print length($0), $NF }' <<< "$section_line")"
check "a section without a counter is the width too" "78" "$(ui 'ui_section Setup' LANG=C | awk 'NR == 2 { print length($0) }')"

section "statuses"
check "ok without colors" "   ok   Docker 27.3.1" "$(ui 'ui_ok "Docker 27.3.1"')"
check "info without colors" "   info 4 devices" "$(ui 'ui_info "4 devices"')"
branch=$'\xe2\x94\x94\xe2\x94\x80'
check "warn and its fix" "$(printf '   warn old\n     %s fix brew upgrade' "$branch")" "$(ui 'ui_warn old "brew upgrade"')"
check "fail and its fix in ASCII" "   FAIL down
     \`- fix start it" "$(ui 'ui_fail down "start it"' LANG=C)"
check "a colored dot" "   ${ESC}[38;5;78m"$'\xe2\x97\x8f'"${ESC}[0m up" "$(ui 'ui_ok up' UI_COLOR=always)"

section "callout"
long="STF_TOKEN of variables.env is empty: the grid reserves no device. Sign in to https://mcloud.example.com/stf, generate an access token (Settings, Keys), set it as STF_TOKEN of variables.env and run ./zebrunner.sh restart."
callout="$(env LANG=C bash -c '. "$UI_SH"; ui_callout warn "$1"' _ "$long" | sed 1d)"
check "the title of a warning" "  | WARNING" "$(head -1 <<< "$callout")"
check "the text is wrapped to the width" "true" "$([[ "$(max_width "$callout")" -le 78 ]] && echo true || echo false)"
check_contains "the text is kept" "| restart." "$callout"
check "the title of an error" "  | ERROR" "$(ui 'ui_callout error x' LANG=C | sed -n 2p)"
check "a title of its own" "  | NOTE: MDM" "$(ui 'ui_callout note x "NOTE: MDM"' LANG=C | sed -n 2p)"

section "prompt and help"
check "the prompt has no newline" "  > Start now? [Y/n] |" "$(ui 'ui_prompt "Start now?" "[Y/n]"; echo "|"' LANG=C)"
check "a prompt without a hint" "  > Label: |" "$(ui 'ui_prompt "Label:"; echo "|"' LANG=C)"
check "a command of the help" "   status      [label]             Status" "$(ui 'ui_help_cmd status "[label]" Status')"
help="$(ui 'ui_help_cmd ansible "[devices] [args...] [more]" "Deploy MCloud Agent: devices without the download of the images, args of ansible-playbook"')"
check "long arguments: the description on the next line" "   ansible [devices] [args...] [more]" "$(head -1 <<< "$help")"
check "the description is aligned" "" "$(sed 1d <<< "$help" | grep -v '^                                   [^ ]')"
check "the help is the width" "true" "$([[ "$(max_width "$help")" -le 78 ]] && echo true || echo false)"
check "the group of the help" "[ SET UP ]" "$(ui 'ui_help_group "Set up"' | sed -n 's/^  //p')"

section "summary"
check "the counts without colors" "  1 ok, 2 warn, 3 fail" "$(ui 'ui_summary 1 2 3' | tail -1)"
check_contains "the badges with colors" " 3 FAIL " "$(ui 'ui_summary 1 2 3' UI_COLOR=always)"

section "spinner"
check "a passed command" "   ok   Copy|0" "$(ui 'ui_spin Copy true; echo "|$?"' | tr '\n' ' ' | sed 's/ |/|/; s/ $//')"
check "a failed command shows its output and status" "   FAIL Copy      boom|3" \
  "$(ui 'ui_spin Copy bash -c "echo boom; exit 3"; echo "|$?"' | tr '\n' ' ' | sed 's/ |/|/; s/ $//')"
check "the arguments are kept" "     a b|c|" "$(ui 'ui_spin Args bash -c "printf \"%s|\" \"\$@\"; exit 1" _ "a b" c' | tail -1)"
check_not_contains "no spinner without a terminal" $'\r' "$(ui 'ui_spin Copy true')"

finish
