# Nhật ký dựng production — 2026-09-12

Bản ghi theo đúng thứ tự đã làm trên máy `103.173.154.168` để đưa
`https://english.biibo.app` lên, kể cả hai chỗ làm sai và cách sửa.

`deployment.md` là sách hướng dẫn **nên làm thế nào**. File này là **đã làm gì,
theo thứ tự nào** — đọc nó khi cần dò lại một bước, hoặc khi dựng máy thứ hai.

Toàn bộ diễn ra trong khoảng 19:00–22:15 (+07).

---

## 0. Trạng thái xuất phát

- Repo: `nguyenmanh18/biibo-vocabulary`, nhánh `main`
- VPS trắng: Ubuntu 24.04 LTS, 6 vCPU / 15 GiB RAM / 98 GB đĩa, mới cài, chỉ có
  `sshd` và `systemd-resolve` lắng nghe; chưa có Docker; ufw tắt
- DNS `english.biibo.app` đã trỏ thẳng về IP VPS (mây xám)
- Database thật nằm ở máy dev, chưa có bản nào trên server

---

## 1. Chuẩn bị trong repo (commit `d60a48f`, `39a9fb6`)

Trước khi đụng tới VPS, repo phải đóng gói được:

- `next.config.ts`: thêm `output: "standalone"`
- `Dockerfile` (Next, 3 tầng) và `backend/Dockerfile` (Go + goose)
- `.dockerignore`, `backend/.dockerignore`
- `docker-compose.prod.yml` — **tự chứa**, không chồng lên file dev
- `Caddyfile`
- `.github/workflows/deploy.yml`
- Dọn sạch toàn bộ code crawler/offline pipeline (22 lệnh `backend/cmd/*`,
  `internal/wordgen`, `internal/ingest`, `data/` 230 MB, `plans/`)

Xác minh trước khi lên máy: `go build` và `go vet` sạch, `npx tsc --noEmit` sạch,
`docker build` hai image thành công (97 MB api / 229 MB web), chạy thử container
web → `GET /vi` trả 200 với canonical đúng domain thật.

---

## 2. Vào VPS, dựng nền

```bash
# khoá SSH đã được cài trước bằng ssh-copy-id, thêm mục vào ~/.ssh/config:
#   Host biibo
#     HostName 103.173.154.168
#     User root
#     IdentityFile ~/.ssh/biibo_deploy
#     IdentitiesOnly yes

ssh biibo
curl -fsSL https://get.docker.com | sh      # Docker 29.8.0 + Compose v5.5.1
mkdir -p /opt/biibo && chmod 700 /opt/biibo
```

### `.env`

Sinh trên máy dev rồi `scp` lên, **không gõ giá trị qua màn hình**:

- `POSTGRES_PASSWORD`, `REDIS_PASSWORD` — `openssl rand -base64 24`, sinh mới
- `AI_KEY_ENCRYPTION_SECRET` — **chép nguyên văn từ `.env.local`**, đối chiếu
  checksum hai đầu để chắc không lệch một ký tự
- `APP_BASE_URL` / `GOOGLE_REDIRECT_URL` / `ZALO_REDIRECT_URL` → domain thật
- `SESSION_COOKIE_NAME=biibo_session`, `SESSION_COOKIE_SECURE=true`
- `COMING_SOON=1`, `IMAGE_TAG=latest`

Không chép sang: mọi biến chỉ có nghĩa ở máy dev (`DEV_FALLBACK_USER_ID`,
`QGEN_*`, `YTDLP_*`, `NEXT_PUBLIC_GRAPHQL_URL`…). Google/Zalo/AI/R2/TTS/STT
**không nằm trong `.env`** — chúng đọc từ các bảng `*_settings` trong DB.

```bash
chmod 600 /opt/biibo/.env
```

### Tường lửa

Mở cổng **trước**, bật **sau** — ngược lại là tự khoá mình khỏi SSH:

```bash
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp
ufw default deny incoming && ufw default allow outgoing
ufw --force enable
```

---

## 3. Dựng hạ tầng, chưa dựng app

Cố ý tách làm hai nhịp: khôi phục database xong mới cho app chạy.

