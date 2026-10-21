# Changelog

## v1.0.1 - 2026-10-21

- First immutable release (the repository turned on immutable releases after
  v1.0.0 shipped). No change to the action's behavior: same gh-actions-lock
  v0.2.0 binary and digest, same failure policy.
- Repository housekeeping only: a Dependabot auto-merge sweep, the fleet's
  agent guidance and skills bundle, and the README usage example now names
  v1.0.1.

## v1.0.0 - 2026-10-20

- First release: a composite action that runs `gh actions-lock --verify`
  (gh-actions-lock v0.2.0, linux-amd64, checksum-pinned) on pull requests that
  change workflow dependencies, fails on any finding except
  `cooldown-config-ignored`, and escapes finding text in `::error::` lines.
