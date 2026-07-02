---
name: mux
description: Show the muxer routing table, cost model, and current session economics. Use when the user asks how work is being routed across models, what something costs, or how to tune the multiplexer.
user-invocable: true
argument-hint: "[question about routing or cost]"
---

# muxer — model multiplexer status and doctrine

When invoked, do the following:

1. State which model this session's main loop runs on (you know your own model) and what that implies: Fable main loop = premium extra-usage billing, so delegation matters most; Opus or below = Max-plan quota, delegation still saves quota but the stakes are lower.
2. Print the routing table and cost table below, then answer the user's question (the skill argument) if one was given.
3. Keep it brief and factual. No advice they didn't ask for.

## Prime rule

Quality is the constraint, cost is optimized within it. Route each task to the cheapest model that can do it to full quality; when unsure, route up a tier. Substandard delegate output defeats the purpose — rework costs more than the tokens saved. Big meaty tasks are never delegated whole: decompose, brief with acceptance criteria, build one exemplar at a strong tier, fan out the pattern, and verify everything through the reviewer.

## Routing table

| Delegate | Model | Use for |
|---|---|---|
| muxer:scout | Haiku | Exploration, file-finding, reading and summarizing logs/docs/code. Read-only. |
| muxer:writer | Sonnet | Docs, copy, boilerplate, config, mechanical low-risk edits. |
| muxer:builder | Opus | Implementing and debugging code. The default for code changes. |
| muxer:reviewer | Opus | Verifying completed work against the original intent. Read-only. |
| muxer:oracle | Fable | Escalation: visual/creative direction, hardest design decisions. Premium billing — one shot, full context. |
| muxer:codex | external | OpenAI Codex CLI. Work bills to the user's OpenAI account, zero Anthropic tokens. |
| muxer:gemini | external | Google Gemini CLI. Work bills to the user's Google account, zero Anthropic tokens. Huge-context summarization. |

## Cost table (API list prices per 1M tokens, in/out)

| Model | Input | Output | Billing on a Max plan |
|---|---|---|---|
| Fable 5 | $10 | $50 | Extra usage credits (outside Max plan) |
| Opus 4.8 | $5 | $25 | Max plan quota |
| Sonnet 5 | $3 | $15 | Max plan quota |
| Haiku 4.5 | $1 | $5 | Max plan quota |

Key economics: subagents run in their own context and bill at their own model's rate. The orchestrator pays its own rate only for the tokens that pass through the main loop — its plans, the delegate reports it reads, and its own prose. So the cost lever is keeping the main loop lean, not just picking cheap subagents.

## Cost reporting

- Before: for sizable multiplexed tasks (3+ delegations or one large one), the orchestrator states a one-line $ estimate up front (tiers, rough range, Fable-credits share). It is an estimate; actuals come from the hook below.
- After: a Stop hook parses the session and subagent transcripts, prices every turn at API list rates (cache-aware), and prints one line comparing actual spend to the un-muxed all-main-model cost, split into Fable extra-usage credits vs Max-plan quota. It stays silent until accumulated savings since the last report cross the threshold, so small turns don't spam.
- Not counted: muxer:codex / muxer:gemini work (external billing, invisible to transcripts) and the token overhead the un-muxed counterfactual would not have had (subagents re-read context). Figures are estimates at list prices, marked with `~`.

## Tuning

- `MUXER_GUARD=off` — disable the PreToolUse hook that assigns a default model to built-in subagents (general-purpose, Explore, Plan) when none was chosen.
- `MUXER_BUILTIN_AGENT_MODEL=<alias>` — change that default (default: opus, erring toward quality).
- `MUXER_REPORT=off` — disable the after-task cost line. `MUXER_REPORT=always` — print it after every turn that spent anything, ignoring the threshold.
- `MUXER_REPORT_MIN_USD=<n>` — savings threshold that triggers a report (default 0.25).
- Mode A (what this plugin is tuned for): run the session on Fable (`/model fable`), delegate everything. Preserves Fable's orchestration, planning, and persistence; premium billing applies to the main loop only.
- Mode B (max savings): run the session on Opus (`/model opus`), escalate selectively to muxer:oracle. Fable billing applies only to oracle calls.
