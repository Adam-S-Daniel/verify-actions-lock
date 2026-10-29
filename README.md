# verify-actions-lock

A composite GitHub Action that runs GitHub's
[`gh actions-lock`](https://github.com/github/gh-actions-lock) extension with
`--verify` on pull requests that change workflow dependencies. It is the "verify
job" that GitHub's guide
[Enforcing workflow lockfiles](https://docs.github.com/en/actions/how-tos/administer/enforce-workflow-lockfiles)
recommends running as a required check. GitHub also publishes a sample
workflow for it
([`verify-lockfile.yml`](https://github.com/github/gh-actions-lock/blob/main/.github/workflows/verify-lockfile.yml));
this action differs in three ways:

1. **It installs a checksum-verified binary.** The release asset's SHA-256 is
   pinned in `scripts/install.sh`, rather than trusting the release tag alone.
2. **It fails on errors, warns on warnings, and escapes both.** It fails when
   gh-actions-lock exits non-zero, reports `valid` other than `true`, or reports
   any finding that is not a warning. Warnings (for example `container-image`
   or `ref-moved`) are printed as `::warning::` and do not fail the check.
   Finding text is escaped (`%` to `%25`, CR to `%0D`, LF to `%0A`) so nothing
   the tool echoes can start a workflow command.
3. **It runs always, and verifies only when it matters.** On `pull_request`,
   `pull_request_target` and `merge_group` it verifies if and only if the change
   touches `.github/workflows/**`, `.github/actions/**`, or a file named
   `action.yml` or `action.yaml` anywhere; otherwise it succeeds with a notice.
   If it cannot tell (a base or head SHA is missing or malformed, the commits
   are not available even after a fetch, or `git diff` fails), it verifies. On
   `schedule` and `workflow_dispatch` it verifies every pin, which catches
   upstream changes (a re-pointed tag, a commit that left its branch) between
   pull requests; add a weekly `schedule` trigger to the workflow for that. On
   any other event (`push`, ...) it skips with a notice.

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
      - uses: Adam-S-Daniel/verify-actions-lock@v1.1.0
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

`scripts/install.sh` downloads gh-actions-lock `v0.3.0`, asset `linux-amd64`,
and refuses it unless its SHA-256 is
`15810767a8cd28d389f0942e3ce515ac0008c3f65301c3834fd4c046d4bda497`. Any
previously installed `actions-lock` extension is removed first, so a stale one
is never used. To bump it, change `VERSION` and `SHA256` together in
`scripts/install.sh` (take the digest from the release asset you have
reviewed and whose build attestation you have checked with
`gh attestation verify <file> -R github/gh-actions-lock`), update
`CHANGELOG.md`, and cut a new release.

## When it fails

Every finding is printed as
`::error::actions.lock <category>: <dependency>: <detail>` (or `::warning::`
for warnings). Each finding's `doc_url` points into gh-actions-lock's
[troubleshooting guide](https://github.com/github/gh-actions-lock/blob/main/docs/troubleshooting.md).

- **`tag-commit-mismatch`:** an exact tag is locked to an older commit than the
  one it points at. Find out why, then run `gh actions-lock --relock` and commit
  the updated lockfile.
- **A moved or unreachable pin:** find out why the tag moved or the commit
  disappeared first. If the new commit is the one you want, run
  `gh actions-lock --accept-moved` and commit the updated lockfile.
- **GitHub did not answer** (`reachability-unknown` or `"retryable": true`):
  re-run the job once the API is back.
- **No readable JSON:** gh-actions-lock crashed or printed something else; read
  the job log.

## Limitations

- Cross-repository reusable workflows are not locked by gh-actions-lock today
  ([github/gh-actions-lock#179](https://github.com/github/gh-actions-lock/issues/179)).
- Docker images are not locked; gh-actions-lock reports them as
  `container-image` warnings.
- If GitHub's own sample workflow comes to cover the three differences above,
  replace this action with it.

## License

[Apache-2.0](LICENSE)
