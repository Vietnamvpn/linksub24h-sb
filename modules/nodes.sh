#!/bin/bash

prompt_node_config() {
    local proto=$1
    read -p " Nhập Cổng (Port) chính cho Node này: " RET_PORT </dev/tty
    
    read -p " Nhập Domain kết nối (Bỏ trống tự động dùng IP VPS): " RET_DOM </dev/tty
    if [ -z "$RET_DOM" ]; then RET_DOM=$(get_ip); fi
    
    RET_SNI=""
    RET_RANGE=""
    
    if [ "$proto" == "hysteria2" ]; then
        read -p " Nhập SNI chứng chỉ (Bỏ trống lấy ngẫu nhiên): " RET_SNI </dev/tty
        read -p " Nhập Port Range (Ví dụ: 2345:2347) (Bỏ trống nếu không dùng): " RET_RANGE </dev/tty
    elif [ "$proto" == "tuic" ]; then
        read -p " Nhập SNI chứng chỉ (Bỏ trống lấy ngẫu nhiên): " RET_SNI </dev/tty
    elif [ "$proto" == "vless" ]; then
        read -p " Nhập SNI giả lập Reality (Bắt buộc, bỏ trống mặc định www.microsoft.com): " RET_SNI </dev/tty
        if [ -z "$RET_SNI" ]; then RET_SNI="www.microsoft.com"; fi
    fi

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
        if [ ! -f "$CONFIG_FILE" ]; then
            mkdir -p "$(dirname "$CONFIG_FILE")"
            echo '{"inbounds": [], "outbounds": []}' > "$CONFIG_FILE"
        fi
        port_check=$(jq -r ".inbounds[] | select(.listen_port == $RET_PORT)" $CONFIG_FILE 2>/dev/null)
        if [ ! -z "$port_check" ] && [ "$port_check" != "null" ]; then
            echo -e "${RED}Lỗi: Cổng $RET_PORT đã được sử dụng! Vui lòng chọn cổng khác.${NC}"
            sleep 2
            continue
        fi
        
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
    echo -e "${PURPLE}========================================= ${NC}"
    echo -e "${PURPLE}   BƯỚC 2: KHỞI TẠO USER CHO TẤT CẢ NODE  ${NC}"
    echo -e "${PURPLE}========================================= ${NC}"
    read -p " Nhập tên Tài khoản (Username) chung: " common_name </dev/tty
    common_pass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
    echo -e " Mật khẩu (Password) chung tự động tạo: ${GREEN}$common_pass${NC}"
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
            jq ".inbounds += [{\"type\": \"hysteria2\", \"tag\": \"hy2-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"name\": \"$common_name\", \"password\": \"$common_pass\"}], \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('hysteria2', $port, '$safe_dom', '$safe_common_name::$safe_common_pass::');"
            
        elif [ "$type" == "tuic" ]; then
            jq ".inbounds += [{\"type\": \"tuic\", \"tag\": \"tuic-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"uuid\": \"$common_uuid\", \"password\": \"$common_pass\"}], \"congestion_control\": \"bbr\", \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"alpn\": [\"h3\"], \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('tuic', $port, '$safe_dom', '$safe_common_name:$common_uuid:$safe_common_pass::');"
            
        elif [ "$type" == "vless" ]; then
            /usr/local/bin/sing-box generate reality-keypair > /tmp/kp.txt 2>&1
            priv_key=$(awk '/[Pp]rivate/ {print $NF}' /tmp/kp.txt | tr -d '\r')
            pub_key=$(awk '/[Pp]ublic/ {print $NF}' /tmp/kp.txt | tr -d '\r')
            if [ -z "$priv_key" ]; then 
                priv_key="mK3_Ag3X_Placeholder_Must_Be_43_Chars_Long"
                pub_key="pub_placeholder"
            fi
            rm -f /tmp/kp.txt
            
            jq ".inbounds += [{\"type\": \"vless\", \"tag\": \"vless-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"uuid\": \"$common_uuid\", \"name\": \"$common_name\"}], \"tls\": {\"enabled\": true, \"server_name\": \"$sni\", \"reality\": {\"enabled\": true, \"handshake\": {\"server\": \"$sni\", \"server_port\": 443}, \"private_key\": \"$priv_key\", \"short_id\": [\"0123456789abcdef\"]}}, \"transport\": {\"type\": \"grpc\", \"service_name\": \"vless-grpc\"}}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('vless', $port, '$safe_dom', '$safe_common_name:$common_uuid::$pub_key:$sni');"
        fi
    done
    systemctl restart sing-box; ufw reload &>/dev/null
    echo -e "\n${GREEN} ĐÃ THIẾT LẬP XONG TOÀN BỘ NODE! Nhấn Enter để vào Menu.${NC}"
    read dummy </dev/tty
}