```bash
cd /opt/biibo
docker compose -f docker-compose.prod.yml up -d postgres redis restate
ss -ltnp | grep -v 127.0.0.1     # chỉ được thấy cổng 22
```

---

## 4. Chuyển database từ máy dev sang

```bash
# máy dev
pg_dump -Fc -d vocahero -f biibo-prod-seed.dump      # 51 MB
scp biibo-prod-seed.dump biibo:/root/
md5sum / md5 -q hai đầu → phải khớp

# VPS
docker cp /root/biibo-prod-seed.dump biibo-postgres:/tmp/seed.dump
docker exec biibo-postgres pg_restore -l /tmp/seed.dump | head   # đọc thử trước
docker exec biibo-postgres pg_restore -U vocahero -d vocahero \
  --no-owner --no-privileges -j4 /tmp/seed.dump
```

Kiểm sau khi nạp: 93 bảng, 297 MB, **13 user / 145 session** (giữ nguyên theo
yêu cầu), 31.828 từ, 44 sách, 3 `ai_credentials`, 1 `storage_settings`.

Phiên bản: dump từ Postgres 16.13 → nạp vào 16.15. Cùng dòng 16 nên đọc được.

### goose

Kiểm tra trước khi cho CI chạy migration:

```sql
select id, version_id, is_applied from goose_db_version order by id;
-- 0|t , 0|t , 1|t
```

Dump đã mang sẵn version 1 applied, mà `backend/db/migrations/` chỉ có
`00001_init.sql` → **`goose up` là no-op, không phải đóng dấu tay**. (Về sau CI
xác nhận: `goose: no migrations to run. current version: 1`.)

### Sửa dữ liệu mang theo từ máy dev

```sql
UPDATE google_oauth_settings SET redirect_url =
  'https://english.biibo.app/api/v1/auth/google/callback' WHERE id = 1;
UPDATE zalo_oauth_settings  SET redirect_url =
  'https://english.biibo.app/api/v1/auth/zalo/callback'  WHERE id = 1;
```

URL Zalo ở máy dev còn thừa **một dấu chấm cuối** — Zalo sẽ từ chối URI đó. Đã
bỏ luôn.

Rồi quét toàn bộ cột text/varchar của 93 bảng tìm `localhost` (script SQL ở
`deployment.md` §5): **không còn dòng nào**.

---

## 5. Cấu hình GitHub

Khoá SSH **riêng cho CI**, không dùng chung khoá cá nhân:

```bash
ssh-keygen -t ed25519 -f biibo_ci -N "" -C "github-actions-deploy@biibo"
# thêm vào authorized_keys với hạn chế:
#   no-agent-forwarding,no-X11-forwarding,no-user-rc ssh-ed25519 AAAA... 
```

```bash
R=nguyenmanh18/biibo-vocabulary
ssh-keyscan -t rsa,ecdsa,ed25519 103.173.154.168 > vps_hostkey

gh secret set VPS_HOST         --repo $R --body "103.173.154.168"
gh secret set VPS_USER         --repo $R --body "root"
gh secret set VPS_SSH_KEY      --repo $R < biibo_ci        # đọc từ file
gh secret set VPS_SSH_HOST_KEY --repo $R < vps_hostkey
gh variable set NEXT_PUBLIC_URL --repo $R --body "https://english.biibo.app"
gh variable set DEPLOY_DIR      --repo $R --body "/opt/biibo"
```

### Không tạo PAT cho GHCR

Thay vì cất một PAT dài hạn trên VPS, bước deploy cho VPS **mượn `GITHUB_TOKEN`
của chính lần chạy đó**: `docker login` → `pull` → `docker logout`. Job `deploy`
khai thêm `permissions: packages: read` để token đủ quyền.

Đổi lại: giữa hai lần deploy, `docker pull` bằng tay trên VPS báo
`unauthorized`. Muốn lên bản mới thì chạy lại workflow.

---

## 6. Lần deploy đầu — CI báo xanh nhưng máy trống

Push `main` (lúc đó workflow còn chạy theo nhánh, chưa theo tag) → build hai
image OK, `scp` OK, `goose` OK… rồi bước kiểm tra HTTPS
trả `HTTP 000` suốt 2 phút. Lên máy xem: **không có container web/api/caddy nào
tồn tại**.

