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
