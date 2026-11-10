#!/usr/bin/env bash
# Deterministic tests for verify-actions-lock: no network, no sleeps, no wall clock.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1${2:+ ($2)}"; failed=$((failed + 1)); }

# Keep git deterministic and independent of the user's configuration.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'

# ---------------------------------------------------------------------------
# decide.sh
# ---------------------------------------------------------------------------

# new_repo <name>: a repo with one base commit; prints its path.
new_repo() {
  local repo="$WORK/$1"
  git init -q -b main "$repo"
  mkdir -p "$repo/src" "$repo/docs" "$repo/.github/workflows"
  echo base >"$repo/src/x.py"
  echo base >"$repo/docs/readme.md"
  echo 'name: x' >"$repo/.github/workflows/x.yml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  echo "$repo"
}

# commit_change <repo> <command...>: run a change in the repo, commit, print the SHA.
commit_change() {
  local repo="$1"
  shift
  (cd "$repo" && "$@")
  git -C "$repo" add -A
  git -C "$repo" commit -q -m change
  git -C "$repo" rev-parse HEAD
}

# run_decide <name> <expected> <repo> <event> <base> <head>
run_decide() {
  local name="$1" expected="$2" repo="$3" event="$4" base="$5" head="$6"
  decide_n=$((decide_n + 1))
  local out="$WORK/decide-output-$decide_n"
  : >"$out"
  local rc=0
  (cd "$repo" && GITHUB_OUTPUT="$out" EVENT_NAME="$event" BASE_SHA="$base" HEAD_SHA="$head" \
    bash "$ROOT/scripts/decide.sh") >"$WORK/decide-log-$decide_n" 2>&1 || rc=$?
  local lines
  lines=$(grep -c '^run=' "$out" || true)
  if [[ "$rc" -ne 0 ]]; then
    fail "decide: $name" "exit $rc"
  elif [[ "$lines" -ne 1 ]]; then
    fail "decide: $name" "$lines run= lines"
  elif [[ "$(cat "$out")" != "run=$expected" ]]; then
    fail "decide: $name" "got '$(cat "$out")', want run=$expected"
  else
    pass "decide: $name"
  fi
}

decide_n=0
repo=$(new_repo decide)
base=$(git -C "$repo" rev-parse HEAD)

head=$(commit_change "$repo" sh -c 'echo changed >src/x.py')
run_decide "only src/x.py" false "$repo" pull_request "$base" "$head"

git -C "$repo" reset -q --hard "$base"
head=$(commit_change "$repo" sh -c 'echo "on: push" >.github/workflows/ci.yml')
run_decide ".github/workflows/ci.yml" true "$repo" pull_request "$base" "$head"

git -C "$repo" reset -q --hard "$base"
head=$(commit_change "$repo" sh -c 'echo "{}" >.github/workflows/actions.lock')
run_decide ".github/workflows/actions.lock" true "$repo" pull_request "$base" "$head"

git -C "$repo" reset -q --hard "$base"
head=$(commit_change "$repo" sh -c 'mkdir -p .github/actions/a && echo "name: a" >.github/actions/a/action.yml')
run_decide ".github/actions/a/action.yml" true "$repo" pull_request_target "$base" "$head"

git -C "$repo" reset -q --hard "$base"
head=$(commit_change "$repo" sh -c 'mkdir -p tools/b && echo "name: b" >tools/b/action.yaml')
run_decide "tools/b/action.yaml" true "$repo" pull_request "$base" "$head"

git -C "$repo" reset -q --hard "$base"
head=$(commit_change "$repo" git mv .github/workflows/x.yml docs/x.yml)
run_decide "rename .github/workflows/x.yml to docs/x.yml" true "$repo" pull_request "$base" "$head"

