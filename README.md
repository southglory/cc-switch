# cc-switch

> Run multiple **Claude Code** accounts (personal / work) on **one machine** (Windows · macOS · Linux) — side by side, in separate terminals, with zero logging out.

![platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-0078D6)
![powershell](https://img.shields.io/badge/PowerShell-7%2B-5391FE)
![bash/zsh](https://img.shields.io/badge/shell-bash%20%7C%20zsh-4EAA25)
![claude code](https://img.shields.io/badge/Claude%20Code-2.1%2B-D97757)
![license](https://img.shields.io/badge/license-MIT-green)

A tiny PowerShell module. No admin rights. No credential surgery. No daemon.

```powershell
ccp    # → Claude Code as your personal account
ccw    # → Claude Code as your work account   (different terminal, at the same time)
```

---

## Why

Claude Code remembers only **one login per OS user**. Juggling a personal and a
work account means `/login`-ing back and forth all day. `cc-switch` gives each
account its own config directory so both stay logged in — open two terminals and
run them in parallel.

## How it works

Claude Code reads its entire state from the directory named by the
`CLAUDE_CONFIG_DIR` environment variable. As of **Claude Code 2.1+** this
includes *both* `~/.claude/` **and** the `~/.claude.json` global-state file, so
pointing two profiles at two directories gives you **complete isolation**:

```
personal  →  CLAUDE_CONFIG_DIR unset   →  ~/.claude         (your existing setup, untouched)
work      →  CLAUDE_CONFIG_DIR set      →  ~/.claude-work    (its own login, history, MCP)
```

Each launch sets the variable only for the Claude process it spawns and restores
it afterward — so your shell stays clean and two terminals run two accounts at
once. Credentials, history, projects and memory are **never** shared.

> **On the `~/.claude.json` caveat:** older guides warn it leaks shared state
> across profiles and recommend swapping `$USERPROFILE`. That was true on earlier
> builds — verified fixed on **2.1.174**: setting `CLAUDE_CONFIG_DIR` relocates
> `.claude.json` into the profile dir and never touches `~/.claude.json`. If
> you're on an older build, upgrade first.

## Install

One line — no clone needed (the script downloads what it needs):

**macOS / Linux** (bash · zsh; needs `curl` + `python3`):

```bash
curl -fsSL https://raw.githubusercontent.com/southglory/cc-switch/main/install.sh | bash
```

**Windows** (PowerShell 7+):

```powershell
irm https://raw.githubusercontent.com/southglory/cc-switch/main/Install.ps1 | iex
```

Open a new terminal afterward. It copies the launcher to `~/.cc-switch/` (POSIX)
or your module path (Windows) and wires it into your shell profile. Re-run the
same line to update. Prefer to read the code first? `curl … | less` — it's a
small public script.

<details><summary>From a clone (contributors / offline)</summary>

```bash
git clone https://github.com/southglory/cc-switch && cd cc-switch
bash install.sh          # macOS / Linux
pwsh -File .\Install.ps1 # Windows
```
</details>

## Use

```powershell
ccp                     # launch the personal account
ccw                     # launch the work account
cc-switch list          # show profiles + which account each is logged into
```

First time you run `ccw` the profile is empty — run `/login` inside Claude once
to authenticate the work account. It sticks after that.

Arguments pass straight through:

```powershell
ccw --version
ccp -p "summarize this repo"
```

`cc-switch list` shows you exactly who's who:

```
  Profile   Account                Dir
  -------   -------                ---
● personal  you@gmail.com          C:\Users\you\.claude (default)
  work      you@company.com        C:\Users\you\.claude-work
```

### Two accounts at once

Open two terminals. Run `ccp` in one and `ccw` in the other. Fully independent —
different logins, different histories, no collisions.

## More profiles

Not limited to two. Add a profile per client/project:

```powershell
cc-switch new client-x                   # → ~/.claude-client-x
cc-switch new client-x "D:\cc\client-x"  # custom directory
ccx client-x                             # launch it
cc-switch remove client-x                # unregister (keeps the dir)
cc-switch remove client-x -Purge         # unregister and delete the dir
```

The registry lives at `~/.cc-switch/profiles.json` — shared by the Windows and
macOS/Linux versions.

## Project-local accounts (`cclocal`)

Named profiles above are **global** — the same account wherever you run them. For
a throwaway account scoped to **one project folder**, use `cclocal`:

```bash
cd my-project
cclocal                 # runs Claude with CLAUDE_CONFIG_DIR=my-project/.cc-local
```

- The config lives in **`./.cc-local`** (a cc-switch name, deliberately *not*
  `.claude`, which Claude Code uses for project settings).
- `cclocal` adds `.cc-local/` to the project's `.gitignore` so its credentials are
  never committed.
- It's **not a saved profile** — nothing is written to `~/.cc-switch/profiles.json`
  and it never shows up in `cc-switch list`. First run: `/login` inside Claude.

Use named profiles (`ccp`/`ccw`/`ccx`) for your accounts; use `cclocal` when you
want a separate login bound to the current directory.

## Your own shortcuts

`ccp` (personal) and `ccw` (work) are just seeded defaults — rename them or add
your own:

```bash
cc-switch new client-x --alias ccx1   # profile + shortcut in one step
cc-switch alias ccx1 client-x         # add/change a shortcut later
cc-switch unalias ccw                 # drop one you don't want
ccx1                                  # launch it
```

Shortcuts are generated from the registry for every new shell. The `personal`
profile (the default `~/.claude`) can't be removed, but its `ccp` alias can be
changed like any other.

## Commands

| Command | What it does |
|---|---|
| `<alias> [args]` | launch a profile via its shortcut (e.g. `ccp`, `ccw`) |
| `ccx <name> [args]` | launch any named profile |
| `cc-switch list` | list profiles, aliases + the account each is logged into |
| `cc-switch new <name> [dir] [--alias <short>]` | register a new profile (+shortcut) |
| `cc-switch alias <short> <name>` | add/change a shortcut |
| `cc-switch unalias <short>` | drop a shortcut |
| `cc-switch remove <name> [--purge]` | unregister (optionally delete its dir) |
| `cc-switch run <name> [args]` | what the shortcuts call under the hood |

> On PowerShell the flags are `-Alias` / `-Purge`; on bash/zsh they are `--alias` / `--purge`.

## Requirements

- **Windows** (PowerShell 7+) **or** **macOS / Linux** (bash or zsh + `python3`)
- Claude Code 2.1+ (`claude --version`)

## Uninstall

**Windows:**

```powershell
Remove-Item -Recurse "$HOME\Documents\PowerShell\Modules\cc-switch"
```

Then delete the `Import-Module cc-switch` line from your PowerShell profile
(`$PROFILE.CurrentUserAllHosts`).

**macOS / Linux:** delete the `source ~/.cc-switch/cc-switch.sh` line (and the
`# cc-switch` comment above it) from your `~/.bashrc` / `~/.zshrc`, then
`rm -rf ~/.cc-switch`.

Your account directories (`~/.claude`, `~/.claude-work`, …) are left untouched.

## Notes

- **CLI-first.** If you want IDE-centric isolation (VS Code / Cursor profiles),
  other tools fit better. cc-switch is for people who live in the terminal.
- **Not a credential swapper.** It never reads or moves your tokens — it just
  points Claude Code at a different directory. Each account logs in once, itself.
- This is a thin wrapper around one environment variable. If Claude Code ever
  ships native multi-account support, you won't need it — and that's fine.
- **Works with the [Claude Multi-Account Status Bar](https://github.com/southglory/claude-usage-bar)
  extension.** Adding an account there can register a shortcut in this tool's
  registry. The installer writes a small `~/.cc-switch/installed.json` marker so the
  extension can tell cc-switch is present — if you installed an older build, just
  re-run the installer once (it's idempotent) to register it.

## License

MIT
