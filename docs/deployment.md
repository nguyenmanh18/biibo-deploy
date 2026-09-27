# Deploy

Đích: `https://english.biibo.app` và `https://admin.biibo.app`, chung một VPS, quản lý hoàn toàn bằng
`docker compose`. Kiến trúc và sức chứa nằm ở `infrastructure.md`; file này chỉ
nói cách đưa code lên máy.

File này trả lời **nên làm thế nào**. Muốn dò lại **đã làm gì, theo thứ tự nào**
trên chính cái máy đang chạy — kể cả hai chỗ làm sai và cách phát hiện — đọc
`deployment-log.md`.

---

## 1. Hình dạng

**Bốn repo, một VPS.** `biibo-backend` build image API, `biibo-vocab-english-web` build
image web, `biibo-supper-admin` build image admin, `biibo-deploy` (repo này) giữ file
vận hành. Cả bốn ghi vào cùng `/opt/biibo`; mỗi repo đánh tag và deploy độc lập
(bảng trong `README.md`). `biibo-vocab-chinese-web` chưa có trong stack.

**VPS không giữ source code.** Nó chỉ có vài file trong `/opt/biibo`:

| File | Từ đâu tới | Ai sửa |
|---|---|---|
| `docker-compose.prod.yml` | CI của `biibo-deploy` `scp` | repo này |
| `Caddyfile`, `backup.sh` | CI của `biibo-deploy` `scp` | repo này |
| `.env` | đặt tay một lần | **chỉ người**. CI chỉ chạm đúng dòng tag của mình: `API_TAG` (backend), `WEB_TAG` (web), `ADMIN_TAG` (admin) |

Toàn bộ code đi trong image. VPS không có Node, không có Go toolchain, không
`git pull`.

```
tag v*  ─► GitHub Actions (amd64) ─► build image ──► ghcr.io
                                                          │
                                   ssh ◄──────────────────┘
                                    └─► VPS: pull → migrate → up -d
```

Build chạy trên runner của GitHub, không trên VPS: build Next tốn nhiều CPU, mà
`infrastructure.md` §9 đã đo ra CPU chính là nút cổ chai của máy này. Runner
cũng là amd64, nên máy dev Apple Silicon không gây lệch kiến trúc.

---

## 2. Registry: GHCR

Dùng `ghcr.io` chứ không phải Docker Hub, vì tài khoản GitHub đã có sẵn: trong
Actions `GITHUB_TOKEN` tự đủ quyền đẩy package của repo, private không giới hạn
số lượng, và không có hạn mức pull theo IP như Docker Hub (100 pull/6h) — thứ sẽ
đếm cả những lần VPS kéo image.

Hai image:

- `ghcr.io/nguyenmanh18/biibo-web` — Next.js
- `ghcr.io/nguyenmanh18/biibo-api` — Go backend (kèm `goose` để chạy migration)

Mỗi bản được gắn ba tag: `:latest`, `:<phiên bản>` (ví dụ `:v1.0.0`) và
`:<commit sha>`. Phiên bản là thứ dùng để quay lui — xem §6 và §8.

**Image để private**, nên VPS phải xác thực mới kéo được. VPS *không* giữ token
riêng: bước deploy đưa `GITHUB_TOKEN` của chính lần chạy đó qua SSH, `docker
login` → `pull` → `docker logout`. Token hết hiệu lực khi job kết thúc, nên
không có credential nào nằm lại trên máy chờ bị lộ.

Hệ quả cần biết: giữa hai lần deploy, `docker pull` **bằng tay** trên VPS sẽ báo
`unauthorized`. Đó là hành vi đúng — muốn đưa bản mới lên thì chạy lại workflow
(`gh workflow run deploy.yml`), đừng kéo tay. Còn `docker compose up -d` bằng
tay vẫn chạy bình thường vì image đã nằm sẵn trên máy.

---

## 3. Chuẩn bị VPS (đã làm, 2026-09-12)

Máy hiện tại: `103.173.154.168`, Ubuntu 24.04 LTS, 6 vCPU / 15 GiB RAM / 98 GB
đĩa, đăng nhập `root` **chỉ bằng khoá SSH** — mật khẩu đã tắt (§12).

```bash
curl -fsSL https://get.docker.com | sh     # Docker 29.8.0 + Compose v5.5.1
mkdir -p /opt/biibo && chmod 700 /opt/biibo
```

`/opt/biibo/.env` (`chmod 600`) được tạo tay. Những giá trị đã đặt:

| Biến | Lấy từ đâu |
|---|---|
| `POSTGRES_PASSWORD`, `REDIS_PASSWORD` | `openssl rand -base64 24`, sinh mới |
| `AI_KEY_ENCRYPTION_SECRET` | **chép nguyên văn từ `.env.local` của máy dev** |
| `APP_BASE_URL`, `GOOGLE_REDIRECT_URL`, `ZALO_REDIRECT_URL` | `https://english.biibo.app…` |
| `SESSION_COOKIE_NAME` | `biibo_session` |
| `SESSION_COOKIE_SECURE` | `true` |
| `API_TAG`, `WEB_TAG`, `ADMIN_TAG` | CI của từng repo ghi đè mỗi lần deploy (`IMAGE_TAG` cũ chỉ còn là dự phòng) |

> `AI_KEY_ENCRYPTION_SECRET` phải **giống hệt** máy dev nếu database đi lên từ
> dump. Nó là khoá AES-256-GCM đang mã hoá `ai_credentials`, token R2 trong
> `storage_settings`, và client secret Google. Sinh khoá mới = ba thứ đó thành
> rác, trong khi server vẫn khởi động bình thường và chỉ vỡ lúc người dùng chạm
> vào tính năng. Không có đường khôi phục.

