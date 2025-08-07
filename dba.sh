#!/bin/bash

# 顏色定義
RED='\033[0;31m'     # 錯誤用紅色
GREEN='\033[0;32m'   # 成功用綠色
YELLOW='\033[1;33m'  # 警告用黃色
CYAN='\033[0;36m'    # 一般提示用青色
RESET='\033[0m'      # 清除顏色

version="3.0.0"

# 檢查是否以root權限運行
if [ "$(id -u)" -ne 0 ]; then
  echo "此腳本需要root權限運行" 
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  else
    echo "無sudo指令"
    exit 1
  fi
fi

# 檢查系統版本
check_system(){
  if command -v apt >/dev/null 2>&1; then
    system=1
  elif command -v yum >/dev/null 2>&1; then
    system=2
  elif command -v apk >/dev/null 2>&1; then
    system=3
  else
    echo -e "${RED}不支援的系統。${RESET}"
    exit 1
  fi
}

#是否有安裝mysql
check_mysql(){
  if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
    get_mysql_command
    db_mode=mysql
  else
    echo -e "${YELLOW}未安裝MariaDB/MySQL，請先安裝！${RESET}"
    exit 1
  fi
}

check_pgsql(){
  if command -v psql >/dev/null 2>&1; then
    db_mode=pgsql
    get_postgres_command
  else
    echo -e "${YELLOW}未安裝PostgreSQL，請先安裝！${RESET}"
    exit 1
  fi
}

# 檢查無安裝內容
check_app(){
  if ! command -v sudo >/dev/null 2>&1; then
    case $system in
    1)
      apt install sudo -y
      ;;
    2)
      yum install sudo -y
      ;;
    3)
      apk add sudo
      ;;
    esac
  fi
  if ! command -v wget  >/dev/null 2>&1; then
    case $system in
    1)
      apt update
      apt install wget -y
      ;;
    2)
      yum update
      yum install -y wget
      ;;
    3)
      apk update
      apk add wget
      ;;
    esac
  fi
}
# 檢查是否安裝PostgreSQL
check_db(){
  pg=false
  mysql=false
  if command -v psql >/dev/null 2>&1; then
    pg=true
  fi
  if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
    mysql=true
  fi
  if [[ $pg = true && $mysql = true ]]; then
    choice_db_menu
  elif [[ $pg = false && $mysql = true ]]; then
    get_mysql_command
    db_mode=mysql
    show_menu
  elif [[ $pg = true && $mysql = false ]]; then
    get_postgres_command
    db_mode=pgsql
    show_menu
  elif [[ $pg = false && $mysql = false ]]; then
    install_menu
  fi
  
}

deploy_db_admin_ui() {
  local db_host="172.17.0.1"
  local mysql_port=3306
  local pgsql_port=5432
  local ui_user="admin"
  local ui_pass="$(openssl rand -base64 12 | tr -dc A-Za-z0-9)"
  local confirm=""
  local port=""
  local pg_user=""
  local pg_pass=""

  # 檢查 docker 是否存在
  if ! command -v docker &>/dev/null; then
    echo -e "${RED}Docker 未安裝，請先安裝 Docker。${RESET}"
    return 1
  fi
  if command -v ufw >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1; then
    echo "跳過開放容器能連結宿主機。"
  elif command -v iptables >/dev/null 2>&1; then
    case $system in
    1)
      if ! command -v netfilter-persistent >/dev/null 2>&1; then
        apt update
        apt install -y iptables-persistent
        systemctl enable netfilter-persistent
      fi
      ;;
    2)
      if ! systemctl list-unit-files | grep iptables > /dev/null 2>&1; then
        yum update -y
        yum install -y iptables-services
        systemctl enable iptables
      fi
      ;;
    3)
      if ! rc-service iptables status > /dev/null 2>&1; then
        apk update
        apk add iptables
        rc-update add iptables
      fi
      ;;
    esac
    if ! iptables -C INPUT -i docker0 -j ACCEPT > /dev/null 2>&1; then
      iptables -I INPUT -i docker0 -j ACCEPT
    fi
    case $system in
    1)
      netfilter-persistent save
      ;;
    2)
      service iptables save
      ;;
    3)
      /etc/init.d/iptables save
      ;;
    esac
    echo -e "${GREEN}已添加可讓docker容器連入宿主機的防火牆規則${RESET}"
    sleep 2
  fi
  while true; do
    read -r -p "請輸入數據庫管理映射端口（留空自動隨機）:" port
    if [[ -z "$port" ]]; then
      local port=$(( ( RANDOM % (65535 - 1025) ) + 1025 ))
      echo -e "${CYAN}自動選擇隨機端口：$port${RESET}"
    fi
    if ss -tuln | awk '{print $5}' | grep -qE ":$port\$"; then
      echo -e  "${YELLOW}端口 $port 已被佔用，請重新輸入！${RESET}"
    else
      break
    fi
  done
  if [ "$db_mode" = "mysql" ]; then
    echo -e "${CYAN}檢查 phpMyAdmin 是否已存在...${RESET}"
    if docker ps -a --format '{{.Names}}' | grep -q "^phpmyadmin$"; then
      echo -e "${YELLOW}phpMyAdmin 容器已存在，跳過建立。${RESET}"
    else
      echo -e "${CYAN}創建 phpMyAdmin...${RESET}"
      if command -v site >/dev/null 2>&1; then
        read -p "是否使用反向代理？（Y/n）" confirm
        confirm=${confirm,,}
        if [[ "$confirm" = "y" || "$confirm" = "" ]]; then
          read -p "請輸入域名：" domain
          if site setup $domain proxy "127.0.0.1" "http" "$port"; then
            docker run -d \
              --restart always \
              --name phpmyadmin \
              -p $port:80 \
              -e PMA_HOST=$db_host \
              -e PMA_PORT=$mysql_port \
              -e PMA_ABSOLUTE_URI=https://$domain \
              phpmyadmin/phpmyadmin
            echo -e "${GREEN}phpMyAdmin 已創建於 https://$domain${RESET}" 
            return 0
          fi
        fi
      fi
      docker run -d \
        --name phpmyadmin \
        -e PMA_HOST="$db_host" \
        -e PMA_PORT="$mysql_port" \
        -p "$port":80 \
        phpmyadmin/phpmyadmin
      echo -e "${GREEN}phpMyAdmin 已啟動於 http://localhost:$port${RESET}"
      read -p "請按任意鍵繼續..." -n1; echo
    fi

  elif [ "$db_mode" = "pgsql" ]; then
    echo -e "${CYAN}檢查 adminer 是否已存在...${RESET}"
    if docker ps -a --format '{{.Names}}' | grep -q "^adminer$"; then
      echo -e "${YELLOW}adminer 容器已存在，跳過建立。${RESET}"
    else
      echo -e "${CYAN}啟動 adminer...${RESET}"
      docker run -d --restart always --name adminer -p $port:8080 adminer
      if command -v site >/dev/null 2>&1; then
        read -p "是否執行反向代理？（Y/n）" confirm
        confirm=${confirm,,}
        if [[ "$confirm" == y || $confirm == "" ]]; then
          read -p "請輸入您的域名：" domain
          if site setup $domain proxy "127.0.0.1" "http" "$port"; then
            echo -e "${GREEN}adminer 已開啟於 http://$domain${RESET}"
            echo "主機名稱:172.17.0.1"
            read -p "請按任意鍵繼續..." -n1; echo
          fi
        fi
      fi
      echo -e "${GREEN} adminer 已開啟於 http://localhost:$port${RESET}"
      echo "主機名稱:172.17.0.1"
      read -p "請按任意鍵繼續..." -n1; echo
    fi
  fi
}


