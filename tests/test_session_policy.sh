#!/bin/bash
# session-policy.sh: the injected routing policy adapts to the session model.
# On Fable the orchestrator gets the "never delegate" director's brief; on cheaper
# models it gets the common policy plus the muxer:oracle escalation bullet.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/helpers.sh"
S="$here/../scripts/session-policy.sh"

# --- fable session: orchestrator brief, no oracle escalation ---
out=$(printf '{"model":"claude-fable-5","session_id":"t"}' | "$S")
assert_valid_json "fable session emits valid JSON" "$out"
assert_jq "fable session targets SessionStart" '.hookSpecificOutput.hookEventName' "SessionStart" "$out"
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "fable policy carries the routing header" "MUXER ROUTING POLICY" "$ctx"
assert_contains "fable policy names the never-delegate list" "NEVER DELEGATE" "$ctx"
assert_not_contains "fable policy has no oracle escalation bullet" "muxer:oracle (Fable, premium billing)" "$ctx"

# --- cheaper session: common policy plus the oracle escalation path ---
out=$(printf '{"model":"claude-opus-4-8","session_id":"t"}' | "$S")
assert_valid_json "opus session emits valid JSON" "$out"
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "opus policy carries the routing header" "MUXER ROUTING POLICY" "$ctx"
assert_contains "opus policy adds the oracle escalation bullet" "muxer:oracle (Fable, premium billing)" "$ctx"
assert_not_contains "opus policy omits the never-delegate list" "NEVER DELEGATE" "$ctx"

# --- resilience ---
out=$(echo 'not json at all' | "$S"; echo "rc=$?")
assert_contains "garbage input exits 0" "rc=0" "$out"
out=$(printf '' | "$S"; echo "rc=$?")
assert_contains "empty input exits 0" "rc=0" "$out"

finish
