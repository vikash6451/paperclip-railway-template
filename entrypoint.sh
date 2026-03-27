#!/bin/bash
set -e

# Fix ownership of the Railway volume mount at /paperclip
# Railway mounts volumes as root, but we need the paperclip user to write to it
if [ -d "/paperclip" ]; then
  chown -R paperclip:paperclip /paperclip 2>/dev/null || true
fi

# Keep Codex state in the same directory for both old/new env conventions.
CODEX_HOME="${CODEX_HOME:-/paperclip/.codex}"
CODEX_CONFIG_DIR="${CODEX_CONFIG_DIR:-$CODEX_HOME}"
export CODEX_HOME
export CODEX_CONFIG_DIR

# Bootstrap GitHub CLI/git auth from GitHub App credentials when available.
# This gives execution agents a short-lived installation token for clone/push/PR work.
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
  echo "🔐 GitHub App credentials detected; minting installation token for agent repo access..."
  if GITHUB_TOKEN="$(
    node - <<'NODE'
const crypto = require("crypto");

const appId = process.env.GITHUB_APP_ID;
const installationId = process.env.GITHUB_APP_INSTALLATION_ID;
const privateKey = (process.env.GITHUB_APP_PRIVATE_KEY || "").replace(/\\n/g, "\n");

function base64Url(value) {
  return Buffer.from(typeof value === "string" ? value : JSON.stringify(value))
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

async function main() {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${base64Url({ alg: "RS256", typ: "JWT" })}.${base64Url({
    iat: now - 60,
    exp: now + 540,
    iss: appId,
  })}`;

  const signature = crypto
    .createSign("RSA-SHA256")
    .update(unsigned)
    .sign(privateKey, "base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");

  const jwt = `${unsigned}.${signature}`;
  const response = await fetch(`https://api.github.com/app/installations/${installationId}/access_tokens`, {
    method: "POST",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${jwt}`,
      "User-Agent": "paperclip-github-bootstrap",
    },
  });

  const body = await response.json();
  if (!response.ok || !body.token) {
    console.error(JSON.stringify(body));
    process.exit(1);
  }

  process.stdout.write(body.token);
}

main().catch(err => {
  console.error(String(err));
  process.exit(1);
});
NODE
  )"; then
    export GITHUB_TOKEN
    export GH_TOKEN="$GITHUB_TOKEN"
    export GIT_TERMINAL_PROMPT=0
    mkdir -p /home/paperclip/.config/gh
    cat > /home/paperclip/.config/gh/hosts.yml <<EOF
github.com:
    oauth_token: ${GITHUB_TOKEN}
    user: x-access-token
    git_protocol: https
EOF
    chown -R paperclip:paperclip /home/paperclip/.config 2>/dev/null || true
    gosu paperclip git config --global credential.helper ""
    gosu paperclip git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
    echo "✅ GitHub App installation token configured for git and gh"
  else
    echo "⚠️  Failed to mint GitHub App installation token; git/gh repo auth may fail."
  fi
fi

# Ensure the Codex auth directory exists and is writable by the paperclip user.
mkdir -p "$CODEX_HOME"
chown paperclip:paperclip "$CODEX_HOME" 2>/dev/null || true

# Reset stale Codex runtime state on boot while preserving auth/config.
# This clears persisted workspace/model selections that can trigger
# invalid_workspace_selected errors after account/workspace changes.
CODEX_RESET_STATE_ON_BOOT="${CODEX_RESET_STATE_ON_BOOT:-true}"
if [ "$CODEX_RESET_STATE_ON_BOOT" != "false" ] && [ -d "$CODEX_HOME" ]; then
  echo "🧹 Resetting Codex runtime state in ${CODEX_HOME} (auth cache preserved)..."
  find "$CODEX_HOME" -maxdepth 1 -type f \
    \( -name 'state_*.sqlite' -o -name 'state_*.sqlite-wal' -o -name 'state_*.sqlite-shm' \
      -o -name 'logs_*.sqlite' -o -name 'logs_*.sqlite-wal' -o -name 'logs_*.sqlite-shm' \) \
    -delete 2>/dev/null || true
  rm -rf "$CODEX_HOME/sessions" 2>/dev/null || true
fi

# Bootstrap Codex login from OPENAI_API_KEY when no auth cache exists yet.
# This avoids headless ChatGPT-session issues that often surface as websocket 403s.
CODEX_AUTH_FILE="${CODEX_HOME}/auth.json"
if [ -n "${OPENAI_API_KEY:-}" ] && [ ! -f "$CODEX_AUTH_FILE" ]; then
  echo "🔐 OPENAI_API_KEY detected; bootstrapping Codex login into ${CODEX_HOME}..."
  if gosu paperclip env CODEX_HOME="$CODEX_HOME" CODEX_CONFIG_DIR="$CODEX_CONFIG_DIR" OPENAI_API_KEY="$OPENAI_API_KEY" bash -lc \
    'printf "%s" "$OPENAI_API_KEY" | codex login --with-api-key >/tmp/codex-login.log 2>&1'; then
    echo "✅ Codex API-key login saved to ${CODEX_AUTH_FILE}"
  else
    echo "⚠️  Failed to bootstrap Codex API-key login; continuing startup."
    if [ -f /tmp/codex-login.log ]; then
      tail -n 5 /tmp/codex-login.log | sed 's/^/   /'
    fi
  fi
fi

# Check whether auth material is present.
if [ ! -f "$CODEX_AUTH_FILE" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
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
  if [ -f "$CODEX_AUTH_FILE" ]; then
    echo "✅ Codex auth token found at ${CODEX_AUTH_FILE}"
  else
    echo "ℹ️  OPENAI_API_KEY is set; Codex can use API-key auth without a local auth.json cache."
  fi
fi

# Preflight auth status for clearer deploy logs.
if gosu paperclip env CODEX_HOME="$CODEX_HOME" CODEX_CONFIG_DIR="$CODEX_CONFIG_DIR" codex login status >/tmp/codex-login-status.log 2>&1; then
  STATUS_LINE="$(tail -n 1 /tmp/codex-login-status.log)"
  if [ -n "$STATUS_LINE" ]; then
    echo "ℹ️  ${STATUS_LINE}"
  fi
else
  echo "⚠️  Codex login status check failed. Codex runs may fail with responses_websocket 403."
  if [ -f /tmp/codex-login-status.log ]; then
    tail -n 3 /tmp/codex-login-status.log | sed 's/^/   /'
  fi
fi

# Ensure the logs directory exists and is writable by the paperclip user
mkdir -p /paperclip/logs
chown paperclip:paperclip /paperclip/logs

# Start Codex app-server as a background WebSocket endpoint used by Paperclip runtime services.
CODEX_SERVE_PORT=8000
CODEX_LOG=/paperclip/logs/codex-serve.log

if [ -f "$CODEX_AUTH_FILE" ] || [ -n "${OPENAI_API_KEY:-}" ]; then
  echo "🚀 Starting Codex app-server on ws://127.0.0.1:${CODEX_SERVE_PORT}..."
  # Run as the paperclip user so it inherits Codex auth/env settings.
  gosu paperclip env CODEX_HOME="$CODEX_HOME" CODEX_CONFIG_DIR="$CODEX_CONFIG_DIR" OPENAI_API_KEY="${OPENAI_API_KEY:-}" bash -c \
    "codex app-server --listen ws://127.0.0.1:${CODEX_SERVE_PORT} >> ${CODEX_LOG} 2>&1 &"
  echo "   Codex app-server started (logs: ${CODEX_LOG})"
else
  echo "⚠️  Codex app-server not started — no auth configured."
fi

# Drop privileges and run the actual command as the paperclip user
exec gosu paperclip "$@"
