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
  printf '%s\n' 'Review summary.' '' '[github run](https://github.example/run/1)' '' \
    '<!-- opencode-findings-json' "$1" '-->' > "$tmp/comment"
}

payload() {
  prepare_review "$tmp/comment" "$tmp/diff.patch" "$tmp"
}

assert_fallback() {
  payload | jq -e '. == {
    body: "Review summary.\n\nInline comments were skipped because the findings JSON was malformed."
  }' > /dev/null
}

write_comment '[
  {"path":"a.txt","line":2.0,"severity":"MUST","body":"Fix this.","commit":"abc"},
  {"path":"a.txt","line":7,"side":"RIGHT","severity":"SHOULD","body":"Consider this."}
]'
extract_findings "$tmp/comment" | jq -e 'map(.side) == ["RIGHT","RIGHT"]' > /dev/null
payload | jq -e '. == {
  event: "COMMENT",
  body: ("Review summary.\n\nSome findings were moved here because they could not be posted inline."
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
  body: ("Review summary.\n\nSome findings were moved here because they could not be posted inline."
    + "\n\n- a.txt:2 (SHOULD): Old line.\n- a.txt:3 (MUST): Deleted line."),
  comments: [{path:"a.txt",line:1,side:"RIGHT",body:"Context."}]
}' > /dev/null
printf 'ok: context and deletion sides\n'

write_comment '[broken'
assert_fallback
printf 'ok: malformed JSON falls back without inline comments\n'

printf '%s\n' 'Review summary.' '[github run](https://github.example/run/1)' > "$tmp/comment"
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
  body: "Review summary.",
  comments: [
    {path:"a.txt",line:18,side:"RIGHT",body:"Second hunk."},
    {path:"b.txt",line:1,side:"RIGHT",body:"Second file."}
  ]
}' > /dev/null
printf 'ok: multiple hunks and files\n'
