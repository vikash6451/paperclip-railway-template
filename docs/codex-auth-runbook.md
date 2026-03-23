# Codex Workspace/Auth Runbook (Railway)

Use this after any `codex login` change or ChatGPT workspace/account change to prevent:

- `invalid_workspace_selected`
- `403 Forbidden` on `/backend-api/codex/models` or `/backend-api/codex/responses`

## 1) Refresh local Codex login

```bash
codex logout
codex login
```

## 2) Re-seed Railway auth from local `~/.codex/auth.json`

```bash
AUTH_B64=$(base64 < ~/.codex/auth.json | tr -d '\n')
echo ${#AUTH_B64}
```

`AUTH_B64` length should be large (usually thousands). If it is `2`, your value is wrong (commonly set to literal `@-`).

Set variables on Railway:

```bash
railway variables set CODEX_AUTH_STRIP_ACCOUNT_ID=true --service Paperclip --environment production --skip-deploys
railway variables set CODEX_RESET_STATE_ON_BOOT=true --service Paperclip --environment production --skip-deploys
railway variables set CODEX_AUTH_JSON_B64="$AUTH_B64" --service Paperclip --environment production
```

## 3) Smoke test Codex in the running container

```bash
railway ssh --service Paperclip --environment production -- \
"cd /app && CODEX_HOME=/paperclip/.codex CODEX_CONFIG_DIR=/paperclip/.codex codex exec --sandbox workspace-write --skip-git-repo-check 'reply with OK only'"
```

Expected result: response text `OK` and no `invalid_workspace_selected`.

## 4) If it still fails

Switch production to API-key auth (most stable in headless/server environments):

```bash
railway variables set OPENAI_API_KEY="sk-..." --service Paperclip --environment production
```

