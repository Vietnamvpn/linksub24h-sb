#!/bin/bash
CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
TEMP_LOG="/tmp/singbox_pending.log"
RESULT_LOG="/tmp/webhook_result.log"

# Đảm bảo file tồn tại
touch "$TEMP_LOG" "$RESULT_LOG"

# 1. Tiến trình chạy ngầm: Đọc log liên tục từ sing-box
# ĐÃ SỬA BỘ LỌC: Chấp nhận dòng có "inbound/" và "inbound connection to"
journalctl -u sing-box -f -n 0 | while read -r line; do
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        > "$TEMP_LOG"
        continue
    fi
    if [[ "$line" =~ "inbound/" && "$line" =~ "inbound connection to" ]]; then
        echo "$line" >> "$TEMP_LOG"
    fi
done &
PID_JOURNAL=$!

# 2. Lấy IP của VPS
VPS_IP=$(curl -s -m 5 ifconfig.me || curl -s -m 5 icanhazip.com)

# Bắt tín hiệu để dọn dẹp tiến trình ngầm khi dừng script
trap 'kill $PID_JOURNAL; exit 0' SIGTERM SIGINT

# 3. Vòng lặp chính: Gửi dữ liệu mỗi 60 giây
while true; do
    sleep 60
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        > "$TEMP_LOG"
        continue
    fi
    
    PHP_URL=$(cat "$CONF_FILE")
    
    if [ -s "$TEMP_LOG" ]; then
        # Đổi tên file để lấy dữ liệu, tránh mất log mới đang ghi vào
        mv "$TEMP_LOG" "${TEMP_LOG}.sending"
        touch "$TEMP_LOG"
        
        # Xử lý nội dung log chuẩn hóa JSON
        LOG_CONTENT=$(cat "${TEMP_LOG}.sending" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
        
        # Gửi cURL
        RESPONSE=$(curl -s -w "\nHTTP_STATUS: %{http_code}" -X POST "$PHP_URL" \
             -H "Content-Type: application/json" \
             -d "{\"vps_ip\":\"$VPS_IP\", \"batch\": true, \"log\":\"$LOG_CONTENT\"}")
             
        # Ghi kết quả vào file nhật ký
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Gửi tới $PHP_URL | Phản hồi Server: $RESPONSE" >> "$RESULT_LOG"
        
        # Dọn dẹp file nháp
        rm -f "${TEMP_LOG}.sending"
    fi
done