**Nguyên nhân.** Script deploy đi vào máy qua **stdin của `ssh`**
(`ssh host bash -s <<'REMOTE'`). `docker compose run` mặc định nối stdin của nó
vào container, nên `run --rm migrate` đã nuốt trọn phần script còn lại —
`up -d`, `image prune`, `docker logout` không bao giờ chạy. Và bước đó vẫn
**exit 0**, nên CI báo thành công.

**Sửa** (`e877ab6`):

```bash
docker compose -f docker-compose.prod.yml run --rm -T migrate </dev/null
...
echo "DEPLOY_SCRIPT_HOAN_TAT"      # mốc cuối script
```

Không thấy dòng mốc trong log = script đã bị cắt ngắn, bất kể job màu gì.

> Quy tắc rút ra: mọi lệnh thêm vào khối heredoc đó mà có thể đọc stdin đều phải
> chặn bằng `</dev/null`.

---

## 7. Bật app, lấy chứng chỉ

Image đã nằm sẵn trên máy sau lần pull hỏng, nên bật tay để có phản hồi ngay:

```bash
cd /opt/biibo && docker compose -f docker-compose.prod.yml up -d --remove-orphans
docker logs biibo-caddy | tail
# → "certificate obtained successfully" từ Let's Encrypt qua HTTP-01
```

Kiểm bằng request thật từ máy dev:

| Thử | Kết quả |
|---|---|
| `/vi`, `/en`, `/vi/books`, `/robots.txt`, `/sitemap.xml` | 200 |
| `http://` → | 308 sang HTTPS |
| chứng chỉ | `issuer=Let's Encrypt`, `subject=english.biibo.app` |
| canonical trong HTML | `https://english.biibo.app/vi` ✓ |
| `/api/v1/books` | JSON thật từ Postgres, ảnh bìa từ R2 |
| `/api/v1/auth/google` | 302 sang Google, `redirect_uri` đúng domain thật |

Cái cuối quan trọng nhất: Google OAuth đọc cấu hình **từ DB** và **giải mã được
client secret** → chứng minh `AI_KEY_ENCRYPTION_SECRET` đã chép đúng.

### Restate

```bash
curl -X POST http://127.0.0.1:9070/deployments \
  -H 'content-type: application/json' -d '{"uri":"http://api:9080"}'
# → 201, ba service: Broadcast/Fanout, Scoring/ScoreSentence, Email/Send
```

Sau khi sửa lỗi ở §6, push lại → workflow xanh trọn vẹn, bao gồm cả
`OK — https://english.biibo.app/vi trả về 200`.

---

## 8. Sao lưu (commit `5daf95a`, `04d32d9`)

Máy đang có database thật với người dùng thật và **không có bản sao lưu nào**.

- `backup.sh` + `biibo-backup.timer`, chạy 03:00 hằng ngày
- Giữ 3 bản ở `/opt/biibo/backups/`, 3 ngày trên R2 (cửa sổ do chủ dự án chọn)
- Bucket `biibo-backup`, thư mục con `biibo-english-vocab` — một bucket dùng
  chung cho nhiều app, nên tên file mang luôn tiền tố app
- Script tự kiểm: đọc mục lục trong container, đối chiếu số byte khi chép ra,
  chỉ xoá bản cũ sau khi bản mới qua kiểm, dùng tên `.partial` tới phút chót

**Lỗi đã dính:** bản đầu viết `docker exec biibo-postgres sh -c "cat > ..."` mà
thiếu `-i`, nên stdin không được nối, file kiểm tra rỗng, script báo dump hỏng
trong khi dump 51 MB hoàn toàn tốt. Sửa bằng cách kiểm ngay trong container
trước khi chép ra.

**Diễn tập khôi phục** — thứ duy nhất chứng minh bản sao lưu có giá trị:

```bash
docker exec biibo-postgres psql -U vocahero -d postgres -c 'CREATE DATABASE restore_drill'
docker exec biibo-postgres pg_restore -U vocahero -d restore_drill \
  --no-owner --no-privileges -j4 /tmp/drill.dump
# đối chiếu: vocahero 13|145|31828|3  ==  restore_drill 13|145|31828|3  ✓
docker exec biibo-postgres psql -U vocahero -d postgres -c 'DROP DATABASE restore_drill'
```

