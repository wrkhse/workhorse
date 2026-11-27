#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export TIDY_CACHE_ROOT="$work/cache"
mkdir -p "$work/repo/.githooks" "$work/repo/.github" "$TIDY_CACHE_ROOT"
cd "$work/repo"
git init -q -b main
git config user.email precommit@example.invalid
git config user.name precommit
cp "$repo_root/.githooks/pre-commit" .githooks/pre-commit
cp "$repo_root/.github/tidy.env" .github/tidy.env
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
printf '# hook selftest\n' > README.md
git add .githooks/pre-commit .github/tidy.env README.md
git commit -qm 'chore: setup'

printf '#[must_use]\npub fn badly_formatted()->usize{ 1 }\n' > bad.rs
git add bad.rs
git commit -qm 'fmt: badly formatted'
git show HEAD:bad.rs | grep -q 'pub fn badly_formatted() -> usize {'

printf 'const value={a:1};\n' > tidy-input.ts
git add tidy-input.ts
git commit -qm 'fmt: badly formatted TypeScript'
git show HEAD:tidy-input.ts | grep -q 'const value = { a: 1 };'

printf 'fn broken( {\n}\n' > parse.rs
git add parse.rs
if git commit -qm 'fmt: parse error' > "$work/parse.out" 2>&1; then
  echo 'parse error commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at rustfmt' "$work/parse.out"
git restore --staged --worktree parse.rs
rm -f parse.rs

printf 'one\n' > partial.md
git add partial.md
git commit -qm 'docs: partial base'
printf 'two\n' >> partial.md
git add partial.md
printf 'three\n' >> partial.md
if git commit -qm 'docs: partial' > "$work/partial.out" 2>&1; then
  echo 'partially staged commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'partially staged: partial.md' "$work/partial.out"
git restore --staged --worktree partial.md

printf '#[must_use]\npub fn dash()->usize{ 1 }\n' > --dash.rs
git add -- --dash.rs
git commit -qm 'fmt: dash filename'
git show 'HEAD:--dash.rs' | grep -q 'pub fn dash() -> usize {'

for cache_dir in "$TIDY_CACHE_ROOT"/tidy-*; do
  printf 'corrupt archive\n' > "$cache_dir/tidy.tar.gz"
done
printf '# note\n' > note.md
git add note.md
if git commit -qm 'chore: corrupted cache' > "$work/sha.out" 2>&1; then
  echo 'corrupted cache commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at tidy checksum' "$work/sha.out"
for cache_dir in "$TIDY_CACHE_ROOT"/tidy-*; do
  rm -f "$cache_dir/tidy.tar.gz"
done

echo 'pre-commit hook selftest: all cases passed'
