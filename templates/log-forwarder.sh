#!/bin/bash
CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
TEMP_LOG="/tmp/singbox_pending.log"
RESULT_LOG="/tmp/webhook_result.log"

> "$TEMP_LOG"
chmod 666 "$TEMP_LOG" "$RESULT_LOG"

# 1. Bắt log từ Sing-box
journalctl -u sing-box -f -n 0 | while read -r line; do
    if [[ "$line" =~ "inbound/" || "$line" =~ "closed" ]]; then
        echo "$line" >> "$TEMP_LOG"
    fi
done &
PID_JOURNAL=$!

VPS_IP=$(curl -s -m 5 ifconfig.me || curl -s -m 5 icanhazip.com)
trap 'kill $PID_JOURNAL; exit 0' SIGTERM SIGINT

# 2. Vòng lặp bóc tách 60s
while true; do
    sleep 60
    
    if [ -f "$RESULT_LOG" ] && [ $(stat -c%s "$RESULT_LOG") -gt 524288 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Log đã đầy, tự động làm mới..." > "$RESULT_LOG"
    fi
    
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        continue
    fi
    
    # [FIX]: Sửa lỗi cắt URL và loại bỏ triệt để ký tự \r
    PHP_URL=$(grep "^WEB_URL=" "$CONF_FILE" | cut -d'=' -f2- | tr -d '\r')
    if [ -z "$PHP_URL" ]; then PHP_URL=$(head -n 1 "$CONF_FILE" | tr -d '\r'); fi
    API_PORT=$(grep "^PORT=" "$CONF_FILE" | cut -d'=' -f2- | tr -d '\r')
    API_TOKEN=$(grep "^TOKEN=" "$CONF_FILE" | cut -d'=' -f2- | tr -d '\r')
    
    if [ -s "$TEMP_LOG" ] && [ -n "$PHP_URL" ]; then
        mv "$TEMP_LOG" "${TEMP_LOG}.sending"
        touch "$TEMP_LOG"
        
        JSON_STATS=$(awk -v state_file="/tmp/singbox_state.txt" '
        BEGIN {
            while ((getline < state_file) > 0) {
                if ($1 == "U") conn_user[$2] = $3
                if ($1 == "I") conn_ip[$2] = $3
            }
            close(state_file)
        }
        {
            conn_id = ""
            idx_info = index($0, "INFO [")
            if (idx_info > 0) {
                rest = substr($0, idx_info + 6)
                idx_space = index(rest, " ")
                if (idx_space > 0) conn_id = substr(rest, 1, idx_space - 1)
            }
            
            user = ""
            idx_tag = index($0, "]: [")
            if (idx_tag > 0) {
                rest = substr($0, idx_tag + 4)
                idx_close = index(rest, "]")
                if (idx_close > 0) user = substr(rest, 1, idx_close - 1)
            }
            
            ip = ""
            idx_from = index($0, " from ")
            if (idx_from == 0) idx_from = index($0, " từ ")
            if (idx_from > 0) {
                rest = substr($0, idx_from + 6)
                split(rest, parts, ":")
                ip = parts[1]
            }
            
            if (conn_id != "") {
                if (user != "") conn_user[conn_id] = user
                else user = conn_user[conn_id]
                
                if (ip != "") conn_ip[conn_id] = ip
                else ip = conn_ip[conn_id]
            }
            
            if (user != "" && ip != "") {
                if (!((user "," ip) in seen)) {
                    ips[user] = (ips[user] == "" ? ip : ips[user] "," ip)
                    ip_count[user]++
                    seen[user "," ip] = 1
                }
            }
            
            if (user != "") {
                if (match($0, /[0-9]+ bytes tx/)) {
                    m = substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", m)
                    traffic[user] += m
                }
                if (match($0, /[0-9]+ bytes rx/)) {
                    m = substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", m)
                    traffic[user] += m
                }
            }
            
            if (conn_id != "" && index($0, "closed") > 0) {
                delete conn_user[conn_id]
                delete conn_ip[conn_id]
            }
            
            if (user != "" && !(user in ip_count)) {
                ip_count[user] = 0
                ips[user] = ""
            }
        }
        END {
            tmp_state = state_file ".tmp"
            for (c in conn_user) print "U", c, conn_user[c] > tmp_state
            for (c in conn_ip) print "I", c, conn_ip[c] > tmp_state
            close(tmp_state)
            system("mv " tmp_state " " state_file)
            
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
        
        if [ "$JSON_STATS" != "[]" ] && [ -n "$JSON_STATS" ]; then
            PAYLOAD=$(jq -n \
                --arg vps_ip "$VPS_IP" \
                --arg port "$API_PORT" \
                --argjson stats "$JSON_STATS" \
                '{vps_ip: $vps_ip, server_port: $port, stats: $stats}')
                
            # [FIX]: Thêm timeout (-m 15), bỏ qua kiểm tra SSL chứng chỉ (-k) để chống treo tiến trình
            RESPONSE=$(curl -s -k -m 15 -w "\nHTTP_STATUS: %{http_code}" -X POST "$PHP_URL" \
                 -H "Content-Type: application/json" \
                 -H "X-API-Port: $API_PORT" \
                 -H "X-API-Token: $API_TOKEN" \
                 -d "$PAYLOAD")
                 
            echo "$(date '+%Y-%m-%d %H:%M:%S') | Đã gửi thống kê. Phản hồi Web: $RESPONSE" >> "$RESULT_LOG"
        fi
        rm -f "${TEMP_LOG}.sending"
    fi
done
