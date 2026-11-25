#!/usr/bin/env bash
# Turn a `tidy check` exit status into the format job's result: 0 passes,
# 1 (unformatted files) and 2 (a parse or config error) fail with a named
# error, and any other status fails as itself.
#
# With EXPECT_STATUS set, it asserts instead: it prints the same named
# message for the status, then exits 0 when the status equals EXPECT_STATUS
# and 1 when it does not.
set -euo pipefail

status="${1:?usage: check-tidy-status.sh <tidy check exit status>}"

if [[ ! "$status" =~ ^[0-9]{1,3}$ ]]; then
  echo "::error::check-tidy-status.sh needs a numeric exit status, got '$status'"
  exit 1
fi

case "$status" in
  0)
    message=""
    code=0
    ;;
  1)
    message="::error::tidy found unformatted files (listed above); run tidy up on the named paths"
    code=1
    ;;
  2)
    message="::error::tidy hit a parse or config error (reported above)"
    code=2
    ;;
  *)
    message="::error::tidy check exited with unexpected status $status"
    code="$status"
    ;;
esac

if [[ -n "$message" ]]; then
  echo "$message"
fi

if [[ -z "${EXPECT_STATUS+set}" ]]; then
  exit "$code"
fi

if [[ ! "$EXPECT_STATUS" =~ ^[0-9]{1,3}$ ]]; then
  echo "::error::EXPECT_STATUS must be a numeric exit status, got '$EXPECT_STATUS'"
  exit 1
fi

if [[ "$status" -ne "$EXPECT_STATUS" ]]; then
  echo "::error::tidy check exited $status; expected $EXPECT_STATUS"
  exit 1
fi
