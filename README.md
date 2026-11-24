# muxer

`muxer` is a Claude Code plugin that lets an expensive model run the session while cheaper models handle most of the actual work.

I built it because I want Fable planning my work and judging the results, yet Fable costs 2x Opus per token. Most of what happens during a coding session, such as searching files or reading logs, does not need the priciest model in the catalog. `muxer` keeps Fable on the main session loop and routes execution to Opus, Sonnet, and Haiku, or to OpenAI Codex and Google Gemini through their CLIs. A third external route sends work to Gemini Neon through the `agy` CLI, used only for user-facing product prose.

## Routing mechanisms

Claude Code picks a model for a subtask at the moment the orchestrator spawns it. `muxer` shapes that decision through 3 mechanisms:

- **Per-agent model pins (`agents/*.md`):** Each agent file in `agents/*.md` carries a `model:` line in its frontmatter. `muxer:scout` always runs on Haiku and `muxer:builder` always runs on Opus, regardless of which model runs the main session. Frontmatter pins are enforced directly by Claude Code as a hard guarantee.
- **SessionStart policy hook (`scripts/session-policy.sh`):** When a session starts, resumes, clears, or compacts, this hook injects a short routing policy telling the orchestrator to delegate work instead of doing everything itself. The script reads the active session model and adapts: a Fable session gets a reminder that the main loop is premium-priced and must stay lean, while sessions on cheaper models get 2 routes up to Fable, preferring `muxer:arbiter` when a quick verdict is all it needs and escalating to `muxer:oracle` for deep work.
- **PreToolUse guard (`scripts/guard-model.sh`):** Claude Code's built-in subagents (`general-purpose`, `Explore`, `Plan`) inherit the main session's model when spawned without an override. On a Fable session, that default causes built-in file exploration to bill at premium rates. The guard intercepts only those built-in subagent types when spawned without an explicit model, never touching `muxer`'s own agents, and pins them to `MUXER_BUILTIN_AGENT_MODEL` (default `opus`). Because the guard does not inspect the session model, it applies that pin in every session, including sessions running on Sonnet or Haiku.

## Session modes

You can run `muxer` in 2 modes depending on how much you want to spend on the main loop.

**Mode A (Fable session):** I tuned the plugin for this setup. Start the session with `/model fable` and let Fable orchestrate. You keep Fable's planning and visual taste, along with its habit of staying with a job until it is actually done, while Fable's per-token rate applies only to the lean main loop.

**Mode B (Opus session):** For maximum savings, run the main loop on Opus with `/model opus`. Consult Fable when a task genuinely needs it, starting with `muxer:arbiter` when a quick verdict is all you need and escalating to `muxer:oracle` for deep work such as creative direction or a hard design call. Main-loop tokens cost half as much at list price.

## Pricing and subagent billing

These are Anthropic's API list prices per 1M tokens:

| Model | List price per 1M tokens (in/out) |
|---|---|
| Fable | $10/$50 |
| Opus | $5/$25 |
| Sonnet | $3/$15 |
| Haiku | $1/$5 |

Fable is the most expensive model at 2x Opus per token ($10/$50 against $5/$25), so at list prices moving tokens off Fable brings an Opus token to 50% of Fable's cost, with Sonnet at 30% and Haiku at 10%. Work routed to Codex or Gemini leaves the Anthropic bill altogether, and the same applies to the Gemini Neon generation step of `muxer:neon` (its Opus verification pass still bills on Anthropic).

Subagents run in their own context windows and bill at their own model's rate. The orchestrator pays its session rate only for what enters the main loop: its plans and replies to you, plus the reports delegates send back. To keep main-loop spend low, the orchestrator has to both delegate work and avoid reading raw material directly. `muxer:scout` handles that by condensing something like 50k tokens of logs into a 300-word report before anything reaches the Fable loop. `muxer:reviewer` applies the same idea to review, reading diffs on Opus so the main loop does not re-read them at premium rates.

## Quality and delegation rules

The injected policy sets a clear priority: pick the cheapest model that can complete a task to full quality, and step up a tier when in doubt. Cheap output that falls short costs more to redo than the tokens saved on the first attempt.

The injected policy instructs the orchestrator to follow several advisory rules:

- Large tasks are never handed off whole. The orchestrator decomposes them into scoped briefs with acceptance criteria.
- For repetitive work such as a port or migration, one exemplar is built at a strong tier and verified before anything fans out.
- Completed work goes through `muxer:reviewer`. A task that fails review twice at one tier gets redone a tier up with a fresh brief.
- Taste-critical work (UI, CSS, game feel) never goes below Opus, regardless of cost hints.
- The verifier is never a cheaper model than the builder it judges. Both rules exist because a cheap model can produce visually flawed output that an equally cheap reviewer fails to catch.

