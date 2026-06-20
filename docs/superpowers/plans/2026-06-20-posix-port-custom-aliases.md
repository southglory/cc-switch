# cc-switch POSIX Port + User-Defined Aliases — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bash/zsh (Linux + macOS) port of cc-switch and let users define their own launch shortcuts, sharing one `profiles.json` registry with the existing PowerShell module and migrating current users with zero breakage.

**Architecture:** Both platforms are thin wrappers over the same `~/.cc-switch/profiles.json` (schema v2 with an `alias` field) and the same `CLAUDE_CONFIG_DIR` mechanic. The POSIX side delegates all JSON read/write to short inline `python3` programs; it generates one shell function per aliased profile at shell-startup. A one-time v1→v2 migration backfills `ccp`/`ccw`.

**Tech Stack:** bash + zsh (target shells), `python3` (JSON engine for the POSIX side), PowerShell 7+ (existing side), Markdown (docs).

## Global Constraints

- Registry path: `~/.cc-switch/profiles.json`; tests/override via `CC_SWITCH_HOME` env (both platforms must honor it).
- Schema v2: `{ version:2, default:"personal", profiles:{ <name>:{ dir, alias, desc } } }`. `dir:null` = default profile (`CLAUDE_CONFIG_DIR` unset → `~/.claude`). `alias` optional.
- Seeded defaults: `personal`(+`ccp`, non-removable) and `work`(+`ccw`, removable).
- Alias name rule: `^[a-zA-Z][a-zA-Z0-9_-]*$`; reject if it collides with another profile's alias; warn (but allow) if it shadows an existing command.
- POSIX target is **bash and zsh only** (uses process substitution / `eval`); not POSIX `sh`, not Fish.
- The tool NEVER reads, moves, or writes credentials/account dirs beyond `mkdir -p` of a profile's own dir. Migration only ADDS the `alias` field and writes a `.bak`.
- Paths in the registry stored with `~` and expanded at use time (portable across machines).
- JSON engine: `python3`. If absent, commands that touch the registry must fail with an actionable message.
- Author/copyright stays `southglory`; project URL `https://github.com/southglory/cc-switch`.

---

## File Structure

- **Create** `cc-switch.sh` — POSIX implementation (registry+migration, launcher, alias generation, dispatcher, shortcuts). Sourced from `~/.bashrc`/`~/.zshrc`.
- **Create** `install.sh` — POSIX installer (copy to `~/.cc-switch/`, add a source line to rc files, seed registry).
- **Create** `test/posix_test.sh` — bash test harness (temp `CC_SWITCH_HOME`, fake `claude` shim).
- **Create** `test/ps_test.ps1` — PowerShell test (migration + alias parity), runnable on Windows.
- **Modify** `cc-switch.psm1` — `CC_SWITCH_HOME` override, `alias` field, v1→v2 migration, registry-driven alias generation (replace hard-coded `ccp`/`ccw`), `new --alias`, `alias`/`unalias` commands.
- **Modify** `cc-switch.psd1` — bump version to `0.2.0`; cross-platform description/tags.
- **Modify** `README.md` — document both platforms; add macOS/Linux badges; alias UX.

---

## Task 1: POSIX registry + JSON helpers + v1→v2 migration

**Files:**
- Create: `cc-switch.sh`
- Test: `test/posix_test.sh`

**Interfaces:**
- Produces: `CC_DIR`, `CC_FILE` vars; `_cc_has_py()`; `_cc_registry_ensure()` (creates/seeds/migrates, idempotent); `_cc_profiles_json()` (echo raw registry).

- [ ] **Step 1: Write the failing test** — create `test/posix_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CC_SWITCH_HOME="$TMP/.cc-switch"
export HOME="$TMP"            # isolate ~ expansion
fail=0; ok(){ echo "ok - $1"; }; no(){ echo "NOT OK - $1"; fail=1; }

# fake claude on PATH that records the env it saw
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}" > "$CC_TEST_OUT"
echo "ARGS=$*" >> "$CC_TEST_OUT"
SH
chmod +x "$TMP/bin/claude"; export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
. "$HERE/cc-switch.sh"

# --- Task 1: migration ---
# seed a v1 registry by hand, then ensure() must migrate to v2 + backfill aliases
mkdir -p "$CC_SWITCH_HOME"
cat > "$CC_SWITCH_HOME/profiles.json" <<'JSON'
{"version":1,"default":"personal","profiles":{"personal":{"dir":null,"desc":"p"},"work":{"dir":"~/.claude-work","desc":"w"}}}
JSON
_cc_registry_ensure
python3 - "$CC_SWITCH_HOME/profiles.json" <<'PY' && ok "migrated v1->v2" || no "migrated v1->v2"
import json,sys; d=json.load(open(sys.argv[1]))
assert d["version"]==2, d
assert d["profiles"]["personal"]["alias"]=="ccp"
assert d["profiles"]["work"]["alias"]=="ccw"
PY
[ -f "$CC_SWITCH_HOME/profiles.json.bak" ] && ok "backup written" || no "backup written"

exit $fail
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/posix_test.sh`
Expected: FAIL — `cc-switch.sh` does not exist / `_cc_registry_ensure: command not found`.

