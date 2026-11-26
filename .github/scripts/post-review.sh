#!/usr/bin/env bash
set -euo pipefail

# Posts one opencode review from the event stream of 'opencode run --format json':
# - one issue comment that starts with the marker and holds the human-readable review;
# - one COMMENT pull request review that ends with the marker and carries the findings inline.
#
# Inputs (environment): REPO (owner/name), PR, GH_TOKEN, DIFF (the PR's unified diff), EVENTS
# (JSONL events), optional OUT (scratch directory), GH (gh binary) and OPENCODE (opencode binary).
# A malformed reply can get one repair turn in the same session. The turn needs MODEL and inherits
# OPENCODE_CONFIG_CONTENT and OPENCODE_API_KEY from the workflow.

review_marker='<!-- opencode-review -->'

# Logs the stream before reply validation, which still owns reporting malformed input.
events_summary() {
  local events="$1" attempts="$2"

  jq -sr --argjson attempts "$attempts" '
    (group_by(.type // "unknown") | map({key: (.[0].type // "unknown"), value: length})
      | from_entries) as $types
    | (map(select(.type == "step_finish")) | last | .part) as $finish
    | {
        attempts: $attempts,
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
  ' "$events" 2> /dev/null || printf 'Review events: {"attempts":%s,"summary":"unknown"}\n' "$attempts"
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

# Keeps the marker comment, which may come before or after the findings JSON block.
reply_comment_text() {
  awk '
    !comment && !in_findings && /^[[:space:]]*$/ { next }
    !in_findings && /^<!-- opencode-findings-json[[:space:]]*$/ {
      if (comment || after_findings) exit
      in_findings = 1
      next
    }
    in_findings && /^-->[[:space:]]*$/ { in_findings = 0; after_findings = 1; next }
    in_findings { next }
    { comment = 1; print }
  ' < "$1"
}

verdict_line() {
  awk '
    NR == 2 && /^\*\*Verdict:/ { sub(/[[:space:]]+$/, ""); print; found = 1 }
    NR == 2 { exit }
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

# Keeps the human-readable portion, without a trailing run-link footer, under exactly one marker
# line and the verdict line.
marker_comment() {
  MARKER="$review_marker" VERDICT="$2" awk '
    function blank(s) { return s ~ /^[[:space:]]*$/ }

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

# Renders, as bullets, the findings of one severity that the human-readable reply
# does not already hold as its own bullet: a line '- path:line: body' or the older
# '- path:line body', with any further body lines on the lines after it, as
# written or indented the way a bullet continues it. Comparison is literal, so a
# body quoted elsewhere or the same body at another path or line does not count.
# Prints nothing when the reply holds them all.
missing_bullets() {
  local reply="$1" findings="$2" severity="$3"

  jq -r --rawfile reply "$reply" --arg severity "$severity" '
    def trimmed: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
    # The suffix a rendered bullet carries after its last body line, " (commit <commit>)",
    # or null when the finding names no commit and its body must match with nothing after it.
    def commit_suffix:
      if (.commit | type) == "string" then " (commit \(.commit))" else null end;
    def bullet_text: "- \(.path):\(.line): \(.body | gsub("\n"; "\n  "))";
    # The commit suffix the bullet appends after its body, or null when the finding
    # names no commit or its body already ends with the suffix.
    def appended_suffix: commit_suffix as $suffix
      | if $suffix == null or (bullet_text | endswith($suffix)) then null else $suffix end;
    # The rendered bullet, with the commit suffix unless the body already ends with it.
    def bullet: bullet_text + (appended_suffix // "");
    # A body line matches exactly. When the bullet appends a commit suffix, the last
    # line matches only when followed by exactly that suffix, so a reply bullet
    # without it does not count as the finding written.
    def line_matches($want; $last; $suffix): trimmed as $have
      | if $last and $suffix != null then $have == $want + $suffix else $have == $want end;
    def written:
      ("- \(.path):\(.line)") as $head
      | appended_suffix as $suffix
      | (.body | split("\n") | map(trimmed)) as $body
      | ($body | length) as $count
      | ($reply | split("\n")) as $lines
      | any(range(0; ($lines | length) - $count + 1); . as $i
          | ($lines[$i] | line_matches($head + ": " + $body[0]; $count == 1; $suffix)
              or line_matches($head + " " + $body[0]; $count == 1; $suffix))
            and all(range(1; $count); . as $j
              | $lines[$i + $j] | line_matches($body[$j]; $j == $count - 1; $suffix)));

    map(select(.severity == $severity) | select(written | not) | bullet) | join("\n")
  ' < "$findings"
}

# Adds every finding the reply left out to the rendered marker comment, so none is
# lost: under the reply's own MUST or SHOULD header when it has one, otherwise under
# a new header at the end. The explanation line appears only when a new header is
# appended, directly before it.
add_missing_findings() {
  local reply="$1" findings="$2" rendered="$3"
  local must should

  must=$(missing_bullets "$reply" "$findings" MUST) || return 1
  should=$(missing_bullets "$reply" "$findings" SHOULD) || return 1

  MUST_BULLETS="$must" SHOULD_BULLETS="$should" awk '
    function blank(s) { return s ~ /^[[:space:]]*$/ }
    # A bold line or a Markdown heading ends the section before it.
    function header(s) { return s ~ /^\*\*[^*]+\*\*/ || s ~ /^#/ }

    { lines[++n] = $0 }

    END {
      order[1] = "MUST"; order[2] = "SHOULD"
      bullets["MUST"] = ENVIRON["MUST_BULLETS"]
      bullets["SHOULD"] = ENVIRON["SHOULD_BULLETS"]

      # A section runs from its first header to its last non-blank line before the
      # next header.
      for (i = 1; i <= n; i++) {
        if (header(lines[i])) {
          section = ""
          if (match(lines[i], /^\*\*(MUST|SHOULD)\*\*/)) {
            severity = substr(lines[i], 3, RLENGTH - 4)
            if (!(severity in end_of)) section = severity
          }
        }
        if (section != "" && !blank(lines[i])) end_of[section] = i
      }

      for (i = 1; i <= n; i++) {
        print lines[i]
        for (k = 1; k <= 2; k++) {
          severity = order[k]
          if ((severity in end_of) && end_of[severity] == i &&
            bullets[severity] != "") {
            print bullets[severity]
          }
        }
      }

      # The note introduces the new sections below it, so in-section merges alone
      # leave it out.
      for (k = 1; k <= 2; k++) {
        severity = order[k]
        if (!(severity in end_of) && bullets[severity] != "") appended = 1
      }
      if (!appended) exit

      print ""
      note = "The reply left out these findings, so they were rendered"
      print note " from its structured findings."
      for (k = 1; k <= 2; k++) {
        severity = order[k]
        if (!(severity in end_of) && bullets[severity] != "") {
          print ""
          print "**" severity "**"
          print bullets[severity]
        }
      }
    }
  ' < "$rendered"
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
    echo 'WARNING: Could not list older review comments; skipping deletion.' >&2
    return 0
  fi

  for id in $ids; do
    if "${GH:-gh}" api --method DELETE "repos/$REPO/issues/comments/$id" --silent 2> "$err"; then
      printf 'Deleted older review comment %s.\n' "$id"
    elif grep -q 'HTTP 404' "$err"; then
      printf 'Review comment %s is already gone.\n' "$id"
    else
      printf 'WARNING: Could not delete review comment %s.\n' "$id" >&2
      cat -- "$err" >&2 || true
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
      printf 'WARNING: Could not minimize review %s.\n' "$id" >&2
      cat -- "$err" >&2 || true
    fi
  done <<< "$reviews"
}

# Returns 1 for repairable reply content, 2 when the event stream itself failed.
validate_reply() {
  local events="$1" work="$2" marker

  reply_text "$events" > "$work/reply" || return 2

  if ! grep -q '[^[:space:]]' "$work/reply"; then
    events_diagnostics "$events" >&2 || true
    printf 'ERROR: %s has no text reply from opencode.\n' "$events" >&2
    return 1
  fi

  reply_comment_text "$work/reply" > "$work/comment" || return 2

  if ! verdict_line "$work/comment" > "$work/verdict"; then
    echo 'ERROR: review reply has no Verdict line' >&2
    return 1
  fi
  if ! IFS= read -r marker < "$work/comment" || [ "$marker" != "$review_marker" ]; then
    echo 'ERROR: review reply has no marker comment before the Verdict line' >&2
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
}

repair_reply() {
  local events="$1" repair_events="$2" sessionID status=0
  local OPENCODE="${OPENCODE:-opencode}"

  sessionID=$(jq -sr 'map(.sessionID | strings | select(length > 0)) | first // ""' "$events") || return 1
  if [ -z "$sessionID" ]; then
    echo 'ERROR: Cannot repair review reply without an opencode sessionID.' >&2
    return 1
  fi
  if [ -z "${MODEL:-}" ]; then
    echo 'ERROR: MODEL is required to repair the review reply.' >&2
    return 1
  fi

  (
    # Keep the write credential in the posting process, not the resumed reviewer.
    unset GH_TOKEN
    "$OPENCODE" run --model "$MODEL" --variant low --format json --session "$sessionID" \
      'Reply now with only the required output: the marker comment with the verdict line, a short summary, MUST/SHOULD findings bullets, and the findings JSON block. Do not describe what you read or did.' > "$repair_events"
  ) || status=$?
  events_summary "$repair_events" 2

  if [ "$status" -ne 0 ]; then
    printf 'ERROR: opencode repair exited with status %s.\n' "$status" >&2
    return 1
  fi
}

# Validates before posting; only an invalid reply from the first turn can trigger a repair.
prepare() {
  local events="$1" diff="$2" work="$3" repair_events="$4"
  local status=0 verdict

  events_summary "$events" 1
  validate_reply "$events" "$work" || status=$?
  case "$status" in
    0) ;;
    1)
      repair_reply "$events" "$repair_events" || return 1
      validate_reply "$repair_events" "$work" || return 1
      ;;
    *) return 1 ;;
  esac

  IFS= read -r verdict < "$work/verdict"
  marker_comment "$work/comment" "$verdict" > "$work/comment.rendered"
  add_missing_findings "$work/comment" "$work/findings.json" \
    "$work/comment.rendered" > "$work/comment.md" || return 1
  jq -Rs '{body: rtrimstr("\n")}' < "$work/comment.md" > "$work/comment.json"
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

  prepare "$EVENTS" "$DIFF" "$temp" "${out%/}/review-repair.jsonl"

  comment_id=$(post_marker_comment "$temp/comment.json" "$temp/comment-response.json")
  printf 'Posted review comment %s.\n' "$comment_id"

  review_id=$(post_review "$temp/review.json" "$temp/review-response.json")
  printf 'Posted review %s.\n' "$review_id"

  delete_older_comments "$comment_id" "$temp/delete.err"
  minimize_old_reviews "$review_id" "$temp/minimize.err"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$#:${1:-}" in
    0:) main ;;
    1:--test) exec bash "$(dirname -- "${BASH_SOURCE[0]}")/test-review-post.sh" ;;
    *) echo 'Usage: post-review.sh [--test]' >&2; exit 2 ;;
  esac
fi