The delegates enforce quality on their side as well. `muxer:builder` refuses briefs that are under-scoped instead of guessing through them, and `muxer:writer` sends back any task that turns out to need real judgment. When `muxer:reviewer` flags a failure, it labels the cause as either a spec problem or a capability problem so the orchestrator knows whether to fix the brief or change the model.

## Delegates

| Agent | Model | Role |
|---|---|---|
| `muxer:scout` | Haiku | Read-only recon: search files and summarize findings. |
| `muxer:runner` | Haiku | Run builds, tests, and dev servers; return condensed pass/fail output with the error lines that matter. |
| `muxer:writer` | Sonnet | Documentation, copy, boilerplate, and mechanical low-risk edits. |
| `muxer:pilot` | Sonnet | Drive browser or app flows and capture screenshots and GIFs to files. Requires a connected browser MCP. |
| `muxer:researcher` | Sonnet | Web research with named sources. |
| `muxer:builder` | Opus | Implementation and debugging. |
| `muxer:reviewer` | Opus | Adversarial verification of completed work. |
| `muxer:arbiter` | Fable, low effort | Quick top-tier verdicts on plans, design calls, and taste checks. |
| `muxer:oracle` | Fable | Escalation tier for visual or creative direction and the hardest decisions. |
| `muxer:codex` | external | Dispatches to OpenAI Codex CLI (`codex exec`), using zero Anthropic tokens. |
| `muxer:gemini` | external | Dispatches to Google Gemini CLI (`gemini -p`), using zero Anthropic tokens. |
| `muxer:neon` | Opus + external | User-facing product prose written by Gemini Neon through the `agy` CLI, verified for factual accuracy by an Opus checker that leaves the wording alone. |

### muxer:arbiter

`muxer:arbiter` runs the same Fable model as `muxer:oracle`, paired with `effort: low` in its frontmatter (a field agent definitions support alongside `model:`). The `effort` setting scales how many thinking tokens the model spends while leaving per-token rates unchanged, so a low-effort Fable call costs a fraction of a full `muxer:oracle` consultation and keeps Fable's judgment. On verdict-shaped questions, such as checking whether a UI matches a theme or whether a plan is sound, low-effort Fable tends to beat Opus, which uses far more thinking tokens to reach a worse call.

Fable input still costs double Opus input ($10 vs $5 per 1M tokens), so `muxer:arbiter` should receive a condensed question instead of a pile of files.

### muxer:neon

`muxer:neon` handles text that users read in the shipped product: page copy, UI strings, error and empty states, and store pages. Gemini Neon writes the copy through the `agy` CLI in its own voice, and an Opus checker verifies every string against the brief. Every claim must trace to a fact stated in the brief, and all limits and placeholders must hold. Neon never guesses: when the brief lacks a fact, it writes the string without that fact if the string can still do its job, and otherwise leaves a marker where the fact would go.

A string that fails verification returns to Neon in the same conversation with the defect named, for up to 2 revision rounds. The Opus checker has no say on style and never rewrites wording, because preserving Neon's voice is the reason to use this delegate. Because `agy`'s print mode writes files without asking, Neon runs from an empty temporary folder with the context quoted into its brief. The session policy lists `muxer:neon` only when `agy` is on `PATH`. When `agy` is present, the policy routes all user-facing product prose to `muxer:neon` while `muxer:writer` keeps docs, READMEs, comments, and commit messages; when `agy` is absent, copy stays with `muxer:writer`. If `agy` is installed yet `muxer:neon` reports that `agy` or the Neon model is unavailable, the orchestrator tells you and does not fall back to Claude-written copy on its own.

## Cost reporting

`muxer` gives you a pre-task estimate from the orchestrator and a measured receipt from a `Stop` hook afterward.

Before starting any sizable multiplexed task, the injected policy instructs the orchestrator to print a single-line estimate with a rough list-price dollar range for the whole task, stating both which tiers will do what and how much of that total is Fable. That estimate is labeled as a guess, since no hook can know a task's size before the work runs.

