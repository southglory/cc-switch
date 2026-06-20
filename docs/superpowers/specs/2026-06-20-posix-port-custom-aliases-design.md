# cc-switch — POSIX port + user-defined aliases

**Date:** 2026-06-20
**Status:** Approved design, pending spec review

## Goal

Bring `cc-switch` (today a Windows/PowerShell module that runs multiple Claude
Code accounts via `CLAUDE_CONFIG_DIR` isolation) to **Linux and macOS**, and let
users **name their own launch shortcuts** instead of being limited to the
hard-coded `ccp`/`ccw`. Keep both platforms behaving identically by sharing one
profile registry, and migrate existing Windows users with zero breakage.

## Background (current state)

- PowerShell module `cc-switch.psm1` + `cc-switch.psd1` + `Install.ps1`.
- Core: `Use-ClaudeProfile <name> [args]` sets `CLAUDE_CONFIG_DIR`, runs `claude`,
  restores the env afterward. `personal` = the default profile = `~/.claude`
  (variable unset).
- Registry: `~/.cc-switch/profiles.json`, shape
  `{ version:1, default:'personal', profiles:{ <name>:{ dir, desc } } }`.
- Shortcuts `ccp` (personal) / `ccw` (work) are **hard-coded functions**; any
  other profile launches via `ccx <name>`.
- Management: `cc-switch list|new|remove|run|path`.

## Decisions

1. **Approach A — alias on creation.** `cc-switch new <name> --alias <short>`
   registers a profile *and* its shortcut. Aliases are stored in the registry,
   not hard-coded. `ccp`/`ccw` become seeded defaults rather than special code.
2. **Defaults:** seed `personal` (+`ccp`, permanent — it is the non-removable
   default profile) and `work` (+`ccw`, removable). Users add their own
   (e.g. `cct`).
3. **One POSIX script** (`cc-switch.sh`) covering bash *and* zsh (Linux + macOS).
4. **Unify both platforms.** PowerShell also reads/writes the `alias` field and
   generates shortcut functions from the registry, so Windows and POSIX behave
   identically off the shared `profiles.json`.
5. **READMEs updated on both sides** (PowerShell + POSIX; platform badges add
   macOS/Linux).

## Architecture

Both implementations are thin wrappers over the same registry and the same
`CLAUDE_CONFIG_DIR` mechanic. Units:

### Registry (shared, `~/.cc-switch/profiles.json`)

Schema **v2**:

```jsonc
{
  "version": 2,
  "default": "personal",
  "profiles": {
    "personal": { "dir": null,               "alias": "ccp", "desc": "..." },
    "work":     { "dir": "~/.claude-work",    "alias": "ccw", "desc": "..." }
  }
}
```

- `dir: null` → the default profile (`CLAUDE_CONFIG_DIR` unset → `~/.claude`).
- `alias` → optional short command name. Absent = launch only via `ccx <name>`.
- Both platforms read/write this identical file. Paths stored with `~` and
  expanded at use time so the file is portable across machines.

### Core launcher

- **POSIX** `cc_run <name> [args...]`: resolve profile → ensure dir exists →
  export `CLAUDE_CONFIG_DIR` (or unset for default) in a **subshell** so the
  parent shell's env is never mutated → `claude "$@"`.
- **PowerShell** `Use-ClaudeProfile` — unchanged mechanic.

### Alias generation (the new part)

- On shell startup, `cc-switch.sh` reads the registry and **defines one function
  per profile that has an `alias`**: `ccw() { cc_run work "$@"; }`.
- PowerShell does the equivalent at module import (replacing the hard-coded
  `ccp`/`ccw` with registry-driven generation).
- `cc-switch alias <short> <name>` / `cc-switch unalias <short>` edit the registry
  and re-generate in the current shell. A note tells the user new shells pick it
  up automatically; the current shell is refreshed immediately.
- Alias name validation: must match `^[a-zA-Z][a-zA-Z0-9_-]*$`, must not collide
  with an existing command/builtin (warn) or another profile's alias (reject).

### Management commands (both platforms, unchanged + additions)

`list` · `new <name> [dir] [--alias <short>]` · `remove <name> [--purge]` ·
`run <name> [args]` · `path <name>` · **`alias <short> <name>`** ·
**`unalias <short>`**.

### Migration (v1 → v2, non-destructive)

On load, if `version < 2`:
1. Copy `profiles.json` → `profiles.json.bak` (one-time safety backup).
2. Backfill missing aliases: `personal → ccp`, `work → ccw`.
3. Set `version: 2`.
4. **Never** touch profiles, directories, or credentials — only add the `alias`
   field. Idempotent.

Result: existing Windows users keep `ccp`/`ccw` working after updating; account
dirs (`~/.claude*`) and tokens are untouched.

### Install

- **POSIX** `install.sh`: copy `cc-switch.sh` to `~/.cc-switch/`, add a single
  `source ~/.cc-switch/cc-switch.sh` line to `~/.bashrc` and/or `~/.zshrc`
  (detect which exist; idempotent — don't double-add). Print "open a new shell".
- **PowerShell** `Install.ps1`: unchanged, plus a note that updating = `git pull`
  then re-run.

## Data flow

```
user types `ccw --version`
  └─ ccw() generated from registry  →  cc_run work --version
       └─ resolve work → dir ~/.claude-work
       └─ ( export CLAUDE_CONFIG_DIR=~/.claude-work ; claude --version )   # subshell
       └─ parent shell env unchanged
```

## Error handling

- Unknown profile / alias → clear message listing known names + how to add.
- Not-logged-in profile (no account email in its dir) → one-time yellow hint to
  run `/login`, same as the PS version does today.
- Alias collides with a real command (e.g. `ls`) → warn but allow with
  confirmation; collides with another profile's alias → reject.
- Corrupt/unreadable registry → fail safe: report path, do not overwrite; suggest
  restoring from `profiles.json.bak`.
- `claude` not on PATH → actionable message.

## Testing

- **POSIX:** `bash -n` / `zsh -n` syntax checks; a small test that drives the
  registry CRUD + alias generation with a fake `claude` shim on `PATH` and a
  temp `HOME`, asserting `CLAUDE_CONFIG_DIR` is set correctly and the parent
  shell's env is restored. Run under both bash and zsh.
- **PowerShell (testable on this Windows machine):** migration v1→v2 backfills
  aliases without mutating dirs; registry-driven `ccp`/`ccw` still work; `new
  --alias` + `alias`/`unalias` behave; existing profiles.json round-trips.
- **Migration:** start from a real v1 registry fixture, assert `.bak` written,
  aliases backfilled, version bumped, profiles untouched.

## Out of scope (YAGNI)

- No GUI, no daemon, no credential handling (cc-switch never touches tokens).
- No Fish/other shells in v1 (bash + zsh only).
- No auto-switching of the *current* shell's account (launch-per-process only,
  matching today's model).

## Compatibility summary

- Existing Windows users: seamless via auto-migration; `ccp`/`ccw` keep working;
  account dirs/credentials untouched; update = pull + re-run installer.
- Registry stays one shared file; `alias` is additive and ignored safely if an
  older PS build ever reads it.
