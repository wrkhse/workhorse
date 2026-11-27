#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${CI:-}" ]]; then
  echo 'hook selftest runs only in CI' >&2
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export TIDY_CACHE_ROOT="$work/cache"
mkdir -p "$work/repo/.githooks" "$work/repo/.github" "$TIDY_CACHE_ROOT"
cp "$repo_root/rust-toolchain.toml" "$work/repo/rust-toolchain.toml"
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

printf 'const = ;\n' > tidy-parse.ts
git add tidy-parse.ts
if git commit -qm 'fmt: tidy parse error' > "$work/tidyparse.out" 2>&1; then
  echo 'tidy parse error commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at tidy format' "$work/tidyparse.out"
git restore --staged --worktree tidy-parse.ts
rm -f tidy-parse.ts

printf 'fn broken( {\n}\n' > parse.rs
git add parse.rs
if git commit -qm 'fmt: parse error' > "$work/parse.out" 2>&1; then
  echo 'parse error commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at rustfmt' "$work/parse.out"
git restore --staged --worktree parse.rs
rm -f parse.rs

printf 'pub fn multi_a()->usize{ 1 }\n' > multi-a.rs
printf 'fn broken( {\n}\n' > multi-b.rs
git add multi-a.rs multi-b.rs
if git commit -qm 'fmt: multi file failure' > "$work/multi.out" 2>&1; then
  echo 'multi-file failure commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at rustfmt' "$work/multi.out"
if ! git show :multi-a.rs | grep -q 'pub fn multi_a() -> usize {'; then
  echo 'successfully formatted file was not staged' >&2
  exit 1
fi
git restore --staged --worktree multi-a.rs multi-b.rs
rm -f multi-a.rs multi-b.rs

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
for cache_dir in "$TIDY_CACHE_ROOT"/tidy-*; do
  printf 'not a tidy binary\n' > "$cache_dir/tidy"
  chmod -x "$cache_dir/tidy"
done
printf '# cached binary\n' > cache.md
git add cache.md
git commit -qm 'fmt: cached binary repair'
git show HEAD:cache.md | grep -q '# cached binary'

cp .github/tidy.env "$work/tidy.env.orig"
zeros="$(printf '0%.0s' {1..64})"
while IFS= read -r line; do
  case "$line" in
    TIDY_*SHA256=*) printf '%s\n' "${line%%=*}=$zeros" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$work/tidy.env.orig" > .github/tidy.env
git add .github/tidy.env
if git commit -qm 'chore: bad pin' > "$work/pin.out" 2>&1; then
  echo 'bad pin commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at tidy checksum' "$work/pin.out"
if [ -f "$TIDY_CACHE_ROOT/tidy-$zeros/tidy.tar.gz" ]; then
  echo 'unverified download was cached' >&2
  exit 1
fi
git restore --staged --worktree .github/tidy.env

while IFS= read -r line; do
  case "$line" in
    TIDY_*ASSET=*) ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$work/tidy.env.orig" > .github/tidy.env
git add .github/tidy.env
if git commit -qm 'test: missing pin' > "$work/missing.out" 2>&1; then
  echo 'missing pin commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at tidy pin' "$work/missing.out"
cp "$work/tidy.env.orig" .github/tidy.env
git restore --staged --worktree .github/tidy.env

while IFS= read -r line; do
  case "$line" in
    TIDY_*SHA256=*) printf '%s\n' "${line%%=*}=nothex" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$work/tidy.env.orig" > .github/tidy.env
git add .github/tidy.env
if git commit -qm 'test: bad sha format' > "$work/badsha.out" 2>&1; then
  echo 'bad SHA format commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at tidy pin' "$work/badsha.out"
cp "$work/tidy.env.orig" .github/tidy.env
git restore --staged --worktree .github/tidy.env

printf '# platform\n' > platform.md
git add platform.md
if TIDY_PLATFORM=Unknown-test git commit -qm 'test: unknown platform' > "$work/platform.out" 2>&1; then
  echo 'unknown platform commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at tidy platform' "$work/platform.out"
git restore --staged --worktree platform.md
rm -f platform.md

ones="$(printf '1%.0s' {1..64})"
while IFS= read -r line; do
  case "$line" in
    TIDY_RELEASE_BASE=*) printf '%s\n' "${line%%=*}=https://127.0.0.1:9/unreachable" ;;
    TIDY_*SHA256=*) printf '%s\n' "${line%%=*}=$ones" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$work/tidy.env.orig" > .github/tidy.env
git add .github/tidy.env
printf '# download failure\n' > download.md
git add download.md
if git commit -qm 'test: download failure' > "$work/download.out" 2>&1; then
  echo 'download failure commit unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'FAILED at tidy download' "$work/download.out"
cp "$work/tidy.env.orig" .github/tidy.env
git restore --staged --worktree .github/tidy.env
git restore --staged --worktree download.md
rm -f download.md

echo 'pre-commit hook selftest: all cases passed'
