# muxer

A Claude Code plugin that lets an expensive model run the session while cheaper models do most of the actual work.

I built this because Fable is the model I want planning my work and judging the results, but on a Max plan it bills as extra usage credits with no ceiling. Meanwhile most of what happens in a coding session (grepping through files, writing boilerplate, reading logs) doesn't need the priciest model in the catalog. muxer keeps Fable in the director's chair and pushes the typing down to Opus, Sonnet, and Haiku, or out to OpenAI Codex and Google Gemini through their CLIs.

## How it works

Claude Code picks a model for a subtask at the moment the orchestrator spawns it. muxer leans on that decision from three directions.

The agents in `agents/*.md` each carry a `model:` line in their frontmatter, so the scout always runs on Haiku and the builder always runs on Opus no matter what the main session runs on. This is where the actual multiplexing happens, and it's a hard guarantee rather than a suggestion.

A SessionStart hook (`scripts/session-policy.sh`) injects a short routing policy into every session so the orchestrator knows to delegate instead of doing everything itself. The policy reads the session model and adapts. On Fable it says: you're premium-priced, keep the main loop lean. On cheaper models it adds an escalation path up to Fable through `muxer:oracle`.

The third piece is a PreToolUse guard (`scripts/guard-model.sh`). Claude Code's built-in subagents (general-purpose, Explore, Plan) inherit the main session's model when spawned without an override, which on a Fable session means your file exploration quietly bills at premium rates. The guard catches those spawns and pins them to `opus` unless a model was chosen explicitly.

## Quality first

The injected policy is blunt about priorities: pick the cheapest model that can do the task to full quality, and when in doubt go up a tier, not down. Cheap work that comes back below the bar defeats the whole point, since redoing it costs more than the tokens saved.

So big meaty tasks never get handed off whole. The orchestrator decomposes them into scoped briefs with acceptance criteria, and for repetitive work like a port or migration, one exemplar gets built at a strong tier and verified before anything fans out. Completed work goes through the reviewer, and a task that fails review twice at one tier gets redone a tier up with a fresh brief. Taste-critical work (UI, CSS, game feel) never goes below Opus regardless of cost hints, and the verifier is never a cheaper model than the builder it's judging. Both rules exist because the failure mode is real: a cheap model builds something visually off, and an equally cheap reviewer can't see what's wrong with it.

The delegates hold up their end too. The builder refuses briefs that are under-scoped rather than winging them, and the writer bounces anything that turns out to need real judgment. The reviewer labels each failure as either a spec problem or a capability problem, so the orchestrator knows whether to fix the brief or change the model.

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

## Where the money goes

API list prices per 1M tokens (in/out): Fable $10/$50, Opus $5/$25, Sonnet $3/$15, Haiku $1/$5. On a Max plan, Fable bills as extra usage credits while the rest draw from plan quota, so every token moved off Fable turns open-ended spend into quota spend. Tokens moved to Codex or Gemini leave the Anthropic bill entirely.

Subagents run in their own context windows and bill at their own model's rate. The orchestrator pays its premium rate only for what passes through the main loop: its plans, the reports it reads back, its replies to you. Which is why delegating the work is only half the job. The orchestrator also has to stop reading raw material, and that's what the scout is for, turning 50k tokens of logs into a 300-word report before anything touches the Fable loop. Same reasoning behind the reviewer: it reads the diffs so the main loop doesn't re-read them at premium rates.

## Two ways to run it

Mode A is what the plugin is tuned for. Run the session on Fable (`/model fable`) and let it orchestrate. You keep Fable's planning, its visual taste, and its habit of running a job until it's actually done, while premium billing applies only to the lean main loop.

Mode B is for maximum savings. Run the session on Opus (`/model opus`) and consult Fable only through `muxer:oracle` when something genuinely needs it, like creative direction or a hard design call. Main-loop tokens cost roughly half and stay on plan quota.

## Cost reporting

You get an estimate before and a receipt after.

