#!/bin/bash

check_and_update_system() {
    clear
    echo -e "${BLUE}=================================================${NC}"
    echo -e "${BLUE}       KIỂM TRA HỆ THỐNG & CẬP NHẬT GÓI          ${NC}"
    echo -e "${BLUE}=================================================${NC}"
    
    echo -e "${YELLOW}--> Đang kiểm tra thông tin hệ điều hành...${NC}"
    if [ -f /etc/os-release ]; then 
        . /etc/os-release; OS_NAME=$NAME; OS_VER=$VERSION_ID
    else 
        echo -e "${RED} [LỖI] Không thể đọc thông tin hệ điều hành!${NC}"
        exit 1
    fi
    
    CPU_CORES=$(nproc)
    RAM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
    DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    DISK_FREE=$(df -h / | awk 'NR==2 {print $4}')
    
    echo -e "${YELLOW}--> Đang cập nhật danh sách gói (apt update)...${NC}"
    apt update -y &>/dev/null || echo -e "${RED} [CẢNH BÁO] Có lỗi nhỏ khi cập nhật apt, tiếp tục tiến trình...${NC}"
    
    echo -e "${YELLOW}--> Đang cài đặt các thư viện lõi (curl, jq, wget, ufw, openssl, sqlite3...)...${NC}"
    apt install -y curl jq wget ufw openssl sqlite3 tar git iptables &>/dev/null
    
    echo -e "${GREEN}--> Kiểm tra và chuẩn bị hệ thống hoàn tất!${NC}"
    sleep 1
    
    clear
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}    THÔNG TIN HỆ THỐNG VPS CỦA BẠN               ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo -e " Hệ điều hành : ${YELLOW}$OS_NAME $OS_VER${NC}"
    echo -e " Chip xử lý    : ${YELLOW}$CPU_CORES Cores CPU${NC}"
    echo -e " Dung lượng RAM: ${YELLOW}$RAM_TOTAL${NC}"
    echo -e " Ổ đĩa lưu trữ : ${YELLOW}Tổng $DISK_TOTAL (Còn trống $DISK_FREE)${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo -e " 1. Đồng ý và tiếp tục cài đặt"
    echo -e " 0. Hủy bỏ"
    read -p "Lựa chọn của bạn (0-1): " init_choice </dev/tty
    if [ "$init_choice" != "1" ]; then 
        echo -e "${RED} Đã hủy cài đặt.${NC}"
        exit 0
    fi
    install_core
}

