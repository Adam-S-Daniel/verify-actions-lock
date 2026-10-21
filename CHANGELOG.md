# Changelog

## v1.0.1 - 2026-10-21

- No change to the action. Re-released because v1.0.0 was published before
  immutable releases were turned on, so its tag can still move; v1.0.1 can't.
  Callers should move to v1.0.1.

## v1.0.0 - 2026-10-20

- First release: a composite action that runs `gh actions-lock --verify`
  (gh-actions-lock v0.2.0, linux-amd64, checksum-pinned) on pull requests that
  change workflow dependencies, fails on any finding except
  `cooldown-config-ignored`, and escapes finding text in `::error::` lines.
