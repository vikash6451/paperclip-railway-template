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

# Drop privileges and run the actual command as the paperclip user
exec gosu paperclip "$@"