- [ ] **Step 3: Write minimal implementation** — create `cc-switch.sh`:

```bash
# cc-switch.sh — run multiple Claude Code accounts on Linux/macOS (bash/zsh).
# Sourced from ~/.bashrc or ~/.zshrc. Shares ~/.cc-switch/profiles.json with the
# Windows PowerShell module. JSON is handled by python3.

CC_DIR="${CC_SWITCH_HOME:-$HOME/.cc-switch}"
CC_FILE="$CC_DIR/profiles.json"

_cc_has_py() { command -v python3 >/dev/null 2>&1; }
_cc_need_py() {
  _cc_has_py && return 0
  echo "cc-switch: python3 is required (used to read ~/.cc-switch/profiles.json)." >&2
  return 1
}

# Create + seed the registry if missing; migrate v1 -> v2 (non-destructive).
_cc_registry_ensure() {
  _cc_need_py || return 1
  python3 - "$CC_FILE" <<'PY'
import json, os, sys, shutil
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
if not os.path.exists(path):
    data = {"version": 2, "default": "personal", "profiles": {
        "personal": {"dir": None,            "alias": "ccp", "desc": "Personal account (default ~/.claude)"},
        "work":     {"dir": "~/.claude-work","alias": "ccw", "desc": "Work account"}}}
    json.dump(data, open(path, "w"), indent=2)
    sys.exit(0)
data = json.load(open(path))
if data.get("version", 1) < 2:
    shutil.copyfile(path, path + ".bak")        # one-time safety backup
    for name, alias in (("personal", "ccp"), ("work", "ccw")):
        p = data.get("profiles", {}).get(name)
        if p is not None and not p.get("alias"):
            p["alias"] = alias
    data["version"] = 2
    json.dump(data, open(path, "w"), indent=2)
PY
}

_cc_profiles_json() { _cc_registry_ensure || return 1; cat "$CC_FILE"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/posix_test.sh`
Expected: PASS — `ok - migrated v1->v2`, `ok - backup written`.

- [ ] **Step 5: Commit**

```bash
git add cc-switch.sh test/posix_test.sh
git commit -m "feat(posix): registry + json helpers + v1->v2 migration"
```

---

## Task 2: POSIX core launcher

**Files:**
- Modify: `cc-switch.sh` (append)
- Test: `test/posix_test.sh` (append assertions)

**Interfaces:**
- Consumes: `CC_FILE`, `_cc_registry_ensure`.
- Produces: `_cc_profile_dir <name>` (echoes dir; empty for default; exit 3 if unknown); `_cc_account_email <dir>`; `cc_run <name> [args...]` (launch claude under the profile in a subshell).

- [ ] **Step 1: Write the failing test** — append before `exit $fail` in `test/posix_test.sh`:

```bash
# --- Task 2: launcher sets/sunsets CLAUDE_CONFIG_DIR, restores parent env ---
export CLAUDE_CONFIG_DIR="/parent/stays"     # parent env must be untouched
export CC_TEST_OUT="$TMP/out.work"
cc_run work --version
grep -q "CLAUDE_CONFIG_DIR=$HOME/.claude-work" "$CC_TEST_OUT" && ok "work dir exported" || no "work dir exported"
grep -q "ARGS=--version" "$CC_TEST_OUT" && ok "args passed" || no "args passed"
[ "$CLAUDE_CONFIG_DIR" = "/parent/stays" ] && ok "parent env restored" || no "parent env restored"

export CC_TEST_OUT="$TMP/out.personal"
cc_run personal
grep -q "CLAUDE_CONFIG_DIR=<unset>" "$CC_TEST_OUT" && ok "default unsets var" || no "default unsets var"

cc_run nope 2>/dev/null && no "unknown profile errors" || ok "unknown profile errors"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/posix_test.sh`
Expected: FAIL — `cc_run: command not found`.

- [ ] **Step 3: Write minimal implementation** — append to `cc-switch.sh`:

