#!/usr/bin/env bash
set -euo pipefail

# Starts every comment this workflow manages: the review, and both fallbacks below.
review_marker='<!-- opencode-review -->'

# The marker comment keeps the full review for workers; the review body repeats only its verdict.
review_body() {
  awk '
    /^<!-- opencode-findings-json[[:space:]]*$/ { exit }
    /^\*\*Verdict:/ { sub(/[[:space:]]+$/, ""); printf "%s", $0; found = 1; exit }
    END { if (!found) printf "%s", "See the opencode review comment on this pull request for the full review." }
  ' < "$1"
}

extract_findings() {
  awk '
    !started && /^<!-- opencode-findings-json[[:space:]]*$/ { started = 1; next }
    started && /^-->[[:space:]]*$/ { closed = 1; exit }
    started { print }
    END { if (!closed) exit 1 }
  ' < "$1" | jq -cse '
    def side: if has("side") then .side else "RIGHT" end;
    def valid_finding:
      type == "object"
      and (.path | type == "string")
      and (.line | type == "number" and . >= 1 and floor == .)
      and (side == "RIGHT" or side == "LEFT")
      and (.severity == "MUST" or .severity == "SHOULD")
      and (.body | type == "string" and length >= 1 and length <= 1500)
      and (if has("commit") then (.commit | type == "string") else true end);
    select(length == 1) | .[0]
    | select(type == "array" and length <= 30 and all(.[]; valid_finding))
    | map(.side = side | .line |= floor)
  '
}

right_lines() {
  awk '
    /^diff --git / { path = ""; in_hunk = 0; remaining = 0; next }
    !in_hunk && /^\+\+\+ b\// {
      path = substr($0, 7)
      sub(/\t$/, "", path)
      next
    }
    !in_hunk && /^\+\+\+ "b\/.*"\t?$/ {
      path = substr($0, 8)
      sub(/"\t?$/, "", path)
      next
    }
    !in_hunk && /^\+\+\+ \/dev\/null$/ { path = ""; next }
    /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ {
      in_hunk = 1
      fields = split(substr($3, 2), range, ",")
      n = range[1] + 0
      remaining = fields == 2 ? range[2] + 0 : 1
      next
    }
    path != "" && remaining > 0 && /^[ +]/ {
      printf "%s\t%d\n", path, n
      n++
      remaining--
    }
  ' < "$1"
}

prepare_review() {
  local comment="$1" diff="$2" work="$3"

  review_body "$comment" > "$work/body"
  if ! extract_findings "$comment" > "$work/findings.json" 2> /dev/null; then
    jq -n --arg marker "$review_marker" --rawfile body "$work/body" '
      ($body | if startswith("**Verdict:") then . else "**Verdict: FIX FIRST**" end) as $verdict
      | {body: ($marker + "\n" + $verdict
          + "\n\nInline comments were skipped because the findings JSON was malformed.")}
    '
    return
  fi

  right_lines "$diff" > "$work/right-lines"
  jq -n --rawfile body "$work/body" --slurpfile findings "$work/findings.json" \
    --rawfile lines "$work/right-lines" '
    ($lines | split("\n") | map({key: ., value: true}) | from_entries) as $valid
    | ($findings[0] | map(. + {inline: (.side == "RIGHT" and
        ($valid[.path + "\t" + (.line | tostring)] == true))})) as $findings
    | ($findings | map(select(.inline | not)
        | "- \(.path):\(.line) (\(.severity)): \(.body)")) as $bullets
    | {
        event: "COMMENT",
        body: ([$body, (
          if $bullets == [] then ""
          else "Some findings were moved here because they could not be posted inline.\n\n"
            + ($bullets | join("\n"))
          end
        )] | map(select(length > 0)) | join("\n\n")),
        comments: ($findings | map(select(.inline) | {path, line, side, body}))
      }
  '
}

