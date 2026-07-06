#!/bin/bash
# pr-review.sh — single audited entry point for the GitHub operations used by
# the review-feedback and review-sweep skills, so the Bash allowlist can cover
# one script instead of open-ended `gh api` invocations.
#
# Safety properties (written for unattended / auto-mode runs):
#   - The target repo is derived from the working tree's `origin` remote; no
#     caller-supplied owner/repo ever reaches gh. Every gh call pins --repo
#     explicitly, so gh's own remote inference (which can resolve to a fork)
#     is never trusted.
#   - The derived repo must live under github.com/yuryu (ALLOWED_OWNER), so
#     the script cannot operate on anyone else's repository at all.
#   - This script lives at ~/.claude/scripts/pr-review.sh — a fixed path
#     outside any repository — so a checked-out PR branch cannot shadow or
#     tamper with it. The Bash allowlist trusts this path.
#   - Every argument is validated against a strict pattern before use.
#   - Comment/reply bodies are read from stdin and the "*— written by Claude*"
#     attribution line is appended automatically (never forgotten, never doubled).
#   - `push` refuses main/master and the repo's actual default branch, requires
#     the commit to exist locally, and never force-pushes (a non-fast-forward
#     is rejected by the server).
#   - There is deliberately no merge, close, branch-delete, or force subcommand.
#
# Usage: ~/.claude/scripts/pr-review.sh <subcommand> [args]
#        (run from inside a clone of the target repo)
set -euo pipefail

ATTRIBUTION='*— written by Claude*'

# Every subcommand (read or write) refuses to run unless origin points at a
# repo under this owner on github.com. This bounds the blast radius of every
# write to repos the user owns — notably `resolve`, whose GraphQL thread IDs
# are global and could otherwise touch any repo the token can reach.
ALLOWED_OWNER='yuryu'

# Bot logins differ per API surface. The patterns are fully anchored so a
# registrable look-alike login (e.g. "chatgpt-codex-connector2") can't be
# mistaken for a bot and have its text treated as trusted review feedback.
#   gh pr view reviews / GraphQL threads: chatgpt-codex-connector, copilot-pull-request-reviewer
#   REST inline comments:                 chatgpt-codex-connector[bot], Copilot
# (reviews and GraphQL threads share one login set, so one constant serves both).
BOTS_GRAPHQL='^(chatgpt-codex-connector|copilot-pull-request-reviewer)$'
BOTS_REST='^(Copilot|chatgpt-codex-connector\[bot\])$'

usage() {
  cat <<'EOF'
Usage: ~/.claude/scripts/pr-review.sh <subcommand> [args]
       (run from inside a clone; targets the repo `origin` points to,
        which must be under github.com/yuryu)

Read-only:
  current-pr                     PR number of the current branch
  candidates                     open PRs that have unresolved bot review threads
  summaries <pr>                 latest summary review per bot
  comments <pr>                  top-level inline bot comments (paginated)
  threads <pr> [--bots]          unresolved review threads (--bots: bot-opened only)
  runs <branch>                  recent workflow runs for a branch

Writes (each one guarded):
  reply <pr> <comment-id>        reply to an inline comment; body on stdin
  pr-comment <pr>                comment on the PR; body on stdin
  resolve <thread-id>            resolve one review thread
  request-copilot <pr>           re-request a Copilot review
  push <branch> [<sha>]          push sha (default HEAD) to origin/<branch>;
                                 refuses the default branch, never force-pushes
  rerun-failed <run-id>          rerun the failed jobs of a workflow run

Bodies passed on stdin get the attribution line appended automatically.
EOF
}

die() { echo "pr-review.sh: $*" >&2; exit 1; }

# jq is a hard dependency (candidates/summaries/comments/threads filter with
# it; gh's --jq can't take --arg). Fail fast with a clear message instead of
# letting a subcommand die mid-pipeline on a stock machine without jq.
command -v jq >/dev/null || die "jq is required but not installed (e.g. 'brew install jq')"

