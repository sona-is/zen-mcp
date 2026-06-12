#!/bin/bash
# Launch Zen Browser with remote debugging on an ISOLATED, throwaway profile so
# the zen-mcp server (and the LLM agent driving it) never touches your everyday
# Zen profile, cookies, or logged-in sessions.
#
# Safe to run alongside your normal Zen: it does NOT kill any existing instance.
#
# Config (all optional, via env):
#   ZEN_DEBUG_PORT  debugging port                      (default: 9222)
#   ZEN_PROFILE     throwaway profile directory         (default: /tmp/zen-mcp)
#   ZEN_BIN         path to the Zen executable          (default: the system app)
#                   e.g. a renamed copy so it shows as its own app in Cmd+Tab:
#                   ZEN_BIN="/Applications/Zen MCP.app/Contents/MacOS/zen"

set -euo pipefail

PORT="${ZEN_DEBUG_PORT:-9222}"
PROFILE="${ZEN_PROFILE:-/tmp/zen-mcp}"
ZEN_BIN="${ZEN_BIN:-/Applications/Zen.app/Contents/MacOS/zen}"

# If something is already serving the debug port, reuse it rather than launching
# a duplicate (avoids a profile-lock clash with a previous zen-mcp instance).
if curl -s "http://127.0.0.1:${PORT}/json/version" > /dev/null 2>&1; then
    echo "Zen is already listening on port ${PORT}; reusing it."
    exit 0
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