# 全域變數 MYSQL_CMD（陣列）將會被設定為 mysql 指令
MYSQL_CMD=()

get_mysql_command() {
  # 如果 MYSQL_CMD 已經設定，就直接返回
  if [ ${#MYSQL_CMD[@]} -gt 0 ]; then
    return 0
  fi

  local mysql_root_pw=""
  local pass_file="/etc/mysql-pass.conf"

  # 嘗試無密碼登入
  if mysql -u root -e "SELECT 1;" &>/dev/null; then
    MYSQL_CMD=("mysql" "-u" "root")
    return 0
  fi

  # 嘗試讀取 /etc/mysql-pass.conf
  if [ -f "$pass_file" ]; then
    mysql_root_pw=$(< "$pass_file")
    if mysql -u root -p"$mysql_root_pw" -e "SELECT 1;" &>/dev/null; then
      MYSQL_CMD=("mysql" "-u" "root" "-p$mysql_root_pw")
      return 0
    fi
  fi

  # 不存在 conf 或無效，請使用者輸入
  while true; do
    read -s -p "請輸入 MySQL root 密碼：" mysql_root_pw
    echo
    if [ -z "$mysql_root_pw" ]; then
      echo -e "${YELLOW}密碼不能為空，請再試一次。${RESET}"
      continue
    fi

    if mysql -u root -p"$mysql_root_pw" -e "SELECT 1;" &>/dev/null; then
      echo -e "${GREEN}密碼正確，已成功登入 MySQL${RESET}" 
      echo "$mysql_root_pw" > "$pass_file"
      chmod 600 "$pass_file"
      echo -e "${GREEN}已將 root 密碼寫入 $pass_file (權限 600)${RESET}"
      MYSQL_CMD=("mysql" "-u" "root" "-p$mysql_root_pw")
      return 0
    else
      echo -e "${RED}密碼錯誤，請再試一次。${RESET}"
    fi
  done
}


# 全域變數 PSQL_CMD 和 PGDUMP_CMD
PSQL_CMD=()
PGDUMP_CMD=()

get_postgres_command() {
  if id "postgres" &>/dev/null; then
    # 加上 -i 參數，模擬 postgres 使用者登入，
    # 這會將工作目錄切換到 postgres 的家目錄，從而避免在 /root 目錄下執行導致的權限警告。
    PSQL_CMD=("sudo" "-iu" "postgres" "psql" "-q" "-t" "-A")
    PSQL_EXEC_CMD=("sudo" "-iu" "postgres" "psql" "-c")
    PGDUMP_CMD=("sudo" "-iu" "postgres" "pg_dump")
    return 0
  else
    echo -e "${RED}找不到 postgres 系統使用者，請確認 PostgreSQL 是否已正確安裝並初始化。${RESET}"
    exit 1
  fi
}

enable_postgres_user_external_access() {
  local username=$1
  
  echo -e "${CYAN}正在設定 listen_addresses = '*'...${RESET}" >&2

  local conf_file=$(sudo -iu postgres psql -tAc "SHOW config_file;")
  local hba_file=$(sudo -iu postgres psql -tAc "SHOW hba_file;")

  if [ ! -f "$conf_file" ] || [ ! -f "$hba_file" ]; then
    echo -e "${RED}找不到 PostgreSQL 設定檔，無法繼續。${RESET}"
    return 1
  fi

  # 處理 listen_addresses 設定（略過註解行，並更新不為 '*' 的有效設定）
  # 強制設為 listen_addresses = '*'
  if grep -P "^\s*listen_addresses\s*=\s*'\*'" "$conf_file" >/dev/null; then
    echo -e "${GREEN}listen_addresses 已正確設定為 '*'。${RESET}" >&2
  else
    echo -e "${YELLOW}正在強制設為 listen_addresses = '*'...${RESET}" >&2

    # 若已有 listen_addresses 設定（不論是否註解），統一替換為有效設定
    if grep -P "^\s*#?\s*listen_addresses\s*=" "$conf_file" >/dev/null; then
      sed -i -E "s|^\s*#?\s*listen_addresses\s*=.*|listen_addresses = '*'|" "$conf_file"
    else
    # 若完全沒有該設定，則直接加在檔案結尾
      echo "listen_addresses = '*'" >> "$conf_file"
    fi

    echo -e "${CYAN}已更新 listen_addresses 為 '*'，重新啟動 PostgreSQL...${RESET}" >&2
    service postgresql restart
  fi

  # 加入 pg_hba.conf 條目
  if grep -E "host\s+all\s+$username\s+0\.0\.0\.0/0\s+md5" "$hba_file" >/dev/null; then
    echo -e "${YELLOW}該用戶 '$username' 已允許外部訪問，無需重複添加。${RESET}" >&2
  else
    echo "host all $username 0.0.0.0/0 md5" >> "$hba_file"
    echo -e "${GREEN}已加入 '$username' 的外部訪問條目至 pg_hba.conf。${RESET}" >&2
  fi

  echo -e "${GREEN}已成功開放 '$username' 從外部網路登入 PostgreSQL。${RESET}" >&2
  access_mode=外網
}

revoke_user_external_access() {
  local username="$1"
  if [[ -z "$username" ]]; then
    echo "請提供使用者名稱！"
    return 1
  fi

  echo "檢查是否存在外網訪問規則：$username"

  # 取得 pg_hba.conf 路徑
  local hba_file=$(sudo -iu postgres psql -tAc "SHOW hba_file;")

  if [[ ! -f "$hba_file" ]]; then
    echo -e "找不到 pg_hba.conf 檔案：$hba_file"
    return 1
  fi

  # 備份 pg_hba.conf
  cp "$hba_file" "${hba_file}.bak"

  # 檢查是否有針對此用戶的 0.0.0.0/0 或 ::/0 host 規則
  if grep -qE "^[[:space:]]*host[[:space:]]+all[[:space:]]+$username[[:space:]]+(0\.0\.0\.0/0|::/0)" "$hba_file"; then
    echo -e "${CYAN}發現規則，正在移除...${RESET}"
    # 移除該條目
    sed -i "/^[[:space:]]*host[[:space:]]\+all[[:space:]]\+$username[[:space:]]\+\(0\.0\.0\.0\/0\|::\/0\)/d" "$hba_file"
        
    echo -e "${GREEN}已移除用戶 $username 的外網訪問規則${RESET}"
    service postgresql restart
  fi
}


sanitize_name() {
  local input="$1"
  # 允許小寫字母、數字、底線，並以字母開頭
  local clean=$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]//g')
  echo "$clean"
}

# 建立資料庫
create_database() {
  local raw_dbname="${1:-}"
  local username="${2:-}"
  local password="${3:-}"
  local allow_remote="$4"
  local cli_mode="$5"
  local dbname=""
  local host="localhost"
  local add_user=""

  # 要求輸入資料庫名稱
  if [ -z "$raw_dbname" ]; then
    read -p "請輸入資料庫名稱：" raw_dbname
  fi
  dbname=$(sanitize_name "$raw_dbname")

  # CLI 模式下預設創建用戶
  if [ "$cli_mode" = "false" ]; then
    read -p "是否創建用戶？（Y/n）" add_user
    add_user=${add_user,,}
  else
    add_user="y"
  fi

  if [[ "$add_user" == "y" ]]; then
    if [ -z "$username" ]; then
      read -p "請輸入用戶名稱（建議與資料庫同名）：" username
    fi
  fi

  # 外網設定
  if [ "$db_mode" == "mysql" ]; then
    if [ -z "$allow_remote" ]; then
      read -p "此用戶是否需要外網訪問？(y/n)：" allow_remote
    fi
    [[ "$allow_remote" =~ ^[Yy]$ ]] && host="%" || host="localhost"
  elif [ "$db_mode" == "pgsql" ]; then
    if [ -z "$allow_remote" ]; then
      read -p "此用戶是否需要外網訪問？(y/n)：" allow_remote
    fi
    allow_remote=${allow_remote,,}
    if [[ "$allow_remote" == "y" ]]; then
      enable_postgres_user_external_access "$username"
      host="外網"
    fi
  fi

  # 密碼設定
  if [ -z "$password" ]; then
    while true; do
      read -s -p "請輸入用戶密碼（空白將自動生成密碼）：" password
      echo
      if [ -z "$password" ]; then
        password=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')
        break
      else
        read -s -p "請再次輸入用戶密碼：" password2
        echo
        if [ "$password" != "$password2" ]; then
          echo -e "${RED}密碼不一致，請重新輸入。${RESET}" >&2
        else
          break
        fi
      fi
    done
  fi

  # 建立資料庫
  if [ "$db_mode" == "mysql" ]; then
    "${MYSQL_CMD[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$dbname\`;" >&2
    if [[ "$add_user" == "y" ]]; then
      "${MYSQL_CMD[@]}" -e "CREATE USER IF NOT EXISTS '$username'@'$host' IDENTIFIED BY '$password';" >&2
      "${MYSQL_CMD[@]}" -e "GRANT ALL PRIVILEGES ON \`$dbname\`.* TO '$username'@'$host';" >&2
      "${MYSQL_CMD[@]}" -e "FLUSH PRIVILEGES;" >&2
    fi
  elif [ "$db_mode" == "pgsql" ]; then
    "${PSQL_EXEC_CMD[@]}" "CREATE DATABASE \"$dbname\";" >&2
    if [[ "$add_user" == "y" ]]; then
      "${PSQL_EXEC_CMD[@]}" "CREATE USER \"$username\" WITH PASSWORD '$password';" >&2
      "${PSQL_EXEC_CMD[@]}" "GRANT ALL PRIVILEGES ON DATABASE \"$dbname\" TO \"$username\";" >&2
      "${PSQL_EXEC_CMD[@]}" "REVOKE ALL ON DATABASE \"$dbname\" FROM PUBLIC;" >&2
      "${PSQL_EXEC_CMD[@]}" "REVOKE ALL ON SCHEMA public FROM PUBLIC;" >&2
      "${PSQL_EXEC_CMD[@]}" "GRANT ALL ON SCHEMA public TO \"$username\";" >&2
    fi
    (service postgresql restart 2>/dev/null || service postgresql-17 restart 2>/dev/null)
  fi

  # CLI模式不顯示
  if [ "$cli_mode" == "true" ]; then return 0; fi

  echo -e "${GREEN}資料庫與使用者設定完成${RESET}"
  echo "資料庫名稱：$dbname"
  echo "用戶名稱：$username"
  echo "用戶密碼：$password"
  echo "主機地址：$host"
  
}


# 刪除資料庫，並可選擇是否一併刪除其關聯的所有用戶
remove_database() {
  local dbs_to_delete="${1:-}"
  local cli_mode="${2:-}"
  local skip="$3"
  if [ $db_mode = mysql ]; then
    if [ -z $dbs_to_delete ]; then
      read -p "請輸入要刪除的資料庫名稱：" dbs_to_delete
    fi
    if [ $skip == y ]; then
      choice=y
    else
      choice=n
    fi
    if ! "${MYSQL_CMD[@]}" -e "SHOW DATABASES LIKE '$dbs_to_delete';" | grep -q "$dbs_to_delete" >&2; then
      echo -e "${RED}資料庫 $dbs_to_delete 不存在！${RESET}" >&2
      return 1
    fi
    if [ -z $choice ]; then
    read -p "是否刪除此資料庫的用戶? (y/n) " choice
    fi
    if [ "$choice" = "y" ]; then
      echo -e "${CYAN}正在尋找與 $dbs_to_delete 資料庫相關的用戶...${RESET}" >&2
      local users=$("${MYSQL_CMD[@]}" -N -e "SELECT user, host FROM mysql.db WHERE db = '$dbs_to_delete';")
      if [ -z "$users" ]; then
        echo -e "${YELLOW}找不到任何與 $dbname 資料庫相關的用戶。${RESET}" >&2
        sleep 2
        return 1
      else
        echo "$users" | while read user host; do
          echo -e "${CYAN}正在刪除用戶 '$user'@'$host'...${RESET}" >&2
          "${MYSQL_CMD[@]}" -e "DROP USER IF EXISTS '$user'@'$host';" >&2
        done
      fi
    else
      echo -e "${CYAN}跳過刪除用戶。${RESET}"  >&2
    fi
    echo -e "${CYAN}正在刪除資料庫 $dbname...${RESET}" >&2
    "${MYSQL_CMD[@]}" -e "DROP DATABASE IF EXISTS \`$dbname\`;"
    echo -e "${GREEN}資料庫 $dbname 已刪除。${RESET}" >&2
    return 0
  fi
  get_postgres_command
  if [ $cli_mode = false ]; then
    local dbs_to_delete=$("${PSQL_CMD[@]}" -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres';")

    if [ -z "$dbs_to_delete" ]; then
      echo -e "${YELLOW}目前沒有可供刪除的自訂資料庫。${RESET}" >&2
      sleep 2
      return
    fi

    echo -e "${CYAN}可刪除的資料庫列表：${RESET}"
    local db_array=($dbs_to_delete)
    for i in "${!db_array[@]}"; do
      printf "%3d) %s\n" "$((i+1))" "${db_array[$i]}"
    done
    echo

    read -p "請輸入要刪除的資料庫編號 (可輸入多個，以空格分隔): " choice
    if [ -z "$choice" ]; then
      echo -e "${YELLOW}未輸入任何選項，操作取消。${RESET}"
      return
    fi

    for i in $choice; do
      if ! [[ "$i" =~ ^[0-9]+$ ]] || [ "$i" -lt 1 ] || [ "$i" -gt "${#db_array[@]}" ]; then
        echo -e "${RED}輸入的編號 '$i' 是無效的，已跳過。${RESET}"
        continue
      fi

      local db_to_delete="${db_array[$((i-1))]}"
      echo -e "\n${YELLOW}--- 準備刪除資料庫: $db_to_delete ---${RESET}" >&2

      # 步驟 1: 在刪除資料庫前，先找出所有關聯的用戶 (擁有者 + 可存取者)
      local user_query="
        SELECT rolname FROM pg_roles WHERE rolname IN (
          SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db_to_delete'
          UNION
          SELECT u.rolname FROM pg_roles u WHERE has_database_privilege(u.rolname, '$db_to_delete', 'CONNECT')
        )
        AND rolname != 'postgres' AND rolname NOT LIKE 'pg_%';
      "
      mapfile -t associated_users < <("${PSQL_CMD[@]}" -t -A -c "$user_query")

      # 執行刪除資料庫
      if "${PSQL_EXEC_CMD[@]}" "DROP DATABASE \"$db_to_delete\";"; then
        echo -e "${GREEN}資料庫 '$db_to_delete' 已成功刪除。${RESET}" >&2

        # 如果有關聯用戶，逐一詢問是否刪除
        if [ -n "$associated_users" ]; then
          echo -e "${CYAN}接下來，將處理與該資料庫關聯的用戶...${RESET}" >&2
          for user in "${associated_users[@]}"; do
            if [ -z "$confirm_user" ]; then
              read -p "是否要一併刪除關聯用戶 '$user'？ (y/n) " confirm_user
            fi
            if [[ "$confirm_user" =~ ^[Yy]$ ]]; then
              revoke_user_external_access "$user"
              "${PSQL_EXEC_CMD[@]}" "REASSIGN OWNED BY \"$user\" TO postgres; DROP OWNED BY \"$user\";" >/dev/null
              if "${PSQL_EXEC_CMD[@]}" "DROP ROLE \"$user\";"; then
                echo -e "${GREEN}使用者 '$user' 已成功刪除。${RESET}" >&2
              else
                echo -e "${RED}刪除使用者 '$user' 失敗！可能是因為該使用者還擁有其他資源。${RESET}" >&2
              fi
            else
              echo -e "${YELLOW}已保留使用者 '$user'。${RESET}" >&2
            fi
          done
        fi
      else
        echo -e "${RED}刪除資料庫 '$db_to_delete' 失敗！${RESET}" >&2
      fi
    done
  fi
}



# 建立使用者
add_user() {
  local raw_username=""
  local username=""
  local password=""
  local password2=""
  access_mode=localhost
  local host=""
  local host_desc=""

  read -p "請輸入用戶名稱：" raw_username
  username=$(sanitize_name "$raw_username")

  if [[ -z "$username" ]]; then
    echo -e "${RED}用戶名稱不可為空或含非法字元！${RESET}"
    return 1
  fi
  while true; do
    read -s -p "請輸入用戶密碼（留空則自動生成）：" password
    echo

    if [ -z "$password" ]; then
      password=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')
      echo -e "${YELLOW}已自動生成密碼：$password${RESET}"
      break
    else
      read -s -p "請再次輸入用戶密碼：" password2
      echo
      if [ "$password" != "$password2" ]; then
        echo -e "${RED}密碼不一致，請重新輸入。${RESET}"
      else
        break
      fi
    fi
  done
  if [ $db_mode = mysql ]; then
    read -p "是否允許外網訪問此用戶？(y/n) " remote

    if [[ "$remote" =~ ^[Yy]$ ]]; then
      host='%'
      host_desc="外網"
    else
      host='localhost'
      host_desc="本地"
    fi

    "${MYSQL_CMD[@]}" -e "CREATE USER IF NOT EXISTS '$username'@'$host' IDENTIFIED BY '$password';"
    "${MYSQL_CMD[@]}" -e "FLUSH PRIVILEGES;"

    echo -e "${GREEN}用戶已建立${RESET}"
    echo "用戶名稱：$username"
    echo "用戶密碼：$password"
    echo "主機地址：$host_desc"
    echo
    echo -e "${YELLOW}請記下用戶名稱、用戶密碼，以便後續使用。${RESET}"
    return
  fi
  if "${PSQL_CMD[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$username'" |   grep -q 1; then
    echo -e "${RED}使用者 $username 已存在！${RESET}"
    return 1
  fi
  

  "${PSQL_EXEC_CMD[@]}" "CREATE USER \"$username\" WITH PASSWORD '$password';"
  read -p "是否開放此用戶外網訪問？（Y/n）？" confirm
  confirm=${confirm,,}
  if [[ $confirm == y || $confirm == "" ]]; then
    enable_postgres_user_external_access $username
  fi
  echo -e "${GREEN}用戶已建立${RESET}"
  echo "用戶名稱：$username"
  echo "用戶密碼：$password"
  echo "類型：$access_mode"
  echo
  echo -e "${YELLOW}請記下用戶名稱、用戶密碼，以便後續使用。${RESET}"
}


#刪除使用者
remove_user() {
  read -p "請輸入要刪除的用戶名稱：" username
  if [ "$username" == "root" ]; then
    echo -e "${RED}禁止刪除 root 超級使用者！${RESET}"
    return 1
  fi
  
  if [ $db_mode = mysql ]; then
    local user_hosts=$("${MYSQL_CMD[@]}" -N -e "
      SELECT host FROM mysql.user WHERE user='$username';
    ")

    if [ -z "$user_hosts" ]; then
      echo -e "${RED}用戶 $username 不存在！${RESET}"
      return 1
    fi

    echo -e "${CYAN}正在撤銷用戶 '$username' 的所有權限...${RESET}"

    echo "$user_hosts" | while read host; do
      # revoke
      "${MYSQL_CMD[@]}" -e "REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$username'@'$host';" 2>/dev/null

      # drop user
      "${MYSQL_CMD[@]}" -e "DROP USER   IF EXISTS '$username'@'$host';"
          echo -e "${GREEN}已刪除用戶   $username@$host${RESET}"
    done
    return 0
  fi

  if ! "${PSQL_CMD[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
    echo -e "${RED}用戶 $username 不存在！${RESET}"
    return 1
  fi
  
  if [ "$username" == "postgres" ]; then
    echo -e "${RED}禁止刪除 postgres 超級使用者！${RESET}"
    return 1
  fi

  echo -e "${CYAN}正在轉移用戶 '$username' 的資產...${RESET}"
  "${PSQL_EXEC_CMD[@]}" "REASSIGN OWNED BY \"$username\" TO postgres; REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"$username\";"
  
  
  echo -e "${CYAN}正在刪除用戶 '$username'...${RESET}"
  "${PSQL_EXEC_CMD[@]}" "REASSIGN OWNED BY \"$username\" TO postgres; DROP OWNED BY \"$username\";" >/dev/null
  "${PSQL_EXEC_CMD[@]}" "DROP USER IF EXISTS \"$username\";"
  revoke_user_external_access $username
  echo -e "${GREEN}已刪除用戶 $username ${RESET}"
}

#建立超級帳號
create_super_user() {
  username=${1:-}
  password=${2:-}
  cli_mode=${3:-false}
  nat_access=y  # 預設開啟外網

  if [ -z "$username" ]; then
    read -p "請輸入用戶名：" username
  fi
  if [ -z "$password" ]; then 
    read -p "請輸入密碼：（空白將隨機生成密碼）" password
    password=${password:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9')}
  fi
  if [ "$cli_mode" = false ]; then
    echo -e "${YELLOW}您好，此超級帳號是要給外網進行訪問的，可以使用外網的 windows GUI或者docker容器的圖形化網頁訪問資料庫。${RESET}"
    read -p "是否繼續？（Y/n）" confirm
    confirm=${confirm,,}
    if [[ "$confirm" = "n" || "$confirm" = "" ]]; then
      echo "取消創建。"
      sleep 1
      return
    fi
  fi

  if [ "$db_mode" = "mysql" ]; then
    # 建立 MySQL/MariaDB 超級帳號
    "${MYSQL_CMD[@]}" -e "CREATE USER IF NOT EXISTS '$username'@'%' IDENTIFIED BY '$password';" 2>/dev/null
    "${MYSQL_CMD[@]}" -e "GRANT ALL PRIVILEGES ON *.* TO '$username'@'%' WITH GRANT OPTION;" 2>/dev/null
    "${MYSQL_CMD[@]}" -e "FLUSH PRIVILEGES;" 2>/dev/null
    echo "$password"

    # 偵測可寫入的 bind-address 設定檔路徑
    detect_mysql_config() {
      local candidates=(
        "/etc/mysql/my.cnf"
        "/etc/my.cnf"
        "/etc/mysql/mysql.conf.d/mysqld.cnf"
        "/etc/mysql/mariadb.conf.d/50-server.cnf"
        "/etc/my.cnf.d/server.cnf"
      )
      for f in "${candidates[@]}"; do
        if [ -f "$f" ] && grep -q "\[mysqld\]" "$f"; then
          echo "$f"
          return
        fi
      done
    }

    MY_CNF=$(detect_mysql_config)

    if [ -n "$MY_CNF" ]; then
      # 若未設或不是 0.0.0.0 則寫入 bind-address
      if ! grep -qE '^\s*bind-address\s*=\s*0\.0\.0\.0' "$MY_CNF"; then
        if grep -q '^\s*bind-address\s*=' "$MY_CNF"; then
          sed -i 's/^\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$MY_CNF"
        else
          sed -i '/^\[mysqld\]/a bind-address = 0.0.0.0' "$MY_CNF"
        fi
      fi
      # 重啟服務
      service mysql restart 2>/dev/null || service mariadb restart 2>/dev/null
    fi

  elif [ "$db_mode" = "pgsql" ]; then
    local PG_HBA=$(sudo -iu postgres psql -tAc "SHOW hba_file;")
    local PG_CONF=$(sudo -iu postgres psql -tAc "SHOW config_file;")

    # 建立 PostgreSQL 超級帳號
    "${PSQL_EXEC_CMD[@]}" "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1 || \
    "${PSQL_EXEC_CMD[@]}" "CREATE ROLE $username WITH LOGIN SUPERUSER PASSWORD '$password';"

    if [[ "$nat_access" == "y" ]]; then
      # 啟用 listen_addresses
      sed -i "s/^#*\s*listen_addresses.*/listen_addresses = '*'/" "$PG_CONF" 2>/dev/null

      # 加入 pg_hba.conf 允許此使用者從外部登入
      if ! grep -q "^host *all *$username *0.0.0.0/0 *md5" "$PG_HBA"; then
        echo "host all $username 0.0.0.0/0 md5" >> "$PG_HBA"
      fi
      if ! grep -q "^host *all *$username *::/0 *md5" "$PG_HBA"; then
        echo "host all $username ::/0 md5" >> "$PG_HBA"
      fi

      (service postgresql restart 2>/dev/null || service postgresql-17 restart 2>/dev/null)
    fi

    if [ "$cli_mode" = true ]; then
      return
    fi

    echo "======帳號信息======"
    echo "用戶名：$username"
    echo "密碼：$password"
    read -p "操作完成，請按任意鍵繼續" -n1
  fi
}

# 重製密碼
reset_user_password() {
  local raw_user=""
  local user=""
  local new_pass=""
  local hosts=""
  local host_count=""
  
  if [ $db_mode = mysql ]; then
    echo "===== MySQL 帳號密碼重置工具 ====="
    read -p "請輸入欲重置密碼的 MySQL 帳號：" raw_user
    user=$(sanitize_name "$raw_user")

    if [[ -z "$user" ]]; then
      echo -e "${RED}用戶名稱不可為空或含非法字元！${RESET}"
      return 1
    fi

    if [[ "$user" == "root" ]]; then
      echo -e "${RED}禁止重置 root 帳號的密碼！操作已終止。${RESET}"
      return 1
    fi

    host_count=$("${MYSQL_CMD[@]}" -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE user='$user';")
    if [[ "$host_count" -eq 0 ]]; then
      echo -e "${RED}使用者 $user 不存在！操作已終止。${RESET}"
      return 1
    fi

    hosts=$("${MYSQL_CMD[@]}" -N -B -e "SELECT host FROM mysql.user WHERE user='$user';")

    echo -e "${GREEN}找到使用者 $user 存在於以下 host：${RESET}"
    echo "$hosts"
  elif [ $db_mode = pgsql ]; then
  
    echo "===== PostgreSQL 帳號密碼重置工具 ====="

    read -p "請輸入欲重置密碼的 PostgreSQL 帳號：" raw_user
    user=$(sanitize_name "$raw_user")

    if [[ -z "$user" ]]; then
      echo -e "${RED}用戶名稱不可為空或含非法字元！${RESET}"
      return 1
    fi
  
    if [[ "$user" == "postgres" ]]; then
      echo -e "${RED}不建議直接修改 postgres 帳號的密碼，操作已終止。${RESET}"
      return 1
    fi
  
    if ! "${PSQL_CMD[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$user'" | grep -q 1; then
      echo -e "${RED}使用者 $user 不存在！操作已終止。${RESET}"
      return 1
    fi
  fi

  while true; do
    read -s -p "請輸入新密碼（留空將自動生成）：" new_pass
      echo

    if [[ -z "$new_pass" ]]; then
      new_pass=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')
      break
    else
      local new_pass2=""
      read -s -p "請再次輸入新密碼：" new_pass2
      echo
      if [[ "$new_pass" != "$new_pass2" ]]; then
        echo -e "${RED}密碼不一致，請重新輸入。${RESET}"
      else
        break
      fi
    fi
  done
  case $db_mode in
  mysql)
    for h in $hosts; do
      "${MYSQL_CMD[@]}" -e "ALTER USER '$user'@'$h' IDENTIFIED BY '$new_pass'; FLUSH PRIVILEGES;"
      if [[ $? -eq 0 ]]; then
      echo -e "${GREEN}[$user@$h] 密碼已成功更新！${RESET}"
      else
        echo -e "${RED}[$user@$h] 密碼更新失敗！${RESET}"
      fi
    done
    ;;
  pgsql)
    "${PSQL_EXEC_CMD[@]}" "ALTER USER \"$user\" WITH PASSWORD '$new_pass';"
    if [[ $? -eq 0 ]]; then
      echo -e "${GREEN}[$user] 密碼已成功更新！${RESET}"
    else
      echo -e "${RED}[$user] 密碼更新失敗！${RESET}"
    fi
    ;;
  esac
  
  echo
  echo -e "${YELLOW}請記下新密碼：${RESET}"
  echo "用戶名稱：$user"
  echo "新密碼：$new_pass"
}

# 授權用戶
grant_user() {
  echo -e "${CYAN}正在讀取用戶與資料庫列表...${RESET}"

  if [ "$db_mode" == "pgsql" ]; then
    # PostgreSQL
    mapfile -t user_list < <("${PSQL_CMD[@]}" -tAc "SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolname NOT IN ('postgres');")

    if [ "${#user_list[@]}" -eq 0 ]; then
      echo -e "${RED}找不到可用的登入用戶！${RESET}"
      return 1
    fi

    echo "請選擇要授權的用戶："  
    select username in "${user_list[@]}"; do
      if [ -n "$username" ]; then
        break
      else
        echo -e "${YELLOW}請輸入有效的編號。${RESET}"
      fi
    done

    # 取得資料庫清單（排除模板與系統資料庫）
    mapfile -t db_list < <("${PSQL_CMD[@]}" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")

    if [ "${#db_list[@]}" -eq 0 ]; then
      echo -e "${RED}找不到可用的資料庫！${RESET}"
      return 1
    fi

    echo "請選擇要授權的資料庫："  
    select dbname in "${db_list[@]}"; do
      if [ -n "$dbname" ]; then
        break
      else
        echo -e "${YELLOW}請輸入有效的編號。${RESET}"
      fi
    done

    echo
    if "${PSQL_EXEC_CMD[@]}" "GRANT ALL PRIVILEGES ON DATABASE \"$dbname\" TO \"$username\";"; then
      echo -e "${GREEN}已成功授予 '$username' 對資料庫 '$dbname' 的所有權限。${RESET}"
    else
      echo -e "${RED}授權失敗，請檢查是否有權限或資料庫狀態異常。${RESET}"
    fi

  elif [ "$db_mode" == "mysql" ]; then
    # MySQL
    # 取得用戶清單（排除系統用戶）
    mapfile -t user_list < <("${MYSQL_CMD[@]}" -e "SELECT User FROM mysql.user WHERE Host = 'localhost';")

    if [ "${#user_list[@]}" -eq 0 ]; then
      echo -e "${RED}找不到可用的登入用戶！${RESET}"
      return 1
    fi

    echo "請選擇要授權的用戶："  
    select username in "${user_list[@]}"; do
      if [ -n "$username" ]; then
        break
      else
        echo -e "${YELLOW}請輸入有效的編號。${RESET}"
      fi
    done

    # 取得資料庫清單
    mapfile -t db_list < <("${MYSQL_CMD[@]}" -e "SHOW DATABASES;")

    if [ "${#db_list[@]}" -eq 0 ]; then
      echo -e "${RED}找不到可用的資料庫！${RESET}"
      return 1
    fi

    echo "請選擇要授權的資料庫："  
    select dbname in "${db_list[@]}"; do
      if [ -n "$dbname" ]; then
        break
      else
        echo -e "${YELLOW}請輸入有效的編號。${RESET}"
      fi
    done

    echo
    if "${MYSQL_CMD[@]}" -e "GRANT ALL PRIVILEGES ON $dbname.* TO '$username'@'localhost';"; then
      echo -e "${GREEN}已成功授予 '$username' 對資料庫 '$dbname' 的所有權限。${RESET}"
    else
      echo -e "${RED}授權失敗，請檢查是否有權限或資料庫狀態異常。${RESET}"
    fi
  fi
}

export_database() {
  local dbname="${1:-}"
  case $db_mode in
  mysql)
    local backup_dir="/root/mysql_backups"
    ;;
  pgsql)
    local backup_dir="/root/postgres_backups"
    ;;
  esac
  mkdir -p "$backup_dir"
  
  if [ -z "$dbname" ]; then
    read -p "請輸入要匯出的資料庫名稱：" dbname
  fi
  local timestamp=$(date +%Y-%m-%d_%H%M%S)
  local backup_file="${backup_dir}/${dbname}_${timestamp}.sql"
  
  if [ $db_mode = mysql ]; then
    if ! "${MYSQL_CMD[@]}" -e "SHOW DATABASES LIKE '$dbname';" | grep -q "$dbname"; then
      echo -e "${RED}資料庫 $dbname 不存在！${RESET}" >&2
      return 1
    fi
    
    # 組合 mysqldump 指令
    local MYSQLDUMP_CMD=("mysqldump" "${MYSQL_CMD[@]:1}")

    echo -e "${CYAN}正在匯出資料庫 '$dbname' 到 $backup_file ...${RESET}" >&2
    
    "${MYSQLDUMP_CMD[@]}" "$dbname" > "$backup_file"
  elif [ $db_mode = pgsql ]; then
    if ! "${PSQL_CMD[@]}" -l | cut -d \| -f 1 | grep -qw "$dbname"; then
        echo -e "${RED}資料庫 $dbname 不存在！${RESET}"
        return 1
    fi
    echo -e "${CYAN}正在匯出資料庫 '$dbname' 到 $backup_file ...${RESET}" >&2
    if "${PGDUMP_CMD[@]}" "$dbname" > "$backup_file"; then
      echo -e "${GREEN}資料庫 '$dbname' 已成功匯出至：${RESET}" >&2
      echo "$backup_file"
    else
      echo -e "${RED}資料庫 '$dbname' 匯出失敗！${RESET}" >&2
      rm -f "$backup_file"
    fi
  fi
}

# 匯入資料庫
import_database() {
  case $db_mode in
  mysql)
    local backup_dir="/root/mysql_backups"
    ;;
  pgsql)
    local backup_dir="/root/postgres_backups"
    ;;
  esac
  if [ ! -d "$backup_dir" ] || [ -z "$(ls -A ${backup_dir}/*.sql 2>/dev/null)" ]; then
    echo -e "${YELLOW}找不到任何備份檔案於 ${backup_dir} 目錄中。${RESET}"
    sleep 2
    return 1
  fi
  echo -e "${CYAN}可用的備份檔案：${RESET}"

  # 使用 while read 迴圈取代 mapfile，以獲得更好的相容性
  local backup_files=()
  while IFS= read -r line; do
    backup_files+=("$line")
  done < <(find "$backup_dir" -maxdepth 1 -name "*.sql" | sort)

  for i in "${!backup_files[@]}"; do
    printf "%3d) %s\n" "$((i+1))" "$(basename "${backup_files[$i]}")"
  done
  echo

  local choice
  read -p "請選擇要匯入的備份檔案編號：" choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
    echo -e "${RED}無效的選擇！${RESET}"
    return 1
  fi

  local selected_file="${backup_files[$((choice-1))]}"
  local auto_dbname=$(basename "$selected_file" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.sql$//')

  read -p "請輸入要匯入的目標資料庫名稱 [留空預設為: ${auto_dbname}]: " target_dbname
  target_dbname=${target_dbname:-$auto_dbname}

  echo -e "${CYAN}準備將 '${selected_file}' 匯入到資料庫 '${target_dbname}'...${RESET}"
  read -p "這個操作可能會覆蓋現有資料，確定要繼續嗎？ (y/n) " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}操作已取消。${RESET}"
    return 1
  fi
  
  if [ $db_mode = mysql ]; then
    "${MYSQL_CMD[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$target_dbname\`;"
    echo -e "${CYAN}正在匯入...${RESET}"
    
    if "${MYSQL_CMD[@]}" "$target_dbname" < "$selected_file"; then
      echo -e "${GREEN}資料庫 '$target_dbname' 已成功從 '$selected_file' 匯入。${RESET}"
    else
      echo -e "${RED}資料庫匯入失敗！${RESET}"
      return 1
    fi
    return 0
  fi

  # 確保目標資料庫存在
  if ! sudo -iu postgres psql -lqt | cut -d \| -f 1 | grep -qw "$target_dbname"; then
    sudo -iu postgres psql -c "CREATE DATABASE \"$target_dbname\";"
  fi

  echo -e "${CYAN}正在匯入...${RESET}"

  if sudo -iu postgres psql -d "$target_dbname" < "$selected_file"; then
    echo -e "${GREEN}資料庫 '$target_dbname' 已成功從 '$selected_file' 匯入。${RESET}"
  else
    echo -e "${RED}資料庫匯入失敗！${RESET}"
  fi
}


