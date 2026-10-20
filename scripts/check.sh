#!/usr/bin/env bash
# Run gh actions-lock --verify and fail on a non-zero exit, valid != true, or any
# finding other than the exempt cooldown-config-ignored category.
set -euo pipefail

rc=0
out=$(gh actions-lock --verify --no-interactive --json=valid,findings) || rc=$?
if [[ "$rc" -ne 0 ]] || ! jq -e '.valid == true and ([.findings[] | select(.category != "cooldown-config-ignored")] | length) == 0' <<<"$out" >/dev/null; then
  # Escape %, CR and LF so finding text cannot start a new workflow command.
  if jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    jq -r 'def esc: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A"); .findings[]? | select(.category != "cooldown-config-ignored") | "::error::actions.lock \(.category | esc): \(.dependency // .workflow // "-" | esc): \(.detail | esc)"' <<<"$out"
  else
    echo '::error::gh actions-lock --verify returned no readable JSON.'
  fi
  if jq -e 'any(.findings[]?; .category == "reachability-unknown")' <<<"$out" >/dev/null 2>&1; then
    echo '::error::reachability-unknown means the GitHub API was unreachable; re-run once it is back.'
  fi
  echo "::error::gh actions-lock --verify failed (exit $rc)."
  exit 1
fi

if jq -e 'any(.findings[]?; .category == "cooldown-config-ignored")' <<<"$out" >/dev/null; then
  echo '::notice::Ignored a cooldown-config-ignored finding: gh actions-lock does not apply dependabot.yml cooldown include/exclude lists, which says nothing about whether a pin is valid.'
fi
echo 'gh actions-lock --verify: lockfile verified.'
