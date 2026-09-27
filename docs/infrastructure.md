# Infrastructure

Triển khai, cổng, backup, giám sát. Đọc kèm `system-architecture.md` (kiến trúc code)
và `performance-scalability.md` (quy tắc viết truy vấn).

> **Trạng thái tài liệu:** mô tả cả cái **đang chạy** lẫn cái **đã chốt nhưng chưa dựng**.
> Mỗi mục đều có nhãn. Đừng giả định thứ gắn nhãn 🔜 đã tồn tại trong repo.

---

## 1. Máy chủ

| | |
|---|---|
| Kiểu | 1 VPS duy nhất (chưa tách tầng) |
| CPU / RAM | 6 vCPU / 16 GB |
| Disk | 100 GB NVMe (CEPH — storage qua mạng, `fsync` chậm hơn NVMe gắn trực tiếp) |
| Mạng | 200 Mbps, data transfer không giới hạn |
| Quản lý | **Chỉ qua `docker-compose`.** Mọi thành phần thêm mới phải khai báo trong `docker-compose.yml`, không cài trực tiếp lên host |

**Sức chứa ước tính sau khi hoàn tất mục 8: ~1000–1500 người dùng đồng thời.**
Nút thắt là **CPU**, không phải RAM (DB chỉ 366 MB, toàn bộ media nằm ở R2).

---

## 2. Nguyên tắc: tự host cái gì, đẩy ra ngoài cái gì

Quy tắc quyết định là **độ trễ**, không phải chi phí. VPS đặt ở VN; managed service
gần nhất thường ở Singapore (~30–50 ms RTT). Thứ nằm trên **đường request nóng** thì
mỗi truy vấn cộng thêm chừng đó — 5 query tuần tự là +200 ms, không chấp nhận được.

| Thành phần | Ở đâu | Lý do |
|---|---|---|
| Postgres | 🏠 tự host | Đường request nóng. Quyết định sản phẩm: giai đoạn đầu chung máy, **có doanh thu thì tách VPS riêng của mình** — không dùng Neon/Supabase |
| Redis | 🏠 tự host | Rate limit chạy mỗi request, còn nhạy độ trễ hơn Postgres |
| Restate | 🏠 tự host | Đánh giá lại Restate Cloud lúc lên online (sẽ bỏ được backup ở mục 6) |
| Go backend, Next.js | 🏠 tự host | — |
| CDN / TLS / DDoS | ☁️ Cloudflare | Đã cấu hình domain, chỉ trỏ DNS lúc deploy |
| Ảnh, audio, media | ☁️ Cloudflare R2 | Không có file media nào lưu trên đĩa VPS |
| Email giao dịch | ☁️ AWS SES (SMTP interface) | Lo DKIM/SPF/reputation. Phải verify domain và xin thoát sandbox trước khi gửi cho địa chỉ chưa verify |
| Error tracking | ☁️ Sentry SaaS 🔜 | Bất đồng bộ nên độ trễ vô hại. Self-host Sentry cần Kafka+ClickHouse — không nhét vào 6 vCPU |
| Uptime check | ☁️ UptimeRobot 🔜 | **Bắt buộc ở ngoài.** Tự host giám sát trên chính máy cần giám sát = mù đúng lúc máy chết |
| Metrics | ⏸ hoãn | Grafana Cloud + agent, chỉ mở khi có câu hỏi hiệu năng thật |

**Không dùng:** Neon/Supabase, self-host Sentry, self-host Grafana/Prometheus.

---

## 3. Bản đồ cổng

> ⚠️ **Restate ingress mặc định là 8080 — trùng cổng Go backend.** Bắt buộc đổi
> phía host ngay từ `docker-compose.yml`, nếu không dựng lên là xung đột.

| Dịch vụ | Cổng host | Cổng container | Công khai? | Ghi chú |
|---|---|---|---|---|
| Go backend (API `/v1`) | 8080 | — | qua reverse proxy | |
| Next.js | **3011** (cả dev lẫn prod) | — | qua reverse proxy | `next dev`/`next start` đều `--port 3011` |
| Postgres | 5433 | 5432 | ❌ | |
| Redis | 6380 | 6379 | ❌ | |
| Restate ingress | **8090** | 8080 | ❌ chỉ nội bộ | đổi để tránh đụng backend |
| Restate UI/admin | 9070 | 9070 | ❌ **phải chặn firewall** | ai vào được là xem/hủy job được |
| Restate nội bộ | 9071 | 9071 | ❌ **phải chặn firewall** | |
| Restate handler (Go) | 9080 | — | ❌ | Restate **gọi ngược vào** đây |
| PgBouncer | 6432 | 6432 | ❌ | container đã dựng, **`DATABASE_URL` chưa trỏ vào** |

