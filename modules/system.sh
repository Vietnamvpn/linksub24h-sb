#!/bin/bash

check_and_update_system() {
    clear
    echo -e ""
    echo -e "${BLUE}       BẮT ĐẦU KIỂM TRA HỆ THỐNG & CẬP NHẬT GÓI       ${NC}"
    echo -e "${BLUE}            -----------------------------             ${NC}"
    
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
    apt install -y curl jq wget ufw openssl sqlite3 tar git iptables golang-go &>/dev/null
    
    echo -e "${GREEN}--> Kiểm tra và chuẩn bị hệ thống hoàn tất!${NC}"
    sleep 1
    
    clear
    echo -e ""
    echo -e "${GREEN}    THÔNG TIN HỆ THỐNG VPS CỦA BẠN      ${NC}"
    echo -e "${GREEN}       -------------------------        ${NC}"
    echo -e " Hệ điều hành : ${YELLOW}$OS_NAME $OS_VER${NC}"
    echo -e " Chip xử lý    : ${YELLOW}$CPU_CORES Cores CPU${NC}"
    echo -e " Dung lượng RAM: ${YELLOW}$RAM_TOTAL${NC}"
    echo -e " Ổ đĩa lưu trữ : ${YELLOW}Tổng $DISK_TOTAL (Còn trống $DISK_FREE)${NC}"
    echo -e "${GREEN}---------------------------------------------------------${NC}"
    
    echo -e "${YELLOW}--> Cấu hình đáp ứng yêu cầu. Đang tự động chuyển sang cài đặt lõi...${NC}"
    sleep 2
    
    install_core
}

install_core() {
    echo -e ""
    echo -e "${BLUE}           BẮT ĐẦU CÀI ĐẶT SING-BOX              ${NC}"
    echo -e "${BLUE}              ----------------                   ${NC}"
    
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

    # =========================================================================
    # KHỞI TẠO API SERVER (TỪ FILE GITHUB)
    # =========================================================================
    echo -e "${YELLOW}--> Đang thiết lập và biên dịch API Server (Golang)...${NC}"
    
    # Kiểm tra xem file tải từ Github về có tồn tại không rồi mới build
    if [ -f "$APP_DIR/api_server.go" ]; then
        cd $APP_DIR && go build -o /usr/local/bin/node-api api_server.go
        chmod +x /usr/local/bin/node-api
    else
        echo -e "${RED}--> Lỗi: Không tìm thấy mã nguồn api_server.go!${NC}"
    fi

    # Tạo file chạy ngầm (Service) cho API nhưng để ở trạng thái ngủ đông
    cat << 'EOF' > /etc/systemd/system/node-api.service
[Unit]
Description=Go API Server for Sing-box Node Management
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/node-api
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    # =========================================================================
    
    echo -e "${GREEN}--> HOÀN TẤT THIẾT LẬP LÕI! Chuẩn bị chuyển sang cài đặt Node...${NC}"
    sleep 2
    
    node_wizard_initial
}

view_vps_status() {
    clear
    echo -e ""
    echo -e "${BLUE}           TRẠNG THÁI HỆ THỐNG VPS       ${NC}"
    echo -e "${BLUE}              -----------------          ${NC}"
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
    echo -e ""
    echo -e "${BLUE}         CẤU HÌNH BỘ NHỚ ẢO (SWAP)        ${NC}"
    echo -e "${BLUE}             -----------------          ${NC}"
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
    echo -e ""
    echo -e "${BLUE}    CẤU HÌNH GỬI LOG LÊN WEB (WEBHOOK)   ${NC}"
    echo -e "${BLUE}        ------------------------         ${NC}"
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
    echo -e ""
    echo -e "${RED}   CẢNH BÁO: GỠ CÀI ĐẶT VÀ XÓA TÀN DƯ    ${NC}"
    echo -e "${RED}        ------------------------         ${NC}"
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
        echo -e "--> Hệ thống sẽ tự động thoát sau 2 giây...${NC}"
        sleep 2
        exit 0
    else
        echo -e "${GREEN}Đã hủy thao tác gỡ cài đặt.${NC}"
        sleep 3
    fi
}

