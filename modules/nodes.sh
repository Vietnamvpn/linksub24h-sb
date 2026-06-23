#!/bin/bash

# --- FORM NHẬP LIỆU THÔNG MINH THEO GIAO THỨC ---
prompt_node_config() {
    local proto=$1
    read -p " Nhập Cổng (Port) chính cho Node này: " RET_PORT </dev/tty
    
    read -p " Nhập Domain kết nối (Bỏ trống tự động dùng IP VPS): " RET_DOM </dev/tty
    if [ -z "$RET_DOM" ]; then RET_DOM=$(get_ip); fi
    
    RET_SNI=""
    RET_RANGE=""
    
    if [ "$proto" == "hysteria2" ]; then
        read -p " Nhập SNI chứng chỉ (Bỏ trống hệ thống lấy ngẫu nhiên): " RET_SNI </dev/tty
        read -p " Nhập Port Range (Ví dụ: 2345:2347) (Bỏ trống nếu không dùng): " RET_RANGE </dev/tty
    elif [ "$proto" == "tuic" ]; then
        read -p " Nhập SNI chứng chỉ (Bỏ trống hệ thống lấy ngẫu nhiên): " RET_SNI </dev/tty
    elif [ "$proto" == "vless" ]; then
        read -p " Nhập SNI giả lập Reality (Bắt buộc, bỏ trống mặc định www.microsoft.com): " RET_SNI </dev/tty
        if [ -z "$RET_SNI" ]; then RET_SNI="www.microsoft.com"; fi
    fi

    # Tự sinh SNI ngẫu nhiên cho Hy2 và TUIC nếu người dùng bỏ trống
    if [ -z "$RET_SNI" ] && [ "$proto" != "vless" ]; then
        arr_sni=("www.google.com" "www.yahoo.com" "www.apple.com" "www.cloudflare.com")
        RET_SNI=${arr_sni[$RANDOM % ${#arr_sni[@]}]}
    fi
}

node_wizard_initial() {
    declare -a SESSION_TYPES SESSION_PORTS SESSION_DOMAINS SESSION_SNIS SESSION_RANGES
    node_idx=0
    
    while true; do
        clear
        echo -e "${BLUE}========================================= ${NC}"
        echo -e "${BLUE}   BƯỚC 1: KHAI BÁO CẤU HÌNH LOẠT NODE    ${NC}"
        echo -e "${BLUE}========================================= ${NC}"
        echo "1. Thêm cấu hình Node Hysteria2"
        echo "2. Thêm cấu hình Node TUIC v5"
        echo "3. Thêm cấu hình Node VLESS (gRPC-Reality)"
        read -p "Chọn loại giao thức (1-3): " n_choice </dev/tty
        
        case $n_choice in
            1) proto="hysteria2" ;;
            2) proto="tuic" ;;
            3) proto="vless" ;;
            *) echo -e "${RED}Lựa chọn sai!${NC}"; sleep 1; continue ;;
        esac
        
        prompt_node_config $proto
        
        SESSION_TYPES[$node_idx]=$proto
        SESSION_PORTS[$node_idx]=$RET_PORT
        SESSION_DOMAINS[$node_idx]=$RET_DOM
        SESSION_SNIS[$node_idx]=$RET_SNI
        SESSION_RANGES[$node_idx]=$RET_RANGE
        
        ufw allow $RET_PORT/udp &>/dev/null
        ufw allow $RET_PORT/tcp &>/dev/null
        if [ ! -z "$RET_RANGE" ]; then
            ufw allow ${RET_RANGE}/udp &>/dev/null
            ufw allow ${RET_RANGE}/tcp &>/dev/null
            if [ ! -f /etc/rc.local ]; then echo -e "#!/bin/bash\nexit 0" > /etc/rc.local; chmod +x /etc/rc.local; fi
            sed -i '/^exit 0/d' /etc/rc.local
            echo "iptables -t nat -A PREROUTING -p udp --dport $RET_RANGE -j REDIRECT --to-ports $RET_PORT" >> /etc/rc.local
            echo "exit 0" >> /etc/rc.local
            /etc/rc.local
        fi
        
        node_idx=$((node_idx + 1))
        echo -e "${GREEN} Đã lưu thành công.${NC}"
        read -p " Bạn có muốn thêm Node giao thức khác không? (y/n): " ext_choice </dev/tty
        if [[ "$ext_choice" != "y" && "$ext_choice" != "Y" ]]; then break; fi
    done
    
    clear
    echo -e ""
    echo -e "${PURPLE}   BƯỚC 2: KHỞI TẠO USER CHO TẤT CẢ NODE  ${NC}"
    echo -e "${PURPLE}     ---------------------------------    ${NC}"
    read -p " Nhập tên Tài khoản (Username): " common_name </dev/tty
    common_pass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
    echo -e " Mật khẩu (Password) tự động tạo: ${GREEN}$common_pass${NC}"
    common_uuid=$(cat /proc/sys/kernel/random/uuid)
    
    safe_common_name=$(echo "$common_name" | sed "s/'/''/g")
    safe_common_pass=$(echo "$common_pass" | sed "s/'/''/g")
    
    for ((i=0; i<$node_idx; i++)); do
        type=${SESSION_TYPES[$i]}
        port=${SESSION_PORTS[$i]}
        dom=${SESSION_DOMAINS[$i]}
        sni=${SESSION_SNIS[$i]}
        
        safe_dom=$(echo "$dom" | sed "s/'/''/g")
        
        if [ "$type" == "hysteria2" ]; then
            jq ".inbounds += [{\"type\": \"hysteria2\", \"tag\": \"hy2-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"name\": \"$common_name\", \"password\": \"$common_pass\"}], \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('hysteria2', $port, '$safe_dom', '$safe_common_name::$safe_common_pass::');"
            
        elif [ "$type" == "tuic" ]; then
            jq ".inbounds += [{\"type\": \"tuic\", \"tag\": \"tuic-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"uuid\": \"$common_uuid\", \"password\": \"$common_pass\"}], \"congestion_control\": \"bbr\", \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"alpn\": [\"h3\"], \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('tuic', $port, '$safe_dom', '$safe_common_name:$common_uuid:$safe_common_pass::');"
            
        elif [ "$type" == "vless" ]; then
            /usr/local/bin/sing-box generate reality-keypair > /tmp/kp.txt 2>&1
            
            # ✅ Cập nhật tương tự như trên
            priv_key=$(grep -i "Private" /tmp/kp.txt | awk '{print $NF}' | tr -d '\r')
            pub_key=$(grep -i "Public" /tmp/kp.txt | awk '{print $NF}' | tr -d '\r')
            
            if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then 
                priv_key="mK3_Ag3X_Placeholder_Must_Be_43_Chars_Long"
                pub_key="pub_placeholder"
            fi
            rm -f /tmp/kp.txt
            
            jq ".inbounds += [{\"type\": \"vless\", \"tag\": \"vless-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"uuid\": \"$common_uuid\", \"name\": \"$common_name\"}], \"tls\": {\"enabled\": true, \"server_name\": \"$sni\", \"reality\": {\"enabled\": true, \"handshake\": {\"server\": \"$sni\", \"server_port\": 443}, \"private_key\": \"$priv_key\", \"short_id\": [\"0123456789abcdef\"]}}, \"transport\": {\"type\": \"grpc\", \"service_name\": \"vless-grpc\"}}]" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('vless', $port, '$safe_dom', '$safe_common_name:$common_uuid::$pub_key:$sni');"
        fi
    done
    systemctl restart sing-box; ufw reload &>/dev/null
    echo -e "\n${GREEN} Đã thiết lập xong toàn bộ node! Nhấn vvc để vào Menu.${NC}"
    read dummy </dev/tty
}