Những thứ **không** chép sang: mọi biến chỉ có ý nghĩa ở máy dev
(`DEV_FALLBACK_USER_ID`, `NEXT_PUBLIC_GRAPHQL_URL`, `QGEN_*`, `YTDLP_*`…).
Google/Zalo/AI/R2/TTS/STT **không nằm trong `.env`** — chúng đọc từ các bảng
`*_settings` trong database và chỉnh trong admin console.

Tường lửa:

```bash
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp
ufw default deny incoming && ufw default allow outgoing
ufw --force enable
```

**`ufw deny <cổng>` KHÔNG đóng được một cổng mà Docker đã publish**, vì Docker
chèn luật NAT đi vòng qua UFW. Bảo vệ thật nằm ở chỗ `docker-compose.prod.yml`
không publish cổng nào ngoài 80/443 của Caddy (và 9070 bind `127.0.0.1`). Đừng
thêm `ports:` cho postgres/redis/restate trên máy này. Kiểm tra lại bất cứ lúc
nào bằng `ss -ltnp | grep -v 127.0.0.1` — chỉ được thấy 22, 80, 443.

DNS: `english.biibo.app` trỏ thẳng về IP VPS. Hiện đang để **mây xám** (không
proxy) để lần xin chứng chỉ đầu tiên chắc chắn qua. Sau khi site lên xanh thì
bật mây cam và đặt SSL/TLS ở **Full (strict)** — "Flexible" sẽ tạo vòng lặp
chuyển hướng. Caddy vẫn tự xin được Let's Encrypt qua cổng 80 sau lớp proxy.

Đăng ký redirect URI ở Google Cloud Console và app Zalo:
`https://english.biibo.app/api/v1/auth/{google,zalo}/callback`. Chưa đăng ký thì
nút đăng nhập Google trả lỗi `redirect_uri_mismatch`.

---

## 4. Cấu hình GitHub (đã làm)

Settings → Secrets and variables → Actions. Đặt bằng `gh`, không dán giá trị qua
màn hình:

| Loại | Tên | Giá trị |
|---|---|---|
| Secret | `VPS_HOST` | `103.173.154.168` |
| Secret | `VPS_USER` | `root` |
| Secret | `VPS_SSH_KEY` | private key của cặp khoá **dành riêng cho CI** |
| Secret | `VPS_SSH_HOST_KEY` | `ssh-keyscan -t rsa,ecdsa,ed25519 <IP>` |
| Variable | `NEXT_PUBLIC_URL` | `https://english.biibo.app` |
| Variable | `DEPLOY_DIR` | `/opt/biibo` |

Khoá CI là một cặp ed25519 riêng (`github-actions-deploy@biibo`), **không dùng
chung với khoá cá nhân trên laptop**: lộ CI thì thu hồi đúng một dòng trong
`authorized_keys` mà không mất quyền vào máy. Dòng đó có thêm
`no-agent-forwarding,no-X11-forwarding,no-user-rc`.

`VPS_SSH_HOST_KEY` có đặt, nên workflow không chạy nhánh TOFU (`ssh-keyscan` lúc
deploy) nữa — nhánh đó vẫn còn trong file để không chết cứng khi đổi máy, và nó
ghi `::warning::` mỗi lần dùng.

`GITHUB_TOKEN` không cần khai — Actions tự cấp. Job `deploy` khai
`permissions: packages: read` để token đó đủ quyền cho VPS mượn mà kéo image.

---

## 5. Database lần đầu (đã làm — khôi phục từ máy dev)

Bản init này **không** dựng DB trắng. Toàn bộ database của máy dev đã được bê
nguyên sang, giữ đủ cả người dùng lẫn phiên đăng nhập, theo yêu cầu "local có gì
trên server y hệt".

```bash
# trên máy dev: dump định dạng custom (51 MB nén)
pg_dump -Fc -d biibo_english -f biibo-prod-seed.dump

scp biibo-prod-seed.dump root@<VPS>:/root/
# đối chiếu md5sum hai đầu trước khi nạp

# trên VPS: dựng hạ tầng trước, app sau
cd /opt/biibo
docker compose -f docker-compose.prod.yml up -d postgres redis restate

docker cp /root/biibo-prod-seed.dump biibo-postgres:/tmp/seed.dump
docker exec biibo-postgres pg_restore -U biibo -d biibo_english \
  --no-owner --no-privileges -j4 /tmp/seed.dump
```

Kết quả đã kiểm: 93 bảng, 297 MB, 13 user, 145 session, 31.828 từ, 44 sách,
3 `ai_credentials`, 1 `storage_settings`, 1 `google_oauth_settings`.
(297 MB < 391 MB ở máy dev là bình thường — bản khôi phục chưa có bloat.)

Phiên bản Postgres: dump từ 16.13, nạp vào 16.15. Cùng dòng 16 nên đọc được;
nạp dump của dòng cao hơn vào dòng thấp hơn thì **không**.

**`goose up` sau đó là no-op, không cần đóng dấu tay.** Dump đã mang theo bảng
`goose_db_version` với `version_id = 1` ở trạng thái applied, mà `db/migrations/`
hiện chỉ có `00001_init.sql`. Nếu một ngày nào đó nạp một dump *không* kèm bảng
đó, khi ấy mới phải đóng dấu trước khi cho CI chạy migration:

```sql
INSERT INTO goose_db_version (version_id, is_applied) VALUES (0, true), (1, true);
```

