#!/bin/bash

# Thiết lập màu sắc hiển thị
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export NC='\033[0m'

# Biến môi trường hệ thống
export CONFIG_DIR="/usr/local/etc/sing-box"
export CONFIG_FILE="$CONFIG_DIR/config.json"
export DB_FILE="$CONFIG_DIR/proxy_data.db"
export vvc_BIN="/usr/local/bin/vvc"

catch_error() {
    echo -e "\n${RED} LỖI tại dòng $1. Quá trình cài đặt tạm dừng!${NC}"
    exit 1
}

get_ip() { echo $(curl -s ifconfig.me || curl -s icanhazip.com); }