`backup.sh` được thêm vào danh sách `scp` của workflow, nên nó đi cùng mỗi lần
deploy thay vì thành file mồ côi trên máy.

---

## 9. Khoá SSH lại, chỉ cho vào bằng khoá

```bash
cat > /etc/ssh/sshd_config.d/01-biibo-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t

# hẹn sẵn lệnh tự hoàn tác — nếu không đăng nhập lại được để huỷ nó,
# sau 5 phút máy tự trở về như cũ
systemd-run --on-active=300 --unit=sshd-rollback \
  bash -c "rm -f /etc/ssh/sshd_config.d/01-biibo-hardening.conf; systemctl restart ssh"

systemctl restart ssh
```

**Lỗi đã dính:** lần đầu đặt tên file `99-` cho "ghi đè lên cấu hình mặc định".
Sai hướng — **sshd lấy giá trị ĐẦU TIÊN đọc được**, nên `50-cloud-init.conf`
(có `PasswordAuthentication yes`) thắng, mà `sshd -t` vẫn báo hợp lệ và
`sshd -T` vẫn in `passwordauthentication yes`. Đổi thành `01-` mới ăn.

Kiểm rồi mới huỷ lệnh hoàn tác:

```bash
sshd -T | grep ^passwordauthentication      # → no
ssh biibo 'echo ok'                          # khoá cá nhân: vào được
ssh -i biibo_ci root@<IP> 'echo ok'          # khoá CI: vào được
ssh -o PubkeyAuthentication=no root@<IP>     # → Permission denied (publickey)
systemctl stop sshd-rollback.timer
```

Dòng cuối của lần thử thứ ba đổi từ `(publickey,password)` sang `(publickey)` —
đó mới là bằng chứng server không còn chào phương thức mật khẩu.

> Từ giờ **mất khoá riêng là mất quyền vào máy**. Giữ `~/.ssh/biibo_deploy` ở
> nơi khôi phục được.

---

## 10. Ngày 13/09: bỏ tên cũ "vocahero"

Ba thứ cùng mang cái tên đó, và chúng độc lập với nhau:

| Thứ | Cách đổi | Downtime |
|---|---|---|
| Module Go `vocahero` | `go mod edit -module biibo` + sửa 207 dòng import trong 91 file | không |
| Database `vocahero` → `biibo_english`, role → `biibo` | `ALTER DATABASE` + `ALTER ROLE` | ~2 phút |
| Volume `*_vocahero_*` → `*_pgdata`… | tạo volume mới rồi `cp -a` sang | nằm trong cùng cửa sổ trên |

Ba điều học được, cái thứ hai là cái đắt:

1. **Gạch dưới, không gạch ngang.** `biibo-english` sẽ buộc bọc nháy kép trong
   mọi lệnh psql và mọi connection string về sau. `biibo_english` thì không.

2. **`ERROR: session user cannot be renamed`.** Không thể đổi tên chính cái role
   mình đang đăng nhập, mà `vocahero` lại là superuser duy nhất. Phải mượn một
   superuser tạm rồi xoá đi:

   ```bash
   psql -U vocahero -d postgres -c "CREATE ROLE rename_helper SUPERUSER LOGIN"
   psql -U rename_helper -d postgres -c "ALTER ROLE vocahero RENAME TO biibo"
   psql -U biibo      -d postgres -c "DROP ROLE rename_helper"
   ```

   `ALTER DATABASE ... RENAME` thì phải đứng từ một database khác (`postgres`)
   và không còn kết nối nào tới database bị đổi tên.

3. **Đổi tên role có thể làm mất mật khẩu — nhưng lần này thì không.** Hash
   `md5` của Postgres nhúng tên đăng nhập vào trong hash, nên đổi tên role là
   mật khẩu vô hiệu ngay lập tức mà không báo gì. Hash `scram-sha-256` thì
   không nhúng. Đã kiểm trước khi làm:

   ```sql
   SELECT rolname, rolpassword LIKE 'SCRAM-SHA-256%' FROM pg_authid WHERE rolname='vocahero';
   ```

   Trả về `t`, nên `POSTGRES_PASSWORD` trong `.env` giữ nguyên không phải sửa.