Không đóng dấu thì `goose up` sẽ cố tạo lại 93 bảng đang có và gãy giữa chừng.

### Sửa dữ liệu sau khi nạp

Dump mang theo URL của máy dev. Hai bảng OAuth đã được sửa sang domain thật:

```sql
UPDATE google_oauth_settings SET redirect_url =
  'https://english.biibo.app/api/v1/auth/google/callback' WHERE id = 1;
UPDATE zalo_oauth_settings  SET redirect_url =
  'https://english.biibo.app/api/v1/auth/zalo/callback'  WHERE id = 1;
```

(Bản ở máy dev còn thừa một dấu chấm ở cuối URL Zalo — Zalo sẽ từ chối URI đó.
Đã bỏ luôn.)

Sau đó quét toàn bộ cột text/varchar của 93 bảng tìm chuỗi `localhost`: **không
còn dòng nào**. Lần sau nạp dump thì quét lại, đừng đoán:

```sql
DO $$ DECLARE r record; n bigint; BEGIN
  FOR r IN SELECT c.table_name, c.column_name FROM information_schema.columns c
           JOIN information_schema.tables t ON t.table_schema = c.table_schema
            AND t.table_name = c.table_name
           WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
             AND c.data_type IN ('text','character varying') LOOP
    EXECUTE format('select count(*) from %I where %I like %L',
                   r.table_name, r.column_name, '%localhost%') INTO n;
    IF n > 0 THEN RAISE NOTICE '% . % -> % dòng', r.table_name, r.column_name, n;
    END IF;
  END LOOP; END $$;
```

Quy tắc chung vẫn giữ: **sao lưu trước mọi thay đổi schema hoặc dữ liệu.**

### Nạp lại khi migration bị gộp

Bản gộp (`00001_init.sql` ôm luôn sáu migration sau v1.1.9) **không tự chạy trên
một DB đã từng chạy goose**: DB đó đã ghi `version_id = 1` là applied nên goose
bỏ qua file, và schema đứng nguyên ở chỗ cũ — deploy vẫn xanh, DB vẫn thiếu. Vì
vậy production được dựng lại thay vì migrate: dump từ dev (đã qua bản gộp), drop
database cũ, nạp lại đúng quy trình ở trên, rồi sửa lại hai URL OAuth.

```bash
# trên VPS, sau khi đã có dump mới và đã tắt app (docker compose stop api web)
docker exec biibo-postgres pg_dump -U biibo -Fc -d biibo_english -f /tmp/before-reseed.dump
docker cp biibo-postgres:/tmp/before-reseed.dump /root/   # giữ bản cũ đã, xoá là hết
docker exec biibo-postgres psql -U biibo -d postgres \
  -c "DROP DATABASE biibo_english;" -c "CREATE DATABASE biibo_english OWNER biibo;"
```

Dump mới mang theo `goose_db_version` chỉ còn đúng một dòng version 1, nên
`goose up` sau đó lại là no-op như cũ.

Khoảng một tháng nữa database sẽ tách sang VPS riêng để dùng chung cho nhiều
app. Khi đó `DATABASE_URL` trong `.env` trỏ ra máy mới, service `postgres` trong
compose bỏ đi, và PgBouncer (`profiles: ["future"]`) mới thực sự có việc — đọc
cảnh báo prepared statement trong `infrastructure.md` trước khi bật.

---

## 6. Nhánh, tag và vòng deploy

### Ba nhánh làm ba việc khác nhau

| | Vai trò | Đẩy lên đó thì sao |
|---|---|---|
| `dev` | nhánh phát triển, mọi việc hằng ngày | không deploy |
| `main` | "sẵn sàng phát hành" | **không deploy** |
| tag `v*` | một bản phát hành | **deploy lên production** |

**Đẩy lên `main` không deploy gì cả.** Chỉ đánh tag mới deploy. Tách như vậy để
production luôn là thứ gọi được tên — "đang chạy `v1.2.0`" — chứ không phải
"đang chạy cái commit cuối cùng ai đó đẩy lên main".

```bash
# làm việc hằng ngày
git switch dev
# ... commit ...
git push origin dev              # không deploy

# tới lúc phát hành
git switch main && git merge dev
git tag -a v1.0.0 -m "Ra mắt"
git push origin main v1.0.0      # tag này mới kích hoạt deploy
```

Đánh số theo semver: `v<lớn>.<nhỏ>.<vá>`. Chỉ tag khớp `v*` mới chạy workflow,
nên một tag nháp kiểu `thu-nghiem-1` sẽ bị bỏ qua.

### Workflow làm gì

> Mô tả dưới đây là quy trình gốc khi còn một repo. Giờ nó chia ba: bước 2 nằm
> ở `biibo-backend` (image api, kèm `go test`) và `biibo-vocab-english-web` (image web);
> bước 3 là workflow `stack-*` của repo này; bước 4 của backend chỉ `pull api
> migrate` → migrate → `up -d api` → chờ healthcheck, của web chỉ `up -d web`.
> Deploy backend trước, web sau: `concurrency` chỉ xếp hàng trong một repo.

1. **`verify`** — tag có nằm trên `main` không. Không thì dừng ngay, chưa build
   gì. Một tag có thể đánh ở bất kỳ đâu, kể cả một nhánh thử nghiệm; đây là chỗ
   chặn.
2. build + push hai image (song song, cache `type=gha` riêng từng scope). Mỗi
   image mang ba tag: `:latest`, `:v1.0.0`, và `:<sha>`.
