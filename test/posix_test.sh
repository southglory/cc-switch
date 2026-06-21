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

# --- Task 2: launcher sets/unsets CLAUDE_CONFIG_DIR, restores parent env ---
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

# --- Task 3: management ---
_cc_new team "" --alias cct
_cc_profile_dir team >/dev/null && ok "new creates profile" || no "new creates profile"
_cc_alias_pairs | grep -qP '^cct\tteam$' && ok "new --alias stored" || no "new --alias stored"
_cc_new bad --alias cct 2>/dev/null && no "duplicate alias rejected" || ok "duplicate alias rejected"
_cc_alias_unset cct; _cc_alias_pairs | grep -qP '^cct\t' && no "unalias removes" || ok "unalias removes"
_cc_alias_set ccteam team; _cc_alias_pairs | grep -qP '^ccteam\tteam$' && ok "alias add" || no "alias add"
_cc_remove personal 2>/dev/null && no "refuse remove default" || ok "refuse remove default"
_cc_remove team; _cc_profile_dir team >/dev/null 2>&1 && no "remove deletes profile" || ok "remove deletes profile"

# --- Task 4: alias generation + dispatcher ---
_cc_load_aliases
type ccw >/dev/null 2>&1 && ok "ccw function generated" || no "ccw function generated"
export CC_TEST_OUT="$TMP/out.alias"
ccw --foo
grep -q "CLAUDE_CONFIG_DIR=$HOME/.claude-work" "$CC_TEST_OUT" && ok "generated alias launches" || no "generated alias launches"
cc-switch list >/dev/null 2>&1 && ok "dispatcher list works" || no "dispatcher list works"

# --- install.sh writes the install marker ---
IHOME="$(mktemp -d)"
HOME="$IHOME" CC_SWITCH_HOME="$IHOME/.cc-switch" bash "$HERE/install.sh" >/dev/null 2>&1
[ -f "$IHOME/.cc-switch/installed.json" ] && ok "install.sh writes marker" || no "install.sh writes marker"
grep -q '"tool":"cc-switch"' "$IHOME/.cc-switch/installed.json" 2>/dev/null && ok "marker has tool field" || no "marker has tool field"
rm -rf "$IHOME"

exit $fail