add_single_node_menu() {
    clear
    echo -e ""
    echo -e "${BLUE}      THÊM NODE SERVER MỚI      ${NC}"
    echo -e "${BLUE}        ----------------        ${NC}"
    echo "1. Thêm cấu hình Node Hysteria2"
    echo "2. Thêm cấu hình Node TUIC v5"
    echo "3. Thêm cấu hình Node VLESS (gRPC-Reality)"
    read -p "Chọn loại giao thức (1-3): " n_choice </dev/tty
    
    case $n_choice in
        1) proto="hysteria2" ;;
        2) proto="tuic" ;;
        3) proto="vless" ;;
        *) echo -e "${RED}Sai lựa chọn!${NC}"; sleep 1; return ;;
    esac
    
    prompt_node_config $proto
    
    echo -e "----------------------------------------"
    echo -e "Tùy chọn cấp phát User cho Node mới:"
    echo -e "1) Chỉ tạo và thêm 1 User mới"
    echo -e "2) Thêm TẤT CẢ User đang có trong hệ thống vào Node này"
    read -p "Chọn (1-2): " user_choice </dev/tty

    users_list=()
    if [ "$user_choice" == "2" ]; then
        # Lấy danh sách tất cả username hiện có từ DB (cắt chuỗi trước dấu ':' đầu tiên và lọc trùng lặp)
        existing_users=$(sqlite3 $DB_FILE "SELECT user_key FROM users;" | awk -F':' '{print $1}' | sort -u)
        
        if [ -z "$existing_users" ]; then
            echo -e "${YELLOW}Không tìm thấy user nào trong Database. Tự động chuyển về chế độ thêm 1 user mới.${NC}"
            user_choice="1"
        else
            for u in $existing_users; do
                users_list+=("$u")
            done
            echo -e "${GREEN}-> Đã tìm thấy ${#users_list[@]} user trong hệ thống.${NC}"
        fi
    fi

    # Nếu người dùng chọn 1 hoặc hệ thống không có user nào để quét
    if [ "$user_choice" == "1" ]; then
        read -p " Nhập Username dành riêng cho Node mới này: " uname </dev/tty
        users_list+=("$uname")
    fi
    
    port=$RET_PORT
    dom=$RET_DOM
    sni=$RET_SNI
    range=$RET_RANGE
    safe_dom=$(echo "$dom" | sed "s/'/''/g")

    # Mở port trên UFW và thiết lập Port Hopping (nếu có)
    ufw allow $port/udp &>/dev/null
    ufw allow $port/tcp &>/dev/null
    if [ ! -z "$range" ]; then
        ufw allow ${range}/udp &>/dev/null
        ufw allow ${range}/tcp &>/dev/null
        if [ ! -f /etc/rc.local ]; then echo -e "#!/bin/bash\nexit 0" > /etc/rc.local; chmod +x /etc/rc.local; fi
        sed -i '/^exit 0/d' /etc/rc.local
        echo "iptables -t nat -A PREROUTING -p udp --dport $range -j REDIRECT --to-ports $port" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        /etc/rc.local
    fi

    # KHỞI TẠO KEYPAIR VLESS (Chỉ cần tạo 1 lần cho mỗi Node/Cổng)
    if [ "$proto" == "vless" ]; then
        /usr/local/bin/sing-box generate reality-keypair > /tmp/kp.txt 2>&1 || true
        priv_key=$(grep -i "Private" /tmp/kp.txt | awk '{print $NF}' | tr -d '\r')
        pub_key=$(grep -i "Public" /tmp/kp.txt | awk '{print $NF}' | tr -d '\r')
        
        if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then 
            priv_key="mK3_Ag3X_Placeholder_Must_Be_43_Chars_Long"
            pub_key="pub_placeholder"
        fi
        rm -f /tmp/kp.txt
    fi

    # CHUẨN BỊ MẢNG JSON CHO USERS
    jq_users_array="[]"
    echo -e "\nĐang thiết lập cấu hình cho các user..."
    
    # Vòng lặp cấp phát thông số cho từng user
    for uname in "${users_list[@]}"; do
        upass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
        uuid_gen=$(cat /proc/sys/kernel/random/uuid)
        
        safe_uname=$(echo "$uname" | sed "s/'/''/g")
        safe_upass=$(echo "$upass" | sed "s/'/''/g")

        if [ "$user_choice" == "1" ]; then
            echo -e " Mật khẩu (Password) tự động tạo cho Node này: ${GREEN}$upass${NC}"
        fi

        # Cập nhật mảng JSON và lưu vào Database theo từng giao thức
        if [ "$proto" == "hysteria2" ]; then
            jq_users_array=$(echo "$jq_users_array" | jq ". += [{\"name\": \"$uname\", \"password\": \"$upass\"}]")
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('hysteria2', $port, '$safe_dom', '$safe_uname::$safe_upass::');"
        
        elif [ "$proto" == "tuic" ]; then
            jq_users_array=$(echo "$jq_users_array" | jq ". += [{\"uuid\": \"$uuid_gen\", \"password\": \"$upass\"}]")
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('tuic', $port, '$safe_dom', '$safe_uname:$uuid_gen:$safe_upass::');"
        
        elif [ "$proto" == "vless" ]; then
            jq_users_array=$(echo "$jq_users_array" | jq ". += [{\"uuid\": \"$uuid_gen\", \"name\": \"$uname\"}]")
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('vless', $port, '$safe_dom', '$safe_uname:$uuid_gen::$pub_key:$sni');"
        fi
    done

    # INJECT MẢNG USERS VÀO FILE CONFIG TỔNG
    if [ "$proto" == "hysteria2" ]; then
        jq --argjson users "$jq_users_array" ".inbounds += [{\"type\": \"hysteria2\", \"tag\": \"hy2-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": \$users, \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
    elif [ "$proto" == "tuic" ]; then
        jq --argjson users "$jq_users_array" ".inbounds += [{\"type\": \"tuic\", \"tag\": \"tuic-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": \$users, \"congestion_control\": \"bbr\", \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"alpn\": [\"h3\"], \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
    elif [ "$proto" == "vless" ]; then
        jq --argjson users "$jq_users_array" ".inbounds += [{\"type\": \"vless\", \"tag\": \"vless-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": \$users, \"tls\": {\"enabled\": true, \"server_name\": \"$sni\", \"reality\": {\"enabled\": true, \"handshake\": {\"server\": \"$sni\", \"server_port\": 443}, \"private_key\": \"$priv_key\", \"short_id\": [\"0123456789abcdef\"]}}, \"transport\": {\"type\": \"grpc\", \"service_name\": \"vless-grpc\"}}]" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
    fi
    
    systemctl restart sing-box
    echo -e "${GREEN} Thêm Node độc lập hoàn tất! Đã cập nhật thành công ${#users_list[@]} user vào cổng $port.${NC}"
    sleep 3
}

