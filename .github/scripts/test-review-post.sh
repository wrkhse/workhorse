#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/post-review.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-review-post.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

cat > "$tmp/diff.patch" <<'DIFF'
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,4 +1,2 @@
 keep
-removed
-also removed
-old value
+new value
@@ -20 +18 @@
-old second hunk
+new second hunk
diff --git a/b.txt b/b.txt
--- /dev/null
+++ b/b.txt
@@ -0,0 +1 @@
+second file
DIFF

write_comment() {
  printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' 'Review summary.' '' \
    '[github run](https://github.example/run/1)' '' \
    '<!-- opencode-findings-json' "$1" '-->' > "$tmp/comment"
}

payload() {
  prepare_review "$tmp/comment" "$tmp/diff.patch" "$tmp"
}

# A plain fallback comment is the only payload key and carries the marker, the
# verdict line and each expected finding as a whole bullet line.
assert_plain_fallback() {
  jq -e --args '
    keys == ["body"]
    and (.body | startswith("<!-- opencode-review -->"))
    and (.body | test("(^|\n)\\*\\*Verdict:"))
    and ($ARGS.positional - (.body | split("\n")) == [])
  ' "$@" > /dev/null
}

assert_fallback() {
  payload | assert_plain_fallback
}

write_comment '[
  {"path":"a.txt","line":2.0,"severity":"MUST","body":"Fix this.","commit":"abc"},
  {"path":"a.txt","line":7,"side":"RIGHT","severity":"SHOULD","body":"Consider this."}
]'
extract_findings "$tmp/comment" | jq -e 'map(.side) == ["RIGHT","RIGHT"]' > /dev/null
payload | jq -e '. == {
  event: "COMMENT",
  body: ("**Verdict: FIX FIRST**\n\nSome findings were moved here because they could not be posted inline."
    + "\n\n- a.txt:7 (SHOULD): Consider this."),
  comments: [{path:"a.txt",line:2,side:"RIGHT",body:"Fix this."}]
}' > /dev/null
printf 'ok: valid block, inline finding, and out-of-hunk bullet\n'

write_comment '[
  {"path":"a.txt","line":1,"side":"RIGHT","severity":"MUST","body":"Context."},
  {"path":"a.txt","line":2,"side":"LEFT","severity":"SHOULD","body":"Old line."},
  {"path":"a.txt","line":3,"side":"RIGHT","severity":"MUST","body":"Deleted line."}
]'
payload | jq -e '. == {
  event: "COMMENT",
  body: ("**Verdict: FIX FIRST**\n\nSome findings were moved here because they could not be posted inline."
    + "\n\n- a.txt:2 (SHOULD): Old line.\n- a.txt:3 (MUST): Deleted line."),
  comments: [{path:"a.txt",line:1,side:"RIGHT",body:"Context."}]
}' > /dev/null
printf 'ok: context and deletion sides\n'

write_comment '[broken'
assert_fallback
printf 'ok: malformed JSON falls back without inline comments\n'

printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' 'Review summary.' \
  '[github run](https://github.example/run/1)' > "$tmp/comment"
assert_fallback
printf 'ok: absent block falls back without inline comments\n'

finding='{path:"a.txt",line:2,severity:"MUST",body:"Note."}'
write_comment "$(jq -n "[range(31) | $finding]")"
assert_fallback
printf 'ok: more than 30 findings rejected\n'

write_comment "$(jq -n "[$finding | .body = (\"x\" * 1501)]")"
assert_fallback
printf 'ok: 1501-character body rejected\n'

write_comment '[
  {"path":"a.txt","line":18,"severity":"MUST","body":"Second hunk."},
  {"path":"b.txt","line":1,"severity":"SHOULD","body":"Second file."}
]'
payload | jq -e '. == {
  event: "COMMENT",
  body: "**Verdict: FIX FIRST**",
  comments: [
    {path:"a.txt",line:18,side:"RIGHT",body:"Second hunk."},
    {path:"b.txt",line:1,side:"RIGHT",body:"Second file."}
  ]
}' > /dev/null
printf 'ok: multiple hunks and files\n'

# The stub gh lives in $tmp and records each POST payload beside itself, so
# main runs its real posting path without the network.
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir=$(dirname -- "$0")
[ "${1:-}" = api ] || { echo "stub gh: unexpected command: $*" >&2; exit 2; }
shift
method=GET endpoint='' input='' query='' id=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    -f | -F)
      case "$2" in
        query=*) query=${2#query=} ;;
        id=*) id=${2#id=} ;;
      esac
      shift 2
      ;;
    --paginate | --silent) shift ;;
    -*) echo "stub gh: unexpected flag: $1" >&2; exit 2 ;;
    *) endpoint=$1; shift ;;
  esac
