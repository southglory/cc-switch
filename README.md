# cc-switch

Run **multiple Claude Code accounts** (personal / work) on **one Windows machine** —
side by side, in separate terminals, with zero logging out.

A tiny PowerShell module. No admin rights. No credential surgery.

## How it works

Claude Code reads its entire state from the directory named by the
`CLAUDE_CONFIG_DIR` environment variable. As of **Claude Code 2.1+**, this
includes *both* the `~/.claude/` directory **and** the `~/.claude.json`
global-state file — so pointing two profiles at two directories gives you
**complete isolation**:

```
personal  →  CLAUDE_CONFIG_DIR unset   →  ~/.claude            (your existing setup, untouched)
work      →  CLAUDE_CONFIG_DIR=...      →  ~/.claude-work       (its own login, history, MCP)
```

Each terminal sets the variable only for the Claude process it launches and
restores it afterward, so two terminals run two accounts **at the same time**.

> Older guides warn that `~/.claude.json` leaks shared state across profiles.
> That was true on earlier builds; verified fixed on **2.1.174** (setting
> `CLAUDE_CONFIG_DIR` relocates `.claude.json` into the profile dir and never
> touches `~/.claude.json`). If you're on an older build, upgrade first.

Credentials, history, projects and memory are **never** shared between profiles.

## Install

```powershell
pwsh -File .\Install.ps1
```

This copies the module to your user module path and adds `Import-Module cc-switch`
to your PowerShell profile. Open a new terminal afterward.

## Use

```powershell
cc-switch list          # show profiles and which account each is logged into
ccp                     # launch Claude Code as your personal account
ccw                     # launch Claude Code as your work account
```

First time you run `ccw`, the profile is empty — just run `/login` inside
Claude and authenticate the work account. Done once; it sticks.

Arguments pass straight through:

```powershell
ccw --version
ccp -p "summarize this repo"
```

### Two accounts at once

Open two terminals. Run `ccp` in one and `ccw` in the other. They're fully
independent — different logins, different histories, no collisions.

## Manage profiles

```powershell
cc-switch new client-x                       # → ~/.claude-client-x
cc-switch new client-x "D:\cc\client-x"      # custom directory
ccx client-x                                 # launch it
cc-switch remove client-x                    # unregister (keeps the dir)
cc-switch remove client-x -Purge             # unregister and delete the dir
```

The registry lives at `~/.cc-switch/profiles.json`.

## Requirements

- Windows
- PowerShell 7+
- Claude Code 2.1+

## Commands

| Command | What it does |
|---|---|
| `ccp [args]` | launch the **personal** profile |
| `ccw [args]` | launch the **work** profile |
| `ccx <name> [args]` | launch any named profile |
| `cc-switch list` | list profiles + the account each is logged into |
| `cc-switch new <name> [dir]` | register a new profile |
| `cc-switch remove <name> [-Purge]` | unregister (optionally delete its dir) |
| `cc-switch run <name> [args]` | what `ccp`/`ccw` call under the hood |

## License

MIT
