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
printf 'ok: fixed-later\n'