# 解除安裝資料庫
uninstall_database(){
  local type=$1
  read -p "警告：這將會移除此資料庫及其所有資料，確定要繼續嗎？ (y/n) " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}操作已取消。${RESET}"
    return
  fi
  case $type in
  mysql)
    if [ $system -eq 1 ]; then
      apt-get purge -y mariadb-server mariadb-common
      apt-get autoremove -y
    elif [ $system -eq 2 ]; then
      yum remove -y mariadb-server
      yum autoremove -y
    elif [ $system -eq 3 ]; then
      apk del mariadb
    fi
    rm -rf /etc/mysql /var/lib/mysql /etc/mysql-pass.conf /root/mysql_backups
    echo -e "${GREEN}MySQL已成功解除安裝並清除所有相關文件。${RESET}"
    exit 0
    ;;
  pgsql)
    echo -e "${CYAN}正在停止 PostgreSQL 服務...${RESET}"
    (service postgresql stop 2>/dev/null || service postgresql-17 stop 2>/dev/null)
    if [ $system -eq 1 ]; then
      apt-get purge -y 'postgresql-*'
      apt-get autoremove -y
    elif [ $system -eq 2 ]; then
      yum remove -y 'postgresql*'
      yum autoremove -y
    elif [ $system -eq 3 ]; then
      apk del $(apk info | grep '^postgresql')
    fi

    # 删除 PostgreSQL 配置文件和数据目录
    rm -rf /etc/postgresql /var/lib/postgresql /root/postgres_backups

    echo -e "${GREEN}PostgreSQL 已成功解除安裝並清除所有相關文件。${RESET}"
    exit 0
    ;;
  esac
}