3. `scp` `docker-compose.prod.yml`, `Caddyfile`, `backup.sh` lên `/opt/biibo`
4. ssh vào VPS: `docker login ghcr.io` bằng `GITHUB_TOKEN` của job → ghi
   `IMAGE_TAG=v1.0.0` vào `.env` → `pull` → `run --rm migrate` → `up -d` →
   `image prune -f` → `docker logout`
5. gọi `GET /vi` cho tới khi nhận 200, tối đa 2 phút

`IMAGE_TAG` trong `.env` giờ là tên phiên bản chứ không phải sha, nên
`docker compose ps` trên VPS đọc ra được ngay đang chạy bản nào.

`workflow_dispatch` vẫn chạy tay được từ một nhánh khi cần deploy lại — khi đó
nó dùng sha và ghi `::warning::` để không ai nhầm với một bản phát hành.

Migration chạy **trước** khi đổi container app, để code mới luôn gặp schema mới.
Đảo thứ tự là code mới chạy trên schema cũ.

`concurrency` xếp hàng các lần deploy: hai lần chồng nhau sẽ đua nhau chạy
migration.

Chạy tay khi cần (ví dụ vừa sửa `.env`):

```bash
cd /opt/biibo && docker compose -f docker-compose.prod.yml up -d
```

Vì CI đã ghim `API_TAG`/`WEB_TAG`/`ADMIN_TAG` vào `.env`, lệnh trên dựng lại đúng bản đang chạy chứ
không âm thầm nhảy sang `:latest`.

---

### Cái bẫy đã dính một lần

Script deploy đi vào VPS qua **stdin của ssh**. `docker compose run` mặc định
nối stdin của nó vào container, nên `run --rm migrate` đã nuốt luôn phần script
còn lại: `up -d` không bao giờ chạy, mà bước deploy vẫn xanh — CI báo thành công
trong khi trên máy chỉ có postgres/redis/restate, không có web/api/caddy. Đúng
kiểu hỏng tệ nhất: im lặng.

Vì vậy lệnh đó viết là `run --rm -T migrate </dev/null`, và cuối script có một
mốc `echo "DEPLOY_SCRIPT_HOAN_TAT"`. Không thấy dòng mốc đó trong log thì script
đã bị cắt ngắn, bất kể job màu gì. Quy tắc chung: mọi lệnh thêm vào khối heredoc
này mà có thể đọc stdin đều phải chặn bằng `</dev/null`.

## 7. Sao lưu database

`backup.sh` chạy bằng `biibo-backup.timer` mỗi ngày **03:00 (+07)**, ghi
vào `/opt/biibo/backups/biibo-english-vocab-<ngày>-<giờ>.dump`, giữ **3 bản** trên
đĩa và **3 ngày** trên R2 (~150 MB, DB 51 MB nén).

> Cửa sổ 3 ngày là lựa chọn có chủ đích của chủ dự án, không phải giới hạn kỹ
> thuật. Đánh đổi: dữ liệu hỏng mà phát hiện vào ngày thứ tư thì không còn bản
> sạch nào để quay về — mà kiểu hỏng nguy hiểm nhất (`UPDATE` sai ở một bảng ít
> ai nhìn) lại đúng là kiểu âm thầm. Muốn nới ra thì đổi `KEEP` ở đầu
> `backup.sh` và số ngày ở dòng `rclone delete --min-age`, không phải sửa
> gì thêm.

Script làm ba việc mà một dòng `pg_dump` trần không làm:

1. **Đọc thử mục lục ngay trong container** trước khi chép ra. `pg_dump` trả về
   0 vẫn có thể để lại file không khôi phục được — hết đĩa giữa chừng chẳng hạn.
2. **Đối chiếu số byte** giữa file trong container và file đã chép ra.
3. **Chỉ xoá bản cũ sau khi bản mới qua kiểm.** Dọn trước là có ngày còn lại
   đúng một bản hỏng.

Tên file chỉ được đổi từ `.partial` sang tên thật ở bước cuối. Một bản dump đứt
giữa chừng mà mang đúng tên thật là thứ nguy hiểm nhất: nó trông như bản sao lưu
hợp lệ cho tới lúc cần dùng.

```bash
systemctl list-timers biibo-backup.timer   # lần chạy kế tiếp
journalctl -u biibo-backup.service -n 20   # kết quả lần gần nhất
systemctl start biibo-backup.service       # chạy tay ngay bây giờ
ls -lh /opt/biibo/backups/
```

### Khôi phục

Nạp vào một database nháp trước, **không** nạp đè thẳng lên `biibo_english`:

```bash
docker cp /opt/biibo/backups/<file>.dump biibo-postgres:/tmp/d.dump
docker exec biibo-postgres psql -U biibo -d postgres \
  -c 'CREATE DATABASE restore_drill'
docker exec biibo-postgres pg_restore -U biibo -d restore_drill \
  --no-owner --no-privileges -j4 /tmp/d.dump
# đối chiếu số dòng rồi mới quyết định làm gì với bản thật
docker exec biibo-postgres psql -U biibo -d postgres -c 'DROP DATABASE restore_drill'
```

Đã diễn tập ngày 2026-09-12: bản khôi phục khớp bản thật từng con số
(13 user / 145 session / 31.828 từ / 3 ai_credentials). **Một bản sao lưu chưa
từng được nạp thử thì chưa phải bản sao lưu** — chạy lại bài này mỗi lần đổi
phiên bản Postgres hoặc đổi máy.

### Đẩy ra ngoài máy (R2)

Bản trên đĩa cứu được lỗi người — xoá nhầm bảng, migration hỏng, `UPDATE` thiếu
`WHERE`. Nó **không** cứu được mất VPS: đĩa hỏng, nhà cung cấp xoá máy,
ransomware. Bước dưới đây mới là bước cứu được.