Bảng trên mô tả `docker-compose.yml` (máy dev). Trên VPS, `docker-compose.prod.yml`
**không publish cổng nào** ngoài 80/443 của Caddy và 9070 bind `127.0.0.1` — Go và
Next chạy trong container và gọi nhau qua mạng nội bộ của compose. Khác biệt đầy
đủ ở `deployment.md` §10.

Không có cổng vào — chỉ gọi ra ngoài qua HTTPS 443:

| Dịch vụ | Dùng ở đâu |
|---|---|
| Cloudflare R2 | ảnh, audio, media |
| Azure Speech | chấm phát âm, TTS |
| AWS SES | email giao dịch, qua SMTP interface (`email-smtp.<region>.amazonaws.com:587`) |
| Gemini / các nhà cung cấp AI | sinh nội dung |
| Sentry 🔜 | báo lỗi — **chưa có trong code**, mới là kế hoạch |

UptimeRobot đi **ngược lại**: từ ngoài internet gọi vào `/healthz` qua 443.

---

## 4. Restate (durable execution)

Chọn Restate thay River/Temporal cho: retry khi API ngoài lỗi, biết job nào
thành công/thất bại, và **idempotency của side-effect** (retry gửi email không
gửi trùng, retry chấm điểm không trừ credit hai lần).

| | |
|---|---|
| Image | `docker.restate.dev/restatedev/restate:latest` |
| Go SDK | `github.com/restatedev/sdk-go` **v1.0.4** (cam kết semver 1.x) |
| Server hỗ trợ | 1.4–1.7. `WithInvocationRetryPolicy` cần ≥1.5. **Đang chạy 1.7.7** |
| Go yêu cầu | ≥1.24 (repo đang 1.26.4 ✅) |
| Volume | `/restate-data` — journal RocksDB, **phải backup**. Sàn ~290MB do RocksDB cấp phát trước; kích thước **không** phản ánh số job đang chạy dở |
| Đăng ký service | `restate deployments register http://host.docker.internal:9080`<br>**chạy lại mỗi lần đổi chữ ký handler** — nhớ đưa vào quy trình deploy |

**Handler nằm chung binary `cmd/server`, cổng riêng 9080** — ít process hơn (6 vCPU
không dư), dùng chung `*App` và pgx pool. Service đã đăng ký: `Broadcast → Fanout`,
`Email → Send`, `Scoring → ScoreSentence`. Tài nguyên đo được lúc idle:
**~300MB RAM / ~2% CPU** (trong ngân sách 1–2GB đã dự trù).

**Quy mô dự án:** repo chính `restatedev/restate` có ~4.3k sao, 200 fork, SDK cho
TypeScript, Java/Kotlin, Python, Go, Rust. Repo binding `sdk-go` chỉ ~65 sao — đó là
con số bình thường của một binding ngôn ngữ, **không phải dấu hiệu nền tảng ít dùng**.

**Rủi ro còn lại:** Go là 1 trong 5 SDK và không phải SDK được ưu tiên nhất (TS/Java
đi trước). Nên rủi ro là **edge case riêng của binding Go**, không phải rủi ro nền
tảng. Việc đầu tiên chuyển sang Restate cố ý chọn `BroadcastNotification`: nhỏ, độc
lập, hỏng cũng không ai mất tiền. Đó là phép thử trước khi đi tiếp.

### Việc nào chạy qua Restate

| Việc | Kiểu gọi | Vì sao |
|---|---|---|
| `BroadcastNotification` | nền | Hiện là `go func()` trần → restart là mất sạch |
| Email biên lai, verify, reset | nền | `go func()` trần / chặn request |
| Chấm từng câu của báo cáo cả bài | **đồng bộ** | Xem dưới |
| `AssessSpeaking` (chấm 1 câu lẻ) | ❌ không qua Restate | Học viên đứng chờ, thêm hop chỉ làm chậm |

**Chấm cả bài giữ nguyên đồng bộ, KHÔNG polling.** UX hiện tại: học viên thu được
bao nhiêu câu thì bấm chấm, chấm bấy nhiêu — `LessonRecorder` đếm `clips.size` rồi
upload lần lượt. Restate xen vào bên dưới mỗi lời gọi (ingress request-response,
`Idempotency-Key = reportID:sentenceIndex`), nên **FE không đổi một dòng nào**.
Được thêm retry bền vững + chống submit trùng; mất thêm một hop localhost (<1 ms,
so với Azure vài giây là nhiễu).

