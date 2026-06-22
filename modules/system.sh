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
    sleep 3
    
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
    # Đã định nghĩa đường dẫn cố định để tránh lỗi biến môi trường rỗng
    APP_DIR="/usr/local/singbox-manager"
    
    echo -e "${YELLOW}--> Đang thiết lập và biên dịch API Server (Golang)...${NC}"
    
    # Kiểm tra xem file tải từ Github về có tồn tại không rồi mới build
    if [ -f "$APP_DIR/api_server.go" ]; then
        cd $APP_DIR && go build -o /usr/local/bin/node-api api_server.go
        chmod +x /usr/local/bin/node-api
    else
        echo -e "${RED}--> Lỗi: Không tìm thấy mã nguồn api_server.go tại $APP_DIR!${NC}"
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
    sleep 3
    
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
        sleep 3
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
        
        # =========================================================================
        # TỰ ĐỘNG VÁ LỖI MẤT FILE SERVICE
        # =========================================================================
        echo -e "${YELLOW}--> Đang kiểm tra tính toàn vẹn của các dịch vụ hệ thống...${NC}"
        
        # Khôi phục log-forwarder.service nếu bị mất
        if [ ! -f /etc/systemd/system/log-forwarder.service ]; then
            echo -e "${YELLOW}    [+] Phát hiện thiếu log-forwarder.service, đang khôi phục...${NC}"
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
            systemctl daemon-reload
            systemctl enable log-forwarder &>/dev/null
        fi

        # Khôi phục node-api.service nếu bị mất.
        if [ ! -f /etc/systemd/system/node-api.service ]; then
            echo -e "${YELLOW}    [+] Phát hiện thiếu node-api.service, đang khôi phục...${NC}"
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
        fi
        # =========================================================================

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
            
            echo -e "${YELLOW}------------------------------------------------${NC}"
        else
            echo -e "${YELLOW}--> Phiên bản của bạn đã là mới nhất. Không có thay đổi nào!${NC}"
        fi
        
        echo -e "\n--> Đang khởi động lại giao diện mới..."
        sleep 4
        
        # Sửa lại đoạn này thành lệnh gọi trực tiếp vvc cho an toàn
        exec vvc
    else
        echo -e "${RED} Cập nhật thất bại! Vui lòng kiểm tra kết nối Github.${NC}"
        sleep 4
    fi
}

