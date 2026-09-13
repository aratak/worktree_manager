# wt — git worktrees with Claude Code

`wt` creates a git worktree for a branch and opens a new terminal tab (or window) with a fresh `claude` session already running in the new worktree. The result: a second branch ready to work on, started with one command.

## Why

When you need to start work on another branch without disturbing what's running in the current one, doing it by hand means creating a worktree, opening a terminal, cd-ing there, and starting `claude`. `wt` does all of that in one command. The new session starts clean, but it isn't amnesiac about the project: Claude Code shares its auto-memory across all worktrees of the same repository, and `CLAUDE.md` comes with the checkout.

## Requirements

- **bash**, **git**, **jq** — `jq` is the only non-ubiquitous dependency; install it from your package manager.
- `sed`, `awk` — standard on macOS and Linux.
- A supported terminal (see [Supported terminals](#supported-terminals)).
- macOS or Linux.

## Install

```sh
git clone <repo-url> create_worktree
cd create_worktree
chmod +x wt.bash
ln -s "$PWD/wt.bash" ~/bin/wt    # or: ln -s "$PWD/wt.bash" /usr/local/bin/wt
```

Make sure the symlink's directory is on your `PATH`, then verify:

```sh
wt --help
```

Configuration lives in `~/.config/create_worktree/`.

## Usage

| Command | Behavior | Example |
| --- | --- | --- |
| `wt <name>` | Branch `<name>`, worktree dir `../<name>`. | `wt fix-login` → branch `fix-login`, dir `../fix-login` |
| `wt <prefix> <name>` | Branch `<prefix>/<name>`, worktree dir `../<name>`. | `wt PR-26341 fix-login` → branch `PR-26341/fix-login`, dir `../fix-login` |
| `wt … -- <command…>` | Same, but the new tab runs `<command…>` instead of the configured claude command. | `wt dev -- cloudclaude --scope demo --agent developer` |
| `wt list` / `wt ls` | List worktrees (branch + path); marks the current one with `*`. | `wt ls` |
| `wt remove <name>` / `wt rm <name>` | Remove the worktree, delete its branch, and remove its Claude project dir. Resolves `<name>` by branch, dir basename, or path. | `wt rm fix-login` |
| `wt --help` | Show help. | `wt --help` |
| `wt --create-config` | Create the default config if it doesn't exist. | `wt --create-config` |
| `wt --edit-config` | Open the config in `$EDITOR` (creating it first if missing). | `wt --edit-config` |

## Configuration

Path: `~/.config/create_worktree/config.json`. Default:

```json
{
  "command": "claude",
  "args": [],
  "env": {},
  "terminal": ""
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `command` | `"claude"` | The Claude binary to run in the new terminal. Ignored when `-- <command…>` is given. |
| `args` | `[]` | Extra arguments passed to `claude`. Ignored when `-- <command…>` is given. |
| `env` | `{}` | Extra environment variables for the launched command — applied to `-- <command…>` too. |
| `terminal` | `""` | Which terminal backend to open. `""` means auto-detect; set it explicitly to override detection. |

## Supported terminals

| Terminal | OS | Opens | Notes |
| --- | --- | --- | --- |
| `iterm` | macOS | tab | iTerm2. |
| `appleterm` | macOS | **window** | Terminal.app — its AppleScript has no reliable new-tab, so a window is opened. |
| `tmux` | any | window | Works headless / over SSH. |
| `kitty` | any | tab | Needs `allow_remote_control` enabled. |
| `wezterm` | any | tab | Needs a running mux server. |
| `gnome` | Linux | tab | GNOME Terminal. |
| `konsole` | Linux | tab | KDE Konsole. |
| `alacritty` | Linux / any | **window** | Alacritty has no tabs, so a window is opened. |
| `warp` | macOS + Linux | tab | Via a named YAML Tab Config opened through a `warp://tab_config/<name>` URI. |

Auto-detection inspects terminal-specific environment variables (`TERM_PROGRAM`, `TMUX`, `KITTY_WINDOW_ID`, `WEZTERM_PANE`, `KONSOLE_VERSION`, `GNOME_TERMINAL_*`, `ALACRITTY_*`) and is best-effort. Generic terminals expose nothing useful — set `terminal` explicitly in the config when detection fails.

## How it works

- **Worktree** — `git worktree add` for the branch, created as a sibling directory of the repo root.
- **Claude session** — a fresh `claude` (or whatever follows `--`) is launched in the new worktree; no state is copied. Project context comes along anyway: Claude Code shares its auto-memory across all worktrees of the same repository, and `CLAUDE.md` is part of the checkout.
- **Cleanup** — `wt remove` deletes the worktree, its branch, and the worktree's `~/.claude/projects` dir, so removed worktrees don't leave stale session transcripts behind.

## ⚠️ Claude Code compatibility

The `wt remove` cleanup relies on the path-encoding scheme that names dirs under `~/.claude/projects`, which is Claude Code **internal and undocumented** — Anthropic can change it at any time. If the cleanup stops finding the dir after a Claude Code update, that's why. Everything else `wt` does is plain git and terminal automation.

## Troubleshooting

- **kitty / wezterm do nothing** — these need remote control: enable `allow_remote_control` in kitty, and make sure a wezterm mux server is running.
- **Headless / over SSH** — only the `tmux` backend works without a graphical display. Run inside tmux or set `"terminal": "tmux"`.
- **Warp doesn't open a tab** — Warp needs its Tab Config directory to be writable (`~/.warp/tab_configs` on macOS, `${XDG_DATA_HOME:-~/.local/share}/warp-terminal/tab_configs` on Linux).
- **Got a window instead of a tab** — Terminal.app (`appleterm`) and Alacritty (`alacritty`) have no usable tab API, so they open a new window by design.

## License

MIT — see [LICENSE](LICENSE).