install_database(){
  local type=$1
  case $type in
  mysql)
    if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
      echo -e "${GREEN}已安裝MariaDB/MySQL。${RESET}"
      exec dbx mysql
    else
      echo -e "${YELLOW}未安裝MariaDB/MySQL。${RESET}"
      if [ $system -eq 1 ]; then
        apt install -y curl gnupg lsb-release
        curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version="10.11"
        apt update
        apt install -y mariadb-server
        systemctl enable mariadb
        systemctl start mariadb
      elif [ $system -eq 2 ]; then
        curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version="10.11"
        yum install -y MariaDB-server
        systemctl enable mariadb
        systemctl start mariadb
      elif [ $system -eq 3 ]; then
        apk add mariadb mariadb-client mariadb-openrc
        rc-update add mariadb default
        mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
        service mariadb start
      fi
      exec dbx mysql
    fi
    ;;
  pgsql)
    if command -v pgsql >/dev/null 2>&1; then
      echo -e "${GREEN}已安裝PostgreSQL。${RESET}"
      exec dbx pgsql
    else
      echo -e "${YELLOW}未安裝PostgreSQL。${RESET}"
      if [ $system -eq 1 ]; then
        if ! command -v gpg >/dev/null 2>&1; then
          apt install -y gpg
        fi
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg-archive-keyring.gpg
        local codename=$(lsb_release -c -s)
        echo "deb [signed-by=/usr/share/keyrings/pgdg-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list
        apt update
        apt install -y postgresql-17 postgresql-client-17
        systemctl enable postgresql
        systemctl start postgresql
      elif [ $system -eq 2 ]; then
        local major_ver=$(rpm -E %{rhel})
        yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-${major_ver}-x86_64/pgdg-redhat-repo-latest.noarch.rpm
        yum config-manager --disable pgdg16
        yum config-manager --enable pgdg17
        if [ "$major_ver" -ge 8 ]; then
          dnf -qy module disable postgresql
        fi
        yum install -y postgresql17-server postgresql17
        /usr/pgsql-17/bin/postgresql-17-setup initdb
        systemctl enable postgresql-17
        systemctl start postgresql-17
      elif [ "$system" -eq 3 ]; then
        echo "http://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories
        apk update

        apk add --no-cache \
          postgresql17 --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main --allow-untrusted \
          postgresql17-contrib --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main --allow-untrusted \
          postgresql17-openrc --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main --allow-untrusted

        mkdir -p /run/postgresql
        chown postgres:postgres /run/postgresql

        install -d -m0700 -o postgres -g postgres /var/lib/postgresql/data
        su - postgres -c "/usr/bin/initdb -D /var/lib/postgresql/data"

        rc-update add postgresql default
        rc-service postgresql start
      fi
      echo -e "${GREEN}PostgreSQL 已安裝完成。${RESET}"
      exec dbx pgsql
    fi
    ;;
  esac
}


