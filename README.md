# paperclip-railway

Railway wrapper for `paperclipai` with a persistent `/paperclip` volume, a web-based `/setup` page, Codex bootstrapping, and a small proxy layer for authenticated attachment downloads.

This repo is not a generic Paperclip fork. It is an operational wrapper around the upstream server so Paperclip can run on Railway without shell access during first-time setup.

## What This Repo Does

On boot, `scripts/start.mjs` owns the public port and decides whether the instance is ready.

Ready means:

- `DATABASE_URL` is set
- `BETTER_AUTH_SECRET` is set
- `PAPERCLIP_PUBLIC_URL` is set
- `PAPERCLIP_ALLOWED_HOSTNAMES` is set
- `/paperclip/config.json` exists

If the instance is not ready, the wrapper serves `/setup` and exposes status endpoints so you can finish configuration from the browser and trigger first launch.

If the instance is ready, the wrapper:

- writes a fresh `config.json` into `PAPERCLIP_HOME`
- starts upstream `paperclipai run` on internal port `3099`
- proxies public traffic from Railway port `3100` to the upstream server
- preserves Codex auth/config under `/paperclip/.codex`
- defaults the Paperclip attachment allowlist to include `video/mp4`
- adds authenticated forced-download routes for attachments and assets

## Wrapper-Specific Behavior

This repo adds behavior on top of upstream Paperclip:

- `PAPERCLIP_ALLOWED_ATTACHMENT_TYPES` defaults to:
  `image/png,image/jpeg,image/jpg,image/webp,image/gif,application/pdf,text/markdown,text/plain,application/json,text/csv,text/html,video/mp4`
- download aliases:
  - `/api/attachments/:attachmentId/download`
  - `/api/assets/:assetId/download`
- Codex auth can be seeded from `CODEX_AUTH_JSON_B64` or `CODEX_AUTH_JSON`
- stale Codex runtime sqlite/session state is cleared on boot by default
- stale `tokens.account_id` is stripped from Codex auth by default to avoid `invalid_workspace_selected`
- `entrypoint.sh` repairs volume ownership and can bootstrap Codex login from `OPENAI_API_KEY`

## Repo Layout

```text
.
├── Dockerfile
├── entrypoint.sh
├── package.json
├── scripts/
│   ├── setup.html
│   └── start.mjs
└── docs/
    └── codex-auth-runbook.md
```

## Requirements

- Node.js 20+
- npm
- PostgreSQL
- A writable persistent directory for `PAPERCLIP_HOME`
- Railway volume mounted at `/paperclip` for production

## Environment Variables

Required:

```env
DATABASE_URL="postgresql://user:pass@host:5432/db"
BETTER_AUTH_SECRET="replace-with-random-secret"
PAPERCLIP_PUBLIC_URL="https://your-app.up.railway.app"
PAPERCLIP_ALLOWED_HOSTNAMES="your-app.up.railway.app"
```

Recommended:

```env
PAPERCLIP_HOME="/paperclip"
CODEX_HOME="/paperclip/.codex"
CODEX_CONFIG_DIR="/paperclip/.codex"
PAPERCLIP_DEPLOYMENT_MODE="authenticated"
PAPERCLIP_DEPLOYMENT_EXPOSURE="public"
HOST="0.0.0.0"
PORT="3100"
NODE_ENV="production"
CODEX_AUTH_STRIP_ACCOUNT_ID="true"
CODEX_RESET_STATE_ON_BOOT="true"
```

Optional auth for Codex:

```env
OPENAI_API_KEY="sk-..."
```

or

```env
CODEX_AUTH_JSON_B64="<base64-encoded-auth-json>"
```

Optional override:

```env
PAPERCLIP_ALLOWED_ATTACHMENT_TYPES="image/*,application/pdf,video/mp4"
```

If you override `PAPERCLIP_ALLOWED_ATTACHMENT_TYPES`, include `video/mp4` explicitly if you want native MP4 uploads to continue working.

## Reproduce The Repo Locally

These steps reproduce the wrapper behavior locally, including the `/setup` flow and the runtime proxy.

