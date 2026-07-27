# wt — git worktrees with Claude Code session forking

`wt` creates a git worktree for a branch, forks the Claude Code session you're running from, and opens a new terminal tab (or window) with `claude` already running in the new worktree. The result: a second branch with a fully-seeded Claude session, started with one command.

## Why

When you're deep in a Claude Code conversation and need to start work on another branch, switching worktrees the normal way means a fresh session that knows nothing about what you were doing. `wt` lets you spin up parallel work on a new branch without losing the current conversation and context — the new session is forked from the one you're in, so it carries the history forward.

## Requirements

- **bash**, **git**, **jq** — `jq` is the only non-ubiquitous dependency; install it from your package manager.
- `uuidgen`, `date`, `sed`, `awk` — standard on macOS and Linux.
- A supported terminal (see [Supported terminals](#supported-terminals)).
- macOS or Linux.
- **Must be run from inside a Claude Code session** for the fork to happen — `wt` reads `CLAUDE_CODE_SESSION_ID`. Without it, the worktree is still created, but no session is forked.

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
| `wt list` | List worktrees (branch + path); marks the current one with `*`. | `wt list` |
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
| `command` | `"claude"` | The Claude binary to run in the new terminal. |
| `args` | `[]` | Extra arguments passed to `claude`. |
| `env` | `{}` | Extra environment variables for the launched command. |
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

- **Memory** — nothing to do: Claude Code shares its auto-memory across all worktrees of the same repository natively, so the new worktree sees the same memory as the source.
- **Session fork** — `wt` copies the current session's `<session>.jsonl` into the new worktree's project dir and appends one `isMeta` turn that tells the resumed session it moved: the working directory changed from the old worktree to the new one, and it should operate in the new path from then on. `claude` is launched with `--resume <session> --fork-session`.

## ⚠️ Claude Code compatibility

The session fork relies on Claude Code's **internal, undocumented** session format: the `~/.claude/projects` directory layout, the path-encoding scheme that names project dirs, and the `.jsonl` record schema (fields like `parentUuid`, `isMeta`, `cwd`, `sessionId`, `version`, …). None of this is a public API — Anthropic can change it at any time. If forking breaks after a Claude Code update, that's almost certainly why. Worktree creation, `wt list`, and `wt remove` don't touch any of this and are unaffected.

## Troubleshooting

- **kitty / wezterm do nothing** — these need remote control: enable `allow_remote_control` in kitty, and make sure a wezterm mux server is running.
- **Headless / over SSH** — only the `tmux` backend works without a graphical display. Run inside tmux or set `"terminal": "tmux"`.
- **Warp doesn't open a tab** — Warp needs its Tab Config directory to be writable (`~/.warp/tab_configs` on macOS, `${XDG_DATA_HOME:-~/.local/share}/warp-terminal/tab_configs` on Linux).
- **Got a window instead of a tab** — Terminal.app (`appleterm`) and Alacritty (`alacritty`) have no usable tab API, so they open a new window by design.

## License

MIT — see [LICENSE](LICENSE).