# 顯示 PostgreSQL 資料庫、擁有者、可存取使用者，以及孤立使用者
show_postgres_info(){
  get_postgres_command
  echo -e "\n${CYAN}目 前 資 料 庫 與 用 戶 狀 態 ：${RESET}"
  echo -e "\033[1;34m----------------------------------------------------------------------\033[0m"

  local db_info_query="
    SELECT
      d.datname,
      r.rolname,
      (SELECT string_agg(u.rolname, ', ')
       FROM pg_roles u
       WHERE has_database_privilege(u.rolname, d.datname, 'CONNECT')
         AND u.rolname NOT LIKE 'pg_%'
         AND u.rolname != 'postgres'
         AND u.rolname != r.rolname)
    FROM pg_database d
    JOIN pg_roles r ON d.datdba = r.oid
    WHERE d.datistemplate = false AND d.datname <> 'postgres'
    ORDER BY d.datname;
  "

  local db_info=$("${PSQL_CMD[@]}" -c "$db_info_query")

  if [ -z "$db_info" ]; then
    echo -e "${YELLOW}  尚 無 自 訂 資 料 庫 。${RESET}"
  else
    printf "%-25s | %-20s | %s\n" "資 料 庫 名 稱" "擁 有 者" "其 他 可 存 取 用 戶"
    echo -e "\033[1;34m----------------------------------------------------------------------\033[0m"
    echo "$db_info" | while IFS='|' read -r db owner users; do
        printf "%-25s | %-20s | %s\n" "$(echo $db)" "$(echo $owner)" "$(echo ${users:-無})"
    done
  fi

  echo -e "\033[1;34m----------------------------------------------------------------------\033[0m"

  # 查詢完全沒有任何資料庫 CONNECT 權限的非系統用戶
  local orphan_users_query="
    SELECT r.rolname
    FROM pg_roles r
    WHERE r.rolcanlogin = true
      AND r.rolname NOT LIKE 'pg_%'
      AND r.rolname != 'postgres'
      AND NOT EXISTS (
        SELECT 1 FROM pg_database d
        WHERE d.datistemplate = false
          AND d.datname <> 'postgres'
          AND has_database_privilege(r.rolname, d.datname, 'CONNECT')
      )
    ORDER BY r.rolname;
  "

  local orphan_users=$("${PSQL_CMD[@]}" -t -A -c "$orphan_users_query")

  if [ -n "$orphan_users" ]; then
    local user_list=$(echo "$orphan_users" | paste -sd ", " -)
    echo -e "${YELLOW}未配置任何資料庫 CONNECT 權限的用戶：${RESET}${user_list}"
  fi
  echo
}
setup_dba_command() {
  local dba_path="/usr/local/bin/dba"
  local dba_url="https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh"  # 改成你的腳本網址

  # 如果已經存在，就略過
  if [ -f "$dba_path" ]; then
    return 0
  fi

  # 靜默下載腳本（使用 curl）
  curl -fsSL "$dba_url" -o "$dba_path" || return 1

  # 確保有執行權限
  chmod +x "$dba_path"
}

