#!/usr/bin/env bash
set -euo pipefail

# Offline fixtures for post-review.sh. A JSONL file stands in for the reviewer's
# opencode event stream, and stub gh and opencode binaries record every call, so
# nothing reaches GitHub or a model.
script="$(dirname -- "${BASH_SOURCE[0]}")/post-review.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-review-post.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
FAIL_CLEANUP=0
marker='<!-- opencode-review -->'
fix_first='**Verdict: FIX FIRST**'

# New-file lines 1 (context), 2 (added) and 3 (context) are in the hunk; old
# line 2 is deleted.
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

# gh defaults to POST when a body or field is given, as the real one does. Each
# POST lands in $dir/writes with its body kept beside the stub; cleanup writes
# land in $dir/cleanup-attempts. FAIL_CLEANUP=1 lists one older marker comment
# and fails its DELETE and every GraphQL call.
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
    if [ "${FAIL_CLEANUP:-0}" = 1 ]; then
      jq -cn '[{id: 122, user: {login: "github-actions[bot]"},
        body: "<!-- opencode-review -->"}]'
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
      *mutation*) printf 'graphql mutation\n' >> "$dir/cleanup-attempts" ;;
    esac

    if [ "${FAIL_CLEANUP:-0}" = 1 ]; then
      echo 'stub gh: simulated GraphQL failure' >&2
      exit 1
    fi
    case "$query" in
      *mutation*)
        jq -cn '{data: {minimizeComment: {minimizedComment: {isMinimized: true}}}}'
        ;;
      *)
        jq -cn '{data: {repository: {pullRequest: {reviews: {nodes: [],
          pageInfo: {hasNextPage: false, endCursor: null}}}}}}'
        ;;
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

# opencode is only ever the repair turn. It records its arguments and its last,
# positional, argument (the repair prompt), then prints the repair fixture.
cat > "$tmp/opencode" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir=$(dirname -- "$0")

jq -cn --args '$ARGS.positional' -- "$@" >> "$dir/opencode-calls.jsonl"
printf '%s' "${!#}" > "$dir/repair-prompt"

if [ ! -f "$dir/repair-events.jsonl" ]; then
  echo 'stub opencode: no repair fixture' >&2
  exit 2
fi

cat -- "$dir/repair-events.jsonl"
STUB
chmod +x "$tmp/opencode"

# One 'opencode run --format json' stream: step_start, the reply as a finished
# text event when there is one, any extra raw event lines, then step_finish.
events() {
  local text=$1
  shift

  jq -cn '{type: "step_start", timestamp: 1, sessionID: "ses_test",
    part: {type: "step-start"}}'

  if [ -n "$text" ]; then
    jq -cn --arg text "$text" '{type: "text", timestamp: 2, sessionID: "ses_test",
      part: {type: "text", text: $text, time: {start: 1, end: 2}}}'
  fi

  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
  fi

  jq -cn '{type: "step_finish", timestamp: 3, sessionID: "ses_test",
    part: {type: "step-finish", reason: "stop"}}'
}

# A reviewer reply: the marker, an optional verdict line, any prose lines, then
# the findings block with the findings on one line.
reply() {
  local verdict=$1 findings=$2
  shift 2

  printf '%s\n' "$marker"

  if [ -n "$verdict" ]; then
    printf '%s\n' "$verdict"
  fi

  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" ''
  fi

  printf '%s\n' '<!-- opencode-findings-json' "$findings" '-->'
}

run_main() {
  rm -f -- "$tmp/writes" "$tmp/comment-payload.json" "$tmp/review-payload.json" \
    "$tmp/cleanup-attempts" "$tmp/opencode-calls.jsonl" "$tmp/repair-prompt"

  GH="$tmp/gh" OPENCODE="$tmp/opencode" MODEL="${1:-}" \
    FAIL_CLEANUP="$FAIL_CLEANUP" REPO=owner/repo PR=7 GH_TOKEN=test \
    DIFF="$tmp/diff.patch" EVENTS="$tmp/events.jsonl" OUT="$tmp/out" \
    bash "$script" > "$tmp/main.out" 2> "$tmp/main.err"
}