# =========================================================================
# HÀM CẤU HÌNH TÍCH HỢP (WEBHOOK LOG & API TRUNG TÂM)
# =========================================================================
config_central_panel() {
    clear
    echo -e ""
    echo -e "${BLUE}  CẤU HÌNH LIÊN KẾT WEB PANEL (LOG & ĐỒNG BỘ NODE)  ${NC}"
    echo -e "${BLUE}      --------------------------------------------      ${NC}"
    
    WH_CONF="/usr/local/etc/sing-box/php_url.conf"
    API_CONF="/usr/local/etc/sing-box/api.conf"
    SERVICE_API="/etc/systemd/system/node-api.service"
    
    # --- KIỂM TRA TRẠNG THÁI CHUNG ---
    if [ -f "$API_CONF" ] || [ -f "$WH_CONF" ]; then
        current_url=$(grep "WEB_URL=" "$API_CONF" 2>/dev/null | cut -d'=' -f2)
        current_port=$(grep "PORT=" "$API_CONF" 2>/dev/null | cut -d'=' -f2)
        
        echo -e " Link Web: ${GREEN}$current_url${NC}"
        echo -e " Cổng Port chung: ${GREEN}$current_port${NC}"
        
        # Kiểm tra API Service
        if systemctl is-active --quiet node-api; then
            echo -e " API Đồng bộ Node: ${GREEN}Đang hoạt động${NC}"
        else
            echo -e " API Đồng bộ Node: ${YELLOW}Đang tắt${NC}"
        fi
        
        # Kiểm tra Webhook Service
        if systemctl is-active --quiet log-forwarder; then
            echo -e " Webhook Gửi Log : ${GREEN}Đang hoạt động${NC}"
        else
            echo -e " Webhook Gửi Log : ${YELLOW}Đang tắt${NC}"
        fi
    else
        echo -e " Trạng thái: ${RED}Chưa cấu hình liên kết hệ thống${NC}"
    fi
    echo -e "----------------------------------------"
    
    echo -e " 1. Thiết lập Liên kết Web Panel (Chỉ nhập 1 lần)"
    echo -e " 2. Đẩy danh sách Node lên Web trung tâm"
    echo -e " 3. Bật / Tắt đồng loạt Dịch vụ Liên kết"
    echo -e " 4. Xóa hoàn toàn cấu hình khỏi hệ thống"
    echo -e " 0. Quay lại Menu"
    read -p " Nhập lựa chọn (0-4): " choice </dev/tty
    
    case $choice in
        1)
            if [ -f "$API_CONF" ] || [ -f "$WH_CONF" ]; then
                echo -e "${YELLOW} Lỗi: Cấu hình đã tồn tại!${NC}"
                echo -e " Vui lòng dùng phím 4 để xóa cấu hình cũ trước khi thiết lập mới."
                sleep 4
            else
                echo -e "${YELLOW}--> Tiến hành cấu hình dùng chung cho toàn bộ hệ thống${NC}"
                read -p " Nhập URL Web trung tâm (VD: https://domain.com/api): " shared_url </dev/tty
                
                if [[ "$shared_url" == http* ]]; then
                    read -p " Nhập cổng Port dùng chung (VD: 8083): " shared_port </dev/tty
                    read -p " Nhập mã Bảo mật (Token): " shared_token </dev/tty
                    
                    # 1. Lưu cấu hình Webhook (Log)
                    echo "WEB_URL=$shared_url" > "$WH_CONF"
                    echo "PORT=$shared_port" >> "$WH_CONF"
                    echo "TOKEN=$shared_token" >> "$WH_CONF"
                    
                    # 2. Lưu cấu hình API Đồng bộ (Node)
                    echo "PORT=$shared_port" > "$API_CONF"
                    echo "TOKEN=$shared_token" >> "$API_CONF"
                    echo "WEB_URL=$shared_url" >> "$API_CONF"
                    
                    # 3. Mở Firewall
                    ufw allow "$shared_port/tcp" &>/dev/null || true
                    
                    # 4. Khởi động các dịch vụ
                    systemctl enable log-forwarder &>/dev/null
                    systemctl restart log-forwarder
                    
                    if [ -f "$SERVICE_API" ]; then
                        systemctl enable node-api &>/dev/null || true
                        systemctl restart node-api
                    fi
                    
                    echo -e "${GREEN} Cập nhật thành công! Đã áp dụng Port, Token và Domain cho toàn hệ thống.${NC}"
                    sleep 2
                    sync_nodes_to_web
                    sleep 4
                else
                    echo -e "${RED} Lỗi: URL phải bắt đầu bằng http:// hoặc https://${NC}"
                    sleep 3
                fi
            fi
            ;;
        2)
            if [ -f "$API_CONF" ]; then
                if systemctl is-active --quiet node-api; then
                    sync_nodes_to_web
                else
                    echo -e "${YELLOW} Lỗi: API đang bị tắt! Vui lòng chọn phím 3 để bật lại trước khi đồng bộ.${NC}"
                fi
            else
                echo -e "${RED} Lỗi: Chưa liên kết Web Panel! Vui lòng chọn phím 1 để liên kết.${NC}"
            fi
            sleep 4
            ;;
        3)
            if [ ! -f "$API_CONF" ] && [ ! -f "$WH_CONF" ]; then
                echo -e "${RED} Lỗi: Chưa có cấu hình. Vui lòng chọn phím 1 để liên kết trước!${NC}"
                sleep 4
            else
                shared_port=$(grep "PORT=" "$API_CONF" 2>/dev/null | cut -d'=' -f2 || true)
                
                # NẾU ĐANG BẬT -> CHUYỂN SANG TẮT (Cả 2)
                if systemctl is-active --quiet node-api || systemctl is-active --quiet log-forwarder; then
                    if [ -n "$shared_port" ]; then
                        ufw delete allow "$shared_port/tcp" &>/dev/null || true
                    fi
                    
                    systemctl stop log-forwarder &>/dev/null || true
                    systemctl stop node-api &>/dev/null || true
                    
                    echo -e "${YELLOW} Đã TẮT API, Webhook và đóng cổng $shared_port (Cấu hình vẫn được giữ lại).${NC}"
                
                # NẾU ĐANG TẮT -> CHUYỂN SANG BẬT (Cả 2)
                else
                    if [ -n "$shared_port" ]; then
                        ufw allow "$shared_port/tcp" &>/dev/null || true
                    fi
                    
                    systemctl start log-forwarder &>/dev/null || true
                    systemctl start node-api &>/dev/null || true
                    
                    echo -e "${GREEN} Đã BẬT LẠI hệ thống liên kết và mở cổng $shared_port!${NC}"
                fi
                sleep 4
            fi
            ;;
        4)
            echo -e "${RED} CẢNH BÁO: Thao tác này sẽ xóa sạch cấu hình và đóng cổng API/Webhook!${NC}"
            read -p " Bạn có chắc chắn muốn xóa không? (y/n): " confirm </dev/tty
            
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                shared_port=$(grep "PORT=" "$API_CONF" 2>/dev/null | cut -d'=' -f2 || true)
                if [ -n "$shared_port" ]; then
                    ufw delete allow "$shared_port/tcp" &>/dev/null || true
                fi
                
                # Dừng dịch vụ
                systemctl stop log-forwarder &>/dev/null || true
                systemctl disable log-forwarder &>/dev/null || true
                systemctl stop node-api &>/dev/null || true
                systemctl disable node-api &>/dev/null || true
                
                # Xóa sạch cấu hình
                rm -f "$WH_CONF" || true
                rm -f "$API_CONF" || true
                
                echo -e "${GREEN} Đã dọn dẹp cấu hình và ngắt liên kết hoàn toàn khỏi hệ thống!${NC}"
            else
                echo -e "${YELLOW} Đã hủy thao tác.${NC}"
            fi
            sleep 4
            ;;
        0) return ;;
        *) echo -e "${RED} Lựa chọn không hợp lệ!${NC}"; sleep 2 ;;
    esac
}

