# verify-actions-lock

A composite GitHub Action that runs GitHub's
[`gh actions-lock`](https://github.com/github/gh-actions-lock) extension with
`--verify` on pull requests that change workflow dependencies. It is the "verify
job" that GitHub's guide
[Enforcing workflow lockfiles](https://docs.github.com/en/actions/how-tos/administer/enforce-workflow-lockfiles)
recommends running as a required check, plus three things the guide does not
cover:

1. **It fails on any finding, not just the exit code.** gh-actions-lock v0.2.0
   exits 0 with `"valid": true` and a `reachability-unknown` finding when
   GitHub's API is unreachable. This action fails then too; re-run the job once
   the API is back. One category is exempt: `cooldown-config-ignored`, which
   reports that gh-actions-lock ignores a `dependabot.yml` cooldown
   include/exclude list and says nothing about a pin. It is printed as a notice.
2. **It escapes finding text** before printing `::error::` lines (`%` to `%25`,
   CR to `%0D`, LF to `%0A`), so text the tool echoes cannot start a workflow
   command.
3. **It runs always, and verifies only when it matters.** On `pull_request`,
   `pull_request_target` and `merge_group` it verifies if and only if the change
   touches `.github/workflows/**`, `.github/actions/**`, or a file named
   `action.yml` or `action.yaml` anywhere; otherwise it succeeds with a notice.
   If it cannot tell (a base or head SHA is missing or malformed, the commits
   are not available even after a fetch, or `git diff` fails), it verifies. On
   `workflow_dispatch` it verifies. On any other event (`push`, `schedule`, ...)
   it skips with a notice: pins only change through pull requests.

## It is not the only guard

GitHub's runner rejects a forged pin, and the **Require lockfile** policy
blocks workflows that have not been onboarded. Turn that policy on as well; it
is the runtime backstop. This check adds early feedback for authors and
enforces something stricter than the runtime: each locked commit must be the
commit its tag points at now, so a downgrade within a tag's history is flagged
rather than merely visible in a diff.

## Usage

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<tag locked in actions.lock>
        with:
          persist-credentials: false
      - uses: Adam-S-Daniel/verify-actions-lock@v1.0.0
```

- **Reference it by release tag, locked in your `actions.lock`** like any other
  action. A bare SHA ref in a lockfile repository trips gh-actions-lock's
  `sha-as-ref` warning, which this check treats as a failure.
- **Put it in a job that is a required check and runs on every pull request.**
  Do not filter the workflow with `on.paths`: the action decides whether to
  verify, so the check always reports and never blocks a merge by going missing.
- **Linux x64 runners only.** The install step refuses any other `RUNNER_OS` or
  `RUNNER_ARCH`.

### Inputs

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | The repository checkout to verify. |
| `token` | `${{ github.token }}` | Token for `gh`; read-only is enough. |

### Outputs

| Output | Description |
| --- | --- |
| `ran` | `true` if the lockfile was verified, `false` if the check was skipped. |

## The pinned extension

`scripts/install.sh` downloads gh-actions-lock `v0.2.0`, asset `linux-amd64`,
and refuses it unless its SHA-256 is
`79ec84c191667fd935a277e6fd3662cf5d3669cccc9e99998731d8f306f373b6`. Any
previously installed `actions-lock` extension is removed first, so a stale one
is never used. To bump it, change `VERSION` and `SHA256` together in
`scripts/install.sh` (take the digest from the release asset you have
reviewed), update `CHANGELOG.md`, and cut a new release.

## When it fails

Every finding is printed as
`::error::actions.lock <category>: <dependency>: <detail>`.

- **A moved or unreachable pin:** find out why the tag moved or the commit
  disappeared first. If the new commit is the one you want, run
  `gh actions-lock --accept-moved` and commit the updated lockfile.
- **`reachability-unknown`:** the GitHub API was unreachable; re-run the job.
- **No readable JSON:** gh-actions-lock crashed or printed something else; read
  the job log.

## Limitations

- Cross-repository reusable workflows are not locked by gh-actions-lock today
  ([github/gh-actions-lock#179](https://github.com/github/gh-actions-lock/issues/179)).
- Docker images are not locked.
- If GitHub ships an official implementation of this check, replace this
  action with it.

## License

[MIT](LICENSE)
