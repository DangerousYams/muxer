#!/bin/bash
# Run the plugin test suite: tests/run.sh [name-filter]
#   tests/run.sh            run everything
#   tests/run.sh stop       run only test files whose name contains "stop"
set -u

dir=$(cd "$(dirname "$0")" && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq is required to run these tests"; exit 1; }

pattern="${1:-}"
suites=0
failed=0

for t in "$dir"/test_*"$pattern"*.sh; do
  [ -f "$t" ] || { echo "no test files match '$pattern'"; exit 1; }
  suites=$((suites + 1))
  echo "== $(basename "$t")"
  bash "$t" || failed=$((failed + 1))
  echo
done

if [ "$failed" -eq 0 ]; then
  echo "ALL GREEN ($suites suite(s))"
else
  echo "$failed of $suites suite(s) FAILED"
  exit 1
fi
