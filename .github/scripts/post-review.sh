#!/usr/bin/env bash
set -euo pipefail

# Posts one opencode review from the event stream of 'opencode run --format json':
# - one issue comment that starts with the marker and holds the human-readable review;
# - one COMMENT pull request review that ends with the marker and carries the findings inline.
#
# Inputs (environment): REPO (owner/name), PR, GH_TOKEN, DIFF (the PR's unified diff), EVENTS
# (JSONL events), optional OUT (scratch directory) and GH (gh binary). A reply without a verdict
# or a valid findings block fails before anything is posted.

review_marker='<!-- opencode-review -->'

# Logs the stream before reply validation, which still owns reporting malformed input.
events_summary() {
  local events="$1"

  jq -sr '
    (group_by(.type // "unknown") | map({key: (.[0].type // "unknown"), value: length})
      | from_entries) as $types
    | (map(select(.type == "step_finish")) | last | .part) as $finish
    | {
        total: length,
        types: $types,
        text_events: ($types.text // 0),
        step_finish: {
          reason: ($finish.reason // "unknown"),
          tokens: {
            output: ($finish.tokens.output // "unknown"),
            reasoning: ($finish.tokens.reasoning // "unknown"),
            total: ($finish.tokens.total // "unknown")
          }
        }
      }
    | "Review events: \(tojson)"
  ' "$events" 2> /dev/null || printf 'Review events: unknown\n'
}

# Prints the last text part of the event stream. An error event means the run failed, so its
# reply, if any, is not a review.
reply_text() {
  local events="$1" errors

  if ! errors=$(jq -r '
    select(.type == "error") | .error
    | if type == "string" then . else (.data.message? // .message? // tojson) end
  ' "$events"); then
    printf 'ERROR: %s is not a JSONL event stream.\n' "$events" >&2
    return 1
  fi

  if [ -n "$errors" ]; then
    printf 'ERROR: opencode reported an error: %s\n' "$errors" >&2
    return 1
  fi

  jq -sj 'map(select(.type == "text") | .part.text | strings) | last // ""' "$events"
}

# Describes an event stream that held no text reply: how many events of each type it has, its
# line count, its error events and its last lines, so a failed run can be diagnosed from the log.
events_diagnostics() {
  local events="$1"

  echo 'Event types:'
  jq -sr 'group_by(.type) | map("\(length) \(.[0].type)") | .[]' "$events"
  printf 'Event lines: %s\n' "$(awk 'END { print NR }' "$events")"

  if jq -se 'any(.[]; .type == "error")' "$events" > /dev/null; then
    echo 'Error events:'
    jq -c 'select(.type == "error")' "$events"
  fi

  echo 'Last 5 event lines (400 characters each at most):'
  tail -n 5 -- "$events" | cut -c 1-400
}

verdict_line() {
  awk '
    /^<!-- opencode-findings-json[[:space:]]*$/ { exit }
    /^\*\*Verdict:/ { sub(/[[:space:]]+$/, ""); print; found = 1; exit }
    END { exit !found }
  ' < "$1"
}

# Prints the body of the first findings block; fails when there is none or it is never closed.
findings_block() {
  awk '
    !started && /^<!-- opencode-findings-json[[:space:]]*$/ { started = 1; next }
    started && /^-->[[:space:]]*$/ { closed = 1; exit }
    started { print }
    END { exit !closed }
  ' < "$1"
}

# Reads the findings block on stdin and prints the normalized array, or fails naming the problem.
validate_findings() {
  jq -cs '
    def side: if has("side") then .side else "RIGHT" end;
    def problem:
      if type != "object" then "is not an object"
      elif (.path | type) != "string" then "path must be a string"
      elif (.line | type != "number" or . < 1 or floor != .) then "line must be an integer >= 1"
      elif (side | . != "RIGHT" and . != "LEFT") then "side must be RIGHT or LEFT"
      elif (.severity | . != "MUST" and . != "SHOULD") then "severity must be MUST or SHOULD"
      elif (.body | type != "string" or length < 1 or length > 1500) then
        "body must be a string of 1 to 1500 characters"
      elif has("commit") and (.commit | type) != "string" then "commit must be a string"
      else empty
      end;

    if length != 1 then error("the block must hold exactly one JSON value") else .[0] end
    | if type != "array" then error("findings must be a JSON array")
      elif length > 30 then error("\(length) findings given; at most 30 are allowed")
      else . end
    | (to_entries | map(.key as $i | .value | problem | "finding \($i): \(.)") | first) as $bad
    | if $bad then error($bad) else map(.side = side | .line |= floor) end
  '
}

# The comment keeps the reply before the findings block, without a trailing run-link footer,
# under exactly one marker line and the verdict line.
marker_comment() {
  MARKER="$review_marker" VERDICT="$2" awk '
    function blank(s) { return s ~ /^[[:space:]]*$/ }

    /^<!-- opencode-findings-json[[:space:]]*$/ { exit }
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    line == ENVIRON["MARKER"] { next }
    !verdict_seen && line == ENVIRON["VERDICT"] { verdict_seen = 1; next }
    { lines[++n] = $0 }

    END {
      while (n > 0 && blank(lines[n])) n--
      if (n > 0 && lines[n] ~ /^\[[A-Za-z ]*run\]\(https?:\/\/[^)[:space:]]*\)[[:space:]]*$/) n--
      while (n > 0 && blank(lines[n])) n--
      start = 1
      while (start <= n && blank(lines[start])) start++

      print ENVIRON["MARKER"]
      print ENVIRON["VERDICT"]
      for (i = start; i <= n; i++) print lines[i]
    }
  ' < "$1"
}

# Prints "path<TAB>line" for every new-file line a RIGHT-side review comment can target: the
# context and added lines of each hunk. Git C-quotes unusual paths, so quoted paths are decoded.
right_lines() {
  LC_ALL=C awk '
    function unquote(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") {
          c = substr(s, ++i, 1)
          if (c ~ /^[0-3]$/) {
            c = sprintf("%c", c * 64 + substr(s, i + 1, 1) * 8 + substr(s, i + 2, 1))
            i += 2
          } else if (c == "t") {
            c = "\t"
          } else if (c == "n") {
            c = "\n"
          }
        }
        out = out c
      }
      return out
    }

    /^diff --git / { path = ""; in_hunk = 0; remaining = 0; next }
    !in_hunk && /^\+\+\+ b\// { path = substr($0, 7); sub(/\t$/, "", path); next }
    !in_hunk && /^\+\+\+ "b\/.*"\t?$/ {
      path = substr($0, 8)
      sub(/"\t?$/, "", path)
      path = unquote(path)
      next
    }
    !in_hunk && /^\+\+\+ \/dev\/null/ { path = ""; next }
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

# A finding is inline only on a RIGHT-side diff line; the rest become bullets in the review body.
review_payload() {
  local verdict="$1" findings="$2" lines="$3"

  jq -n --arg verdict "$verdict" --arg marker "$review_marker" \
    --slurpfile findings "$findings" --rawfile lines "$lines" '
    ($lines | split("\n") | map(select(length > 0) | {key: ., value: true}) | from_entries) as $valid
    | ($findings[0] | map(. + {inline: (.side == "RIGHT"
        and $valid[.path + "\t" + (.line | tostring)] == true)})) as $placed
    | ($placed | map(select(.inline))) as $inline
    | ($placed | map(select(.inline | not) | "- \(.path):\(.line) (\(.severity)): \(.body)"))
      as $bullets
    | {
        event: "COMMENT",
        body: ([
          $verdict,
          (if $placed == [] then "No findings to place on the diff."
            else "\($inline | length) of \($placed | length) findings are inline comments." end)
            + " The full review is in the opencode review comment on this pull request.",
          (if $bullets == [] then empty
            else "Findings that could not be posted inline:\n\n" + ($bullets | join("\n")) end),
          $marker
        ] | join("\n\n")),
        comments: ($inline | map({path, line, side, body}))
      }
  '
}

# Prints the new comment's numeric ID.
post_marker_comment() {
  local payload="$1" response="$2"

  if ! "${GH:-gh}" api --method POST "repos/$REPO/issues/$PR/comments" \
    --input "$payload" > "$response"; then
    echo 'ERROR: Could not post the review comment.' >&2
    return 1
  fi

  jq -er '.id | numbers' "$response"
}

# Keeps only the newest marker comment: every older bot comment that starts with the marker goes.
delete_older_comments() {
  local newest="$1" err="$2"
  local ids id

  if ! ids=$("${GH:-gh}" api "repos/$REPO/issues/$PR/comments" --paginate |
    jq -sr --argjson newest "$newest" --arg marker "$review_marker" '
      add // [] | .[]
      | select(.id < $newest)
      | select(.user.login == "github-actions[bot]" or .user.login == "opencode-agent[bot]")
      | select(.body // "" | startswith($marker))
      | .id
    '); then
    echo 'ERROR: Could not list older review comments.' >&2
    return 1
  fi

  for id in $ids; do
    if "${GH:-gh}" api --method DELETE "repos/$REPO/issues/comments/$id" --silent 2> "$err"; then
      printf 'Deleted older review comment %s.\n' "$id"
    elif grep -q 'HTTP 404' "$err"; then
      printf 'Review comment %s is already gone.\n' "$id"
    else
      printf 'ERROR: Could not delete review comment %s.\n' "$id" >&2
      cat -- "$err" >&2
      return 1
    fi
  done
}

# Prints the new review's node ID. The review is a COMMENT: it never approves or requests changes.
post_review() {
  local payload="$1" response="$2"

  if ! "${GH:-gh}" api --method POST "repos/$REPO/pulls/$PR/reviews" \
    --input "$payload" > "$response"; then
    echo 'ERROR: Could not post the pull request review.' >&2
    return 1
  fi

  jq -er '.node_id | strings | select(length > 0)' "$response"
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
  ' | jq -sr --arg newest "$newest" --arg marker "$review_marker" '
    if length == 0 then error("empty GraphQL response") else .[] end
    | if (.errors // [] | length) > 0 then error(.errors | tostring) else . end
    | .data.repository.pullRequest.reviews.nodes[]
    | select(.id != $newest and (
        .author.login == "github-actions[bot]" or .author.login == "opencode-agent[bot]"
        or (.author.__typename == "Bot"
          and (.author.login == "github-actions" or .author.login == "opencode-agent"))
      ))
    # Reviews this script posts end with the marker line; other bot reviews are left alone.
    | select(.body // "" | split("\n") | any(sub("\\s+$"; "") == $marker))
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

# Validates the whole reply before posting anything, so a bad reply fails with nothing on the PR.
prepare() {
  local events="$1" diff="$2" work="$3"
  local verdict

  events_summary "$events"
  reply_text "$events" > "$work/reply"

  if ! grep -q '[^[:space:]]' "$work/reply"; then
    events_diagnostics "$events" >&2 || true
    printf 'ERROR: %s has no text reply from opencode.\n' "$events" >&2
    return 1
  fi

  if ! verdict=$(verdict_line "$work/reply"); then
    echo 'ERROR: review reply has no Verdict line' >&2
    return 1
  fi

  if ! findings_block "$work/reply" > "$work/findings-block"; then
    echo 'ERROR: review reply has no closed <!-- opencode-findings-json ... --> block' >&2
    return 1
  fi

  if ! validate_findings < "$work/findings-block" > "$work/findings.json" 2> "$work/findings.err"; then
    printf 'ERROR: review findings JSON is invalid: %s\n' "$(cat -- "$work/findings.err")" >&2
    return 1
  fi

  marker_comment "$work/reply" "$verdict" | jq -Rs '{body: rtrimstr("\n")}' > "$work/comment.json"
  right_lines "$diff" > "$work/right-lines"
  review_payload "$verdict" "$work/findings.json" "$work/right-lines" > "$work/review.json"
}

main() (
  : "${REPO:?REPO is required}" "${PR:?PR is required}" "${GH_TOKEN:?GH_TOKEN is required}" \
    "${DIFF:?DIFF is required}" "${EVENTS:?EVENTS is required}"

  out="${OUT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
  mkdir -p -- "$out"
  temp=$(mktemp -d "${out%/}/post-review.XXXXXX")
  trap 'rm -rf -- "$temp"' EXIT

  prepare "$EVENTS" "$DIFF" "$temp"

  comment_id=$(post_marker_comment "$temp/comment.json" "$temp/comment-response.json")
  printf 'Posted review comment %s.\n' "$comment_id"
  delete_older_comments "$comment_id" "$temp/delete.err"

  review_id=$(post_review "$temp/review.json" "$temp/review-response.json")
  printf 'Posted review %s.\n' "$review_id"
  minimize_old_reviews "$review_id" "$temp/minimize.err"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$#:${1:-}" in
    0:) main ;;
    1:--test) exec bash "$(dirname -- "${BASH_SOURCE[0]}")/test-review-post.sh" ;;
    *) echo 'Usage: post-review.sh [--test]' >&2; exit 2 ;;
  esac
fi
