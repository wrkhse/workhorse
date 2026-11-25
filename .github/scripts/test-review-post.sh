#!/usr/bin/env bash
set -euo pipefail

# Offline fixtures for post-review.sh. A JSONL file stands in for the reviewer's
# opencode event stream, and a stub gh records every write, so nothing reaches GitHub.
script="$(dirname -- "${BASH_SOURCE[0]}")/post-review.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-review-post.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

# New-file lines 1 (context), 2 (added) and 3 (context) are in the hunk; old line 2 is deleted.
cat > "$tmp/diff.patch" <<'DIFF'
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 keep
-removed
+added
 tail
DIFF

# gh defaults to POST when a body or field is given, as the real one does. Each write
# lands in $dir/writes and each POST body is kept beside the stub for the assertions.
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir=$(dirname -- "$0")
[ "${1:-}" = api ] || { echo "stub gh: unexpected command: $*" >&2; exit 2; }
shift
method='' endpoint='' input='' query='' fields=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method | -X) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    -f | -F | --raw-field | --field)
      fields=1
      case "$2" in query=*) query=${2#query=} ;; esac
      shift 2
      ;;
    --paginate | --silent) shift ;;
    -*) echo "stub gh: unexpected flag: $1" >&2; exit 2 ;;
    *) endpoint=$1; shift ;;
  esac
done
if [ -z "$method" ]; then
  if [ -n "$input$fields" ]; then method=POST; else method=GET; fi
fi
case "$method $endpoint" in
  'POST repos/'*'/issues/'*'/comments')
    echo "POST $endpoint" >> "$dir/writes"
    cp -- "$input" "$dir/comment-payload.json"
    printf '%s\n' '{"id":123}'
    ;;
  'POST repos/'*'/pulls/'*'/reviews')
    echo "POST $endpoint" >> "$dir/writes"
    cp -- "$input" "$dir/review-payload.json"
    printf '%s\n' '{"node_id":"PRR_test"}'
    ;;
  'GET repos/'*'/issues/'*'/comments') printf '[]\n' ;;
  *' graphql')
    case "$query" in
      *mutation*)
        echo "graphql mutation" >> "$dir/writes"
        printf '%s\n' '{"data":{"minimizeComment":{"minimizedComment":{"isMinimized":true}}}}'
        ;;
      *) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],
           "pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
    esac
    ;;
  *)
    echo "unexpected $method $endpoint" >> "$dir/writes"
    echo "stub gh: unexpected request: $method $endpoint" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$tmp/gh"

# A reviewer reply: the marker, an optional verdict line, a summary, bullets and the findings block.
reply() {
  local verdict=$1 findings=$2

  printf '%s\n' '<!-- opencode-review -->'
  [ -z "$verdict" ] || printf '%s\n' "$verdict"
  printf '%s\n' 'Review summary.' '' '**MUST**' '- a.txt:2 Fix this.' '' \
    '<!-- opencode-findings-json' "$findings" '-->'
}

# One opencode "run --format json" stream: step_start, the reply as a finished text event,
# any extra raw event lines, then step_finish.
write_events() {
  local text=$1
  shift

  {
    jq -cn '{type: "step_start", timestamp: 1, sessionID: "ses_test", part: {type: "step-start"}}'
    jq -cn --arg text "$text" '{type: "text", timestamp: 2, sessionID: "ses_test",
      part: {type: "text", text: $text, time: {start: 1, end: 2}}}'
    printf '%s\n' "$@"
    jq -cn '{type: "step_finish", timestamp: 3, sessionID: "ses_test",
      part: {type: "step-finish", reason: "stop"}}'
  } > "$tmp/events.jsonl"
}

run_main() {
  rm -f -- "$tmp/writes" "$tmp/comment-payload.json" "$tmp/review-payload.json"
  GH="$tmp/gh" REPO=owner/repo PR=7 GH_TOKEN=test DIFF="$tmp/diff.patch" \
    EVENTS="$tmp/events.jsonl" OUT="$tmp/out" bash "$script" > "$tmp/main.out" 2> "$tmp/main.err"
}

expect_posted() {
  if ! run_main; then
    cat -- "$tmp/main.out" "$tmp/main.err" >&2
    return 1
  fi

  printf '%s\n' 'POST repos/owner/repo/issues/7/comments' 'POST repos/owner/repo/pulls/7/reviews' \
    > "$tmp/expected-writes"
  sort -- "$tmp/writes" | diff -u -- "$tmp/expected-writes" -
}

# A rejected stream exits non-zero, names the reason on stderr when one is given, and writes nothing.
expect_rejected() {
  local reason=$1

  if run_main; then
    echo 'post-review.sh accepted an invalid event stream' >&2
    return 1
  fi

  if [ -n "$reason" ] && ! grep -qi -- "$reason" "$tmp/main.err"; then
    cat -- "$tmp/main.err" >&2
    return 1
  fi

  if [ -e "$tmp/writes" ]; then
    cat -- "$tmp/writes" >&2
    return 1
  fi
}

findings='[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."},
  {"path":"a.txt","line":9,"side":"RIGHT","severity":"SHOULD","body":"Off the diff."}]'
write_events "$(reply '**Verdict: FIX FIRST**' "$findings")"
expect_posted
jq -e '.body | startswith("<!-- opencode-review -->\n")
  and (split("\n") | any(. == "**Verdict: FIX FIRST**") and any(. == "Review summary."))
' "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
  and (.body | split("\n") | any(. == "- a.txt:9 (SHOULD): Off the diff."))
' "$tmp/review-payload.json" > /dev/null
printf 'ok: valid reply posts the marker comment and a COMMENT review\n'

write_events "$(reply '' "$findings")"
expect_rejected Verdict
printf 'ok: missing verdict fails without posting\n'

write_events "$(reply '**Verdict: FIX FIRST**' '[{"path":"a.txt","line":')"
expect_rejected JSON
printf 'ok: malformed findings JSON fails without posting\n'

write_events "$(reply '**Verdict: FIX FIRST**' '[
  {"path":"a.txt","line":1,"side":"RIGHT","severity":"MUST","body":"Context line."},
  {"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Added line."},
  {"path":"a.txt","line":2,"side":"LEFT","severity":"SHOULD","body":"Deleted line."},
  {"path":"a.txt","line":7,"side":"RIGHT","severity":"SHOULD","body":"Not in the hunk."}
]')"
expect_posted
jq -e '.event == "COMMENT"
  and .comments == [
    {path: "a.txt", line: 1, side: "RIGHT", body: "Context line."},
    {path: "a.txt", line: 2, side: "RIGHT", body: "Added line."}
  ]
  and (.body | split("\n")
    | any(. == "- a.txt:2 (SHOULD): Deleted line.") and any(. == "- a.txt:7 (SHOULD): Not in the hunk."))
' "$tmp/review-payload.json" > /dev/null
printf 'ok: deleted and out-of-hunk lines become bullets; context and added lines stay inline\n'

write_events "$(reply '**Verdict: FIX FIRST**' "$findings")" \
  '{"type":"error","timestamp":3,"sessionID":"ses_test","error":{"name":"APIError","data":{"message":"provider overloaded"}}}'
expect_rejected ''
printf 'ok: an error event fails without posting\n'
