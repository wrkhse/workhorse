#!/usr/bin/env bash
set -euo pipefail

# Posts one opencode review from the event stream of 'opencode run --format json':
# - one issue comment that starts with the marker: the verdict, the reply's
#   summary and the MUST and SHOULD findings, rendered from the findings JSON alone
#   and capped below GitHub's comment limit;
# - one COMMENT pull request review that ends with the marker and carries the
#   findings on RIGHT-side diff lines inline.
#
# Inputs (environment): REPO (owner/name), PR, GH_TOKEN, DIFF (the PR's unified
# diff), EVENTS (JSONL events), optional OUT (scratch directory), GH (gh binary)
# and OPENCODE (opencode binary). A malformed reply can get one repair turn in the
# same session. The turn needs MODEL and inherits OPENCODE_CONFIG_CONTENT and
# OPENCODE_API_KEY.

review_marker='<!-- opencode-review -->'
# GitHub rejects comment bodies over 65536 characters.
marker_comment_limit=60000

# Logs the stream before reply validation, which still reports malformed input.
events_summary() {
  local events="$1" attempts="$2"

  jq -sr --argjson attempts "$attempts" '
    (group_by(.type // "unknown")
      | map({key: (.[0].type // "unknown"), value: length}) | from_entries) as $types
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
  ' "$events" 2> /dev/null ||
    printf 'Review events: {"attempts":%s,"summary":"unknown"}\n' "$attempts"
}

# Prints the last text part of the event stream. An error event means the run failed,
# so its reply, if any, is not a review.
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

# Describes an event stream that held no text reply: how many events of each type it
# has, its line count, its error events and its last lines.
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

# Prints the first verdict line, if present, without surrounding whitespace.
verdict_line() {
  awk '
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    line ~ /^\*\*Verdict:[^*]*\*\*$/ {
      print line
      exit
    }
  '
}

# Prints the prose after the verdict (or from the start if there is no verdict)
# up to the first bullet, findings block, backtick fence of any language, or line
# that is only a JSON array. Drops headings, HTML comments, trailing run links, and
# leading, trailing and repeated blank lines.
summary_text() {
  VERDICT="$1" awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function blank(s) { return s ~ /^[[:space:]]*$/ }

    BEGIN { after = ENVIRON["VERDICT"] == "" }
    !after { after = trim($0) == ENVIRON["VERDICT"]; next }
    /^[[:space:]]*<!-- opencode-findings-json/ { exit }
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ { exit }
    /^[[:space:]]*```/ { exit }
    /^[[:space:]]*\[[[:space:]]*(\]|\{.*\])[[:space:]]*$/ { exit }
    /^[[:space:]]*(#|<!--)/ { next }
    /^[[:space:]]*\*\*[^*]+\*\*:?[[:space:]]*$/ { next }
    blank($0) && (n == 0 || blank(lines[n])) { next }
    { lines[++n] = $0 }

    END {
      while (n > 0 && (blank(lines[n]) ||
          trim(lines[n]) ~ /^\[[^]]+ run\]\(https?:\/\/.+\)$/)) n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  '
}

# Prints the lines of the reply's last closed findings block: those between a line
# that is exactly the opener and the next line that is only -->. The reply ends
# with its block, so an example block quoted earlier, in a fence or the prose, is
# skipped. An opener inside an open block starts the block again. Fails when no
# block is closed.
findings_block() {
  awk '
    /^<!-- opencode-findings-json[[:space:]]*$/ { open = 1; n = 0; next }
    open && /^-->[[:space:]]*$/ {
      open = 0
      found = 1
      last = ""
      for (i = 1; i <= n; i++) last = last lines[i] "\n"
      next
    }
    open { lines[++n] = $0 }

    END {
      printf "%s", last
      exit !found
    }
  '
}

# Writes the findings of the reply's last closed findings block to
# $work/findings.json.
# The block is the only source of findings. Returns 1, naming the problem, when it
# is missing or its JSON is invalid.
extract_findings() {
  local work="$1"

  if ! findings_block < "$work/reply" > "$work/findings-block"; then
    printf 'ERROR: review reply has no closed %s block\n' \
      '<!-- opencode-findings-json ... -->' >&2
    return 1
  fi

  if ! validate_findings < "$work/findings-block" > "$work/findings.json" \
    2> "$work/findings.err"; then
    printf 'ERROR: review findings JSON is invalid: %s\n' \
      "$(cat -- "$work/findings.err")" >&2
    return 1
  fi

  if [ -s "$work/findings.err" ]; then
    cat -- "$work/findings.err" >&2
  fi
}

# Reads the findings block on stdin and prints the normalized array, or fails naming
# the problem.
validate_findings() {
  jq -cs '
    def side: if has("side") then .side else "RIGHT" end;
    # Commit is attribution only. Scalars become strings; other types are dropped
    # with a warning so a bad commit can never block the review.
    def normalize_commit:
      if (has("commit") | not) or (.commit | type) == "string" then .
      elif (.commit | type) == "number" or (.commit | type) == "boolean" then
        .commit |= tostring
      else
        ("dropping non-scalar finding commit" | debug) as $unused | del(.commit)
      end;
    def problem:
      if type != "object" then "is not an object"
      elif (has("path") | not) or (.path | type != "string" and . != null) then
        "path must be a string or null"
      elif (has("line") | not) or (.line |
          . != null and (type != "number" or . < 1 or floor != .)) then
        "line must be an integer >= 1 or null"
      elif (side | . != "RIGHT" and . != "LEFT") then "side must be RIGHT or LEFT"
      elif (.severity | . != "MUST" and . != "SHOULD") then
        "severity must be MUST or SHOULD"
      elif (.body | type != "string" or length < 1 or length > 1500) then
        "body must be a string of 1 to 1500 characters"
      else empty
      end;

    if length != 1 then error("the block must hold exactly one JSON value")
    else .[0] end
    | if type != "array" then error("findings must be a JSON array")
      elif length > 30 then error("\(length) findings given; at most 30 are allowed")
      else . end
    | (to_entries | map(.key as $i | .value | problem | "finding \($i): \(.)")
      | first) as $bad
    | if $bad then error($bad)
      else map(.side = side | if .line == null then . else .line |= floor end
        | normalize_commit)
      end
  '
}

# Prints the marker comment payload: the marker, the verdict, the summary, then a
# MUST and a SHOULD section rendered from the findings JSON, each omitted when empty.
# The body stays within marker_comment_limit characters. When the whole comment does
# not fit, the summary is cut so the marker and verdict remain, findings are added in
# order until the next one would not fit, and a last line counts the ones left out.
marker_comment() {
  local verdict="$1" summary="$2" findings="$3"

  jq -n --arg marker "$review_marker" --arg verdict "$verdict" \
    --argjson limit "$marker_comment_limit" \
    --rawfile summary "$summary" --slurpfile findings "$findings" '
    def bullet:
      " (commit \(.commit))" as $suffix
      | (if .path == null then .severity
        elif .line == null then .path
        else "\(.path):\(.line)" end) as $label
      | "- \($label): \(.body | gsub("\n"; "\n  "))"
        + (if (.commit // "") == "" or (.body | endswith($suffix)) then ""
          else $suffix end);

    # Room kept for the line that counts the findings left out.
    ($limit - 100) as $budget
    | "\n\n(Summary truncated.)" as $cut
    | ($summary | rtrimstr("\n")) as $text
    | ([$marker, $verdict] | join("\n")) as $top
    | ($top + (if $text == "" then "" else "\n" + $text end)) as $head
    | ($findings[0] | map(select(.severity == "MUST"))
        + map(select(.severity == "SHOULD"))) as $ordered
    | [$ordered | to_entries[] | .key as $i | .value
        | (if $i == 0 or $ordered[$i - 1].severity != .severity
          then "\n\n**\(.severity)**\n" else "\n" end) + bullet] as $pieces
    | ($head + ($pieces | add // "")) as $whole
    | if ($whole | length) <= $limit then {body: $whole}
      else
        (if ($head | length) <= $budget then $head
          else $top + "\n"
            + $text[:$budget - ($top | length) - 1 - ($cut | length)] + $cut
          end) as $start
        | reduce $pieces[] as $piece ({text: $start, n: 0, full: false};
            if .full or ((.text + $piece) | length) > $budget then .full = true
            else .text += $piece | .n += 1 end)
        | (($pieces | length) - .n) as $left
        | {body: (.text + (if $left == 0 then ""
            else "\n\n\($left) more findings are in the pull request review"
              + " (inline comments and body bullets)." end))}
      end
  '
}

# Prints "path<TAB>line" for every new-file line a RIGHT-side review comment can
# target: the context and added lines of each hunk. Git C-quotes unusual paths, so
# quoted paths are decoded.
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

# A finding is inline only with a path and line on the RIGHT side of the diff.
# The rest become bullets in the review body. Validation caps findings at 30
# and each body at 1500 characters.
review_payload() {
  local verdict="$1" findings="$2" lines="$3"

  jq -n --arg verdict "$verdict" --arg marker "$review_marker" \
    --slurpfile findings "$findings" --rawfile lines "$lines" '
    ($lines | split("\n") | map(select(length > 0) | {key: ., value: true})
      | from_entries) as $valid
    | ($findings[0] | map(. + {inline: (.path != null and .line != null
        and .side == "RIGHT"
        and $valid[.path + "\t" + (.line | tostring)] == true)})) as $placed
    | ($placed | map(select(.inline))) as $inline
    | ($placed | map(select(.inline | not)
        | if .path == null then "- \(.severity): \(.body)"
          elif .line == null then "- \(.path) (\(.severity)): \(.body)"
          else "- \(.path):\(.line) (\(.severity)): \(.body)" end)) as $bullets
    | {
        event: "COMMENT",
        body: ([
          $verdict,
          (if $placed == [] then "No findings to place on the diff."
            else "\($inline | length) of \($placed | length)"
              + " findings are inline comments. This review holds every"
              + " finding, inline or as a bullet below; the opencode review"
              + " comment may leave some out when it is too long." end),
          (if $bullets == [] then empty
            else "Findings that could not be posted inline:\n\n"
              + ($bullets | join("\n")) end),
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

# Prints the new review's node ID. The review is a COMMENT: it never approves or
# requests changes.
post_review() {
  local payload="$1" response="$2"

  if ! "${GH:-gh}" api --method POST "repos/$REPO/pulls/$PR/reviews" \
    --input "$payload" > "$response"; then
    echo 'ERROR: Could not post the pull request review.' >&2
    return 1
  fi

  jq -er '.node_id | strings | select(length > 0)' "$response"
}

# Keeps only the newest marker comment: every older bot comment that starts with the
# marker goes.
delete_older_comments() {
  local newest="$1" err="$2"
  local ids id

  if ! ids=$("${GH:-gh}" api "repos/$REPO/issues/$PR/comments" --paginate |
    jq -sr --argjson newest "$newest" --arg marker "$review_marker" '
      add // [] | .[]
      | select(.id < $newest)
      | select(.user.login == "github-actions[bot]"
          or .user.login == "opencode-agent[bot]")
      | select(.body // "" | startswith($marker))
      | .id
    '); then
    echo 'WARNING: Could not list older review comments; skipping deletion.' >&2
    return 0
  fi

  for id in $ids; do
    if "${GH:-gh}" api --method DELETE "repos/$REPO/issues/comments/$id" \
      --silent 2> "$err"; then
      printf 'Deleted older review comment %s.\n' "$id"
    elif grep -q 'HTTP 404' "$err"; then
      printf 'Review comment %s is already gone.\n' "$id"
    else
      printf 'WARNING: Could not delete review comment %s.\n' "$id" >&2
      cat -- "$err" >&2 || true
    fi
  done
}

reviews_query='
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
'

minimize_mutation='
  mutation($id: ID!) {
    minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) {
      minimizedComment { isMinimized }
    }
  }
'

# Prints "id<TAB>isMinimized" for every older bot review carrying the marker line.
older_reviews() {
  local newest="$1"

  "${GH:-gh}" api graphql --paginate -f owner="${REPO%/*}" -f repo="${REPO#*/}" \
    -F pr="$PR" -f query="$reviews_query" |
    jq -sr --arg newest "$newest" --arg marker "$review_marker" '
      if length == 0 then error("empty GraphQL response") else .[] end
      | if (.errors // [] | length) > 0 then error(.errors | tostring) else . end
      | .data.repository.pullRequest.reviews.nodes[]
      | select(.id != $newest and (
          .author.login == "github-actions[bot]"
          or .author.login == "opencode-agent[bot]"
          or (.author.__typename == "Bot" and (.author.login == "github-actions"
            or .author.login == "opencode-agent"))
        ))
      | select(.body // "" | split("\n") | any(sub("\\s+$"; "") == $marker))
      | [.id, .isMinimized] | @tsv
    '
}

minimize_review() {
  local id="$1"

  "${GH:-gh}" api graphql -f id="$id" -f query="$minimize_mutation" | jq -es '
    if length != 1 then error("expected one GraphQL response")
    elif (.[0].errors // [] | length) > 0 then error(.[0].errors | tostring)
    else .[0].data.minimizeComment.minimizedComment.isMinimized == true
    end
  '
}

minimize_old_reviews() {
  local newest="$1" err="$2"
  local reviews id minimized
  local gone='HTTP 404|already[- ]minimized'
  gone+='|could not resolve to a node with the global id'

  if ! reviews=$(older_reviews "$newest"); then
    echo 'WARNING: Could not list older bot reviews; skipping minimization.' >&2
    return 0
  fi

  while IFS=$'\t' read -r id minimized; do
    if [ -z "$id" ]; then
      continue
    fi

    if [ "$minimized" = true ]; then
      printf 'Review %s is already minimized.\n' "$id"
    elif minimize_review "$id" > /dev/null 2> "$err"; then
      printf 'Minimized review %s as outdated.\n' "$id"
    elif grep -qiE "$gone" "$err"; then
      printf 'Review %s is gone or already minimized.\n' "$id"
    else
      printf 'WARNING: Could not minimize review %s.\n' "$id" >&2
      cat -- "$err" >&2 || true
    fi
  done <<< "$reviews"
}

# Returns 1, naming the problem, for a reply a repair turn can fix: no text, a
# missing or invalid findings block, or no review marker. Returns 2 for other
# failures, such as an errored run.
validate_reply() {
  local events="$1" work="$2" verdict model_verdict

  reply_text "$events" > "$work/reply" || return 2

  if ! grep -q '[^[:space:]]' "$work/reply"; then
    events_diagnostics "$events" >&2 || true
    printf 'ERROR: %s has no text reply from opencode.\n' "$events" >&2
    return 1
  fi

  extract_findings "$work" || return $?

  if ! grep -qF -- "$review_marker" "$work/reply"; then
    printf 'ERROR: review reply has no %s marker\n' "$review_marker" >&2
    return 1
  fi

  verdict=$(jq -r '
    if any(.[]; .severity == "MUST") then "**Verdict: FIX FIRST**"
    else "**Verdict: MERGE AS IS**" end
  ' "$work/findings.json") || return 2

  model_verdict=$(verdict_line < "$work/reply") || return 2
  if [ -n "$model_verdict" ] && [ "$model_verdict" != "$verdict" ]; then
    printf 'WARNING: verdict %s disagrees with the findings JSON; using %s\n' \
      "$model_verdict" "$verdict" >&2
  fi

  printf '%s\n' "$verdict" > "$work/verdict" || return 2
  summary_text "$model_verdict" < "$work/reply" > "$work/summary" || return 2
}

# The repair turn spells out the whole reply shape, ending with the closed findings
# block, because a turn told only to include the block has left it out or unclosed.
repair_prompt=$(printf '%s\n' \
  "Reply now with only the review, in this exact shape and nothing else. \
Do not describe what you read or did." \
  "Line 1, exactly: $review_marker" \
  "Line 2, exactly: **Verdict: X**, where X is MERGE AS IS when there is no \
MUST and FIX FIRST otherwise." \
  'Then a short summary.' \
  "Then one-line bullets with file:line under **MUST** or **SHOULD**. \
Omit an empty section." \
  "End the reply with these three lines, without a code fence and with \
nothing after them:" \
  '<!-- opencode-findings-json' \
  '[{"path":"...","line":12,"side":"RIGHT","severity":"MUST","body":"..."}]' \
  '-->' \
  "The middle line is a JSON array of EVERY finding, at most 30 of them: those \
on the diff, those outside it and those from NOTES.txt." \
  "Use \"line\":null where no line applies, and \"path\":null as well where no \
file applies. Use [] if there are no findings." \
  'The --> line on its own closes the block and is required.')

repair_reply() {
  local events="$1" repair_events="$2" sessionID status=0
  local OPENCODE="${OPENCODE:-opencode}"

  sessionID=$(jq -sr 'map(.sessionID | strings | select(length > 0)) | first // ""' \
    "$events") || return 1
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
    "$OPENCODE" run --model "$MODEL" --variant low --format json \
      --session "$sessionID" "$repair_prompt" > "$repair_events"
  ) || status=$?
  events_summary "$repair_events" 2

  if [ "$status" -ne 0 ]; then
    printf 'ERROR: opencode repair exited with status %s.\n' "$status" >&2
    return 1
  fi
}

# Validates before posting. A first reply that validation can repair (no findings
# block, invalid findings JSON or no marker) gets one repair turn; a repaired reply
# that is still invalid fails with the reason validation names.
prepare() {
  local events="$1" diff="$2" work="$3" repair_events="$4"
  local status=0 verdict

  events_summary "$events" 1
  validate_reply "$events" "$work" || status=$?
  case "$status" in
    0) ;;
    1)
      repair_reply "$events" "$repair_events" || return 1
      if ! validate_reply "$repair_events" "$work"; then
        echo 'ERROR: the repaired review reply is still invalid; not posting.' >&2
        return 1
      fi
      ;;
    *) return 1 ;;
  esac

  IFS= read -r verdict < "$work/verdict"
  marker_comment "$verdict" "$work/summary" "$work/findings.json" \
    > "$work/comment.json"
  right_lines "$diff" > "$work/right-lines"
  review_payload "$verdict" "$work/findings.json" "$work/right-lines" \
    > "$work/review.json"
}

main() (
  : "${REPO:?REPO is required}" "${PR:?PR is required}" \
    "${GH_TOKEN:?GH_TOKEN is required}" "${DIFF:?DIFF is required}" \
    "${EVENTS:?EVENTS is required}"

  out="${OUT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
  mkdir -p -- "$out"
  temp=$(mktemp -d "${out%/}/post-review.XXXXXX")
  trap 'rm -rf -- "$temp"' EXIT

  prepare "$EVENTS" "$DIFF" "$temp" "${out%/}/review-repair.jsonl"

  comment_id=$(post_marker_comment "$temp/comment.json" \
    "$temp/comment-response.json")
  printf 'Posted review comment %s.\n' "$comment_id"

  review_id=$(post_review "$temp/review.json" "$temp/review-response.json")
  printf 'Posted review %s.\n' "$review_id"

  # Cleanup is best effort: a failure here warns and never fails the job.
  delete_older_comments "$comment_id" "$temp/delete.err" ||
    echo 'WARNING: Cleanup of older review comments failed.' >&2
  minimize_old_reviews "$review_id" "$temp/minimize.err" ||
    echo 'WARNING: Minimizing older reviews failed.' >&2
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$#:${1:-}" in
    0:) main ;;
    1:--test) exec bash "$(dirname -- "${BASH_SOURCE[0]}")/test-review-post.sh" ;;
    *) echo 'Usage: post-review.sh [--test]' >&2; exit 2 ;;
  esac
fi
