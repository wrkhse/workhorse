#!/usr/bin/env bash
set -euo pipefail

# Offline fixture for the carry-forward lookup in opencode-review.yml. Every
# completed "review" check-run shares one head SHA: this PR (42) failed, and a
# newer success comes from PR 999. An older same-app success for 42 is a repeat
# run; another newer success comes from a different app. The lookup must select
# 42's newest GitHub Actions verdict (failure), never the other PR's or the
# other app's success. Dropping the PR-number filter selects the newer PR 999
# success and fails this test.

# Keep this jq literal identical to the one in the carry_forward step of
# .github/workflows/opencode-review.yml.
carry_forward_verdict() {
  jq -rs --argjson pr "$PR" '
    [ .[].check_runs[]
      | select(.name == "review")
      | select(.status == "completed")
      | select(.conclusion == "success" or .conclusion == "failure")
      | select(.app.id == 15368)
      | select(any(.pull_requests[]?; .number == $pr))
    ] as $matches
    | if ($matches | length) == 0 then error("No review check-run for PR \($pr)")
      else ($matches | sort_by(.completed_at) | reverse | .[0].conclusion)
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
    app: {id: 15368}, completed_at: "2026-11-27T05:00:00Z",
    pull_requests: [{number: 999}]
  }]
}')
this_pr=$(jq -nc --arg sha "$sha" '{
  total_count: 3,
  check_runs: [
    {
      name: "review", head_sha: $sha, status: "completed", conclusion: "failure",
      app: {id: 15368}, completed_at: "2026-11-27T03:00:00Z",
      pull_requests: [{number: 42}]
    },
    {
      name: "review", head_sha: $sha, status: "completed", conclusion: "success",
      app: {id: 15368}, completed_at: "2026-11-27T01:00:00Z",
      pull_requests: [{number: 42}]
    },
    {
      name: "review", head_sha: $sha, status: "completed", conclusion: "success",
      app: {id: 424242}, completed_at: "2026-11-27T04:00:00Z",
      pull_requests: [{number: 42}]
    }
  ]
}')

verdict=$(printf '%s\n%s\n' "$other_pr" "$this_pr" | carry_forward_verdict)
if [ "$verdict" != failure ]; then
  printf 'expected failure verdict, got %s\n' "$verdict" >&2
  exit 1
fi
printf 'ok: newest GitHub Actions verdict for PR 42 selected; others ignored\n'