show_mysql_info() {
  echo -e "\n${CYAN}目 前 資 料 庫 與 用 戶 狀 態 ：${RESET}"
  echo -e "\033[1;34m----------------------------------------------------------------------\033[0m"
  printf "%-25s | %-40s\n" "資 料 庫 名 稱" "可 存 取 用 戶"
  echo -e "\033[1;34m----------------------------------------------------------------------\033[0m"

  # 撈自訂資料庫清單（排除系統庫）
  local all_dbs
  all_dbs=$("${MYSQL_CMD[@]}" -N -e "
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');
  ")

  # 撈出授權對應表：資料庫 -> 使用者（GROUP_CONCAT 組成一行）
  declare -A db_has_user
  while IFS=$'\t' read -r db users; do
    db_has_user["$db"]="$users"
  done < <("${MYSQL_CMD[@]}" -N -e "
    SELECT db, GROUP_CONCAT(DISTINCT user SEPARATOR ', ')
    FROM mysql.db
    WHERE db NOT IN ('mysql','information_schema','performance_schema','sys')
    GROUP BY db;
  ")

  if [ -z "$all_dbs" ]; then
    echo -e "${YELLOW}  尚 無 自 訂 資 料 庫。${RESET}"
  else
    echo "$all_dbs" | sed '/^\s*$/d' | while read -r db; do
      if [[ -z "${db_has_user["$db"]}" || "${db_has_user["$db"]}" == "NULL" ]]; then
        printf "${RED}%-25s | 無任何授權 (孤立資料庫)${RESET}\n" "$db"
      else
        printf "%-25s | %s\n" "$db" "${db_has_user["$db"]}"
      fi
    done
  fi

  # 查找沒有任何授權的孤立用戶（user@host 格式）
  local orphan_users
  orphan_users=$("${MYSQL_CMD[@]}" -N -e "
    SELECT CONCAT(user, '@', host)
    FROM mysql.user
    WHERE
      CONCAT(user, '@', host) NOT IN (
        SELECT DISTINCT CONCAT(user, '@', host) FROM mysql.db
      )
      AND user NOT IN (
        'mysql.session', 'mysql.sys', 'debian-sys-maint', 'mysql', 'root', 'mariadb.sys'
      );
  ")

  if [ -n "$orphan_users" ]; then
    echo -e "\n${RED}警告：以下用戶沒有任何資料庫授權：${RESET}"
    echo "$orphan_users" | while read -r user_host; do
      echo -e "${RED}- $user_host${RESET}"
    done
  fi

  echo -e "\033[1;34m----------------------------------------------------------------------\033[0m"
  echo
}

update_script() {
  local download_url="https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh"
  local temp_path="/tmp/dba.sh"
  local current_script="/usr/local/bin/dba"
  local current_path="$0"

  echo "正在檢查更新..."
  wget -q "$download_url" -O "$temp_path"
  if [ $? -ne 0 ]; then
    echo -e "${RED}無法下載最新版本，請檢查網路連線。${RESET}"
    return
  fi

  # 比較檔案差異
  if [ -f "$current_script" ]; then
    if diff "$current_script" "$temp_path" >/dev/null; then
      echo -e "${GREEN}腳本已是最新版本，無需更新。${RESET}"
      rm -f "$temp_path"
      return
    fi
    echo "正在更新..."
    cp "$temp_path" "$current_script" && chmod +x "$current_script"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}更新成功！將自動重新啟動腳本以套用變更...${RESET}"
      sleep 1
      exec "$current_script"
    else
      echo -e "${RED}更新失敗，請確認權限。${RESET}"
    fi
  else
    # 非 /usr/local/bin 執行時 fallback 為當前檔案路徑
    if diff "$current_path" "$temp_path" >/dev/null; then
      echo -e "${GREEN}腳本已是最新版本，無需更新。${RESET}"
      rm -f "$temp_path"
      return
    fi
    echo "檢測到新版本，正在更新..."
    cp "$temp_path" "$current_path" && chmod +x "$current_path"
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}更新成功！將自動重新啟動腳本以套用變更...${RESET}"
      sleep 1
      exec "$current_path" $db_mode
    else
      echo -e "${RED}更新失敗，請確認權限。${RESET}"
    fi
  fi

  rm -f "$temp_path"
}

install_menu(){
  while true; do
    echo "=======資料庫管理工具========"
    echo "1. 安裝MySQL"
    echo "2. 安裝PostgreSQL"
    read -p "請選擇安裝程式：" choice
    case $choice in
    1)
      install_database mysql
      ;;
    2)
      install_database pgsql
      ;;
    esac
  done
}

