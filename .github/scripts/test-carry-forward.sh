#!/usr/bin/env bash
set -euo pipefail

# Offline fixture for the carry-forward lookup in opencode-review.yml. Two
# completed "review" check-runs share one head SHA: PR 999 passed, this PR (42)
# failed. Matching by pull_requests number must select 42's verdict, never
# reuse 999's success.

# Keep this jq literal identical to the one in the carry_forward step of
# .github/workflows/opencode-review.yml.
carry_forward_verdict() {
  jq -rs --argjson pr "$PR" '
    [ .[].check_runs[]
      | select(.name == "review")
      | select(.status == "completed")
      | select(.conclusion == "success" or .conclusion == "failure")
      | select(any(.pull_requests[]?; .number == $pr))
    ] as $matches
    | if ($matches | length) == 1 then $matches[0].conclusion
      else error("Expected exactly one review check-run for PR \($pr); got \($matches | length)")
      end
  '
}

PR=42
sha=0123456789abcdef0123456789abcdef01234567

# gh api --paginate emits one JSON document per page; jq -s slurps both pages.
other_pr=$(jq -nc --arg sha "$sha" '{
  total_count: 1,
  check_runs: [{
    name: "review", head_sha: $sha, status: "completed", conclusion: "success",
    pull_requests: [{number: 999}]
  }]
}')
this_pr=$(jq -nc --arg sha "$sha" '{
  total_count: 1,
  check_runs: [{
    name: "review", head_sha: $sha, status: "completed", conclusion: "failure",
    pull_requests: [{number: 42}]
  }]
}')

verdict=$(printf '%s\n%s\n' "$other_pr" "$this_pr" | carry_forward_verdict)
if [ "$verdict" != failure ]; then
  printf 'expected failure verdict, got %s\n' "$verdict" >&2
  exit 1
fi
printf 'ok: same-SHA other-PR success is not carried forward; this PR failure is selected\n'
