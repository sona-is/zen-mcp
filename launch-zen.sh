#!/bin/bash
# Launch Zen Browser with remote debugging on an ISOLATED, throwaway profile so
# the zen-mcp server (and the LLM agent driving it) never touches your everyday
# Zen profile, cookies, or logged-in sessions.
#
# Safe to run alongside your normal Zen: it does NOT kill any existing instance.
#
# Config (all optional, via env):
#   ZEN_DEBUG_PORT  debugging port                       (default: 9222)
#   ZEN_PROFILE     throwaway profile directory          (default: /tmp/zen-mcp)
#   ZEN_BIN         explicit Zen executable to launch    (overrides the options below)
#   ZEN_SRC_APP     source Zen.app to launch/clone from  (default: /Applications/Zen.app)
#
#   App identity (optional): give the throwaway instance its own name + icon in
#   the macOS app switcher / Dock by launching a renamed clone of Zen.app:
#     ZEN_APP_NAME  e.g. "Zen MCP" — enables the renamed clone (default: unset)
#     ZEN_APP_DIR   where to keep the clone               (default: ~/Applications)
#     ZEN_APP_ID    CFBundleIdentifier for the clone      (default: app.zen-browser.mcp)
#   The clone is built once via an APFS clone (cp -c, ~0 extra disk) and only
#   rebuilt when the source Zen version changes. Editing the bundle requires an
#   ad-hoc re-sign; if macOS refuses the clone, unset ZEN_APP_NAME or set ZEN_BIN.

set -euo pipefail

PORT="${ZEN_DEBUG_PORT:-9222}"
PROFILE="${ZEN_PROFILE:-/tmp/zen-mcp}"
ZEN_SRC_APP="${ZEN_SRC_APP:-/Applications/Zen.app}"
ZEN_APP_NAME="${ZEN_APP_NAME:-}"
ZEN_APP_DIR="${ZEN_APP_DIR:-$HOME/Applications}"
ZEN_APP_ID="${ZEN_APP_ID:-app.zen-browser.mcp}"

# Read an Info.plist key from an .app bundle (empty string if absent).
plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Build/refresh a renamed clone of ZEN_SRC_APP so the throwaway instance appears
# as its own app (own name, icon, Cmd+Tab entry). Idempotent: rebuilds only when
# the clone is missing or the source version has changed. Sets nothing; the
# caller points ZEN_BIN at "$MCP_APP/Contents/MacOS/zen".
ensure_renamed_app() {
  local src="$ZEN_SRC_APP" dst="$MCP_APP"
  if [ ! -d "$src" ]; then
    echo "Error: source app not found: $src (set ZEN_SRC_APP)." >&2
    exit 1
  fi

  local src_ver dst_ver
  src_ver="$(plist_get "$src" CFBundleShortVersionString)"
  dst_ver="$(plist_get "$dst" CFBundleShortVersionString)"

  if [ -d "$dst" ] && [ -n "$src_ver" ] && [ "$src_ver" = "$dst_ver" ]; then
    return 0  # already current
  fi

  echo "Building renamed app '$ZEN_APP_NAME' from $src (version ${src_ver:-unknown})..."
  mkdir -p "$ZEN_APP_DIR"
  rm -rf "$dst"
  # APFS clone: instant, ~0 extra disk. Fall back to a full copy off-APFS.
  if ! cp -c -R "$src" "$dst" 2>/dev/null; then
    rm -rf "$dst"
    cp -R "$src" "$dst"
  fi

  local pl="$dst/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $ZEN_APP_NAME" "$pl" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $ZEN_APP_NAME" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $ZEN_APP_NAME" "$pl" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $ZEN_APP_NAME" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ZEN_APP_ID" "$pl" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $ZEN_APP_ID" "$pl"

  # Editing Info.plist invalidates the signature; ad-hoc re-sign + clear
  # quarantine so macOS will launch the clone.
  xattr -dr com.apple.quarantine "$dst" 2>/dev/null || true
  if ! codesign --force --deep --sign - "$dst" 2>/dev/null; then
    echo "Warning: ad-hoc re-sign of '$dst' failed. It may still launch; if macOS" >&2
    echo "refuses it, unset ZEN_APP_NAME or set ZEN_BIN to the system Zen binary." >&2
  fi
}

# If something is already serving the debug port, reuse it rather than launching
# a duplicate (avoids a profile-lock clash with a previous zen-mcp instance).
# Done first so we never build the clone needlessly.
if curl -s "http://127.0.0.1:${PORT}/json/version" > /dev/null 2>&1; then
    echo "Zen is already listening on port ${PORT}; reusing it."
    exit 0
fi

# Resolve which Zen binary to launch (may build/refresh the renamed clone).
if [ -n "${ZEN_BIN:-}" ]; then
    : # explicit override — use as-is
elif [ -n "$ZEN_APP_NAME" ]; then
    MCP_APP="$ZEN_APP_DIR/$ZEN_APP_NAME.app"
    ensure_renamed_app
    ZEN_BIN="$MCP_APP/Contents/MacOS/zen"
else
    ZEN_BIN="$ZEN_SRC_APP/Contents/MacOS/zen"
fi

if [ ! -x "$ZEN_BIN" ]; then
    echo "Error: Zen executable not found or not executable: $ZEN_BIN" >&2
    echo "Set ZEN_BIN to the Zen binary path and retry." >&2
    exit 1
fi

mkdir -p "$PROFILE"

echo "Launching Zen with remote debugging on an isolated profile:"
echo "  binary  : $ZEN_BIN"
echo "  profile : $PROFILE"
echo "  port    : $PORT"

# --profile <dir>          dedicated throwaway profile (no personal logins)
# --remote-debugging-port  enables the WebDriver BiDi WebSocket zen-mcp uses
# --no-remote              force a SEPARATE instance, so these flags are not
#                          handed to (and ignored by) your running daily Zen
nohup "$ZEN_BIN" \
    --profile "$PROFILE" \
    --remote-debugging-port "$PORT" \
    --no-remote \
    > /dev/null 2>&1 &
ZEN_PID=$!

echo "Zen launched (pid ${ZEN_PID}). Waiting for the debug port to come up..."

# Wait for the debugging port to become available
for _ in $(seq 1 30); do
    if curl -s "http://127.0.0.1:${PORT}/json/version" > /dev/null 2>&1; then
        echo "Zen is ready on port ${PORT}!"
        VERSION_JSON="$(curl -s "http://127.0.0.1:${PORT}/json/version" 2>/dev/null || true)"
        echo "$VERSION_JSON" | python3 -m json.tool 2>/dev/null || echo "$VERSION_JSON"
        exit 0
    fi
    # If Zen exited early (e.g. a profile lock), surface it instead of looping.
    if ! kill -0 "$ZEN_PID" 2>/dev/null; then
        echo "Error: Zen exited before the debug port came up." >&2
        echo "If a previous zen-mcp instance is using ${PROFILE}, close it or set" >&2
        echo "ZEN_PROFILE to a fresh directory and retry." >&2
        exit 1
    fi
    sleep 1
done

echo "Warning: Zen did not open the debug port on ${PORT} within 30s." >&2
echo "Check that ${ZEN_BIN##*/} supports --remote-debugging-port." >&2
exit 1