**Volume Docker không đổi tên được** — không có lệnh nào cả. Phải `docker
compose down`, tạo volume mới, `cp -a` toàn bộ nội dung sang, rồi đổi khai báo
trong compose. Đối chiếu **số file** hai bên chứ đừng đối chiếu `du -sh`:
RocksDB của Restate cấp phát thưa, bản chép ra nhìn nhỏ hơn hẳn (4.7M → 712K)
trong khi không thiếu file nào.

Volume cũ được giữ lại làm lưới an toàn, xoá sau khi chạy ổn vài ngày:

```bash
docker volume rm biibo_vocahero_pgdata biibo_vocahero_redisdata biibo_vocahero_restatedata
```

Kiểm sau khi đổi: site 200, `users=13 sessions=145 bảng=93` y như trước, api
`healthy` (tức là role mới + mật khẩu cũ đi qua TCP được), `goose` vẫn nhận ra
`current version: 1`, backup chạy và đẩy lên R2 bình thường.

Còn sót lại một chữ `vocahero` **cố ý**: `vocahero-vertex` là tên service
account có thật trên Google Cloud. Sửa trong docs sẽ làm docs sai.

---

## 11. Ngày 13/09 (chiều): mở đường quản trị, khoá docs

Đăng nhập Google chạy thật sau khi chủ dự án đăng ký redirect URI — `sessions`
tăng 145 → 146. Cách kiểm mà **không cần trình duyệt**: mở URL mà app chuyển
hướng tới; sai cấu hình thì chính Google trả về trang `redirect_uri_mismatch`,
đúng thì trả về trang đăng nhập.

Ba thứ làm tiếp:

1. **Postgres và Redis trước đó không publish ra host chút nào**, nên DataGrip
   không có cửa vào kể cả qua hầm SSH. Giờ publish trên `127.0.0.1` — cổng vẫn
   không tồn tại với internet (đã thử `nc` từ ngoài vào: đóng).
2. **Docs API đang mở công khai**: `/api/v1/openapi.json` liệt kê 216 endpoint,
   81 cái `/admin/` kèm schema. Đã cho ra sau HTTP Basic ở Caddy.
3. Alias `biibo-tunnel` trong `~/.ssh/config` mở sẵn cả ba đường.

Hai cái bẫy, cả hai đều **im lặng**:

- **Hash bcrypt chứa `$`, mà compose diễn giải `$` như biến** — kể cả trong
  `env_file`, trái với điều thường được tin. Hash 60 ký tự tới container còn 49,
  Caddy trả 401 cho cả mật khẩu đúng và không log gì. Trong `caddy.env` mỗi `$`
  phải viết thành `$$`. Kiểm bằng:
  `docker exec biibo-caddy sh -c 'printenv DOCS_AUTH_HASH | wc -c'` → phải 60.
- **Máy dev đã chiếm 5432, 6379 và 9070.** Lần mở hầm đầu tiên, `ssh` in đúng
  một dòng `bind: Address already in use` rồi chạy tiếp, và phép thử "Restate
  production" thật ra đang đọc Restate của dev. Cổng phía máy cá nhân phải lệch
  (5433/6380/19070) và alias đặt `ExitOnForwardFailure yes`.

---

## 12. Còn lại

Xem `deployment.md` §13 (danh sách kiểm trước khi ra mắt) và §14 (nợ kỹ thuật).
Tóm tắt:

- Zalo redirect URI chưa đăng ký (Google đã xong 13/09)
- Bật mây cam Cloudflare + SSL **Full (strict)**
- SePay/Polar chưa có credential → checkout 503
- SMTP chờ AWS SES duyệt
- `/restate-data` chưa được sao lưu
- Ngày ra mắt: `COMING_SOON=0` trong `/opt/biibo/.env` rồi `up -d`

---

## Liên quan

- `deployment.md` — sách hướng dẫn vận hành thường ngày
- `infrastructure.md` — kiến trúc, sức chứa