### Hai quy tắc bắt buộc khi viết handler mới

**1. Lỗi vĩnh viễn phải là `TerminalError`.** Restate mặc định retry mọi lỗi —
đúng cho timeout, sai cho từ chối. Một lỗi "không tìm thấy báo cáo" trả về trần
sẽ được retry hết cửa sổ retry (3 phút với chấm điểm) trong khi học viên ngồi
chờ một câu trả lời đã có từ giây đầu; tệ hơn, một từ chối từ API trả tiền sẽ bị
hỏi lại nhiều lần.

`internal/durable/terminal.go` giữ quy tắc duy nhất: **4xx từ domain là phát
biểu về chính yêu cầu đó → terminal.** Mọi thứ khác vẫn retry. Bọc mọi lời gọi
port bằng `terminal(err)`. Status gốc đi kèm qua `WithErrorCode` và
`rejectedError` dựng lại `*httpx.Error` ở phía client, nên người dùng vẫn nhận
đúng 404/409 kèm câu tiếng Việt của domain. API ngoài từ chối vĩnh viễn thì đổi
sang lỗi domain trước khi trả (xem `scoring.ErrRejected` → 422).

**2. Mọi hàm được `restate.Run` gọi phải chịu được chạy hai lần.** Retry của
Restate là chạy lại cả bước đó. `DeliverNotification` làm mẫu: id notification
sinh xác định bằng `uuid.NewSHA1`, `ON CONFLICT DO NOTHING`, và
`RowsAffected()==0` thì bỏ luôn cả web push — chạy lại không tạo dòng thứ hai,
cũng không đẩy thông báo thứ hai.

### Restate hỏng thì sao

Không mất tính năng. `RESTATE_INGRESS_URL` để trống là `Client.Enabled()` false
và mọi caller chạy đường inline — đúng code đã chạy trước khi có Restate. Khi
Restate có cấu hình mà không kết nối được, chỉ `ErrUnreachable` (không có phản
hồi HTTP nào) mới được làm lại inline: Restate đã trả lời thì lời của nó là
quyết định, làm lại sẽ trả tiền Azure lần hai.

---

## 5. Nền tảng dữ liệu

| | |
|---|---|
| Postgres | 16-alpine, DB `biibo_english`, cổng host 5433 |
| Kích thước | 366 MB (lớn nhất: `voca_word_questions` 126 MB) |
| Migration | goose — `cd backend && make migrate-up` |
| Redis | 7-alpine, cổng host 6380. **Chỉ dùng cho cache + rate limit**, không phải hàng đợi |

**PgBouncer (transaction pooling)** — container đã có trong `docker-compose.yml`,
`DATABASE_URL` **chưa** trỏ vào. Dựng sẵn từ đầu vì thêm sau phải chỉnh pool ở mọi
instance; làm trước thì scale chỉ là thêm máy. Đọc cảnh báo prepared statement
dưới đây trước khi nối.

**`pool_max_conns` phải đặt trong `DATABASE_URL`** 🔜 — hiện không chỗ nào set, tức
đang dùng mặc định của pgx (4×CPU = 24 conn/instance). Bốn instance là chạm trần
`max_connections`=100.

```
DATABASE_URL=...?pool_max_conns=20&pool_min_conns=2&pool_max_conn_lifetime=1h&pool_max_conn_idle_time=30m
```

**Cảnh báo trước khi trỏ `DATABASE_URL` vào PgBouncer:** ở chế độ `transaction`,
mỗi câu lệnh có thể rơi vào một session Postgres khác. pgx mặc định dùng extended
protocol và **cache prepared statement theo session** — statement chuẩn bị ở
session này đem chạy ở session khác là lỗi `prepared statement "stmtcache_..."
does not exist`. Lỗi này **không xuất hiện lúc test một request**; nó nổ khi có
tải, đúng lúc pool bắt đầu ghép nhiều client vào một session.

Nối vào PgBouncer đòi thêm ít nhất một trong hai:

```
DATABASE_URL=...?default_query_exec_mode=exec     # tắt cache prepared statement
```

hoặc đổi `pool_mode` sang `session` (mất phần lớn lợi ích của pooling). Đây là
lý do container dựng sẵn nhưng chưa nối: **đổi biến môi trường thôi là chưa đủ,
phải đo lại dưới tải.** Đường sqlc (`db/queries`) dùng prepared statement nhiều
nhất nên là chỗ cần nhìn đầu tiên.

