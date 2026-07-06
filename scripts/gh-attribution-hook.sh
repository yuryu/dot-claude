#!/bin/bash
# gh-attribution-hook.sh — PreToolUse hook for the Bash tool that enforces the
# "🤖 Generated with Claude Code" footer on gh commands that post Claude-written
# content (issue/PR bodies, comments, reviews) to repos under github.com/yuryu.
#
# The CLAUDE.md attribution rule is advisory — the model usually follows it,
# but nothing checks. This hook is the backstop: the harness runs it before
# Bash calls that match the hook's `if` filter in settings.json
# ("Bash(gh *)" — any subcommand invoking gh, with the filter failing open
# on unparseable commands), and a posting command whose body lacks the footer
# is denied
# with a reason, so Claude retries with the footer appended. It deliberately
# never rewrites the command itself — injecting text into arbitrary shell
# (quoting, heredocs, --body-file) is fragile, and a wrong rewrite would post
# mangled content; a deny is always safe.
#
# This is a best-effort scan of a shell command string, not a parser, so it is
# tuned to fail in the cheap direction: a rare false deny just makes Claude
# retry with the footer, while the remaining blind spots (a body that itself
# quotes the footer or the pr-review.sh path, flag-lookalike text inside a
# body) fall back to the advisory rule rather than blocking anything.
#
# Compliant posts are additionally auto-approved (permissionDecision "allow",
# which skips the permission prompt for the whole Bash command) — but only in
# auditable form, because "allow" is the one direction where a heuristic
# misread is expensive. Auditable means the scan provably saw everything the
# shell will do: a single plain gh invocation that is the entire command, with
# no expansions ($, backticks), no compound operators or redirections outside
# quoted spans, no embedded newlines/heredocs, and not `gh api` (its field
# soup is too loose to audit). Compliant posts in any fancier form stay
# silent and fall through to the normal permission prompt — same cheap
# failure direction as the deny side.
#
# Out-of-scope calls stay silent (exit 0, no output, no permission opinion):
#   - anything that isn't a content-posting gh command (reads, --help, other
#     tools; a bare `gh pr review --approve` carries no Claude-written text)
#   - repos not under github.com/yuryu — the target is the --repo/-R flag if
#     given, else the origin remote of the directory gh runs in (a leading
#     `cd <dir> && ...` prefix is honored, else the session's cwd)
#   - ~/.claude/scripts/pr-review.sh invocations (it appends the footer
#     itself, so its stdin bodies legitimately lack it at hook time)
#   - machines without jq (fail open silently rather than surfacing a hook
#     error on every Bash call; pr-review.sh, by contrast, hard-fails)
set -euo pipefail

# Matches both footer forms: the plain one and the markdown-link one Claude
# Code's own PR convention emits ("🤖 Generated with [Claude Code](https://claude.com/claude-code)").
MARKER_RE='Generated with \[?Claude Code'
# FOOTER must itself satisfy MARKER_RE, or the deny reason would tell Claude
# to append a footer the hook can never recognize — an infinite deny loop.
FOOTER='🤖 Generated with Claude Code'
ALLOWED_OWNER='yuryu'

payload=$(cat)

# Spawn-free fast path: most Bash calls never mention gh at all; skip the jq
# spawns entirely for them. (False positives just fall through to real checks.)
case "$payload" in *gh*) ;; *) exit 0 ;; esac

command -v jq >/dev/null 2>&1 || exit 0

command=$(jq -r '.tool_input.command // empty' <<<"$payload")

case "$command" in
  # Exempt only the full fixed path (the form the Bash allowlist and the
  # skills use), so a body that merely mentions "pr-review.sh" doesn't skip
  # enforcement. A body quoting the full path is an accepted blind spot.
  *.claude/scripts/pr-review.sh*) exit 0 ;;
  *gh*) ;;
  *) exit 0 ;;
esac

