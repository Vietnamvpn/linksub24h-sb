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
# HÀM CẤU HÌNH API
# =========================================================================
config_api_web() {
    clear
    echo -e "${BLUE}    LIÊN KẾT API VỚI WEB PANEL TRUNG TÂM   ${NC}"
    echo -e "${BLUE}        ---------------------------------      ${NC}"
    API_CONF="/usr/local/etc/sing-box/api.conf"
    
    if systemctl is-active --quiet node-api; then
        echo -e " Trạng thái: ${GREEN}Đang hoạt động (Đã liên kết)${NC}"
        echo -e " Cổng API: ${GREEN}$(grep "PORT=" "$API_CONF" | cut -d'=' -f2)${NC}"
        echo -e " Link Web: ${GREEN}$(grep "WEB_URL=" "$API_CONF" | cut -d'=' -f2)${NC}"
    else
        echo -e " Trạng thái: ${YELLOW}Chưa liên kết (Hoạt động độc lập)${NC}"
    fi
    
    echo -e "----------------------------------------"
    echo -e " 1. Liên kết Web Panel (Khai báo Key, Port & URL)"
    echo -e " 2. Đẩy lại toàn bộ Node lên Web trung tâm"
    echo -e " 3. Hủy liên kết (Tắt API)"
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
            if [ -f "$API_CONF" ]; then
                sync_nodes_to_web
            else
                echo -e "${RED} Lỗi: Chưa liên kết Web Panel! Vui lòng chọn phím 1 trước.${NC}"
            fi
            sleep 3
            ;;
        3)
            systemctl stop node-api &>/dev/null && systemctl disable node-api &>/dev/null
            rm -f "$API_CONF"
            echo -e "${GREEN} Đã hủy liên kết Web Panel!${NC}"; sleep 2 ;;
        0) return ;;
        *) echo " Lựa chọn không hợp lệ!"; sleep 1 ;;
    esac
}

# =========================================================================
# HÀM ĐỒNG BỘ DỮ LIỆU LÊN WEB TRUNG TÂM (ĐÃ FIX LỖI NODE & CHỈ LẤY ADMIN)
# =========================================================================
sync_nodes_to_web() {
    echo -e "${YELLOW}--> Đang xử lý và đồng bộ danh sách Node (chỉ Admin) lên Web trung tâm...${NC}"
    
    API_CONF="/usr/local/etc/sing-box/api.conf"
    CONFIG_FILE="/usr/local/etc/sing-box/config.json"
    DB_FILE="/usr/local/etc/sing-box/proxy_data.db"
    
    API_URL=$(grep "WEB_URL=" "$API_CONF" | cut -d'=' -f2)
    API_TOKEN=$(grep "TOKEN=" "$API_CONF" | cut -d'=' -f2)

    if [ -z "$API_URL" ] || [ -z "$API_TOKEN" ]; then
        echo -e "${RED} [LỖI] Chưa cấu hình WEB_URL hoặc TOKEN trong api.conf!${NC}"
        return
    fi

    JSON_DATA="["
    
    # Đọc và bóc tách từng dòng từ Database y hệt như lúc export link
    while read -r row; do
        ntype=$(echo "$row" | cut -d'|' -f1)
        port=$(echo "$row" | cut -d'|' -f2)
        dom=$(echo "$row" | cut -d'|' -f3)
        ukey=$(echo "$row" | cut -d'|' -f4)
        
        uname=$(echo "$ukey" | cut -d':' -f1)
        
        # ---------------------------------------------------------
        # CHỈ LẤY NODE CỦA ADMIN: Nếu không phải "admin" thì bỏ qua
        # ---------------------------------------------------------
        if [ "$uname" != "admin" ]; then
            continue
        fi
        
        uuid=$(echo "$ukey" | cut -d':' -f2)
        upass=$(echo "$ukey" | cut -d':' -f3)
        pub_k=$(echo "$ukey" | cut -d':' -f4)
        db_sni=$(echo "$ukey" | cut -d':' -f5)
        
        # Fallback lấy SNI từ config.json nếu DB không có
        if [ -z "$db_sni" ]; then
            sni=$(jq -r ".inbounds[] | select(.listen_port == $port) | .tls.server_name // \"bing.com\"" "$CONFIG_FILE" 2>/dev/null)
        else
            sni=$db_sni
        fi
        
        # Build URL Node hoàn chỉnh để API Web dễ dàng sử dụng
        node_link=""
        if [ "$ntype" == "hysteria2" ]; then
            node_link="hysteria2://$upass@$dom:$port?insecure=1&sni=$sni"
        elif [ "$ntype" == "tuic" ]; then
            node_link="tuic://$uuid:$upass@$dom:$port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$sni&allow_insecure=1"
        elif [ "$ntype" == "vless" ]; then
            node_link="vless://$uuid@$dom:$port?security=reality&encryption=none&pbk=$pub_k&headerType=none&fp=chrome&spx=%2F&type=grpc&sni=$sni&serviceName=vless-grpc&sid=0123456789abcdef"
        fi
        
        # Đóng gói JSON an toàn bằng jq, chống lỗi escape nháy kép
        JSON_OBJ=$(jq -n \
            --arg type "$ntype" \
            --arg port "$port" \
            --arg domain "$dom" \
            --arg uname "$uname" \
            --arg uuid "$uuid" \
            --arg password "$upass" \
            --arg sni "$sni" \
            --arg pub_k "$pub_k" \
            --arg link "$node_link" \
            '{node_type: $type, port: $port, domain: $domain, username: $uname, uuid: $uuid, password: $password, sni: $sni, pub_k: $pub_k, link: $link}')
        
        # Nối vào mảng JSON
        if [ "$JSON_DATA" == "[" ]; then
            JSON_DATA="${JSON_DATA}${JSON_OBJ}"
        else
            JSON_DATA="${JSON_DATA},${JSON_OBJ}"
        fi
        
    done < <(sqlite3 "$DB_FILE" "SELECT node_type, port, domain, user_key FROM users;")
    
    JSON_DATA="${JSON_DATA}]"

    # Tránh gửi request nếu mảng rỗng (không có node admin nào)
    if [ "$JSON_DATA" == "[]" ]; then
        echo -e "${YELLOW}--> Không tìm thấy node nào của tài khoản 'admin' để đồng bộ.${NC}"
        return
    fi

    # POST payload chuẩn lên Web Panel
    RESPONSE=$(curl -s -X POST "$API_URL" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer $API_TOKEN" \
         -d "{\"admin\": \"admin\", \"nodes\": $JSON_DATA}")

    # Log kết quả
    if [[ "$RESPONSE" == *"success"* ]] || [ $? -eq 0 ]; then
        echo -e "${GREEN}--> Đã đồng bộ chi tiết Node lên Web thành công!${NC}"
    else
        echo -e "${RED}--> Lỗi kết nối Web trung tâm. Phản hồi API: $RESPONSE${NC}"
    fi
}