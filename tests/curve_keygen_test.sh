#!/bin/bash
# Tests of shared/patch/curve_keygen.py, the patch/curve_keygen.py of mcloud and mcloud-agent: the X25519 test vector of
# RFC 7748, a new pair, the errors.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

require_cmd python3
KEYGEN=shared/patch/curve_keygen.py

section "keys"
# RFC 7748, section 6.1: the secret key of Alice and its public key
check "the X25519 test vector of RFC 7748" \
  "public=8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a
secret=77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a" \
  "$(python3 "$KEYGEN" 77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a)"
pair="$(python3 "$KEYGEN")"
secret="$(sed -n 's/^secret=//p' <<< "$pair")"
check "a new secret key is 64 hex characters" "true" "$([[ "$secret" =~ ^[0-9a-f]{64}$ ]] && echo true || echo false)"
check "the public key of a new pair is the one of its secret key" "$pair" "$(python3 "$KEYGEN" "$secret")"

section "errors"
python3 "$KEYGEN" xyz > /dev/null 2>&1
check "a secret key that is not 64 hex characters fails" "1" "$?"
python3 "$KEYGEN" a b > /dev/null 2>&1
check "more arguments are a usage error" "2" "$?"

finish
