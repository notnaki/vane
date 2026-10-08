#!/usr/bin/env bash
set -euo pipefail

binary="${1:-.build/debug/vane}"
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export VANE_DATA_DIR="$fixture/data"

set +e
"$binary" import "$fixture/missing.csv" >"$fixture/stdout" 2>"$fixture/stderr"
status=$?
set -e

if [[ "$status" -ne 1 ]]; then
    echo "Expected a missing CSV import to exit 1; got $status" >&2
    exit 1
fi
if [[ -s "$fixture/stdout" ]]; then
    echo "A failed import must not report success on stdout" >&2
    exit 1
fi
if ! grep -q 'Could not import passwords:' "$fixture/stderr" ||
   ! grep -q 'missing.csv' "$fixture/stderr"; then
    echo "A failed import must explain the file error" >&2
    cat "$fixture/stderr" >&2
    exit 1
fi

set +e
"$binary" import >"$fixture/stdout" 2>"$fixture/stderr"
status=$?
set -e
if [[ "$status" -ne 2 || -s "$fixture/stdout" ]] ||
   ! grep -q 'Usage: vane import <password-export.csv>' "$fixture/stderr"; then
    echo "An import without a file must print usage and exit 2" >&2
    exit 1
fi

# Invalid documents must fail before Keychain access, and no field/header can leak
# into the diagnostic. Every value is synthetic; the data directory is isolated.
for case_name in header quoting overwide; do
    case "$case_name" in
        header) printf 'SYNTHETIC_SECRET_SENTINEL,unknown\n' > "$fixture/input.csv" ;;
        quoting) printf 'url,username,password\nhttps://valid.invalid,ada,SYNTHETIC_SECRET_SENTINEL\nhttps://bad.invalid,bob,"unfinished' > "$fixture/input.csv" ;;
        overwide) printf 'url,username,password\nhttps://valid.invalid,ada,SYNTHETIC_SECRET_SENTINEL\nhttps://bad.invalid,bob,part1,part2\n' > "$fixture/input.csv" ;;
    esac
    set +e
    "$binary" import "$fixture/input.csv" >"$fixture/stdout" 2>"$fixture/stderr"
    status=$?
    set -e
    if [[ "$status" -ne 1 || -s "$fixture/stdout" ]] ||
       ! grep -q 'Could not import passwords:' "$fixture/stderr" ||
       grep -q 'SYNTHETIC_SECRET_SENTINEL' "$fixture/stderr"; then
        echo "Invalid $case_name CSV must fail without reporting success or field values" >&2
        exit 1
    fi
done

echo "PASS (CLI password import errors and secret-free malformed input diagnostics)"
