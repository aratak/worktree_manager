#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.config/create_worktree"
CONFIG_PATH="$CONFIG_DIR/config.json"

CLAUDE_PROJECTS="$HOME/.claude/projects"

# Encode a filesystem path the way Claude Code names its project dirs.
encode_path() {
  echo "$1" | sed 's|^/||; s|/|-|g; s|_|-|g; s|^|-|'
}

usage() {
  cat <<'EOF'
Usage:
  wt <name>                   branch: <name>,          dir: ../<name>
  wt <prefix> <name>          branch: <prefix>/<name>, dir: ../<name>

  Creates a git worktree, links Claude memory from the current project,
  forks the current Claude session, and opens a new iTerm2 tab with
  Claude running in the new worktree.

  wt list                     list worktrees (branch + path)
  wt remove <name>            remove worktree, its branch, and Claude project dir

Options:
  --create-config   Create default config at ~/.config/create_worktree/config.json
  --edit-config     Open config in $EDITOR (creates it first if missing)
  --help            Show this help

Config (~/.config/create_worktree/config.json):
  command   Claude binary to run (default: "claude")
  args      Extra arguments passed to claude (default: [])
  env       Extra environment variables (default: {})
EOF
  exit 0
}

ensure_config() {
  if [ ! -f "$CONFIG_PATH" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_PATH" <<'EOF'
{
  "command": "claude",
  "args": [],
  "env": {}
}
EOF
    echo "created: $CONFIG_PATH"
  fi
}

cmd_list() {
  local cwd
  cwd=$(git rev-parse --show-toplevel 2>/dev/null || true)
  git worktree list --porcelain | awk -v cwd="$cwd" '
    function flush() {
      if (path == "") return
      label = branch
      if (bare)          label = "(bare)"
      else if (detached) label = "(detached)"
      mark = (path == cwd) ? "*" : " "
      printf "%s %-30s %s\n", mark, label, path
    }
    /^worktree /  { flush(); path = substr($0, 10); branch = ""; bare = 0; detached = 0 }
    /^branch /    { branch = $2; sub(/^refs\/heads\//, "", branch) }
    /^bare$/      { bare = 1 }
    /^detached$/  { detached = 1 }
    END { flush() }
  '
}

cmd_remove() {
  local name="${1:-}"
  [ -n "$name" ] || usage

  local dir_name="${name//\//-}"
  local repo_root target
  repo_root=$(git rev-parse --show-toplevel)
  target="$(dirname "$repo_root")/$dir_name"

  # Resolve the worktree's branch from porcelain output; empty if not a worktree.
  local branch
  branch=$(git worktree list --porcelain | awk -v t="$target" '
    /^worktree / { p = substr($0, 10) }
    /^branch /   { if (p == t) { b = $2; sub(/^refs\/heads\//, "", b); print b } }
  ')

  if ! git worktree list --porcelain | grep -qxF "worktree $target"; then
    echo "error: no worktree at $target" >&2
    exit 1
  fi

  if [ "$target" = "$repo_root" ]; then
    echo "error: refusing to remove the current worktree ($target)" >&2
    exit 1
  fi

  if ! git worktree remove "$target"; then
    echo "hint: worktree has changes; commit/stash them or run: git worktree remove --force '$target'" >&2
    exit 1
  fi
  echo "worktree: removed $target"

  if [ -n "$branch" ]; then
    if git branch -d "$branch" 2>/dev/null; then
      echo "branch: deleted $branch"
    else
      echo "branch: kept $branch (not fully merged); delete with: git branch -D '$branch'" >&2
    fi
  fi

  local project_dir="$CLAUDE_PROJECTS/$(encode_path "$target")"
  if [ -d "$project_dir" ]; then
    rm -rf "$project_dir"
    echo "claude: project dir removed"
  fi
}

case "${1:-}" in
  --help) usage ;;
  list) cmd_list; exit 0 ;;
  remove|rm) shift; cmd_remove "${1:-}"; exit 0 ;;
  --create-config)
    if [ -f "$CONFIG_PATH" ]; then
      echo "config already exists: $CONFIG_PATH"
    else
      ensure_config
    fi
    exit 0
    ;;
  --edit-config)
    ensure_config
    "${EDITOR:-vi}" "$CONFIG_PATH"
    exit 0
    ;;
esac

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

claude_projects="$CLAUDE_PROJECTS"
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

# Copy current session so the fork can find it. Only resume if the copy
# succeeds — a freshly started session may not be flushed to disk yet, in
# which case we start clean instead of pointing claude at a missing file.
session_id="${CLAUDE_CODE_SESSION_ID:-}"
fork_ready=false
if [ -z "$session_id" ]; then
  echo "claude: no active session to fork (CLAUDE_CODE_SESSION_ID not set)" >&2
elif [ ! -f "$old_project/$session_id.jsonl" ]; then
  echo "claude: session $session_id not on disk yet; starting fresh (no fork)" >&2
else
  cp "$old_project/$session_id.jsonl" "$new_project/$session_id.jsonl"
  echo "claude: session $session_id copied"
  fork_ready=true
fi

# ── Config ───────────────────────────────────────────────────────────────────

config_file="$CONFIG_PATH"
claude_cmd="claude"
claude_args=""
claude_env=""

if [ -f "$config_file" ]; then
  claude_cmd=$(jq -r '.command // "claude"' "$config_file")
  claude_args=$(jq -r '(.args // []) | join(" ")' "$config_file")
  claude_env=$(jq -r '(.env // {}) | to_entries | map("\(.key)=\(.value)") | join(" ")' "$config_file")
fi

# ── Open new iTerm2 tab ───────────────────────────────────────────────────────

env_prefix=""
[ -n "$claude_env" ] && env_prefix="env $claude_env "

if [ "$fork_ready" = true ]; then
  cmd="cd '$new_path' && ${env_prefix}${claude_cmd} ${claude_args} --resume '$session_id' --fork-session"
else
  cmd="cd '$new_path' && ${env_prefix}${claude_cmd} ${claude_args}"
fi
cmd="${cmd%% }"

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
