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

  Creates a git worktree and opens a new terminal tab/window with a
  fresh Claude session running in the new worktree. The terminal is
  auto-detected (or set "terminal" in the config); supported terminals
  are listed below.

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
  terminal  Terminal to open (default: "" = auto-detect). One of:
            iterm, appleterm, tmux, kitty, wezterm, gnome, konsole,
            alacritty, warp
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
  "env": {},
  "terminal": ""
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

# ── Config ───────────────────────────────────────────────────────────────────

config_file="$CONFIG_PATH"
claude_cmd="claude"
terminal=""
declare -a cfg_args=()
declare -a env_pairs=()

if [ -f "$config_file" ]; then
  claude_cmd=$(jq -r '.command // "claude"' "$config_file")
  terminal=$(jq -r '.terminal // ""' "$config_file")
  while IFS= read -r a;  do [ -n "$a" ]  && cfg_args+=("$a");   done < <(jq -r '(.args // [])[]' "$config_file")
  while IFS= read -r kv; do [ -n "$kv" ] && env_pairs+=("$kv"); done < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$config_file")
fi

# ── Command to run in the new terminal ───────────────────────────────────────
# This is the one logical command — "run claude in the new worktree" — that
# every backend below renders into its own dialect (an AppleScript string, a
# CLI argv, or a Warp YAML tab config). Keeping it as an argv array lets the
# CLI backends pass it verbatim and the string backends quote it themselves.

declare -a RUN_ARGV=()
[ ${#env_pairs[@]} -gt 0 ] && RUN_ARGV+=(env "${env_pairs[@]}")
RUN_ARGV+=("$claude_cmd")
[ ${#cfg_args[@]} -gt 0 ] && RUN_ARGV+=("${cfg_args[@]}")

# Single-quote for the shell. Ordinary input stays backslash-free, so the result
# also survives embedding inside an AppleScript string literal unchanged.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
shell_join() { local out= a; for a in "$@"; do out+="$(sq "$a") "; done; printf '%s' "${out% }"; }

# ── Terminal backends ─────────────────────────────────────────────────────────
# Each opens a new tab — or a new window, where the terminal has none — in the
# worktree directory and runs RUN_ARGV there. This is the only platform seam.

open_iterm() {
  local line="cd $(sq "$new_path") && $(shell_join "${RUN_ARGV[@]}")"
  osascript <<EOF
tell application "iTerm"
  activate
  tell current window
    create tab with default profile
    tell current session
      write text "$line"
    end tell
  end tell
end tell
EOF
}

open_appleterm() {
  # Terminal.app's AppleScript has no reliable "new tab"; do script opens a window.
  local line="cd $(sq "$new_path") && $(shell_join "${RUN_ARGV[@]}")"
  osascript <<EOF
tell application "Terminal"
  activate
  do script "$line"
end tell
EOF
}

open_tmux()   { tmux new-window -c "$new_path" "$(shell_join "${RUN_ARGV[@]}")"; }
open_kitty()  { kitty @ launch --type=tab --cwd "$new_path" "${RUN_ARGV[@]}"; }
open_wezterm(){ wezterm cli spawn --cwd "$new_path" -- "${RUN_ARGV[@]}"; }
open_gnome()  { gnome-terminal --tab --working-directory="$new_path" -- "${RUN_ARGV[@]}"; }
open_konsole(){ konsole --new-tab --workdir "$new_path" -e "${RUN_ARGV[@]}"; }
open_alacritty() {
  # Alacritty has no tabs; this opens a new window.
  alacritty --working-directory "$new_path" -e "${RUN_ARGV[@]}"
}

open_warp() {
  # Warp's new-tab URI cannot run a command; the only way to execute on open is
  # a named Tab Config (YAML) reached via warp://tab_config/<name>.
  local tab_dir name uri
  if [ "$(uname -s)" = "Darwin" ]; then
    tab_dir="$HOME/.warp/tab_configs"
  else
    tab_dir="${XDG_DATA_HOME:-$HOME/.local/share}/warp-terminal/tab_configs"
  fi
  mkdir -p "$tab_dir"
  name="wt-$dir_name"
  cat > "$tab_dir/$name.yaml" <<EOF
---
name: "$name"
directory: "$new_path"
commands:
  - "$(shell_join "${RUN_ARGV[@]}")"
EOF
  uri="warp://tab_config/$name"
  if [ "$(uname -s)" = "Darwin" ]; then open "$uri"; else xdg-open "$uri"; fi
}

# ── Pick and open the terminal ────────────────────────────────────────────────

detect_terminal() {
  [ -n "${TMUX:-}" ] && { echo tmux; return; }
  case "${TERM_PROGRAM:-}" in
    iTerm.app)      echo iterm;     return ;;
    Apple_Terminal) echo appleterm; return ;;
    WarpTerminal)   echo warp;      return ;;
    WezTerm)        echo wezterm;   return ;;
  esac
  [ -n "${KITTY_WINDOW_ID:-}" ] && { echo kitty;   return; }
  [ -n "${WEZTERM_PANE:-}" ]    && { echo wezterm; return; }
  [ -n "${KONSOLE_VERSION:-}" ] && { echo konsole; return; }
  { [ -n "${GNOME_TERMINAL_SCREEN:-}" ] || [ -n "${GNOME_TERMINAL_SERVICE:-}" ]; } && { echo gnome;     return; }
  { [ -n "${ALACRITTY_SOCKET:-}" ]      || [ -n "${ALACRITTY_WINDOW_ID:-}" ];     } && { echo alacritty; return; }
  echo ""
}

[ -z "$terminal" ] && terminal=$(detect_terminal)
if [ -z "$terminal" ]; then
  echo "error: could not detect your terminal. Set \"terminal\" in $CONFIG_PATH" >&2
  echo "       (one of: iterm, appleterm, tmux, kitty, wezterm, gnome, konsole, alacritty, warp)" >&2
  exit 1
fi

if [ "$(uname -s)" = "Linux" ] && [ "$terminal" != tmux ] \
   && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "error: no graphical display; only the tmux backend works headless." >&2
  echo "       Run inside tmux or set \"terminal\": \"tmux\" in $CONFIG_PATH." >&2
  exit 1
fi

case "$terminal" in
  iterm)     open_iterm ;;
  appleterm) open_appleterm ;;
  tmux)      open_tmux ;;
  kitty)     open_kitty ;;
  wezterm)   open_wezterm ;;
  gnome)     open_gnome ;;
  konsole)   open_konsole ;;
  alacritty) open_alacritty ;;
  warp)      open_warp ;;
  *) echo "error: unknown terminal '$terminal' (set a valid \"terminal\" in $CONFIG_PATH)" >&2; exit 1 ;;
esac

echo "done: opened $terminal → $new_path"