The estimate comes from the orchestrator itself. The policy tells it to open any sizable multiplexed task with a single line covering which tiers will do what, a rough dollar range at list prices, and how much of that is Fable credits. It's a guess, labeled as one. No hook can know a task's size before the work runs.

The receipt is measured. A `Stop` hook parses the session transcript plus every subagent transcript, dedupes the rows Claude Code writes repeatedly while streaming, and prices each turn at API list rates, cache-aware (cache reads at 0.1x the input rate, 5-minute cache writes at 1.25x, 1-hour writes at 2x). It then prints one line breaking actual spend down by model, with the Fable share tagged as extra-usage credits, against the counterfactual where every token ran on the session's main model. It stays quiet until the savings accumulated since its last report cross `MUXER_REPORT_MIN_USD` (default $0.25), so small turns never spam you.

```
muxer: this stretch cost ~$1.25 (opus $0.58 + haiku $0.68) vs ~$3.95 all-opus. Saved ~$2.70 (68%).
```

A SessionStart hook records the transcript's running totals as a baseline whenever a session starts, resumes, or clears. Without that, the first report of a resumed session would bill the transcript's entire history to "this stretch", and a long-lived session can carry hundreds of dollars of it. If the baseline is ever missing, the first Stop sets it silently instead of reporting.

Two blind spots worth knowing about. Work done through `muxer:codex` or `muxer:gemini` bills externally and never appears in the transcripts, so it's invisible here. And the un-muxed counterfactual is approximate, because a single-model run wouldn't have paid for subagents re-reading context. Read every figure as a rough number at list prices, not an invoice.

## Install

```bash
git clone https://github.com/DangerousYams/muxer.git
claude plugin marketplace add ./muxer
claude plugin install muxer@muxer-local
```

To update later, pull and run `claude plugin update muxer@muxer-local`. Claude Code installs plugins as cached copies, so edits to the repo do nothing until you update. One wrinkle worth knowing: agents, skills, and the injected policy load when a session starts, but hook commands resolve the plugin path at the moment they fire, so updated hook scripts take effect in already-running sessions immediately, without their SessionStart hooks ever re-firing. The cost hook is written to survive that (it validates its saved state before using it).

The external delegates need their CLIs installed and signed in:

```bash
npm install -g @openai/codex      # then run `codex` once to sign in (ChatGPT account)
npm install -g @google/gemini-cli # then run `gemini` once to sign in
```

## Tuning

- `MUXER_GUARD=off` turns off the PreToolUse default-model guard.
- `MUXER_BUILTIN_AGENT_MODEL=<alias>` changes what the guard injects (default `opus`).
- `MUXER_REPORT=off` silences the after-task cost line. `MUXER_REPORT=always` prints it after every turn that spent anything.
- `MUXER_REPORT_MIN_USD=<n>` sets the savings threshold for the cost line (default `0.25`).
- `/mux` shows the routing table, cost model, and session economics from inside a session.

## Notes and limits

Routing is advisory for the orchestrator, since it chooses which agent to spawn. The hard guarantees are the per-agent `model:` pins and the PreToolUse guard.

The orchestrator's own context, including prompt-cache re-reads, always bills at the session model's rate. If a session will be mostly reading and chatting rather than directing work, run it on a cheaper model to begin with.

Anthropic doesn't explicitly document how subagent models bill against Max plans, and the per-model rates above are API list prices. Watch `/usage` after adopting this and confirm the behavior on your own plan.

## Tests

A hermetic test suite covers the three hook scripts and the plugin manifests. Run it from the repo root:

```bash
tests/run.sh            # every suite
tests/run.sh report     # only suites whose filename matches "report"
```

The optional argument is a name filter, so `tests/run.sh guard` runs just the guard-model checks. A green run prints `ALL GREEN`.

Dependencies are bash and jq, the same tools the hooks themselves need. The manifest suite additionally runs `claude plugin validate` when the claude CLI is on your PATH, and skips that single check cleanly when it isn't.

The tests never touch your real setup. Every invocation overrides `HOME` to a throwaway directory and strips `MUXER_*` from the environment, so the live `~/.cache/muxer` and your shell config are left alone.
