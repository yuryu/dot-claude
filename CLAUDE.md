# dot-claude

Personal Claude Code configuration, symlinked into `~/.claude` by `setup.sh`.

- `CLAUDE.global.md` is the user-level instructions file; it is linked to
  `~/.claude/CLAUDE.md`. This file (`CLAUDE.md`) is project instructions for
  working on the repo itself and is not linked anywhere.
- Edits to `settings.json`, `skills/`, and `scripts/` take effect immediately
  in all sessions via the symlinks — no re-run of `setup.sh` needed.
- When adding a new top-level file or directory that should live in
  `~/.claude`, add a `link` line to `setup.sh` and a row to the README table.
