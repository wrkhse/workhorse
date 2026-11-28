#!/usr/bin/env bash
set -euo pipefail
: "${PR_JSON:?PR_JSON is required}"
jq -r '.body // ""' "$PR_JSON" | sha256sum | cut -d' ' -f1
