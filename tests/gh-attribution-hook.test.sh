#!/bin/bash
# Tests for scripts/gh-attribution-hook.sh. Each case feeds the hook a
# PreToolUse payload and asserts the permission decision:
#   allow  — hook emitted permissionDecision "allow" (auto-approve)
#   deny   — hook emitted permissionDecision "deny"
#   silent — hook exited 0 with no output (normal permission flow decides)
# Run directly: tests/gh-attribution-hook.test.sh
set -u
HOOK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/gh-attribution-hook.sh
CWD=$(mktemp -d)
trap 'rm -rf "$CWD"' EXIT
git -C "$CWD" init -q
git -C "$CWD" remote add origin git@github.com:yuryu/testrepo.git

FOOTER='🤖 Generated with Claude Code'
BODYFILE_OK="$CWD/ok.md"
BODYFILE_BAD="$CWD/bad.md"
printf 'hello\n\n%s\n' "$FOOTER" > "$BODYFILE_OK"
printf 'hello no footer\n' > "$BODYFILE_BAD"

pass=0 fail=0
check() {
  local name=$1 expect=$2 cmd=$3
  local payload out rc decision
  payload=$(jq -n --arg c "$cmd" --arg w "$CWD" '{tool_input:{command:$c},cwd:$w}')
  out=$("$HOOK" <<<"$payload" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then decision="error(rc=$rc)"
  elif [[ -z "$out" ]]; then decision=silent
  else decision=$(jq -r '.hookSpecificOutput.permissionDecision // "unparseable"' <<<"$out")
  fi
  if [[ "$decision" == "$expect" ]]; then
    pass=$((pass+1)); echo "PASS: $name -> $decision"
  else
    fail=$((fail+1)); echo "FAIL: $name -> got $decision, want $expect"; echo "      cmd: $cmd"
  fi
}

# --- Marker outside the body must not count as compliance ---
check "marker in --title, unattributed --body" silent \
  "gh issue create --repo yuryu/testrepo --title \"Generated with Claude Code\" --body \"unattributed\""
check "marker in non-body flag value, unattributed body" silent \
  "gh issue create --repo yuryu/testrepo --body \"unattributed\" --milestone \"Generated with Claude Code\""

# --- --help inside a quoted body must not disable enforcement ---
check "--help inside quoted body, no footer" deny \
  "gh pr comment 1 --repo yuryu/testrepo --body \"try gh pr review --help\""
check "real help invocation stays silent" silent \
  "gh pr comment --help"
check "-h flag stays silent" silent \
  "gh issue create -h"

# --- Compliant forms ---
check "compliant inline body auto-approves" allow \
  "gh pr comment 1 --repo yuryu/testrepo --body \"looks good. $FOOTER\""
check "compliant --body= form auto-approves" allow \
  "gh issue comment 2 --repo yuryu/testrepo --body=\"done. $FOOTER\""
check "compliant body-file auto-approves" allow \
  "gh issue create --repo yuryu/testrepo --title \"t\" --body-file $BODYFILE_OK"
check "body-file without footer denies" deny \
  "gh issue create --repo yuryu/testrepo --title \"t\" --body-file $BODYFILE_BAD"
check "unattributed inline body denies" deny \
  "gh pr comment 1 --repo yuryu/testrepo --body \"thanks\""
check "compliant heredoc: silent (no deny loop, no auto-allow)" silent \
  "gh pr comment 1 --repo yuryu/testrepo --body-file - <<'EOF'
hello
$FOOTER
EOF"
check "compliant piped body: silent" silent \
  "printf 'hi\n$FOOTER' | gh pr comment 1 --repo yuryu/testrepo --body-file -"
check "compliant but compound: silent (prompt, not auto-allow)" silent \
  "cd $CWD && gh pr comment 1 --body \"ok $FOOTER\""
check "gh api with body field, marker present: silent" silent \
  "gh api repos/yuryu/testrepo/issues/1/comments -f body=\"x $FOOTER\""
check "gh api with body field, no marker: deny" deny \
  "gh api repos/yuryu/testrepo/issues/1/comments -f body=\"x\""

# --- Scope: out-of-scope stays silent ---
check "other owner stays silent" silent \
  "gh pr comment 1 --repo someoneelse/repo --body \"no footer\""
check "non-posting gh command stays silent" silent \
  "gh pr view 1 --repo yuryu/testrepo"
check "non-gh command stays silent" silent \
  "ls -la"
check "origin-derived repo denies without footer" deny \
  "gh pr comment 1 --body \"no footer\""
check "origin-derived repo allows with footer in body" allow \
  "gh pr comment 1 --body \"ok $FOOTER\""

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
