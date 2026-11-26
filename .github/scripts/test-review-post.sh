#!/usr/bin/env bash
set -euo pipefail

# Offline fixtures for post-review.sh. A JSONL file stands in for the reviewer's
# opencode event stream, and a stub gh records every write, so nothing reaches GitHub.
script="$(dirname -- "${BASH_SOURCE[0]}")/post-review.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-review-post.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
FAIL_DELETE=0

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

# gh defaults to POST when a body or field is given, as the real one does. Each POST
# lands in $dir/writes and each body is kept beside the stub for the assertions.
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
  'GET repos/'*'/issues/'*'/comments')
    if [ "${FAIL_DELETE:-0}" = 1 ]; then
      printf '%s\n' '[{"id":122,"user":{"login":"github-actions[bot]"},"body":"<!-- opencode-review -->"}]'
    else
      printf '[]\n'
    fi
    ;;
  'DELETE repos/'*'/issues/comments/'*)
    printf 'DELETE %s\n' "$endpoint" >> "$dir/cleanup-attempts"
    echo 'stub gh: simulated DELETE failure' >&2
    exit 1
    ;;
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

# The first call seeds EVENTS; only the second may emit the repaired reply.
cat > "$tmp/opencode" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir=$(dirname -- "$0")

if [ ! -f "$dir/invalid-events.jsonl" ]; then
  echo 'stub opencode: unexpected invocation without a fixture' >&2
  exit 2
fi

jq -cn --args '$ARGS.positional' -- "$@" >> "$dir/opencode-calls.jsonl"
case "$(awk 'END { print NR }' "$dir/opencode-calls.jsonl")" in
  1) cat -- "$dir/invalid-events.jsonl" ;;
  2) cat -- "$dir/valid-events.jsonl" ;;
  *) echo 'stub opencode: unexpected extra invocation' >&2; exit 2 ;;
esac
STUB
chmod +x "$tmp/opencode"

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
  rm -f -- "$tmp/writes" "$tmp/comment-payload.json" "$tmp/review-payload.json" "$tmp/cleanup-attempts"

  GH="$tmp/gh" OPENCODE="$tmp/opencode" MODEL="${1:-}" FAIL_DELETE="$FAIL_DELETE" \
    REPO=owner/repo PR=7 GH_TOKEN=test DIFF="$tmp/diff.patch" \
    EVENTS="$tmp/events.jsonl" OUT="$tmp/out" bash "$script" > "$tmp/main.out" 2> "$tmp/main.err"
}

expect_posted() {
  if ! run_main "$@"; then
    cat -- "$tmp/main.out" "$tmp/main.err" >&2
    return 1
  fi

  printf '%s\n' 'POST repos/owner/repo/issues/7/comments' 'POST repos/owner/repo/pulls/7/reviews' \
    > "$tmp/expected-writes"
  diff -u -- "$tmp/expected-writes" "$tmp/writes"
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

repair_model=fixture/reviewer
write_events "$(reply '**Verdict: FIX FIRST**' '[{"path":"a.txt","line":')"
mv -- "$tmp/events.jsonl" "$tmp/invalid-events.jsonl"
write_events "$(reply '**Verdict: FIX FIRST**' \
  '[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."}]')"
mv -- "$tmp/events.jsonl" "$tmp/valid-events.jsonl"
"$tmp/opencode" run --model "$repair_model" --variant low --format json 'Initial review.' > "$tmp/events.jsonl"

expect_posted "$repair_model"
[ ! -e "$tmp/cleanup-attempts" ]
jq -se --arg model "$repair_model" '
  length == 2
  and .[0] == ["run", "--model", $model, "--variant", "low", "--format", "json", "Initial review."]
  and (.[1] | length == 10
    and .[:9] == ["run", "--model", $model, "--variant", "low", "--format", "json", "--session", "ses_test"]
    and (.[9] | test("[^[:space:]]")))
' "$tmp/opencode-calls.jsonl" > /dev/null
jq -e '
  .body == "<!-- opencode-review -->\n**Verdict: FIX FIRST**\nReview summary.\n\n**MUST**\n- a.txt:2 Fix this."
' "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
' "$tmp/review-payload.json" > /dev/null
sed -n 's/^Review events: //p' "$tmp/main.out" "$tmp/main.err" |
  jq -se 'last | .attempts == 2' > /dev/null
printf 'ok: invalid, then valid on repair, with both payloads posted\n'

