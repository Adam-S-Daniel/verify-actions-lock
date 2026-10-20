# Changelog

## v1.0.0 - 2026-10-20

- First release: a composite action that runs `gh actions-lock --verify`
  (gh-actions-lock v0.2.0, linux-amd64, checksum-pinned) on pull requests that
  change workflow dependencies, fails on any finding except
  `cooldown-config-ignored`, and escapes finding text in `::error::` lines.
