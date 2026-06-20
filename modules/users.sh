#!/bin/bash

list_links() {
    clear
    echo "======================================================="
    echo "          DANH SÁCH TOÀN BỘ LINK NODE CỦA BẠN          "
    echo "======================================================="
    
    echo -e "--> Đang lấy thông tin quốc gia của máy chủ..."
    vps_country=$(curl -s -m 5 http://ip-api.com/json/ | jq -r '.country // "VPS"')
    safe_country=$(echo "$vps_country" | sed 's/ /_/g')
    
    all_names=$(sqlite3 $DB_FILE "SELECT DISTINCT SUBSTR(user_key, 1, INSTR(user_key, ':') - 1) FROM users;")
    
    if [ -z "$all_names" ]; then
        echo -e "\n ${YELLOW}Chưa có người dùng nào trên hệ thống.${NC}"
    else
        for u_name in $all_names; do
            echo -e "\n NGƯỜI DÙNG: $u_name"
            echo "-------------------------------------------------------"
            
            node_count=1
            sqlite3 $DB_FILE "SELECT node_type, port, domain, user_key FROM users WHERE user_key LIKE '$u_name:%';" | while read -r row; do
                ntype=$(echo "$row" | cut -d'|' -f1)
                port=$(echo "$row" | cut -d'|' -f2)
                dom=$(echo "$row" | cut -d'|' -f3)
                ukey=$(echo "$row" | cut -d'|' -f4)
                
                uuid=$(echo "$ukey" | cut -d':' -f2)
                upass=$(echo "$ukey" | cut -d':' -f3)
                pub_k=$(echo "$ukey" | cut -d':' -f4)
                db_sni=$(echo "$ukey" | cut -d':' -f5)
                
                if [ -z "$db_sni" ]; then
                    sni=$(jq -r ".inbounds[] | select(.listen_port == $port) | .tls.server_name // \"bing.com\"" $CONFIG_FILE 2>/dev/null)
                else
                    sni=$db_sni
                fi
                
                idx_str=$(printf "%02d" $node_count)
                remark_tag="${safe_country}-${idx_str}"
                
                if [ "$ntype" == "hysteria2" ]; then
                    echo " hysteria2://$upass@$dom:$port?insecure=1&sni=$sni#$remark_tag"
                elif [ "$ntype" == "tuic" ]; then
                    echo " tuic://$uuid:$upass@$dom:$port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$sni&allow_insecure=1#$remark_tag"
                elif [ "$ntype" == "vless" ]; then
                    echo " vless://$uuid@$dom:$port?security=reality&encryption=none&pbk=$pub_k&headerType=none&fp=chrome&spx=%2F&type=grpc&sni=$sni&serviceName=vless-grpc&sid=0123456789abcdef#$remark_tag"
                fi
                node_count=$((node_count + 1))
            done
        done
    fi
    echo -e "\n======================================================="
    read -p "Nhấn Enter để quay lại..." dummy </dev/tty
}

add_user_advanced() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}         THÊM NGƯỜI DÙNG MỚI VÀO NODE    ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    read -p " Nhập cổng Node muốn thêm (để trống thêm vào tất cả): " target_port </dev/tty
    
    read -p " Nhập tên User viết liền không dấu: " uname </dev/tty
    if [ -z "$uname" ]; then return; fi
    safe_uname=$(echo "$uname" | sed "s/'/''/g")

    if [ -z "$target_port" ]; then
        db_count=$(sqlite3 $DB_FILE "SELECT COUNT(*) FROM users WHERE user_key LIKE '$safe_uname:%';")
        if [ "$db_count" -gt 0 ]; then echo -e "${YELLOW} ĐÃ TỒN TẠI!${NC}"; sleep 3; return; fi
    else
        db_count=$(sqlite3 $DB_FILE "SELECT COUNT(*) FROM users WHERE port=$target_port AND user_key LIKE '$safe_uname:%';")
        if [ "$db_count" -gt 0 ]; then echo -e "${YELLOW} ĐÃ CÓ MẶT ở Node $target_port!${NC}"; sleep 3; return; fi
    fi

    upass=$(sqlite3 $DB_FILE "SELECT user_key FROM users WHERE user_key LIKE '$safe_uname:%' AND (node_type='hysteria2' OR node_type='tuic') LIMIT 1;" | cut -d':' -f3 | tr -d '\r')
    if [ -z "$upass" ]; then upass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10); fi
    safe_upass=$(echo "$upass" | sed "s/'/''/g")

    uuid_gen=$(sqlite3 $DB_FILE "SELECT user_key FROM users WHERE user_key LIKE '$safe_uname:%' AND (node_type='vless' OR node_type='tuic') LIMIT 1;" | cut -d':' -f2 | tr -d '\r')
    if [ -z "$uuid_gen" ]; then uuid_gen=$(cat /proc/sys/kernel/random/uuid); fi
    
    set +e 
    if [ -z "$target_port" ]; then
        ports=$(jq -r '.inbounds[].listen_port' $CONFIG_FILE)
        for p in $ports; do
            type=$(jq -r ".inbounds[] | select(.listen_port == $p) | .type" $CONFIG_FILE)
            dom=$(sqlite3 $DB_FILE "SELECT domain FROM users WHERE port=$p LIMIT 1;")
            if [ -z "$dom" ]; then dom=$(get_ip); fi
            safe_dom=$(echo "$dom" | sed "s/'/''/g")
            
            if [ "$type" == "hysteria2" ]; then
                jq "(.inbounds[] | select(.listen_port == $p).users) += [{\"name\": \"$uname\", \"password\": \"$upass\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
                sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('hysteria2', $p, '$safe_dom', '$safe_uname::$safe_upass::');"
            elif [ "$type" == "tuic" ]; then
                jq "(.inbounds[] | select(.listen_port == $p).users) += [{\"uuid\": \"$uuid_gen\", \"password\": \"$upass\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
                sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('tuic', $p, '$safe_dom', '$safe_uname:$uuid_gen:$safe_upass::');"
            elif [ "$type" == "vless" ]; then
                sni=$(jq -r ".inbounds[] | select(.listen_port == $p).tls.server_name" $CONFIG_FILE)
                pub_k=$(sqlite3 $DB_FILE "SELECT user_key FROM users WHERE port=$p AND node_type='vless' LIMIT 1;" | cut -d':' -f4 | tr -d '\r')
                if [ -z "$pub_k" ]; then pub_k="reused_key"; fi
                
                jq "(.inbounds[] | select(.listen_port == $p).users) += [{\"uuid\": \"$uuid_gen\", \"name\": \"$uname\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
                sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('vless', $p, '$safe_dom', '$safe_uname:$uuid_gen::$pub_k:$sni');"
            fi
        done
        echo -e "${GREEN} Thêm User thành công!${NC}"
    else
        type=$(jq -r ".inbounds[] | select(.listen_port == $target_port) | .type" $CONFIG_FILE)
        dom=$(sqlite3 $DB_FILE "SELECT domain FROM users WHERE port=$target_port LIMIT 1;")
        if [ -z "$dom" ]; then dom=$(get_ip); fi
        safe_dom=$(echo "$dom" | sed "s/'/''/g")
        
        if [ "$type" == "hysteria2" ]; then
            jq "(.inbounds[] | select(.listen_port == $target_port).users) += [{\"name\": \"$uname\", \"password\": \"$upass\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('hysteria2', $target_port, '$safe_dom', '$safe_uname::$safe_upass::');"
        elif [ "$type" == "tuic" ]; then
            jq "(.inbounds[] | select(.listen_port == $target_port).users) += [{\"uuid\": \"$uuid_gen\", \"password\": \"$upass\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('tuic', $target_port, '$safe_dom', '$safe_uname:$uuid_gen:$safe_upass::');"
        elif [ "$type" == "vless" ]; then
            sni=$(jq -r ".inbounds[] | select(.listen_port == $target_port).tls.server_name" $CONFIG_FILE)
            pub_k=$(sqlite3 $DB_FILE "SELECT user_key FROM users WHERE port=$target_port AND node_type='vless' LIMIT 1;" | cut -d':' -f4 | tr -d '\r')
            if [ -z "$pub_k" ]; then pub_k="reused_key"; fi
            
            jq "(.inbounds[] | select(.listen_port == $target_port).users) += [{\"uuid\": \"$uuid_gen\", \"name\": \"$uname\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            sqlite3 $DB_FILE "INSERT INTO users (node_type, port, domain, user_key) VALUES ('vless', $target_port, '$safe_dom', '$safe_uname:$uuid_gen::$pub_k:$sni');"
        fi
        echo -e "${GREEN} Đã thêm User vào cổng [$target_port] thành công!${NC}"
    fi
    set -e 
    systemctl restart sing-box; sleep 3
}

