#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.config/create_worktree"
CONFIG_PATH="$CONFIG_DIR/config.json"
TABS_PATH="$CONFIG_DIR/tabs.json"
LOCK_DIR="$CONFIG_DIR/tabs.lock"
EMPTY_REGISTRY='{"v":1,"tabs":{}}'

CLAUDE_PROJECTS="$HOME/.claude/projects"

# Encode a filesystem path the way Claude Code names its project dirs.
encode_path() {
  echo "$1" | sed 's|^/||; s|/|-|g; s|_|-|g; s|^|-|'
}

# Single-quote for the shell. Ordinary input stays backslash-free, so the result
# also survives embedding inside an AppleScript string literal unchanged.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
shell_join() { local out= a; for a in "$@"; do out+="$(sq "$a") "; done; printf '%s' "${out% }"; }

usage() {
  cat <<'EOF'
Usage:
  wt <name>                   branch: <name>,          dir: ../<name>
  wt <prefix> <name>          branch: <prefix>/<name>, dir: ../<name>
  wt <prefix>/<name>          same branch as the two-argument form
  wt … -- <command…>          run <command…> in the new tab instead of claude
  wt … --create               create the worktree only, open no tab
  wt … --new-tab              always open a fresh tab
  wt … --tab <uid>            focus that tab instead of opening one

  Creates a git worktree and opens a new terminal tab/window in it. When the
  branch is already checked out somewhere, that worktree is reused and only
  the tab opens, so re-running wt on an existing worktree takes you back to
  it. By default the tab runs a fresh Claude session (the configured command
  and args); everything after -- replaces that command entirely (env from
  the config still applies). The terminal is auto-detected (or set
  "terminal" in the config); supported terminals are listed below.

  wt tracks every tab it opens and prints a uid for it. Re-running wt on a
  worktree that already has one of our tabs focuses that tab instead of
  opening a second one; with several open it lists them and asks which.
  Tabs you opened by hand are invisible to wt and are never touched.

  wt list | wt ls [--json]    list worktrees, with our live tabs under each
  wt close <name>             close our tabs in that worktree
  wt close --tab <uid>        close that one tab
  wt remove | wt rm <name>    close our tabs there, then remove the worktree,
                              its branch, and the Claude project dir
  wt rm --keep-tabs <name>    remove the worktree, leave the tabs running

Options:
  --create-config   Create default config at ~/.config/create_worktree/config.json
  --edit-config     Open config in $EDITOR (creates it first if missing)
  --help            Show this help

Exit codes:
  1  nothing matched the query
  2  that tab's terminal backend cannot close or focus tabs

Config (~/.config/create_worktree/config.json):
  command   Claude binary to run (default: "claude")
  args      Extra arguments passed to claude (default: []);
            command and args are ignored when -- <command…> is given
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

# ── Tab registry ─────────────────────────────────────────────────────────────
# wt tracks only the tabs it opened itself; a tab you opened by hand inside a
# worktree is invisible to wt and never touched. Resolving tabs by cwd could
# not tell ours from yours, which is why there is a registry at all. The rule
# that keeps it honest:
#
#   The registry says what is ours. The terminal says what is alive.
#
# Nothing here is trusted for liveness: every read verifies its rows against
# the live terminal (registry_sync), so a tab closed by hand, a restarted
# terminal or a reboot self-heal instead of accumulating stale rows.

REG="$EMPTY_REGISTRY"   # the verified registry, refreshed by registry_sync
TAB_UID=""              # uid of the row registry_add last wrote
CLOSED_COUNT=0          # tabs close_tabs actually closed

lock_held=false

lock_release() {
  [ "$lock_held" = true ] || return 0
  lock_held=false
  local owner
  owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ "$owner" = "$$" ]; then
    rm -rf "$LOCK_DIR" || true
  fi
  return 0
}

trap 'lock_release || true' EXIT

# macOS has no flock(1), so the lock is a mkdir. It guards only read → jq → mv:
# no osascript, no git and no prompt runs inside it, or a modal iTerm would
# leave every other wt spinning. Writes are atomic through temp-then-mv anyway;
# the lock is what stops two concurrent writers from losing each other's rows.
lock_acquire() {
  mkdir -p "$CONFIG_DIR"
  local waited=0 owner
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 100 ]; then
      echo "error: registry lock held for 5s; remove $LOCK_DIR if no other wt is running" >&2
      exit 1
    fi
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$LOCK_DIR" || true
    else
      sleep 0.05
    fi
  done
  echo "$$" > "$LOCK_DIR/pid"
  lock_held=true
}

