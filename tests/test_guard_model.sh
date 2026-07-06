#!/bin/bash
# guard-model.sh: pin built-in subagents to a cheap model when none was chosen,
# stay out of the way when a model is explicit or the subagent isn't a built-in.
# MUXER_GUARD / MUXER_BUILTIN_AGENT_MODEL are stripped from the environment so the
# developer's shell can never leak config into the assertions.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/helpers.sh"
S="$here/../scripts/guard-model.sh"

run() { # raw-json-input
  printf '%s' "$1" | env -u MUXER_GUARD -u MUXER_BUILTIN_AGENT_MODEL "$S"
}

# --- injects a default model for built-in subagents with no model ---
out=$(run '{"tool_input":{"subagent_type":"general-purpose"}}')
assert_valid_json "no-model general-purpose emits valid JSON" "$out"
assert_jq "no-model general-purpose is allowed" '.hookSpecificOutput.permissionDecision' "allow" "$out"
assert_jq "no-model general-purpose injects opus" '.hookSpecificOutput.updatedInput.model' "opus" "$out"
assert_contains "reason attributes the change to muxer" "muxer" "$out"

out=$(run '{"tool_input":{"subagent_type":"Explore"}}')
assert_jq "no-model Explore injects opus" '.hookSpecificOutput.updatedInput.model' "opus" "$out"

out=$(run '{"tool_input":{}}')
assert_jq "missing subagent_type still injects opus" '.hookSpecificOutput.updatedInput.model' "opus" "$out"
assert_jq "missing subagent_type is allowed" '.hookSpecificOutput.permissionDecision' "allow" "$out"

# --- stays silent when it should ---
assert_silent "explicit model is left untouched" "$(run '{"tool_input":{"model":"haiku","subagent_type":"general-purpose"}}')"
assert_silent "non-built-in subagent is left untouched" "$(run '{"tool_input":{"subagent_type":"muxer:scout"}}')"
assert_silent "MUXER_GUARD=off disables the guard" \
  "$(printf '%s' '{"tool_input":{"subagent_type":"general-purpose"}}' | env -u MUXER_BUILTIN_AGENT_MODEL MUXER_GUARD=off "$S")"

# --- the injected default is configurable ---
out=$(printf '%s' '{"tool_input":{"subagent_type":"Explore"}}' | env -u MUXER_GUARD MUXER_BUILTIN_AGENT_MODEL=sonnet "$S")
assert_jq "MUXER_BUILTIN_AGENT_MODEL overrides the default" '.hookSpecificOutput.updatedInput.model' "sonnet" "$out"

# --- resilience ---
out=$(run 'garbage' 2>/dev/null; echo "rc=$?")
assert_contains "garbage input exits 0" "rc=0" "$out"
assert_silent "garbage input is silent" "$(run 'garbage' 2>/dev/null)"

finish
