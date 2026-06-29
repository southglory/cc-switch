# cc-switch.sh — run multiple Claude Code accounts on Linux/macOS (bash/zsh).
# Sourced from ~/.bashrc or ~/.zshrc. Shares ~/.cc-switch/profiles.json with the
# Windows PowerShell module. JSON is handled by python3.

CC_DIR="${CC_SWITCH_HOME:-$HOME/.cc-switch}"
CC_FILE="$CC_DIR/profiles.json"

_cc_has_py() { command -v python3 >/dev/null 2>&1; }
# Always run our python in UTF-8 mode so the ✔/● output is locale-independent.
_cc_py() { PYTHONUTF8=1 python3 "$@"; }
_cc_need_py() {
  _cc_has_py && return 0
  echo "cc-switch: python3 is required (used to read ~/.cc-switch/profiles.json)." >&2
  return 1
}

# Create + seed the registry if missing; migrate v1 -> v2 (non-destructive).
_cc_registry_ensure() {
  _cc_need_py || return 1
  _cc_py - "$CC_FILE" <<'PY'
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

# Echo a profile's dir ("" for the default/null), exit 3 if the profile is unknown.
_cc_profile_dir() {
  _cc_registry_ensure || return 1
  _cc_py - "$CC_FILE" "$1" <<'PY'
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
  _cc_py - "$json" <<'PY'
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
    printf '\033[33m\xe2\x84\xb9  Profile "%s" is not logged in yet \xe2\x80\x94 run /login inside Claude.\033[0m\n' "$name" >&2
  fi
  if [ -z "$dir" ]; then
    ( unset CLAUDE_CONFIG_DIR; command claude "$@" )
  else
    ( export CLAUDE_CONFIG_DIR="$dir"; command claude "$@" )
  fi
}

# --- management ------------------------------------------------------------

_cc_valid_alias() { printf '%s' "$1" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'; }

# print "alias<TAB>name" for every profile that has an alias
_cc_alias_pairs() {
  _cc_registry_ensure || return 1
  _cc_py - "$CC_FILE" <<'PY'
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
  _cc_py - "$CC_FILE" "$name" "$dir" "$alias" "$HOME" <<'PY' || return 1
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
  dir="$(_cc_py - "$CC_FILE" "$name" <<'PY' || exit $?
import json, sys
d = json.load(open(sys.argv[1])); n = sys.argv[2]; profs = d.get("profiles", {})
if n not in profs: sys.stderr.write("cc-switch: unknown profile '%s'.\n" % n); sys.exit(1)
if n == d.get("default"): sys.stderr.write("cc-switch: refusing to remove the default profile '%s'.\n" % n); sys.exit(1)
dir_ = profs[n].get("dir") or ""
del profs[n]; json.dump(d, open(sys.argv[1], "w"), indent=2); print(dir_)
PY
)" || return 1
  printf '\xe2\x9c\x94 Unregistered profile "%s".\n' "$name"
  dir="${dir/#\~/$HOME}"
  if [ -n "$purge" ] && [ -n "$dir" ] && [ -d "$dir" ]; then rm -rf "$dir"; echo "  Deleted $dir"; fi
  _cc_load_aliases
}

# alias <short> <name>  /  unalias <short>
_cc_alias_set() {
  local alias="$1" name="$2"
  _cc_valid_alias "$alias" || { echo "cc-switch: invalid alias '$alias'" >&2; return 1; }
  command -v "$alias" >/dev/null 2>&1 && printf "cc-switch: note \xe2\x80\x94 '%s' shadows an existing command.\n" "$alias" >&2
  _cc_registry_ensure || return 1
  _cc_py - "$CC_FILE" "$alias" "$name" <<'PY' || return 1
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
  _cc_py - "$CC_FILE" "$alias" <<'PY' || return 1
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
  _cc_py - "$CC_FILE" "$HOME" "$active" <<'PY'
import json, sys, os
d = json.load(open(sys.argv[1])); home, active = sys.argv[2], sys.argv[3]
print("  %-10s %-8s %-28s %s" % ("Profile", "Alias", "Dir", "Account"))
for n, p in d.get("profiles", {}).items():
    raw = p.get("dir"); dir_ = "" if raw is None else raw.replace("~", home, 1)
    disp = "%s/.claude (default)" % home if raw is None else raw
    is_active = (not active and raw is None) or (active and dir_ and os.path.normpath(active) == os.path.normpath(dir_))
    jpath = os.path.join(dir_ or os.path.join(home, ".claude"), ".claude.json")
    try:
        email = (json.load(open(jpath)).get("oauthAccount") or {}).get("emailAddress") or ""
    except Exception:
        email = "(not logged in)"
    print(" %s %-10s %-8s %-28s %s" % ("●" if is_active else " ", n, p.get("alias") or "-", disp, email))
PY
}

# --- alias generation, dispatcher, shortcuts -------------------------------

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

# Ensure <dir>/.gitignore ignores .cc-local/ (create or append; idempotent).
_cc_gitignore_local() {
  local gi="$1/.gitignore"
  if [ ! -f "$gi" ]; then
    printf '# cc-switch project-local account (keep out of git)\n.cc-local/\n' > "$gi" 2>/dev/null || true
  elif ! grep -qxF '.cc-local/' "$gi" 2>/dev/null; then
    printf '.cc-local/\n' >> "$gi" 2>/dev/null || true
  fi
}

# Run Claude Code with a PROJECT-LOCAL config dir ($PWD/.cc-local), isolated per
# directory. Not a registered profile — never in `cc-switch list`.
cc_local() {
  local dir="$PWD/.cc-local"
  [ -d "$dir" ] || mkdir -p "$dir"
  _cc_gitignore_local "$PWD"
  if [ -z "$(_cc_account_email "$dir")" ]; then
    printf '\033[33m\xe2\x84\xb9  Local account in ./.cc-local is not logged in yet \xe2\x80\x94 run /login inside Claude.\033[0m\n' >&2
  fi
  ( export CLAUDE_CONFIG_DIR="$dir"; command claude "$@" )
}

cclocal() { cc_local "$@"; }

cc-switch() {
  local cmd="${1:-list}"; shift 2>/dev/null || true
  case "$cmd" in
    list|ls|status) _cc_list;;
    new)            _cc_new "$@";;
    remove|rm)      _cc_remove "$@";;
    run)            cc_run "$@";;
    local)          cc_local "$@";;
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
  cc-switch local [args]              launch a PROJECT-LOCAL account ($PWD/.cc-local)

Shortcuts are generated from the registry, e.g.  ccp  ccw  ccx <name>
Project-local (current dir only, not a saved profile):  cclocal
HELP
    ;;
  esac
}

# Generate alias functions when this file is sourced.
_cc_load_aliases 2>/dev/null || true
