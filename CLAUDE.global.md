# Global instructions

## GitHub

* Attribute Claude's writing: `gh` posts under the user's account, so end every Claude-written issue, comment, or review reply with a `🤖 Generated with Claude Code` footer.
* Post in auditable form: a hook auto-approves attributed `gh` posts to `github.com/yuryu` repos, but only when it can prove the command does nothing else. Make the `gh` call the entire command — no `&&`/`;`/pipes, no `$(...)`, backticks, or `$VAR`, no redirection, no heredocs. Write multi-line bodies to a file with the Write tool (footer included) and pass `--body-file <path>`; keep inline `--body` to a single line. Anything fancier isn't blocked — it just falls back to a normal permission prompt.