`rclone` đã cài sẵn trên VPS. Script tự tìm `/opt/biibo/rclone.conf`; **không có
file đó thì nó bỏ qua trong im lặng và vẫn thoát 0**, để bản sao lưu trên đĩa
không phụ thuộc vào việc đã cấu hình R2 hay chưa. Nhưng nếu file có mà upload
hỏng thì script **báo lỗi** — một bản sao lưu tưởng là đã ra ngoài mà thực ra
không, còn tệ hơn là biết mình không có.

Đã cấu hình 2026-09-13. Bucket `biibo-backup` (Private, APAC), mỗi app một thư
mục con — app này là `biibo-english-vocab`, và tên file dump mang luôn tiền tố
đó. Một bucket sẽ chứa bản sao lưu của nhiều app, nên file phải tự nói được nó
thuộc về đâu kể cả khi bị lôi ra khỏi thư mục gốc.

Token là R2 API token **riêng cho backup**, quyền *Object Read & Write* giới hạn
đúng bucket `biibo-backup`. Không dùng lại token media trong `storage_settings`:
token đó mã hoá AES trong DB nên script shell không đọc được, và quyền của nó
rộng hơn mức cần — lộ token backup thì kẻ tấn công đọc/ghi được bản sao lưu
nhưng không chạm được ảnh đang phục vụ người dùng.

Dựng lại từ đầu (hoặc cho app thứ hai):

1. Cloudflare → R2 → bucket `biibo-backup` (**Private**, không public URL,
   không custom domain — trong đó là dữ liệu người dùng thật)
2. R2 → `{} API` → Manage API Tokens → Create, **Object Read & Write**, chọn
   riêng bucket đó. Secret chỉ hiện một lần.
3. Trên VPS:

```bash
cat > /opt/biibo/rclone.conf <<'EOF'
[r2]
type = s3
provider = Cloudflare
region = auto
access_key_id = <Access Key ID>
secret_access_key = <Secret Access Key>
endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
acl = private
# Bat buoc. Token chi co quyen tren mot bucket, khong tao duoc bucket moi;
# thieu dong nay thi rclone goi CreateBucket truoc moi lan upload va an 403.
no_check_bucket = true
EOF
chmod 600 /opt/biibo/rclone.conf

systemctl start biibo-backup.service   # chạy thử ngay
journalctl -u biibo-backup.service -n 5
```

Hai điều dễ tưởng là hỏng mà thật ra đúng:

- `rclone lsd r2:` trả **403 AccessDenied**. Đúng — token bị giới hạn một bucket
  nên không được liệt kê cả tài khoản. Thử bằng `rclone lsf r2:biibo-backup/`.
- Bucket rỗng sau khi tạo. Đúng, tới lần chạy đầu mới có file.

Kiểm bản trên R2 có dùng được không (upload thành công chưa chắc file còn
nguyên): kéo ngược về, đối chiếu md5 với bản trên đĩa, rồi `pg_restore -l`. Đã
làm 2026-09-13 — md5 khớp, đọc ra đủ 93 bảng.

Ngoài đó giữ **3 ngày**, bằng với trên đĩa.

`rclone.conf` **không** nằm trong repo và CI không bao giờ ghi đè nó, giống
`.env`.

### Không nằm trong bản sao lưu

- **`/restate-data`** — cố ý không sao lưu. Restate chỉ giữ việc đang chạy dở
  (gửi thông báo hàng loạt, email, chấm điểm câu) và journal 1 ngày; mọi dữ
  liệu nghiệp vụ nằm trong Postgres. Bản chép 3 giờ sáng không cứu được việc
  chạy lúc 3 giờ chiều, còn chép lúc Restate đang ghi dễ ra bản hỏng. Mất store
  thì xoá thư mục, khởi động lại và đăng ký lại handler (§9); trong lúc chưa
  đăng ký, code tự chạy inline. Một đợt thông báo đang gửi dở thì gửi lại —
  id cố định nên người đã nhận không nhận lần hai.
- **`/opt/biibo/.env`** — mất file này thì `AI_KEY_ENCRYPTION_SECRET` mất theo,
  và mọi credential đã mã hoá trong DB thành rác vĩnh viễn, kể cả khi database
  còn nguyên vẹn.

  Hiện có **một** bản sao ở máy dev: `.env.vps` trong thư mục repo, `chmod 600`,
  dính luật `.env*` của `.gitignore` nên `git add` từ chối (phải `-f` mới thêm
  được). Đặt tên `.env.vps` chứ không phải `.env.production` là có lý do: Next
  **tự nạp** `.env.production` và `.env.production.local` khi chạy ở chế độ
  production, nên cái tên đó sẽ có ngày kéo mật khẩu Postgres của server vào một
  lần build ở máy cá nhân.

  Một bản trong thư mục làm việc **chưa phải là đã sao lưu** — `git clean -xdf`
  xoá được nó. Cất thêm một bản trong trình quản lý mật khẩu. Và **đừng** gộp nó
  vào thư mục backup: gộp vào là ngày nào đó đẩy backup lên R2 sẽ đẩy luôn khoá
  giải mã đi cùng đúng dữ liệu mà nó mở.

---

## 8. Quay lui

```bash
cd /opt/biibo
sed -i 's|^API_TAG=.*|API_TAG=v1.0.0|' .env    # hoặc WEB_TAG — tên bản phát hành cũ
docker compose -f docker-compose.prod.yml up -d
```

Image mang cả tag phiên bản lẫn sha, nên quay lui bằng tên bản (`v1.0.0`) hay
bằng sha đều được — tên bản dễ đọc hơn khi đang vội.