delete_user_from_node() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}         XÓA NGƯỜI DÙNG KHỎI NODE        ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    read -p " Nhập chính xác Tên User cần xóa: " target_del </dev/tty
    
    if [ -z "$target_del" ]; then return; fi

    db_check=$(sqlite3 $DB_FILE "SELECT COUNT(*) FROM users WHERE user_key LIKE '$target_del:%';")
    if [ "$db_check" -eq 0 ]; then
        echo -e "${RED} Không tìm thấy người dùng!${NC}"; sleep 3; return
    fi

    read -p " Nhập Cổng muốn xóa, để trống sẽ xóa tất cả: " port </dev/tty
    set +e 
    
    target_uuid=$(sqlite3 $DB_FILE "SELECT user_key FROM users WHERE user_key LIKE '$target_del:%' AND node_type IN ('tuic', 'vless') LIMIT 1;" | cut -d':' -f2 | tr -d '\r')
    if [ -z "$target_uuid" ]; then target_uuid="NO_UUID_FOUND"; fi
    
    if [ -z "$port" ]; then
        jq "(.inbounds[] | select(has(\"users\")).users) |= map(select((.name // \"\") != \"$target_del\" and (.uuid // \"\") != \"$target_uuid\"))" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        sqlite3 $DB_FILE "DELETE FROM users WHERE user_key LIKE '$target_del:%';"
        echo -e "${GREEN} Đã dọn sạch User [$target_del] khỏi TOÀN BỘ Node!${NC}"
    else
        jq "(.inbounds[] | select(.listen_port == $port and has(\"users\")).users) |= map(select((.name // \"\") != \"$target_del\" and (.uuid // \"\") != \"$target_uuid\"))" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        sqlite3 $DB_FILE "DELETE FROM users WHERE port=$port AND user_key LIKE '$target_del:%';"
        echo -e "${GREEN} Đã xóa User khỏi cổng $port!${NC}"
    fi
    set -e 
    systemctl restart sing-box; sleep 3
}

