#!/usr/bin/env bash
set -euo pipefail

gather="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/gather-review-input.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cd -- "$tmp"
git init -q -b main
git config --local user.email fixture@example.com
git config --local user.name Fixture
printf 'base\n' > history.txt
git add history.txt
git commit -qm 'Base'
base=$(git rev-parse HEAD)

for ((n = 1; n <= 101; n++)); do
  printf 'commit %s\n' "$n" >> history.txt
  git add history.txt

  if [ "$n" -eq 1 ]; then
    printf '%2048s\n' x > large.txt
    git add large.txt
  fi

  git commit -qm "Fixture commit $n"
done

head=$(git rev-parse HEAD)
first_commit=$(git rev-list --reverse "$base..$head" | sed -n '1p')

cat > "$tmp/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1-}" = api && "${2-}" = --paginate && "${3-}" = "repos/o/r/pulls/1/files" ]]; then
  cat -- "$API_FILES_FIXTURE"
  exit 0
fi

if [[ "$#" -lt 3 || "$1" != issue || "$2" != view ]]; then
  echo 'unexpected gh command' >&2
  exit 1
fi

if [ "$3" = 7 ]; then
  printf '%s\n' '{"title":"Real issue","body":"Fixture issue body"}'
else
  echo 'could not resolve to an issue' >&2
  exit 1
fi
SH
chmod +x "$tmp/gh"

run_case() {
  local name="$1" body="$2"
  local out="$tmp/$name" notes="$tmp/$name/NOTES.txt"
  local commit_patch="$tmp/$name/commits/001-$first_commit.patch"

  jq -n --arg body "$body" '{title:"Fixture",body:$body}' > "$tmp/pr.json"
  BASE="$base" HEAD="$head" PR_JSON="$tmp/pr.json" REPO=o/r GH="$tmp/gh" \
    OUT="$out" MAX_BYTES=1000 MAX_COMMITS=100 "$gather"

  case "$name" in
    full|url-link)
      [ -f "$out/issue.json" ]
      grep -Fq 'Real issue' "$out/issue.json"
      ;;
    missing|no-link)
      [ ! -e "$out/issue.json" ]
      ;;
  esac

  if [ "$name" = full ]; then
    [ "$(wc -c < "$out/diff.patch")" -eq 1000 ]
    [ "$(wc -c < "$commit_patch")" -eq 1000 ]
    [ "$(find "$out/commits" -type f | wc -l)" -eq 100 ]
    grep -Fxq "$out/diff.patch exceeded 1000 bytes and was cut." "$notes"
    grep -Fxq "$commit_patch exceeded 1000 bytes and was cut." "$notes"
    grep -Fxq 'Only the first 100 of 101 commits are in commits/.' "$notes"
  fi

  if grep -Fq '#' "$notes"; then
    printf '%s: issue references do not belong in NOTES.txt\n' "$name" >&2
    return 1
  fi

  printf 'ok: %s\n' "$name"
}

run_case full 'Example: `Fixes #42`.
```text
Closes #42
```
Mentions #999999 and https://github.com/other/other/issues/42. Part of #7.'
run_case missing 'Closes #999999'
run_case no-link 'See #1234 and https://other/repo/issues/9'
run_case url-link 'Related: /o/r/issues/7'

# Keep these commits outside the capped history used by the four cases above.
printf '%s\n' '#[allow(dead_code)]' 'pub fn fixture() {}' > fixture.rs
git add fixture.rs
git commit -qm 'Add lint suppression'
suppression_commit=$(git rev-parse HEAD)

printf '%s\n' 'pub fn fixture() {}' > fixture.rs
git add fixture.rs
git commit -qm 'Remove lint suppression'
clean_head=$(git rev-parse HEAD)

out="$tmp/fixed-later"
jq -n '{title:"Fixture",body:""}' > "$tmp/pr.json"
BASE="$head" HEAD="$clean_head" PR_JSON="$tmp/pr.json" REPO=o/r GH="$tmp/gh" \
  OUT="$out" MAX_BYTES=1000 MAX_COMMITS=100 "$gather"

grep -Fxq -- '+#[allow(dead_code)]' "$out/commits/001-$suppression_commit.patch"
grep -Fxq -- '-#[allow(dead_code)]' "$out/commits/002-$clean_head.patch"
[ "$(git show "$clean_head:fixture.rs")" = 'pub fn fixture() {}' ]

digest="$out/commits-digest.txt"
[ -f "$digest" ]
[ "$(cat -- "$digest")" = "commit $suppression_commit Add lint suppression
file fixture.rs
+ fixture.rs:1: #[allow(dead_code)]
commit $clean_head Remove lint suppression
file fixture.rs
- fixture.rs:1: #[allow(dead_code)]" ]

printf 'ok: fixed-later\n'

# Gather-level fixtures for the docs-only classifier. The pr.json stub plays
# the workflow's `gh pr view --json title,body,files` step and the changed-files
# file plays its `gh api ... --jq .changed_files` step; the gh stub's api branch
# answers `gh api --paginate repos/o/r/pulls/1/files` with the complete file
# list read from $API_FILES_FIXTURE.
cat > "$tmp/gh-pr-files" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 || "$1" != pr || "$2" != view ]]; then
  echo 'unexpected gh command' >&2
  exit 1
fi

cat -- "$PR_FIXTURE"
SH
chmod +x "$tmp/gh-pr-files"