git -C "$repo" reset -q --hard "$base"
head=$(commit_change "$repo" sh -c 'echo changed >docs/readme.md')
run_decide "base SHA empty" true "$repo" pull_request "" "$head"
run_decide "base SHA not 40-hex" true "$repo" pull_request "${base:0:39}g" "$head"
# A short SHA resolves locally, so only the format check sends this one to run=true.
run_decide "base SHA abbreviated (resolvable but not 40-hex)" true "$repo" pull_request "${base:0:12}" "$head"
run_decide "base commit unknown, no origin" true "$repo" pull_request "0123456789abcdef0123456789abcdef01234567" "$head"
run_decide "push" false "$repo" push "$base" "$head"
run_decide "schedule" true "$repo" schedule "" ""
run_decide "workflow_dispatch" true "$repo" workflow_dispatch "" ""
run_decide "merge_group touching only docs" false "$repo" merge_group "$base" "$head"

# ---------------------------------------------------------------------------
# check.sh, with a stub gh that prints $FIXTURE_FILE and exits $FIXTURE_RC
# ---------------------------------------------------------------------------

STUB_CHECK="$WORK/stub-check"
mkdir -p "$STUB_CHECK"
cat >"$STUB_CHECK/gh" <<'EOF'
#!/usr/bin/env bash
cat "$FIXTURE_FILE"
exit "$FIXTURE_RC"
EOF
chmod +x "$STUB_CHECK/gh"

CHECK_OUT="$WORK/check-out"
# run_check <fixture-content> <fixture-rc>; sets check_rc, output in $CHECK_OUT
run_check() {
  printf '%s' "$1" >"$WORK/fixture"
  check_rc=0
  PATH="$STUB_CHECK:$PATH" FIXTURE_FILE="$WORK/fixture" FIXTURE_RC="$2" \
    bash "$ROOT/scripts/check.sh" >"$CHECK_OUT" 2>/dev/null || check_rc=$?
}
has_line() { grep -qxF -- "$1" "$CHECK_OUT"; }
has_prefix() { grep -q -- "^$1" "$CHECK_OUT"; }

API_HINT='::error::GitHub did not answer for some pins; re-run once the API is back.'
NO_JSON='::error::gh actions-lock --verify returned no readable JSON.'

run_check '{"valid":true,"findings":[]}' 0
if [[ "$check_rc" -eq 0 ]] && has_line 'gh actions-lock --verify: lockfile verified.'; then
  pass "check: clean"
else fail "check: clean" "exit $check_rc"; fi

run_check '{"valid":true,"findings":[{"category":"container-image","severity":"warning","dependency":"docker://alpine:3","detail":"image not locked"}]}' 0
if [[ "$check_rc" -eq 0 ]] && has_line '::warning::actions.lock container-image: docker://alpine:3: image not locked' \
  && ! has_prefix '::error::' && has_line 'gh actions-lock --verify: lockfile verified.'; then
  pass "check: a warning finding passes and is printed as ::warning::"
else fail "check: a warning finding passes and is printed as ::warning::" "exit $check_rc"; fi

run_check '{"valid":true,"findings":[{"category":"tag-commit-mismatch","severity":"error","dependency":"x/y@v1.2.3","detail":"behind"}]}' 0
if [[ "$check_rc" -eq 1 ]] && has_line '::error::actions.lock tag-commit-mismatch: x/y@v1.2.3: behind'; then
  pass "check: an error finding fails even when the tool exits 0"
else fail "check: an error finding fails even when the tool exits 0" "exit $check_rc"; fi

run_check '{"valid":false,"findings":[{"category":"api-unavailable","severity":"error","retryable":true,"dependency":"x/y@v1","detail":"no answer"}]}' 1
if [[ "$check_rc" -eq 1 ]] && has_line "$API_HINT"; then
  pass "check: a retryable finding fails with the API hint"
else fail "check: a retryable finding fails with the API hint" "exit $check_rc"; fi

run_check '{"valid":true,"findings":[{"category":"reachability-unknown","dependency":"actions/checkout@v7","detail":"api unreachable"}]}' 0
if [[ "$check_rc" -eq 1 ]] && has_line "$API_HINT" \
  && has_line '::error::actions.lock reachability-unknown: actions/checkout@v7: api unreachable'; then
  pass "check: reachability-unknown with exit 0 fails with the API hint"
else fail "check: reachability-unknown with exit 0 fails with the API hint" "exit $check_rc"; fi