toggle_user_status() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}      TẠM KHÓA / MỞ KHÓA MẠNG NGƯỜI DÙNG ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    read -p " Nhập chính xác Tên User cần xử lý: " target_user </dev/tty
    
    if [ -z "$target_user" ]; then return; fi

    db_check=$(sqlite3 $DB_FILE "SELECT COUNT(*) FROM users WHERE user_key LIKE '$target_user:%';")
    if [ "$db_check" -eq 0 ]; then return; fi

    target_uuid=$(sqlite3 $DB_FILE "SELECT user_key FROM users WHERE user_key LIKE '$target_user:%' AND node_type IN ('tuic', 'vless') LIMIT 1;" | cut -d':' -f2 | tr -d '\r')
    if [ -z "$target_uuid" ]; then target_uuid="NO_UUID_FOUND"; fi

    is_active=$(jq "[.inbounds[] | select(has(\"users\")).users[]? | select((.name // \"\") == \"$target_user\" or (.uuid // \"\") == \"$target_uuid\")] | length" $CONFIG_FILE)

    if [ "$is_active" -gt 0 ]; then
        echo -e "--> Đang tiến hành ${RED}TẠM KHÓA${NC} mạng của [$target_user]..."
        jq "(.inbounds[] | select(has(\"users\")).users) |= map(select((.name // \"\") != \"$target_user\" and (.uuid // \"\") != \"$target_uuid\"))" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        echo -e "${GREEN} Đã cắt mạng User [$target_user]! (Dữ liệu vẫn được bảo lưu)${NC}"
    else
        echo -e "--> Đang tiến hành ${GREEN}MỞ LẠI${NC} mạng cho [$target_user]..."
        sqlite3 $DB_FILE "SELECT node_type, port, user_key FROM users WHERE user_key LIKE '$target_user:%';" | while read -r row; do
            ntype=$(echo "$row" | cut -d'|' -f1)
            port=$(echo "$row" | cut -d'|' -f2)
            ukey=$(echo "$row" | cut -d'|' -f3)
            
            uuid=$(echo "$ukey" | cut -d':' -f2)
            upass=$(echo "$ukey" | cut -d':' -f3)
            
            if [ "$ntype" == "hysteria2" ]; then
                jq "(.inbounds[] | select(.listen_port == $port).users) += [{\"name\": \"$target_user\", \"password\": \"$upass\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            elif [ "$ntype" == "tuic" ]; then
                jq "(.inbounds[] | select(.listen_port == $port).users) += [{\"uuid\": \"$uuid\", \"password\": \"$upass\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            elif [ "$ntype" == "vless" ]; then
                jq "(.inbounds[] | select(.listen_port == $port).users) += [{\"uuid\": \"$uuid\", \"name\": \"$target_user\"}]" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            fi
        done
        echo -e "${GREEN} Đã khôi phục mạng cho User [$target_user]!${NC}"
    fi
    systemctl restart sing-box; sleep 3
}