install_core() {
    echo -e "\n${BLUE}=================================================${NC}"
    echo -e "${BLUE}           BẮT ĐẦU CÀI ĐẶT SING-BOX              ${NC}"
    echo -e "${BLUE}=================================================${NC}"
    
    echo -e "${YELLOW}--> Đang tạo thư mục lưu trữ cấu hình...${NC}"
    mkdir -p $CONFIG_DIR
    
    echo -e "${YELLOW}--> Đang quét phiên bản Sing-box mới nhất từ Github...${NC}"
    TAG_NAME=$(curl -s https://api.github.com/repos/Vietnamvpn/sing-box/releases/latest | jq -r .tag_name)
    
    if [ -z "$TAG_NAME" ] || [ "$TAG_NAME" == "null" ]; then
        echo -e "${RED} [LỖI] Không thể kết nối API Github repo của bạn!${NC}"
        exit 1
    fi
    VERSION=${TAG_NAME#v}
    echo -e "${GREEN}--> Tìm thấy phiên bản: ${TAG_NAME}${NC}"
    
    echo -e "${YELLOW}--> Đang tải xuống tệp cài đặt...${NC}"
    wget -qO sing-box.tar.gz "https://github.com/Vietnamvpn/sing-box/releases/download/${TAG_NAME}/sing-box-${VERSION}-linux-amd64.tar.gz"
    
    echo -e "${YELLOW}--> Đang giải nén và thiết lập quyền thực thi...${NC}"
    tar -xzf sing-box.tar.gz && mv sing-box-${VERSION}-linux-amd64/sing-box /usr/local/bin/
    rm -rf sing-box.tar.gz sing-box-* && chmod +x /usr/local/bin/sing-box
    echo -e "${GREEN}--> Cài đặt Sing-box Core thành công!${NC}"
    
    echo -e "${YELLOW}--> Đang khởi tạo tệp cấu hình (config.json)...${NC}"
    if [ ! -f $CONFIG_FILE ]; then
        cp "$APP_DIR/templates/config.base.json" "$CONFIG_FILE"
    fi

    echo -e "${YELLOW}--> Đang thiết lập cơ sở dữ liệu SQLite...${NC}"
    sqlite3 $DB_FILE "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, node_type TEXT, port INTEGER, domain TEXT, user_key TEXT);"
    
    echo -e "${YELLOW}--> Đang tự động tạo chứng chỉ bảo mật (SSL)...${NC}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout $CONFIG_DIR/private.key -out $CONFIG_DIR/cert.pem -days 3650 -subj "/CN=bing.com" &>/dev/null

    echo -e "${YELLOW}--> Đang nạp Systemd Service để Sing-box chạy ngầm...${NC}"
    cp "$APP_DIR/templates/sing-box.service" /etc/systemd/system/sing-box.service
    systemctl daemon-reload && systemctl enable sing-box &>/dev/null

    echo -e "${YELLOW}--> Đang khởi tạo dịch vụ Log Webhook...${NC}"
    cp "$APP_DIR/templates/log-forwarder.sh" /usr/local/bin/log-forwarder.sh
    chmod +x /usr/local/bin/log-forwarder.sh

    cat << 'EOF' > /etc/systemd/system/log-forwarder.service
[Unit]
Description=Sing-box Log Forwarder (Batch Mode)
After=sing-box.service
[Service]
ExecStart=/usr/local/bin/log-forwarder.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable log-forwarder &>/dev/null
    systemctl start log-forwarder &>/dev/null
    
    echo -e "${GREEN}--> HOÀN TẤT THIẾT LẬP LÕI! Chuẩn bị chuyển sang cài đặt Node...${NC}"
    sleep 2
    
    node_wizard_initial
}

view_vps_status() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}           TRẠNG THÁI HỆ THỐNG VPS       ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e " Thời gian hoạt động (Uptime): $(uptime -p)"
    echo -e " Mức tải hệ thống (Load Avg) : $(uptime | awk -F'load average:' '{print $2}')"
    echo -e "----------------------------------------"
    echo -e " Sử dụng Bộ nhớ (RAM):"
    free -h
    echo -e "----------------------------------------"
    echo -e " Tình trạng Ổ đĩa (Disk Space):"
    df -h /
    echo -e "----------------------------------------"
    echo -e " Trạng thái kết nối mạng (Port đang mở):"
    ss -tuln | grep -E 'Listen|ESTAB' | head -n 15
    echo -e "----------------------------------------"
    read -p "Nhấn Enter để quay lại..." dummy </dev/tty
}

create_swap() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}         CẤU HÌNH BỘ NHỚ ẢO (SWAP)        ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e " Trạng thái SWAP hiện tại hệ thống:"
    swapon --show
    echo -e "----------------------------------------"
    read -p " Nhập dung lượng SWAP muốn tạo (Ví dụ: 1 hoặc 2 tương ứng 1GB/2GB, hoặc 0 để hủy): " swap_size </dev/tty
    if [ "$swap_size" == "0" ] || [ -z "$swap_size" ]; then
        echo -e "${YELLOW} Đã hủy thao tác cấu hình SWAP.${NC}"
        sleep 2
        return
    fi
    
    echo -e "--> Đang khởi tạo tệp bộ nhớ ảo SWAP ${swap_size}GB (Vui lòng chờ)..."
    swapoff -a &>/dev/null
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count=$((swap_size * 1024)) status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    fi
    echo -e "${GREEN} Tạo dung lượng ảo SWAP ${swap_size}GB thành công!${NC}"
    sleep 3
}

