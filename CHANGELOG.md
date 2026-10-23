# Changelog

## v1.1.0 - 2026-10-23

- gh-actions-lock v0.3.0 (linux-amd64, SHA-256
  `15810767a8cd28d389f0942e3ce515ac0008c3f65301c3834fd4c046d4bda497`; build
  attestation verified against its release workflow at `v0.3.0`). v0.3.0
  itself fails on pins GitHub did not answer for and on an exact tag locked
  behind its commit (`tag-commit-mismatch`), and no longer reports
  `cooldown-config-ignored` during `--verify`.
- Failure policy: fail when gh-actions-lock exits non-zero, reports `valid`
  other than `true`, or reports any non-warning finding. Warnings (for example
  v0.3.0's `container-image` and `ref-moved`) are printed as `::warning::` and
  no longer fail the check. The `cooldown-config-ignored` exemption is gone.
- The outage hint now also keys off `"retryable": true`.
- `schedule` events verify every pin (previously skipped), so a weekly
  scheduled run catches upstream changes between pull requests.
- First release cut since immutable releases were turned on (v1.0.1 was
  prepared but never released; its contents are included here).

## v1.0.0 - 2026-10-20

- First release: a composite action that runs `gh actions-lock --verify`
  (gh-actions-lock v0.2.0, linux-amd64, checksum-pinned) on pull requests that
  change workflow dependencies, fails on any finding except
  `cooldown-config-ignored`, and escapes finding text in `::error::` lines.