# A missing, unreadable, corrupt or wrong-version file all read as empty: jq
# exits 2 on a missing file, and the first run has no registry at all.
registry_read() {
  jq -c 'if (.v == 1) and ((.tabs | type) == "object") then . else {v: 1, tabs: {}} end' \
    "$TABS_PATH" 2>/dev/null || printf '%s' "$EMPTY_REGISTRY"
}

registry_write() {
  local tmp
  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp "$CONFIG_DIR/tabs.json.XXXXXX")
  cat > "$tmp"
  mv "$tmp" "$TABS_PATH"
}

# Record a tab we just opened; sets TAB_UID. The uid is derived from the
# session's own handle instead of generated: $RANDOM is 16 bits seeded from pid
# and time, so two scripted launches in the same second realistically collide.
# Take the handle's first 4 hex digits and widen on collision — under the lock,
# so concurrent launches cannot settle on the same uid.
registry_add() {
  local backend="$1" native="$2" worktree="$3"
  local reg next hex n

  lock_acquire
  reg=$(registry_read)
  hex=$(printf '%s' "$native" | tr -dc '0-9A-Fa-f' | tr 'A-F' 'a-f')
  n=4
  TAB_UID="wt-${hex:0:4}"
  while [ "$(printf '%s' "$reg" | jq -r --arg u "$TAB_UID" '.tabs | has($u)')" = true ] \
     && [ "$n" -lt "${#hex}" ]; do
    n=$((n + 1))
    TAB_UID="wt-${hex:0:$n}"
  done
  next=$(printf '%s' "$reg" | jq -c \
    --arg u "$TAB_UID" --arg b "$backend" --arg n "$native" --arg w "$worktree" \
    '.tabs[$u] = {backend: $b, native: $n, worktree: $w}')
  printf '%s\n' "$next" | registry_write
  lock_release
}