minimize_old_reviews() {
  local newest="$1" err="$2"
  local reviews id minimized

  if ! reviews=$("${GH:-gh}" api graphql --paginate -f owner="${REPO%/*}" -f repo="${REPO#*/}" -F pr="$PR" -f query='
    query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviews(first: 100, after: $endCursor) {
            nodes { id author { login __typename } body isMinimized }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
  ' | jq -sr --arg newest "$newest" '
    if length == 0 then error("empty GraphQL response") else .[] end
    | if (.errors // [] | length) > 0 then error(.errors | tostring) else . end
    | .data.repository.pullRequest.reviews.nodes[]
    | select(.id != $newest and (
        .author.login == "github-actions[bot]" or .author.login == "opencode-agent[bot]"
        or (.author.__typename == "Bot"
          and (.author.login == "github-actions" or .author.login == "opencode-agent"))
      ))
    # Reviews this script posts always carry a verdict line; other bot reviews are left alone.
    | select(.body // "" | split("\n") | any(test("^\\*\\*Verdict:")))
    | [.id, .isMinimized] | @tsv
  '); then
    echo 'WARNING: Could not list older bot reviews; skipping minimization.' >&2
    return 0
  fi

  while IFS=$'\t' read -r id minimized; do
    if [ -z "$id" ]; then
      continue
    fi

    if [ "$minimized" = true ]; then
      printf 'Review %s is already minimized.\n' "$id"
    elif {
      "${GH:-gh}" api graphql -f id="$id" -f query='
        mutation($id: ID!) {
          minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) {
            minimizedComment { isMinimized }
          }
        }
      ' | jq -es '
        if length != 1 then error("expected one GraphQL response")
        elif (.[0].errors // [] | length) > 0 then error(.[0].errors | tostring)
        else .[0].data.minimizeComment.minimizedComment.isMinimized == true
        end
      '
    } > /dev/null 2> "$err"; then
      printf 'Minimized review %s as outdated.\n' "$id"
    elif grep -qiE 'HTTP 404|already[- ]minimized|could not resolve to a node with the global id' "$err"; then
      printf 'Review %s is gone or already minimized.\n' "$id"
    else
      printf 'WARNING: Could not minimize review %s; stopping minimization.\n' "$id" >&2
      cat -- "$err" >&2
      return 0
    fi
  done <<< "$reviews"
}

# The fallback is a marker comment holding every finding: the review body (verdict and moved
# findings) plus one bullet per inline comment, with its severity from the parsed findings.
review_fallback() {
  local payload="$1" findings="$2"

  jq --arg marker "$review_marker" --slurpfile findings "$findings" '
    (.comments | map(. as $c
      | ($findings[0] | map(select(.path == $c.path and .line == $c.line
          and .side == $c.side and .body == $c.body)) | first | .severity) as $severity
      | "- \($c.path):\($c.line) (\($severity)): \($c.body)")) as $bullets
    | {body: ([$marker + "\n" + .body, (
        if $bullets == [] then ""
        else "Inline placement failed, so these findings are listed here instead.\n\n"
          + ($bullets | join("\n"))
        end
      )] | map(select(length > 0)) | join("\n\n"))}
  ' "$payload"
}

# Never fails silently: a rejected review falls back to one marker comment with every finding.
post_review() {
  local payload="$1" work="$2"
  local newest

  if ! "${GH:-gh}" api --method POST "repos/$REPO/pulls/$PR/reviews" --input "$payload" \
    > "$work/review.json"; then
    echo 'WARNING: Could not post the review; posting its findings as a plain comment instead.' >&2
    review_fallback "$payload" "$work/findings.json" > "$work/fallback.json"
    "${GH:-gh}" api --method POST "repos/$REPO/issues/$PR/comments" --input "$work/fallback.json" --silent
    return 0
  fi

  if ! newest=$(jq -er '.node_id | strings | select(length > 0)' "$work/review.json"); then
    echo 'WARNING: Posted the review but its node ID was missing; skipping minimization.' >&2
    return 0
  fi
  printf 'Posted review %s.\n' "$newest"
  minimize_old_reviews "$newest" "$work/minimize.err"
}

main() (
  : "${REPO:?REPO is required}" "${PR:?PR is required}" \
    "${GH_TOKEN:?GH_TOKEN is required}" "${DIFF:?DIFF is required}"

  out="${OUT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
  mkdir -p -- "$out"
  temp=$(mktemp -d "${out%/}/post-review.XXXXXX")
  trap 'rm -rf -- "$temp"' EXIT

  "${GH:-gh}" api "repos/$REPO/issues/$PR/comments" --paginate |
    jq -sr --arg marker "$review_marker" '
      map(.[] | select(
        (.user.login == "github-actions[bot]" or .user.login == "opencode-agent[bot]")
        and (.body // "" | startswith($marker))
      ))
      | max_by(.id) | .body // ""
    ' > "$temp/comment"

  if ! grep -q -- '^\*\*Verdict:' "$temp/comment"; then
    echo 'ERROR: The opencode review comment has no "Verdict:" line, so the review is invalid.' >&2
    exit 1
  fi

  prepare_review "$temp/comment" "$DIFF" "$temp" > "$temp/payload.json"
  if ! jq -e 'has("comments")' "$temp/payload.json" > /dev/null; then
    echo 'WARNING: Inline review comments skipped: findings JSON was missing or malformed.' >&2
    "${GH:-gh}" api --method POST "repos/$REPO/issues/$PR/comments" --input "$temp/payload.json" --silent
    exit 0
  fi

  post_review "$temp/payload.json" "$temp"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$#:${1:-}" in
    0:) main ;;
    1:--test) exec bash "$(dirname -- "${BASH_SOURCE[0]}")/test-review-post.sh" ;;
    *) echo 'Usage: post-review.sh [--test]' >&2; exit 2 ;;
  esac
fi