```bash
# Echo a profile's dir ("" for the default/null), exit 3 if the profile is unknown.
_cc_profile_dir() {
  _cc_registry_ensure || return 1
  python3 - "$CC_FILE" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); p = d.get("profiles", {}).get(sys.argv[2])
if p is None: sys.exit(3)
print("" if p.get("dir") is None else p["dir"])
PY
}

# Echo the logged-in account email for a config dir ("" if none / not logged in).
_cc_account_email() {
  local dir="$1" json
  if [ -z "$dir" ]; then json="$HOME/.claude.json"; else json="$dir/.claude.json"; fi
  [ -f "$json" ] || { echo ""; return; }
  python3 - "$json" <<'PY'
import json, sys
try:
    o = json.load(open(sys.argv[1]))
    print((o.get("oauthAccount") or {}).get("emailAddress") or "")
except Exception:
    print("")
PY
}

# Launch claude under a named profile. Uses a subshell so the parent shell's
# CLAUDE_CONFIG_DIR is never mutated.
cc_run() {
  local name="$1"; shift 2>/dev/null || true
  local dir; dir="$(_cc_profile_dir "$name")"
  local rc=$?
  if [ $rc -eq 3 ]; then
    echo "cc-switch: unknown profile '$name'. Try: cc-switch list" >&2
    return 1
  fi
  [ $rc -eq 0 ] || return 1
  dir="${dir/#\~/$HOME}"                              # expand leading ~
  if [ -n "$dir" ] && [ ! -d "$dir" ]; then mkdir -p "$dir"; fi
  if [ -z "$(_cc_account_email "$dir")" ]; then
    printf '\033[33mℹ  Profile "%s" is not logged in yet — run /login inside Claude.\033[0m\n' "$name" >&2
  fi
  if [ -z "$dir" ]; then
    ( unset CLAUDE_CONFIG_DIR; command claude "$@" )
  else
    ( export CLAUDE_CONFIG_DIR="$dir"; command claude "$@" )
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/posix_test.sh`
Expected: PASS — all five Task 2 assertions `ok`.

- [ ] **Step 5: Commit**

```bash
git add cc-switch.sh test/posix_test.sh
git commit -m "feat(posix): core CLAUDE_CONFIG_DIR launcher (subshell-isolated)"
```

---

## Task 3: POSIX management commands + alias edit

**Files:**
- Modify: `cc-switch.sh` (append)
- Test: `test/posix_test.sh` (append assertions)

**Interfaces:**
- Consumes: `CC_FILE`, `_cc_registry_ensure`, `_cc_profile_dir`.
- Produces: `_cc_valid_alias <s>`; `_cc_new <name> [dir] [--alias s]`; `_cc_remove <name> [--purge]`; `_cc_alias_set <s> <name>`; `_cc_alias_unset <s>`; `_cc_alias_pairs` (prints `alias<TAB>name`); `_cc_list`.

- [ ] **Step 1: Write the failing test** — append:

```bash
# --- Task 3: management ---
_cc_new team "" --alias cct
_cc_profile_dir team >/dev/null && ok "new creates profile" || no "new creates profile"
_cc_alias_pairs | grep -qP '^cct\tteam$' && ok "new --alias stored" || no "new --alias stored"
_cc_new bad --alias cct 2>/dev/null && no "duplicate alias rejected" || ok "duplicate alias rejected"
_cc_alias_unset cct; _cc_alias_pairs | grep -qP '^cct\t' && no "unalias removes" || ok "unalias removes"
_cc_alias_set ccteam team; _cc_alias_pairs | grep -qP '^ccteam\tteam$' && ok "alias add" || no "alias add"
_cc_remove personal 2>/dev/null && no "refuse remove default" || ok "refuse remove default"
_cc_remove team; _cc_profile_dir team >/dev/null 2>&1 && no "remove deletes profile" || ok "remove deletes profile"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/posix_test.sh`
Expected: FAIL — `_cc_new: command not found`.

- [ ] **Step 3: Write minimal implementation** — append to `cc-switch.sh`:

