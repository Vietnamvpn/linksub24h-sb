#!/bin/bash

# [CẬP NHẬT] Dùng readlink -f để lấy đường dẫn thực, bỏ qua các layer symlink
export APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Thêm kiểm tra an toàn (Giúp bạn debug nhanh nếu cài đặt lỗi)
if [ ! -d "$APP_DIR/modules" ]; then
    echo "Lỗi nghiêm trọng: Không tìm thấy thư mục modules tại $APP_DIR"
    echo "Vui lòng kiểm tra lại cấu trúc thư mục trên VPS."
    exit 1
fi

# Nạp các thư viện và module
source "$APP_DIR/modules/utils.sh"
source "$APP_DIR/modules/system.sh"
source "$APP_DIR/modules/nodes.sh"
source "$APP_DIR/modules/users.sh"

# Bắt lỗi toàn cục
set -e
trap 'catch_error $LINENO' ERR

main_menu() {
    clear
    echo -e "${BLUE}===============================================================================${NC}"
    echo -e "${BLUE}                       MENU QUẢN LÝ SING-BOX PROXY TOOL V3                     ${NC}"
    echo -e "${BLUE}===============================================================================${NC}"
    echo -e " 1. Xem danh sách Node & User  | 10. Xin chứng chỉ SSL Cloudflare"
    echo -e " 2. Xem LOG kết nối trực tiếp  | 11. Bắt đầu Sing-box"
    echo -e " 3. Xem trạng thái VPS         | 12. Dừng Sing-box"
    echo -e "-------------------------------------------------------------------------------"
    echo -e " 4. Thêm Node độc lập mới      | 13. Khởi động lại"
    echo -e " 5. Xóa Node                   | 14. Gỡ cài đặt hệ thống"
    echo -e " 6. Cập nhật Node              | 15. Cập nhật Tool"
    echo -e "-------------------------------------------------------------------------------"
    echo -e " 7. Thêm người dùng            | 16. Khóa & Mở mạng User"
    echo -e " 8. Xóa người dùng             | 17. Cấu hình Webhook"
    echo -e " 9. Tạo bộ nhớ ảo (SWAP)       | 18. Liên kết Web Panel (API)"
    echo -e "  0. Thoát hệ thống            |"
    echo -e "${BLUE}===============================================================================${NC}"
    
    # Lấy trạng thái hiện tại của Sing-box
    if systemctl is-active --quiet sing-box; then
        echo -e "Trạng thái: ${GREEN}Đang chạy${NC}"
    else
        echo -e "Trạng thái: ${RED}Đã dừng${NC}"
    fi
    echo -e "-------------------------------------------------------------------------------"
    
    read -p "Nhập lựa chọn: " m_choice </dev/tty
    
    case $m_choice in
        1) view_and_export_links ;;
        2) journalctl -u sing-box --no-hostname -n 50 -f ;;
        3) view_vps_status ;;
        4) add_single_node_menu ;;
        5) delete_node ;;
        6) update_node_config ;;
        7) add_user_advanced ;;
        8) delete_user_menu ;;
        9) create_swap ;;
        10) issue_cloudflare_cert ;;
        11) systemctl start sing-box; echo -e "${GREEN} Đã BẬT dịch vụ Sing-box!${NC}"; sleep 3 ;;
        12) systemctl stop sing-box; echo -e "${YELLOW} Đã DỪNG dịch vụ Sing-box!${NC}"; sleep 3 ;;
        13) systemctl restart sing-box; echo -e "${GREEN} Đã KHỞI ĐỘNG LẠI dịch vụ Sing-box thành công!${NC}"; sleep 3 ;;
        14) uninstall_system ;;
        15) update_script ;;
        16) toggle_user_status ;;
        17) config_webhook ;;
        18) config_api_web ;;
        0) exit 0 ;;
        *) ;;
    esac
    main_menu
}

# Khởi chạy logic ban đầu
if [ -f "$CONFIG_FILE" ]; then 
    main_menu
else 
    check_and_update_system
fi