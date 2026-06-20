#!/bin/bash

# Hằng số Màu sắc
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export NC='\033[0m'

# Biến hệ thống
export CONFIG_DIR="/usr/local/etc/sing-box"
export CONFIG_FILE="$CONFIG_DIR/config.json"
export DB_FILE="$CONFIG_DIR/proxy_data.db"
export GITHUB_INSTALL_URL="https://raw.githubusercontent.com/Vietnamvpn/linksub24h-sb/refs/heads/main/install.sh"

# Bắt lỗi toàn cục
set -e
trap 'catch_error $LINENO' ERR
catch_error() {
    echo -e "\n${RED} LỖI tại dòng $1. Quá trình tạm dừng!${NC}"
    exit 1
}

# Tiện ích
get_ip() { echo $(curl -s ifconfig.me || curl -s icanhazip.com); }
