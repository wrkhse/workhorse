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

write_commit_digest() {
  local sha="$1"
  local -a show_opts=(--diff-merges=first-parent --no-ext-diff --no-textconv
    --no-color --no-notes --no-show-signature)

  git show "${show_opts[@]}" --format='commit %H %s' --name-only "$sha" |
    awk 'NR == 1 { print; next } length($0) { print "file " $0 }'

  git show "${show_opts[@]}" --format= --unified=0 --no-prefix "$sha" |
    awk '
      /^diff --git / { in_hunk = 0; next }
      !in_hunk && /^--- / { old_path = substr($0, 5); sub(/\t$/, "", old_path); next }
      !in_hunk && /^\+\+\+ / { new_path = substr($0, 5); sub(/\t$/, "", new_path); next }
      /^@@ / {
        old_line = substr($2, 2) + 0
        new_line = substr($3, 2) + 0
        in_hunk = 1
        next
      }
      !in_hunk { next }
      /^ / { old_line++; new_line++; next }
      /^[+-]/ {
        sign = substr($0, 1, 1)
        text = substr($0, 2)
        if (sign == "+") {
          path = new_path
          line = new_line++
        } else {
          path = old_path
          line = old_line++
        }

        if (text ~ /#\[(allow|expect|ignore|test)|cfg\(not\(test\)\)|mutants::skip|mutants\.toml/ ||
            text ~ /continue-on-error|\|\| true|set \+e|deny\.toml|clippy\.toml/ ||
            text ~ /timeout-minutes|retry|permissions:|paths:|assert|skip/) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
          printf "%s %s:%d: %s\n", sign, path, line, text
        }
      }
    '
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
    write_commit_digest "$sha"
  done

  # Keep rev-list from failing with SIGPIPE after the loop reaches the cap.
  cat > /dev/null
} | write_capped "$OUT/commits-digest.txt" 200000 "$OUT/commits-digest.txt"

for f in AGENTS.md CONTRIBUTING.md; do
  if git cat-file -e "$BASE:$f" 2> /dev/null; then
    dest="$OUT/rules/$f"
    git show "$BASE:$f" | write_capped "$dest" "$MAX_BYTES" "$dest"
  fi
done

cat -- "$PR_JSON" | write_capped "$OUT/pr.json" "$MAX_BYTES" "$OUT/pr.json"

# A docs-only PR gets an advisory verdict. Classification uses the complete
# file list from the GitHub API and the expected count in the CHANGED_FILES file:
# gh pr view's files array stops at 100 entries, while the API count covers
# them all. A renamed file must pass on both its old and new path. Anything
# missing, unreadable or inconsistent fails toward blocking.
docs_only=false
changed=""
if [ -n "${CHANGED_FILES-}" ] && [ -f "$CHANGED_FILES" ]; then
  changed=$(cat -- "$CHANGED_FILES" | tr -d '[:space:]') || changed=""
fi
if [[ "$changed" =~ ^[0-9]+$ ]] &&
   api_files=$("$GH" api --paginate "repos/$REPO/pulls/${PR-}/files" 2>/dev/null); then
  docs_only=$(printf '%s' "$api_files" | jq -rs \
    --argjson changed "$changed" '
    def image:
      endswith(".png") or endswith(".jpg") or endswith(".gif");

    def allowed:
      ascii_downcase as $p
      | ($p | startswith(".github/") | not)
        and (($p | endswith(".md"))
          or ((($p | startswith("docs/")) or ($p | startswith("site/")))
              and ($p | image)));

    # Governance files are never docs-only, on the old and new path of a
    # rename alike.
    def governance:
      . as $p
      | $p == "AGENTS.md"
        or $p == "CLAUDE.md"
        or $p == "CONTRIBUTING.md"
        or $p == "PHILOSOPHY.md"
        or $p == "SECURITY.md"
        or $p == "docs/repository-standards.md"
        or $p == "docs/issues-and-pull-requests.md"
        or ($p | startswith(".opencode/"))
        or ($p | startswith(".github/"))
        or ($p | split("/") | last | endswith("AGENTS.md"));

    if (length == 0 or any(.[]; type != "array")) then
      false
    else
      add as $files
      | if ($files | length) == 0
           or ($changed != ($files | length)) then
          false
        else
          ($files | all(
            (.filename? // "") as $filename
            | (.previous_filename? // "") as $previous
            | ($filename | type == "string" and allowed and (governance | not))
              and (if (.status? // "") == "renamed" or (.previous_filename? != null) then
                     ($previous | type == "string" and allowed and (governance | not))
                   else true end)
          ))
        end
    end
  ') || docs_only=false
fi
printf '%s\n' "$docs_only" > "$OUT/docs-only.txt"

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