run_check '{"valid":false,"findings":[{"category":"unreachable-pin","dependency":"x/y@v1","detail":"gone"}]}' 1
n=$(grep -c '^::error::actions.lock unreachable-pin: ' "$CHECK_OUT" || true)
if [[ "$check_rc" -eq 1 ]] && [[ "$n" -eq 1 ]] && ! has_line "$API_HINT" \
  && has_line '::error::gh actions-lock --verify failed (exit 1).'; then
  pass "check: unreachable-pin fails with one error and no API hint"
else fail "check: unreachable-pin fails with one error and no API hint" "exit $check_rc, $n lines"; fi

for case_name in empty null non-json; do
  case "$case_name" in
    empty) fixture='' ;;
    null) fixture='null' ;;
    non-json) fixture='panic: something broke' ;;
  esac
  run_check "$fixture" 0
  if [[ "$check_rc" -eq 1 ]] && has_line "$NO_JSON"; then
    pass "check: $case_name output reports no readable JSON"
  else fail "check: $case_name output reports no readable JSON" "exit $check_rc"; fi
done

run_check "$(jq -cn '{valid:false,findings:[{category:"c%d\r",dependency:"x/y@v1",detail:"a\n::add-mask::x"}]}')" 1
want='::error::actions.lock c%25d%0D: x/y@v1: a%0A::add-mask::x'
n=$(grep -c 'x/y@v1' "$CHECK_OUT" || true)
if [[ "$check_rc" -eq 1 ]] && has_line "$want" && [[ "$n" -eq 1 ]] && ! has_prefix '::add-mask::'; then
  pass "check: finding text is escaped"
else fail "check: finding text is escaped" "exit $check_rc, $n lines"; fi

# ---------------------------------------------------------------------------
# install.sh, with a stub gh that records its calls
# ---------------------------------------------------------------------------

STUB_INSTALL="$WORK/stub-install"
mkdir -p "$STUB_INSTALL"
cat >"$STUB_INSTALL/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
if [[ "$1 $2" == "release download" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-O" ]]; then echo "not the real binary" >"$2"; fi
    shift
  done
fi
exit 0
EOF
chmod +x "$STUB_INSTALL/gh"

# run_install <name> [env assignments...]; sets install_rc
run_install() {
  local name="$1"
  shift
  GH_CALLS="$WORK/gh-calls-$name"
  : >"$GH_CALLS"
  install_rc=0
  env PATH="$STUB_INSTALL:$PATH" GH_CALLS="$GH_CALLS" RUNNER_TEMP="$WORK/runner-temp-$name" "$@" \
    bash "$ROOT/scripts/install.sh" >"$WORK/install-log-$name" 2>&1 || install_rc=$?
}

run_install mismatch RUNNER_OS=Linux RUNNER_ARCH=X64
if [[ "$install_rc" -ne 0 ]] && grep -q '^release download' "$GH_CALLS" \
  && ! grep -q '^extension install' "$GH_CALLS"; then
  pass "install: checksum mismatch fails before installing"
else fail "install: checksum mismatch fails before installing" "exit $install_rc"; fi

run_install windows RUNNER_OS=Windows RUNNER_ARCH=X64
if [[ "$install_rc" -ne 0 ]] && [[ ! -s "$GH_CALLS" ]]; then
  pass "install: refuses Windows before downloading"
else fail "install: refuses Windows before downloading" "exit $install_rc"; fi

# ---------------------------------------------------------------------------
# upstream-watch.sh, with a stub git and gh that answer from fixtures
# ---------------------------------------------------------------------------

STUB_WATCH="$WORK/stub-watch"
mkdir -p "$STUB_WATCH"
cat >"$STUB_WATCH/git" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "ls-remote" ]] || exit 99
cat "$TAGS"
EOF
cat >"$STUB_WATCH/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
case "$1 $2" in
  "release view")
    # RELEASES lines: <tag> <publishedAt> <isPrerelease> <isDraft>
    line=$(grep "^$3 " "$RELEASES") || { echo '{"message":"release not found"}'; exit 1; }
    echo "${line#* }" ;;
  "issue list") cat "$OPEN_ISSUES" ;;
  "issue create") echo "https://github.com/o/r/issues/42" ;;