**Backend nói chuyện với DB qua `DATABASE_URL`, không qua socket local.** Đây là
điều kiện để ngày tách DB ra VPS riêng chỉ là đổi một biến môi trường.

---

## 6. Backup — có **hai** kho state

Một VPS = một điểm chết. Cả hai phải đẩy ra R2, bằng hai cơ chế riêng.

| Kho | Chứa gì | Mất thì sao |
|---|---|---|
| Postgres 🔜 | Toàn bộ dữ liệu người dùng | Mất hết |
| Restate `/restate-data` 🔜 | Job đang chạy dở | Mất việc in-flight: email chưa gửi, câu chưa chấm |

Kho thứ hai rất dễ quên vì nó mới xuất hiện cùng Restate.

---

## 7. Giám sát 🔜

Chỉ có **một người quản trị**, nên tiêu chí là ít tốn thời gian bảo trì nhất, và
tuyệt đối không tự host trên chính máy cần giám sát.

| Câu hỏi | Công cụ | Tải lên VPS |
|---|---|---|
| "Nó chết chưa?" | UptimeRobot → `/healthz`, 5 phút | 0 (hoàn toàn ngoài máy) |
| "Sao request kia lỗi?" | Sentry SaaS + scrubbing PII + rate limit SDK | ~50 MB RAM |
| "req/s, p99 bao nhiêu?" | ⏸ hoãn tới khi có câu hỏi thật | — |

Hiện backend **chỉ có `/healthz`** — không metrics, không tracing, không error
reporting. Lỗi production đang im lặng hoàn toàn.

Bật scrubbing PII ngay từ lúc cấu hình Sentry: stack trace có thể dính email/user id.
Đặt rate limit phía SDK: một bug lặp vô hạn đốt hết free tier trong một đêm.

---

## 8. Ràng buộc đã biết (chưa xử lý)

### 8.1 Bảo mật — phải xử lý trước khi mở ra internet

Cả nhóm này **vô hại trên laptop sau NAT** và **nguy hiểm ngay khi lên VPS có IP
công cộng**. Đó là lý do dễ bỏ sót: local chạy tốt không nói gì về VPS.

Quan trọng nhất phải hiểu trước: **Docker publish port bằng cách chèn luật NAT,
đi vòng qua UFW.** `ufw deny 6380` **không** đóng được một cổng Docker đã publish
ra `0.0.0.0`. Cách chắc chắn duy nhất là bind `127.0.0.1:` trong
`docker-compose.yml`.

| Vấn đề | Đã kiểm chứng thế nào | Hậu quả trên VPS |
|---|---|---|
| **Redis không mật khẩu, `protected-mode no`** | `CONFIG GET requirepass` → rỗng; `PING` → `PONG` | Nặng nhất. Ai cũng đọc/ghi/`FLUSHALL` được. Rate limit thành vô nghĩa; session cache là của người lạ |
| **Postgres mật khẩu `biibo`/`biibo`** | `docker-compose.yml` | Đoán một lần là ra. Toàn bộ dữ liệu người dùng |
| **5433, 6380, 8090 bind `0.0.0.0`** | `docker ps` | Nằm thẳng trên internet, UFW không cứu (xem trên) |
| **Restate ingress 8090 không xác thực** | POST thẳng vào lúc nghiệm thu B4, không kèm gì | **Cổng tốn tiền.** Ai cũng gọi được `/Email/Send`, `/Scoring/ScoreSentence` → đốt tiền Azure + quota SES |
| **Handler 9080 chưa bật kiểm chữ ký** | backend tự log `WARN Accepting requests without validating request signatures` | Có sẵn `server.WithIdentityV1(...)` trong SDK, chỉ là chưa bật |
| Restate admin 9070 **không có** lớp đăng nhập | `curl localhost:9070/deployments` → 200 | Không phải chưa bật — Restate self-host không cung cấp. **Chỉ chặn được bằng biên mạng** |

**9070/9071 hiện đã kín** vì compose bind `127.0.0.1:` — xem bằng SSH tunnel:

```
ssh -L 9070:127.0.0.1:9070 user@vps      # rồi mở http://localhost:9070
```

Xác thực ở đây **là SSH key**, không phải truy cập vô danh. Với Restate đó cũng là
cách duy nhất, vì không có mật khẩu nào để đặt.

