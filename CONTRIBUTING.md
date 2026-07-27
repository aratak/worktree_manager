# Contributing to `wt`

Thanks for helping out. `wt` is a single bash script — `wt.bash` — distributed as one copyable file. Keep it that way: no sourced modules, no extra files in the runtime path.

## Before a PR

Run both locally — there's no CI:

```sh
bash -n wt.bash        # syntax check
shellcheck wt.bash     # lint (not run in CI, so run it yourself)
```

## The constraint that bites

`wt` must run on **macOS's default bash 3.2** under `set -euo pipefail`. The trap that catches people: expanding an empty array (`"${arr[@]}"`) errors under `set -u` in bash 3.2. Guard it with a length check before expanding — see how `RUN_ARGV` is built:

```bash
[ ${#env_pairs[@]} -gt 0 ] && RUN_ARGV+=(env "${env_pairs[@]}")
```

## Adding a terminal backend

This is the most likely contribution. The launch layer is the only platform-specific seam — everything else is terminal-agnostic. Steps:

1. **Write `open_<name>()`** taking the worktree dir (`$new_path`) and the `RUN_ARGV` array.
2. **Render `RUN_ARGV` in your terminal's dialect.** There are three existing shapes to copy:
   - **AppleScript string** — build the line with `shell_join` and feed it to `osascript` (see `open_iterm`, `open_appleterm`).
   - **Raw CLI argv** — pass `"${RUN_ARGV[@]}"` after the terminal's command separator (see `open_kitty`, `open_wezterm`, `open_gnome`, `open_konsole`, `open_alacritty`, `open_tmux`).
   - **Config-file + open mechanism** — write a config the terminal reads and trigger it (see `open_warp`).
3. **Add an env-marker branch to `detect_terminal()`** if the terminal exposes one (an env var or a `TERM_PROGRAM` value). Skip this if it exposes nothing — users will set `terminal` explicitly.
4. **Add a `case` arm** in the dispatcher that calls your `open_<name>`.
5. **Update the `usage()` terminal list** and the README [Supported terminals](README.md#supported-terminals) matrix.

## A note on the Claude Code coupling

The `wt remove` cleanup depends on Claude Code's internal project-dir naming under `~/.claude/projects`, which is undocumented and can change without notice. This fragility is intentional and accepted — see the compatibility note in the README.