```bash
_cc_valid_alias() { printf '%s' "$1" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'; }

# print "alias<TAB>name" for every profile that has an alias
_cc_alias_pairs() {
  _cc_registry_ensure || return 1
  python3 - "$CC_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for n, p in d.get("profiles", {}).items():
    if p.get("alias"): print("%s\t%s" % (p["alias"], n))
PY
}

# new <name> [dir] [--alias <short>]
_cc_new() {
  local name="" dir="" alias=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --alias) alias="$2"; shift 2;;
      *) if [ -z "$name" ]; then name="$1"; elif [ -z "$dir" ]; then dir="$1"; fi; shift;;
    esac
  done
  [ -n "$name" ] || { echo "usage: cc-switch new <name> [dir] [--alias <short>]" >&2; return 1; }
  if [ -n "$alias" ] && ! _cc_valid_alias "$alias"; then
    echo "cc-switch: invalid alias '$alias' (use letters/digits/_/-, starting with a letter)" >&2; return 1
  fi
  _cc_registry_ensure || return 1
  python3 - "$CC_FILE" "$name" "$dir" "$alias" "$HOME" <<'PY' || return 1
import json, sys, os
path, name, dir_, alias, home = sys.argv[1:6]
d = json.load(open(path)); profs = d.setdefault("profiles", {})
if name in profs: sys.stderr.write("cc-switch: profile '%s' already exists.\n" % name); sys.exit(1)
if alias and any(p.get("alias") == alias for p in profs.values()):
    sys.stderr.write("cc-switch: alias '%s' is already in use.\n" % alias); sys.exit(1)
if not dir_: dir_ = "~/.claude-%s" % name
profs[name] = {"dir": dir_, "alias": alias or None, "desc": ""}
json.dump(d, open(path, "w"), indent=2)
real = os.path.join(home, dir_[2:]) if dir_.startswith("~/") else dir_
os.makedirs(real, exist_ok=True)
print("✔ Added profile '%s' → %s%s" % (name, dir_, ("  (alias: %s)" % alias) if alias else ""))
PY
  _cc_load_aliases
}

_cc_remove() {
  local name="" purge=""
  while [ $# -gt 0 ]; do case "$1" in --purge) purge=1; shift;; *) name="$1"; shift;; esac; done
  [ -n "$name" ] || { echo "usage: cc-switch remove <name> [--purge]" >&2; return 1; }
  _cc_registry_ensure || return 1
  local dir
  dir="$(python3 - "$CC_FILE" "$name" <<'PY' || exit $?
import json, sys
d = json.load(open(sys.argv[1])); n = sys.argv[2]; profs = d.get("profiles", {})
if n not in profs: sys.stderr.write("cc-switch: unknown profile '%s'.\n" % n); sys.exit(1)
if n == d.get("default"): sys.stderr.write("cc-switch: refusing to remove the default profile '%s'.\n" % n); sys.exit(1)
dir_ = profs[n].get("dir") or ""
del profs[n]; json.dump(d, open(sys.argv[1], "w"), indent=2); print(dir_)
PY
)" || return 1
  echo "✔ Unregistered profile '$name'."
  dir="${dir/#\~/$HOME}"
  if [ -n "$purge" ] && [ -n "$dir" ] && [ -d "$dir" ]; then rm -rf "$dir"; echo "  Deleted $dir"; fi
  _cc_load_aliases
}

# alias <short> <name>  /  unalias <short>
_cc_alias_set() {
  local alias="$1" name="$2"
  _cc_valid_alias "$alias" || { echo "cc-switch: invalid alias '$alias'" >&2; return 1; }
  command -v "$alias" >/dev/null 2>&1 && echo "cc-switch: note — '$alias' shadows an existing command." >&2
  _cc_registry_ensure || return 1
  python3 - "$CC_FILE" "$alias" "$name" <<'PY' || return 1
import json, sys
d = json.load(open(sys.argv[1])); alias, name = sys.argv[2], sys.argv[3]; profs = d.get("profiles", {})
if name not in profs: sys.stderr.write("cc-switch: unknown profile '%s'.\n" % name); sys.exit(1)
for n, p in profs.items():
    if p.get("alias") == alias and n != name: sys.stderr.write("cc-switch: alias '%s' already used by '%s'.\n" % (alias, n)); sys.exit(1)
profs[name]["alias"] = alias; json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
  _cc_load_aliases
}

_cc_alias_unset() {
  local alias="$1"
  _cc_registry_ensure || return 1
  python3 - "$CC_FILE" "$alias" <<'PY' || return 1
import json, sys
d = json.load(open(sys.argv[1])); alias = sys.argv[2]
for p in d.get("profiles", {}).values():
    if p.get("alias") == alias: p["alias"] = None
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
  unset -f "$alias" 2>/dev/null || true
  _cc_load_aliases
}

_cc_list() {
  _cc_registry_ensure || return 1
  local active="${CLAUDE_CONFIG_DIR-}"
  python3 - "$CC_FILE" "$HOME" "$active" <<'PY'
import json, sys, os
d = json.load(open(sys.argv[1])); home, active = sys.argv[2], sys.argv[3]
print("  %-10s %-8s %-28s %s" % ("Profile", "Alias", "Dir", "Account"))
for n, p in d.get("profiles", {}).items():
    raw = p.get("dir"); dir_ = "" if raw is None else raw.replace("~", home, 1)
    disp = "%s/.claude (default)" % home if raw is None else raw
    is_active = (not active and raw is None) or (active and dir_ and os.path.normpath(active) == os.path.normpath(dir_))
    jpath = os.path.join(dir_ or os.path.join(home, ".claude"), ".claude.json")
    email = ""
    try:
        email = (json.load(open(jpath)).get("oauthAccount") or {}).get("emailAddress") or ""
    except Exception:
        email = "(not logged in)"
    print(" %s %-10s %-8s %-28s %s" % ("●" if is_active else " ", n, p.get("alias") or "-", disp, email))
PY
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/posix_test.sh`
Expected: PASS — all Task 3 assertions `ok`. (Defines `_cc_load_aliases` in Task 4; until then add a temporary `_cc_load_aliases(){ :; }` at the top of the test's sourced section — remove after Task 4. The test sources the real file, so add the stub only if Task 4 not yet merged.)

- [ ] **Step 5: Commit**

```bash
git add cc-switch.sh test/posix_test.sh
git commit -m "feat(posix): new/remove/alias/unalias/list management commands"
```

---

## Task 4: POSIX alias generation, dispatcher, shortcuts + installer

**Files:**
- Modify: `cc-switch.sh` (append)
- Create: `install.sh`
- Test: `test/posix_test.sh` (append)

**Interfaces:**
- Consumes: everything above.
- Produces: `_cc_load_aliases` (defines a function per aliased profile); `ccx <name> [args]`; `cc-switch` dispatcher; auto-load on source. `install.sh` copies the script and wires rc files.

- [ ] **Step 1: Write the failing test** — append:

```bash
# --- Task 4: alias generation + dispatcher ---
_cc_load_aliases
type ccw >/dev/null 2>&1 && ok "ccw function generated" || no "ccw function generated"
export CC_TEST_OUT="$TMP/out.alias"
ccw --foo
grep -q "CLAUDE_CONFIG_DIR=$HOME/.claude-work" "$CC_TEST_OUT" && ok "generated alias launches" || no "generated alias launches"
cc-switch list >/dev/null 2>&1 && ok "dispatcher list works" || no "dispatcher list works"
```

Also remove the temporary `_cc_load_aliases(){ :; }` stub if it was added in Task 3.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/posix_test.sh`
Expected: FAIL — real `_cc_load_aliases` / `cc-switch` not yet defined.

- [ ] **Step 3: Write minimal implementation** — append to `cc-switch.sh`:

```bash
# (Re)define one shell function per profile that has an alias.
_cc_load_aliases() {
  _cc_has_py || return 0
  local alias name
  while IFS="$(printf '\t')" read -r alias name; do
    [ -n "$alias" ] || continue
    eval "${alias}() { cc_run '${name}' \"\$@\"; }"
  done <<EOF
$(_cc_alias_pairs)
EOF
}

ccx() { local n="$1"; shift 2>/dev/null || true; cc_run "$n" "$@"; }

cc-switch() {
  local cmd="${1:-list}"; shift 2>/dev/null || true
  case "$cmd" in
    list|ls|status) _cc_list;;
    new)            _cc_new "$@";;
    remove|rm)      _cc_remove "$@";;
    run)            cc_run "$@";;
    alias)          _cc_alias_set "$@";;
    unalias)        _cc_alias_unset "$@";;
    path)           _cc_profile_dir "$1";;
    *) cat <<'HELP'