Phần lớn nhóm này đã đóng trong `docker-compose.prod.yml`: Postgres và Redis đều
bắt buộc mật khẩu từ `.env`, và **không service hạ tầng nào publish cổng ra host**
— chỉ Caddy giữ 80/443, Restate admin bind `127.0.0.1`. Còn lại chưa làm: bật
kiểm chữ ký cho handler Restate (`server.WithIdentityV1`). Xem `deployment.md` §9.

### 8.2 Còn lại

| Vấn đề | Vị trí | Trạng thái |
|---|---|---|
| Recorder xuất WAV không nén | `use-wav-recorder.ts` | **Đã cân nhắc và hoãn.** Câu thật 3–8 s ≈ 160–250 KB (960 KB chỉ là mức 30 s kịch trần), cả bài 20 câu ≈ 3.2 MB — chưa căng. Opus là codec **có mất mát** mà Azure khuyến nghị PCM 16 kHz cho pronunciation assessment; chưa ai đo điểm chấm giữa hai định dạng. Azure tính tiền theo giây audio nên nén không tiết kiệm gì. Chỉ làm khi băng thông thật sự căng **và** đã đo được độ chính xác không giảm |
| `azure_batch.go:207` và `:251` tạo `http.Client` mỗi lời gọi | `internal/scoring/` | Đường transcribe theo lô, không nằm trên đường học viên chờ. Để riêng, chưa sửa |
| Xử lý bounce/complaint của SES | — | Cần SNS topic + endpoint public + bảng suppression. Là feature riêng, không nằm trong việc đổi transport. SES khoá tài khoản nếu tỉ lệ bounce vượt ngưỡng, nên đây là việc phải làm trước khi gửi nhiều |
| Trang nội dung công khai chưa cache được | `/pricing`, `/topics`, `/books`, `/dictionary` | Đòn giảm CPU SSR thật (PPR / `use cache`). Dữ liệu giống nhau với mọi người, chỉ header là riêng. **Cần quyết định thiết kế** |

Đã xử lý trong đợt này, giữ lại để khỏi báo trùng: `consume()` → `charge()`+`refund()`
trên 3 đường trả phí · Azure retry 429/5xx có backoff · `smtp.SendMail` đổi sang
`DialContext` huỷ được theo context · 4 truy vấn `ORDER BY random()` đổi sang
`TABLESAMPLE` · `force-dynamic` đã audit và **giữ lại có chủ đích** (đo ra: bỏ cờ
build giống hệt, 53/60 trang vốn đã tự vào dynamic).

---

## 9. Sức chứa & lộ trình nâng cấp

| Mốc | Cấu hình |
|---|---|
| ~1–1.5k đồng thời | VPS hiện tại + Cloudflare ✅ |
| ~3–5k | 2× app (8 vCPU) + DB ra máy riêng (8 vCPU/32 GB) + PgBouncer + LB |
| ~10k | 3–4× app + DB 16 vCPU/32 GB + read replica ≈ **20–28 vCPU tổng** |

Ước tính cho 10k (≈3000 req/s): Next.js SSR 8–12 vCPU, Go API 3–4, Postgres 4–8,
Redis 1. **10k không thể ép vào 6 vCPU** — cần khoảng 4–5 lần máy hiện tại.

Băng thông: 200 Mbps đủ **nếu có CDN** (origin chỉ còn JSON ≈ 30–70 Mbps).
Không CDN thì riêng bundle JS đã ~160 Mbps ở mức 20 lượt tải trang/giây.

**Code đã sẵn sàng scale ngang:** không có state trong RAM (các `var ... map` ở
`billing.go:52`, `roadmap.go:244-246` đều là hằng số chỉ đọc), không có cron chạy
trong process (quota reset bằng khóa theo kỳ — không cần leader election). Hai chỗ
`go func()` trần (`orders.go:313`, `notifications.go:306`) **không chặn scale ngang**
— mỗi cái chạy trên đúng instance nhận request; vấn đề của chúng là **mất việc khi
restart**, và đó chính là lý do có mục 4.

---

## Liên quan

- `system-architecture.md` — kiến trúc code, OpenAPI contract
- `performance-scalability.md` — quy tắc bắt buộc khi thêm endpoint/truy vấn
- `object-storage.md` — R2
- `deployment.md` — đưa code lên VPS: image, GHCR, CI/CD, sao lưu, quay lui
- `deployment-log.md` — nhật ký dựng máy 2026-09-12, theo đúng thứ tự đã chạy
