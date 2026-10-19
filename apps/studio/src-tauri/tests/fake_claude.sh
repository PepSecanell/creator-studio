#!/bin/sh
# A stand-in for the `claude` CLI, used by the tests (STUDIO_CLAUDE_BIN points here).
# It answers by looking at the JSON schema argument and the prompt on stdin, and it prints one
# result event, which both `--output-format json` and `stream-json` readers understand.
in=$(cat)
args="$*"
[ -n "$STUDIO_FAKE_LOG" ] && printf '%s\n----\n' "$in" >> "$STUDIO_FAKE_LOG"

emit() {
  printf '{"type":"result","is_error":false,"structured_output":%s,"total_cost_usd":0.01}\n' "$1"
}

good_card() {
  # $1 = index, $2 = number of points, $3 = payoff
  pts='"Rushed and flat"'
  [ "$2" -ge 2 ] && pts="$pts, \"Slow with one pause\""
  [ "$2" -ge 3 ] && pts="$pts, \"Warm and a bit quiet\""
  printf '{"title":"Card number %s","hook":{"idea":"Why the same sentence lands differently","takes":["Nobody hears your first draft.","Why does the plan always change when you start?"]},"points":[%s],"payoff":"%s","end_line":"Follow for one small build a day.","facts":[]}' "$1" "$pts" "$3"
}

case "$in" in
  *"problems were found"*)
    case "$args" in
      *'"hook"'*)
        np=$(printf '%s\n' "$in" | grep -c '"Rushed and flat"\|"Slow with one pause"\|"Warm and a bit quiet"')
        emit "$(good_card 1 "${np:-3}" 'The pause version is the one people remember.')" ;;
      *'"fixed_text"'*) emit '{"fixed_text":"Clean text."}' ;;
      *'"script"'*) emit '{"script":"Short script. Trimmed to fit."}' ;;
      *) emit '{}' ;;
    esac
    exit 0 ;;
esac

case "$args" in
  *'"cards"'*)
    n=$(printf '%s' "$in" | sed -n 's/.*Write \([0-9][0-9]*\) cards.*/\1/p' | head -1)
    out=""
    k=1
    while [ "$k" -le "$n" ]; do
      p=$(printf '%s\n' "$in" | grep "^Card $k:" | grep -o '([0-9]\( to [0-9]\)\{0,1\} points)' | head -1 | sed 's/^(\([0-9]\).*/\1/')
      payoff='The pause version is the one people remember.'
      if [ "$k" -eq 1 ] && [ -n "$STUDIO_FAKE_BAD" ]; then payoff="It will unlock everything $(printf '\342\200\224') fast."; fi
      c=$(good_card "$k" "${p:-3}" "$payoff")
      out="${out:+$out,}$c"
      k=$((k + 1))
    done
    emit "{\"cards\":[$out]}" ;;
  *'"shape"'*)
    emit '{"ideas":[{"shape":"face-words","words":"Stop saying this","scene":"Close face, one raised eyebrow","why":"A direct warning"},{"shape":"object-number","words":"3 tools","scene":"One laptop screen with three icons","why":"Shows the result"},{"shape":"split-contrast","words":"Before after","scene":"Left cluttered desk, right clean desk","why":"Easy to compare"}]}' ;;
  *'"ideas"'*)
    emit '{"ideas":[{"title":"Ship it ugly","angle":"You get a first version out this week.","format":"myth-then-fix"},{"title":"Say this, not that for emails","angle":"You write shorter emails.","format":"say-this-not-that"},{"title":"One tip for tiny tools","angle":"You build faster.","format":"nonsense-format"}]}' ;;
  *'"titles"'*)
    emit '{"titles":["How to plan a week in ten minutes","A plain way to plan your week","Planning is not what you think"]}' ;;
  *'"chapters"'*)
    emit '{"description":"A plain walk through planning a week. You get a method you can copy.","chapters":[{"start_seconds":0,"title":"The idea"},{"start_seconds":65,"title":"The method"},{"start_seconds":190,"title":"Try it"}]}' ;;
  *'"hook"'*)
    emit "$(good_card 1 3 'A rewritten payoff people remember.')" ;;
  *'"points"'*)
    emit '{"points":[{"title":"Start with the end","detail":"Write what done looks like first"},{"title":"List the moves","detail":"Five small steps, no more"},{"title":"Pick the first one","detail":"Do it before anything else"},{"title":"Check at night","detail":"Cross off what is done"},{"title":"Reset on Sunday","detail":"Move what is left forward"}],"facts":[]}' ;;
  *'"fixed_text"'*)
    emit '{"fixed_text":"Clean text."}' ;;
  *'"script"'*)
    words=$(i=0; while [ "$i" -lt 140 ]; do printf 'plain '; i=$((i + 1)); done)
    emit "{\"script\":\"Short script. $words\"}" ;;
  *) printf 'unexpected request\n' >&2; exit 1 ;;
esac