delete_node() {
    read -p "Nhập số Cổng (Port) của node muốn xóa (Bỏ trống và nhấn Enter để xóa TẤT CẢ): " del_port </dev/tty
    
    if [ -z "$del_port" ]; then
        # CẢNH BÁO: Thêm bước xác nhận để tránh lỡ tay bấm nhầm Enter
        read -p "Bạn có chắc chắn muốn xóa TẤT CẢ các node không? (y/n): " confirm </dev/tty
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Đã hủy thao tác xóa toàn bộ."
            sleep 2
            return
        fi
        
        echo "Đang tiến hành dọn dẹp toàn bộ node..."
        # Lấy danh sách tất cả các port hiện có từ Database
        ports=$(sqlite3 $DB_FILE "SELECT port FROM users;")
        
        if [ -n "$ports" ]; then
            for p in $ports; do
                # Xóa cấu hình JSON của từng port
                jq "del(.inbounds[] | select(.listen_port == $p))" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
                # Xóa rule tường lửa
                ufw delete allow $p/udp &>/dev/null
                ufw delete allow $p/tcp &>/dev/null
            done
        fi
        
        # Dọn sạch toàn bộ dữ liệu trong bảng users
        sqlite3 $DB_FILE "DELETE FROM users;"
        
        systemctl restart sing-box
        echo -e "${GREEN}--> Đã dọn sạch TẤT CẢ các node đang có!${NC}"
        sleep 3
    else
        # BƯỚC MỚI: Kiểm tra cổng có tồn tại trong database không
        check_port=$(sqlite3 $DB_FILE "SELECT port FROM users WHERE port=$del_port;")
        
        if [ -z "$check_port" ]; then
            echo -e "${RED}Lỗi: Cổng $del_port không tồn tại trong hệ thống!${NC}"
            sleep 3
            return
        fi
        
        # Logic giữ nguyên: Xóa 1 node cụ thể
        jq "del(.inbounds[] | select(.listen_port == $del_port))" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
        ufw delete allow $del_port/udp &>/dev/null
        ufw delete allow $del_port/tcp &>/dev/null
        sqlite3 $DB_FILE "DELETE FROM users WHERE port=$del_port;"
        systemctl restart sing-box
        echo -e "${GREEN}--> Đã dọn sạch cổng $del_port!${NC}"
        sleep 3
    fi
}

