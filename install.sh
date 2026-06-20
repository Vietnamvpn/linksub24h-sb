#!/bin/bash
# Thiết lập màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Thay đường dẫn này bằng Link Github chứa thư mục source của bạn
REPO_URL="https://github.com/Vietnamvpn/linksub24h-sb.git"
APP_DIR="/usr/local/singbox-manager"

clear
echo -e "${YELLOW}--> Đang tải toàn bộ mã nguồn cấu trúc mới từ Github...${NC}"
apt-get install -y git &>/dev/null

# Xóa bản cũ nếu có và tải bản mới
rm -rf $APP_DIR
git clone $REPO_URL $APP_DIR || { echo -e "${RED}Lỗi: Không thể tải mã nguồn từ Github!${NC}"; exit 1; }

# Phân quyền thực thi
chmod +x $APP_DIR/main.sh
chmod +x $APP_DIR/modules/*.sh

# Tạo lệnh gõ tắt 'sbls' để mở menu
ln -sf $APP_DIR/main.sh /usr/local/bin/sbls

echo -e "${GREEN}--> Cài đặt mã nguồn hoàn tất!${NC}"
sleep 1

# Bắt đầu chạy file hệ thống chính
sbls