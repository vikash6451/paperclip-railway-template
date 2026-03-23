#!/bin/bash
set -e

# Fix ownership of the Railway volume mount at /paperclip
# Railway mounts volumes as root, but we need the paperclip user to write to it
if [ -d "/paperclip" ]; then
  chown -R paperclip:paperclip /paperclip 2>/dev/null || true
fi

# Ensure the Codex auth directory exists and is owned by the paperclip user.
# This directory persists across container restarts via the Railway volume.
mkdir -p /paperclip/.codex
chown paperclip:paperclip /paperclip/.codex

# Check whether a Codex auth token is already present in the persistent volume.
# The token is written once by running: codex login --device-auth
# (exec into the running container and run that command as the paperclip user)
CODEX_AUTH_FILE="/paperclip/.codex/auth.json"
if [ ! -f "$CODEX_AUTH_FILE" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║           Codex CLI — device auth not yet configured            ║"
  echo "╠══════════════════════════════════════════════════════════════════╣"
  echo "║  No auth token found at: ${CODEX_AUTH_FILE}"
  echo "║"
  echo "║  To authenticate, exec into this container and run:"
  echo "║    codex login --device-auth"
  echo "║"
  echo "║  The token will be saved to the persistent volume and will"
  echo "║  survive future container restarts automatically."
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo ""
else
  echo "✅ Codex auth token found at ${CODEX_AUTH_FILE}"
fi

# Propagate CODEX_CONFIG_DIR so the app process inherits it even if the
# environment variable was not set at image build time.
export CODEX_CONFIG_DIR=/paperclip/.codex

# Ensure the logs directory exists and is writable by the paperclip user
mkdir -p /paperclip/logs
chown paperclip:paperclip /paperclip/logs

# Start Codex as a background WebSocket server on localhost:8000 if auth is present.
# codex app-server exposes a WebSocket endpoint that Paperclip can connect to
# without requiring any external API keys.
CODEX_SERVE_PORT=8000
CODEX_LOG=/paperclip/logs/codex-serve.log

if [ -f "$CODEX_AUTH_FILE" ]; then
  echo "🚀 Starting Codex app-server on ws://127.0.0.1:${CODEX_SERVE_PORT}..."
  # Run as the paperclip user so it inherits the correct CODEX_CONFIG_DIR
  gosu paperclip bash -c \
    "CODEX_CONFIG_DIR=${CODEX_CONFIG_DIR} codex app-server --listen ws://127.0.0.1:${CODEX_SERVE_PORT} >> ${CODEX_LOG} 2>&1 &"
  echo "   Codex app-server started (logs: ${CODEX_LOG})"
else
  echo "⚠️  Codex serve not started — no auth token found. Authenticate first, then redeploy."
fi

# Drop privileges and run the actual command as the paperclip user
exec gosu paperclip "$@"