Chỉ quay lui được **code**. Migration không tự lùi: nếu bản lỗi có kèm migration
thì phải `goose down` một cách có chủ đích, sau khi đã xem migration đó làm gì.

---

## 9. Restate: đăng ký handler

Restate gọi ngược vào binary Go để chạy việc nền (gửi mail, chấm điểm phát âm,
bắn thông báo). Lần đầu, và **mỗi lần đổi chữ ký handler**, phải đăng ký lại.

Cổng admin 9070 bind `127.0.0.1`, nên chạy thẳng trên VPS là gọn nhất:

```bash
ssh root@<VPS>
curl -X POST http://127.0.0.1:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri":"http://api:9080"}'
```

`api:9080` là tên service trong compose, **không** phải `host.docker.internal`
như ở máy dev. Restate là bên gọi đi, nên địa chỉ phải giải được từ trong mạng
compose.

Đã đăng ký ngày 2026-09-12, trả về `201` với ba service: `Broadcast/Fanout`,
`Scoring/ScoreSentence`, `Email/Send`. Đăng ký lại 2026-09-13 sau khi xoá store
(xem ngay dưới đây).

### Tên node — cái bẫy làm gãy mọi lần tạo lại container

Restate lấy tên node từ **hostname**, mà Docker đặt hostname bằng container ID.
Tạo lại container là có ID mới, là tên node mới, và nó từ chối khởi động trên dữ
liệu của tên cũ:

```
[RT0002] invalid configuration: node-name is required: The working directory
'/restate-data' contains data from node '727d0a836932' but the default node
name is 'a490eede114b'.
```

Nó không gãy khi restart (restart giữ nguyên container), chỉ gãy khi **tạo lại**
— tức là đúng vào lúc nâng version, đổi `ports`, hay bất kỳ thay đổi compose nào
chạm tới service này. Container cứ khởi động lại vòng tròn, còn `docker compose
up -d` vẫn báo `Started`.

Vì vậy `docker-compose.prod.yml` đặt cứng `RESTATE_NODE_NAME: biibo-restate`.
**Đừng bỏ dòng đó.** Tài liệu Restate nói rõ: tên node không được đổi trừ khi
khởi động với store rỗng.

Gặp lỗi này trên một máy chưa có dòng đó: store chỉ chứa bản đăng ký deployment
chứ không chứa dữ liệu người dùng, nên đường ra rẻ nhất là sao lưu volume, xoá
sạch, đặt tên cố định rồi đăng ký lại (đúng những gì đã làm ngày 2026-09-13):

```bash
docker run --rm -v biibo_restatedata:/d -v /opt/biibo/backups:/b alpine \
  tar czf /b/restate-data-$(date +%Y%m%d-%H%M).tar.gz -C /d .
docker compose -f docker-compose.prod.yml rm -sf restate
docker run --rm -v biibo_restatedata:/d alpine sh -c 'rm -rf /d/* /d/.[!.]*'
docker compose -f docker-compose.prod.yml up -d restate
# rồi đăng ký lại bằng lệnh curl ở trên
```

Cách còn lại là đặt `RESTATE_NODE_NAME` bằng đúng container ID cũ để nạp lại dữ
liệu — giữ được state, nhưng danh tính hệ thống từ đó mang một chuỗi hex vô
nghĩa vĩnh viễn.

### Ghim version

Image là `restate:1.7.9`, **không** phải `:latest`. Restate giữ journal RocksDB
trên đĩa; một lần `compose pull` kéo về bản major mới rồi restart im lặng là
chuyện không ai muốn gặp lúc 3 giờ sáng. Nâng bản = đọc release notes, đổi số
trong compose, deploy như mọi thay đổi khác. Kiểm bản đang chạy:
`docker exec biibo-restate restate-server --version`.

Xem lại bất cứ lúc nào: `curl -s http://127.0.0.1:9070/deployments`. Muốn mở UI
thì tạo đường hầm rồi vào `http://localhost:9070`:

```bash
ssh -L 9070:127.0.0.1:9070 root@<VPS>
```

Restate self-host không có lớp đăng nhập cho cổng này — xác thực ở đây **chính
là** khoá SSH. Tuyệt đối không đổi binding sang `0.0.0.0`.

Chưa đăng ký thì không vỡ: mọi đường durable có nhánh chạy inline. Nhưng sẽ mất
việc đang chạy dở khi restart.

---

## 10. Khác biệt so với máy dev

| | Dev (`docker-compose.yml`) | Prod (`docker-compose.prod.yml`) |
|---|---|---|
| Next + Go | chạy tay trên host | container, kéo từ GHCR |
| Cổng ra internet | 5433/6380/9070/8090 mở trên máy cá nhân | **chỉ 80/443** |
| Cổng chỉ loopback | — | 5432, 6379, 9070 — vào qua hầm SSH (§12) |
| Postgres | `biibo`/`biibo` | `POSTGRES_PASSWORD` trong `.env` |
| Redis | không mật khẩu | `REDIS_PASSWORD`, bắt buộc |
| Restate gọi handler | `host.docker.internal:9080` | `api:9080` |
| TLS | không | Caddy + Let's Encrypt |
| PgBouncer | có, chưa nối | `profiles: ["future"]`, không chạy |

Prod là file **tự chứa**, không chồng lên file dev. Cơ chế merge của compose nối
thêm `ports` chứ không thay thế, nên một cổng dev lỡ sót lại trên máy có IP công
cộng là sự cố bảo mật — ở đây khai báo tường minh thay vì suy ra từ file khác.

