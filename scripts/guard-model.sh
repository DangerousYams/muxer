#!/bin/bash
# muxer PreToolUse guard for the Agent/Task tool.
# Built-in subagents (general-purpose, Explore, Plan) inherit the MAIN model when
# no model is specified - on a Fable session that silently bills subagent work at
# premium rates. This hook injects a cheap default model when none was chosen.
#
# Config:
#   MUXER_GUARD=off                   disable entirely
#   MUXER_BUILTIN_AGENT_MODEL=sonnet  change the injected default (default: opus -
#                                     quality-first: err toward the stronger model)
#
# Fail-open: on any problem, emit nothing and let the call proceed unchanged.
set -u

[ "${MUXER_GUARD:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

model=$(printf '%s' "$input" | jq -r '.tool_input.model // ""' 2>/dev/null) || exit 0
[ -n "$model" ] && exit 0   # an explicit model was chosen; respect it

subtype=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null) || exit 0

case "$subtype" in
  general-purpose|Explore|Plan|claude|"")
    default_model="${MUXER_BUILTIN_AGENT_MODEL:-opus}"
    printf '%s' "$input" | jq -c --arg m "$default_model" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: ("muxer: built-in subagent had no model override; defaulted to " + $m + ". Set model explicitly to override, or MUXER_GUARD=off to disable."),
        updatedInput: (.tool_input + {model: $m})
      }
    }'
    ;;
esac
exit 0
