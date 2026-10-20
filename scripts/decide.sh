#!/usr/bin/env bash
# Decide whether to verify the lockfile. Writes exactly one run=true|false line
# to $GITHUB_OUTPUT. When in doubt on a pull request, run.
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
EVENT_NAME="${EVENT_NAME:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"

decide() {
  # $1: true|false, $2: reason
  if [[ "$1" == "false" ]]; then
    echo "::notice::verify-actions-lock skipped: $2"
  else
    echo "verify-actions-lock will run: $2"
  fi
  echo "run=$1" >>"$GITHUB_OUTPUT"
  exit 0
}

case "$EVENT_NAME" in
  pull_request | pull_request_target | merge_group) ;;
  workflow_dispatch) decide true "event is workflow_dispatch." ;;
  *) decide false "event '$EVENT_NAME' is not a pull request; pins only change through pull requests, and the runner and the Require lockfile policy cover runtime." ;;
esac

sha_re='^[0-9a-f]{40}$'
if ! [[ "$BASE_SHA" =~ $sha_re && "$HEAD_SHA" =~ $sha_re ]]; then
  decide true "base or head SHA is missing or malformed, so changed files are unknown."
fi

have_commits() {
  git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null && git cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null
}

if ! have_commits; then
  git fetch --no-tags --depth=1 origin "$BASE_SHA" "$HEAD_SHA" >/dev/null 2>&1 || true
  if ! have_commits; then
    decide true "base or head commit is not available locally, so changed files are unknown."
  fi
fi

# Two-dot diff: a superset of the pull request's own changes, so it can only
# over-run, never miss. --no-renames lists both sides of a rename.
# The list is NUL-separated, which command substitution cannot hold; use a file.
changed=$(mktemp)
trap 'rm -f "$changed"' EXIT
if ! git diff --no-renames --name-only -z "$BASE_SHA" "$HEAD_SHA" >"$changed"; then
  decide true "git diff failed, so changed files are unknown."
fi

while IFS= read -r -d '' path; do
  case "$path" in
    .github/workflows/* | .github/actions/* | action.yml | action.yaml | */action.yml | */action.yaml)
      # Escape %, CR and LF: a path is untrusted text and must not start a workflow command.
      safe=${path//%/%25}
      safe=${safe//$'\r'/%0D}
      safe=${safe//$'\n'/%0A}
      decide true "changed path '$safe' can affect workflow dependencies."
      ;;
  esac
done <"$changed"

decide false "no changed path under .github/workflows/, .github/actions/, or named action.yml/action.yaml."
