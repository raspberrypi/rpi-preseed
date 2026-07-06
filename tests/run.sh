#!/bin/sh
# rpi-preseed test harness (POSIX sh). Runs unit + integration tests.

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
export RPI_PRESEED_SCHEMA="$REPO/schema/rpi-preseed.schema"
export RPI_PRESEED_BASEDIR="$REPO/src"

SCRATCH=$(mktemp -d)
export RPI_PRESEED_STATE_DIR="$SCRATCH/state"
export RPI_PRESEED_BOOT_DIR="$SCRATCH/boot"
trap 'rm -rf "$SCRATCH"' EXIT

# Source libraries for unit tests.
# shellcheck source=src/lib/common.sh
. "$REPO/src/lib/common.sh"
# shellcheck source=src/lib/toml.sh
. "$REPO/src/lib/toml.sh"
# shellcheck source=src/lib/validate.sh
. "$REPO/src/lib/validate.sh"
# shellcheck source=src/lib/redact.sh
. "$REPO/src/lib/redact.sh"
# shellcheck source=src/lib/log.sh
. "$REPO/src/lib/log.sh"

TESTS=0
FAILS=0
ok() { TESTS=$((TESTS + 1)); printf 'ok   - %s\n' "$1"; }
no() { TESTS=$((TESTS + 1)); FAILS=$((FAILS + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq()        { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want [$3] got [$2])"; fi; }
assert_contains()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing [$3])"; fi; }
assert_ncontains() { if printf '%s' "$2" | grep -qF -- "$3"; then no "$1 (unexpectedly found [$3])"; else ok "$1"; fi; }
assert_ok()        { if ( eval "$2" ) >/dev/null 2>&1; then ok "$1"; else no "$1 (cmd failed: $2)"; fi; }
assert_fail()      { if ( eval "$2" ) >/dev/null 2>&1; then no "$1 (cmd unexpectedly ok: $2)"; else ok "$1"; fi; }
assert_file()      { if [ -f "$2" ]; then ok "$1"; else no "$1 (no file: $2)"; fi; }

# shellcheck source=tests/test_toml.sh
. "$REPO/tests/test_toml.sh"
# shellcheck source=tests/test_validate.sh
. "$REPO/tests/test_validate.sh"
# shellcheck source=tests/test_redact.sh
. "$REPO/tests/test_redact.sh"
# shellcheck source=tests/test_hash.sh
. "$REPO/tests/test_hash.sh"
# shellcheck source=tests/test_integration.sh
. "$REPO/tests/test_integration.sh"

echo "== toml =="        ; t_toml
echo "== validate =="    ; t_validate
echo "== redact =="      ; t_redact
echo "== hash =="        ; t_hash
echo "== integration ==" ; t_integration

echo "-------------------------------------"
printf '%d tests, %d failures\n' "$TESTS" "$FAILS"
[ "$FAILS" -eq 0 ]