esac
exit 0
EOF
chmod +x "$STUB_WATCH/git" "$STUB_WATCH/gh"

# Pin v0.4.0, like scripts/install.sh, but from a fixture.
printf 'VERSION=v0.4.0\nSHA256=0\n' >"$WORK/install-fixture.sh"
# 2026-11-10T00:00:00Z
WATCH_NOW=1794268800

# run_watch <name> <tags> <releases> <open-issues>; sets watch_rc, WATCH_OUT, GH_CALLS
run_watch() {
  local name="$1"
  printf '%b' "$2" >"$WORK/tags-$name"
  printf '%b' "$3" >"$WORK/releases-$name"
  printf '%b' "$4" >"$WORK/issues-$name"
  GH_CALLS="$WORK/watch-calls-$name"
  WATCH_OUT="$WORK/watch-log-$name"
  : >"$GH_CALLS"
  watch_rc=0
  env PATH="$STUB_WATCH:$PATH" GH_CALLS="$GH_CALLS" TAGS="$WORK/tags-$name" RELEASES="$WORK/releases-$name" \
    OPEN_ISSUES="$WORK/issues-$name" NOW_EPOCH="$WATCH_NOW" INSTALL_SH="$WORK/install-fixture.sh" \
    GITHUB_REPOSITORY=o/r bash "$ROOT/scripts/upstream-watch.sh" >"$WATCH_OUT" 2>&1 || watch_rc=$?
}

TAGS_ALL='a\trefs/tags/v0.3.0\nb\trefs/tags/v0.4.0\nc\trefs/tags/v0.4.1\nd\trefs/tags/v0.5.0-rc.1\ne\trefs/tags/v0.10.0\n'

# Sourced, the script defines its functions without running main.
newer=$(
  # shellcheck source=/dev/null
  source "$ROOT/scripts/upstream-watch.sh"
  printf '%b' "$TAGS_ALL" | newer_stable_tags v0.4.0 | tr '\n' ' '
)
if [[ "$newer" == "v0.10.0 v0.4.1 " ]]; then
  pass "watch: newer stable tags, version-sorted, newest first"
else fail "watch: newer stable tags, version-sorted, newest first" "got '$newer'"; fi

run_watch none 'b\trefs/tags/v0.4.0\n' '' ''
if [[ "$watch_rc" -eq 0 ]] && ! grep -q '^release view' "$GH_CALLS" && ! grep -q '^issue' "$GH_CALLS"; then
  pass "watch: nothing newer opens nothing"
else fail "watch: nothing newer opens nothing" "exit $watch_rc"; fi

# v0.4.1 is 8 days old.
run_watch opens 'b\trefs/tags/v0.4.0\nc\trefs/tags/v0.4.1\n' 'v0.4.1 2026-11-02T00:00:00Z false false\n' ''
if [[ "$watch_rc" -eq 0 ]] && grep -q '^issue create -R o/r --title gh-actions-lock v0.4.1 is out: bump verify-actions-lock from v0.4.0 ' "$GH_CALLS" \
  && grep -q -- '--assignee Adam-S-Daniel' "$GH_CALLS" \
  && grep -qxF 'api -X POST repos/o/r/issues/42/labels -f labels[]=upstream-release -f labels[]=needs-owner --silent' "$GH_CALLS"; then
  pass "watch: a release past 7 days opens one labeled, assigned issue"
else fail "watch: a release past 7 days opens one labeled, assigned issue" "exit $watch_rc"; fi

# v0.4.1 is 6 days old: wait.
run_watch waits 'c\trefs/tags/v0.4.1\n' 'v0.4.1 2026-11-04T00:00:00Z false false\n' ''
if [[ "$watch_rc" -eq 0 ]] && ! grep -q '^issue' "$GH_CALLS"; then
  pass "watch: a release inside the 7-day wait opens nothing"
else fail "watch: a release inside the 7-day wait opens nothing" "exit $watch_rc"; fi