done
case "$method $endpoint" in
  'GET repos/'*'/issues/'*'/comments')
    if [ -e "$dir/malformed" ]; then
      cat -- "$dir/issue-comments-malformed.json"
    elif [ -e "$dir/no-verdict" ]; then
      cat -- "$dir/issue-comments-no-verdict.json"
    else
      cat -- "$dir/issue-comments.json"
    fi
    ;;
  'POST repos/'*'/pulls/'*'/reviews')
    cp -- "$input" "$dir/review-payload.json"
    if [ -e "$dir/review-fails" ]; then
      echo 'gh: Validation Failed (HTTP 422)' >&2
      exit 1
    fi
    printf '%s\n' '{"node_id":"PRR_test"}'
    ;;
  'POST repos/'*'/issues/'*'/comments') cp -- "$input" "$dir/fallback-payload.json" ;;
  'GET graphql')
    case "$query" in
      *'mutation('*)
        printf '%s\n' "$id" >> "$dir/minimized"
        printf '%s\n' '{"data":{"minimizeComment":{"minimizedComment":{"isMinimized":true}}}}'
        ;;
      *)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[
          {"id":"PRR_old","author":{"login":"github-actions","__typename":"Bot"},"isMinimized":false,
            "body":"<!-- opencode-review -->\n**Verdict: SHIP**"},
          {"id":"PRR_unrelated","author":{"login":"github-actions","__typename":"Bot"},"isMinimized":false,
            "body":"Another workflow review without the marker."},
          {"id":"PRR_test","author":{"login":"github-actions","__typename":"Bot"},"isMinimized":false,
            "body":"<!-- opencode-review -->\n**Verdict: FIX FIRST**"}
        ],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
        ;;
    esac
    ;;
  *) echo "stub gh: unexpected request: $method $endpoint" >&2; exit 2 ;;
esac
STUB
chmod +x "$tmp/gh"

summary='This summary belongs only in the marker comment.'
printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' "$summary" '' \
  '**MUST**' '- a.txt:2 Fix this.' '' '[github run](https://github.example/run/1)' '' \
  '<!-- opencode-findings-json' \
  '[{"path":"a.txt","line":2,"side":"RIGHT","severity":"MUST","body":"Fix this."},
    {"path":"a.txt","line":7,"side":"RIGHT","severity":"SHOULD","body":"Off the diff."}]' \
  '-->' > "$tmp/marker-comment"
jq -n --rawfile body "$tmp/marker-comment" \
  '[{id: 1, user: {login: "github-actions[bot]"}, body: $body}]' > "$tmp/issue-comments.json"
sed '/^\*\*Verdict:/d' "$tmp/marker-comment" > "$tmp/marker-comment-no-verdict"
jq -n --rawfile body "$tmp/marker-comment-no-verdict" \
  '[{id: 1, user: {login: "github-actions[bot]"}, body: $body}]' > "$tmp/issue-comments-no-verdict.json"
printf '%s\n' '<!-- opencode-review -->' '**Verdict: FIX FIRST**' "$summary" '' \
  '<!-- opencode-findings-json' '[broken' '-->' > "$tmp/marker-comment-malformed"
jq -n --rawfile body "$tmp/marker-comment-malformed" \
  '[{id: 1, user: {login: "github-actions[bot]"}, body: $body}]' > "$tmp/issue-comments-malformed.json"

# A fresh bash runs main through the script's own entrypoint: inside an if or ||
# the caller's set -e is off, so calling main in-process would mask its failures.
run_main() {
  rm -f -- "$tmp/review-payload.json" "$tmp/fallback-payload.json" "$tmp/minimized"
  GH="$tmp/gh" REPO=owner/repo PR=7 GH_TOKEN=test DIFF="$tmp/diff.patch" OUT="$tmp/out" \
    bash "$(dirname -- "${BASH_SOURCE[0]}")/post-review.sh" > "$tmp/main.out" 2> "$tmp/main.err"
}

post_with_stub() {
  if ! run_main; then
    cat -- "$tmp/main.out" "$tmp/main.err" >&2
    return 1
  fi
}

post_with_stub
jq -e --arg summary "$summary" '
  .event == "COMMENT"
  and (.body | startswith("**Verdict: FIX FIRST**"))
  and (.body | contains($summary) | not)
  and .comments == [{path: "a.txt", line: 2, side: "RIGHT", body: "Fix this."}]
' "$tmp/review-payload.json" > /dev/null
[ ! -e "$tmp/fallback-payload.json" ]
# Only the older marker-bearing bot review is minimized; PRR_unrelated has no marker.
[ "$(cat -- "$tmp/minimized")" = PRR_old ]
printf 'ok: stub gh review has verdict body and inline comments on diff lines only\n'
printf 'ok: only the older marker-bearing bot review is minimized\n'

touch -- "$tmp/review-fails"
post_with_stub
assert_plain_fallback '- a.txt:2 (MUST): Fix this.' '- a.txt:7 (SHOULD): Off the diff.' \
  < "$tmp/fallback-payload.json"
printf 'ok: failed review POST falls back to a plain marker comment with every finding\n'

rm -f -- "$tmp/review-fails"
touch -- "$tmp/malformed"
post_with_stub
assert_plain_fallback < "$tmp/fallback-payload.json"
[ ! -e "$tmp/review-payload.json" ]
printf 'ok: malformed findings JSON falls back to a plain marker comment\n'

rm -f -- "$tmp/malformed"
touch -- "$tmp/no-verdict"
if run_main; then
  echo 'main succeeded on a marker comment without a Verdict line' >&2
  exit 1
fi
if ! grep -q 'Verdict' "$tmp/main.err"; then
  cat -- "$tmp/main.err" >&2
  exit 1
fi
[ ! -e "$tmp/review-payload.json" ]
[ ! -e "$tmp/fallback-payload.json" ]
printf 'ok: marker comment without a Verdict line fails before posting\n'
