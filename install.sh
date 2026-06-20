#!/bin/bash
# Thiết lập màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Thay đường dẫn này bằng Link Github chứa thư mục source của bạn
REPO_URL="https://github.com/Vietnamvpn/linksub24h-sb.git"
APP_DIR="/usr/local/singbox-manager"

clear
# --- BẮT ĐẦU CHÀO MỪNG VÀ THÔNG TIN TÁC GIẢ ---
echo -e ""
echo -e "${GREEN}      CHÀO MỪNG BẠN ĐẾN VỚI HỆ THỐNG SING-BOX V3      ${NC}"
echo -e "${GREEN}          -------------------------------             ${NC}"
echo -e "${CYAN}  → Tác giả:${NC} Vietnamvpn | ${CYAN}Website:${NC} https://linksub24h.com"
echo -e "${CYAN}  → Phiên bản sing-box-core:${NC}${GREEN} v1.13.13${NC} SagerNet"
echo -e "${GREEN}--------------------------------------------------------------------${NC}"
echo -e ""
echo -e "${YELLOW}Nhấn Enter để tiếp tục cài đặt hoặc nhập [0] để HỦY: ${NC}"
read -r choice </dev/tty

# Kiểm tra nếu người dùng chọn 0 để hủy
if [ "$choice" = "0" ]; then
    echo -e "\n${RED}--> Đã hủy quá trình cài đặt hệ thống theo yêu cầu!${NC}\n"
    exit 0
fi
# -----------------------------------------------

clear
echo -e "${YELLOW}--> Hệ thống đang tải toàn bộ mã nguồn cấu trúc mới từ Github...${NC}"
apt-get install -y git &>/dev/null

# Xóa bản cũ nếu có và tải bản mới
rm -rf $APP_DIR
git clone $REPO_URL $APP_DIR || { echo -e "${RED}Lỗi: Không thể tải mã nguồn từ Github!${NC}"; exit 1; }

# Phân quyền thực thi
chmod +x $APP_DIR/main.sh
chmod +x $APP_DIR/modules/*.sh

# Tạo lệnh gõ tắt 'vvc' để mở menu
ln -sf $APP_DIR/main.sh /usr/local/bin/vvc

echo -e "${GREEN}--> Cài đặt mã nguồn hoàn tất!${NC}"
sleep 2

# Bắt đầu chạy file hệ thống chính
vvc