run_docs_case() {
  local name="$1" fixture="$2" api_fixture="$3" changed="$4" expected="$5"
  local out="$tmp/docs-$name"

  printf '%s\n' "$changed" > "$tmp/changed-files.txt"
  PR_FIXTURE="$fixture" "$tmp/gh-pr-files" pr view 1 -R o/r \
    --json title,body,files > "$tmp/pr.json"
  BASE="$base" HEAD="$head" PR_JSON="$tmp/pr.json" REPO=o/r PR=1 \
    CHANGED_FILES="$tmp/changed-files.txt" \
    API_FILES_FIXTURE="$api_fixture" GH="$tmp/gh" \
    OUT="$out" MAX_BYTES=1000 MAX_COMMITS=100 "$gather"

  [ "$(cat -- "$out/docs-only.txt")" = "$expected" ]
  printf 'ok: docs-only %s\n' "$name"
}

cat > "$tmp/docs.json" <<'JSON'
{"title":"Docs","body":"","files":[{"path":"README.md"},{"path":"site/img/logo.png"}]}
JSON
# From wrkhse/workhorse#49 (docs-only).
cat > "$tmp/docs-files.json" <<'JSON'
[{"filename":"ARCHITECTURE.md","previous_filename":null,"status":"modified"}]
JSON
run_docs_case docs "$tmp/docs.json" "$tmp/docs-files.json" 1 true

# Shaped from the real REST response shape: AGENTS.md is governance, so it
# must not be classified as docs-only.
cat > "$tmp/governance.json" <<'JSON'
{"title":"Governance","body":"","files":[{"path":"AGENTS.md"}]}
JSON
cat > "$tmp/governance-files.json" <<'JSON'
[{"filename":"AGENTS.md","previous_filename":null,"status":"modified"}]
JSON
run_docs_case governance "$tmp/governance.json" "$tmp/governance-files.json" 1 false

cat > "$tmp/mdx.json" <<'JSON'
{"title":"Docs","body":"","files":[{"path":"site/x.mdx"}]}
JSON
cat > "$tmp/mdx-files.json" <<'JSON'
[{"filename":"site/x.mdx","previous_filename":null,"status":"modified"}]
JSON
run_docs_case mdx "$tmp/mdx.json" "$tmp/mdx-files.json" 1 false

cat > "$tmp/mixed.json" <<'JSON'
{"title":"Mixed","body":"","files":[{"path":"README.md"},{"path":"src/main.rs"}]}
JSON
# From wrkhse/workhorse#75 (mixed docs and code).
cat > "$tmp/mixed-files.json" <<'JSON'
[{"filename":"PHILOSOPHY.md","previous_filename":null,"status":"modified"},{"filename":"hub.config.ts","previous_filename":null,"status":"modified"},{"filename":"site/scripts/roadmap.test.ts","previous_filename":null,"status":"modified"},{"filename":"site/src/how-it-fits.md","previous_filename":null,"status":"modified"}]
JSON
run_docs_case mixed "$tmp/mixed.json" "$tmp/mixed-files.json" 4 false

# Real REST response from wrkhse/tack#48 (a docs-to-docs rename).
cat > "$tmp/rename-real.json" <<'JSON'
{"title":"Rename","body":"","files":[{"path":"crates/luau/src/sandbox/README.md"}]}
JSON
cat > "$tmp/rename-real-files.json" <<'JSON'
[{"filename":"crates/luau/src/sandbox/README.md","previous_filename":"crates/runtime/src/sandbox/README.md","status":"renamed"}]
JSON
run_docs_case rename-real "$tmp/rename-real.json" "$tmp/rename-real-files.json" 1 true

# Derived from the tack#48 REST shape with a code old path (src/x.rs ->
# README.md). No real code-to-docs rename exists in the family; this case
# exercises the old-path guard and must not be docs-only.
cat > "$tmp/rename-code-old.json" <<'JSON'
{"title":"Rename","body":"","files":[{"path":"README.md"}]}
JSON
cat > "$tmp/rename-code-old-files.json" <<'JSON'
[{"filename":"README.md","previous_filename":"src/x.rs","status":"renamed"}]
JSON
run_docs_case rename-code-old "$tmp/rename-code-old.json" "$tmp/rename-code-old-files.json" 1 false

# An API list shorter than CHANGED_FILES cannot be trusted.
cat > "$tmp/truncated.json" <<'JSON'
{"title":"Truncated","body":"","files":[{"path":"README.md"}]}
JSON
cat > "$tmp/truncated-files.json" <<'JSON'
[{"filename":"README.md","previous_filename":null,"status":"modified"}]
JSON
run_docs_case truncated "$tmp/truncated.json" "$tmp/truncated-files.json" 2 false

# An unreadable CHANGED_FILES must fail closed, never claim docs-only.
cat > "$tmp/unreadable.json" <<'JSON'
{"title":"Unreadable","body":"","files":[{"path":"README.md"}]}
JSON
cat > "$tmp/unreadable-files.json" <<'JSON'
[{"filename":"README.md","previous_filename":null,"status":"modified"}]
JSON
out="$tmp/docs-unreadable"
PR_FIXTURE="$tmp/unreadable.json" "$tmp/gh-pr-files" pr view 1 -R o/r \
  --json title,body,files > "$tmp/pr.json"
missing_changed="$tmp/no-such-changed-files.txt"
[ ! -e "$missing_changed" ]
BASE="$base" HEAD="$head" PR_JSON="$tmp/pr.json" REPO=o/r PR=1 \
  CHANGED_FILES="$missing_changed" \
  API_FILES_FIXTURE="$tmp/unreadable-files.json" GH="$tmp/gh" \
  OUT="$out" MAX_BYTES=1000 MAX_COMMITS=100 "$gather"

[ "$(cat -- "$out/docs-only.txt")" = "false" ]
printf 'ok: docs-only unreadable\n'