cc-switch — multi-account launcher for Claude Code (Linux/macOS)

  cc-switch list                      profiles + active account
  cc-switch new <name> [dir] [--alias <short>]   register a profile (+shortcut)
  cc-switch remove <name> [--purge]   unregister (optionally delete its dir)
  cc-switch alias <short> <name>      add/change a shortcut
  cc-switch unalias <short>           drop a shortcut
  cc-switch run <name> [args]         launch under a profile

Shortcuts are generated from the registry, e.g.  ccp  ccw  ccx <name>
HELP
    ;;
  esac
}

# Generate alias functions when this file is sourced.
_cc_load_aliases 2>/dev/null || true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/posix_test.sh`
Expected: PASS — all assertions `ok`. Also verify zsh syntax if available: `zsh -n cc-switch.sh` (skip if zsh absent on this machine; the user verifies on macOS).

- [ ] **Step 5: Create `install.sh`:**

```bash
#!/usr/bin/env bash
# Install cc-switch for bash/zsh (Linux/macOS). No sudo.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${CC_SWITCH_HOME:-$HOME/.cc-switch}"
mkdir -p "$DEST"
cp "$SRC/cc-switch.sh" "$DEST/cc-switch.sh"
echo "✔ Installed → $DEST/cc-switch.sh"

LINE="source \"$DEST/cc-switch.sh\""
MARK="# cc-switch: multi-account Claude Code"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -e "$rc" ] || { case "$rc" in *zshrc) [ -n "${ZSH_VERSION:-}" ] || continue;; esac; }
  if [ -e "$rc" ] && grep -qF "$DEST/cc-switch.sh" "$rc"; then
    echo "• already wired in $rc"
  else
    printf '\n%s\n%s\n' "$MARK" "$LINE" >> "$rc"
    echo "✔ Added source line to $rc"
  fi
