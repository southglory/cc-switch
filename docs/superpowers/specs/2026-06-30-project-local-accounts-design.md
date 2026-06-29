# Project-local accounts — `cclocal`

**Date:** 2026-06-30
**Repo:** cc-switch
**Status:** Approved design

## Goal

Let a user run Claude Code with a **project-local** config dir (isolated per
directory) via a dedicated `cclocal` command — clearly separate from the named
**global** profiles (`ccp`/`ccw`/`ccx`), with credentials kept out of git.

## Background

cc-switch today only has **global** named profiles stored in
`~/.cc-switch/profiles.json` and launched via `ccp`/`ccw`/`ccx <name>` (POSIX
`cc_run` / PowerShell `Use-ClaudeProfile`). All resolve to a fixed absolute dir,
independent of cwd. There is no per-project isolation.

## Decisions

1. **Ephemeral, not registered.** `cclocal` is a separate command; it does NOT
   write to `profiles.json` and never appears in `cc-switch list`. This keeps the
   global profile list clean and avoids cwd-dependent registered profiles.
2. **Dir = `$PWD/.cc-local`.** A cc-switch-branded name, deliberately NOT `.claude`
   (which Claude Code uses for *project* settings — pointing CLAUDE_CONFIG_DIR
   there would mix user credentials into a git-tracked dir) and not `.claude-*`
   (visually confusable with `.claude`).
3. **Auto-gitignore.** On launch, ensure `$PWD/.gitignore` ignores `.cc-local/`
   (create the file if absent; append the line if missing; idempotent) so the
   account's credentials are never committed.
4. **Same launch mechanics** as global profiles (subshell on POSIX, save/restore
   on PowerShell; first-run `/login` hint).

## Architecture

### POSIX (`cc-switch.sh`)

- `cclocal() { cc_local "$@"; }` — public shortcut.
- `cc_local()`:
  ```
  dir="$PWD/.cc-local"
  [ -d "$dir" ] || mkdir -p "$dir"
  _cc_gitignore_local "$PWD"        # ensure .gitignore ignores .cc-local/
  login hint if no account email (reuse _cc_account_email)
  ( export CLAUDE_CONFIG_DIR="$dir"; command claude "$@" )
  ```
- `_cc_gitignore_local <dir>`: if `<dir>/.gitignore` missing → create with
  `.cc-local/`; else `grep -qxF '.cc-local/'` and append if absent.
- Dispatcher: add `local) cc_local "$@";;` to `cc-switch()`; add a help line.

### PowerShell (`cc-switch.psm1`)

- `function cclocal { ... }` mirroring the above:
  ```
  $dir = Join-Path $PWD '.cc-local'
  New-Item -ItemType Directory -Force $dir (if missing)
  Set-CcLocalGitignore $PWD
  login hint (Get-CcAccountEmail -Dir $dir)
  save/restore $env:CLAUDE_CONFIG_DIR; set to $dir; run claude
  ```
- `Set-CcLocalGitignore`: create/append `.cc-local/` to `$dir\.gitignore`, idempotent.
- Dispatcher `Invoke-CcSwitch`: add `'local' { cclocal @rest }`; help line.
- Export `cclocal`; add to `.psd1 FunctionsToExport`.

### Distinction from global (the core requirement)

- Different command name (`cclocal` vs `ccp`/`ccw`/`ccx`).
- Never in `profiles.json`; never shown by `cc-switch list`.
- Folder `.cc-local` is unmistakable next to `.claude`.
- Help + README label it "current directory only".

## Data flow

```
cd my-project ; cclocal
  └─ dir = my-project/.cc-local  (created)
  └─ my-project/.gitignore gets ".cc-local/"   (created/appended)
  └─ ( CLAUDE_CONFIG_DIR=my-project/.cc-local ; claude )   # isolated, project-local
```

## Error handling

- `.gitignore` write fails (read-only dir) → warn, continue (don't block launch).
- `.cc-local` already exists/logged in → just launch (no re-login hint).
- Not a git repo → still create `.gitignore` (harmless; protects if it becomes one).
- `claude` missing on PATH → standard "not found" surfaced by the shell.

## Testing

- **POSIX** (`test/posix_test.sh`, fake `claude` shim, temp cwd):
  - `cclocal` exports `CLAUDE_CONFIG_DIR=<cwd>/.cc-local`.
  - `.cc-local` dir created.
  - `.gitignore` created containing `.cc-local/`; second call does not duplicate the line.
- **PowerShell** (`test/ps_local_test.ps1`, fake `claude.cmd`, temp cwd):
  - same three assertions.

## Out of scope (YAGNI)

- No registering local dirs in the registry.
- No custom local dir name (fixed `.cc-local`).
- No `cc-switch list` integration for local dirs.
- No cleanup/removal command (delete the folder manually).

## Compatibility

- Purely additive: new command + new dispatcher verb. Global profiles, registry,
  `ccp`/`ccw`/`ccx`, and existing tests are untouched. cc-switch → **0.3.0**.