expect_posted() {
  if ! run_main "$@"; then
    cat -- "$tmp/main.out" "$tmp/main.err" >&2
    return 1
  fi

  printf '%s\n' 'POST repos/owner/repo/issues/7/comments' \
    'POST repos/owner/repo/pulls/7/reviews' > "$tmp/expected-writes"
  diff -u -- "$tmp/expected-writes" "$tmp/writes"
}

# A rejected stream exits non-zero, names the reason on stderr when one is
# given, and writes nothing.
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

# The marker comment holds each finding of $findings exactly once, as a
# '- path:line: body' bullet under its own severity header, MUST first.
expect_sections() {
  jq -e '
    def at($s): (map(select(. == $s)) | length) as $n
      | if $n == 1 then index($s) else error("\($n) lines equal \($s)") end;
    .body | split("\n")
    | at("**MUST**") < at("- a.txt:2: Fix this.")
      and at("- a.txt:2: Fix this.") < at("**SHOULD**")
      and at("**SHOULD**") < at("- a.txt:9: Off the diff.")
  ' "$tmp/comment-payload.json" > /dev/null
}

# One MUST on the added line 2 and one SHOULD on line 9, outside the diff.
findings=$(jq -c . <<'JSON'
[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."},
 {"path":"a.txt","line":9,"side":"RIGHT","severity":"SHOULD","body":"Off the diff."}]
JSON
)

# Model-written sections that disagree with the JSON; the comment must not keep them.
prose=('Review summary.' '' '**MUST**' '- a.txt:3: Stale model claim.' '' \
  '**SHOULD**' '- a.txt:4: Stale model claim too.')

events "$(reply "$fix_first" "$findings" "${prose[@]}")" > "$tmp/events.jsonl"
expect_posted
[ ! -s "$tmp/cleanup-attempts" ]
jq -e --arg marker "$marker" --arg verdict "$fix_first" '
  .body | split("\n")
  | .[0] == $marker and .[1] == $verdict and any(.[]; . == "Review summary.")
    and all(.[]; contains("Stale model claim") | not)
' "$tmp/comment-payload.json" > /dev/null
expect_sections
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
  and (.body | split("\n") | any(.[]; . == "- a.txt:9 (SHOULD): Off the diff."))
' "$tmp/review-payload.json" > /dev/null
printf 'ok: valid reply renders its findings from JSON and posts a COMMENT review\n'
printf 'ok: normal posting makes no cleanup mutations\n'

# The terse repair seen on sourcefed#104: the first turn has no text event at
# all, and the repair holds only the marker, the verdict and the findings block.
repair_model=fixture/reviewer
events '' > "$tmp/events.jsonl"
events "$(reply "$fix_first" "$findings")" > "$tmp/repair-events.jsonl"
expect_posted "$repair_model"
rm -f -- "$tmp/repair-events.jsonl"
jq -se --arg model "$repair_model" '
  length == 1 and (.[0]
    | length == 10
      and .[:9] == ["run", "--model", $model, "--variant", "low",
        "--format", "json", "--session", "ses_test"]
      and (.[9] | type == "string" and . != ""))
' "$tmp/opencode-calls.jsonl" > /dev/null
jq -Rse '
  [split("\n")[] | select(startswith("Review events: "))
    | ltrimstr("Review events: ") | fromjson | .attempts]
  | last == 2
' "$tmp/main.out" > /dev/null
expect_sections
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
' "$tmp/review-payload.json" > /dev/null
printf 'ok: terse repair reply renders the MUST and SHOULD sections from JSON\n'

# The repair prompt the reviewer received spells out the reply shape, ending
# with the closed findings block: the opener, one JSON line, and --> alone.
jq -Rse --arg marker "$marker" '
  contains($marker) and contains("**Verdict: ")
  and (split("\n") as $l
    | [range(0; ($l | length) - 2)
        | select($l[.] == "<!-- opencode-findings-json"
          and ($l[. + 1] | try (fromjson | type == "array") catch false)
          and $l[. + 2] == "-->")]
    | length == 1)