update_script() {
    clear
    echo -e ""
    echo -e "${BLUE}       CẬP NHẬT MÃ NGUỒN TỪ GITHUB       ${NC}"
    echo -e "${BLUE}         ------------------------        ${NC}"
    echo -e "--> Đang kiểm tra và kéo bản cập nhật mới nhất..."
    
    cd $APP_DIR
    
    # 1. Lưu lại mã phiên bản hiện tại trước khi cập nhật
    OLD_COMMIT=$(git rev-parse HEAD 2>/dev/null)
    
    # Xóa các thay đổi rác và kéo bản mới về
    git reset --hard HEAD &>/dev/null
    git pull origin main &>/dev/null
    
    if [ $? -eq 0 ]; then
        # 2. Lấy mã phiên bản sau khi tải về
        NEW_COMMIT=$(git rev-parse HEAD 2>/dev/null)
        
        chmod +x $APP_DIR/main.sh
        chmod +x $APP_DIR/modules/*.sh
        # ---------------------------------------------------------
        echo -e "${YELLOW}--> Đang biên dịch lại các thành phần cốt lõi...${NC}"
        if [ -f "$APP_DIR/api_server.go" ]; then
            go build -o /usr/local/bin/node-api api_server.go
            chmod +x /usr/local/bin/node-api
            # Nếu API đang chạy thì khởi động lại để nhận code mới
            if systemctl is-active --quiet node-api; then
                systemctl restart node-api &>/dev/null
            fi
        fi
        # ---------------------------------------------------------
        echo -e "${GREEN}--> Tải mã nguồn thành công!${NC}"
        
        # 3. Liệt kê các thay đổi nếu có
        if [ "$OLD_COMMIT" != "$NEW_COMMIT" ]; then
            echo -e ""
            echo -e "${YELLOW}       NHỮNG ĐIỂM MỚI TRONG BẢN CẬP NHẬT:       ${NC}"
            echo -e "${YELLOW}          ----------------------------          ${NC}"
            
            # In log từ bản cũ đến bản mới (hiển thị dấu * màu xanh và nội dung commit)
            git log ${OLD_COMMIT}..${NEW_COMMIT} --pretty=format:" ${GREEN}*${NC} %s"
            
            echo -e "\n${YELLOW}------------------------------------------------${NC}"
        else
            echo -e "${YELLOW}--> Phiên bản của bạn đã là mới nhất. Không có thay đổi nào!${NC}"
        fi
        
        echo -e "\n--> Đang khởi động lại giao diện mới..."
        sleep 4
        
        # Sửa lại đoạn này thành lệnh gọi trực tiếp vvc cho an toàn
        exec vvc
    else
        echo -e "${RED} Cập nhật thất bại! Vui lòng kiểm tra kết nối Github.${NC}"
        sleep 3
    fi
}

# =========================================================================
# HÀM ĐỒNG BỘ DỮ LIỆU LÊN WEB TRUNG TÂM
# =========================================================================
sync_nodes_to_web() {
    echo -e "${YELLOW}--> Đang đồng bộ danh sách người dùng lên Web trung tâm...${NC}"
    
    API_CONF="/usr/local/etc/sing-box/api.conf"
    DB_FILE="/usr/local/etc/sing-box/users.db"
    
    # Lấy thông tin từ file config
    API_URL=$(grep "WEB_URL=" "$API_CONF" | cut -d'=' -f2)
    API_TOKEN=$(grep "TOKEN=" "$API_CONF" | cut -d'=' -f2)

    if [ -z "$API_URL" ] || [ -z "$API_TOKEN" ]; then
        echo -e "${RED} [LỖI] Thông tin Web URL hoặc Token chưa được lưu!${NC}"
        return
    fi

    # Lấy dữ liệu từ SQLite (giả sử bảng là 'users', các cột là user_key, port, node_type)
    # Dùng jq để tạo format JSON chuẩn
    JSON_DATA=$(sqlite3 "$DB_FILE" "SELECT json_object('user_key', user_key, 'port', port, 'node_type', node_type) FROM users;" | jq -s '.')

    # Gửi lên Web trung tâm
    RESPONSE=$(curl -s -X POST "$API_URL" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer $API_TOKEN" \
         -d "{\"admin\": \"admin\", \"nodes\": $JSON_DATA}")

    if [[ "$RESPONSE" == *"success"* ]]; then
        echo -e "${GREEN}--> Đã đẩy dữ liệu lên Web thành công!${NC}"
    else
        echo -e "${RED}--> Lỗi: Web trung tâm không phản hồi hoặc dữ liệu sai định dạng.${NC}"
    fi
}

# =========================================================================
# HÀM CẤU HÌNH API
# =========================================================================
config_api_web() {
    clear
    echo -e "\n${BLUE}    LIÊN KẾT API VỚI WEB PANEL TRUNG TÂM   ${NC}\n------------------------"
    API_CONF="/usr/local/etc/sing-box/api.conf"
    
    if systemctl is-active --quiet node-api; then
        echo -e " Trạng thái: ${GREEN}Đang hoạt động (Đã liên kết)${NC}"
        echo -e " Cổng API: ${GREEN}$(grep "PORT=" "$API_CONF" | cut -d'=' -f2)${NC}"
    else
        echo -e " Trạng thái: ${YELLOW}Chưa liên kết (Hoạt động độc lập)${NC}"
    fi
    
    echo -e "----------------------------------------"
    echo -e " 1. Liên kết Web Panel (Khai báo Key, Port & URL)"
    echo -e " 2. Hủy liên kết (Tắt API)"
    echo -e " 0. Quay lại Menu"
    read -p " Nhập lựa chọn: " choice </dev/tty
    
    case $choice in
        1)
            read -p " Nhập cổng Port cho API (VD: 8083): " api_port </dev/tty
            read -p " Nhập mã Bảo mật (Token): " api_token </dev/tty
            read -p " Nhập URL Web trung tâm (VD: https://domain.com/api/sync): " api_web_url </dev/tty
            
            # Lưu config
            echo "PORT=$api_port" > "$API_CONF"
            echo "TOKEN=$api_token" >> "$API_CONF"
            echo "WEB_URL=$api_web_url" >> "$API_CONF"
            
            # Cấu hình hệ thống
            ufw allow "$api_port/tcp" &>/dev/null
            systemctl enable node-api &>/dev/null && systemctl restart node-api
            echo -e "${GREEN} Đã khởi động API Server!${NC}"
            
            # Tự động đồng bộ ngay lập tức
            sync_nodes_to_web
            sleep 3
            ;;
        2)
            systemctl stop node-api &>/dev/null && systemctl disable node-api &>/dev/null
            rm -f "$API_CONF"
            echo -e "${GREEN} Đã hủy liên kết Web Panel!${NC}"; sleep 2 ;;
        0) return ;;
        *) echo " Lựa chọn không hợp lệ!"; sleep 1 ;;
    esac
}

sync_nodes_to_web() {
    echo -e "${YELLOW}--> Đang đồng bộ danh sách Node lên Web trung tâm...${NC}"
    
    # 1. Đọc thông tin API từ file
    API_CONF="/usr/local/etc/sing-box/api.conf"
    API_URL=$(grep "WEB_URL=" "$API_CONF" | cut -d'=' -f2) # Bạn cần thêm dòng WEB_URL vào api.conf
    API_TOKEN=$(grep "TOKEN=" "$API_CONF" | cut -d'=' -f2)

    if [ -z "$API_URL" ]; then
        echo -e "${RED} [LỖI] Chưa cấu hình WEB_URL trong api.conf!${NC}"
        return
    fi

    # 2. Lấy dữ liệu từ SQLite và convert sang JSON
    # Giả sử bạn muốn gửi: node_type, port, domain, user_key
    # Dùng sqlite3 kết hợp với jq để tạo JSON
    JSON_DATA=$(sqlite3 /usr/local/etc/sing-box/users.db "SELECT json_object('node_type', node_type, 'port', port, 'domain', domain, 'user_key', user_key) FROM users;" | jq -s '.')
    
    # 3. Gửi lên web trung tâm
    # Bạn gửi kèm tên 'admin' như yêu cầu
    curl -s -X POST "$API_URL" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer $API_TOKEN" \
         -d "{\"admin\": \"admin\", \"nodes\": $JSON_DATA}" &>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}--> Đã đẩy dữ liệu lên Web thành công!${NC}"
    else
        echo -e "${RED}--> Lỗi kết nối đến Web trung tâm.${NC}"
    fi
}