After work finishes, a `Stop` hook runs `scripts/report-cost.sh` with no argument to compute the receipt. It parses the session transcript along with every subagent transcript and deduplicates rows that Claude Code writes repeatedly while streaming. Each turn is then priced at API list rates with cache multipliers applied (cache reads at 0.1x the input rate, 5-minute cache writes at 1.25x, and 1-hour cache writes at 2x). The hook prints one line breaking actual spend down by model against the counterfactual where every token ran on the session's main model. It stays silent until savings accumulated since its last report cross `MUXER_REPORT_MIN_USD` (default `$0.25`), so small turns do not clutter the output.

```
muxer: this stretch cost ~$1.25 (opus $0.58 + haiku $0.68) vs ~$3.95 all-opus. Saved ~$2.70 (68%).
```

The same script runs as a `SessionStart` hook with the argument `baseline`, snapshotting the transcript's running totals whenever a session starts, resumes, or clears. Without that baseline, the first report of a resumed session would bill the transcript's entire history to "this stretch", which can add up to hundreds of dollars in a long-lived session. If the baseline is missing, the first `Stop` call sets it silently without printing a report.

The receipt has 2 blind spots. Work run through `muxer:codex` or `muxer:gemini` bills externally and never appears in Claude Code transcripts, so it is absent here; the same applies to the Neon half of `muxer:neon`, while its Opus checker is counted. In addition, the un-muxed counterfactual is approximate because a single-model run would not have paid for subagents re-reading context. Every figure is a rough estimate at list prices and does not reflect an invoice.

## Installation

Install the plugin from a local clone:

```bash
git clone https://github.com/DangerousYams/muxer.git
claude plugin marketplace add ./muxer
claude plugin install muxer@muxer-local
```

The hook scripts require `bash` and `jq`.

### Updating

To update later, pull the latest commits and run `claude plugin update muxer@muxer-local`. Claude Code installs plugins as cached copies, so edits in the repo do nothing until you run that update command.

Agent definitions and skills load at session start, as does the injected policy, whereas hook commands resolve the plugin path when they fire. Updated hook scripts therefore take effect immediately in already-running sessions even though their `SessionStart` hooks do not re-fire. The cost hook validates its saved state before using it so it handles that mid-session transition safely.

### Prerequisites

The Codex and Gemini delegates need their CLIs installed and signed in:

```bash
npm install -g @openai/codex      # then run `codex` once to sign in (ChatGPT account)
npm install -g @google/gemini-cli # then run `gemini` once to sign in
```

`muxer:neon` requires the `agy` CLI installed and signed in, with a Neon model showing in `agy models`.

`muxer:pilot` requires browser tools in the session. Normally that is the Claude in Chrome extension, though any browser MCP such as Playwright also works. When no browser tool is connected, `muxer:pilot` stops and reports the missing prerequisite without driving anything.

## Configuration

- `MUXER_GUARD=off`: turns off the PreToolUse default-model guard.
- `MUXER_BUILTIN_AGENT_MODEL=<alias>`: changes the model alias that the guard injects (default `opus`).
- `MUXER_REPORT=off`: silences the after-task cost line.
- `MUXER_REPORT=always`: prints the cost line after every turn that spent anything.
- `MUXER_REPORT_MIN_USD=<n>`: sets the savings threshold for the cost line (default `0.25`).

Inside a session, `/mux` shows the routing table along with the cost model and session economics.

## Limits

- Routing is advisory for the orchestrator, since it chooses which agent to spawn. The hard guarantees are the per-agent `model:` pins and the PreToolUse guard.
- The orchestrator's own context, including prompt-cache re-reads, always bills at the session model's rate. If a session will be mostly reading and chatting instead of directing work, run it on a cheaper model from the start.
- `muxer` prices everything at API list rates and does not know how a subscription plan counts usage. If you are on a plan, watch `/usage` to see the effect on your own plan.

## Tests

A hermetic test suite covers the plugin manifests and the 3 hook scripts (`scripts/session-policy.sh`, `scripts/guard-model.sh`, `scripts/report-cost.sh`). Run it from the repo root:

```bash
tests/run.sh            # every suite
tests/run.sh report     # only suites whose filename matches "report"
```

The optional argument is a name filter, so `tests/run.sh guard` runs only the guard-model checks. A passing run prints `ALL GREEN`.

Dependencies are `bash` and `jq`, the same tools the hooks themselves need. When the `claude` CLI is on your `PATH`, the manifest suite also runs `claude plugin validate`, and skips that single check cleanly when `claude` is absent.

The tests never touch your real setup. Every invocation overrides `HOME` to a throwaway directory and strips `MUXER_*` from the environment, leaving `~/.cache/muxer` and your shell config untouched.
