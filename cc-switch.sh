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