' "$tmp/repair-prompt" > /dev/null
printf '%s\n' \
  'ok: repair prompt holds the marker, verdict shape and closed findings block'

# sourcefed#105: a findings block that parses but fails validation gets one
# repair turn, and the valid repair reply posts.
invalid=$(jq -c '.[0].line = 0' <<< "$findings")
events "$(reply "$fix_first" "$invalid" 'Review summary.')" > "$tmp/events.jsonl"
events "$(reply "$fix_first" "$findings")" > "$tmp/repair-events.jsonl"
expect_posted "$repair_model"
rm -f -- "$tmp/repair-events.jsonl"
jq -se 'length == 1' "$tmp/opencode-calls.jsonl" > /dev/null
jq -Rse '
  [split("\n")[] | select(startswith("Review events: "))
    | ltrimstr("Review events: ") | fromjson | .attempts]
  | last == 2
' "$tmp/main.out" > /dev/null
expect_sections
printf 'ok: invalid findings JSON is repaired once and the repair posts\n'

# Findings in a fenced json code block instead of the HTML comment block are
# accepted on the first turn: no MODEL is given, so a repair could not run.
fence='```'
fenced=$(printf '%s\n' "$marker" "$fix_first" 'Review summary.' '' \
  "${fence}json" "$findings" "$fence")
events "$fenced" > "$tmp/events.jsonl"
expect_posted
[ ! -e "$tmp/opencode-calls.jsonl" ]
jq -Rse '
  [split("\n")[] | select(startswith("Review events: "))
    | ltrimstr("Review events: ") | fromjson | .attempts]
  == [1]
' "$tmp/main.out" > /dev/null
expect_sections
jq -e --arg fence "$fence" '.body | contains($fence) | not' \
  "$tmp/comment-payload.json" > /dev/null
jq -e '.event == "COMMENT"
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
' "$tmp/review-payload.json" > /dev/null
printf 'ok: fenced json findings post without a repair turn\n'

events "$(reply '' "$findings" "${prose[@]}")" > "$tmp/events.jsonl"
expect_posted
jq -e --arg verdict "$fix_first" '.body | split("\n") | .[1] == $verdict' \
  "$tmp/comment-payload.json" > /dev/null
jq -e --arg verdict "$fix_first" '.body | split("\n") | .[0] == $verdict' \
  "$tmp/review-payload.json" > /dev/null
printf 'ok: reply without a verdict posts the verdict derived from JSON\n'

events "$(reply "$fix_first" '[{"path":"a.txt","line":' "${prose[@]}")" \
  > "$tmp/events.jsonl"
expect_rejected JSON
printf 'ok: malformed findings JSON fails without posting\n'

should_only=$(jq -c . <<'JSON'
[{"path":"a.txt","line":9,"side":"RIGHT","severity":"SHOULD","body":"Off the diff."}]
JSON
)
events "$(reply "$fix_first" "$should_only" 'Review summary.')" > "$tmp/events.jsonl"
expect_posted
merge_as_is='**Verdict: MERGE AS IS**'
jq -e --arg verdict "$merge_as_is" '.body | split("\n") | .[1] == $verdict' \
  "$tmp/comment-payload.json" > /dev/null
jq -e --arg verdict "$merge_as_is" '.body | split("\n") | .[0] == $verdict' \
  "$tmp/review-payload.json" > /dev/null
grep -qi -- 'warning' "$tmp/main.err"
printf 'ok: mismatched verdict warns and posts the verdict derived from JSON\n'

# Context and added lines stay inline; a deleted line and a line outside the
# hunk become bullets in the review body.
placed=$(jq -c . <<'JSON'
[{"path":"a.txt","line":1,"side":"RIGHT","severity":"MUST","body":"Context line."},
 {"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Added line."},
 {"path":"a.txt","line":2,"side":"LEFT","severity":"SHOULD","body":"Deleted line."},
 {"path":"a.txt","line":7,"side":"RIGHT","severity":"SHOULD",
  "body":"Not in the hunk."}]
JSON
)
events "$(reply "$fix_first" "$placed" 'Review summary.')" > "$tmp/events.jsonl"
expect_posted
jq -e '.event == "COMMENT"
  and .comments == [
    {path: "a.txt", line: 1, side: "RIGHT", body: "Context line."},
    {path: "a.txt", line: 2, side: "RIGHT", body: "Added line."}
  ]
  and (.body | split("\n")
    | any(.[]; . == "- a.txt:2 (SHOULD): Deleted line.")
      and any(.[]; . == "- a.txt:7 (SHOULD): Not in the hunk."))