done
# seed/migrate now
( CC_SWITCH_HOME="$DEST"; . "$DEST/cc-switch.sh"; cc-switch list ) || true
echo "Open a NEW terminal, then:  cc-switch list   ·   ccp   ·   ccw"
```

- [ ] **Step 6: Commit**

```bash
git add cc-switch.sh install.sh test/posix_test.sh
git commit -m "feat(posix): alias generation, dispatcher, shortcuts + install.sh"
```

---

## Task 5: PowerShell parity (migration + registry-driven aliases + alias/unalias + new --alias)

**Files:**
- Modify: `cc-switch.psm1`
- Modify: `cc-switch.psd1:3` (version), `:6` (description), `:8` (exports), `:13` (tags)
- Create: `test/ps_test.ps1`

**Interfaces:**
- Consumes: existing `Get-CcProfiles`, `Use-ClaudeProfile`.
- Produces: `CC_SWITCH_HOME` override; v2 migration inside `Get-CcProfiles`; `Set-CcAlias`/`Remove-CcAlias`; `New-CcProfile -Alias`; `Register-CcAliases` (generates functions); `list` shows an Alias column.

- [ ] **Step 1: Write the failing test** — create `test/ps_test.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ("ccsw_" + [guid]::NewGuid())
$env:CC_SWITCH_HOME = Join-Path $tmp '.cc-switch'
New-Item -ItemType Directory -Force -Path $env:CC_SWITCH_HOME | Out-Null
$reg = Join-Path $env:CC_SWITCH_HOME 'profiles.json'
# a v1 registry with NO aliases
'{"version":1,"default":"personal","profiles":{"personal":{"dir":null,"desc":"p"},"work":{"dir":"~/.claude-work","desc":"w"}}}' |
  Set-Content -LiteralPath $reg -Encoding utf8

Import-Module "$PSScriptRoot/../cc-switch.psm1" -Force
$cfg = Get-CcProfiles
$pass = $true
if ($cfg.version -ne 2) { Write-Host "NOT OK - migrated to v2"; $pass=$false } else { Write-Host "ok - migrated to v2" }
if ($cfg.profiles['personal'].alias -ne 'ccp') { Write-Host "NOT OK - ccp backfilled"; $pass=$false } else { Write-Host "ok - ccp backfilled" }
if ($cfg.profiles['work'].alias -ne 'ccw') { Write-Host "NOT OK - ccw backfilled"; $pass=$false } else { Write-Host "ok - ccw backfilled" }
if (-not (Test-Path "$reg.bak")) { Write-Host "NOT OK - backup written"; $pass=$false } else { Write-Host "ok - backup written" }

New-CcProfile -Name team -Alias cct
$cfg = Get-CcProfiles
if ($cfg.profiles['team'].alias -ne 'cct') { Write-Host "NOT OK - new -Alias"; $pass=$false } else { Write-Host "ok - new -Alias" }
if (-not (Get-Command cct -ErrorAction SilentlyContinue)) { Write-Host "NOT OK - cct function generated"; $pass=$false } else { Write-Host "ok - cct function generated" }

Remove-Module cc-switch -Force; Remove-Item -Recurse -Force $tmp
if (-not $pass) { exit 1 }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pwsh -NoProfile -File test/ps_test.ps1`
Expected: FAIL — version stays 1 / no `alias` property / `cct` not generated.

- [ ] **Step 3: Write the implementation.**

3a. In `cc-switch.psm1`, make the config path overridable (replace lines 22-23):

```powershell
$script:ConfigDir  = if ($env:CC_SWITCH_HOME) { $env:CC_SWITCH_HOME } else { Join-Path $HOME '.cc-switch' }
$script:ConfigFile = Join-Path $script:ConfigDir 'profiles.json'
```

3b. Replace `Get-CcProfiles` (lines 27-44) to seed v2 and migrate v1→v2:

```powershell
function Get-CcProfiles {
    [CmdletBinding()] param()
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
        $seed = [ordered]@{
            version  = 2
            default  = 'personal'
            profiles = [ordered]@{
                personal = [ordered]@{ dir = $null;                           alias = 'ccp'; desc = 'Personal account (default ~/.claude)' }
                work     = [ordered]@{ dir = (Join-Path $HOME '.claude-work'); alias = 'ccw'; desc = 'Work account' }
            }
        }
        Save-CcProfiles -Data $seed
        return $seed
    }
    $raw = Get-Content -Raw -LiteralPath $script:ConfigFile | ConvertFrom-Json -AsHashtable
    if (-not $raw.ContainsKey('version') -or [int]$raw.version -lt 2) {
        Copy-Item -LiteralPath $script:ConfigFile -Destination "$($script:ConfigFile).bak" -Force
        foreach ($pair in @{ personal = 'ccp'; work = 'ccw' }.GetEnumerator()) {
            if ($raw.profiles.ContainsKey($pair.Key) -and -not $raw.profiles[$pair.Key].ContainsKey('alias')) {
                $raw.profiles[$pair.Key]['alias'] = $pair.Value
            }
        }
        $raw['version'] = 2
        Save-CcProfiles -Data $raw
    }
    return $raw
}
```

3c. Add `-Alias` to `New-CcProfile` (replace lines 148-163):

```powershell
function New-CcProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][string]$Dir,
        [string]$Alias = '',
        [string]$Desc = ''
    )
    $cfg = Get-CcProfiles
    if ($cfg.profiles.ContainsKey($Name)) { throw "Profile '$Name' already exists." }
    if ($Alias) {
        if ($Alias -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') { throw "Invalid alias '$Alias'." }
        foreach ($p in $cfg.profiles.Values) { if ($p.alias -eq $Alias) { throw "Alias '$Alias' is already in use." } }
    }
    if ([string]::IsNullOrEmpty($Dir)) { $Dir = Join-Path $HOME ".claude-$Name" }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $cfg.profiles[$Name] = [ordered]@{ dir = $Dir; alias = ($Alias ? $Alias : $null); desc = $Desc }
    Save-CcProfiles -Data $cfg
    Register-CcAliases
    Write-Host "✔ Added profile '$Name' → $Dir$(if ($Alias) { "  (alias: $Alias)" })" -ForegroundColor Green
}
```

3d. Add alias management + generation (insert before the `# --- daily shortcuts` section, replacing the hard-coded `ccp`/`ccw`/`ccx` block at lines 218-229):

