#!/usr/bin/env bash
#
# Sao lưu Postgres của production. Chạy bởi biibo-backup.timer mỗi ngày 03:00.
#
# Hai chặng. Chặng một là bản CÙNG MÁY: cứu được lỗi người (xoá nhầm bảng,
# migration hỏng, update thiếu WHERE) chứ không cứu được mất VPS. Chặng hai đẩy
# lên R2 — chỉ chặng đó mới sống sót khi mất máy, và nó chỉ chạy nếu có
# /opt/biibo/rclone.conf.
set -euo pipefail

# Ten app, dung lam ca tien to ten file lan thu muc tren R2. Mot bucket R2 se
# chua ban sao luu cua nhieu app, nen moi file phai tu noi duoc no thuoc ve dau
# — ke ca khi bi loi ra khoi thu muc goc.
APP=biibo-english-vocab

DIR=/opt/biibo/backups
KEEP=3
OUT="$DIR/$APP-$(date +%Y%m%d-%H%M).dump"

mkdir -p "$DIR" && chmod 700 "$DIR"

# -Fc: định dạng custom, nén sẵn và pg_restore chọn được từng bảng khi cần.
docker exec biibo-postgres pg_dump -U biibo -d biibo_english -Fc -f /tmp/backup.tmp

# Kiểm NGAY TRONG container, trước khi chép ra. pg_dump trả về 0 vẫn có thể để
# lại file không khôi phục được (hết đĩa giữa chừng chẳng hạn), nên đọc thử mục
# lục thay vì tin mã thoát.
docker exec biibo-postgres pg_restore -l /tmp/backup.tmp > /dev/null
SIZE_IN=$(docker exec biibo-postgres stat -c %s /tmp/backup.tmp)

# Ghi ra tên tạm rồi mới đổi tên: một bản dump đứt giữa chừng mà mang đúng tên
# thật là thứ nguy hiểm nhất — nó trông như bản sao lưu hợp lệ.
docker cp biibo-postgres:/tmp/backup.tmp "$OUT.partial"
docker exec biibo-postgres rm -f /tmp/backup.tmp

SIZE_OUT=$(stat -c %s "$OUT.partial")
if [ "$SIZE_IN" != "$SIZE_OUT" ]; then
  echo "LOI: chep ra thieu byte ($SIZE_IN -> $SIZE_OUT) — KHONG xoa ban cu"
  rm -f "$OUT.partial"
  exit 1
fi

mv "$OUT.partial" "$OUT" && chmod 600 "$OUT"

# Chỉ dọn bản cũ SAU khi bản mới đã qua kiểm. Dọn trước là có ngày còn lại đúng
# một bản hỏng.
ls -1t "$DIR/$APP"-*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "OK $OUT ($(du -h "$OUT" | cut -f1)) — dang giu $(ls -1 "$DIR/$APP"-*.dump | wc -l) ban"

# ── Day ra ngoai may ────────────────────────────────────────────────────────
# Ban tren dia nay cuu duoc loi nguoi, khong cuu duoc mat VPS. Buoc nay moi la
# cai cuu duoc.
#
# Bo qua trong im lang khi chua co config: script van phai chay duoc tu dem dau
# tien, truoc khi co token R2. Nhung neu DA co config ma upload that bai thi
# phai bao loi — mot ban sao luu tuong la da ra ngoai ma thuc ra khong, con te
# hon la biet minh khong co.
CONF=/opt/biibo/rclone.conf
if [ ! -f "$CONF" ]; then
  echo "CHUA day ra ngoai: khong thay $CONF (xem docs/deployment.md muc Sao luu)"
  exit 0
fi

REMOTE=${R2_REMOTE:-r2:biibo-backup/$APP}
rclone --config "$CONF" copy "$OUT" "$REMOTE/" --s3-no-check-bucket

# Giu dung 3 ngay, bang voi tren dia — do la lua chon cua chu du an.
#
# Danh doi can biet: du lieu hong ma phat hien vao ngay thu tu thi khong con ban
# sach nao de quay ve. Kieu hong nguy hiem nhat lai la kieu am tham. Muon noi
# dai ra thi doi KEEP o dau file va so ngay o day, khong phai sua gi them.
rclone --config "$CONF" delete "$REMOTE/" --min-age 3d

echo "Da day len $REMOTE — ngoai do dang giu $(rclone --config "$CONF" lsf "$REMOTE/" | wc -l) ban"