# seg = the command from its first "gh" onward. Flag and body-file parsing
# runs on this slice so tokens of earlier commands in a compound
# (`grep -R TODO . && gh pr comment ...`) can't be mistaken for gh's flags.
pre=${command%%gh*}
seg=${command:${#pre}}

# Does this command post content? Matched anywhere in the string so compound
# commands (`cd x && gh pr comment ...`) are caught too, and with room for a
# few tokens between gh and the subcommand because gh accepts flags there
# (`gh -R owner/repo pr comment ...`). Review only counts with a body flag;
# `gh api` only when it sends a body field.
if grep -qE '\bgh +([^ ]+ +){0,4}(issue +(create|comment)|pr +(create|comment))\b' <<<"$command"; then
  :
elif grep -qE '\bgh +([^ ]+ +){0,4}pr +review\b' <<<"$command" &&
     grep -qE '(^|[[:space:]])(-b|--body|--body-file|-F)([= ]|$)' <<<"$seg"; then
  :
elif grep -qE '\bgh +([^ ]+ +){0,4}api\b' <<<"$command" &&
     grep -qE -- "(-f|-F|--field|--raw-field)[= ]['\"]?body(\[\])?=" <<<"$seg"; then
  :
else
  exit 0
fi

# Help invocations post nothing. Strip quoted spans first so body text that
# merely mentions --help (`--body "try gh pr review --help"`) can't disable
# enforcement, and scan only the gh segment so an earlier command's --help in
# a compound doesn't count either.
help_stripped=$(sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' <<<"$seg")
grep -qE '(^|[[:space:]])(--help|-h)([[:space:]]|$)' <<<"$help_stripped" && exit 0

cwd=$(jq -r '.cwd // empty' <<<"$payload")

# A leading `cd <dir> && ...` moves where gh actually runs; honor it for the
# origin lookup and relative body-file paths. Anything fancier (cd mid-command,
# subshells) falls back to the session cwd — wrong in rare compounds, but the
# failure is a recoverable deny or a skipped backstop, never a bad post.
case "$command" in
  cd\ *)
    cd_target=${command#cd }
    cd_target=${cd_target%%[;&|]*}
    cd_target="${cd_target%"${cd_target##*[![:space:]]}"}"
    cd_target=${cd_target//[\"\']/}
    # shellcheck disable=SC2088 # matching a literal ~ in the command text to expand it ourselves
    case "$cd_target" in
      '~')   cd_target=$HOME ;;
      '~/'*) cd_target="$HOME${cd_target#\~}" ;;
    esac
    if [[ -d "$cd_target" ]]; then cwd=$cd_target; fi
  ;;
esac

# Scope check: enforce only for github.com/yuryu. An explicit --repo/-R flag
# wins (gh accepts --repo VALUE, --repo=VALUE, -R VALUE, and -RVALUE);
# otherwise gh infers the repo from the working tree, so derive it from the
# origin remote the same way pr-review.sh's derive_repo() does (the parsing
# below is deliberately kept in sync with it).
owner='' host=''
repo_arg=$(grep -oE -- '--repo[= ][^ ]+|-R[= ]?[^ ]+' <<<"$seg" | head -n1) || true
if [[ -n "$repo_arg" ]]; then
  repo_arg=${repo_arg#--repo}; repo_arg=${repo_arg#-R}; repo_arg=${repo_arg#[= ]}
  repo_arg=${repo_arg//[\"\']/}
  repo_arg=${repo_arg#https://}; repo_arg=${repo_arg#http://}
  if [[ "$repo_arg" == */*/* ]]; then
    host=${repo_arg%%/*}; repo_arg=${repo_arg#*/}
  else
    host='github.com'   # bare OWNER/REPO targets github.com
  fi
  owner=${repo_arg%%/*}
else
  origin=$(git -C "$cwd" remote get-url origin 2>/dev/null) || exit 0
  # Anchored host forms only, so evil-github.com / github.com.evil can't pass.
  case "$origin" in
    git@github.com:*|ssh://git@github.com/*|https://github.com/*|http://github.com/*) host='github.com' ;;
    *) exit 0 ;;
  esac
  path=${origin%.git}; path=${path%/}
  if [[ "$path" =~ [:/]([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
  else
    exit 0
  fi
fi
[[ "$host" == 'github.com' && "$owner" == "$ALLOWED_OWNER" ]] || exit 0

# Auditable = the scan provably covered the whole command, so an "allow" can't
# smuggle anything past the permission system. Every rejection here is cheap:
# the command just falls back to the normal permission prompt.
is_auditable() {
  # The gh invocation must be the entire command — no cd/env-var prefix, no
  # pipeline feeding it (so cwd is the session cwd and there is one command).
  [[ "$pre" =~ ^[[:space:]]*$ ]] || return 1
  # No expansions anywhere, quoted or not: $(...) and `...` execute code, and
  # even $VAR could hide flags the scan never saw.
  case "$command" in
    *'$'*|*'`'*) return 1 ;;
  esac
  # No embedded newlines: heredoc bodies are multi-line, and the quote
  # stripping below runs line-by-line, so multi-line commands can't be
  # audited reliably. Multi-line bodies belong in --body-file.
  case "$command" in
    *$'\n'*) return 1 ;;
  esac
  # gh api requests are too loose to audit (arbitrary endpoint + field soup).
  grep -qE '\bgh +([^ ]+ +){0,4}api\b' <<<"$command" && return 1
  # Strip quoted spans, then reject any remaining shell metacharacter — or a
  # leftover quote or backslash, either of which means the quoting didn't
  # parse cleanly (e.g. a \" escape inside a double-quoted body makes the
  # stripper pair quotes wrongly) and the strip can't be trusted.
  local stripped
  stripped=$(sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' <<<"$command")
  case "$stripped" in
    *\;*|*\&*|*\|*|*\<*|*\>*|*\'*|*\"*|*\\*) return 1 ;;
  esac
  return 0
}

# Called on the compliant paths: auto-approve if auditable, otherwise stay
# silent so the normal permission flow decides.
allow_or_pass() {
  if is_auditable; then
    jq -n --arg r "gh post to a github.com/$ALLOWED_OWNER repo with the attribution footer, in auditable form" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: $r}}'
  fi
  exit 0
}

# Footer present in the inline body value itself? Only a parsed --body/-b
# argument (or a body file, below) can auto-approve — a marker anywhere else
# in the invocation (a --title, a filename) must not count as compliance.
body_arg=$(grep -oE -- "(^|[[:space:]])(--body|-b)[= ](\"[^\"]*\"|'[^']*'|[^[:space:]]+)" <<<"$seg" | head -n1) || true
if [[ -n "$body_arg" ]] && grep -qE "$MARKER_RE" <<<"$body_arg"; then
  allow_or_pass
fi
# Marker elsewhere in the gh invocation: a heredoc body, a gh api body field,
# quoting the extraction above couldn't parse — but also a title that merely
# mentions it. Compliant and decorative markers are indistinguishable here, so
# never auto-approve, and don't deny either (a legitimate heredoc footer would
# hit an infinite deny loop). Fall through to the normal permission prompt.
grep -qE "$MARKER_RE" <<<"$seg" && exit 0
# A body piped INTO gh (`printf '...' | gh pr comment --body-file -`)
# legitimately carries the footer before gh. Never auditable (pre is non-empty
# by definition), so it too falls to the normal prompt.
pre_trimmed="${pre%"${pre##*[![:space:]]}"}"
if [[ "$pre_trimmed" == *'|' ]]; then
  grep -qE "$MARKER_RE" <<<"$pre" && exit 0
fi

# Footer present in a body file? Covers `--body-file <path>`, the `-F <path>`
# shorthand of issue/pr comment (quoted paths may contain spaces), and
# `gh api -f body=@<path>` (checked first so an earlier unrelated -F field
# can't shadow it). "-" means stdin: pipe/heredoc text already checked above.
body_file=$(grep -oE -- 'body(\[\])?=@("[^"]*"|[^ ]+)' <<<"$seg" | head -n1) || true
if [[ -z "$body_file" ]]; then
  body_file=$(grep -oE -- "(--body-file|-F)[= ](\"[^\"]*\"|'[^']*'|[^ ]+)" <<<"$seg" | head -n1) || true
fi
if [[ -n "$body_file" ]]; then
  body_file=${body_file#--body-file}; body_file=${body_file#-F}; body_file=${body_file#[= ]}
  body_file=${body_file#*=@}
  body_file=${body_file//[\"\']/}
  if [[ "$body_file" != '-' ]]; then
    [[ "$body_file" == /* ]] || body_file="$cwd/$body_file"
    if [[ -r "$body_file" ]] && grep -qE "$MARKER_RE" "$body_file"; then
      allow_or_pass
    fi
  fi
fi

jq -n --arg r "This gh command posts to a github.com/$ALLOWED_OWNER repo without the required attribution footer. Append this as the final line of the body and rerun: $FOOTER" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
