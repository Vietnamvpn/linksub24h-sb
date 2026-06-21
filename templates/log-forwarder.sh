#!/bin/bash
CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
TEMP_LOG="/tmp/singbox_pending.log"
RESULT_LOG="/tmp/webhook_result.log"

# Xóa sạch log tạm khi bắt đầu để tránh dữ liệu rác từ phiên trước
> "$TEMP_LOG"

# Đảm bảo quyền truy cập
chmod 666 "$TEMP_LOG" "$RESULT_LOG"

# 1. Tiến trình chạy ngầm: Đọc log liên tục từ sing-box
journalctl -u sing-box -f -n 0 | while read -r line; do
    if [[ "$line" =~ "inbound/" && "$line" =~ "inbound connection to" ]]; then
        echo "$line" >> "$TEMP_LOG"
    fi
done &
PID_JOURNAL=$!

VPS_IP=$(curl -s -m 5 ifconfig.me || curl -s -m 5 icanhazip.com)
trap 'kill $PID_JOURNAL; exit 0' SIGTERM SIGINT

# 2. Vòng lặp chính: Gửi dữ liệu và Tự dọn dẹp log
while true; do
    sleep 60
    
    # --- TỰ ĐỘNG DỌN DẸP LOG KẾT QUẢ ---
    # Kiểm tra nếu file > 512KB (524288 bytes) thì làm mới
    if [ -f "$RESULT_LOG" ] && [ $(stat -c%s "$RESULT_LOG") -gt 524288 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Log đã đầy, tự động làm mới..." > "$RESULT_LOG"
    fi
    
    # Kiểm tra cấu hình
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        continue
    fi
    
    # Gửi dữ liệu
    if [ -s "$TEMP_LOG" ]; then
        mv "$TEMP_LOG" "${TEMP_LOG}.sending"
        touch "$TEMP_LOG"
        
        LOG_CONTENT=$(cat "${TEMP_LOG}.sending" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
        PHP_URL=$(cat "$CONF_FILE")
        
        RESPONSE=$(curl -s -w "\nHTTP_STATUS: %{http_code}" -X POST "$PHP_URL" \
             -H "Content-Type: application/json" \
             -d "{\"vps_ip\":\"$VPS_IP\", \"batch\": true, \"log\":\"$LOG_CONTENT\"}")
             
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Phản hồi: $RESPONSE" >> "$RESULT_LOG"
        rm -f "${TEMP_LOG}.sending"
    fi
done