add_single_node_menu() {
    clear
    echo -e "${BLUE}========================================= ${NC}"
    echo -e "${BLUE}      [NODE] THÊM NODE PROXY ĐỘC LẬP      ${NC}"
    echo -e "${BLUE}========================================= ${NC}"
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
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        echo '{"inbounds": [], "outbounds": []}' > "$CONFIG_FILE"
    fi
    port_check=$(jq -r ".inbounds[] | select(.listen_port == $RET_PORT)" $CONFIG_FILE 2>/dev/null)
    if [ ! -z "$port_check" ] && [ "$port_check" != "null" ]; then
        echo -e "${RED}Lỗi: Cổng $RET_PORT đã được sử dụng bởi một Node khác!${NC}"
        sleep 2
        return
    fi
    
    echo -e "----------------------------------------"
    read -p " Nhập Username dành riêng cho Node mới này: " uname </dev/tty
    upass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10)
    echo -e " Mật khẩu (Password) tự động tạo cho Node này: ${GREEN}$upass${NC}"
    uuid_gen=$(cat /proc/sys/kernel/random/uuid)
    
    port=$RET_PORT
    dom=$RET_DOM
    sni=$RET_SNI
    range=$RET_RANGE
    
    safe_uname=$(echo "$uname" | sed "s/'/''/g")
    safe_upass=$(echo "$upass" | sed "s/'/''/g")
    safe_dom=$(echo "$dom" | sed "s/'/''/g")
    
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
    
    if [ "$proto" == "hysteria2" ]; then
        jq ".inbounds += [{\"type\": \"hysteria2\", \"tag\": \"hy2-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"name\": \"$uname\", \"password\": \"$upass\"}], \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('hysteria2', $port, '$safe_dom', '$safe_uname::$safe_upass::');"
    elif [ "$proto" == "tuic" ]; then
        jq ".inbounds += [{\"type\": \"tuic\", \"tag\": \"tuic-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"uuid\": \"$uuid_gen\", \"password\": \"$upass\"}], \"congestion_control\": \"bbr\", \"tls\": {\"enabled\": true, \"certificate_path\": \"$CONFIG_DIR/cert.pem\", \"key_path\": \"$CONFIG_DIR/private.key\", \"alpn\": [\"h3\"], \"server_name\": \"$sni\"}}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('tuic', $port, '$safe_dom', '$safe_uname:$uuid_gen:$safe_upass::');"
    elif [ "$proto" == "vless" ]; then
        /usr/local/bin/sing-box generate reality-keypair > /tmp/kp.txt 2>/dev/null || true
        priv_key=$(awk '/[Pp]rivate/ {print $NF}' /tmp/kp.txt | tr -d '\r')
        pub_key=$(awk '/[Pp]ublic/ {print $NF}' /tmp/kp.txt | tr -d '\r')
        if [ -z "$priv_key" ]; then priv_key="mK3_Ag3X_Placeholder"; pub_key="pub_placeholder"; fi
        rm -f /tmp/kp.txt
        jq ".inbounds += [{\"type\": \"vless\", \"tag\": \"vless-$port\", \"listen\": \"::\", \"listen_port\": $port, \"users\": [{\"uuid\": \"$uuid_gen\", \"name\": \"$uname\"}], \"tls\": {\"enabled\": true, \"server_name\": \"$sni\", \"reality\": {\"enabled\": true, \"handshake\": {\"server\": \"$sni\", \"server_port\": 443}, \"private_key\": \"$priv_key\", \"short_id\": [\"0123456789abcdef\"]}}, \"transport\": {\"type\": \"grpc\", \"service_name\": \"vless-grpc\"}}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('vless', $port, '$safe_dom', '$safe_uname:$uuid_gen::$pub_key:$sni');"
    fi
    
    systemctl restart sing-box
    echo -e "${GREEN} Thêm Node độc lập hoàn tất!${NC}"
    sleep 3
}