# =========================================================================
# HÀM ĐỒNG BỘ DỮ LIỆU LÊN WEB TRUNG TÂM (ĐÃ CHUẨN HÓA BẢO MẬT API KEY)
# =========================================================================
sync_nodes_to_web() {
    echo -e "${YELLOW}--> Đang xử lý và đồng bộ danh sách Node (chỉ Admin, có gắn tag Quốc gia) lên Web trung tâm...${NC}"
    
    API_CONF="/usr/local/etc/sing-box/api.conf"
    CONFIG_FILE="/usr/local/etc/sing-box/config.json"
    DB_FILE="/usr/local/etc/sing-box/proxy_data.db"
    
    # Bổ sung việc lấy biến PORT từ file config
    API_PORT=$(grep "PORT=" "$API_CONF" | cut -d'=' -f2)
    API_URL=$(grep "WEB_URL=" "$API_CONF" | cut -d'=' -f2)
    API_TOKEN=$(grep "TOKEN=" "$API_CONF" | cut -d'=' -f2)

    # Ràng buộc phải có đủ 3 yếu tố mới cho chạy tiếp
    if [ -z "$API_URL" ] || [ -z "$API_TOKEN" ] || [ -z "$API_PORT" ]; then
        echo -e "${RED} [LỖI] Chưa cấu hình PORT, WEB_URL hoặc TOKEN trong api.conf!${NC}"
        return
    fi

    JSON_DATA="["
    
    NODE_COUNT=1
    LAST_DOM=""
    COUNTRY_CACHE="Unknown"
    
    while read -r row; do
        ntype=$(echo "$row" | cut -d'|' -f1)
        port=$(echo "$row" | cut -d'|' -f2)
        dom=$(echo "$row" | cut -d'|' -f3)
        ukey=$(echo "$row" | cut -d'|' -f4)
        
        uname=$(echo "$ukey" | cut -d':' -f1)
        
        if [ "$uname" != "admin" ]; then
            continue
        fi
        
        uuid=$(echo "$ukey" | cut -d':' -f2)
        upass=$(echo "$ukey" | cut -d':' -f3)
        pub_k=$(echo "$ukey" | cut -d':' -f4)
        db_sni=$(echo "$ukey" | cut -d':' -f5)
        
        if [ "$dom" != "$LAST_DOM" ]; then
            COUNTRY_RAW=$(curl -s -m 5 "http://ip-api.com/line/$dom?fields=country" 2>/dev/null)
            
            if [ -n "$COUNTRY_RAW" ] && [ "$COUNTRY_RAW" != "fail" ]; then
                COUNTRY_CACHE=$(echo "$COUNTRY_RAW" | tr ' ' '_')
            else
                COUNTRY_CACHE="Unknown"
            fi
            LAST_DOM="$dom"
        fi
        
        FORMATTED_COUNT=$(printf "%02d" $NODE_COUNT)
        TAG_NAME="${COUNTRY_CACHE}-${FORMATTED_COUNT}"
        ((NODE_COUNT++))
        
        if [ -z "$db_sni" ]; then
            sni=$(jq -r ".inbounds[] | select(.listen_port == $port) | .tls.server_name // \"bing.com\"" "$CONFIG_FILE" 2>/dev/null)
        else
            sni=$db_sni
        fi
        
        node_link=""
        if [ "$ntype" == "hysteria2" ]; then
            node_link="hysteria2://$upass@$dom:$port?insecure=1&sni=$sni#$TAG_NAME"
        elif [ "$ntype" == "tuic" ]; then
            node_link="tuic://$uuid:$upass@$dom:$port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$sni&allow_insecure=1#$TAG_NAME"
        elif [ "$ntype" == "vless" ]; then
            node_link="vless://$uuid@$dom:$port?security=reality&encryption=none&pbk=$pub_k&headerType=none&fp=chrome&spx=%2F&type=grpc&sni=$sni&serviceName=vless-grpc&sid=0123456789abcdef#$TAG_NAME"
        fi
        
        JSON_OBJ=$(jq -n \
            --arg name "$TAG_NAME" \
            --arg type "$ntype" \
            --arg port "$port" \
            --arg domain "$dom" \
            --arg uname "$uname" \
            --arg uuid "$uuid" \
            --arg password "$upass" \
            --arg sni "$sni" \
            --arg pub_k "$pub_k" \
            --arg link "$node_link" \
            '{name: $name, node_type: $type, port: $port, domain: $domain, username: $uname, uuid: $uuid, password: $password, sni: $sni, pub_k: $pub_k, link: $link}')
        
        if [ "$JSON_DATA" == "[" ]; then
            JSON_DATA="${JSON_DATA}${JSON_OBJ}"
        else
            JSON_DATA="${JSON_DATA},${JSON_OBJ}"
        fi
        
    done < <(sqlite3 "$DB_FILE" "SELECT node_type, port, domain, user_key FROM users;")
    
    JSON_DATA="${JSON_DATA}]"

    if [ "$JSON_DATA" == "[]" ]; then
        echo -e "${YELLOW}--> Không tìm thấy node nào của tài khoản 'admin' để đồng bộ.${NC}"
        return
    fi

    # Đã cập nhật Header mang theo Port và Token để khớp với PHP receiver
    # Đã sửa lại định dạng JSON đẩy lên chỉ bao gồm "nodes"
    RESPONSE=$(curl -s -X POST "$API_URL" \
         -H "Content-Type: application/json" \
         -H "X-API-Port: $API_PORT" \
         -H "X-API-Token: $API_TOKEN" \
         -d "{\"nodes\": $JSON_DATA}")

    if [[ "$RESPONSE" == *"success"* ]] || [ $? -eq 0 ]; then
        echo -e "${GREEN}--> Đã đồng bộ chi tiết Node lên Web thành công!${NC}"
    else
        echo -e "${RED}--> Lỗi kết nối Web trung tâm. Phản hồi API: $RESPONSE${NC}"
    fi
}