config_webhook() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}    CẤU HÌNH GỬI LOG LÊN WEB (WEBHOOK)   ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    CONF_FILE="/usr/local/etc/sing-box/php_url.conf"
    
    if [ -f "$CONF_FILE" ] && [ -n "$(cat "$CONF_FILE")" ]; then
        current_url=$(cat "$CONF_FILE")
        echo -e " URL hiện tại: ${GREEN}$current_url${NC}"
        echo -e " Trạng thái: ${GREEN}Đang hoạt động${NC}"
    else
        echo -e " Trạng thái: ${YELLOW}Chưa cấu hình (Đang tắt)${NC}"
    fi
    echo -e "----------------------------------------"
    echo -e " 1. Thêm / Thay đổi URL PHP nhận Log"
    echo -e " 2. Xóa URL (Tắt tính năng gửi Log)"
    echo -e " 0. Quay lại Menu"
    read -p " Nhập lựa chọn (0-2): " wh_choice </dev/tty
    
    case $wh_choice in
        1)
            read -p " Nhập URL trang PHP (Bắt đầu bằng http:// hoặc https://): " new_url </dev/tty
            if [[ "$new_url" == http* ]]; then
                echo "$new_url" > "$CONF_FILE"
                systemctl restart log-forwarder
                echo -e "${GREEN} Cập nhật thành công! Mọi log mới từ bây giờ sẽ được gửi lên web.${NC}"
            else
                echo -e "${RED} Lỗi: URL phải bắt đầu bằng http:// hoặc https://${NC}"
            fi
            sleep 3
            ;;
        2)
            rm -f "$CONF_FILE"
            systemctl restart log-forwarder
            echo -e "${GREEN} Đã xóa URL. Tính năng gửi log đã được tắt!${NC}"
            sleep 3
            ;;
        0) return ;;
        *) echo -e "${RED} Lựa chọn không hợp lệ!${NC}"; sleep 1 ;;
    esac
}

uninstall_system() {
    clear
    echo -e "${RED}=========================================${NC}"
    echo -e "${RED}   CẢNH BÁO: GỠ CÀI ĐẶT VÀ XÓA TÀN DƯ    ${NC}"
    echo -e "${RED}=========================================${NC}"
    echo -e " Thao tác này sẽ xóa KHÔNG THỂ KHÔI PHỤC:"
    echo -e " - Toàn bộ cấu hình Node và Database người dùng."
    echo -e " - File thực thi Core Sing-box."
    echo -e " - Dịch vụ (Service) chạy ngầm của hệ thống."
    echo -e " - Xóa cả script menu tool này."
    echo -e "----------------------------------------"
    read -p "Bạn có CHẮC CHẮN muốn dọn sạch mọi thứ không? (y/n): " confirm </dev/tty
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        set +e
        echo -e "\n${YELLOW}--> Đang dừng và gỡ bỏ Service...${NC}"
        systemctl stop sing-box log-forwarder &>/dev/null
        systemctl disable sing-box log-forwarder &>/dev/null
        rm -f /etc/systemd/system/sing-box.service
        rm -f /etc/systemd/system/log-forwarder.service
        systemctl daemon-reload
        
        echo -e "${YELLOW}--> Đang xóa Core, Tools và File cấu hình...${NC}"
        rm -f /usr/local/bin/sing-box
        rm -f /usr/local/bin/log-forwarder.sh
        rm -rf /usr/local/etc/sing-box
        
        echo -e "${YELLOW}--> Đang dọn dẹp Iptables Port Range (nếu có)...${NC}"
        if [ -f /etc/rc.local ]; then
            sed -i '/iptables -t nat -A PREROUTING -p udp --dport/d' /etc/rc.local 2>/dev/null
        fi
        
        echo -e "${YELLOW}--> Đang xóa Tool Menu...${NC}"
        rm -rf $APP_DIR
        rm -f $vvc_BIN
        
        echo -e "${GREEN} Đã dọn sạch toàn bộ tàn dư của Sing-box trên VPS!${NC}"
        echo -e "Bạn có thể cài lại bất cứ khi nào bằng lệnh: bash <(curl -Ls https://raw.githubusercontent.com/Vietnamvpn/linksub24h-sb/main/install.sh)."
        exit 0
    else
        echo -e "${GREEN}Đã hủy thao tác gỡ cài đặt.${NC}"
        sleep 3
    fi
}

update_script() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}       CẬP NHẬT MÃ NGUỒN TỪ GITHUB       ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e "--> Đang kéo bản cập nhật mới nhất từ Github..."
    
    cd $APP_DIR
    git reset --hard HEAD &>/dev/null
    git pull origin main
    
    if [ $? -eq 0 ]; then
        chmod +x $APP_DIR/main.sh
        chmod +x $APP_DIR/modules/*.sh
        echo -e "${GREEN} Đã cập nhật Tool thành công!${NC}"
        echo -e "--> Đang khởi động lại giao diện mới..."
        sleep 3
        exec $vvc_BIN
    else
        echo -e "${RED} Cập nhật thất bại! Vui lòng kiểm tra kết nối Github.${NC}"
        sleep 3
    fi
}