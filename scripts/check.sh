#!/usr/bin/env bash
# Run gh actions-lock --verify and fail when the tool fails (non-zero exit or
# valid != true) or reports any finding that is not a warning. Warnings, such
# as container-image or ref-moved, are printed as ::warning:: and do not fail.
set -euo pipefail

rc=0
out=$(gh actions-lock --verify --no-interactive --json=valid,findings) || rc=$?

if ! jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
  echo '::error::gh actions-lock --verify returned no readable JSON.'
  echo "::error::gh actions-lock --verify failed (exit $rc)."
  exit 1
fi

# Escape %, CR and LF so finding text cannot start a new workflow command.
jq -r 'def esc: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  .findings[]? | "::\(if .severity == "warning" then "warning" else "error" end)::actions.lock \(.category | esc): \(.dependency // .workflow // "-" | esc): \(.detail | esc)"' <<<"$out"

if [[ "$rc" -ne 0 ]] || ! jq -e '.valid == true and ([.findings[]? | select(.severity != "warning")] | length) == 0' <<<"$out" >/dev/null; then
  if jq -e 'any(.findings[]?; .retryable == true or .category == "reachability-unknown")' <<<"$out" >/dev/null; then
    echo '::error::GitHub did not answer for some pins; re-run once the API is back.'
  fi
  echo "::error::gh actions-lock --verify failed (exit $rc)."
  exit 1
fi
echo 'gh actions-lock --verify: lockfile verified.'
