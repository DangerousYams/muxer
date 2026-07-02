#!/bin/bash
# muxer cost hook. Two modes:
#   report-cost.sh            (Stop)         print spend vs un-muxed cost since the last report
#   report-cost.sh baseline   (SessionStart) record current totals silently so the first
#                                            report covers this session's new work only,
#                                            never the transcript's whole history
# Fail-open: on any problem, exit 0 silently.
set -u

[ "${MUXER_REPORT:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

mode="${1:-report}"
input=$(cat 2>/dev/null || true)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$session_id" ] || exit 0

min_usd="${MUXER_REPORT_MIN_USD:-0.25}"
state_dir="${HOME}/.cache/muxer"
state_file="${state_dir}/${session_id}.json"

# Collect main transcript + per-subagent transcripts.
files=()
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  files=("$transcript")
  subdir="${transcript%.jsonl}/subagents"
  if [ -d "$subdir" ]; then
    for f in "$subdir"/agent-*.jsonl; do
      [ -f "$f" ] && files+=("$f")
    done
  fi
fi

# One jq pass: dedup assistant rows by message id (streaming rewrites rows),
# bucket tokens by model family, price actual vs counterfactual-at-main-model.
# Cache pricing: read = 0.1x input rate, 5m write = 1.25x, 1h write = 2x.
totals=""
if [ "${#files[@]}" -gt 0 ]; then
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
        fable:   ([$rows[] | select(fam(.model)=="fable")  | cost("fable"; .u)]  | add // 0),
        opus:    ([$rows[] | select(fam(.model)=="opus")   | cost("opus"; .u)]   | add // 0),
        sonnet:  ([$rows[] | select(fam(.model)=="sonnet") | cost("sonnet"; .u)] | add // 0),
        haiku:   ([$rows[] | select(fam(.model)=="haiku")  | cost("haiku"; .u)]  | add // 0),
        main: $mf,
        delegations: ([$rows[] | select(.sc)] | length) }
      end
  ' "${files[@]}" 2>/dev/null)
fi

write_state() {
  mkdir -p "$state_dir" 2>/dev/null || return 0
  if [ -n "$totals" ]; then
    printf '%s' "$totals" \
      | jq '{a:.actual, c:.counter, fable, opus, sonnet, haiku}' > "$state_file" 2>/dev/null
  else
    jq -n '{a:0, c:0, fable:0, opus:0, sonnet:0, haiku:0}' > "$state_file" 2>/dev/null
  fi
}

if [ "$mode" = "baseline" ]; then
  write_state
  exit 0
fi

# Report mode from here. No transcript data -> nothing to say.
[ -n "$totals" ] || exit 0

# No baseline means we cannot tell this session's new work apart from the
# transcript's history (resumed sessions carry hours of it). Set the baseline
# silently; the next report will be a true delta.
if [ ! -f "$state_file" ]; then
  write_state
  exit 0
fi

main_fam=$(printf '%s' "$totals" | jq -r .main)
delegations=$(printf '%s' "$totals" | jq -r .delegations)

# Deltas since last report; decide whether to speak.
read -r report da dc dsave pct d_fable d_opus d_sonnet d_haiku <<EOF
$(jq -rn --argjson t "$totals" --slurpfile prev "$state_file" \
         --arg min "$min_usd" --arg mode "${MUXER_REPORT:-on}" '
  $prev[0] as $p
  | ($t.actual  - ($p.a // 0)) as $da
  | ($t.counter - ($p.c // 0)) as $dc
  | ($dc - $da) as $ds
  | (if $dc > 0 then ($ds / $dc * 100 | round) else 0 end) as $pct
  | (($t.delegations > 0)
     and (($ds >= ($min|tonumber)) or ($mode == "always" and $da > 0.005))) as $go
  | [(if $go then 1 else 0 end), $da, $dc, $ds, $pct,
     ($t.fable  - ($p.fable  // 0)), ($t.opus  - ($p.opus  // 0)),
     ($t.sonnet - ($p.sonnet // 0)), ($t.haiku - ($p.haiku // 0))]
  | @tsv' | tr '\t' ' ')
EOF
[ "${report:-0}" = "1" ] || exit 0

# Per-model breakdown, skipping models that spent under half a cent.
parts=""
part() {
  awk -v v="$2" 'BEGIN{exit (v>=0.005)?0:1}' || return 0
  p=$(printf '%s $%.2f%s' "$1" "$2" "$3")
  parts="${parts:+$parts + }$p"
}
part fable  "$d_fable"  " credits"
part opus   "$d_opus"   ""
part sonnet "$d_sonnet" ""
part haiku  "$d_haiku"  ""

da=$(printf '%.2f' "$da"); dc=$(printf '%.2f' "$dc"); dsave=$(printf '%.2f' "$dsave")
msg="muxer: this stretch cost ~\$${da}"
[ -n "$parts" ] && msg="${msg} (${parts})"
msg="${msg} vs ~\$${dc} all-${main_fam}. Saved ~\$${dsave} (${pct}%)."

write_state
jq -n --arg m "$msg" '{systemMessage:$m}'
exit 0
