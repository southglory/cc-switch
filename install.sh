#!/usr/bin/env bash
# Install cc-switch for bash/zsh (Linux/macOS). No sudo.
# Works locally (git clone) or piped:  curl -fsSL <raw>/install.sh | bash
set -euo pipefail
RAW="https://raw.githubusercontent.com/southglory/cc-switch/main"
SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
DEST="${CC_SWITCH_HOME:-$HOME/.cc-switch}"
mkdir -p "$DEST"
if [ -n "$SRC" ] && [ -f "$SRC/cc-switch.sh" ]; then
  cp "$SRC/cc-switch.sh" "$DEST/cc-switch.sh"          # local clone
else
  curl -fsSL "$RAW/cc-switch.sh" -o "$DEST/cc-switch.sh"   # piped (no local copy)
fi
echo "✔ Installed → $DEST/cc-switch.sh"

# Install marker so other tools (e.g. the Claude Multi-Account Status Bar
# extension) can tell cc-switch is actually installed.
printf '{"tool":"cc-switch","version":"0.2.3","platform":"posix"}\n' > "$DEST/installed.json"

LINE="source \"$DEST/cc-switch.sh\""
MARK="# cc-switch: multi-account Claude Code"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -e "$rc" ] || continue
  if grep -qF "$DEST/cc-switch.sh" "$rc"; then
    echo "• already wired in $rc"
  else
    printf '\n%s\n%s\n' "$MARK" "$LINE" >> "$rc"
    echo "✔ Added source line to $rc"
  fi
done

# seed/migrate the registry now
( CC_SWITCH_HOME="$DEST"; . "$DEST/cc-switch.sh"; cc-switch list ) || true
echo "Open a NEW terminal, then:  cc-switch list   ·   ccp   ·   ccw"