```powershell
function Set-CcAlias {
    [CmdletBinding()] param(
        [Parameter(Mandatory, Position=0)][string]$Alias,
        [Parameter(Mandatory, Position=1)][string]$Name)
    if ($Alias -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') { throw "Invalid alias '$Alias'." }
    $cfg = Get-CcProfiles
    if (-not $cfg.profiles.ContainsKey($Name)) { throw "Unknown profile '$Name'." }
    foreach ($kv in $cfg.profiles.GetEnumerator()) {
        if ($kv.Value.alias -eq $Alias -and $kv.Key -ne $Name) { throw "Alias '$Alias' already used by '$($kv.Key)'." }
    }
    if (Get-Command $Alias -ErrorAction SilentlyContinue) { Write-Host "note — '$Alias' shadows an existing command." -ForegroundColor Yellow }
    $cfg.profiles[$Name].alias = $Alias
    Save-CcProfiles -Data $cfg
    Register-CcAliases
}

function Remove-CcAlias {
    [CmdletBinding()] param([Parameter(Mandatory, Position=0)][string]$Alias)
    $cfg = Get-CcProfiles
    foreach ($p in $cfg.profiles.Values) { if ($p.alias -eq $Alias) { $p.alias = $null } }
    Save-CcProfiles -Data $cfg
    if (Test-Path "Function:\$Alias") { Remove-Item "Function:\$Alias" }
    Register-CcAliases
}

# Generate one global function per aliased profile (replaces hard-coded ccp/ccw).
function Register-CcAliases {
    [CmdletBinding()] param()
    $cfg = Get-CcProfiles
    foreach ($kv in $cfg.profiles.GetEnumerator()) {
        $alias = $kv.Value.alias
        if (-not $alias) { continue }
        $name = $kv.Key
        $body = "param([Parameter(ValueFromRemainingArguments=`$true)][object[]]`$Rest) Use-ClaudeProfile -Name '$name' @Rest"
        Set-Item -Path "Function:\global:$alias" -Value ([ScriptBlock]::Create($body))
    }
}

function ccx {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name,
          [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest)
    Use-ClaudeProfile -Name $Name @Rest
}
```

3e. Wire the new dispatcher verbs in `Invoke-CcSwitch` (add cases alongside line 198):

```powershell
        'alias'   { Set-CcAlias @rest }
        'unalias' { Remove-CcAlias @rest }
```

3f. Generate aliases at import — append near the bottom (after `Set-Alias -Name cc-switch ...`, line 231):

```powershell
Register-CcAliases
```

3g. Update `Export-ModuleMember` (lines 233-236) to export the new functions and drop the now-generated `ccp`/`ccw`:

```powershell
Export-ModuleMember -Function `
    Use-ClaudeProfile, Show-CcStatus, New-CcProfile, Remove-CcProfile, Invoke-CcSwitch, `
    Get-CcProfiles, Get-CcAccountEmail, Set-CcAlias, Remove-CcAlias, Register-CcAliases, ccx `
    -Alias cc-switch
```

(Generated alias functions are created in the global scope by `Register-CcAliases`, so they need not be module exports.)

3h. Add an `Alias` column to `Show-CcStatus` (in the `[pscustomobject]` at lines 138-143, add after `Profile`):

```powershell
            Alias   = if ($p.alias) { $p.alias } else { '-' }
