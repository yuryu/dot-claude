#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"

mkdir -p "${CLAUDE_DIR}"

link() {
  local name="$1"
  local dst_name="${2:-$1}"
  local src="${REPO_DIR}/${name}"
  local dst="${CLAUDE_DIR}/${dst_name}"

  if [ -L "${dst}" ]; then
    rm "${dst}"
  elif [ -e "${dst}" ]; then
    local bak="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    echo "warn: ${dst} exists; backing up to ${bak}"
    mv "${dst}" "${bak}"
  fi

  ln -s "${src}" "${dst}"
  echo "linked ${dst} -> ${src}"
}

link CLAUDE.global.md CLAUDE.md
link settings.json
link skills
link scripts

echo "done."