# The terse repair seen on sourcefed#104: the first turn has no text event at all, and the repair
# holds only the marker, the verdict and the findings block, so the comment's findings come from JSON.
{
  jq -cn '{type: "step_start", timestamp: 1, sessionID: "ses_test", part: {type: "step-start"}}'
  jq -cn '{type: "step_finish", timestamp: 2, sessionID: "ses_test",
    part: {type: "step-finish", reason: "stop"}}'
} > "$tmp/invalid-events.jsonl"
write_events "$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  '<!-- opencode-findings-json' "$findings" '-->')"
mv -- "$tmp/events.jsonl" "$tmp/valid-events.jsonl"
rm -f -- "$tmp/opencode-calls.jsonl"
"$tmp/opencode" run --model "$repair_model" --variant low --format json 'Initial review.' > "$tmp/events.jsonl"

expect_posted "$repair_model"
jq -se 'length == 2' "$tmp/opencode-calls.jsonl" > /dev/null
jq -e '.body | split("\n")
  | .[0] == "<!-- opencode-review -->" and .[1] == "**Verdict: FIX FIRST**"
    and any(. == "**MUST**") and any(. == "**SHOULD**")
    and any(. == "- a.txt:2: Fix this.") and any(. == "- a.txt:9: Off the diff.")
' "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
  and (.body | split("\n") | any(. == "- a.txt:9 (SHOULD): Off the diff."))
' "$tmp/review-payload.json" > /dev/null
sed -n 's/^Review events: //p' "$tmp/main.out" "$tmp/main.err" |
  jq -se 'last | .attempts == 2' > /dev/null
printf 'ok: a terse repair with only the marker, verdict and findings renders the findings\n'

# A partial findings section: the reply has the MUST header and bullet but no
# SHOULD section, so only the missing SHOULD header and bullet are added from JSON
# and the MUST bullet stays single.
write_events "$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  'Review summary.' '' '**MUST**' '- a.txt:2: Fix this.' '' \
  '<!-- opencode-findings-json' "$findings" '-->')"
expect_posted
jq -e '.body | split("\n")
  | (map(select(. == "**MUST**")) | length == 1)
    and (map(select(endswith("Fix this."))) == ["- a.txt:2: Fix this."])
    and (map(select(. == "**SHOULD**")) | length == 1)
    and (map(select(endswith("Off the diff."))) == ["- a.txt:9: Off the diff."])
    and (index("**MUST**") < index("- a.txt:2: Fix this."))
    and (index("**SHOULD**") < index("- a.txt:9: Off the diff."))
' "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
  and (.body | split("\n") | any(. == "- a.txt:9 (SHOULD): Off the diff."))
' "$tmp/review-payload.json" > /dev/null
printf '%s %s\n' 'ok: a partial findings section keeps its MUST bullet' \
  'and gains the missing SHOULD section'

# A dedup collision: two MUST findings share the body "Fix this." at different lines.
# The reply wrote only the a.txt:2 bullet, so matching on the body alone would drop
# a.txt:5; the comment must keep the written bullet once and add the missing one once.
dup_findings='[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."},
  {"path":"a.txt","line":5,"side":"RIGHT","severity":"MUST","body":"Fix this."}]'
write_events "$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  'Review summary.' '' '**MUST**' '- a.txt:2: Fix this.' '' \
  '<!-- opencode-findings-json' "$dup_findings" '-->')"
expect_posted
jq -e '.body | split("\n")
  | (map(select(. == "**MUST**")) | length == 1)
    and (map(select(endswith("Fix this."))) == ["- a.txt:2: Fix this.", "- a.txt:5: Fix this."])
    and (index("**MUST**") < index("- a.txt:2: Fix this."))
    and (index("**MUST**") < index("- a.txt:5: Fix this."))
' "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
' "$tmp/review-payload.json" > /dev/null
printf '%s %s\n' 'ok: two findings with the same body keep the written a.txt:2 bullet once' \
  'and add the missing a.txt:5 bullet once'

# A prefix collision: two MUST findings share a.txt:2, and one body is a prefix of the other.
# The reply wrote only the longer bullet, so matching by prefix would treat "Fix this." as
# written; the comment must keep the written bullet once and add the shorter one once.
prefix_findings='[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."},
  {"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this. now."}]'
write_events "$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  'Review summary.' '' '**MUST**' '- a.txt:2: Fix this. now.' '' \
  '<!-- opencode-findings-json' "$prefix_findings" '-->')"
expect_posted
jq -e '.body | split("\n")
  | (map(select(. == "**MUST**")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this.")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this. now.")) | length == 1)
    and (index("**MUST**") < index("- a.txt:2: Fix this."))
    and (index("**MUST**") < index("- a.txt:2: Fix this. now."))
