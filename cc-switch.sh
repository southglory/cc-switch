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
    printf '\033[33m\xe2\x84\xb9  Profile "%s" is not logged in yet \xe2\x80\x94 run /login inside Claude.\033[0m\n' "$name" >&2
  fi
  if [ -z "$dir" ]; then
    ( unset CLAUDE_CONFIG_DIR; command claude "$@" )
  else
    ( export CLAUDE_CONFIG_DIR="$dir"; command claude "$@" )
  fi
}
