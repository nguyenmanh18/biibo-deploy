# biibo-deploy

Mọi thứ VPS production chạy, và không có gì VPS phải build. VPS không giữ source
code: chỉ có các file trong repo này cùng `.env` và `caddy.env` riêng của nó, ở
`/opt/biibo`.

Hiện một VPS chạy chung: **english.biibo.app** (web tiếng Anh) và
**admin.biibo.app** (admin), sau Cloudflare proxy. Web tiếng Trung chưa được
deploy. Dự kiến tách Postgres sang một VPS riêng sau.

| File | Vai trò |
|---|---|
| `docker-compose.prod.yml` | cả stack: caddy, web, admin, api, migrate, postgres, redis, restate |
| `Caddyfile` | TLS + reverse proxy tới `web` và `admin`; `/api/v1/docs` và spec OpenAPI có basic auth |
| `backup.sh` | dump Postgres trên VPS |
| `.env.example` | mẫu cho `/opt/biibo/.env` (không bao giờ commit file thật) |
| `docs/` | runbook deploy, ghi chú hạ tầng, nhật ký dựng máy lần đầu |

## Ai deploy cái gì

| Repo | Tag | Làm gì |
|---|---|---|
| [`biibo-backend`](https://github.com/nguyenmanh18/biibo-backend) | `v*` | build `biibo-api`, chạy migration, khởi động lại `api`, ghi `API_TAG` |
| [`biibo-vocab-english-web`](https://github.com/nguyenmanh18/biibo-vocab-english-web) | `v*` | build `biibo-web`, khởi động lại `web`, ghi `WEB_TAG` |
| [`biibo-supper-admin`](https://github.com/nguyenmanh18/biibo-supper-admin) | `v*` | build `biibo-admin`, khởi động lại `admin`, ghi `ADMIN_TAG` |
| `biibo-deploy` (repo này) | `stack-*` | chép các file này lên VPS, `up -d --remove-orphans`, reload Caddy |
| [`biibo-vocab-chinese-web`](https://github.com/nguyenmanh18/biibo-vocab-chinese-web) | — | chưa có trong stack |

Mỗi repo chỉ sửa đúng dòng tag của mình trong `.env`; compose đọc
`${API_TAG:-${IMAGE_TAG:-latest}}` (tương tự cho web, admin), nên từng repo deploy
độc lập. Thứ tự khi thay đổi đi qua nhiều repo: **backend → web → admin → stack**.

Thay đổi ở repo này (thêm service, thêm route Caddy) deploy bằng tag `stack-`:

```bash
git tag -a stack-2026.09.28 -m "..." && git push origin main stack-2026.09.28
```

## Migration

Bản chính thức đầu tiên là `v2.0.0` (27/09/2026): database prod được dựng từ
baseline `00001_init.sql` và cả dev lẫn prod đều ở goose version 1. Từ đây mọi
thay đổi schema phải là migration mới (`00002` trở đi) trong `biibo-backend`;
service `migrate` chạy chúng khi backend deploy. Không sửa tay schema trên prod.

## Secrets mỗi repo cần

GitHub → Settings → Secrets and variables → Actions, environment `production`:
`VPS_SSH_KEY`, `VPS_HOST`, `VPS_USER`, tùy chọn `VPS_SSH_HOST_KEY`; biến
`DEPLOY_DIR` (mặc định `/opt/biibo`) và `SITE_URL` (mặc định
`https://english.biibo.app`). `GITHUB_TOKEN` có sẵn; mỗi repo cần quyền ghi vào
package GHCR tương ứng.

Runbook đầy đủ: [`docs/deployment.md`](docs/deployment.md).