1. Install dependencies.

```bash
npm install
```

2. Create a writable local Paperclip home.

```bash
mkdir -p .paperclip-local/.codex
```

3. Export the minimum environment variables.

```bash
export DATABASE_URL="postgresql://user:pass@localhost:5432/paperclip"
export BETTER_AUTH_SECRET="replace-with-random-secret"
export PAPERCLIP_PUBLIC_URL="http://localhost:3100"
export PAPERCLIP_ALLOWED_HOSTNAMES="localhost"
export PAPERCLIP_HOME="$PWD/.paperclip-local"
export CODEX_HOME="$PWD/.paperclip-local/.codex"
export CODEX_CONFIG_DIR="$PWD/.paperclip-local/.codex"
export PORT="3100"
export HOST="0.0.0.0"
```

4. Start the wrapper.

```bash
npm start
```

5. Open `http://localhost:3100/setup`.

If `config.json` does not exist yet, the wrapper will serve the setup UI. Use the launch action on that page, or POST to `/setup/launch`, to write config and start upstream Paperclip for the first time.

6. Verify the generated state.

```bash
ls -la .paperclip-local
cat .paperclip-local/config.json
```

7. Verify the wrapper syntax if you only want a quick sanity check.

```bash
node --check scripts/start.mjs
```

## Reproduce On Railway

1. Fork this repository.
2. Create a Railway project.
3. Add a PostgreSQL service.
4. Add a service pointing at this repo.
5. Attach a volume mounted at `/paperclip`.
6. Set the required environment variables.
7. Deploy the service.
8. Open your Railway URL and confirm `/setup` shows all required vars as set.
9. Launch Paperclip from the setup page and finish account bootstrap in the UI.
10. After initial bootstrap, set `PAPERCLIP_AUTH_DISABLE_SIGN_UP=true` if you want to close open signups.

## Runtime Flow

```text
public :3100
  -> scripts/start.mjs
     -> /setup and setup status endpoints
     -> readiness check
     -> write /paperclip/config.json
     -> start paperclipai on 127.0.0.1:3099
     -> proxy all app traffic to upstream
```

Attachment download flow:

```text
/api/attachments/:id/download
  -> wrapper proxy
  -> upstream /api/attachments/:id/content?download=1
  -> Content-Disposition rewritten to attachment
```

Same pattern exists for `/api/assets/:id/download`.

## Common Operations

Start locally:

```bash
npm start
```

Validate the wrapper entrypoint:

```bash
node --check scripts/start.mjs
```

Reset local state:

```bash
rm -rf .paperclip-local
mkdir -p .paperclip-local/.codex
```

## Troubleshooting

`/setup` keeps appearing on every boot

- `PAPERCLIP_HOME` is empty, unwritable, or not persistent
- `config.json` is missing under `PAPERCLIP_HOME`
- one of the four required env vars is still unset

MP4 uploads are rejected

- do not remove `video/mp4` from `PAPERCLIP_ALLOWED_ATTACHMENT_TYPES`

Attachment links open inline instead of downloading

- use the wrapper download aliases instead of upstream `/content` routes

Codex fails with `403 Forbidden` on websocket auth

- prefer `OPENAI_API_KEY` in headless Railway deployments
- otherwise refresh local Codex auth and reseed `CODEX_AUTH_JSON_B64`

Codex fails with `invalid_workspace_selected`

- keep `CODEX_AUTH_STRIP_ACCOUNT_ID=true`
- keep `CODEX_RESET_STATE_ON_BOOT=true`
- refresh the auth seed and redeploy

Railway deploy starts but Paperclip never becomes reachable

- confirm the mounted volume is writable at `/paperclip`
- confirm `PAPERCLIP_PUBLIC_URL` and `PAPERCLIP_ALLOWED_HOSTNAMES` match the exact Railway hostname

## Notes

- Upstream `paperclipai` is installed from npm as `latest`
- This wrapper binds the public service to port `3100`
- Upstream Paperclip runs internally on `127.0.0.1:3099`
- Config is regenerated on each boot so env changes are reflected without manual edits
