#!/bin/bash
# report-cost.sh: baseline records totals silently; report mode prints this stretch's
# spend vs the all-main-model counterfactual, but only once savings clear a threshold.
# HOME is overridden to a throwaway dir on EVERY invocation so the real ~/.cache/muxer
# is never read or written, and MUXER_REPORT* are stripped unless a case sets them.
#
# Prices per 1M tokens (in/out): fable 10/50, opus 5/25, sonnet 3/15, haiku 1/5;
# cache reads price at 0.1x the input rate. The fixtures below are chosen so every
# figure is hand-checkable:
#   main transcript  = fable 1000/1000            -> $0.06
#   subagent (big)   = haiku 100000/100000        -> $0.60  (at fable rates $6.00)
#   actual $0.66, all-fable counterfactual $6.06, saved $5.40 (89%).
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/helpers.sh"
S="$here/../scripts/report-cost.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"; mkdir -p "$home"
statedir="$home/.cache/muxer"; mkdir -p "$statedir"

# --- fixtures (jq -nc per line, one row = one assistant turn with usage) ---
main_row() { # file
  jq -nc '{type:"assistant",message:{id:"m1",model:"claude-fable-5",usage:{input_tokens:1000,output_tokens:1000}}}' > "$1"
}
sub_dir() { printf '%s/subagents' "${1%.jsonl}"; }   # transcript -> its subagent dir

# big: main + one haiku delegation (100k/100k)
main_row "$tmp/big.jsonl"
mkdir -p "$(sub_dir "$tmp/big.jsonl")"
jq -nc '{type:"assistant",message:{id:"a1",model:"claude-haiku-4-5",usage:{input_tokens:100000,output_tokens:100000}}}' \
  > "$(sub_dir "$tmp/big.jsonl")/agent-001.jsonl"

# solo: main only, no subagents dir at all (zero delegations)
main_row "$tmp/solo.jsonl"

# small: main + a tiny haiku delegation (1k/1k) -> actual $0.066, counter $0.12
main_row "$tmp/small.jsonl"
mkdir -p "$(sub_dir "$tmp/small.jsonl")"
jq -nc '{type:"assistant",message:{id:"a1",model:"claude-haiku-4-5",usage:{input_tokens:1000,output_tokens:1000}}}' \
  > "$(sub_dir "$tmp/small.jsonl")/agent-001.jsonl"

# dedup: same id twice, a huge first row then the normal one; last row must win
main_row "$tmp/dedup.jsonl"
mkdir -p "$(sub_dir "$tmp/dedup.jsonl")"
{
  jq -nc '{type:"assistant",message:{id:"a1",model:"claude-haiku-4-5",usage:{input_tokens:999999,output_tokens:999999}}}'
  jq -nc '{type:"assistant",message:{id:"a1",model:"claude-haiku-4-5",usage:{input_tokens:100000,output_tokens:100000}}}'
} > "$(sub_dir "$tmp/dedup.jsonl")/agent-001.jsonl"

# cache: big delegation plus a cache-read-only row (+$0.10 actual)
main_row "$tmp/cache.jsonl"
mkdir -p "$(sub_dir "$tmp/cache.jsonl")"
{
  jq -nc '{type:"assistant",message:{id:"a1",model:"claude-haiku-4-5",usage:{input_tokens:100000,output_tokens:100000}}}'
  jq -nc '{type:"assistant",message:{id:"a2",model:"claude-haiku-4-5",usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:1000000}}}'
} > "$(sub_dir "$tmp/cache.jsonl")/agent-001.jsonl"

