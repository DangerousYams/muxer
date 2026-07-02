#!/bin/bash
# muxer Stop hook: report actual token spend vs the un-muxed (all-main-model) cost.
# Prints a one-line systemMessage when the savings accumulated since the last
# report cross a threshold. Fail-open: on any problem, exit 0 silently.
set -u

[ "${MUXER_REPORT:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
[ -n "$session_id" ] || exit 0

min_usd="${MUXER_REPORT_MIN_USD:-0.25}"

# Collect main transcript + per-subagent transcripts.
files=("$transcript")
subdir="${transcript%.jsonl}/subagents"
if [ -d "$subdir" ]; then
  for f in "$subdir"/agent-*.jsonl; do
    [ -f "$f" ] && files+=("$f")
  done
fi

# One jq pass: dedup assistant rows by message id (streaming rewrites rows),
# bucket tokens by model, price actual vs counterfactual-at-main-model.
# Cache pricing: read = 0.1x input rate, 5m write = 1.25x, 1h write = 2x.
totals=$(jq -n --arg main "$transcript" '
  def fam(m): if (m|test("fable")) then "fable"
    elif (m|test("opus")) then "opus"
    elif (m|test("sonnet")) then "sonnet"
    elif (m|test("haiku")) then "haiku"
    else null end;
  def rin(f):  {fable:10, opus:5, sonnet:3, haiku:1}[f];
  def rout(f): {fable:50, opus:25, sonnet:15, haiku:5}[f];
  def cost(f; u):
    ( u.tin*rin(f) + u.cr*rin(f)*0.1 + u.c5*rin(f)*1.25 + u.c1*rin(f)*2
      + u.out*rout(f) ) / 1e6;

  [ inputs
    | select(.type=="assistant" and .message.usage != null)
    | {sc: ((input_filename != $main) or (.isSidechain == true)),
       id: (.message.id // .uuid // "noid"),
       model: (.message.model // ""),
       u: {tin: (.message.usage.input_tokens // 0),
           cr:  (.message.usage.cache_read_input_tokens // 0),
           c5:  (.message.usage.cache_creation.ephemeral_5m_input_tokens
                  // (.message.usage.cache_creation_input_tokens // 0)),
           c1:  (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0),
           out: (.message.usage.output_tokens // 0)}}
    | select(fam(.model) != null) ]
  | group_by(.id) | map(.[-1])
  | . as $rows
  | ([$rows[] | select(.sc|not)] | if length==0 then null else (last.model|fam(.)) end) as $mf
  | if $mf == null then empty else
    { actual:  ([$rows[] | cost(fam(.model); .u)] | add // 0),
      counter: ([$rows[] | cost($mf; .u)] | add // 0),
      credits: ([$rows[] | select(fam(.model)=="fable") | cost("fable"; .u)] | add // 0),
      main: $mf,
      delegations: ([$rows[] | select(.sc)] | length) }
    end
' "${files[@]}" 2>/dev/null)
[ -n "$totals" ] || exit 0

actual=$(printf '%s' "$totals" | jq -r .actual)
counter=$(printf '%s' "$totals" | jq -r .counter)
credits=$(printf '%s' "$totals" | jq -r .credits)
main_fam=$(printf '%s' "$totals" | jq -r .main)
delegations=$(printf '%s' "$totals" | jq -r .delegations)

# State: cumulative figures as of the last report, so quiet turns accumulate
# until the delta crosses the threshold.
state_dir="${HOME}/.cache/muxer"
state_file="${state_dir}/${session_id}.json"
prev_a=0; prev_c=0; prev_cr=0
if [ -f "$state_file" ]; then
  prev_a=$(jq -r '.a // 0' "$state_file" 2>/dev/null || echo 0)
  prev_c=$(jq -r '.c // 0' "$state_file" 2>/dev/null || echo 0)
  prev_cr=$(jq -r '.cr // 0' "$state_file" 2>/dev/null || echo 0)
fi

# Deltas since last report; decide whether to speak.
read -r report da dq dcr dc ds pct <<EOF
$(jq -rn --argjson a "$actual" --argjson c "$counter" --argjson cr "$credits" \
         --argjson pa "$prev_a" --argjson pc "$prev_c" --argjson pcr "$prev_cr" \
         --argjson d "$delegations" \
         --arg min "$min_usd" --arg mode "${MUXER_REPORT:-on}" '
  def r2: .*100 | round / 100;
  ($a - $pa) as $da | ($c - $pc) as $dc | ($cr - $pcr) as $dcr
  | ($dc - $da) as $ds
  | (if $dc > 0 then ($ds / $dc * 100 | round) else 0 end) as $pct
  | (($d > 0) and (($ds >= ($min|tonumber)) or ($mode == "always" and $da > 0.005))) as $go
  | [(if $go then 1 else 0 end),
     ($da|r2), (($da - $dcr)|r2), ($dcr|r2), ($dc|r2), ($ds|r2), $pct]
  | @tsv' | tr '\t' ' ')
EOF
[ "${report:-0}" = "1" ] || exit 0

da=$(printf '%.2f' "$da"); dq=$(printf '%.2f' "$dq"); dcr=$(printf '%.2f' "$dcr")
dc=$(printf '%.2f' "$dc"); ds=$(printf '%.2f' "$ds")

if [ "$main_fam" = "fable" ]; then
  msg="muxer: this stretch cost ~\$${da} (~\$${dcr} Fable credits, ~\$${dq} Max-quota) vs ~\$${dc} un-muxed all-Fable. Saved ~\$${ds} (${pct}%)."
else
  msg="muxer: this stretch cost ~\$${da} vs ~\$${dc} if all ran on ${main_fam}. Saved ~\$${ds} (${pct}%). ${delegations} delegated turns."
fi

mkdir -p "$state_dir" 2>/dev/null || exit 0
jq -n --argjson a "$actual" --argjson c "$counter" --argjson cr "$credits" \
  '{a:$a, c:$c, cr:$cr}' > "$state_file" 2>/dev/null

jq -n --arg m "$msg" '{systemMessage:$m}'
exit 0
