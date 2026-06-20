#!/bin/bash
CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
TEMP_LOG="/tmp/singbox_pending.log"

touch "$TEMP_LOG"

journalctl -u sing-box -f -n 0 | while read -r line; do
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        > "$TEMP_LOG"
        continue
    fi
    if [[ "$line" =~ "inbound/" && ( "$line" =~ "opened" || "$line" =~ "closed" || "$line" =~ "rejected" ) ]]; then
        echo "$line" >> "$TEMP_LOG"
    fi
done &
PID_JOURNAL=$!

VPS_IP=$(curl -s ifconfig.me || curl -s icanhazip.com)
trap 'kill $PID_JOURNAL; exit 0' SIGTERM SIGINT

while true; do
    sleep 60
    if [ ! -f "$CONF_FILE" ] || [ -z "$(cat "$CONF_FILE")" ]; then
        > "$TEMP_LOG"
        continue
    fi
    PHP_URL=$(cat "$CONF_FILE")
    if [ -s "$TEMP_LOG" ]; then
        mv "$TEMP_LOG" "${TEMP_LOG}.sending"
        touch "$TEMP_LOG"
        LOG_CONTENT=$(cat "${TEMP_LOG}.sending" | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
        curl -s -X POST "$PHP_URL" \
             -H "Content-Type: application/json" \
             -d "{\"vps_ip\":\"$VPS_IP\", \"batch\": true, \"log\":\"$LOG_CONTENT\"}"
        rm -f "${TEMP_LOG}.sending"
    fi
done