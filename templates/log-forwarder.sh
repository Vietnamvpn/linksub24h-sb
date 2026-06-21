#!/bin/bash
CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
TEMP_LOG="/tmp/singbox_pending.log"
RESULT_LOG="/tmp/webhook_result.log"

# Xóa sạch log cũ khi bắt đầu để tránh dữ liệu rác từ phiên trước
> "$TEMP_LOG"
> "$RESULT_LOG"

# Đảm bảo quyền truy cập
chmod 666 "$TEMP_LOG" "$RESULT_LOG"

# 1. Tiến trình chạy ngầm: Đọc log liên tục từ sing-box
# Lọc các dòng kết nối mới và lưu vào file tạm
journalctl -u sing-box -f -n 0 | while read -r line; do
    if [[ "$line" =~ "inbound/" && "$line" =~ "inbound connection to" ]]; then
        echo "$line" >> "$TEMP_LOG"
    fi
done &
PID_JOURNAL=$!

# Lấy IP VPS
VPS_IP=$(curl -s -m 5 ifconfig.me || curl -s -m 5 icanhazip.com)

# Dọn dẹp tiến trình ngầm khi service bị tắt
trap 'kill $PID_JOURNAL; exit 0' SIGTERM SIGINT

# 2. Vòng lặp chính: Gửi dữ liệu mỗi 60 giây
while true; do
    sleep 60
    
    # Kiểm tra xem có cấu hình URL chưa
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        continue
    fi
    
    # Chỉ gửi nếu file log tạm có dữ liệu
    if [ -s "$TEMP_LOG" ]; then
        # Copy log hiện tại ra file tạm gửi đi, reset file log chính
        mv "$TEMP_LOG" "${TEMP_LOG}.sending"
        touch "$TEMP_LOG"
        
        LOG_CONTENT=$(cat "${TEMP_LOG}.sending" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
        PHP_URL=$(cat "$CONF_FILE")
        
        # Gửi log bằng cURL
        RESPONSE=$(curl -s -w "\nHTTP_STATUS: %{http_code}" -X POST "$PHP_URL" \
             -H "Content-Type: application/json" \
             -d "{\"vps_ip\":\"$VPS_IP\", \"batch\": true, \"log\":\"$LOG_CONTENT\"}")
             
        # Ghi kết quả vào log theo dõi
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Phản hồi: $RESPONSE" >> "$RESULT_LOG"
        
        # Xóa file log đã gửi xong
        rm -f "${TEMP_LOG}.sending"
    fi
done