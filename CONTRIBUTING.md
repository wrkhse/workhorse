# Contributing

## One-time local setup

Enable this repository's pre-commit hook once per checkout:

    git config core.hooksPath .githooks

On each commit the hook formats staged non-Rust files with tidy v2.0.0, using the repository's tidy.json, and re-stages them, with tidy skipping file types it does not recognize. It stops the commit, naming the reason, when a file cannot be formatted, when a file is partially staged, or when a tidy download, checksum, or platform step fails. It does not run clippy, compile or tests. It also runs rustfmt on staged .rs files and re-stages them, so rustfmt must be available. The tidy URL and SHA-256 pins for macOS arm64, macOS x86_64 and Linux x86_64 live in .github/tidy.env, shared with CI; on first use the hook verifies the checksum and caches the binary at ~/.cache/wrkhse/tidy-<sha>/.