' "$tmp/review-payload.json" > /dev/null
printf 'ok: findings outside the diff become review body bullets, not inline\n'

unanchored=$(jq -c . <<'JSON'
[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."},
 {"path":null,"line":2,"side":"RIGHT","severity":"MUST","body":"General note."},
 {"path":"a.txt","line":null,"side":"RIGHT","severity":"SHOULD",
  "body":"Off the diff."}]
JSON
)
events "$(reply "$fix_first" "$unanchored" 'Review summary.')" > "$tmp/events.jsonl"
expect_posted
jq -e '.body | split("\n") | map(select(startswith("- ")))
  | (map(select(endswith("General note."))) | length) == 1
    and (map(select(. == "- a.txt: Off the diff.")) | length) == 1
' "$tmp/comment-payload.json" > /dev/null
jq -e '
  .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
  and (.body | split("\n")
    | map(select(. == "- a.txt (SHOULD): Off the diff.")) | length == 1)
' "$tmp/review-payload.json" > /dev/null
printf 'ok: null path or line findings are marker bullets, not inline comments\n'

events "$(reply "$fix_first" "$findings" "${prose[@]}")" \
  "$(jq -cn '{type: "error", timestamp: 3, sessionID: "ses_test",
    error: {name: "APIError", data: {message: "provider overloaded"}}}')" \
  > "$tmp/events.jsonl"
expect_rejected ''
printf 'ok: an error event fails without posting\n'

with_commit=$(jq -c '
  .[0] += {body: "Fix this. (commit abc1234)", commit: "abc1234"}
' <<< "$findings")
events "$(reply "$fix_first" "$with_commit" 'Review summary.')" > "$tmp/events.jsonl"
expect_posted
jq -e '.body
  | (split("\n")
    | map(select(. == "- a.txt:2: Fix this. (commit abc1234)")) | length == 1)
    and (contains(" (commit abc1234) (commit abc1234)") | not)
' "$tmp/comment-payload.json" > /dev/null
printf 'ok: marker comment renders the commit suffix exactly once\n'

commit_only=$(jq -c '.[0].commit = "abc1234"' <<< "$findings")
events "$(reply "$fix_first" "$commit_only" 'Review summary.')" > "$tmp/events.jsonl"
expect_posted
jq -e '.body | split("\n")
  | map(select(startswith("- a.txt:2: ")))
    == ["- a.txt:2: Fix this. (commit abc1234)"]
' "$tmp/comment-payload.json" > /dev/null
printf 'ok: marker comment appends the missing commit suffix exactly once\n'

footer='[Build evidence run](https://example.com/builds/123)'
events "$(reply "$fix_first" "$findings" 'Review summary.' '' "$footer")" \
  > "$tmp/events.jsonl"
expect_posted
jq -e --arg footer "$footer" '.body
  | (split("\n") | any(.[]; . == "Review summary."))
    and (contains($footer) | not)
' "$tmp/comment-payload.json" > /dev/null
printf 'ok: marker comment strips an arbitrary trailing run footer\n'

events "$(reply "$fix_first" "$findings" "${prose[@]}")" > "$tmp/events.jsonl"
FAIL_CLEANUP=1 expect_posted
# The failed listing must not lead to any GraphQL mutation.
printf '%s\n' 'DELETE repos/owner/repo/issues/comments/122' \
  > "$tmp/expected-cleanup-attempts"
diff -u -- "$tmp/expected-cleanup-attempts" "$tmp/cleanup-attempts"
printf 'ok: failed cleanup keeps both posts and exits 0\n'
