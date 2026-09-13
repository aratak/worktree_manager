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

This is the most likely contribution. The terminal layer is the only platform-specific seam — everything else is terminal-agnostic. A backend is up to four functions, of which **only `open_<name>` is required**:

| Function | Required | Job |
| --- | --- | --- |
| `open_<name>` | yes | Open a tab in `$new_path` and run `RUN_ARGV` there. |
| `close_<name>` | no | Close the session with the given native handle. |
| `focus_<name>` | no | Bring that session to the front. |
| `list_<name>` | no | Print `handle⇥job⇥path` for every live session, one per line. |
| `alive_<name>` | no | Exit 0 if the given handle is still a live session. |

Defining `close_<name>` is what opts a backend into `wt close`, `wt`'s focus-instead-of-open behaviour and the tabs nested under `wt ls`; it comes as a set with `focus_`, `alive_` and `list_`, and needs `open_<name>` to register the tab (see `registry_add` in `open_iterm`). Support is probed with `declare -f`, never `type -t` — that also resolves executables on `PATH`, so a stray file named `close_kitty` would declare kitty supported. Backends without the set still open tabs exactly as before; `wt close` simply finds nothing of theirs.

Steps for the required part:

1. **Write `open_<name>()`** taking the worktree dir (`$new_path`) and the `RUN_ARGV` array.
2. **Render `RUN_ARGV` in your terminal's dialect.** There are three existing shapes to copy:
   - **AppleScript string** — build the line with `shell_join` and feed it to `osascript` (see `open_iterm`, `open_appleterm`).
   - **Raw CLI argv** — pass `"${RUN_ARGV[@]}"` after the terminal's command separator (see `open_kitty`, `open_wezterm`, `open_gnome`, `open_konsole`, `open_alacritty`, `open_tmux`).
   - **Config-file + open mechanism** — write a config the terminal reads and trigger it (see `open_warp`).
3. **Add an env-marker branch to `detect_terminal()`** if the terminal exposes one (an env var or a `TERM_PROGRAM` value). Skip this if it exposes nothing — users will set `terminal` explicitly.
4. **Add a `case` arm** in the dispatcher that calls your `open_<name>`.
5. **Update the `usage()` terminal list** and the README [Supported terminals](README.md#supported-terminals) matrix.

If you go on to the optional four, two things about the registry are worth knowing before you start. The handle you store must be one the terminal will still recognise later and one a session can read about *itself* — `close_iterm` and the self-skip in `wt close` both compare against it. And the registry is never trusted for liveness: `alive_<name>` is what decides, so every read prunes rows the terminal no longer knows.

## A note on the Claude Code coupling

The `wt remove` cleanup depends on Claude Code's internal project-dir naming under `~/.claude/projects`, which is undocumented and can change without notice. This fragility is intentional and accepted — see the compatibility note in the README.