choice_db_menu(){
  while true; do
    echo "=======資料庫管理工具========"
    echo "1. 管理MySQL"
    echo "2. 管理PostgreSQL"
    read -p "請選擇安裝程式：" choice
    case $choice in
    1)
      get_mysql_command
      db_mode=mysql
      show_menu
      ;;
    2)
      get_postgres_command
      db_mode=pgsql
      show_menu
      ;;
    esac
  done
}



show_menu(){
  while true; do
    clear
    if [ $db_mode = mysql ]; then
      show_mysql_info
      echo "MySQL資料庫管理"
    elif [ $db_mode = pgsql ]; then
      show_postgres_info
      echo "PostgreSQL資料庫管理"
    fi
    echo -e "\033[1;34m-------------------\033[0m"
    echo "1. 建立資料庫與用戶    2. 刪除資料庫"
    echo "3. 匯出資料庫         4. 匯入資料庫"
    echo "5. 建立超級帳號"
    echo ""
    echo "使用者管理"
    echo -e "\033[1;34m-------------------\033[0m"
    echo "6. 建立使用者         7. 刪除使用者"
    echo "8. 重製用戶密碼       9. 授權用戶給資料庫"
    echo ""
    echo "系統管理"
    echo -e "\033[1;34m--------------\033[0m"
    if [ $db_mode = mysql ]; then
      echo "10. 解除安裝MySQL"
      echo ""
      echo "11. 安裝及管理PostgreSQL"
      echo "12. 安裝管理工具phpmyadmin（須有docker和超級用戶）"
    elif [ $db_mode = pgsql ]; then
      echo "10. 解除安裝PostgreSQL"
      echo ""
      echo "11. 安裝及管理MySQL"
      echo "12. 安裝管理工具pgweb（須有docker和超級用戶）"
    fi
    echo ""
    echo -e "\033[1;31mu. 更新腳本          0. 退出\033[0m"
    echo ""
    echo -n -e "\033[1;33m請選擇操作 [0-11]: \033[0m"
    read -r choice
    case $choice in
    1)
      create_database
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    2)
      remove_database
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    3)
      export_database
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    4)
      import_database
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    5)
      create_super_user
      ;;
    6)
      add_user
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    7)
      remove_user
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    8)
      reset_user_password
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    9)
      grant_user
      read -p "操作完成，請按任意鍵繼續。" -n1 -r
      ;;
    10)
      uninstall_database $db_mode
      ;;
    11)
      if [ $db_mode = mysql ]; then
        install_database pgsql
      elif [ $db_mode = pgsql ]; then
        install_database mysql
      fi
      ;;
    12)
      deploy_db_admin_ui
      ;;
    u)
      clear
      echo "更新腳本"
      echo "------------------------"
      update_script
      ;;
    0)
      echo "感謝使用!"
      exit 0
      ;;
    *)
      echo -e "${RED}無效的選項，請重新輸入。${RESET}"
      sleep 1
      ;;
    esac
  done
}