# Exactly 7 days old counts.
run_watch boundary 'c\trefs/tags/v0.4.1\n' 'v0.4.1 2026-11-03T00:00:00Z false false\n' ''
if [[ "$watch_rc" -eq 0 ]] && grep -q '^issue create' "$GH_CALLS"; then
  pass "watch: exactly 7 days old is past the wait"
else fail "watch: exactly 7 days old is past the wait" "exit $watch_rc"; fi

# The newest is too young, so the next older one past the wait is used.
run_watch fallback 'c\trefs/tags/v0.4.1\ne\trefs/tags/v0.5.0\n' \
  'v0.5.0 2026-11-09T00:00:00Z false false\nv0.4.1 2026-11-01T00:00:00Z false false\n' ''
if [[ "$watch_rc" -eq 0 ]] && grep -q '^issue create -R o/r --title gh-actions-lock v0.4.1 ' "$GH_CALLS"; then
  pass "watch: falls back to the newest release past the wait"
else fail "watch: falls back to the newest release past the wait" "exit $watch_rc"; fi

run_watch prerelease 'c\trefs/tags/v0.4.1\n' 'v0.4.1 2026-11-01T00:00:00Z true false\n' ''
if [[ "$watch_rc" -eq 0 ]] && ! grep -q '^issue' "$GH_CALLS"; then
  pass "watch: a prerelease opens nothing"
else fail "watch: a prerelease opens nothing" "exit $watch_rc"; fi

# A tag with no release: the stub's error body must not reach the log.
run_watch norelease 'c\trefs/tags/v0.4.1\n' '' ''
if [[ "$watch_rc" -eq 0 ]] && ! grep -q '^issue' "$GH_CALLS" && ! grep -q 'message' "$WATCH_OUT"; then
  pass "watch: a tag without a release opens nothing and logs no API body"
else fail "watch: a tag without a release opens nothing and logs no API body" "exit $watch_rc"; fi

run_watch dedupe 'c\trefs/tags/v0.4.1\n' 'v0.4.1 2026-11-01T00:00:00Z false false\n' \
  '7\tgh-actions-lock v0.4.1 is out: bump verify-actions-lock from v0.4.0\n'
if [[ "$watch_rc" -eq 0 ]] && ! grep -q '^issue create' "$GH_CALLS" && ! grep -q '^issue edit' "$GH_CALLS" \
  && ! grep -q '^api' "$GH_CALLS"; then
  pass "watch: an open issue for the same release is left alone"
else fail "watch: an open issue for the same release is left alone" "exit $watch_rc"; fi

run_watch moveup 'c\trefs/tags/v0.4.1\ne\trefs/tags/v0.5.0\n' 'v0.5.0 2026-11-01T00:00:00Z false false\n' \
  '7\tgh-actions-lock v0.4.1 is out: bump verify-actions-lock from v0.4.0\n'
if [[ "$watch_rc" -eq 0 ]] && ! grep -q '^issue create' "$GH_CALLS" \
  && grep -q '^issue edit 7 -R o/r --title gh-actions-lock v0.5.0 is out' "$GH_CALLS" && ! grep -q '^api' "$GH_CALLS"; then
  pass "watch: an open issue for an older release moves up, without re-adding needs-owner"
else fail "watch: an open issue for an older release moves up, without re-adding needs-owner" "exit $watch_rc"; fi

printf 'VERSION=latest\n' >"$WORK/install-bad.sh"
watch_rc=0
env PATH="$STUB_WATCH:$PATH" GH_CALLS="$WORK/watch-calls-bad" INSTALL_SH="$WORK/install-bad.sh" GITHUB_REPOSITORY=o/r \
  bash "$ROOT/scripts/upstream-watch.sh" >"$WORK/watch-log-bad" 2>&1 || watch_rc=$?
if [[ "$watch_rc" -ne 0 ]]; then
  pass "watch: an unreadable pin fails"
else fail "watch: an unreadable pin fails" "exit $watch_rc"; fi

