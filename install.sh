#!/bin/bash

# Thiết lập màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Cấu hình đường dẫn
REPO_ARCHIVE_URL="https://github.com/Vietnamvpn/linksub24h-sb/archive/refs/heads/main.tar.gz"
APP_DIR="/usr/local/singbox-manager"
CMD_PATH="/usr/local/bin/sbls"

echo -e "${YELLOW}--> Đang khởi tạo và tải bộ công cụ Sing-box Manager...${NC}"

# Tạo và dọn dẹp thư mục ứng dụng
mkdir -p "$APP_DIR"
rm -rf "${APP_DIR:?}/"*

# Tải và giải nén mã nguồn từ Github
if curl -sL "$REPO_ARCHIVE_URL" | tar -xz -C "$APP_DIR" --strip-components=1; then
    echo -e "${GREEN}--> Tải mã nguồn thành công!${NC}"
else
    echo -e "${RED} [LỖI] Không thể tải mã nguồn từ Github. Vui lòng kiểm tra lại mạng!${NC}"
    exit 1
fi

# Cấp quyền thực thi
chmod +x "$APP_DIR/main.sh"
find "$APP_DIR/modules" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null
find "$APP_DIR/templates" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null

# Tạo lệnh toàn cục (Global Command)
cat << EOF > "$CMD_PATH"
#!/bin/bash
cd $APP_DIR || exit 1
./main.sh
EOF

chmod +x "$CMD_PATH"

echo -e "${GREEN}--> Cài đặt hoàn tất! Đang khởi chạy...${NC}"
sleep 1

# Gọi menu
sbls