# Forget rows, in the file and in REG alike.
registry_drop() {
  [ $# -gt 0 ] || return 0
  local reg next
  lock_acquire
  reg=$(registry_read)
  next=$(printf '%s' "$reg" | jq -c --args 'reduce $ARGS.positional[] as $u (.; del(.tabs[$u]))' "$@")
  printf '%s\n' "$next" | registry_write
  lock_release
  REG=$(printf '%s' "$REG" | jq -c --args 'reduce $ARGS.positional[] as $u (.; del(.tabs[$u]))' "$@")
}

# Refresh REG and drop every row reality disagrees with. Two rules: the
# worktree directory must still exist — which catches worktrees removed with a
# plain `git worktree remove`, in any repo, since the registry is global while
# `wt ls` only ever sees the current one — and the terminal must still know the
# session.
registry_sync() {
  REG=$(registry_read)

  local rows dead
  rows=$(printf '%s' "$REG" | jq -r \
    '.tabs | to_entries[] | [.key, .value.backend, .value.worktree, .value.native] | @tsv')
  [ -n "$rows" ] || return 0

  # Enumerate a terminal only when the registry holds rows for it: `tell
  # application "iTerm"` launches iTerm when it is closed, so an empty registry
  # must cost zero osascript calls.
  if printf '%s\n' "$rows" | awk -F'\t' '$2 == "iterm" { f = 1 } END { exit !f }'; then
    iterm_enum_load
  fi

  dead=$(printf '%s\n' "$rows" | while IFS=$'\t' read -r uid backend worktree native; do
    [ -n "$uid" ] || continue
    if [ ! -d "$worktree" ]; then
      printf '%s\n' "$uid"
    elif declare -f "alive_$backend" >/dev/null && ! "alive_$backend" "$native"; then
      printf '%s\n' "$uid"
    fi
  done)

  if [ -n "$dead" ]; then
    local -a gone=()
    while IFS= read -r uid; do
      [ -n "$uid" ] && gone+=("$uid")
    done <<EOF
$dead
EOF
    registry_drop "${gone[@]}"
  fi
}

# Our own session's handle, empty when we are not sitting in a tab wt opened.
# The ITERM_SESSION_ID prefix (w4t0p0:) goes stale the moment a tab is moved
# between windows, so only the GUID after it is comparable.
self_native() {
  local s="${ITERM_SESSION_ID:-}"
  printf '%s' "${s#*:}"
}

uids_for_worktree() {
  printf '%s' "$REG" | jq -r --arg w "$1" \
    '.tabs | to_entries[] | select(.value.worktree == $w) | .key'
}

# worktree \t uid \t job, for every verified row. The running command is not
# stored in the registry — iTerm reports it live as the session's "jobName" —
# so it is joined in here from the enumeration. bash 3.2 has no associative
# arrays, hence the two-input awk.
verified_rows() {
  awk -F'\t' '
    FNR == NR { if (NF) job[$1] = $2; next }
    NF        { print $2 "\t" $1 "\t" job[$3] }
  ' <(printf '%s\n' "$ITERM_ENUM") \
    <(printf '%s' "$REG" | jq -r '.tabs | to_entries[] | [.key, .value.worktree, .value.native] | @tsv') \
    | sort
}

print_tabs_for() {
  verified_rows | awk -F'\t' -v w="$1" '$1 == w { printf "  %-10s %s\n", $2, $3 }'
}

# ── Terminal backends ─────────────────────────────────────────────────────────
# open_<name> is the only required one: it opens a new tab — or a new window,
# where the terminal has none — in the worktree directory and runs RUN_ARGV
# there. Defining close_<name> opts the backend into close, focus and the tab
# listing; everything is checked with `declare -f`, never `type -t`, which also
# resolves executables on PATH. These live above the command dispatcher because
# `wt close` must find them before the main flow is ever reached.

open_iterm() {
  # Capture the new session's id here, at the one moment it is unambiguous:
  # nothing later can tell which of a window's sessions we just created.
  local line guid
  line="cd $(sq "$new_path") && $(shell_join "${RUN_ARGV[@]}")"
  if ! guid=$(osascript <<EOF
tell application "iTerm"
  activate
  if (count of windows) = 0 then
    set newSession to (current session of (create window with default profile))
  else
    tell current window
      set newTab to (create tab with default profile)
    end tell
    set newSession to (current session of newTab)
  end if
  tell newSession
    write text "$line"
  end tell
  return id of newSession
end tell
EOF
  ); then
    echo "error: iTerm refused to open a tab" >&2
    return 1
  fi
  registry_add iterm "$guid" "$new_path"
}

# GUID \t jobName \t path for every live session. The script takes no
# arguments on purpose: interpolating a path into AppleScript breaks on a " or
# a \, so bash does the matching instead.
list_iterm() {
  osascript <<'EOF'
set T9 to (ASCII character 9)
set NL to (ASCII character 10)
set out to {}
tell application "iTerm"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        try
          set sid to (id of s)
          tell s
            set jn to (variable named "jobName")
            set pp to (variable named "path")
          end tell
          set end of out to (sid & T9 & jn & T9 & pp)
        end try
      end repeat
    end repeat
  end repeat
end tell
set AppleScript's text item delimiters to NL
return out as text
EOF
}

# Deliberately select-free and without `activate`: closing must not yank the
# user's window forward, only focusing may.
# Dispatched by name (close_$backend and friends), which shellcheck cannot
# see — hence the disable.
# shellcheck disable=SC2329
close_iterm() {
  osascript - "$1" <<'EOF'
on run argv
  set target to item 1 of argv
  tell application "iTerm"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s) is target then
            close s
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
end run
EOF
}

# Dispatched by name (close_$backend and friends), which shellcheck cannot
# see — hence the disable.
# shellcheck disable=SC2329
focus_iterm() {
  osascript - "$1" <<'EOF'
on run argv
  set target to item 1 of argv
  tell application "iTerm"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s) is target then
            activate
            select t
            select s
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
end run
EOF
}

# Dispatched by name (close_$backend and friends), which shellcheck cannot
# see — hence the disable.
# shellcheck disable=SC2329
alive_iterm() {
  printf '%s\n' "$ITERM_ENUM" | awk -F'\t' -v want="$1" '$1 == want { f = 1 } END { exit !f }'
}