hookinput() { printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2"; }
base()   { hookinput "$1" "$2" | env -u MUXER_REPORT -u MUXER_REPORT_MIN_USD HOME="$home" "$S" baseline; }
report() { hookinput "$1" "$2" | env -u MUXER_REPORT -u MUXER_REPORT_MIN_USD HOME="$home" "$S"; }
zero()   { jq -n '{a:0,c:0,fable:0,opus:0,sonnet:0,haiku:0}' > "$statedir/$1.json"; }

# --- 1. baseline records totals silently ---
out=$(base s1 "$tmp/big.jsonl")
assert_silent "baseline mode says nothing" "$out"
st=$(cat "$statedir/s1.json")
assert_valid_json "baseline writes a state file" "$st"
assert_jq "baseline records actual spend" '.a*100|round/100' "0.66" "$st"
assert_jq "baseline records the all-fable counterfactual" '.c*100|round/100' "6.06" "$st"

# --- 2. report with no prior state sets the baseline instead of speaking ---
out=$(report s2 "$tmp/big.jsonl")
assert_silent "first report without a baseline stays silent" "$out"
assert_valid_json "first report sets the baseline" "$(cat "$statedir/s2.json")"

# --- 3. report after a zero baseline speaks the full line ---
zero s34
out=$(report s34 "$tmp/big.jsonl")
assert_valid_json "report after a zero baseline emits valid JSON" "$out"
msg=$(printf '%s' "$out" | jq -r '.systemMessage')
assert_contains "report states the actual cost" "muxer: this stretch cost ~\$0.66" "$msg"
assert_contains "report names the all-fable counterfactual" "all-fable" "$msg"
assert_contains "report states savings and percent" "Saved ~\$5.40 (89%)" "$msg"
assert_contains "report breaks out the haiku share" "haiku \$0.60" "$msg"

# --- 4. a second report with no new spend is silent (state was updated in case 3) ---
assert_silent "second report with no new spend stays silent" "$(report s34 "$tmp/big.jsonl")"

# --- 5. zero delegations means nothing to report even with savings on paper ---
zero s5
assert_silent "no delegations means no report" "$(report s5 "$tmp/solo.jsonl")"

# --- 6. savings under the threshold stay silent ---
zero s6
out=$(hookinput s6 "$tmp/big.jsonl" | env -u MUXER_REPORT MUXER_REPORT_MIN_USD=10 HOME="$home" "$S")
assert_silent "savings below MUXER_REPORT_MIN_USD stay silent" "$out"

# --- 7. MUXER_REPORT=off silences everything ---
zero s7
out=$(hookinput s7 "$tmp/big.jsonl" | env -u MUXER_REPORT_MIN_USD MUXER_REPORT=off HOME="$home" "$S")
assert_silent "MUXER_REPORT=off silences the report" "$out"

# --- 8. MUXER_REPORT=always speaks even when savings are tiny ---
zero s8
out=$(hookinput s8 "$tmp/small.jsonl" | env -u MUXER_REPORT_MIN_USD MUXER_REPORT=always HOME="$home" "$S")
assert_valid_json "MUXER_REPORT=always speaks despite tiny savings" "$out"
assert_contains "always-mode still prints the muxer line" "muxer: this stretch cost" \
  "$(printf '%s' "$out" | jq -r '.systemMessage')"

# --- 9. duplicate rows dedup to the last one seen ---
out=$(base s9 "$tmp/dedup.jsonl")
assert_silent "baseline over duplicate rows says nothing" "$out"
assert_jq "duplicate ids keep the last row, not the 999999 one" '.a*100|round/100' "0.66" \
  "$(cat "$statedir/s9.json")"

# --- 10. cache-read tokens price at 0.1x the input rate ---
out=$(base s10 "$tmp/cache.jsonl")
assert_silent "cache baseline says nothing" "$out"
assert_jq "cache read adds \$0.10 (0.66 -> 0.76)" '.a*100|round/100' "0.76" \
  "$(cat "$statedir/s10.json")"

# --- 11. resilience: missing transcript and garbage input fail open ---
out=$(report s11 "$tmp/does-not-exist.jsonl"; echo "rc=$?")
assert_contains "missing transcript exits 0" "rc=0" "$out"
assert_silent "missing transcript is silent" "$(report s11 "$tmp/does-not-exist.jsonl")"
out=$(printf 'garbage' | env -u MUXER_REPORT -u MUXER_REPORT_MIN_USD HOME="$home" "$S"; echo "rc=$?")
assert_contains "garbage input exits 0" "rc=0" "$out"
assert_silent "garbage input is silent" \
  "$(printf 'garbage' | env -u MUXER_REPORT -u MUXER_REPORT_MIN_USD HOME="$home" "$S")"

finish
