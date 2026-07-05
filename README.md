# dot-claude

Personal Claude Code configuration, symlinked into `~/.claude`.

## Layout

| Repo path | Linked to | Purpose |
|---|---|---|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | Global (user-level) instructions |
| `settings.json` | `~/.claude/settings.json` | User settings: model, plugins, permissions |
| `skills/` | `~/.claude/skills/` | Personal skills / slash commands |
| `scripts/` | `~/.claude/scripts/` | Trusted scripts at a fixed path (referenced from permission allowlists) |

## Setup

```sh
./setup.sh
```

Creates the symlinks above. Existing symlinks are replaced; existing real
files are backed up to `<name>.bak.<timestamp>` first.

Machine-local state (`settings.local.json`, `~/.claude.json`, caches,
history) is deliberately not tracked.