case "$1" in
  --version|-V)
    echo "資料庫管理器版本 $version"
    exit 0
    ;;
esac

# 初始化
setup_dba_command
check_system
check_app

case "$1" in
  mysql)
    case "$2" in
    install)
      install_database mysql
      ;;
    add)
      check_mysql
      cil_mode=true
      dbname=$3
      dbuser=$4
      skip=$5
      [[ "$skip" == "--force" ]] && skip=y
      pass=${6:-$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')}
      create_database "$dbname" "$dbuser" "$pass" "$skip" $cil_mode 
      echo $pass
      exit 
      ;;
    del)
      check_mysql
      dbname=$3
      cli_mode=true
      skip=$4
      [[ "$skip" == "--force" ]] && skip=y
      remove_database "$dbname" "$cli_mode" "$skip"
      exit
      ;;
    "export")
      check_mysql
      dbname=$3
      export_database "$dbname"
      exit
      ;;
    *)
      check_mysql
      db_mode=mysql
      show_menu
      ;;
    esac
    ;;
  pgsql)
    case $2 in
    install)
      install_database pgsql
      ;;
    add)
      check_pgsql
      cil_mode=true
      dbname=$3
      dbuser=$4
      nat=$5
      [[ "$nat" == "true" || "$nat" == "yes" ]] && nat=y
      pass=${6:-$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')}
      create_database "$dbname" "$dbuser" "$pass" "$nat" $cil_mode 
      echo $pass
      exit 
      ;;
    del)
      check_pgsql
      dbname=$3
      cli_mode=true
      skip=$4
      [[ "$skip" == "--force" ]] && skip=y
      remove_database "$dbname" "$cli_mode" "$skip"
      exit
      ;;
    "export")
      check_pgsql
      dbname=$3
      export_database "$dbname"
      exit
      ;;
    *)
      check_pgsql
      db_mode=pgsql
      show_menu
      ;;
    esac
    ;;
  install_script)
    exit 0
    ;;
esac

check_db
