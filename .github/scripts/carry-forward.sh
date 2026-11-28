#!/usr/bin/env bash
set -euo pipefail

# Carry a verdict forward only for a title-only edit whose newest marker
# comment came from github-actions[bot] on this exact head, base and PR body
# with MERGE AS IS. A miss reviews fresh; lookup failures are reported and
# never fail the job.
: "${REPO:?REPO is required}" \
  "${PR:?PR is required}" \
  "${HEAD_SHA:?HEAD_SHA is required}" \
  "${BASE_SHA:?BASE_SHA is required}" \
  "${PR_JSON:?PR_JSON is required}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
marker='<!-- opencode-review -->'
author_id=41898282
prefix='<!-- opencode-review-meta '
suffix=' -->'
carried=false
err=$(mktemp "${TMPDIR:-/tmp}/carry-forward-err.XXXXXX")
trap 'rm -f -- "$err"' EXIT

lookup_failed() {
  local message
  message=$(tr '\n' ' ' < "$err" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || message='unknown error'
  printf '::error::Carry-forward lookup failed: %s\n' "${message:-unknown error}" >&2
}

# Writer and reader must hash the body the same way; a failure reviews fresh.
body_hash=''
if ! body_hash=$(PR_JSON="$PR_JSON" bash "$script_dir/pr-body-hash.sh" 2> "$err"); then
  lookup_failed
fi

comments=''
if ! comments=$(gh api --paginate --jq '.[] | {id, user: {id: .user.id}, body}' \
    "repos/$REPO/issues/$PR/comments" 2> "$err"); then
  lookup_failed
  comments=''
fi

if [ -n "$comments" ] && [ -n "$body_hash" ]; then
  body=''
  if ! body=$(printf '%s\n' "$comments" | jq -rs \
      --arg marker "$marker" --argjson author "$author_id" '
        if any(.[]; (.id | type) != "number"
               or (.user.id? | type) != "number"
               or ((.body? // "") | type) != "string") then
          error("unexpected comment shape")
        else . end
        | [ .[]
            | select(.user.id == $author)
            | select(.body | startswith($marker)) ]
        | if length == 0 then "" else (sort_by(.id) | last | .body) end
      ' 2> "$err"); then
    lookup_failed
    body=''
  fi

  if [ -n "$body" ]; then
    # Meta is fixed at line 4: marker, verdict, reviewer-or-blank, meta.
    meta=$(printf '%s\n' "$body" | sed -n '4p')
    case "$meta" in
      "$prefix"*"$suffix")
        json=${meta#"$prefix"}
        json=${json%"$suffix"}
        verdict_ok=''
        if ! verdict_ok=$(printf '%s' "$json" | jq -r \
            --arg head "$HEAD_SHA" --arg base "$BASE_SHA" \
            --arg body "$body_hash" '
              if (.head == $head and .base == $base and .body == $body
                  and .verdict == "MERGE AS IS") then "true" else "false" end
            ' 2> "$err"); then
          lookup_failed
          verdict_ok=''
        fi
        if [ "$verdict_ok" = true ]; then
          carried=true
        fi
        ;;
    esac
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'carried=%s\n' "$carried" >> "$GITHUB_OUTPUT"
fi
printf 'Carry-forward: carried=%s\n' "$carried"
