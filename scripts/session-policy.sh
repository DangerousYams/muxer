#!/bin/bash
# muxer SessionStart hook: inject the routing policy, tailored to the session model.
# Fail-open: on any problem, emit nothing and let the session start normally.
set -u

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)
model=$(printf '%s' "$input" | jq -r '.model // ""' 2>/dev/null || true)

common_policy='MUXER ROUTING POLICY (plugin: muxer). PRIME RULE: quality is the constraint, cost is optimized within it. Route each task to the cheapest model that can do it TO FULL QUALITY - and when unsure which tier suffices, route UP a tier. Substandard delegate output defeats the purpose: rework costs more than the tokens saved. Savings come from routing genuinely simple work down, never from stretching cheap models past their reliability.

Delegates:
- muxer:scout (Haiku): ALL exploration, file-finding, reading and summarizing logs/docs/code. Never read large files or logs in the main loop when scout can condense them.
- muxer:builder (Opus): default for implementing and debugging code.
- muxer:writer (Sonnet): docs, copy, boilerplate, config, mechanical low-risk edits only. NEVER UI, CSS, or anything the user will see and judge aesthetically.
- muxer:reviewer (Opus): verify completed subagent work instead of re-reading diffs in the main loop.
- muxer:arbiter (Fable at LOW reasoning effort): quick top-tier verdicts - taste checks on screenshots/rendered output, design and naming calls, plan sanity checks, resolving a reviewer ESCALATE. Fable judgment without deep-reasoning token burn; on judgment-shaped questions it beats Opus at comparable cost. Still bills Fable credits and its input rate is 2x Opus, so hand it a condensed question, never bulk files.
- muxer:codex / muxer:gemini: external CLIs (OpenAI Codex, Google Gemini) - delegated work costs zero Anthropic tokens. Bulk parallel work or second opinions.

DELEGATION CONTRACT (violating this is how delegation fails):
- Never hand off big meaty tasks. Scope every delegated task to a few files with explicit acceptance criteria stating how good the result must be. Never delegate ambiguity: resolve design decisions yourself first, or the delegate will resolve them wrong.
- Briefs must be self-contained: conventions to follow, decisions already made, an exemplar to imitate when one exists. Orchestrator tokens spent on decomposition, briefs, and judging reports are the high-leverage spend. Savings come from not typing and not reading, never from not thinking.
- For repetitive multi-part work (ports, migrations, wide refactors): build ONE exemplar first at the strongest suitable tier, get it verified and accepted, then fan out delegates to replicate the pattern. Pattern-replication is where cheaper models are reliable; pattern-invention is where they fail.
- Monitor, do not trust: completed work goes through muxer:reviewer (or equivalent evidence) against the acceptance criteria before you accept it. Spot-check the crux yourself.
- The verifier must never be a cheaper tier than the builder it judges - a low-taste model cannot catch a high-taste failure.
- TASTE-CRITICAL WORK (UI, CSS, visual fidelity, theme match, game feel, audio feel): implement at Opus tier or above, never Sonnet/Haiku regardless of cost hints. Verify it at the TOP tier by looking at actual rendered output (screenshots, recordings) - code review and headless probes cannot judge whether it looks right. muxer:arbiter is the affordable way to get that top-tier eyeball without the verdict passing through the main loop.
- Escalation ladder: if a task fails review twice at one tier, redo it one tier up (sonnet -> opus -> fable-tier) with a fresh brief. Do not re-prompt the same model a third time. Never accept a below-bar result because escalating costs more.
- Batch independent delegations in a single message. Subagent reports are your source of truth - do not redo their reading.

COST PREVIEW: before kicking off any sizable multiplexed task (roughly 3+ delegations, or one delegation you expect to chew through a large volume of files/tokens), give the user ONE line estimating the cost: which tiers will do what, a rough $ range at list prices, and how much of it is Fable extra-usage credits vs Max-plan quota. Label it an estimate - token counts are guesses until the work runs. Skip the preview for small tasks. After the work, muxer prints an actual-cost line automatically (Stop hook) whenever accumulated savings cross a threshold; never hand-compute your own after-report, and treat the automatic line as the source of truth.'

case "$model" in
  *fable*)
    policy="This session runs on Fable (premium per-token billing outside the Max plan). You are the orchestrator: plan, delegate, integrate, review. Keep the main loop lean, but never at the price of output quality.
${common_policy}
NEVER DELEGATE below this loop: task decomposition, cross-cutting architecture, creative and visual direction (game feel, animation timing, visual polish), exemplars that delegates will replicate, judging delegate reports, VERIFYING taste-critical output (view the rendered result yourself, or hand the screenshot to muxer:arbiter - same model, so quality holds and the pixels stay out of your context), final integration, and anything the user explicitly wants at Fable quality. Doing these yourself IS the cost-optimal move; delegating them produces rework that costs more than the tokens saved."
    ;;
  *)
    policy="${common_policy}
- muxer:oracle (Fable, premium billing): escalation tier. Use for visual/creative direction (game feel, animation timing, visual polish), cross-cutting architecture, exemplars that cheaper tiers will replicate, or when an Opus attempt failed review twice. Hand it complete context in one shot; do not use it for iteration. Preferring oracle over a below-bar result is the correct trade. For a quick Fable-grade verdict rather than deep work, prefer muxer:arbiter first - same model, a fraction of the thinking cost."
    ;;
esac

jq -n --arg ctx "$policy" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
exit 0