ITERM_ENUM=""
ITERM_ENUM_LOADED=false

# One enumeration per wt process, reused. It costs ~0.9s for ~20 live sessions
# — per call, not per session — so ten separate queries would take ten seconds
# and make `wt ls` feel broken. Upgrade path if that ever bites: filter inside
# AppleScript instead of returning everything.
iterm_enum_load() {
  [ "$ITERM_ENUM_LOADED" = false ] || return 0
  ITERM_ENUM_LOADED=true
  ITERM_ENUM=""

  [ "$(uname -s)" = Darwin ] || return 0
  # `running of application id …` is the form that does not launch iTerm.
  # pgrep -x iTerm2 does not match it, the executable being a full path.
  [ "$(osascript -e 'running of application id "com.googlecode.iterm2"' 2>/dev/null)" = true ] || return 0

  # Empty output means "no sessions" and "the query failed" alike, and the
  # error text is localized, so it cannot be matched on: branch on the exit
  # code and prune nothing when the query fails.
  if ! ITERM_ENUM=$(list_iterm); then
    echo "error: could not query iTerm (is Automation permission granted?)" >&2
    exit 1
  fi
}

open_appleterm() {
  # Terminal.app's AppleScript has no reliable "new tab"; do script opens a window.
  local line
  line="cd $(sq "$new_path") && $(shell_join "${RUN_ARGV[@]}")"
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

# ── Acting on tabs ────────────────────────────────────────────────────────────
# The backend always comes from the row, never from detect_terminal(): `wt
# close` run inside Terminal.app must still close an iTerm tab. Exit 2 means
# "this row's backend has no close_*", not "your terminal is unsupported".

# Close the given rows and forget them. Our own tab is skipped rather than
# refused: `wt close <name>` from inside one of N tabs should still close the
# other N-1. The caller decides whether skipping everything is an error.
close_tabs() {
  local uid backend native self
  local -a gone=()
  self=$(self_native)

  for uid in "$@"; do
    backend=$(printf '%s' "$REG" | jq -r --arg u "$uid" '.tabs[$u].backend')
    native=$(printf '%s' "$REG" | jq -r --arg u "$uid" '.tabs[$u].native')
    if [ -n "$self" ] && [ "$native" = "$self" ]; then
      echo "skipped $uid (this tab)"
      continue
    fi
    if ! declare -f "close_$backend" >/dev/null; then
      echo "error: the $backend backend cannot close tabs; close $uid by hand" >&2
      exit 2
    fi
    "close_$backend" "$native"
    echo "closed $uid"
    gone+=("$uid")
  done

  CLOSED_COUNT=${#gone[@]}
  if [ "$CLOSED_COUNT" -gt 0 ]; then
    registry_drop "${gone[@]}"
  fi
}

focus_tab() {
  local uid="$1" backend native self
  backend=$(printf '%s' "$REG" | jq -r --arg u "$uid" '.tabs[$u].backend // empty')
  if [ -z "$backend" ]; then
    echo "error: no live tab '$uid' (see: wt list)" >&2
    exit 1
  fi
  native=$(printf '%s' "$REG" | jq -r --arg u "$uid" '.tabs[$u].native')
  self=$(self_native)
  if [ -n "$self" ] && [ "$native" = "$self" ]; then
    echo "tab: $uid (already here)"
    return 0
  fi
  if ! declare -f "focus_$backend" >/dev/null; then
    echo "error: the $backend backend cannot focus tabs; switch to $uid by hand" >&2
    exit 2
  fi
  "focus_$backend" "$native"
  echo "tab: $uid (focused)"
}

# ── Worktrees ─────────────────────────────────────────────────────────────────

# Directory of the worktree checked out on <branch>, empty if none. The branch
# is the only stable handle we have: the directory cannot be derived from the
# arguments, since `wt <prefix> <name>` puts branch <prefix>/<name> in ../<name>
# while `wt <prefix>/<name>` would compute ../<prefix>-<name>.
worktree_for_branch() {
  git worktree list --porcelain | awk -v want="$1" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { b = $2; sub(/^refs\/heads\//, "", b); if (b == want) { print path; exit } }
  '
}

# Resolve a query to "<path>\t<branch>", or fail loudly. `close` and `remove`
# both name something that already exists, so both must resolve identically.
resolve_worktree() {
  local query="$1"

  # If the query resolves to an existing directory, canonicalize it so a
  # relative path like ../foo can be matched against git's absolute paths.
  local query_path=""
  if [ -d "$query" ]; then
    query_path=$(cd "$query" 2>/dev/null && pwd -P) || query_path=""
  fi

  # Ordered fallbacks, mirroring what `wt list` shows: branch name first, then
  # directory basename, then filesystem path. We can't derive the path from the
  # name (`wt <prefix> <name>` makes branch <prefix>/<name> but directory
  # ../<name>), so look the worktree up instead. Only the first tier with a hit
  # is used; ambiguity within it is an error.
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
  printf '%s\n' "$match"
}

# One positional is the query; two join into <prefix>/<name>, the same branch
# the two-argument open form builds.
join_query() {
  if [ "$#" -eq 2 ]; then
    printf '%s/%s' "$1" "$2"
  else
    printf '%s' "$1"
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_list() {
  local json=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=true ;;
      *) echo "error: unknown option '$1' for wt list" >&2; exit 1 ;;
    esac
    shift
  done

  registry_sync

  local cwd rows
  cwd=$(git rev-parse --show-toplevel 2>/dev/null || true)
  rows=$(verified_rows)

  if [ "$json" = true ]; then
    local worktrees tabs_json
    worktrees=$(git worktree list --porcelain | awk -v cwd="$cwd" '
      function flush() {
        if (path == "") return
        label = branch
        if (bare)          label = "(bare)"
        else if (detached) label = "(detached)"
        print path "\t" label "\t" ((path == cwd) ? 1 : 0)
      }
      /^worktree /  { flush(); path = substr($0, 10); branch = ""; bare = 0; detached = 0 }
      /^branch /    { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
      /^bare$/      { bare = 1 }
      /^detached$/  { detached = 1 }
      END { flush() }
    ')
    tabs_json=$(printf '%s\n' "$rows" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t")) | group_by(.[0])
      | map({key: .[0][0], value: map({uid: .[1], job: .[2]})}) | from_entries')
    printf '%s\n' "$worktrees" | jq -R -s --argjson tabs "$tabs_json" '
      split("\n") | map(select(length > 0) | split("\t"))
      | map({branch: .[1], path: .[0], current: (.[2] == "1"), tabs: ($tabs[.[0]] // [])})'
    return 0
  fi

  # Two inputs: the tabs first, then git's porcelain. bash 3.2 has no
  # associative arrays and no mapfile, so the grouping happens here.
  awk -F'\t' -v cwd="$cwd" '
    function flush() {
      if (path == "") return
      label = branch
      if (bare)          label = "(bare)"
      else if (detached) label = "(detached)"
      mark = (path == cwd) ? "*" : " "
      printf "%s %-30s %s\n", mark, label, path
      for (i = 1; i <= n[path]; i++) print tab[path SUBSEP i]
    }
    FNR == NR {
      if (NF) { n[$1]++; tab[$1 SUBSEP n[$1]] = sprintf("    %-10s %s", $2, $3) }
      next
    }
    /^worktree /  { flush(); path = substr($0, 10); branch = ""; bare = 0; detached = 0 }
    /^branch /    { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
    /^bare$/      { bare = 1 }
    /^detached$/  { detached = 1 }
    END { flush() }
  ' <(printf '%s\n' "$rows") <(git worktree list --porcelain)
}

cmd_close() {
  local want_uid=""
  local -a positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --tab)
        shift
        [ $# -gt 0 ] || { echo "error: --tab needs a uid (see: wt list)" >&2; exit 1; }
        want_uid="$1"
        ;;
      --tab=*) want_uid="${1#--tab=}" ;;
      -*) echo "error: unknown option '$1' for wt close" >&2; exit 1 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done

  registry_sync

  local -a uids=()
  if [ -n "$want_uid" ]; then
    [ ${#positional[@]} -eq 0 ] || { echo "error: --tab <uid> takes no other arguments" >&2; exit 1; }
    if [ "$(printf '%s' "$REG" | jq -r --arg u "$want_uid" '.tabs | has($u)')" != true ]; then
      echo "error: no live tab '$want_uid' (see: wt list)" >&2
      exit 1
    fi
    uids=("$want_uid")
  else
    { [ ${#positional[@]} -ge 1 ] && [ ${#positional[@]} -le 2 ]; } || usage
    local match target uid
    match=$(resolve_worktree "$(join_query "${positional[@]}")") || exit $?
    target=${match%%$'\t'*}
    while IFS= read -r uid; do
      [ -n "$uid" ] && uids+=("$uid")
    done < <(uids_for_worktree "$target")
    if [ ${#uids[@]} -eq 0 ]; then
      echo "close: no wt tabs in $target"
      return 0
    fi
  fi

  close_tabs "${uids[@]}"
  if [ "$CLOSED_COUNT" -eq 0 ]; then
    exit 1
  fi
}

cmd_remove() {
  local keep_tabs=false
  local -a positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-tabs) keep_tabs=true ;;
      -*) echo "error: unknown option '$1' for wt remove" >&2; exit 1 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  { [ ${#positional[@]} -ge 1 ] && [ ${#positional[@]} -le 2 ]; } || usage

  local repo_root match target branch
  repo_root=$(git rev-parse --show-toplevel)
  match=$(resolve_worktree "$(join_query "${positional[@]}")") || exit $?
  target=${match%%$'\t'*}
  branch=${match#*$'\t'}

  if [ "$target" = "$repo_root" ]; then
    echo "error: refusing to remove the current worktree ($target)" >&2
    exit 1
  fi

  # Close before `git worktree remove`, never after: a claude session whose cwd
  # is inside the removed directory does not crash, it silently keeps writing
  # to a path that no longer exists. The consequence to know: if the removal
  # then fails, the tabs are already closed.
  registry_sync
  local -a uids=()
  local uid
  while IFS= read -r uid; do
    [ -n "$uid" ] && uids+=("$uid")
  done < <(uids_for_worktree "$target")

  if [ ${#uids[@]} -gt 0 ]; then
    if [ "$keep_tabs" = true ]; then
      # The worktree is going away, so the tab relates to nothing wt manages
      # any more: drop the rows regardless. It keeps running, now
      # indistinguishable from a tab opened by hand — which is what
      # --keep-tabs asked for.
      registry_drop "${uids[@]}"
      echo "tabs: kept ${#uids[@]}, no longer tracked"
    else
      close_tabs "${uids[@]}"
    fi
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

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
  --help) usage ;;
  list|ls) shift; cmd_list "$@"; exit 0 ;;
  close) shift; cmd_close "$@"; exit 0 ;;
  remove|rm) shift; cmd_remove "$@"; exit 0 ;;
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

# ── Arguments ─────────────────────────────────────────────────────────────────
# A shift loop rather than `for arg in "$@"`, which cannot express an option
# that takes a value and silently turns an unknown --foo into a positional.

declare -a positional=()
declare -a tab_cmd=()
seen_ddash=false
create_only=false
new_tab=false
want_uid=""

while [ $# -gt 0 ]; do
  case "$1" in
    --)
      shift
      tab_cmd=("$@")
      seen_ddash=true
      break
      ;;
    --create)  create_only=true ;;
    --new-tab) new_tab=true ;;
    --tab)
      shift
      [ $# -gt 0 ] || { echo "error: --tab needs a uid (see: wt list)" >&2; exit 1; }
      want_uid="$1"
      ;;
    --tab=*) want_uid="${1#--tab=}" ;;
    -*) echo "error: unknown option '$1'" >&2; exit 1 ;;
    *) positional+=("$1") ;;
  esac
  shift
done

[ ${#positional[@]} -gt 2 ] && usage
if [ "$seen_ddash" = true ] && [ ${#tab_cmd[@]} -eq 0 ]; then
  echo "error: '--' given but no command follows it" >&2
  exit 1
fi
if [ "$create_only" = true ] && [ "$seen_ddash" = true ]; then
  echo "error: --create opens no tab, so there is nowhere to run '-- <command…>'" >&2
  exit 1
fi
if [ -n "$want_uid" ] && [ "$new_tab" = true ]; then
  echo "error: --tab focuses an existing tab, --new-tab opens another; pick one" >&2
  exit 1
fi
if [ -n "$want_uid" ] && [ "$seen_ddash" = true ]; then
  echo "error: --tab focuses a tab that is already running something" >&2
  exit 1
fi
if [ -n "$want_uid" ] && [ "$create_only" = true ]; then
  echo "error: --create opens no tab, so there is none to focus" >&2
  exit 1
fi

# A uid identifies a tab completely, so it needs no worktree and no repo.
if [ ${#positional[@]} -eq 0 ]; then
  [ -n "$want_uid" ] || usage
  registry_sync
  focus_tab "$want_uid"
  exit 0
fi

if [ ${#positional[@]} -eq 2 ]; then
  branch="${positional[0]}/${positional[1]}"
  name="${positional[1]}"
else
  branch="${positional[0]}"
  name="${positional[0]}"
fi

# Sanitize name for directory (replace / with -)
dir_name="${name//\//-}"

# ── Git ──────────────────────────────────────────────────────────────────────

repo_root=$(git rev-parse --show-toplevel)

# Reuse the worktree the branch already lives in rather than computing a
# directory for it. Both argument forms name the same branch, so this is what
# makes `wt <prefix>/<name>` land on the worktree `wt <prefix> <name>` made
# instead of asking git for a second checkout of a branch it already has.
existing=$(worktree_for_branch "$branch")

if [ -n "$existing" ]; then
  new_path="$existing"
  echo "worktree: exists at $new_path (branch: $branch)"
else
  new_path="$(dirname "$repo_root")/$dir_name"
  if [ -e "$new_path" ]; then
    echo "error: '$new_path' already exists but holds no worktree for branch '$branch'" >&2
    exit 1
  fi
  if [ -n "$(git branch --list "$branch")" ]; then
    git worktree add "$new_path" "$branch"
    echo "worktree: created $new_path from existing branch $branch"
  else
    git worktree add -b "$branch" "$new_path"
    git -C "$new_path" branch --unset-upstream 2>/dev/null || true
    echo "worktree: created $new_path (branch: $branch)"
  fi
fi

if [ "$create_only" = true ]; then
  exit 0
fi

# ── Tab: focus what is already there, open what is not ───────────────────────

if [ -n "$want_uid" ]; then
  registry_sync
  row_worktree=$(printf '%s' "$REG" | jq -r --arg u "$want_uid" '.tabs[$u].worktree // empty')
  if [ -z "$row_worktree" ]; then
    echo "error: no live tab '$want_uid' (see: wt list)" >&2
    exit 1
  fi
  if [ "$row_worktree" != "$new_path" ]; then
    echo "error: tab '$want_uid' is in $row_worktree, not $new_path" >&2
    exit 1
  fi
  focus_tab "$want_uid"
  exit 0
fi

if [ "$new_tab" = false ]; then
  registry_sync
  declare -a here=()
  while IFS= read -r uid; do
    [ -n "$uid" ] && here+=("$uid")
  done < <(uids_for_worktree "$new_path")

  if [ ${#here[@]} -eq 1 ]; then
    focus_tab "${here[0]}"
    exit 0
  fi
  if [ ${#here[@]} -gt 1 ]; then
    echo "tabs already open in $new_path:"
    print_tabs_for "$new_path"
    echo "error: pick one with --tab <uid>, or open another with --new-tab" >&2
    exit 1
  fi
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
# This is the one logical command — "run the session in the new worktree" — that
# every backend renders into its own dialect (an AppleScript string, a CLI
# argv, or a Warp YAML tab config). Keeping it as an argv array lets the CLI
# backends pass it verbatim and the string backends quote it themselves.

declare -a RUN_ARGV=()
[ ${#env_pairs[@]} -gt 0 ] && RUN_ARGV+=(env "${env_pairs[@]}")
if [ ${#tab_cmd[@]} -gt 0 ]; then
  RUN_ARGV+=("${tab_cmd[@]}")
else
  RUN_ARGV+=("$claude_cmd")
  [ ${#cfg_args[@]} -gt 0 ] && RUN_ARGV+=("${cfg_args[@]}")
fi

# ── Pick and open the terminal ────────────────────────────────────────────────

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
[ -n "$TAB_UID" ] && echo "tab: $TAB_UID"
exit 0
