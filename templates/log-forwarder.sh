#!/bin/bash
CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
TEMP_LOG="/tmp/singbox_pending.log"
RESULT_LOG="/tmp/webhook_result.log"

# Xóa sạch log tạm khi bắt đầu để tránh dữ liệu rác từ phiên trước
> "$TEMP_LOG"

# Đảm bảo quyền truy cập
chmod 666 "$TEMP_LOG" "$RESULT_LOG"

# 1. Tiến trình chạy ngầm: Thu thập toàn bộ log liên quan đến inbound để xử lý cả IP và Traffic
journalctl -u sing-box -f -n 0 | while read -r line; do
    if [[ "$line" =~ "inbound/" ]]; then
        echo "$line" >> "$TEMP_LOG"
    fi
done &
PID_JOURNAL=$!

VPS_IP=$(curl -s -m 5 ifconfig.me || curl -s -m 5 icanhazip.com)
trap 'kill $PID_JOURNAL; exit 0' SIGTERM SIGINT

# 2. Vòng lặp chính: Phân tích dữ liệu, gom nhóm theo User và gửi JSON lên Web Panel
while true; do
    sleep 60
    
    # --- TỰ ĐỘNG DỌN DẸP LOG KẾT QUẢ ---
    if [ -f "$RESULT_LOG" ] && [ $(stat -c%s "$RESULT_LOG") -gt 524288 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Log đã đầy, tự động làm mới..." > "$RESULT_LOG"
    fi
    
    # Kiểm tra cấu hình
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        continue
    fi
    
    # Lấy thông tin cấu hình đồng bộ
    PHP_URL=$(grep "WEB_URL=" "$CONF_FILE" | cut -d'=' -f2)
    if [ -z "$PHP_URL" ]; then 
        PHP_URL=$(cat "$CONF_FILE" | head -n 1)
    fi
    
    API_PORT=$(grep "PORT=" "$CONF_FILE" | cut -d'=' -f2)
    API_TOKEN=$(grep "TOKEN=" "$CONF_FILE" | cut -d'=' -f2)
    
    # Xử lý gom nhóm và gửi dữ liệu nếu có log phát sinh
    if [ -s "$TEMP_LOG" ] && [ -n "$PHP_URL" ]; then
        mv "$TEMP_LOG" "${TEMP_LOG}.sending"
        touch "$TEMP_LOG"
        
        # Sử dụng AWK cải tiến: Liên kết đa dòng qua Connection ID và nhận diện chính xác cặp ngoặc tên User
        JSON_STATS=$(awk '
        {
            # A. Trích xuất Connection ID để liên kết dữ liệu đa dòng
            conn_id = ""
            if (match($0, /INFO \[[0-9]+/)) {
                conn_id = substr($0, RSTART+6, RLENGTH-6)
            }
            
            # B. Trích xuất chuẩn xác Username nằm ở cặp ngoặc vuông thứ 2 sau dấu hai chấm (Ví dụ: ]: [user_sub_229])
            user = ""
            if (match($0, /\]: \[[^\]]+\]/)) {
                user = substr($0, RSTART+4, RLENGTH-5)
            }
            
            # Lưu vết ánh xạ hoặc tái thiết lập Username qua bộ nhớ đệm Connection ID
            if (conn_id != "" && user != "") {
                conn_user[conn_id] = user
            }
            if (conn_id != "" && user == "") {
                user = conn_user[conn_id]
            }
            
            # C. Trích xuất IP nguồn kết nối từ log dòng chứa thông tin IP
            ip = ""
            if (match($0, /(from|từ) [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                matched_ip_str = substr($0, RSTART, RLENGTH)
                split(matched_ip_str, ip_parts, " ")
                ip = ip_parts[2]
            }
            
            # Lưu vết ánh xạ hoặc tái thiết lập IP qua bộ nhớ đệm Connection ID
            if (conn_id != "" && ip != "") {
                conn_ip[conn_id] = ip
            }
            if (conn_id != "" && ip == "") {
                ip = conn_ip[conn_id]
            }
            
            # D. Ghi nhận mối quan hệ đồng bộ giữa User và IP không trùng lặp
            if (user != "" && ip != "") {
                if (!((user "," ip) in seen)) {
                    ips[user] = (ips[user] == "" ? ip : ips[user] "," ip)
                    ip_count[user]++
                    seen[user "," ip] = 1
                }
            }
            
            # E. Trích xuất và cộng dồn lưu lượng dung lượng Traffic (tx / rx)
            if (user != "") {
                if (match($0, /[0-9]+( bytes)? tx/)) {
                    m = substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", m)
                    traffic[user] += m
                }
                if (match($0, /[0-9]+( bytes)? rx/)) {
                    m = substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", m)
                    traffic[user] += m
                }
                if (match($0, /(tx|upload|up|rx|download|down)[: ]+[0-9]+/)) {
                    m = substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", m)
                    traffic[user] += m
                }
                
                # Khởi tạo mặc định để đảm bảo user xuất hiện đầy đủ trong danh sách xuất JSON
                if (!(user in ip_count)) {
                    ip_count[user] = 0
                    ips[user] = ""
                }
            }
        }
        END {
            printf "["
            first = 1
            for (u in ip_count) {
                if (!first) printf ","
                first = 0
                t_bytes = (traffic[u] == "" ? 0 : traffic[u])
                printf "{\"username\":\"%s\",\"concurrent_ips\":%d,\"active_ips\":\"%s\",\"data_bytes\":%d}", u, ip_count[u], ips[u], t_bytes
            }
            printf "]"
        }' "${TEMP_LOG}.sending")
        
        # Nếu trích xuất được dữ liệu người dùng hợp lệ, đóng gói cấu trúc JSON chuẩn qua jq
        if [ "$JSON_STATS" != "[]" ] && [ -n "$JSON_STATS" ]; then
            PAYLOAD=$(jq -n \
                --arg vps_ip "$VPS_IP" \
                --arg port "$API_PORT" \
                --argjson stats "$JSON_STATS" \
                '{vps_ip: $vps_ip, server_port: $port, stats: $stats}')
                
            # Đẩy dữ liệu cấu trúc mảng lên API Web nhận xử lý
            RESPONSE=$(curl -s -w "\nHTTP_STATUS: %{http_code}" -X POST "$PHP_URL" \
                 -H "Content-Type: application/json" \
                 -H "X-API-Port: $API_PORT" \
                 -H "X-API-Token: $API_TOKEN" \
                 -d "$PAYLOAD")
                 
            echo "$(date '+%Y-%m-%d %H:%M:%S') | Đã gửi thống kê. Phản hồi Web: $RESPONSE" >> "$RESULT_LOG"
        fi
        
        rm -f "${TEMP_LOG}.sending"
    fi
done