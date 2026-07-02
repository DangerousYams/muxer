# muxer

A model multiplexer for Claude Code, packaged as a plugin. Keep an expensive orchestrator model (Fable) for what it's uniquely good at — planning, creative direction, running long jobs to completion — while routing the bulk of the token spend to cheaper models (Opus, Sonnet, Haiku) and to external models via the OpenAI Codex and Google Gemini CLIs.

## Why this shape

Claude Code decides "which model handles this subtask" at delegation time, in the orchestrator's head. The plugin pulls on all three levers that influence that decision:

1. **Model-pinned agents** (`agents/*.md`) — each delegate has a `model:` in its frontmatter, so its work bills at that model's rate regardless of what the main session runs on. This is the multiplexing mechanism.
2. **SessionStart hook** (`scripts/session-policy.sh`) — injects a short routing policy into every session so the orchestrator knows to delegate instead of doing. The policy adapts: Fable sessions get "you are premium-priced, keep the main loop lean"; cheaper sessions get an escalation path to Fable via `muxer:oracle`.
3. **PreToolUse guard** (`scripts/guard-model.sh`) — built-in subagents (general-purpose, Explore, Plan) inherit the *main* model when spawned without a model override. On a Fable session that silently bills exploration at premium rates. The guard injects `opus` (erring toward quality) whenever no model was explicitly chosen.

## Prime rule: quality first

Cost optimization happens *within* a quality constraint, never instead of it. The policy the plugin injects makes this explicit: route each task to the cheapest model that can do it to full quality, route up a tier when unsure, and never accept a below-bar result because escalating costs more. The delegation contract bans handing off big meaty tasks — work is decomposed into scoped briefs with acceptance criteria, repetitive work follows a verified exemplar built at a strong tier, everything passes through the reviewer, and a task that fails review twice at one tier is redone a tier up. The delegates enforce this from their side too: builder refuses under-scoped briefs, writer refuses work that needs judgment beyond text, and reviewer classifies failures as specification vs capability to drive escalation.

## The delegates

| Agent | Model | Role |
|---|---|---|
| `muxer:scout` | Haiku | Read-only recon: explore, find, summarize. |
| `muxer:writer` | Sonnet | Docs, copy, boilerplate, mechanical low-risk edits. |
| `muxer:builder` | Opus | Implementation and debugging workhorse. |
| `muxer:reviewer` | Opus | Adversarial verification of completed work. |
| `muxer:oracle` | Fable | Escalation tier: visual/creative direction, hardest decisions. |
| `muxer:codex` | external | Dispatches to OpenAI Codex CLI (`codex exec`). Zero Anthropic tokens. |
| `muxer:gemini` | external | Dispatches to Google Gemini CLI (`gemini -p`). Zero Anthropic tokens. |

## The economics

API list prices per 1M tokens (in/out): Fable $10/$50, Opus $5/$25, Sonnet $3/$15, Haiku $1/$5. On a Max plan where Fable bills as extra usage credits, every token moved off Fable and onto Opus/Sonnet/Haiku moves spend from open-ended credits to plan quota, and every token moved to Codex/Gemini leaves the Anthropic bill entirely.

Subagents run in their own context windows and bill at their own model's rates. The orchestrator pays its rate only for what flows through the main loop: its planning, the delegate reports it reads, its replies to you. Two consequences:

- Delegating isn't enough — the orchestrator must also *stop reading raw material*. Scout exists so 50k tokens of logs become a 300-word report before touching the Fable loop.
- Verification should also be delegated (`muxer:reviewer`), or the orchestrator re-reads every diff at premium rates.

## Two modes

- **Mode A — Fable orchestrates** (`/model fable`): preserves Fable's planning, visual taste, and run-until-done persistence. Premium billing applies only to the lean main loop. This is the default this plugin is tuned for.
- **Mode B — Opus orchestrates** (`/model opus`): maximum savings. Fable is consulted only through `muxer:oracle` for the moments that need it (creative direction, hard design calls). Costs roughly half per main-loop token and stays on plan quota.

## Cost reporting

Two halves, one before and one after:

- **Before (estimate, model-driven):** the injected policy tells the orchestrator to open any sizable multiplexed task with a one-line cost estimate: which tiers do what, a rough $ range at list prices, and the Fable-credits share. No hook can know a task's size in advance, so this half is advisory and approximate by nature.
- **After (measured, hook-driven):** a `Stop` hook parses the session transcript plus every subagent transcript, dedupes streamed rows, prices each turn at API list rates (cache reads at 0.1x, 5m cache writes at 1.25x, 1h at 2x input rate), and prints one line: actual spend (split into Fable extra-usage credits vs Max-plan quota) against the counterfactual where every token ran on the session's main model. It stays quiet until savings accumulated since the last report cross `MUXER_REPORT_MIN_USD` (default $0.25), so small turns never spam.

Example output:

```
muxer: this stretch cost ~$1.25 (~$0.00 Fable credits, ~$1.25 Max-quota) vs ~$3.95 un-muxed all-Fable. Saved ~$2.70 (68%).
```

What it can't see: work done through `muxer:codex` / `muxer:gemini` (bills externally, never appears in transcripts), and the fact that an un-muxed run would not have paid subagent context re-reads. Both cut in opposite directions; treat every figure as a `~` estimate at list prices.

## Install

```bash
git clone https://github.com/DangerousYams/muxer.git
claude plugin marketplace add ./muxer
claude plugin install muxer@muxer-local
```

Updating later: pull, bump nothing, just run `claude plugin update muxer@muxer-local`. Plugins are cached copies; repo edits do not take effect until you update, and running sessions keep the old copy until restarted.

External delegates need their CLIs:

```bash
npm install -g @openai/codex      # then run `codex` once to sign in (ChatGPT account)
npm install -g @google/gemini-cli # then run `gemini` once to sign in
```

## Tuning

- `MUXER_GUARD=off` — disable the PreToolUse default-model guard.
- `MUXER_BUILTIN_AGENT_MODEL=<alias>` — change the guard's injected default (default `opus`).
- `MUXER_REPORT=off` — disable the after-task cost line; `MUXER_REPORT=always` prints it after every turn that spent anything.
- `MUXER_REPORT_MIN_USD=<n>` — savings threshold for the cost line (default `0.25`).
- `/mux` — show routing table, cost model, and session economics from inside a session.

## Notes and limits

- Routing is advisory for the orchestrator (it chooses which agent to spawn); the hard guarantees are the per-agent `model:` pins and the PreToolUse guard.
- The orchestrator's own context (including prompt-cache re-reads) always bills at the session model's rate. If a session will be mostly reading and chatting rather than directing, run it on a cheaper model.
- Billing attribution for subagent models on Max plans is not explicitly documented by Anthropic; the per-model rates above are the API list prices. Watch `/usage` after adopting this to confirm behavior on your plan.