update_node_config() {
    clear
    echo -e ""
    echo -e "${BLUE}     CẬP NHẬT CẤU HÌNH NODE SERVER        ${NC}"
    echo -e "${BLUE}        ------------------------          ${NC}"
    echo -e " ${YELLOW}(Bạn có thể nhập 0 hoặc n để hủy bỏ và quay lại Menu)${NC}"
    echo -e "----------------------------------------"
    
    read -p " Nhập cổng (Port) hiện tại của Node cần sửa: " old_port </dev/tty
    if [ -z "$old_port" ] || [ "$old_port" == "0" ] || [ "$old_port" == "n" ] || [ "$old_port" == "N" ]; then
        echo -e "${YELLOW} Đã hủy thao tác cập nhật Node.${NC}"
        sleep 2
        return
    fi
    
    if [[ ! "$old_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED} Lỗi: Cổng phải là một số nguyên hợp lệ!${NC}"
        sleep 3
        return
    fi

    node_exists=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .listen_port" $CONFIG_FILE 2>/dev/null)
    if [ -z "$node_exists" ] || [ "$node_exists" == "null" ]; then
        echo -e "${RED} Lỗi: Không tìm thấy Node nào đang chạy ở cổng $old_port!${NC}"
        sleep 3
        return
    fi
    
    current_tag=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .tag" $CONFIG_FILE 2>/dev/null)
    current_sni=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .tls.server_name" $CONFIG_FILE 2>/dev/null)
    
    echo -e " Node đang chọn có Tag hiện tại là: ${GREEN}$current_tag${NC}"
    echo -e " SNI hiện tại đang sử dụng là: ${GREEN}$current_sni${NC}"
    echo -e "----------------------------------------"
    echo " 1. Đổi Cổng (Port) kết nối"
    echo " 2. Đổi Domain/IP kết nối"
    echo " 3. Đổi Tên Tag nhận diện Node"
    echo " 4. Đổi SNI (chứng chỉ) của Node"
    read -p " Chọn mục cần cập nhật (1-4): " update_choice </dev/tty
    
    if [ -z "$update_choice" ] || [ "$update_choice" == "0" ] || [ "$update_choice" == "n" ] || [ "$update_choice" == "N" ]; then
        return
    fi
    
    if [ "$update_choice" == "1" ]; then
        read -p " Nhập Cổng (Port) muốn thay đổi: " new_port </dev/tty
        if [ -z "$new_port" ] || [ "$new_port" == "0" ] || [ "$new_port" == "n" ] || [ "$new_port" == "N" ]; then return; fi
        
        port_check=$(jq -r ".inbounds[] | select(.listen_port == $new_port) | .listen_port" $CONFIG_FILE 2>/dev/null)
        if [ -n "$port_check" ] && [ "$port_check" != "null" ]; then
            echo -e "${RED} Lỗi: Cổng MỚI $new_port đã bị chiếm dụng bởi Node khác!${NC}"
            sleep 3; return
        fi
        
        node_type=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .type" $CONFIG_FILE)
        new_tag="${node_type}-$new_port"
        jq "(.inbounds[] | select(.listen_port == $old_port)) |= (.listen_port = $new_port | .tag = \"$new_tag\")" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
        sqlite3 $DB_FILE "UPDATE users SET port=$new_port WHERE port=$old_port;"
        
        ufw allow $new_port/tcp &>/dev/null
        ufw allow $new_port/udp &>/dev/null
        ufw delete allow $old_port/tcp &>/dev/null
        ufw delete allow $old_port/udp &>/dev/null
        ufw reload &>/dev/null
        
        systemctl restart sing-box
        echo -e "${GREEN} Cập nhật chuyển đổi cổng thành công!${NC}"
        sleep 3
        
    elif [ "$update_choice" == "2" ]; then
        read -p " Nhập Domain hoặc IP kết nối MỚI: " new_dom </dev/tty
        safe_new_dom=$(echo "$new_dom" | sed "s/'/''/g")
        sqlite3 $DB_FILE "UPDATE users SET domain='$safe_new_dom' WHERE port=$old_port;"
        echo -e "${GREEN} Cập nhật Domain kết nối thành công!${NC}"
        sleep 3
        
    elif [ "$update_choice" == "3" ]; then
        read -p " Nhập Tên nhận diện (Tag) MỚI cho Node này: " new_tag </dev/tty
        safe_new_tag=$(echo "$new_tag" | sed 's/"/\\"/g')
        tag_check=$(jq -r ".inbounds[] | select(.tag == \"$safe_new_tag\") | .tag" $CONFIG_FILE 2>/dev/null)
        if [ -n "$tag_check" ] && [ "$tag_check" != "null" ]; then
            echo -e "${RED} Lỗi: Tên Tag MỚI [$new_tag] đã tồn tại!${NC}"; sleep 3; return
        fi
        
        jq "(.inbounds[] | select(.listen_port == $old_port)).tag = \"$safe_new_tag\"" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
        systemctl restart sing-box
        echo -e "${GREEN} Cập nhật Tên Tag thành công!${NC}"
        sleep 3
        
    elif [ "$update_choice" == "4" ]; then
        read -p " Nhập SNI (server_name) MỚI cho Node này: " new_sni </dev/tty
        safe_new_sni=$(echo "$new_sni" | sed 's/"/\\"/g')
        node_type=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .type" $CONFIG_FILE)
        
        if [ "$node_type" == "vless" ]; then
            jq "(.inbounds[] | select(.listen_port == $old_port)).tls.server_name = \"$safe_new_sni\" | (.inbounds[] | select(.listen_port == $old_port)).tls.reality.handshake.server = \"$safe_new_sni\"" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
            sqlite3 $DB_FILE "SELECT id, user_key FROM users WHERE port=$old_port AND node_type='vless';" | while read -r row; do
                u_id=$(echo "$row" | cut -d'|' -f1)
                u_key=$(echo "$row" | cut -d'|' -f2)
                part1_4=$(echo "$u_key" | cut -d':' -f1-4)
                sqlite3 $DB_FILE "UPDATE users SET user_key='${part1_4}:${safe_new_sni}' WHERE id=$u_id;"
            done
        else
            jq "(.inbounds[] | select(.listen_port == $old_port)).tls.server_name = \"$safe_new_sni\"" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || rm -f tmp.json
        fi
        
        systemctl restart sing-box
        echo -e "${GREEN} Cập nhật SNI thành công!${NC}"
        sleep 3
    fi
}

issue_cloudflare_cert() {
    clear
    echo -e ""
    echo -e "${BLUE}   XIN CHỨNG CHỈ WILDCARD SSL CLOUDFLARE ${NC}"
    echo -e "${BLUE}      -------------------------------    ${NC}"
    read -p " Nhập Tên miền gốc hoặc Wildcard, Ví dụ: nodeserver.ccwu.cc: " cf_domain </dev/tty
    if [ -z "$cf_domain" ] || [ "$cf_domain" == "0" ] || [ "$cf_domain" == "n" ] || [ "$cf_domain" == "N" ]; then return; fi
    
    if [[ "$cf_domain" != \*.* ]]; then
        echo -e "${YELLOW}--> Tự động chuyển đổi tên miền thành định dạng Wildcard: *.$cf_domain${NC}"
        cf_domain="*.$cf_domain"
        sleep 1
    fi
    
    read -p " Nhập Email tài khoản Cloudflare của bạn: " cf_email </dev/tty
    read -p " Nhập Global API Key của Cloudflare: " cf_key </dev/tty
    
    if [ -z "$cf_email" ] || [ -z "$cf_key" ]; then
        echo -e "${RED} Lỗi: Email và Global API Key không được để trống!${NC}"; sleep 3; return
    fi
    
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl https://get.acme.sh | sh -s email=$cf_email &>/dev/null
    fi
    
    export CF_Key="$cf_key"
    export CF_Email="$cf_email"
    
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$cf_domain" --keylength ec-256 --force
    
    if [ $? -eq 0 ]; then
        ~/.acme.sh/acme.sh --install-cert -d "$cf_domain" --ecc \
            --key-file "$CONFIG_DIR/private.key" \
            --fullchain-file "$CONFIG_DIR/cert.pem"
        systemctl restart sing-box
        echo -e "${GREEN} Xin thành công chứng chỉ Wildcard [$cf_domain]!${NC}"
    else
        echo -e "${RED} Xin cấp chứng chỉ thất bại! Vui lòng kiểm tra lại thông tin API hoặc trạng thái DNS.${NC}"
    fi
    sleep 5
}