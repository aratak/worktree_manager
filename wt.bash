#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: wt <branch-prefix> <name>  →  branch: <prefix>/<name>, dir: ../<name>"
  echo "       wt <name>                  →  branch: <name>,           dir: ../<name>"
  exit 1
}

[ $# -eq 0 ] || [ $# -gt 2 ] && usage

if [ $# -eq 2 ]; then
  branch="$1/$2"
  name="$2"
else
  branch="$1"
  name="$1"
fi

# Sanitize name for directory (replace / with -)
dir_name="${name//\//-}"

# ── Git ──────────────────────────────────────────────────────────────────────

repo_root=$(git rev-parse --show-toplevel)
new_path="$(dirname "$repo_root")/$dir_name"

branch_exists=$(git branch --list "$branch")

if [ -n "$branch_exists" ]; then
  if [ -e "$new_path" ]; then
    echo "worktree: already exists at $new_path (branch: $branch)"
  else
    git worktree add "$new_path" "$branch"
    echo "worktree: created $new_path from existing branch $branch"
  fi
else
  if [ -e "$new_path" ]; then
    echo "error: '$new_path' already exists but branch '$branch' does not" >&2
    exit 1
  fi
  git worktree add -b "$branch" "$new_path"
  git -C "$new_path" branch --unset-upstream 2>/dev/null || true
  echo "worktree: created $new_path (branch: $branch)"
fi

# ── Claude project setup ─────────────────────────────────────────────────────

encode_path() {
  echo "$1" | sed 's|^/||; s|/|-|g; s|_|-|g; s|^|-|'
}

claude_projects="$HOME/.claude/projects"
old_encoded=$(encode_path "$repo_root")
new_encoded=$(encode_path "$new_path")

old_project="$claude_projects/$old_encoded"
new_project="$claude_projects/$new_encoded"

mkdir -p "$new_project"

# Share memory between worktrees
if [ -d "$old_project/memory" ] && [ ! -e "$new_project/memory" ]; then
  ln -s "$old_project/memory" "$new_project/memory"
  echo "claude: memory linked from $old_encoded"
fi

# Copy current session so fork can find it
session_id="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$session_id" ] && [ -f "$old_project/$session_id.jsonl" ]; then
  cp "$old_project/$session_id.jsonl" "$new_project/$session_id.jsonl"
  echo "claude: session $session_id copied"
else
  echo "claude: no active session to fork (CLAUDE_CODE_SESSION_ID not set)" >&2
fi

# ── Open new iTerm2 tab ───────────────────────────────────────────────────────

if [ -n "$session_id" ]; then
  cmd="cd '$new_path' && claude --resume '$session_id' --fork-session"
else
  cmd="cd '$new_path' && claude"
fi

osascript <<EOF
tell application "iTerm"
  activate
  tell current window
    create tab with default profile
    tell current session
      write text "$cmd"
    end tell
  end tell
end tell
EOF

echo "done: opened new tab → $new_path"