---

## 11. Chưa cấu hình (site vẫn chạy, tính năng thì chưa)

Những thứ dưới đây thiếu credential chứ không thiếu code. Backend được viết để
**503 đúng một endpoint** thay vì sập, nên cứ lên production được; điền vào lúc
nào thì tính năng sống lúc đó.

| Thứ | Trạng thái | Điền ở đâu | Có phải deploy lại không |
|---|---|---|---|
| SMTP | ✅ AWS SES, người dùng đã gửi thử thành công 2026-09-23 | admin console | không |
| SePay (chuyển khoản VN) | `SEPAY_ACCOUNT/BANK/WEBHOOK_APIKEY` chưa có | `.env` trên VPS | `up -d`, không build lại |
| Polar (thẻ quốc tế) | `POLAR_ACCESS_TOKEN/WEBHOOK_SECRET` chưa có | `.env` trên VPS | `up -d`, không build lại |
| Redirect URI Google | ✅ đăng ký + đăng nhập thật OK 2026-09-13 | — | không |
| Redirect URI Zalo | chưa đăng ký ở phía Zalo | Zalo Developers | không |
| Cloudflare proxy | ✅ mây cam; Caddy đọc IP thật từ `CF-Connecting-IP` (2026-09-23) | — | không |
| Restate handler | ✅ đã đăng ký 2026-09-12 | — | có, khi đổi chữ ký handler |

Thanh toán là chỗ dễ hiểu nhầm nhất: `SepayEnabled()` và `PolarEnabled()`
(`internal/config/config.go`) đòi **cả** thông tin nhận tiền **và** credential
webhook. Thiếu một nửa thì gateway coi như tắt — cố tình như vậy, để checkout
không bao giờ mở trong khi webhook mãi mãi fail xác thực, tức là người mua bị
trừ tiền mà không được cấp gì.

## 12. Truy cập production từ máy cá nhân

Postgres, Redis và bảng điều khiển Restate **chỉ nghe trên `127.0.0.1` của
VPS**. Từ internet chúng không tồn tại — `nc -z <VPS> 5432` không mở được. Đường
vào duy nhất là đường hầm SSH, và như vậy thì xác thực của cả ba thứ này chính
là khoá SSH của bạn.

Mở một lần, dùng cho cả ba:

```bash
ssh biibo-tunnel
```

Alias đó nằm trong `~/.ssh/config` và tự mở cả ba đường:

```
Host biibo-tunnel
    HostName 103.173.154.168
    User root
    IdentityFile ~/.ssh/biibo_deploy
    LocalForward 5433  127.0.0.1:5432
    LocalForward 6380  127.0.0.1:6379
    LocalForward 19070 127.0.0.1:9070
    SessionType none
    ExitOnForwardFailure yes
```

Cổng phía máy cá nhân cố tình lệch (5433, 6380, 19070) vì **máy dev đã chiếm
5432, 6379 và 9070**. Trùng cổng là cái bẫy tệ nhất ở đây: `ssh` chỉ in một dòng
`bind: Address already in use` rồi chạy tiếp, và công cụ của bạn im lặng nói
chuyện với **dev** trong khi bạn đinh ninh đang xem production. `ExitOnForwardFailure
yes` biến chuyện đó thành lỗi dừng hẳn thay vì một sự nhầm lẫn êm ái.

Muốn chắc mình đang xem đúng máy thì hỏi Restate nó đăng ký ai:

```bash
curl -s http://127.0.0.1:19070/deployments | grep -o 'http://[^"]*'
#   http://api:9080/                 -> production
#   http://host.docker.internal:9080 -> dev
```

| Công cụ | Thông số |
|---|---|
| DataGrip / psql | host `localhost`, cổng `5433`, database `biibo_english`, user `biibo`, mật khẩu = `POSTGRES_PASSWORD` trong `/opt/biibo/.env` |
| redis-cli | `redis-cli -h 127.0.0.1 -p 6380 -a "$REDIS_PASSWORD"` |
| Restate UI | mở `http://localhost:19070/ui/` |

DataGrip có sẵn tab **SSH/SSL → Use SSH tunnel** nên không cần chạy lệnh trên:
host `103.173.154.168`, user `root`, khoá `~/.ssh/biibo_deploy`; phần Database
điền host `127.0.0.1` cổng `5432` (tức là nhìn từ phía VPS).

Không cần đường hầm thì dùng thẳng trên VPS:

```bash
ssh biibo
docker exec -it biibo-postgres psql -U biibo -d biibo_english
docker exec -it biibo-redis sh -c 'redis-cli -a "$REDIS_PASSWORD"'
```

**Đang sửa production.** `\set AUTOCOMMIT off` trước khi gõ `UPDATE`/`DELETE`
thủ công, và chạy `bash /opt/biibo/backup.sh` trước mọi thay đổi dữ liệu — §7.

### Docs API

Scalar UI ở `/v1/docs`, bản OpenAPI ở `/v1/openapi.json`. Qua Next thì thành:

- https://english.biibo.app/api/v1/docs
- https://english.biibo.app/api/v1/openapi.json

Trên production cả hai **nằm sau mật khẩu** (HTTP Basic, do Caddy chặn ở biên —
xem `Caddyfile`). Không phải vì các endpoint kia hở: chúng vẫn đòi xác
thực. Lý do là bản đặc tả liệt kê 216 endpoint, trong đó 81 cái `/admin/` kèm
schema request — tấm bản đồ đó không nên tặng không cho người dò.