update_node_config() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}     CẬP NHẬT CẤU HÌNH NODE PROXY        ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    read -p " Nhập cổng (Port) hiện tại của Node cần sửa: " old_port </dev/tty
    if [ -z "$old_port" ] || [ "$old_port" == "0" ] || [ "$old_port" == "n" ]; then return; fi
    
    if [[ ! "$old_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED} Lỗi: Cổng phải là một số nguyên hợp lệ!${NC}"; sleep 3; return
    fi

    node_exists=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .listen_port" $CONFIG_FILE 2>/dev/null)
    if [ -z "$node_exists" ] || [ "$node_exists" == "null" ]; then
        echo -e "${RED} Lỗi: Không tìm thấy Node ở cổng $old_port!${NC}"; sleep 3; return
    fi
    
    current_tag=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .tag" $CONFIG_FILE 2>/dev/null)
    current_sni=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .tls.server_name" $CONFIG_FILE 2>/dev/null)
    
    echo -e " Tag hiện tại: ${GREEN}$current_tag${NC}"
    echo -e " SNI hiện tại: ${GREEN}$current_sni${NC}"
    echo -e "----------------------------------------"
    echo " 1. Đổi Cổng (Port)"
    echo " 2. Đổi Domain/IP kết nối"
    echo " 3. Đổi Tên nhận diện (Tag)"
    echo " 4. Đổi SNI (server_name)"
    read -p " Chọn mục cần cập nhật (1-4): " update_choice </dev/tty
    
    if [ "$update_choice" == "1" ]; then
        read -p " Nhập Cổng (Port) MỚI: " new_port </dev/tty
        if [[ ! "$new_port" =~ ^[0-9]+$ ]]; then return; fi
        
        node_type=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .type" $CONFIG_FILE)
        new_tag="${node_type}-$new_port"
        jq "(.inbounds[] | select(.listen_port == $old_port)) |= (.listen_port = $new_port | .tag = \"$new_tag\")" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || { echo "Lỗi cập nhật JSON"; rm -f tmp.json; return; }
        sqlite3 $DB_FILE "UPDATE users SET port=$new_port WHERE port=$old_port;"
        
        ufw allow $new_port/tcp &>/dev/null; ufw allow $new_port/udp &>/dev/null
        ufw delete allow $old_port/tcp &>/dev/null; ufw delete allow $old_port/udp &>/dev/null
        ufw reload &>/dev/null
        
    elif [ "$update_choice" == "2" ]; then
        read -p " Nhập Domain MỚI: " new_dom </dev/tty
        safe_new_dom=$(echo "$new_dom" | sed "s/'/''/g")
        sqlite3 $DB_FILE "UPDATE users SET domain='$safe_new_dom' WHERE port=$old_port;"
        
    elif [ "$update_choice" == "3" ]; then
        read -p " Nhập Tag MỚI: " new_tag </dev/tty
        safe_new_tag=$(echo "$new_tag" | sed 's/"/\\"/g')
        jq "(.inbounds[] | select(.listen_port == $old_port)).tag = \"$safe_new_tag\"" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        
    elif [ "$update_choice" == "4" ]; then
        read -p " Nhập SNI MỚI: " new_sni </dev/tty
        safe_new_sni=$(echo "$new_sni" | sed 's/"/\\"/g')
        node_type=$(jq -r ".inbounds[] | select(.listen_port == $old_port) | .type" $CONFIG_FILE)
        
        if [ "$node_type" == "vless" ]; then
            jq "(.inbounds[] | select(.listen_port == $old_port)).tls.server_name = \"$safe_new_sni\" | (.inbounds[] | select(.listen_port == $old_port)).tls.reality.handshake.server = \"$safe_new_sni\"" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            sqlite3 $DB_FILE "SELECT id, user_key FROM users WHERE port=$old_port AND node_type='vless';" | while read -r row; do
                u_id=$(echo "$row" | cut -d'|' -f1)
                u_key=$(echo "$row" | cut -d'|' -f2)
                part1_4=$(echo "$u_key" | cut -d':' -f1-4)
                sqlite3 $DB_FILE "UPDATE users SET user_key='${part1_4}:${safe_new_sni}' WHERE id=$u_id;"
            done
        else
            jq "(.inbounds[] | select(.listen_port == $old_port)).tls.server_name = \"$safe_new_sni\"" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        fi
    fi
    
    systemctl restart sing-box
    echo -e "${GREEN} Cập nhật Node thành công!${NC}"
    sleep 3
}

delete_node() {
    read -p "Nhập số Cổng (Port) của node muốn xóa: " del_port </dev/tty
    
    # Xóa file JSON an toàn
    jq "del(.inbounds[] | select(.listen_port == $del_port))" $CONFIG_FILE > tmp.json && [ -s tmp.json ] && mv tmp.json $CONFIG_FILE || { echo "Lỗi file cấu hình!"; return; }
    
    # Dọn dẹp tường lửa
    ufw delete allow $del_port/udp &>/dev/null
    ufw delete allow $del_port/tcp &>/dev/null
    
    # Dọn dẹp iptables trong rc.local (nếu có)
    sed -i "/dport $del_port/d" /etc/rc.local
    
    sqlite3 $DB_FILE "DELETE FROM users WHERE port=$del_port;"
    systemctl restart sing-box
    echo -e "${GREEN}--> Đã xóa hoàn toàn cổng $del_port!${NC}"
    sleep 3
}