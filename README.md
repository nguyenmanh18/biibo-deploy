# biibo-deploy

Everything the production VPS runs, and nothing it builds. The VPS holds no
source code: only the files in this repo plus its own `.env` and `caddy.env`.

| File | Role |
|---|---|
| `docker-compose.prod.yml` | the whole stack: caddy, web, admin, api, migrate, postgres, redis, restate |
| `Caddyfile` | TLS + reverse proxy to `web` and `admin` |
| `backup.sh` | Postgres dump on the VPS |
| `.env.example` | template for `/opt/biibo/.env` (never commit the real one) |
| `docs/` | deployment runbook, infrastructure notes, first-setup log |

## Who deploys what

| Repo | Tag | Does |
|---|---|---|
| `biibo-backend` | `v*` | build `biibo-api`, run migrations, restart `api`, write `API_TAG` |
| `biibo-vocabulary` | `v*` | build `biibo-web`, restart `web`, write `WEB_TAG` |
| `biibo-supper-admin` | `v*` | build `biibo-admin`, restart `admin`, write `ADMIN_TAG` |
| `biibo-deploy` (this) | `stack-*` | copy these files to the VPS, `up -d`, reload Caddy |

An API change ships from `biibo-backend` first, then the web app that uses it.
A change to this repo (a new service, a Caddy route) deploys with a `stack-` tag:

```bash
git tag -a stack-2026.09.27 -m "..." && git push origin main stack-2026.09.27
```

## Secrets each repo needs (GitHub → Settings → Secrets and variables → Actions, environment `production`)

`VPS_SSH_KEY`, `VPS_HOST`, `VPS_USER`, optional `VPS_SSH_HOST_KEY`; variables
`DEPLOY_DIR` (default `/opt/biibo`) and `SITE_URL` (default
`https://english.biibo.app`). `GITHUB_TOKEN` is automatic.

See `docs/deployment.md` for the full runbook.