if [[ "$(sed -n 's/^VERSION=//p' "$ROOT/scripts/install.sh")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "watch: install.sh's VERSION is in the shape the watch reads"
else fail "watch: install.sh's VERSION is in the shape the watch reads"; fi

# ---------------------------------------------------------------------------
# Scheduled workflows: least privilege, no expressions in run:, a Monday cron
# ---------------------------------------------------------------------------

wf_rc=0
# shellcheck disable=SC2016
wf_out=$(python3 -I -c '
import sys
try:
    import yaml
except ImportError:
    print("PyYAML is not installed; cannot check the workflows")
    sys.exit(2)
problems = []
def load(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    # PyYAML reads the bare key `on` as True.
    doc["on"] = doc.pop(True, doc.get("on"))
    return doc
watch = load(sys.argv[1])
crons = [s["cron"] for s in watch["on"].get("schedule", [])]
if len(crons) != 1 or crons[0].split()[4] != "1" or crons[0].split()[0] in ("0", "30"):
    problems.append("watch: want one Monday cron on a jittered minute, got %r" % crons)
if "workflow_dispatch" not in watch["on"]:
    problems.append("watch: no workflow_dispatch")
if watch.get("permissions") != {}:
    problems.append("watch: top-level permissions is not {}")
for name, job in watch["jobs"].items():
    if job.get("permissions") != {"contents": "read", "issues": "write"}:
        problems.append("watch: job %s permissions %r" % (name, job.get("permissions")))
    for i, step in enumerate(job.get("steps", [])):
        if "${{" in str(step.get("run", "")):
            problems.append("watch: job %s step %d run: contains ${{" % (name, i))
health = load(sys.argv[2])
uses = [j.get("uses", "") for j in health["jobs"].values()]
ref = "Adam-S-Daniel/_agent-guidance/.github/workflows/scheduled-run-health-reusable.yml@"
if len(uses) != 1 or not uses[0].startswith(ref) or len(uses[0][len(ref):]) != 40:
    problems.append("health: want one call to the reusable at a full sha, got %r" % uses)
if health.get("permissions") != {"contents": "read", "actions": "read", "issues": "write"}:
    problems.append("health: permissions %r" % health.get("permissions"))
print("; ".join(problems))
sys.exit(1 if problems else 0)
' "$ROOT/.github/workflows/upstream-release-watch.yml" "$ROOT/.github/workflows/scheduled-run-health.yml" 2>&1) || wf_rc=$?
if [[ "$wf_rc" -eq 0 ]]; then
  pass "scheduled workflows shape"
else
  fail "scheduled workflows shape" "$wf_out"
fi

# ---------------------------------------------------------------------------
# action.yml shape, parsed with PyYAML
# ---------------------------------------------------------------------------

shape_rc=0
# The single quotes are deliberate: "${{" is Python text, not a shell expansion.
# shellcheck disable=SC2016
shape_out=$(python3 -I -c '
import sys
try:
    import yaml
except ImportError:
    print("PyYAML is not installed; cannot check action.yml shape")
    sys.exit(2)
with open(sys.argv[1]) as f:
    action = yaml.safe_load(f)
problems = []
runs = action.get("runs", {})
if runs.get("using") != "composite":
    problems.append("runs.using is not composite")
steps = runs.get("steps", [])
if len(steps) != 3:
    problems.append("expected 3 steps, found %d" % len(steps))
for i, step in enumerate(steps):
    if step.get("shell") != "bash":
        problems.append("step %d has no shell: bash" % i)
    if "${{" in str(step.get("run", "")):
        problems.append("step %d run: contains ${{" % i)
if not steps or steps[0].get("id") != "decide":
    problems.append("first step id is not decide")
for i in (1, 2):
    if i < len(steps) and steps[i].get("if") != "steps.decide.outputs.run == '"'"'true'"'"'":
        problems.append("step %d if: is %r" % (i, steps[i].get("if")))
print("; ".join(problems))
sys.exit(1 if problems else 0)
' "$ROOT/action.yml" 2>&1) || shape_rc=$?
if [[ "$shape_rc" -eq 0 ]]; then
  pass "action.yml shape"
else
  fail "action.yml shape" "$shape_out"
fi

echo
echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