' "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [
    {path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."},
    {path: "a.txt", line: 2, side: "RIGHT", body: "Fix this. now."}
  ]
' "$tmp/review-payload.json" > /dev/null
printf '%s %s\n' 'ok: a written bullet whose body extends another finding at the same line' \
  'keeps both bullets once each'

# A commit-suffix collision: two MUST findings share a.txt:2 and the body "Fix this.", and the
# second carries a commit, so only its rendered " (commit abc1234)" suffix tells the bullets apart.
# The reply wrote only the suffixed bullet, so the comment must keep it once, never suffix it
# twice, and add the plain bullet once.
commit_findings='[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."},
  {"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this.","commit":"abc1234"}]'
write_events "$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  'Review summary.' '' '**MUST**' '- a.txt:2: Fix this. (commit abc1234)' '' \
  '<!-- opencode-findings-json' "$commit_findings" '-->')"
expect_posted
jq -e '.body | split("\n")
  | (map(select(. == "**MUST**")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this.")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this. (commit abc1234)")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this. (commit abc1234) (commit abc1234)")) | length == 0)
    and (index("**MUST**") < index("- a.txt:2: Fix this."))
    and (index("**MUST**") < index("- a.txt:2: Fix this. (commit abc1234)"))
' "$tmp/comment-payload.json" > /dev/null
printf '%s %s\n' 'ok: a written bullet with a commit suffix at the same line as a plain finding' \
  'keeps both bullets once each'

# The reverse commit-suffix case: the only MUST finding carries a commit, and the reply wrote
# a plain bullet without the suffix. The plain bullet does not match the finding's rendered
# bullet, so the comment must keep the written plain bullet once, never repeat it, and add the
# suffixed bullet once.
reverse_commit_findings='[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST",
  "body":"Fix this.","commit":"abc1234"}]'
write_events "$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  'Review summary.' '' '**MUST**' '- a.txt:2: Fix this.' '' \
  '<!-- opencode-findings-json' "$reverse_commit_findings" '-->')"
expect_posted
jq -e '.body | split("\n")
  | (map(select(. == "**MUST**")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this. (commit abc1234)")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this.")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this. (commit abc1234) (commit abc1234)")) | length == 0)
    and (index("**MUST**") < index("- a.txt:2: Fix this. (commit abc1234)"))
' "$tmp/comment-payload.json" > /dev/null
printf '%s %s\n' 'ok: a written plain bullet for a finding with a commit' \
  'gains the suffixed bullet once and keeps the plain bullet once'

# A body that already ends with its commit suffix: the reply wrote no bullet for the finding,
# so the fallback renders it, and it must not append " (commit abc1234)" a second time.
suffixed_findings='[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST",
  "body":"Fix this. (commit abc1234)","commit":"abc1234"}]'
write_events "$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  'Review summary.' '' '<!-- opencode-findings-json' "$suffixed_findings" '-->')"
expect_posted
jq -e '.body | split("\n")
  | (map(select(. == "**MUST**")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this. (commit abc1234)")) | length == 1)
    and (map(select(. == "- a.txt:2: Fix this. (commit abc1234) (commit abc1234)")) | length == 0)
    and (index("**MUST**") < index("- a.txt:2: Fix this. (commit abc1234)"))
' "$tmp/comment-payload.json" > /dev/null
printf '%s %s\n' 'ok: a missing finding whose body already ends with its commit suffix' \
  'renders the suffix once'

# A fully populated reply: every JSON finding already has its bullet under its own
# header, so the comment is the reply's human part exactly, with no explanation line
# and no repeated bullet.
full_human=$(printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' \
  'Review summary.' '' '**MUST**' '- a.txt:2: Fix this.' '' \
  '**SHOULD**' '- a.txt:9: Off the diff.')
write_events "$(printf '%s\n' "$full_human" '' \
  '<!-- opencode-findings-json' "$findings" '-->')"
expect_posted
jq -e --arg body "$full_human" '.body == $body' "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
' "$tmp/review-payload.json" > /dev/null
printf 'ok: a fully populated reply leaves the marker comment unchanged\n'

write_events "$(reply '**Verdict: FIX FIRST**' "$findings")"
FAIL_DELETE=1 expect_posted
printf 'DELETE repos/owner/repo/issues/comments/122\n' |
  diff -u -- - "$tmp/cleanup-attempts"
printf 'ok: a failed cleanup DELETE does not prevent either post or fail the run\n'
