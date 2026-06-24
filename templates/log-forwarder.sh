#!/bin/bash
CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
TEMP_LOG="/tmp/singbox_pending.log"
RESULT_LOG="/tmp/webhook_result.log"
API_URL="http://127.0.0.1:10086" # API của Sing-box

> "$TEMP_LOG"
chmod 666 "$TEMP_LOG" "$RESULT_LOG"

# 1. Bắt log IP từ Sing-box
journalctl -u sing-box -f -n 0 | while read -r line; do
    if [[ "$line" =~ "inbound/" || "$line" =~ "closed" ]]; then
        echo "$line" >> "$TEMP_LOG"
    fi
done &
PID_JOURNAL=$!

VPS_IP=$(curl -s -m 5 ifconfig.me || curl -s -m 5 icanhazip.com)
trap 'kill $PID_JOURNAL; exit 0' SIGTERM SIGINT

# 2. Vòng lặp gửi thống kê mỗi 60s
while true; do
    sleep 60
    
    if [ ! -f "$CONF_FILE" ]; then continue; fi
    PHP_URL=$(grep "^WEB_URL=" "$CONF_FILE" | cut -d'=' -f2- | tr -d '\r')
    API_PORT=$(grep "^PORT=" "$CONF_FILE" | cut -d'=' -f2- | tr -d '\r')
    API_TOKEN=$(grep "^TOKEN=" "$CONF_FILE" | cut -d'=' -f2- | tr -d '\r')
    
    # Lấy dữ liệu IP từ file tạm (đã được xử lý bởi AWK)
    JSON_IP_STATS=$(awk '
    {
        idx_info = index($0, "INFO [");
        if (idx_info > 0) {
            rest = substr($0, idx_info + 6);
            split(rest, a, " ");
            conn_id = a[1];
        }
        idx_tag = index($0, "]: [");
        if (idx_tag > 0) {
            rest = substr($0, idx_tag + 4);
            split(rest, b, "]");
            user = b[1];
        }
        if (user != "" && conn_id != "") {
            users[user] = 1;
            ips[user] = (ips[user] == "" ? conn_id : ips[user] "," conn_id);
            counts[user]++;
        }
    }
    END {
        printf "[";
        for (u in users) {
            if (first) printf ",";
            printf "{\"username\":\"%s\",\"concurrent_ips\":%d}", u, counts[u];
            first=1;
        }
        printf "]";
    }' "$TEMP_LOG")
    
    # Lấy dung lượng từ Sing-box Stats API
    # Dùng curl gọi xuống cổng 10086
    TRAFFIC_JSON=$(curl -s -X POST "$API_URL" -d '{"method":"singbox.stats.get"}' | jq -c '.users')
    
    # Kết hợp IP và Traffic vào một Payload
    PAYLOAD=$(jq -n \
        --arg vps_ip "$VPS_IP" \
        --arg port "$API_PORT" \
        --argjson ip_stats "$JSON_IP_STATS" \
        --argjson traffic_stats "$TRAFFIC_JSON" \
        '{vps_ip: $vps_ip, server_port: $port, ip_data: $ip_stats, traffic_data: $traffic_stats}')
    
    # Gửi lên Webhook
    RESPONSE=$(curl -s -k -m 15 -w "\nHTTP_STATUS: %{http_code}" -X POST "$PHP_URL" \
         -H "Content-Type: application/json" \
         -H "X-API-Port: $API_PORT" \
         -H "X-API-Token: $API_TOKEN" \
         -d "$PAYLOAD")
         
    echo "$(date '+%Y-%m-%d %H:%M:%S') | Đã đẩy dữ liệu. Phản hồi: $RESPONSE" >> "$RESULT_LOG"
    > "$TEMP_LOG" # Reset log sau khi gửi
done
