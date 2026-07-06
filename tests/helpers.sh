#!/bin/bash
# Shared assertions for hook-script tests. Source from test_*.sh, call `finish` at the end.
# Dependencies: bash, jq. No framework to install.
set -u

_pass=0
_fail=0

_ok()  { _pass=$((_pass + 1)); printf '  ok    %s\n' "$1"; }
_bad() {
  _fail=$((_fail + 1))
  printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
}

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then _ok "$1"; else _bad "$1" "$2" "$3"; fi
}

assert_silent() { # desc output
  if [ -z "$2" ]; then _ok "$1"; else _bad "$1" "(no output)" "$2"; fi
}

assert_contains() { # desc needle haystack
  case "$3" in
    *"$2"*) _ok "$1" ;;
    *) _bad "$1" "contains: $2" "$3" ;;
  esac
}

assert_not_contains() { # desc needle haystack
  case "$3" in
    *"$2"*) _bad "$1" "does not contain: $2" "$3" ;;
    *) _ok "$1" ;;
  esac
}

assert_valid_json() { # desc output
  if printf '%s' "$2" | jq -e . >/dev/null 2>&1; then
    _ok "$1"
  else
    _bad "$1" "valid JSON" "$2"
  fi
}

assert_jq() { # desc jq-filter expected json
  local actual
  actual=$(printf '%s' "$4" | jq -r "$2" 2>/dev/null || echo "<jq error>")
  if [ "$3" = "$actual" ]; then _ok "$1"; else _bad "$1 (jq: $2)" "$3" "$actual"; fi
}

finish() {
  printf '%d passed, %d failed\n' "$_pass" "$_fail"
  [ "$_fail" -eq 0 ]
}
