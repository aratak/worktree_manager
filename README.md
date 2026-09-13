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
| `wt <prefix>/<name>` | Same branch as the two-argument form, so it reopens the worktree that form created. | `wt PR-26341/fix-login` → tab in `../fix-login` |
| `wt … -- <command…>` | Same, but the new tab runs `<command…>` instead of the configured claude command. | `wt dev -- cloudclaude --scope demo --agent developer` |
| `wt --create …` | Create the worktree and stop — no tab, no command. Cannot be combined with `-- <command…>`. | `wt --create PR-26341 fix-login` |
| `wt … --new-tab` | Open another tab even when `wt` already has one in that worktree. | `wt fix-login --new-tab` |
| `wt … --tab <uid>` | Focus that tab instead of opening one. A uid identifies a tab completely, so it needs no worktree and no repo. | `wt --tab wt-a1b2` |
| `wt list` / `wt ls` | List worktrees (branch + path) with `wt`'s own live tabs nested under each; marks the current worktree with `*`. `--json` prints the same thing machine-readably. | `wt ls --json` |
| `wt close <name>` | Close every tab `wt` opened in that worktree. Resolves `<name>` exactly like `wt remove`. | `wt close fix-login` |
| `wt close --tab <uid>` | Close that one tab. | `wt close --tab wt-a1b2` |
| `wt remove <name>` / `wt rm <name>` | Close `wt`'s tabs there, then remove the worktree, delete its branch, and remove its Claude project dir. Resolves `<name>` by branch, dir basename, or path. | `wt rm fix-login` |
| `wt rm --keep-tabs <name>` | Same, but leaves the tabs running — and stops tracking them, since the worktree they were opened for is gone. | `wt rm --keep-tabs fix-login` |
| `wt --help` | Show help. | `wt --help` |
| `wt --create-config` | Create the default config if it doesn't exist. | `wt --create-config` |
| `wt --edit-config` | Open the config in `$EDITOR` (creating it first if missing). | `wt --edit-config` |

Running `wt` on a worktree that already has exactly one of its tabs focuses that tab instead of opening a second one; with several open, `wt` lists them and asks for `--tab <uid>` or `--new-tab`.

Two exit codes are worth scripting against: **1** when nothing matched the query, **2** when the tab's terminal backend cannot close or focus tabs.

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

| Terminal | OS | Opens | Close / focus / list | Notes |
| --- | --- | --- | --- | --- |
| `iterm` | macOS | tab | yes | iTerm2. |
| `appleterm` | macOS | **window** | no | Terminal.app — its AppleScript has no reliable new-tab, so a window is opened. |
| `tmux` | any | window | no | Works headless / over SSH. |
| `kitty` | any | tab | no | Needs `allow_remote_control` enabled. |
| `wezterm` | any | tab | no | Needs a running mux server. |
| `gnome` | Linux | tab | no | GNOME Terminal. |
| `konsole` | Linux | tab | no | KDE Konsole. |
| `alacritty` | Linux / any | **window** | no | Alacritty has no tabs, so a window is opened. |
| `warp` | macOS + Linux | tab | no | Via a named YAML Tab Config opened through a `warp://tab_config/<name>` URI. |

Every backend opens tabs. Only `iterm` also closes, focuses and lists them: the rest were written from documentation, and a backend that can close your tabs is not something to ship untested. On those terminals `wt` opens the tab and forgets it — `wt close` finds nothing to close and `wt ls` nests nothing, while `wt remove` still removes the worktree. Adding one is purely additive, see [CONTRIBUTING.md](CONTRIBUTING.md).

Auto-detection inspects terminal-specific environment variables (`TERM_PROGRAM`, `TMUX`, `KITTY_WINDOW_ID`, `WEZTERM_PANE`, `KONSOLE_VERSION`, `GNOME_TERMINAL_*`, `ALACRITTY_*`) and is best-effort. Generic terminals expose nothing useful — set `terminal` explicitly in the config when detection fails.

## How it works

- **Worktree** — `git worktree add` for the branch, created as a sibling directory of the repo root. If the branch is already checked out somewhere, that worktree is reused and only the tab opens — the branch, not a computed directory name, is what `wt` looks up, so both argument forms find the same worktree.
- **Claude session** — a fresh `claude` (or whatever follows `--`) is launched in the new worktree; no state is copied. Project context comes along anyway: Claude Code shares its auto-memory across all worktrees of the same repository, and `CLAUDE.md` is part of the checkout.
- **Tabs** — every tab `wt` opens is recorded in `~/.config/create_worktree/tabs.json` and gets a short uid (`wt-a1b2`). The rule that keeps that file honest: *the registry says what is ours, the terminal says what is alive.* Nothing in it is trusted for liveness — every read verifies the rows against the running terminal, so a tab you closed by hand, a restarted terminal or a reboot self-heal instead of piling up stale rows. Tabs you opened by hand are not in the registry, so `wt` never lists, closes or removes them.
- **Cleanup** — `wt remove` closes `wt`'s tabs in the worktree first, then deletes the worktree, its branch, and the worktree's `~/.claude/projects` dir, so removed worktrees don't leave stale session transcripts behind. Closing comes first on purpose: a `claude` whose cwd is inside a deleted worktree does not crash, it silently keeps writing to a path that no longer exists. The consequence to know is the other side of that order — if `git worktree remove` then fails, the tabs are already closed.

## ⚠️ Claude Code compatibility

The `wt remove` cleanup relies on the path-encoding scheme that names dirs under `~/.claude/projects`, which is Claude Code **internal and undocumented** — Anthropic can change it at any time. If the cleanup stops finding the dir after a Claude Code update, that's why. Everything else `wt` does is plain git and terminal automation.

## Troubleshooting

- **kitty / wezterm do nothing** — these need remote control: enable `allow_remote_control` in kitty, and make sure a wezterm mux server is running.
- **Headless / over SSH** — only the `tmux` backend works without a graphical display. Run inside tmux or set `"terminal": "tmux"`.
- **Warp doesn't open a tab** — Warp needs its Tab Config directory to be writable (`~/.warp/tab_configs` on macOS, `${XDG_DATA_HOME:-~/.local/share}/warp-terminal/tab_configs` on Linux).
- **Got a window instead of a tab** — Terminal.app (`appleterm`) and Alacritty (`alacritty`) have no usable tab API, so they open a new window by design.
- **`wt close` hangs on iTerm** — the tab's profile has *Prompt before closing* enabled, and the modal it raises is waiting for an answer AppleScript cannot give. It's your setting, not `wt`'s to override: iTerm → Settings → Profiles → Session.
- **`wt close` says there are no tabs** — only the iTerm backend tracks what it opens (see [Supported terminals](#supported-terminals)); elsewhere there is nothing for `wt` to close.

## License

MIT — see [LICENSE](LICENSE).
