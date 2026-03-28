# paperclip-railway

> A Railway-ready wrapper for [paperclipai/paperclip](https://github.com/paperclipai/paperclip) with a web-based `/setup` page — no CLI access required.

Railway doesn't provide shell access during deployment, so the normal `pnpm paperclipai onboard` flow can't run. This repo solves that by:

1. On first boot, serving a **web-based setup page** at your Railway URL that checks all required env vars and walks you through configuration.
2. Once you click **Launch Paperclip**, the setup page hands off to the real Paperclip server — which automatically runs DB migrations and starts up.
3. You then visit your Railway URL and **sign up** — no CLI needed.

---

## Deploy to Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/paperclip-ai-company)

### Manual steps

1. **Fork or clone this repo** into your own GitHub account.

2. **Create a new Railway project** and add:
   - A **PostgreSQL** database service (Railway managed)
   - A **new service** pointing at your fork of this repo

3. **Add a volume** to the Paperclip service, mounted at `/paperclip`.

4. **Set these environment variables** on the Paperclip service:

```env
DATABASE_URL="${{Postgres.DATABASE_URL}}"
BETTER_AUTH_SECRET="${{secret(32)}}"
PAPERCLIP_PUBLIC_URL="https://your-app.up.railway.app"
PAPERCLIP_ALLOWED_HOSTNAMES="your-app.up.railway.app"
PAPERCLIP_DEPLOYMENT_MODE="authenticated"
PAPERCLIP_HOME="/paperclip"
HOST="0.0.0.0"
PORT="3100"
NODE_ENV="production"

# Optional (recommended for headless/server deployments)
OPENAI_API_KEY="sk-..."

# Optional override. This template defaults to:
# image/png,image/jpeg,image/jpg,image/webp,image/gif,application/pdf,
# text/markdown,text/plain,application/json,text/csv,text/html,video/mp4
PAPERCLIP_ALLOWED_ATTACHMENT_TYPES="image/*,application/pdf,video/mp4"

# Optional (Codex local auth cache path)
CODEX_HOME="/paperclip/.codex"

# Optional (seed auth.json directly for ChatGPT-session auth)
CODEX_AUTH_JSON_B64="<base64_auth_json>"

# Optional (default true): remove tokens.account_id from auth cache to avoid stale workspace selection errors
CODEX_AUTH_STRIP_ACCOUNT_ID="true"

# Optional (default true): reset Codex runtime sqlite/session state on each boot
# Keeps auth.json/config.toml intact, but clears stale workspace/model selections
CODEX_RESET_STATE_ON_BOOT="true"
```

5. **Deploy** — Railway will run `npm start` which serves the setup page.

6. **Open your Railway URL** — you'll see the setup page. Verify all vars are green, then click **Launch Paperclip**.

7. **Sign up** for an account on the Paperclip UI. The first user automatically gets board-level access.

8. **Lock sign-ups**: go back to Railway Variables, add `PAPERCLIP_AUTH_DISABLE_SIGN_UP=true`, and redeploy.

---

## How it works

```
npm start
  └── scripts/start.mjs
        ├── if SETUP_COMPLETE != "true" AND no /paperclip/.setup_complete file:
        │     serve setup UI on PORT  (/setup)
        │     user clicks "Launch" → writes flag → restarts as paperclip
        └── else:
              write minimal config.json to PAPERCLIP_HOME
              spawn: paperclipai run --yes --no-onboard
```

The setup page auto-polls Railway's env vars by hitting `/setup/status` — each var shows as ✓ Set or ✗ Missing in real time.

For attachment delivery, this wrapper also exposes forced-download aliases that preserve Paperclip auth and switch the response to `Content-Disposition: attachment`:

- `/api/attachments/:attachmentId/download`
- `/api/assets/:assetId/download`

---

## Files

```
paperclip-railway/
├── package.json          # installs paperclipai, defines start script
├── scripts/
│   └── start.mjs         # setup server + paperclip launcher
└── README.md
```

---

## After first launch

Once Paperclip is running, this wrapper is transparent — it just passes through to `paperclipai run`. The `/setup` page is bypassed on all subsequent restarts (the flag file persists in the `/paperclip` volume).

---

## Troubleshooting

**Setup page keeps reappearing after redeploy**
→ The `/paperclip` volume wasn't attached. Make sure the volume is mounted at `/paperclip` in Railway's service settings.

**Auth errors / blank screen after login**
→ `PAPERCLIP_PUBLIC_URL` and `PAPERCLIP_ALLOWED_HOSTNAMES` don't match your Railway domain. Update them and redeploy.

**`DATABASE_URL` SSL errors**
→ Add `DATABASE_SSL_REJECT_UNAUTHORIZED=false` to your Railway env vars.

**Paperclip starts but agents can't connect**
→ Make sure `PAPERCLIP_DEPLOYMENT_EXPOSURE=public` is set so the server accepts external connections.

**Attachments upload but browsers try to open them inline**
→ Use the wrapper download aliases instead of the native `.../content` routes:
- `/api/attachments/:attachmentId/download`
- `/api/assets/:assetId/download`

**`video/mp4` uploads are rejected**
→ This template now includes `video/mp4` in the default attachment allowlist. If you override `PAPERCLIP_ALLOWED_ATTACHMENT_TYPES`, make sure `video/mp4` is still included.

**Codex shows `responses_websocket` auth errors / `403 Forbidden`**
→ Codex authentication is being rejected. Fix it in this order:
1. Recommended for Railway/headless: set `OPENAI_API_KEY` and redeploy.
2. If you use ChatGPT-session auth instead, refresh your local Codex login and re-export the auth cache:
```bash
codex login
base64 < ~/.codex/auth.json | tr -d '\n'
```
3. In Railway Variables, set:
```env
CODEX_AUTH_JSON_B64="<paste_base64_here>"
CODEX_HOME="/paperclip/.codex"
```
4. Redeploy. The wrapper writes `CODEX_HOME/auth.json` on boot.
5. If `OPENAI_API_KEY` is already set and 403 still appears, check the agent's `adapterConfig.env` does not override `OPENAI_API_KEY` with an empty value.

**Codex fails with `invalid_workspace_selected` (403 on `/backend-api/codex/models`)**
→ Your ChatGPT session token is selecting an invalid/stale workspace/account.
1. Keep `CODEX_AUTH_STRIP_ACCOUNT_ID=true` (default in this template) so stale `tokens.account_id` is removed at boot.
2. Keep `CODEX_RESET_STATE_ON_BOOT=true` (default) so stale Codex runtime DB/session state is cleared on each deploy.
3. Re-run `codex login` locally and refresh `CODEX_AUTH_JSON_B64`.
4. Redeploy and retry the agent run.
5. If it still fails, switch to `OPENAI_API_KEY` auth on Railway (headless environments are more stable with API-key auth).
