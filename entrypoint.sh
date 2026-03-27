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
# GitHub App installation tokens expire quickly, so install lightweight
# helpers that refresh credentials on demand for both gh and git.
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
  echo "🔐 GitHub App credentials detected; installing refreshable git/gh auth helpers..."
  install -d -m 0755 /usr/local/bin
  cat > /usr/local/bin/paperclip-refresh-github-auth <<'EOF'
#!/bin/bash
set -euo pipefail

GH_CONFIG_DIR="${GH_CONFIG_DIR:-/home/paperclip/.config/gh}"
TOKEN_CACHE="${GH_CONFIG_DIR}/token.json"
mkdir -p "${GH_CONFIG_DIR}"

node - <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const appId = process.env.GITHUB_APP_ID;
const installationId = process.env.GITHUB_APP_INSTALLATION_ID;
const privateKey = (process.env.GITHUB_APP_PRIVATE_KEY || "").replace(/\\n/g, "\n");
const configDir = process.env.GH_CONFIG_DIR || "/home/paperclip/.config/gh";
const tokenCache = process.env.TOKEN_CACHE || path.join(configDir, "token.json");
const nowMs = Date.now();

function readCachedToken() {
  try {
    const cached = JSON.parse(fs.readFileSync(tokenCache, "utf8"));
    const expiresAtMs = Date.parse(cached.expires_at || "");
    if (cached.token && Number.isFinite(expiresAtMs) && expiresAtMs - nowMs > 5 * 60 * 1000) {
      return cached.token;
    }
  } catch (_) {
    // Cache miss or malformed cache; fall through to minting a new token.
  }

  return null;
}

function base64Url(value) {
  return Buffer.from(typeof value === "string" ? value : JSON.stringify(value))
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

async function main() {
  const cachedToken = readCachedToken();
  if (cachedToken) {
    process.stdout.write(cachedToken);
    return;
  }

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

  fs.mkdirSync(configDir, { recursive: true });
  fs.writeFileSync(tokenCache, JSON.stringify({
    token: body.token,
    expires_at: body.expires_at,
  }));
  fs.writeFileSync(path.join(configDir, "hosts.yml"), `github.com:
    oauth_token: ${body.token}
    user: x-access-token
    git_protocol: https
`);

  process.stdout.write(body.token);
}

main().catch(err => {
  console.error(String(err));
  process.exit(1);
});
NODE
EOF
  chmod 0755 /usr/local/bin/paperclip-refresh-github-auth

  cat > /usr/local/bin/paperclip-git-credential-helper <<'EOF'
#!/bin/bash
set -euo pipefail

host=""
protocol=""
while IFS='=' read -r key value; do
  case "$key" in
    host) host="$value" ;;
    protocol) protocol="$value" ;;
  esac
done

if [ "$protocol" = "https" ] && [ "$host" = "github.com" ]; then
  token="$(/usr/local/bin/paperclip-refresh-github-auth)"
  printf 'username=x-access-token\npassword=%s\n' "$token"
fi
EOF
  chmod 0755 /usr/local/bin/paperclip-git-credential-helper

  cat > /usr/local/bin/gh <<'EOF'
#!/bin/bash
set -euo pipefail
export GH_TOKEN="$(
  /usr/local/bin/paperclip-refresh-github-auth
)"
exec /usr/bin/gh "$@"
EOF
  chmod 0755 /usr/local/bin/gh

  if GITHUB_TOKEN="$(/usr/local/bin/paperclip-refresh-github-auth)"; then
    export GITHUB_TOKEN
    export GH_TOKEN="$GITHUB_TOKEN"
    export GIT_TERMINAL_PROMPT=0
    chown -R paperclip:paperclip /home/paperclip/.config 2>/dev/null || true
    gosu paperclip /usr/bin/git config --global --unset-all credential.helper || true
    gosu paperclip /usr/bin/git config --global credential.helper "/usr/local/bin/paperclip-git-credential-helper"
    gosu paperclip /usr/bin/git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
    gosu paperclip /usr/bin/git config --global --get-regexp '^url\..*github\.com/.*\.insteadOf$' | awk '{print $1}' | while read -r key; do
      gosu paperclip /usr/bin/git config --global --remove-section "${key#url.}" 2>/dev/null || true
    done
    echo "✅ Refreshable GitHub App credentials configured for git and gh"
  else
    echo "⚠️  Failed to configure GitHub App credentials; git/gh repo auth may fail."
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