Tài khoản nằm ở `/opt/biibo/caddy.env` (bản sao máy cá nhân: `.env.vps.caddy`).
Trên máy dev không có lớp chặn nào: `http://localhost:8080/v1/docs`.

**Codegen không đi qua đây.** `scripts/update-openapi-auto.js` đọc thẳng
`BACKEND_INTERNAL_URL` (tức `http://api:8080` lúc build, `localhost:8080` ở máy
dev), nên `pnpm build` không hề chạm vào Caddy. Đổi mật khẩu không làm gãy build.

### Hai cái bẫy của lớp mật khẩu này

Hash bcrypt **chứa ký tự `$`** (`$2a$14$…`), và compose diễn giải `$` như biến.
Hai hệ quả, cả hai đều biểu hiện giống hệt nhau — Caddy trả 401 cho cả mật khẩu
đúng, không một dòng log nào giải thích:

1. Truyền hash qua `environment:` là mất từng đoạn. Phải dùng `env_file`.
2. **`env_file` cũng bị diễn giải** (compose v5.5.1 — trái với điều nhiều người
   tưởng), nên trong `caddy.env` mỗi `$` phải viết thành `$$`. Hash 60 ký tự tới
   container chỉ còn 49.

Cách kiểm nhanh khi nghi ngờ, đừng đoán:

```bash
docker exec biibo-caddy sh -c 'printenv DOCS_AUTH_HASH | tr -d "\n" | wc -c'   # phải là 60
```

Đổi mật khẩu:

```bash
docker run --rm caddy:2-alpine caddy hash-password --plaintext '<mat khau moi>'
# roi sua DOCS_AUTH_HASH trong /opt/biibo/caddy.env — NHỚ thay mỗi $ thành $$
docker compose -f docker-compose.prod.yml up -d caddy
```

`caddy.env` không nằm trong repo và CI không bao giờ ghi đè nó, giống `.env`.
Thiếu file đó thì `up -d` sẽ hỏng ngay, không im lặng.

---

## 13. Danh sách kiểm trước khi ra mắt

Hạ tầng đã xong và đã chứng minh được. Phần dưới là những gì còn lại giữa hôm
nay và ngày mở cửa — bỏ dở chỗ nào thì quay lại đúng chỗ đó.

### Đã xong, đã kiểm chứng

| | Bằng chứng |
|---|---|
| Site chạy HTTPS | `/vi` trả 200, chứng chỉ Let's Encrypt |
| Deploy theo tag | `v1.0.0`, run 34730174457 xanh cả 4 job; đẩy `main` không deploy |
| Database | `users=13 sessions=146 bảng=93`; `goose` báo `current version: 1` |
| Sao lưu | 3 bản trên đĩa + 3 ngày trên R2; đã nạp thử lại thành công 2 lần |
| Đăng nhập Google | đăng nhập thật thành công 13/09, `sessions` tăng 145→146 |
| Docs API | sau mật khẩu, 401 với người lạ (§12) |
| Đường quản trị | hầm SSH tới Postgres/Redis/Restate, đã thử cả ba (§12) |
| SSH | chỉ vào bằng khoá, mật khẩu đã tắt |
| SMTP | AWS SES đã cấu hình, gửi mail thử thành công 23/09 |
| UptimeRobot | 2 monitor 5 phút: `/vi` (web) và `/api/v1/auth/me` (Go qua Next), báo qua app điện thoại (23/09) |
| Cloudflare | mây cam, `cf-ray` có trong header; access log ghi IP khách thật, header `X-Forwarded-For` giả bị bỏ qua (23/09) |

### Còn phải làm trước khi mở cửa

Xếp theo thứ tự "hỏng thì đau đến đâu":

1. **Lỗi trong code chưa ai thấy.** Chưa có Sentry: một endpoint trả 500 hay
   lỗi JS chỉ lộ ra khi người dùng báo. (Site sập hẳn thì UptimeRobot đã báo.)
2. **SePay/Polar chưa có credential** → checkout trả 503. Không bán được gì.
   Nhớ: cần **cả** thông tin nhận tiền **và** credential webhook, thiếu một nửa
   thì gateway coi như tắt (§11).
3. **Zalo redirect URI** chưa đăng ký → nút đăng nhập Zalo sẽ hỏng đúng kiểu
   Google đã hỏng trước 13/09.

---

## 14. Nợ kỹ thuật của chính khâu vận hành

- Bật xác thực chữ ký cho handler Restate (`server.WithIdentityV1`).
- Sentry (`infrastructure.md` §7). UptimeRobot đã báo khi site sập hẳn, nhưng
  lỗi trong code (một endpoint 500, lỗi JS) vẫn im lặng tới khi người dùng báo.
- Zero-downtime: `up -d` có một khoảng gián đoạn ngắn khi đổi container.
- ~~`PasswordAuthentication`~~ đã tắt 2026-09-12
  (`/etc/ssh/sshd_config.d/01-biibo-hardening.conf`). Tên file bắt đầu bằng
  `01-` là có chủ đích: sshd lấy **giá trị đầu tiên** đọc được, nên file đặt ở
  `99-` sẽ thua `50-cloud-init.conf` mà `sshd -t` vẫn báo hợp lệ. Từ giờ mất
  khoá riêng là mất quyền vào máy.

---

## Liên quan

- `deployment-log.md` — nhật ký dựng máy 2026-09-12, theo đúng thứ tự đã chạy
- `infrastructure.md` — kiến trúc, sức chứa, danh sách lỗ hổng phải đóng
- `performance-scalability.md` — quy tắc khi thêm endpoint/truy vấn
- `seo.md` — vì sao `NEXT_PUBLIC_URL` phải đúng ngay từ lúc build
