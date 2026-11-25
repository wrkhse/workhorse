#!/usr/bin/env bash
set -euo pipefail

: "${BASE:?BASE is required}" "${HEAD:?HEAD is required}"
: "${PR_JSON:?PR_JSON is required}" "${REPO:?REPO is required}"

OUT="${OUT:-review-input}"
GH="${GH:-gh}"
MAX_BYTES="${MAX_BYTES:-2000000}"
MAX_COMMITS="${MAX_COMMITS:-100}"

if [[ ! "$MAX_BYTES" =~ ^[0-9]{1,18}$ || ! "$MAX_COMMITS" =~ ^[0-9]{1,18}$ ]]; then
  echo 'MAX_BYTES and MAX_COMMITS must be nonnegative integers of at most 18 digits.' >&2
  exit 1
fi

rm -rf -- "$OUT"
mkdir -p -- "$OUT/commits" "$OUT/rules"
notes="$OUT/NOTES.txt"
: > "$notes"

write_capped() {
  local dest="$1" max="$2" label="$3"
  local tmp="$dest.tmp" size
  head -c "$((10#$max + 1))" > "$tmp"
  # Drain to /dev/null to avoid SIGPIPE; the 30-minute review job timeout bounds both drains.
  cat > /dev/null
  size=$(wc -c < "$tmp")

  if [ "$size" -gt "$max" ]; then
    head -c "$max" -- "$tmp" > "$dest"
    rm -- "$tmp"
    printf '%s exceeded %s bytes and was cut.\n' "$label" "$max" >> "$notes"
  else
    mv -- "$tmp" "$dest"
  fi
}

git diff "$BASE...$HEAD" | write_capped "$OUT/diff.patch" "$MAX_BYTES" "$OUT/diff.patch"

total=$(git rev-list --count "$BASE..$HEAD")
if [ "$total" -gt "$MAX_COMMITS" ]; then
  printf 'Only the first %s of %s commits are in commits/.\n' "$MAX_COMMITS" "$total" >> "$notes"
fi

git rev-list --reverse "$BASE..$HEAD" | {
  n=0

  while [ "$n" -lt "$MAX_COMMITS" ] && IFS= read -r sha; do
    n=$((n + 1))
    dest="$OUT/commits/$(printf '%03d' "$n")-$sha.patch"
    git show --stat --patch "$sha" | write_capped "$dest" "$MAX_BYTES" "$dest"
  done

  # Keep rev-list from failing with SIGPIPE after the loop reaches the cap.
  cat > /dev/null
}

for f in AGENTS.md CONTRIBUTING.md; do
  if git cat-file -e "$BASE:$f" 2> /dev/null; then
    dest="$OUT/rules/$f"
    git show "$BASE:$f" | write_capped "$dest" "$MAX_BYTES" "$dest"
  fi
done

cat -- "$PR_JSON" | write_capped "$OUT/pr.json" "$MAX_BYTES" "$OUT/pr.json"

# The capped copy is for the reviewer and may no longer be valid JSON.
issue=$(jq -r --arg repo "$REPO" '
  def code_snippet:
    "^ {0,3}(?<fence>`{3,}(?!`)|~{3,}(?!~))[^\\n]*\\n"
    + "[\\s\\S]*?(?:^ {0,3}\\k<fence>(?:(?<=`)`*|(?<=~)~*)[ \\t\\r]*$|\\z)"
    + "|^(?: {4}|\\t)[^\\n]*"
    + "|(?<!`)(?<ticks>`+)(?!`)[\\s\\S]*?(?<!`)\\k<ticks>(?!`)";

  ($repo | gsub("(?<char>[^A-Za-z0-9_/-])"; "\\" + .char)) as $escaped_repo
  | (code_snippet
    + "|\\b(?:Part[ \\t]+of|Closes|Fixes)[ \\t]+#(?<phrase>[0-9]+)(?![\\w-])"
    + "|(?<![\\w./:%@-])(?:https?://github\\.com)?/"
    + $escaped_repo + "/issues/(?<url>[0-9]+)(?![\\w-])"
    + "|https?://[^\\s<>()]+") as $pattern
  | first(
      (.body // "") | match("(?m)" + $pattern; "g") | .captures[]
      | select(.name == "phrase" or .name == "url") | .string | strings
    ) // ""
' "$PR_JSON")

if [ -z "$issue" ]; then
  echo 'No linked issue found.'
  exit 0
fi

err=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/review-issue-err.XXXXXX")
stage="$OUT/issue.json.tmp"
raw_issue="$OUT/issue.json.raw"
trap 'rm -f -- "$err" "$stage" "$raw_issue"' EXIT

if "$GH" issue view "$issue" -R "$REPO" --json title,body > "$stage" 2> "$err"; then
  # Free issue.json.tmp for write_capped without overwriting its input.
  mv -- "$stage" "$raw_issue"
  write_capped "$OUT/issue.json" "$MAX_BYTES" "$OUT/issue.json" < "$raw_issue"
  rm -- "$raw_issue"
elif grep -qiE 'could not resolve|not found' "$err"; then
  rm -- "$stage"
  printf 'Linked issue #%s was not found in %s.\n' "$issue" "$REPO"
else
  cat -- "$err" >&2
  exit 1
fi