```

3i. Update `cc-switch.psd1`: line 3 `ModuleVersion = '0.2.0'`; line 6 description → `'Run multiple Claude Code accounts on one machine (Windows/macOS/Linux) via CLAUDE_CONFIG_DIR isolation.'`; line 8 `FunctionsToExport` → `@('Use-ClaudeProfile','Show-CcStatus','New-CcProfile','Remove-CcProfile','Invoke-CcSwitch','Get-CcProfiles','Get-CcAccountEmail','Set-CcAlias','Remove-CcAlias','Register-CcAliases','ccx')`; line 13 tags add `'macos','linux'`.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File test/ps_test.ps1`
Expected: PASS — all `ok` lines; exit 0.

- [ ] **Step 5: Commit**

```bash
git add cc-switch.psm1 cc-switch.psd1 test/ps_test.ps1
git commit -m "feat(pwsh): registry-driven aliases, v1->v2 migration, alias/unalias parity"
```

---

## Task 6: READMEs + cross-platform docs

**Files:**
- Modify: `README.md`

**Interfaces:** docs only.

- [ ] **Step 1: Update `README.md`.** Make these concrete changes:

  1. Badges (lines 5-8): change `platform-Windows-0078D6` to `platform-Windows%20|%20macOS%20|%20Linux-0078D6`; keep PowerShell badge; add `![bash/zsh](https://img.shields.io/badge/shell-bash%20%7C%20zsh-4EAA25)`.
  2. Subtitle (line 3): "on **one Windows machine**" → "on **one machine** (Windows · macOS · Linux)".
  3. Add an **Install** split:

```markdown
### macOS / Linux (bash · zsh)
```bash
git clone https://github.com/southglory/cc-switch
cd cc-switch
bash install.sh
```
Adds `source ~/.cc-switch/cc-switch.sh` to your `~/.bashrc` / `~/.zshrc`. Open a new terminal.

### Windows (PowerShell 7+)
```powershell
git clone https://github.com/southglory/cc-switch
cd cc-switch
pwsh -File .\Install.ps1
```
```

  4. Add a **Your own shortcuts** section after "More profiles":

```markdown
## Your own shortcuts

`ccp` (personal) and `ccw` (work) are just seeded defaults — rename or add your own:

```bash
cc-switch new client-x --alias ccx1   # profile + shortcut in one step
cc-switch alias ccx1 client-x         # add/zhange a shortcut later
cc-switch unalias ccw                 # drop one you don't want
ccx1                                  # launch it
```
Shortcuts live in `~/.cc-switch/profiles.json` and are generated for every shell. The same registry is shared by the Windows and macOS/Linux versions.
```

  5. Requirements: note `python3` is required on macOS/Linux (JSON engine). Update the Requirements list to: Windows (PowerShell 7+) **or** macOS/Linux (bash/zsh + python3); Claude Code 2.1+.
  6. Fix the typo introduced above: "add/zhange" → "add/change".

- [ ] **Step 2: Verify rendering** — `bash -n install.sh` already passed; visually confirm the README code fences are balanced (no stray triple-backticks).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: cross-platform README (macOS/Linux install + custom shortcuts)"
```

---

## Self-Review

**Spec coverage:**
- POSIX port (cc-switch.sh) → Tasks 1-4 ✓
- Custom aliases (new --alias / alias / unalias, registry-driven generation) → Tasks 3-4 (POSIX), Task 5 (PS) ✓
- Seeded removable defaults ccp/ccw → seed in Task 1 (POSIX) / Task 5 (PS) ✓
- Shared profiles.json schema v2 + alias field → Tasks 1, 5 ✓
- v1→v2 non-destructive migration + backup → Task 1 (POSIX), Task 5 (PS) ✓
- Subshell env isolation → Task 2 ✓
- Not-logged-in hint → Task 2 ✓
- Install (POSIX) → Task 4; Install (PS) unchanged, doc note → Task 6 ✓
- READMEs both platforms + badges → Task 6 ✓
- python3 dependency documented → Task 6 (Requirements) ✓
- CC_SWITCH_HOME test override → Tasks 1 (POSIX), 5 (PS) ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. (Task 3 notes a temporary `_cc_load_aliases` stub only as a test-ordering aid, removed in Task 4.)

**Type/name consistency:** `cc_run`, `_cc_registry_ensure`, `_cc_profile_dir`, `_cc_alias_pairs`, `_cc_load_aliases`, `_cc_new/_cc_remove/_cc_alias_set/_cc_alias_unset/_cc_list` used consistently across POSIX tasks. PowerShell: `Get-CcProfiles`, `New-CcProfile -Alias`, `Set-CcAlias`, `Remove-CcAlias`, `Register-CcAliases` consistent across Task 5 sub-steps and the psd1 export list. Registry keys `version/default/profiles/<name>/{dir,alias,desc}` identical on both platforms.
