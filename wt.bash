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
  local query="${1:-}"
  [ -n "$query" ] || usage

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)

  # If the query resolves to an existing directory, canonicalize it so a
  # relative path like ../foo can be matched against git's absolute paths.
  local query_path=""
  if [ -d "$query" ]; then
    query_path=$(cd "$query" 2>/dev/null && pwd -P) || query_path=""
  fi

  # Resolve the query through ordered fallbacks, mirroring what `wt list`
  # shows: branch name first, then directory basename, then filesystem path.
  # We can't derive the path from the name (`wt <prefix> <name>` makes branch
  # <prefix>/<name> but directory ../<name>), so look the worktree up instead.
  # Only the first tier with a hit is used; ambiguity within it is an error.
  local match
  match=$(git worktree list --porcelain | awk -v q="$query" -v qp="$query_path" '
    function base(s) { sub(/.*\//, "", s); return s }
    function emit() { if (wt != "") { paths[n] = wt; branches[n] = b; n++ } wt = "" }
    BEGIN { n = 0; m = 0 }
    /^worktree / { emit(); wt = substr($0, 10); b = "" }
    /^branch /   { b = $2; sub(/^refs\/heads\//, "", b) }
    /^$/         { emit() }
    END {
      emit()
      for (i = 0; i < n; i++) if (branches[i] == q)                       { print paths[i] "\t" branches[i]; m++ }
      if (m) exit
      for (i = 0; i < n; i++) if (base(paths[i]) == q)                    { print paths[i] "\t" branches[i]; m++ }
      if (m) exit
      for (i = 0; i < n; i++) if (paths[i] == q || (qp != "" && paths[i] == qp)) { print paths[i] "\t" branches[i]; m++ }
    }
  ')

  if [ -z "$match" ]; then
    echo "error: no worktree matching '$query' (use a branch, dir name, or path from: wt list)" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$match" | wc -l)" -gt 1 ]; then
    echo "error: '$query' matches multiple worktrees:" >&2
    printf '%s\n' "$match" | sed 's/\t/  →  /; s/^/  /' >&2
    exit 1
  fi

  local target branch
  target=${match%%$'\t'*}
  branch=${match#*$'\t'}

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

  # The forked history still records the old worktree everywhere (cwd fields,
  # absolute paths inside tool results). Claude's actual cwd is the new path,
  # but it will happily reach back into the old worktree when it recalls a path
  # from history. Append one meta turn that tells the resumed session it has
  # moved, so it operates in the new worktree instead of the source.
  copied="$new_project/$session_id.jsonl"
  tail_uuid=$(jq -rs '[.[] | select(.uuid)] | last | .uuid' "$copied")
  if [ -n "$tail_uuid" ] && [ "$tail_uuid" != "null" ]; then
    fork_version=$(jq -rs '[.[] | select(.version)] | last | .version // ""' "$copied")
    fork_slug=$(jq -rs '[.[] | select(.slug)] | last | .slug // ""' "$copied")
    fork_uuid=$(uuidgen | tr 'A-Z' 'a-z')
    fork_ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    fork_note="This session was forked into a new git worktree by the wt tool. The previous working directory was \"$repo_root\"; you are now in \"$new_path\" on branch \"$branch\". File paths earlier in this history point under the old worktree, but the same files now live under the new path. Work in the current worktree ($new_path) from here on and do not edit files in the old worktree."
    jq -nc \
      --arg parent "$tail_uuid" \
      --arg uuid "$fork_uuid" \
      --arg ts "$fork_ts" \
      --arg cwd "$new_path" \
      --arg sid "$session_id" \
      --arg ver "$fork_version" \
      --arg branch "$branch" \
      --arg slug "$fork_slug" \
      --arg text "$fork_note" \
      '{parentUuid:$parent, isSidechain:false, promptId:$uuid, type:"user", message:{role:"user", content:[{type:"text", text:$text}]}, isMeta:true, uuid:$uuid, timestamp:$ts, userType:"external", entrypoint:"cli", cwd:$cwd, sessionId:$sid, version:$ver, gitBranch:$branch, slug:$slug}' \
      >> "$copied"
    echo "claude: appended worktree-move note to forked session"
  fi
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
