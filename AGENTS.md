# biibo-deploy

Production operations for the Biibo apps: the compose stack, Caddy, backups and
the runbook in `docs/`. Nothing here is built; images come from `biibo-backend`
(`biibo-api`) and `biibo-vocabulary` (`biibo-web`).

- Never commit `.env`, `caddy.env` or any secret. The VPS `.env` is edited by a
  person; CI only rewrites `API_TAG` / `WEB_TAG`.
- Ports: only Caddy publishes 80/443. Postgres, Redis and Restate bind
  `127.0.0.1` at most — Docker's NAT bypasses UFW, so never publish them on 0.0.0.0.
- Keep Restate's version and `RESTATE_NODE_NAME` pinned (see `docs/deployment.md` §9).
- A `docker compose run` or `exec` inside the ssh heredoc needs `-T </dev/null`,
  or it swallows the rest of the script while the job stays green.