# Derive owner/repo from the `origin` remote of the current working tree.
# This is the ONLY source of the target repo: not an argument, not an env
# var, not gh's inference — so a prompt-injected "run this against repo X"
# can't redirect a write. Handles scp-like (git@host:owner/repo.git) and
# URL (https://host/owner/repo[.git]) forms.
derive_repo() {
  local origin_url repo_path
  origin_url=$(git remote get-url origin 2>/dev/null) \
    || die "no 'origin' remote — run from inside a clone of the target repo"
  repo_path="${origin_url%.git}"
  repo_path="${repo_path%/}"
  if [[ "$repo_path" =~ [:/]([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$ ]]; then
    REPO_OWNER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
  else
    die "cannot parse owner/repo from origin URL '$origin_url'"
  fi
  REPO="$REPO_OWNER/$REPO_NAME"
  # Match the host exactly (anchored forms only), so e.g. evil-github.com or
  # github.com.evil.example can't pass; then pin the owner.
  case "$origin_url" in
    git@github.com:*|ssh://git@github.com/*|https://github.com/*|http://github.com/*) ;;
    *) die "origin '$origin_url' is not on github.com — refusing" ;;
  esac
  [[ "$REPO_OWNER" == "$ALLOWED_OWNER" ]] \
    || die "origin repo $REPO is not under github.com/$ALLOWED_OWNER — refusing"
}

require_pr() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || die "expected a numeric PR number, got '${1:-}'"
}

# Read a comment body from stdin, reject empty input, append attribution.
read_body() {
  local body
  body=$(cat)
  [[ -n "${body//[[:space:]]/}" ]] || die 'empty body on stdin'
  # Suffix match, not "contains": a body that merely quotes an earlier reply's
  # attribution line mid-text still needs its own trailing one. $(cat) has
  # already stripped trailing newlines, so *"$ATTRIBUTION" means "ends with it".
  if [[ "$body" == *"$ATTRIBUTION" ]]; then
    printf '%s\n' "$body"
  else
    printf '%s\n\n%s\n' "$body" "$ATTRIBUTION"
  fi
}

# Stream of {id, commentId, author} for every unresolved review thread of a PR.
# --paginate + pageInfo walks past the first 100 threads (resolved ones occupy
# the window too, so a long-lived PR's newest unresolved threads can sit beyond
# it). author is null for a deleted account; callers guard test() with `// ""`.
unresolved_threads() {
  gh api graphql --paginate \
    -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F pr="$1" -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
        reviewThreads(first:100, after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{
            id isResolved comments(first:1){ nodes{ databaseId author{login} } } } } } } }' \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]
          | select(.isResolved | not)
          | {id, commentId: .comments.nodes[0].databaseId,
             author: .comments.nodes[0].author.login}'
}

cmd_current_pr() {
  # Resolve against the origin-derived repo, never gh's remote inference: in a
  # clone whose default gh repo is a fork, `gh pr view` could return a PR
  # number from that other repo, which every write subcommand would then
  # apply to "$REPO". Prefer the upstream branch name (worktrees often use
  # a local name that differs from the head branch), else the local name.
  local branch num
  branch=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  branch="${branch#*/}"
  [[ -n "$branch" ]] || branch=$(git rev-parse --abbrev-ref HEAD)
  [[ "$branch" != HEAD ]] || die 'detached HEAD: pass a PR number explicitly'
  num=$(gh pr list --repo "$REPO" --state open --head "$branch" \
          --json number --jq '.[0].number // empty')
  [[ -n "$num" ]] || die "no open PR in $REPO with head branch '$branch'"
  printf '%s\n' "$num"
}

cmd_candidates() {
  local prs num count
  prs=$(gh pr list --repo "$REPO" --state open --json number,headRefName,title)
  # Iterate PR numbers only (integers — no shell-quoting hazard); branch and
  # title are pulled from $prs by jq at emit time, so a title containing a tab
  # or backslash can't be mangled by an @tsv/read round-trip.
  while read -r num; do
    [[ -n "$num" ]] || continue
    # `// ""` keeps a deleted-account (null) author from crashing test(); the
    # `|| continue` isolates a single PR's failure (transient gh/GraphQL error)
    # so it can't abort the whole sweep after partial output.
    count=$(unresolved_threads "$num" \
      | jq -s --arg bots "$BOTS_GRAPHQL" '[.[] | select((.author // "") | test($bots))] | length') \
      || { printf 'pr-review.sh: warning: skipping PR %s (thread query failed)\n' "$num" >&2; continue; }
    if (( count > 0 )); then
      jq -n --argjson prs "$prs" --argjson number "$num" --argjson count "$count" \
            '$prs[] | select(.number == $number)
             | {number, headBranch: .headRefName, title, unresolvedBotThreads: $count}'
    fi
  done < <(jq -r '.[].number' <<<"$prs")
}

