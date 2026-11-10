#!/usr/bin/env bash
# Weekly watch for gh-actions-lock releases newer than the one this action
# pins (VERSION in scripts/install.sh). When the newest stable release that is
# past the fleet's 7-day wait is newer than the pin, open one issue for the
# owner, or move the open issue for an older release up to it.
#
# Logs tags and issue numbers only, never an API response body.
#
# Environment: GH_TOKEN and GITHUB_REPOSITORY (set by Actions). For tests:
# NOW_EPOCH (default: the current time), UPSTREAM, INSTALL_SH.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UPSTREAM=${UPSTREAM:-github/gh-actions-lock}
INSTALL_SH=${INSTALL_SH:-$ROOT/scripts/install.sh}
MIN_AGE_SECONDS=$((7 * 86400))
LABEL=upstream-release
OWNER_LABEL=needs-owner
ASSIGNEE=Adam-S-Daniel
SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+$'

# pinned_version: the VERSION= line of install.sh.
pinned_version() {
  sed -n 's/^VERSION=\(v[0-9][0-9.]*\)$/\1/p' "$INSTALL_SH" | head -n 1
}

# newer_stable_tags <pinned>: `git ls-remote --tags --refs` output on stdin;
# prints the stable vX.Y.Z tags newer than <pinned>, newest first.
newer_stable_tags() {
  local pinned=$1 tag
  while read -r _ ref; do
    tag=${ref#refs/tags/}
    [[ $tag =~ $SEMVER ]] || continue
    [[ $tag == "$pinned" ]] && continue
    # Newer when it sorts after the pin. An `if`, not `&&`: a false test as
    # the loop's last command would fail the pipeline under pipefail.
    if [[ $(printf '%s\n%s\n' "$pinned" "$tag" | sort -V | tail -n 1) == "$tag" ]]; then
      echo "$tag"
    fi
  done | sort -rV
}

# release_info <tag>: "<publishedAt> <isPrerelease> <isDraft>", or nothing
# when the tag has no release or the answer is not in that shape.
release_info() {
  local out
  out=$(gh release view "$1" -R "$UPSTREAM" --json publishedAt,isPrerelease,isDraft \
    --jq '"\(.publishedAt) \(.isPrerelease) \(.isDraft)"' 2>/dev/null) || out=""
  if [[ $out =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ (true|false)\ (true|false)$ ]]; then
    echo "$out"
  fi
}

issue_title() { echo "gh-actions-lock $1 is out: bump verify-actions-lock from $2"; }

# issue_body <tag> <pinned> <published>
issue_body() {
  cat <<EOF
[gh-actions-lock $1](https://github.com/$UPSTREAM/releases/tag/$1) was published $2 days or more ago ($3), past the fleet's 7-day wait. This action pins $4 in \`scripts/install.sh\`.

- [ ] Read the release notes for changes to \`--verify\` output or exit codes.
- [ ] Bump \`VERSION\` and \`SHA256\` in \`scripts/install.sh\`; cross-check the \`linux-amd64\` digest against the release API's asset \`digest\` and a plain download.
- [ ] Run \`bash test/run-tests.sh\`, open the PR, then tag a release of this action.

Opened by [upstream-release-watch](${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/workflows/upstream-release-watch.yml). It updates this issue when a newer release comes out and opens another only after this one is closed.
EOF
}

main() {
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
  local pinned now tags candidates target="" published="" info pub pre draft age
  pinned=$(pinned_version)
  if [[ ! $pinned =~ $SEMVER ]]; then
    echo "::error::Could not read a vX.Y.Z VERSION from scripts/install.sh."
    return 1
  fi
  now=${NOW_EPOCH:-$(date -u +%s)}

  if ! tags=$(git ls-remote --tags --refs "https://github.com/$UPSTREAM.git"); then
    echo "::error::git ls-remote of $UPSTREAM failed."
    return 1
  fi
  candidates=$(newer_stable_tags "$pinned" <<<"$tags")
  if [[ -z $candidates ]]; then
    echo "The pinned $pinned is the newest stable gh-actions-lock tag."
    return 0
  fi

  for tag in $candidates; do
    info=$(release_info "$tag")
    if [[ -z $info ]]; then
      echo "$tag: no published release found; skipping."
      continue
    fi
    read -r pub pre draft <<<"$info"
    if [[ $pre != false || $draft != false ]]; then
      echo "$tag: prerelease or draft; skipping."
      continue
    fi
    age=$((now - $(date -u -d "$pub" +%s)))
    if ((age < MIN_AGE_SECONDS)); then
      echo "$tag: published $pub, inside the 7-day wait; checking an older one."
      continue
    fi
    target=$tag
    published=$pub
    break
  done
  if [[ -z $target ]]; then
    echo "No release newer than $pinned is past the 7-day wait yet."
    return 0
  fi

  local title body_file open number existing_title
  title=$(issue_title "$target" "$pinned")
  body_file=$(mktemp)
  issue_body "$target" 7 "$published" "$pinned" >"$body_file"

  if ! open=$(gh issue list -R "$GITHUB_REPOSITORY" --state open --label "$LABEL" \
    --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null); then
    echo "::error::Listing open $LABEL issues failed."
    return 1
  fi
  if [[ -n $open ]]; then
    IFS=$'\t' read -r number existing_title <<<"$(head -n 1 <<<"$open")"
    if [[ $existing_title == "$title" ]]; then
      echo "Issue #$number already tracks $target; nothing to do."
      return 0
    fi
    gh issue edit "$number" -R "$GITHUB_REPOSITORY" --title "$title" --body-file "$body_file" >/dev/null
    echo "Moved issue #$number up to $target."
    return 0
  fi

  local url
  url=$(gh issue create -R "$GITHUB_REPOSITORY" --title "$title" --body-file "$body_file" --assignee "$ASSIGNEE")
  number=${url##*/}
  if [[ ! $number =~ ^[0-9]+$ ]]; then
    echo "::error::Could not read the new issue's number."
    return 1
  fi
  # The labels API creates a missing label. needs-owner is added once, here,
  # so the issue reaches the owner once.
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$number/labels" \
    -f "labels[]=$LABEL" -f "labels[]=$OWNER_LABEL" --silent
  echo "Opened issue #$number for $target."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