cmd_summaries() {
  require_pr "${1:-}"
  # Pass the pattern via --arg (gh's --jq can't take --arg), which also lets the
  # regex hold `\[...\]` safely, and null-guard the author of a deleted account.
  gh pr view "$1" --repo "$REPO" --json reviews \
    | jq --arg bots "$BOTS_GRAPHQL" \
        '[.reviews[] | select((.author.login // "") | test($bots))]
         | group_by(.author.login) | map(last | {author: .author.login, body})'
}

cmd_comments() {
  require_pr "${1:-}"
  # --paginate, or comments past the first 30 are silently missed; gh's per-page
  # `--jq '.[]'` emits one comment object per line, then a second jq filters via
  # --arg (so BOTS_REST's `\[bot\]` isn't mangled) and null-guards a deleted user.
  gh api --paginate "repos/$REPO/pulls/$1/comments" --jq '.[]' \
    | jq -c --arg bots "$BOTS_REST" \
        'select(((.user.login // "") | test($bots)) and .in_reply_to_id == null)
         | {id, author: .user.login, path, line, body}'
}

cmd_threads() {
  require_pr "${1:-}"
  case "${2:-}" in
    --bots) unresolved_threads "$1" | jq --arg bots "$BOTS_GRAPHQL" 'select((.author // "") | test($bots))' ;;
    '')     unresolved_threads "$1" ;;
    *)      die "unknown flag '${2}' (only --bots is supported)" ;;
  esac
}

cmd_reply() {
  require_pr "${1:-}"
  [[ "${2:-}" =~ ^[0-9]+$ ]] || die "expected a numeric comment id, got '${2:-}'"
  local body
  body=$(read_body)  # separate assignment so a read_body failure aborts (set -e)
  gh api "repos/$REPO/pulls/$1/comments/$2/replies" -f body="$body"
}

cmd_pr_comment() {
  require_pr "${1:-}"
  local body
  body=$(read_body)
  gh pr comment "$1" --repo "$REPO" --body "$body"
}

cmd_resolve() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_=+/-]+$ ]] || die "malformed thread id '${1:-}'"
  gh api graphql -f id="$1" -f query='
    mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }'
}

cmd_request_copilot() {
  require_pr "${1:-}"
  # The [bot] suffix is required; the bare login is rejected with HTTP 422.
  gh api "repos/$REPO/pulls/$1/requested_reviewers" \
    -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
}

cmd_push() {
  local branch="${1:-}" sha="${2:-HEAD}" default_branch
  [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "malformed branch name '$branch'"
  # Ask GitHub for the real default branch rather than assuming main/master;
  # if the lookup fails, set -e aborts the push (fail closed, never open).
  default_branch=$(gh repo view "$REPO" --json defaultBranchRef \
                     --jq '.defaultBranchRef.name')
  case "$branch" in
    main|master|"$default_branch") die "refusing to push to $branch" ;;
  esac
  [[ "$sha" == 'HEAD' || "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "expected HEAD or a commit sha, got '$sha'"
  git rev-parse --verify --quiet "$sha^{commit}" >/dev/null || die "commit '$sha' not found locally"
  # Plain push: the server rejects a non-fast-forward, which means the branch
  # moved underneath us — re-fetch and redo the work, never force-push.
  git push origin "$sha:refs/heads/$branch"
}

cmd_runs() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "malformed branch name '${1:-}'"
  gh run list --repo "$REPO" --branch "$1" --limit 5
}

cmd_rerun_failed() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || die "expected a numeric run id, got '${1:-}'"
  gh run rerun "$1" --repo "$REPO" --failed
}

cmd="${1:-}"
shift || true
case "$cmd" in
  -h|--help|help) usage; exit 0 ;;
  '')             usage; exit 1 ;;
esac
derive_repo
case "$cmd" in
  current-pr)      cmd_current_pr "$@" ;;
  candidates)      cmd_candidates "$@" ;;
  summaries)       cmd_summaries "$@" ;;
  comments)        cmd_comments "$@" ;;
  threads)         cmd_threads "$@" ;;
  runs)            cmd_runs "$@" ;;
  reply)           cmd_reply "$@" ;;
  pr-comment)      cmd_pr_comment "$@" ;;
  resolve)         cmd_resolve "$@" ;;
  request-copilot) cmd_request_copilot "$@" ;;
  push)            cmd_push "$@" ;;
  rerun-failed)    cmd_rerun_failed "$@" ;;
  *) usage >&2; die "unknown subcommand '$cmd'" ;;
esac
