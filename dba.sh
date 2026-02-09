#!/bin/bash

# 顏色定義
RED='\033[0;31m'     # 錯誤用紅色
GREEN='\033[0;32m'   # 成功用綠色
YELLOW='\033[1;33m'  # 警告用黃色
CYAN='\033[0;36m'    # 一般提示用青色
RESET='\033[0m'      # 清除顏色

version="4.2.2"
cli_mode=false

# 檢查是否以root權限運行
if [ "$(id -u)" -ne 0 ]; then
  echo "此腳本需要root權限運行" 
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  else
    install_sudo_cmd=""
    if command -v apt >/dev/null 2>&1; then
      install_sudo_cmd="apt-get update && apt-get install -y sudo"
    elif command -v dnf >/dev/null 2>&1; then
      install_sudo_cmd="dnf install -y sudo"
    elif command -v apk >/dev/null 2>&1; then
      install_sudo_cmd="apk add sudo"
    else
      echo "無sudo指令"
      sleep 1
      exit 1
    fi
    su -c "$install_sudo_cmd"
    if [ $? -eq 0 ] && command -v sudo >/dev/null 2>&1; then
      echo "sudo指令已經安裝成功，請等下輸入您的密碼"
      exec sudo "$0" "$@"
    fi
  fi
fi

# 檢查系統版本
check_system(){
  if command -v apt >/dev/null 2>&1; then
    system=1
  elif command -v dnf >/dev/null 2>&1; then
    if grep -q -Ei "release 7|release 8" /etc/redhat-release; then
      echo -e "${RED}不支援 CentOS 7 或 CentOS 8，請升級至 9 系列 (Rocky/Alma/CentOS Stream)${RESET}"
      exit 1
    fi
    if command -v getenforce >/dev/null 2>&1; then
      if [ "$(getenforce)" == "Enforcing" ]; then
        selinux_enforcing=true
      fi
    fi
    system=2
  elif command -v apk >/dev/null 2>&1; then
    system=3
  else
    echo -e "${RED}不支援的系統。${RESET}"
    exit 1
  fi
}

check_cli_db(){
  local input=$1
  declare -A db=(
    ["mysql"]="MariaDB/MySQL"
    ["pgsql"]="PostgreSQL"
  )

  case $input in
  mysql)
    if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
      get_mysql_command
      db_mode=mysql
      return 0
    fi
    ;;
  pgsql)
    if command -v psql >/dev/null 2>&1; then
      db_mode=pgsql
      get_postgres_command
      return 0
    fi
    ;;
  esac
  echo -e "${YELLOW}未安裝${db[$input]}，請先安裝！${RESET}"
  exit 1
}


# 檢查無安裝內容
check_app(){
  declare -A pkg_map=(
    ["sudo"]="sudo"
    ["wget"]="wget"
    ["jq"]="jq"
  )
  if [ $system -eq 2 ]; then
    if ! dnf repolist enabled | grep -q "epel"; then
      dnf install -y epel-release
    fi
  fi
  for cmd in "${!pkg_map[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      pkg="${pkg_map[$cmd]}"
      case "$system" in
      1) apt update -qq && apt install -y "$pkg" ;;
      2) dnf update && dnf install -y "$pkg" ;;
      esac
    fi
  done
  if $selinux_enforcing; then
    if ! command -v semanage >/dev/null 2>&1; then
      dnf install -y policycoreutils-python-utils
    fi
    if ! command -v getfacl >/dev/null 2>&1; then
      dnf install -y acl
    fi
  fi
}
check_db() {
  count=0
  pg=false
  mysql=false

  if command -v psql >/dev/null 2>&1; then
    pg=true
    ((count++))
  fi

  if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
    mysql=true
    ((count++))
  fi

  case $count in
    0)
      install_menu
      ;;
    1)
      if [[ $pg = true ]]; then
        get_postgres_command
        db_mode=pgsql
      else
        get_mysql_command
        db_mode=mysql
      fi
      show_menu
      ;;
    *)
      choice_db_menu
      ;;
  esac
}
deploy_webui() {
  setup_reverse_proxy() {
    local port="$1"
    local confirm=""
    
    read -p "是否使用反向代理？（Y/n）" confirm

    if ! command -v site >/dev/null 2>&1; then
      return 1
    fi
    confirm=${confirm,,}
    if [[ "$confirm" = "y" || "$confirm" = "" ]]; then
      read -p "請輸入域名：" domain
      if site setup "$domain" proxy "127.0.0.1" "http" "$port"; then
        return $?
      fi
    fi
  }
  local db_host="172.17.0.1"
  local mysql_port=3306
  local pgsql_port=5432
  local ui_user="admin"
  local ui_pass="$(openssl rand -base64 12 | tr -dc A-Za-z0-9)"
  local port=""
  local confirm

  # 檢查 docker
  if ! command -v docker &>/dev/null; then
    echo -e "${RED}Docker 未安裝，請先安裝 Docker。${RESET}"
    return 1
  fi

  # 隨機端口
  while true; do
    read -r -p "請輸入數據庫管理映射端口（留空自動隨機）:" port
    if [[ -z "$port" ]]; then
      port=$(( ( RANDOM % (65535 - 1025) ) + 1025 ))
      echo -e "${CYAN}自動選擇隨機端口：$port${RESET}"
    fi
    ss -tuln | awk '{print $5}' | grep -qE ":$port$" \
      && echo -e "${YELLOW}端口 $port 已被佔用，請重新輸入！${RESET}" \
      || break
  done
  if [[ "$db_mode" = "mysql" ]]; then
    if ! docker ps -a --format '{{.Names}}' | grep -q "^phpmyadmin$"; then
      
      local extra_env=""

      read -p "是否使用反向代理[Y/n](Default:N) " confirm
      confirm=${confirm,,}

      if [[ "$confirm" == "y" ]]; then
        if setup_reverse_proxy $port; then
          extra_env="-e PMA_ABSOLUTE_URI=https://$domain"
        else
          domain=""
        fi
      fi

      docker run -d --restart always --name phpmyadmin -p "$port":80 -e PMA_HOST="$db_host" -e PMA_PORT="$mysql_port" $extra_env phpmyadmin/phpmyadmin

      if [[ -n "$domain" ]]; then
        echo -e "${GREEN}phpMyAdmin 已創建於 https://$domain${RESET}"
      else
        echo -e "${GREEN}phpMyAdmin 已啟動於 http://localhost:$port${RESET}"
      fi
      sleep 5
    fi
  elif [[ "$db_mode" = "pgsql" ]]; then

    if ! docker ps -a --format '{{.Names}}' | grep -q "^adminer$"; then
      docker run -d \
        --restart always \
        --name adminer \
        -p $port:8080 \
        adminer

      setup_reverse_proxy "$port"

      if [[ -n "$domain" ]]; then
        echo -e "${GREEN}Adminer 已啟動於 http://$domain${RESET}"
      else
        echo -e "${GREEN}Adminer 已啟動於 http://localhost:$port${RESET}"
      fi
      echo "主機名稱: $db_host"
      read -p "操作完成，請按任意鍵繼續..." -n1
    fi
  fi
  unset domain
  unset setup_reverse_proxy
}



# 全域變數 MYSQL_CMD（陣列）將會被設定為 mysql 指令
MYSQL_CMD=()

get_mysql_command() {
  if [ ${#MYSQL_CMD[@]} -gt 0 ]; then
    return 0
  fi
  local mysql_root_pw=""
  local pass_file="/etc/mysql-pass.conf"
  local cmd=""
  local attempt=0
  local max_attempts=5

  # 優先使用 mariadb 指令
  if command -v mariadb >/dev/null 2>&1; then
    cmd="mariadb"
  elif command -v mysql >/dev/null 2>&1; then
    cmd="mysql"
  fi

  # 嘗試無密碼登入
  if $cmd -u root -e "SELECT 1;" &>/dev/null; then
    MYSQL_CMD=("$cmd" "-u" "root")
    return 0
  fi

  # 嘗試讀取 /etc/mysql-pass.conf
  if [ -f "$pass_file" ]; then
    mysql_root_pw=$(< "$pass_file")
    if $cmd -u root -p"$mysql_root_pw" -e "SELECT 1;" &>/dev/null; then
      MYSQL_CMD=("$cmd" "-u" "root" "-p$mysql_root_pw")
      return 0
    fi
  fi

  # 不存在 conf 或無效，請使用者輸入
  while true; do
    read -s -p "請輸入 MySQL root 密碼：" mysql_root_pw
    echo
    attempt=$((attempt + 1))

    if [ -z "$mysql_root_pw" ]; then
      echo -e "${YELLOW}密碼不能為空，請再試一次。${RESET}"
      continue
    fi

    if $cmd -u root -p"$mysql_root_pw" -e "SELECT 1;" &>/dev/null; then
      echo "$mysql_root_pw" > "$pass_file"
      chmod 600 "$pass_file"
      echo -e "${GREEN}已將 root 密碼寫入 $pass_file (權限 600)${RESET}"
      MYSQL_CMD=("$cmd" "-u" "root" "-p$mysql_root_pw")
      return 0
    else
      echo -e "${RED}密碼錯誤，請再試一次。${RESET}"
    fi

    if [ $attempt -ge $max_attempts ]; then
      echo -e "${RED}已達最大嘗試次數 ($max_attempts)，程式退出。${RESET}"
      exit 1
    fi
  done
}

PSQL_CMD=()
PGDUMP_CMD=()

get_postgres_command() {
  # --- 前置檢查 (保持不變) ---
  if ! id "postgres" &>/dev/null; then
    echo -e "${RED}找不到 postgres 系統使用者，請確認 PostgreSQL 是否已正確安裝並初始化。${RESET}" >&2
    exit 1
  fi
  pg_major=$(psql -V | grep -oP 'PostgreSQL\)\s+\K[0-9]+' )
  _filtered_sudo() {
    sudo "$@" 2> >(grep -v "unable to resolve host" >&2)
  }
  export -f _filtered_sudo

  PSQL_CMD=("_filtered_sudo" "-iu" "postgres" "psql" "-q" "-t" "-A")
  PSQL_EXEC_CMD=("_filtered_sudo" "-iu" "postgres" "psql" "-c")
  PGDUMP_CMD=("_filtered_sudo" "-iu" "postgres" "pg_dump")
  return 0
}

postgres_external_access() {
  local username=$1
  
  local conf_file=$(_filtered_sudo -iu postgres psql -tAc "SHOW config_file;")
  local hba_file=$(_filtered_sudo -iu postgres psql -tAc "SHOW hba_file;")
  if ! grep -P "^\s*listen_addresses\s*=\s*'\*'" "$conf_file" >/dev/null; then
    if grep -P "^\s*#?\s*listen_addresses\s*=" "$conf_file" >/dev/null; then
      sed -i -E "s|^\s*#?\s*listen_addresses\s*=.*|listen_addresses = '*'|" "$conf_file"
    else
      echo "listen_addresses = '*'" >> "$conf_file"
    fi
    (service postgresql restart 2>/dev/null || service postgresql-$pg_major restart 2>/dev/null)
  fi
  if ! grep -E "host\s+all\s+$username\s+0\.0\.0\.0/0\s+md5" "$hba_file" >/dev/null; then
    echo "host all $username 0.0.0.0/0 md5" >> "$hba_file"
  fi
  access_mode=外網
}

postgres_revoke_external_access() {
  local username="$1"

  # 取得 pg_hba.conf 路徑
  local hba_file=$(_filtered_sudo -iu postgres psql -tAc "SHOW hba_file;")

  if [[ ! -f "$hba_file" ]]; then
    echo -e "找不到 pg_hba.conf 檔案：$hba_file"
    return 1
  fi

  # 備份 pg_hba.conf
  cp "$hba_file" "${hba_file}.bak"

  # 檢查是否有針對此用戶的 0.0.0.0/0 或 ::/0 host 規則
  if grep -qE "^[[:space:]]*host[[:space:]]+all[[:space:]]+$username[[:space:]]+(0\.0\.0\.0/0|::/0)" "$hba_file"; then
    # 移除該條目
    sed -i "/^[[:space:]]*host[[:space:]]\+all[[:space:]]\+$username[[:space:]]\+\(0\.0\.0\.0\/0\|::\/0\)/d" "$hba_file"
    (service postgresql restart 2>/dev/null || service postgresql-$pg_major restart 2>/dev/null)
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
      postgres_external_access "$username"
      host="外網"
    fi
  fi

  # 密碼設定
  if [[ "$add_user" == "y" ]]; then
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
  fi

  # 建立資料庫
  if [ "$db_mode" == "mysql" ]; then
    "${MYSQL_CMD[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$dbname\`;" >/dev/null
    if [[ "$add_user" == "y" ]]; then
      "${MYSQL_CMD[@]}" -e "CREATE USER IF NOT EXISTS '$username'@'$host' IDENTIFIED BY '$password';" >/dev/null
      "${MYSQL_CMD[@]}" -e "GRANT ALL PRIVILEGES ON \`$dbname\`.* TO '$username'@'$host';" >/dev/null
      "${MYSQL_CMD[@]}" -e "FLUSH PRIVILEGES;" >/dev/null
    fi
  elif [ "$db_mode" == "pgsql" ]; then
    "${PSQL_EXEC_CMD[@]}" "CREATE DATABASE \"$dbname\";" >/dev/null
    if [[ "$add_user" == "y" ]]; then
      "${PSQL_EXEC_CMD[@]}" "CREATE USER \"$username\" WITH PASSWORD '$password';" >/dev/null
      "${PSQL_EXEC_CMD[@]}" "GRANT ALL PRIVILEGES ON DATABASE \"$dbname\" TO \"$username\";" >/dev/null
      "${PSQL_EXEC_CMD[@]}" "REVOKE ALL ON DATABASE \"$dbname\" FROM PUBLIC;" >/dev/null
      "${PSQL_EXEC_CMD[@]}" "REVOKE ALL ON SCHEMA public FROM PUBLIC;" >/dev/null
      "${PSQL_EXEC_CMD[@]}" "GRANT ALL ON SCHEMA public TO \"$username\";" >/dev/null
    fi
    if [ $allow_remote == y ]; then
      (service postgresql restart 2>/dev/null || service postgresql-$pg_major restart 2>/dev/null)
    fi
  fi
  
  # CLI模式不顯示
  if [ "$cli_mode" == "true" ]; then return 0; fi

  echo -e "${GREEN}資料庫與使用者設定完成${RESET}"
  echo "資料庫名稱：$dbname"
  if [[ "$add_user" == "y" ]]; then
    echo "用戶名稱：$username"
    echo "用戶密碼：$password"
    echo "主機地址：$host"
  fi
}


# 刪除資料庫，並可選擇是否一併刪除其關聯的所有用戶
remove_database() {
  local target_dbs="${1:-}"
  local skip="$2"
  
  if [ "$db_mode" = "mysql" ]; then
    if [ -z "$target_dbs" ]; then
      local raw_dbs=$("${MYSQL_CMD[@]}" -N -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys');")

      if [ -z "$raw_dbs" ]; then
        echo -e "${YELLOW}目前沒有可供刪除的自訂資料庫。${RESET}" >&2
        sleep 2
        return 0
      fi

      echo -e "${CYAN}可刪除的資料庫列表 (MySQL)：${RESET}"
      local db_array=($raw_dbs)
      for i in "${!db_array[@]}"; do
        printf "%3d) %s\n" "$((i+1))" "${db_array[$i]}"
      done
      echo

      read -p "請輸入要刪除的資料庫編號 (可輸入多個，以空格分隔): " selection
      if [ -z "$selection" ]; then
        echo -e "${YELLOW}未輸入任何選項，操作取消。${RESET}"
        return
      fi

      local selected_dbs=""
      for i in $selection; do
        if ! [[ "$i" =~ ^[0-9]+$ ]] || [ "$i" -lt 1 ] || [ "$i" -gt "${#db_array[@]}" ]; then
          echo -e "${RED}輸入的編號 '$i' 是無效的，已跳過。${RESET}"
          continue
        fi
        selected_dbs="$selected_dbs ${db_array[$((i-1))]}"
      done
      target_dbs=$selected_dbs
    fi

    for dbname in $target_dbs; do
      if [ -z "$dbname" ]; then continue; fi

      if ! "${MYSQL_CMD[@]}" -e "SHOW DATABASES LIKE '$dbname';" | grep -q "$dbname"; then
        echo -e "${RED}資料庫 $dbname 不存在！${RESET}" >&2
        continue
      fi

      local users=$("${MYSQL_CMD[@]}" -N -e "SELECT user, host FROM mysql.db WHERE db = '$dbname';")

      if [ -n "$users" ]; then
        local choice=""
        if [ -z "$skip" ]; then
          read -p "偵測到與 '$dbname' 有關聯用戶，是否要一併刪除？(y/n) " choice
        else
          choice="$skip"
        fi

        if [[ "$choice" == "y" ]]; then
          echo "$users" | while read user host; do
            "${MYSQL_CMD[@]}" -e "DROP USER IF EXISTS '$user'@'$host';" >&2
            echo -e "${GREEN}已刪除用戶：$user@$host${RESET}"
          done
        fi
      fi

      if "${MYSQL_CMD[@]}" -e "DROP DATABASE IF EXISTS \`$dbname\`;"; then
        echo -e "${GREEN}資料庫 $dbname 已成功刪除。${RESET}" >&2
      else
        echo -e "${RED}刪除資料庫 $dbname 失敗！${RESET}" >&2
      fi
    done
    return 0
  fi

  if [ "$db_mode" = "pgsql" ]; then
    
    # 1. 如果沒有傳入 target_dbs，才顯示選單
    if [ -z "$target_dbs" ]; then
      local raw_dbs=$("${PSQL_CMD[@]}" -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres';")

      if [ -z "$raw_dbs" ]; then
        echo -e "${YELLOW}目前沒有可供刪除的自訂資料庫。${RESET}" >&2
        sleep 2
        return 0
      fi
      
      echo -e "${CYAN}可刪除的資料庫列表 (PostgreSQL)：${RESET}"
      local db_array=($raw_dbs)
      for i in "${!db_array[@]}"; do
          printf "%3d) %s\n" "$((i+1))" "${db_array[$i]}"
      done
      echo

      read -p "請輸入要刪除的資料庫編號 (可輸入多個，以空格分隔): " selection
      if [ -z "$selection" ]; then
        echo -e "${YELLOW}未輸入任何選項，操作取消。${RESET}"
        return
      fi

      local selected_dbs=""
      for i in $selection; do
        if ! [[ "$i" =~ ^[0-9]+$ ]] || [ "$i" -lt 1 ] || [ "$i" -gt "${#db_array[@]}" ]; then
          echo -e "${RED}輸入的編號 '$i' 是無效的，已跳過。${RESET}"
          continue
        fi
        selected_dbs="$selected_dbs ${db_array[$((i-1))]}"
      done
      target_dbs=$selected_dbs
    fi

    for dbname in $target_dbs; do
      if [ -z "$dbname" ]; then continue; fi

      # 檢查是否有關聯用戶
      local user_query="
        SELECT rolname FROM pg_roles WHERE rolname IN (
          SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$dbname'
          UNION
          SELECT u.rolname FROM pg_roles u WHERE has_database_privilege(u.rolname, '$dbname', 'CONNECT')
        )
        AND rolname != 'postgres' AND rolname NOT LIKE 'pg_%';
      "
      mapfile -t associated_users < <("${PSQL_CMD[@]}" -t -A -c "$user_query")

      # 執行刪除資料庫
      # 注意：PostgreSQL 如果有人連線中會刪除失敗，這裡不強制斷線，若有需要可加 pg_terminate_backend
      if "${PSQL_EXEC_CMD[@]}" "DROP DATABASE \"$dbname\";" >/dev/null; then
        echo -e "${GREEN}資料庫 '$dbname' 已成功刪除。${RESET}" >&2

        # 如果有關聯用戶，詢問刪除
        if [ -n "$associated_users" ]; then
          for user in "${associated_users[@]}"; do
            # 這裡加入 skip 判斷
            local confirm_user=""
            if [ -z "$skip" ]; then
               # 手動模式
               read -p "是否要一併刪除關聯用戶 '$user'？ (y/n) " confirm_user
            else
               confirm_user="$skip"
            fi

            if [[ "$confirm_user" =~ ^[Yy]$ ]]; then
              postgres_revoke_external_access "$user"
              "${PSQL_EXEC_CMD[@]}" "REASSIGN OWNED BY \"$user\" TO postgres; DROP OWNED BY \"$user\";" >/dev/null
              if "${PSQL_EXEC_CMD[@]}" "DROP ROLE \"$user\";" >/dev/null; then
                echo -e "${GREEN}使用者 '$user' 已成功刪除。${RESET}" >&2
              else
                echo -e "${RED}刪除使用者 '$user' 失敗！可能是因為該使用者還擁有其他資源。${RESET}" >&2
              fi
            fi
          done
        fi
      else
        echo -e "${RED}刪除資料庫 '$dbname' 失敗！(請確認名稱正確或無連線佔用)${RESET}" >&2
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
  local info_desc=""

  read -p "請輸入用戶名稱：" raw_username
  username=$(sanitize_name "$raw_username")

  if [[ -z "$username" ]]; then
    echo -e "${RED}用戶名稱不可為空或含非法字元！${RESET}"
    return 1
  fi

  # 密碼輸入流程
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
      [[ "$password" != "$password2" ]] \
        && echo -e "${RED}密碼不一致，請重新輸入。${RESET}" \
        || break
    fi
  done

  # MySQL 區域
  if [ "$db_mode" = mysql ]; then
    read -p "是否允許外網訪問此用戶？(y/n) " remote

    if [[ "$remote" =~ ^[Yy]$ ]]; then
      host='%'
      info_desc="MySQL：外網"
    else
      host="localhost"
      info_desc="MySQL：本地"
    fi

    "${MYSQL_CMD[@]}" -e "CREATE USER IF NOT EXISTS '$username'@'$host' >/dev/null IDENTIFIED BY '$password';"
    "${MYSQL_CMD[@]}" -e "FLUSH PRIVILEGES;" >/dev/null
  else
    # PostgreSQL 區域
    if "${PSQL_CMD[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
      echo -e "${RED}使用者 $username 已存在！${RESET}"
      return 1
    fi

    "${PSQL_EXEC_CMD[@]}" "CREATE USER \"$username\" WITH PASSWORD '$password';" >/dev/null

    read -p "是否開放此用戶外網訪問？（Y/n）？" confirm
    confirm=${confirm,,}

    if [[ $confirm == y || $confirm == "" ]]; then
      postgres_external_access "$username"
      info_desc="PostgreSQL：外網"
    else
      info_desc="PostgreSQL：本地"
    fi
  fi

  echo -e "${GREEN}用戶已建立${RESET}"
  echo "用戶名稱：$username"
  echo "用戶密碼：$password"
  echo "資料庫模式：$info_desc"
  echo
  echo -e "${YELLOW}請記下用戶名稱、用戶密碼，以便後續使用。${RESET}"
}


#刪除使用者
remove_user() {
  local target_users=""
  local cli_mode=""
  if [ -z "$target_users" ]; then
    local raw_users=""
    local db_label=""

    if [ "$db_mode" = "mysql" ]; then
      raw_users=$("${MYSQL_CMD[@]}" -N -e "SELECT DISTINCT user FROM mysql.user WHERE user NOT IN ('root', 'mariadb.sys', 'mysql', 'mysql.session', 'mysql.sys', 'mysql.infoschema', 'debian-sys-maint');")
      db_label="MySQL"
    else
      raw_users=$("${PSQL_CMD[@]}" -t -A -c "SELECT rolname FROM pg_roles WHERE rolname != 'postgres' AND rolname NOT LIKE 'pg_%';")
      db_label="PostgreSQL"
    fi

    if [ -z "$raw_users" ]; then
      echo -e "${YELLOW}目前沒有可供刪除的自訂使用者。${RESET}" >&2
      sleep 2
      return 0
    fi

    echo -e "${CYAN}可刪除的使用者列表 ($db_label)：${RESET}"
    local user_array=($raw_users)
    for i in "${!user_array[@]}"; do
      printf "%3d) %s\n" "$((i+1))" "${user_array[$i]}"
    done
    echo

    read -p "請輸入要刪除的使用者編號 (可輸入多個，以空格分隔): " selection
    if [ -z "$selection" ]; then
      echo -e "${YELLOW}未輸入任何選項，操作取消。${RESET}"
      return
    fi

    for i in $selection; do
      if ! [[ "$i" =~ ^[0-9]+$ ]] || [ "$i" -lt 1 ] || [ "$i" -gt "${#user_array[@]}" ]; then
        echo -e "${RED}輸入的編號 '$i' 是無效的，已跳過。${RESET}"
        continue
      fi
      target_users="$target_users ${user_array[$((i-1))]}"
    done
  fi
  
  for username in $target_users; do
    if [ -z "$username" ]; then continue; fi
    if [ "$username" == "root" ]; then
      echo -e "${RED}禁止刪除 root 超級使用者！${RESET}"
      continue
    fi
    
    if [ $db_mode = mysql ]; then
      # 你的 MySQL 邏輯
      local user_hosts=$("${MYSQL_CMD[@]}" -N -e "
        SELECT host FROM mysql.user WHERE user='$username';
      ")

      if [ -z "$user_hosts" ]; then
        echo -e "${RED}用戶 $username 不存在！${RESET}" >&2
        continue # 改成 continue
      fi
      echo "$user_hosts" | while read host; do
        # revoke
        "${MYSQL_CMD[@]}" -e "REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$username'@'$host';" 2>/dev/null

        # drop user
        "${MYSQL_CMD[@]}" -e "DROP USER IF EXISTS '$username'@'$host';"
        echo -e "${GREEN}已刪除用戶 $username@$host${RESET}"
      done
      continue 
    fi

    # 你的 PostgreSQL 邏輯
    if ! "${PSQL_CMD[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$username'" | grep -q 1; then
      echo -e "${RED}用戶 $username 不存在！${RESET}" >&2
      continue
    fi
    
    if [ "$username" == "postgres" ]; then
      echo -e "${RED}禁止刪除 postgres 超級使用者！${RESET}" >&2
      continue
    fi

    "${PSQL_EXEC_CMD[@]}" "REASSIGN OWNED BY \"$username\" TO postgres; REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"$username\";"
    
    "${PSQL_EXEC_CMD[@]}" "REASSIGN OWNED BY \"$username\" TO postgres; DROP OWNED BY \"$username\";" >/dev/null
    "${PSQL_EXEC_CMD[@]}" "DROP USER IF EXISTS \"$username\";"
    postgres_revoke_external_access $username
    echo -e "${GREEN}已刪除用戶 $username ${RESET}"
  done
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
      (service mysql restart 2>/dev/null || service mariadb restart 2>/dev/null)
    fi

  elif [ "$db_mode" = "pgsql" ]; then
    local PG_HBA=$(_filtered_sudo -iu postgres psql -tAc "SHOW hba_file;")
    local PG_CONF=$(_filtered_sudo -iu postgres psql -tAc "SHOW config_file;")

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

      (service postgresql restart 2>/dev/null || service postgresql-$pg_major restart 2>/dev/null)
    fi

    if [ "$cli_mode" = true ]; then
      return
    fi
  fi
  echo "======帳號信息======"
  echo "用戶名：$username"
  echo "密碼：$password"
  read -p "操作完成，請按任意鍵繼續" -n1
}

# 重製密碼
reset_user_password() {
  local raw_user=""
  local user=""
  local new_pass=""
  local hosts=""
  local host_count=""
  
  if [ "$db_mode" = mysql ]; then
    echo "===== MySQL 帳號密碼重置工具 ====="

    # 取得 MySQL 使用者列表，排除 root、mysql、mariadb.sys
    mapfile -t users < <("${MYSQL_CMD[@]}" -N -B -e "SELECT user FROM mysql.user WHERE user NOT IN ('root','mysql','mariadb.sys');")

    if [ "${#users[@]}" -eq 0 ]; then
      echo -e "${RED}沒有可用的 MySQL 使用者！${RESET}"
      return 1
    fi

    echo "請選擇要重置的使用者："
    for i in "${!users[@]}"; do
      echo "$((i+1))) ${users[i]}"
    done

    while true; do
      read -p "輸入選項號碼 (1-${#users[@]}): " choice
      if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#users[@]}" ]; then
        user="${users[$((choice-1))]}"
        break
      else
        echo -e "${RED}無效選項，請重新輸入！${RESET}"
      fi
    done

    host_count=$("${MYSQL_CMD[@]}" -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE user='$user';")
    hosts=$("${MYSQL_CMD[@]}" -N -B -e "SELECT host FROM mysql.user WHERE user='$user';")

    echo -e "${GREEN}找到使用者 $user 存在於以下 host：${RESET}"
    echo "$hosts"

  elif [ "$db_mode" = pgsql ]; then
    echo "===== PostgreSQL 帳號密碼重置工具 ====="

    # 取得 PostgreSQL 使用者列表（排除 postgres）
    mapfile -t users < <("${PSQL_CMD[@]}" -Atc "SELECT rolname FROM pg_roles WHERE rolname != 'postgres';")

    if [ "${#users[@]}" -eq 0 ]; then
      echo -e "${RED}沒有可用的 PostgreSQL 使用者！${RESET}"
      return 1
    fi

    echo "請選擇要重置的使用者："
    for i in "${!users[@]}"; do
      echo "$((i+1))) ${users[i]}"
    done

    while true; do
      read -p "輸入選項號碼 (1-${#users[@]}): " choice
      if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#users[@]}" ]; then
        user="${users[$((choice-1))]}"
        break
      else
        echo -e "${RED}無效選項，請重新輸入！${RESET}"
      fi
    done
  fi

  # 密碼輸入或自動生成
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

  # 更新密碼
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
  if [ "$db_mode" == "pgsql" ]; then
    # PostgreSQL
    mapfile -t user_list < <("${PSQL_CMD[@]}" -tAc "SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolname NOT IN ('postgres');")

    if [ "${#user_list[@]}" -eq 0 ]; then
      echo -e "${RED}找不到可用的登入用戶！${RESET}"
      return 1
    fi

    echo "請選擇要授權的用戶："  
    for i in "${!user_list[@]}"; do
      echo "$((i+1))) ${user_list[i]}"
    done

    while true; do
      read -p "輸入選項號碼 (1-${#user_list[@]}): " choice
      if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#user_list[@]}" ]; then
        username="${user_list[$((choice-1))]}"
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
    for i in "${!db_list[@]}"; do
      echo "$((i+1))) ${db_list[i]}"
    done

    while true; do
      read -p "輸入選項號碼 (1-${#db_list[@]}): " choice
      if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#db_list[@]}" ]; then
        dbname="${db_list[$((choice-1))]}"
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
    mapfile -t user_list < <("${MYSQL_CMD[@]}" -N -B -e "SELECT User FROM mysql.user WHERE User NOT IN ('root','mysql','mariadb.sys');")

    if [ "${#user_list[@]}" -eq 0 ]; then
      echo -e "${RED}找不到可用的登入用戶！${RESET}"
      return 1
    fi

    echo "請選擇要授權的用戶："  
    for i in "${!user_list[@]}"; do
      echo "$((i+1))) ${user_list[i]}"
    done

    while true; do
      read -p "輸入選項號碼 (1-${#user_list[@]}): " choice
      if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#user_list[@]}" ]; then
        username="${user_list[$((choice-1))]}"
        break
      else
        echo -e "${YELLOW}請輸入有效的編號。${RESET}"
      fi
    done

    # 取得資料庫清單
    mapfile -t db_list < <("${MYSQL_CMD[@]}" -N -B -e "SHOW DATABASES;")

    # 排除系統資料庫
    db_list=($(printf "%s\n" "${db_list[@]}" | grep -Ev '^(mysql|information_schema|performance_schema|sys)$'))

    if [ "${#db_list[@]}" -eq 0 ]; then
      echo -e "${RED}找不到可用的資料庫！${RESET}"
      return 1
    fi

    echo "請選擇要授權的資料庫："  
    for i in "${!db_list[@]}"; do
      echo "$((i+1))) ${db_list[i]}"
    done

    while true; do
      read -p "輸入選項號碼 (1-${#db_list[@]}): " choice
      if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#db_list[@]}" ]; then
        dbname="${db_list[$((choice-1))]}"
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
  # --- 決定備份目錄 ---
  case $db_mode in
    mysql) local backup_dir="${2:-/root/mysql_backups}" ;;
    pgsql) local backup_dir="${2:-/root/postgres_backups}" ;;
  esac

  mkdir -p "$backup_dir"

  if [ -z "$dbname" ]; then
    echo -e "${CYAN}選擇要匯出的資料庫：${RESET}"

    if [ "$db_mode" = "mysql" ]; then
      # 取得非系統 DB
      mapfile -t db_list < <(
        "${MYSQL_CMD[@]}" -N -e "
          SELECT schema_name
          FROM information_schema.schemata
          WHERE schema_name NOT IN (
            'mysql','information_schema','performance_schema','sys'
          );
        "
      )
    else
      # PostgreSQL：非 template、非 postgres
      mapfile -t db_list < <(
        "${PSQL_CMD[@]}" -t -A -c "
          SELECT datname
          FROM pg_database
          WHERE datistemplate = false
            AND datname <> 'postgres'
          ORDER BY datname;
        "
      )
    fi

    if [ "${#db_list[@]}" -eq 0 ]; then
      echo -e "${YELLOW}沒有可匯出的資料庫。${RESET}"
      sleep 1
      return 0
    fi

    # 顯示選單
    for i in "${!db_list[@]}"; do
      printf "%3d) %s\n" "$((i+1))" "${db_list[$i]}"
    done

    read -p "請選擇資料庫編號：" choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] \
      || [ "$choice" -lt 1 ] \
      || [ "$choice" -gt "${#db_list[@]}" ]; then
      echo -e "${RED}無效的選擇！${RESET}"
      sleep 1
      return 1
    fi
    dbname="${db_list[$((choice-1))]}"
  fi

  local timestamp=$(date +%Y-%m-%d_%H%M%S)
  local backup_file="${backup_dir}/${dbname}_${timestamp}.sql"
  if [ "$db_mode" = "mysql" ]; then

    # 檢查資料庫是否存在
    if ! "${MYSQL_CMD[@]}" -e "SHOW DATABASES LIKE '$dbname';" | grep -q "$dbname"; then
      echo -e "${RED}資料庫 $dbname 不存在！${RESET}" >&2
      return 1
    fi

    # --- 自動偵測可用 dump 工具 ---
    local DUMP_BIN=""
    for cmd in mariadb-dump mysqldump; do
      if command -v "$cmd" >/dev/null 2>&1; then
        DUMP_BIN="$cmd"
        break
      fi
    done

    if [ -z "$DUMP_BIN" ]; then
      echo -e "${RED}找不到可用的 MySQL/MariaDB 匯出工具（mysqldump / mariadb-dump）。${RESET}" >&2
      sleep 1
      return 1
    fi
    # 取代 MYSQL_CMD 中的 mysql → 將帳密參數複製到 dump
    local DUMP_CMD=("$DUMP_BIN")
    for arg in "${MYSQL_CMD[@]:1}"; do
      DUMP_CMD+=("$arg")
    done

    if "${DUMP_CMD[@]}" "$dbname" > "$backup_file"; then
      echo -e "${GREEN}資料庫 '$dbname' 已成功匯出至：${RESET}" >&2
      echo "$backup_file"
    else
      echo -e "${RED}匯出失敗！${RESET}" >&2
      rm -f "$backup_file"
      return 1
    fi
  elif [ "$db_mode" = "pgsql" ]; then
    if ! "${PSQL_CMD[@]}" -lqt | cut -d \| -f 1 | grep -qw "$dbname"; then
      echo -e "${RED}資料庫 $dbname 不存在！${RESET}"
      sleep 1
      return 1
    fi
    if "${PGDUMP_CMD[@]}" "$dbname" > "$backup_file"; then
      echo -e "${GREEN}資料庫 '$dbname' 已成功匯出至：${RESET}" >&2
      echo "$backup_file"
    else
      echo -e "${RED}匯出失敗！${RESET}" >&2
      rm -f "$backup_file"
      return 1
    fi
  fi
}

# 匯入資料庫
import_database() {
  local backup_dir selected_file target_dbname

  # === 步驟 1: 獲取備份檔案路徑和目標資料庫名稱 ===
  if [ "$cli_mode" = true ]; then
    # CLI 模式: dbname, user, pass, sqlfile
    target_dbname="${1:?錯誤: 請提供目標資料庫名稱}"
    local cli_dbuser="${2:-}" # user/pass 可能是可選的
    local cli_dbpass="${3:-}"
    selected_file="${4:?錯誤: 請提供 .sql 備份檔案的完整路徑}"

    if [ ! -f "$selected_file" ]; then
      echo -e "${RED}錯誤: 備份檔案不存在於 '$selected_file'${RESET}" >&2
      return 1
    fi
  else
    # 互動模式: 引導使用者選擇
    case $db_mode in
      mysql) backup_dir="/root/mysql_backups" ;;
      pgsql) backup_dir="/root/postgres_backups" ;;
    esac

    if [ ! -d "$backup_dir" ] || ! ls "$backup_dir"/*.sql >/dev/null 2>&1; then
      echo -e "${YELLOW}在 '$backup_dir' 中找不到任何 .sql 備份檔。${RESET}" >&2
      return 1
    fi

    mapfile -t backup_files < <(ls -1 "$backup_dir"/*.sql | sort)
    echo -e "${CYAN}請選擇要匯入的備份檔案：${RESET}"
    for i in "${!backup_files[@]}"; do
      printf "%3d) %s\n" "$((i + 1))" "$(basename "${backup_files[$i]}")"
    done
    read -p "請輸入數字編號: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backup_files[@]} )); then
      echo -e "${RED}無效的選擇。${RESET}" >&2; return 1
    fi
    selected_file="${backup_files[$((choice - 1))]}"

    local auto_dbname
    auto_dbname=$(basename "$selected_file" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.sql$//')
    read -p "預計匯入至資料庫 [預設: $auto_dbname]: " target_dbname
    target_dbname="${target_dbname:-$auto_dbname}"
  fi

  # === 步驟 2: 檢查資料庫是否存在，並據此執行不同邏輯 ===
  local db_exists=false
  if [ "$db_mode" = "mysql" ]; then
    if "${MYSQL_CMD[@]}" -sN -e "SELECT 1 FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$target_dbname'" | grep -q "1"; then
      db_exists=true
    fi
  elif [ "$db_mode" = "pgsql" ]; then
    if _filtered_sudo -iu postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$target_dbname'" | grep -q 1; then
      db_exists=true
    fi
  fi

  if [ "$db_exists" = true ]; then
    # --- 資料庫已存在的分支 ---
    echo -e "${YELLOW}警告: 資料庫 '$target_dbname' 已存在，將直接匯入。${RESET}"
    if [ "$cli_mode" = false ]; then
        read -p "這個操作可能會覆蓋現有資料，確定要繼續嗎？ (y/n) " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "操作已取消。"
            return 0
        fi
    fi
  else
    # --- 資料庫不存在的分支 (核心修正點) ---
    echo "資料庫 '$target_dbname' 不存在，將開始建立資料庫與使用者..."
    if [ "$cli_mode" = true ]; then
      # 在 CLI 模式下，需要從參數取得帳密
      if [ -z "$cli_dbuser" ] || [ -z "$cli_dbpass" ]; then
        echo -e "${RED}錯誤: 資料庫不存在時，必須提供使用者名稱和密碼作為第 2 和第 3 個參數。${RESET}" >&2
        return 1
      fi
      # 呼叫 create_database，傳入所有必要參數
      create_database "$target_dbname" "$cli_dbuser" "$cli_dbpass" "n" # "n" for no remote access
    else
      # 在互動模式下，呼叫 create_database 讓它來引導使用者輸入
      create_database "$target_dbname"
    fi
    
    # 檢查 create_database 是否成功 (假設失敗會回傳非 0 值)
    if [ $? -ne 0 ]; then
        echo -e "${RED}建立資料庫或使用者失敗，操作已終止。${RESET}" >&2
        return 1
    fi
  fi

  local import_success=false
  if [ "$db_mode" = "mysql" ]; then
    if "${MYSQL_CMD[@]}" "$target_dbname" < "$selected_file"; then
      import_success=true
    fi
  elif [ "$db_mode" = "pgsql" ]; then
    if _filtered_sudo -iu postgres psql -d "$target_dbname" < "$selected_file" >/dev/null 2>&1; then
      import_success=true
    fi
  fi

  # === 步驟 4: 回報結果 ===
  if $import_success; then
    echo -e "${GREEN}資料庫 '$target_dbname' 匯入成功！${RESET}"
  else
    echo -e "${RED}資料庫 '$target_dbname' 匯入失敗！請檢查錯誤訊息。${RESET}" >&2
    return 1
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
      dnf remove -y mariadb-server
      dnf autoremove -y
    elif [ $system -eq 3 ]; then
      apk del mariadb
    fi
    rm -rf /etc/mysql /var/lib/mysql /etc/mysql-pass.conf /root/mysql_backups
    echo -e "${GREEN}MySQL已成功解除安裝並清除所有相關文件。${RESET}"
    exit 0
    ;;
  pgsql)
    (service postgresql stop 2>/dev/null || service postgresql-17 stop 2>/dev/null)
    if [ $system -eq 1 ]; then
      apt-get purge -y 'postgresql-*'
      apt-get autoremove -y
    elif [ $system -eq 2 ]; then
      dnf remove -y 'postgresql*'
      dnf autoremove -y
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
  if ! [ -t 0 ]; then
    echo -e "${YELLOW}非互動模式${RESET}"
    exit 1
  fi
  local type=$1
  local mysql_ver=""
  local lts_versions=""
  case $type in
  mysql)
    if command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
      if [ "$cli_mode" == false ]; then
        exec dba mysql
      fi
    else
      if [[ $system -eq 1 || $system -eq 2 ]]; then
        lts_versions=$(curl -s https://endoflife.date/api/mariadb.json \
          | jq -r '.[] | select(.lts==true and (.eol | strptime("%Y-%m-%d") | mktime > now)) | .cycle' \
          | sort -Vr)

        # 轉成空白分隔的橫式
        lts_line=$(echo $lts_versions)

        echo "可選擇的 MariaDB LTS 版本：${lts_line}"

        # 讀取用戶輸入
        while true; do
          read -p "請輸入要安裝的版本系列：" ver

          if echo "$lts_versions" | grep -qw "$ver"; then
            mysql_ver=$(curl -s https://endoflife.date/api/mariadb.json \
              | jq -r --arg ver "$ver" '.[] | select(.lts==true and .cycle==$ver) | .latest')
            echo "你選擇的版本系列：$ver，將安裝最新穩定版：$mysql_ver"
            break
          else
            echo "輸入錯誤，請從列表中選擇"
          fi
        done
      fi
      if [ "$system" -eq 1 ]; then
        apt install -y curl gnupg lsb-release jq
          curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
          | bash -s -- --mariadb-server-version="$mysql_ver"
        apt update
        apt install -y mariadb-server
        systemctl enable mariadb
        systemctl start mariadb
      elif [ "$system" -eq 2 ]; then
        dnf install -y curl jq
        curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
        | bash -s -- --mariadb-server-version="$mysql_ver"
        dnf install -y MariaDB-server
        if $selinux_enforcing; then
          [ ! -d /var/log/mariadb ] && mkdir -p /var/log/mariadb && chown mysql:mysql /var/log/mariadb
          semanage fcontext -a -t mysqld_exec_t "/usr/bin/mariadbd" 2>/dev/null || semanage fcontext -m -t mysqld_exec_t "/usr/bin/mariadbd"
          semanage fcontext -a -t mysqld_db_t "/var/lib/mysql(/.*)?" 2>/dev/null
          semanage fcontext -a -t mysqld_log_t "/var/log/mariadb(/.*)?" 2>/dev/null
          restorecon -Rv /usr/sbin/mariadbd /var/lib/mysql /var/log/mariadb >/dev/null
          chmod 700 /var/lib/mysql
          local target_web_users="nginx apache caddy"
          for web_user in $target_web_users; do
            if id "$web_user" >/dev/null 2>&1; then
              setfacl -m u:$web_user:x /var/lib/mysql
              setfacl -d -m u:$web_user:rw /var/lib/mysql
            fi
          done
          setfacl -m g::--- /var/lib/mysql
          setsebool -P httpd_can_network_connect_db 1
        fi
        systemctl enable mariadb
        systemctl start mariadb

      elif [ "$system" -eq 3 ]; then
        apk add mariadb mariadb-client mariadb-openrc
        rc-update add mariadb default
        mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
        service mariadb start
      fi
      [ "$cli_mode" == false ] && exec dba mysql
    fi
    ;;
  pgsql)
    if command -v psql >/dev/null 2>&1; then
      if [ "$cli_mode" == false ]; then
        exec dba pgsql
      fi
    else
      # 動態抓取仍在支援期的主版本
      pg_versions=$(curl -s https://endoflife.date/api/postgresql.json \
        | jq -r '.[] | select(.eol | strptime("%Y-%m-%d") | mktime > now) | .cycle' \
        | sort -Vr)
      pg_line=$(echo $pg_versions)

      echo "可選擇的 PostgreSQL 支援版本：${pg_line}"
      while true; do
        read -p "請輸入要安裝的版本系列：" pg_ver

        if echo "$pg_versions" | grep -qw "$pg_ver"; then
          echo "你選擇的版本系列：$pg_ver，將安裝最新穩定版"
          break
        else
          echo " 輸入錯誤，請從列表中選擇支援版本"
        fi
      done

      if [ "$system" -eq 1 ]; then
        apt install -y gpg wget lsb-release
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc \
          | gpg --dearmor -o /usr/share/keyrings/pgdg-archive-keyring.gpg
        codename=$(lsb_release -c -s)
        echo "deb [signed-by=/usr/share/keyrings/pgdg-archive-keyring.gpg] \
          https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
          | tee /etc/apt/sources.list.d/pgdg.list
        apt update
        apt install -y "postgresql-$pg_ver" "postgresql-client-$pg_ver"
        systemctl enable postgresql
        systemctl start postgresql

      elif [ "$system" -eq 2 ]; then
        major_ver=$(rpm -E %{rhel})
        dnf install -y "https://download.postgresql.org/pub/repos/dnf/reporpms/EL-${major_ver}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
        dnf config-manager --disable pgdg*
        dnf config-manager --enable "pgdg$pg_ver"
        if [ "$major_ver" -ge 8 ]; then
          dnf -qy module disable postgresql
        fi
        dnf install -y "postgresql$pg_ver-server" "postgresql$pg_ver"
          "/usr/pgsql-$pg_ver/bin/postgresql-$pg_ver-setup" initdb
        systemctl enable "postgresql-$pg_ver"
        systemctl start "postgresql-$pg_ver"
        if $selinux_enforcing; then
          setsebool -P httpd_can_network_connect_db 1
        fi

      elif [ "$system" -eq 3 ]; then
        echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories
        apk update
        apk add --no-cache \
          "postgresql$pg_ver" \
          "postgresql$pg_ver-client" \
          "postgresql$pg_ver-contrib" \
          "postgresql$pg_ver-openrc"

        mkdir -p /run/postgresql
        chown postgres:postgres /run/postgresql
        install -d -m0700 -o postgres -g postgres /var/lib/postgresql/data
        su - postgres -c "/usr/bin/initdb -D /var/lib/postgresql/data"
        rc-update add postgresql default
        rc-service postgresql start
      fi

      echo -e "${GREEN}PostgreSQL 已安裝完成。${RESET}" >&2
      [ "$cli_mode" == false ] && exec dba pgsql
    fi
    ;;
  esac
}


show_postgres_info(){
  display_width() {
    local str="$1"
    local clean_str=$(echo -e "$str" | sed "s/\x1B\[[0-9;]*[mK]//g")
    local width=0; local i=0
    while [ $i -lt ${#clean_str} ]; do
      local char="${clean_str:$i:1}"
      if [[ $(printf "%d" "'$char") -gt 127 ]] 2>/dev/null; then
        width=$((width + 2))
      else
        width=$((width + 1))
      fi
      i=$((i + 1))
    done
    echo $width
  }

  echo -e "\n${CYAN}目 前 資 料 庫 與 用 戶 狀 態 ：${RESET}"

  # --- 階段一：收集所有需要顯示的資料 ---
  
  # 優化 SQL 查詢：
  # 1. 使用 COALESCE 處理 NULL，直接輸出 '無'，讓邏輯更清晰。
  local db_info_query="
    SELECT
      d.datname,
      r.rolname,
      COALESCE(
        (SELECT string_agg(u.rolname, ', ')
         FROM pg_roles u
         WHERE has_database_privilege(u.rolname, d.datname, 'CONNECT')
           AND u.rolname NOT LIKE 'pg_%'
           AND u.rolname != 'postgres'
           AND u.rolname != r.rolname),
        '無'
      )
    FROM pg_database d
    JOIN pg_roles r ON d.datdba = r.oid
    WHERE d.datistemplate = false AND d.datname <> 'postgres'
    ORDER BY d.datname;
  "

  local -a data_rows
  # 使用進程替換，避免 subshell 問題
  # 使用 psql 的 -t -A -F'|' 選項，獲得乾淨、無標頭、以'|'分隔的輸出
  while IFS='|' read -r db owner users; do
    # 去除可能存在的前後空白
    db=$(echo "$db" | xargs)
    owner=$(echo "$owner" | xargs)
    users=$(echo "$users" | xargs)
    data_rows+=("$db|$owner|$users")
  done < <("${PSQL_CMD[@]}" -t -A -F'|' -c "$db_info_query")

  if [ ${#data_rows[@]} -eq 0 ]; then
    echo -e "${YELLOW}  尚 無 自 訂 資 料 庫。${RESET}"
  else
    # --- 階段二：計算各欄位的最大寬度 ---
    local headers=("資 料 庫 名 稱" "擁 有 者" "其 他 可 存 取 用 戶")
    local -a max_widths=()
    max_widths[0]=$(display_width "${headers[0]}")
    max_widths[1]=$(display_width "${headers[1]}")
    max_widths[2]=$(display_width "${headers[2]}")

    for row in "${data_rows[@]}"; do
      IFS='|' read -r db owner users <<< "$row"
      local db_width=$(display_width "$db")
      local owner_width=$(display_width "$owner")
      local users_width=$(display_width "$users")

      if [[ $db_width -gt ${max_widths[0]} ]]; then max_widths[0]=$db_width; fi
      if [[ $owner_width -gt ${max_widths[1]} ]]; then max_widths[1]=$owner_width; fi
      if [[ $users_width -gt ${max_widths[2]} ]]; then max_widths[2]=$users_width; fi
    done

    # --- 階段三：根據計算好的寬度，格式化輸出 ---
    local total_width=$((max_widths[0] + max_widths[1] + max_widths[2] + 6)) # +6 for " | " x 2
    local separator=$(printf '%.0s-' $(seq 1 $total_width))
    
    echo -e "\033[1;34m$separator\033[0m"
    
    # 輸出標頭
    local h_col1="${headers[0]}"; local p1=$((max_widths[0] - $(display_width "$h_col1"))); h_col1+=$(printf "%*s" $p1 "")
    local h_col2="${headers[1]}"; local p2=$((max_widths[1] - $(display_width "$h_col2"))); h_col2+=$(printf "%*s" $p2 "")
    local h_col3="${headers[2]}"; local p3=$((max_widths[2] - $(display_width "$h_col3"))); h_col3+=$(printf "%*s" $p3 "")
    echo -e "$h_col1 | $h_col2 | $h_col3"

    echo -e "\033[1;34m$separator\033[0m"

    # 輸出資料
    for row in "${data_rows[@]}"; do
      IFS='|' read -r db owner users <<< "$row"
      local col1="$db"; local pad1=$((max_widths[0] - $(display_width "$col1"))); col1+=$(printf "%*s" $pad1 "")
      local col2="$owner"; local pad2=$((max_widths[1] - $(display_width "$col2"))); col2+=$(printf "%*s" $pad2 "")
      local col3="$users"; local pad3=$((max_widths[2] - $(display_width "$col3"))); col3+=$(printf "%*s" $pad3 "")
      echo -e "$col1 | $col2 | $col3"
    done
    
    echo -e "\033[1;34m$separator\033[0m"
  fi

  # 任務完成後，立即刪除輔助函式
  unset -f display_width
  
  # 所有用戶
  local all_users_query="
    SELECT rolname
    FROM pg_roles
    WHERE rolcanlogin = true
      AND rolname NOT IN (
        'postgres',
        'pg_signal_backend',
        'pg_read_all_data',
        'pg_write_all_data',
        'pg_monitor',
        'pg_read_all_stats'
      )
      AND rolname NOT LIKE 'pg_%'
    ORDER BY rolname;
  "
  local all_users=$("${PSQL_CMD[@]}" -t -A -c "$all_users_query")

  # 轉成同一行字符串
  local all_users_line=$(echo "$all_users" | tr '\n' ' ' | sed 's/ $//')
  local all_users_line=$(echo "$all_users" | tr '\n' ' ' | sed 's/ $//')
  
  echo -e "\n${CYAN}所 有 用 戶 列 表：${RESET}${all_users_line}"

  # --- 處理孤立用戶 (這部分邏輯不變，只是格式化輸出) ---
  local orphan_users_query="
    SELECT r.rolname
    FROM pg_roles r
    WHERE r.rolcanlogin = true
      AND r.rolsuper = false
      AND r.rolname NOT LIKE 'pg_%'
      AND r.rolname NOT IN (
        'postgres',
        'pg_signal_backend',
        'pg_read_all_data',
        'pg_write_all_data',
        'pg_monitor',
        'pg_read_all_stats'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_database d
        WHERE d.datistemplate = false
          AND d.datname <> 'postgres'
          AND has_database_privilege(r.rolname, d.datname, 'CONNECT')
      )
    ORDER BY r.rolname;
  "

  local orphan_users=$("${PSQL_CMD[@]}" -t -A -c "$orphan_users_query")

  if [ -n "$orphan_users" ]; then
    # 轉橫排
    local orphan_line=$(echo "$orphan_users" | tr '\n' ' ' | sed 's/ $//')
    echo -e "\n${RED}警告：孤立用戶（無任何資料庫 CONNECT 權限）：${RESET}${orphan_line}"
  fi
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
  # --- 排版輔助函式 (處理中英文對齊) ---
  display_width() {
    local str="$1"
    # 先移除 ANSI 顏色代碼，再計算寬度
    local clean_str=$(echo -e "$str" | sed "s/\x1B\[[0-9;]*[mK]//g")
    local width=0
    local i=0
    while [ $i -lt ${#clean_str} ]; do
      local char="${clean_str:$i:1}"
      if [[ $(printf "%d" "'$char") -gt 127 ]] 2>/dev/null; then
        width=$((width + 2))
      else
        width=$((width + 1))
      fi
      i=$((i + 1))
    done
    echo $width
  }

  echo -e "\n${CYAN}目 前 資 料 庫 與 用 戶 狀 態 ：${RESET}"

  # --- 階段一：收集所有需要顯示的資料 ---

  local all_dbs
  all_dbs=$("${MYSQL_CMD[@]}" -N -e "
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');
  ")

  declare -A db_has_user
  while IFS=$'\t' read -r db users; do
    db_has_user["$db"]="$users"
  done < <("${MYSQL_CMD[@]}" -N -e "
    SELECT db, GROUP_CONCAT(DISTINCT user SEPARATOR ', ')
    FROM mysql.db
    WHERE db NOT IN ('mysql','information_schema','performance_schema','sys')
    GROUP BY db;
  ")

  local -a data_rows
  if [ -z "$all_dbs" ]; then
    echo -e "${YELLOW}  尚 無 自 訂 資 料 庫。${RESET}"
  else
    while read -r db; do
      local users="${db_has_user["$db"]}"
      if [[ -z "$users" || "$users" == "NULL" ]]; then
        data_rows+=("$db|${RED}無任何授權 (孤立資料庫)${RESET}")
      else
        data_rows+=("$db|$users")
      fi
    done < <(echo "$all_dbs" | sed '/^\s*$/d') 
  fi
  
  # 如果沒有任何自訂資料庫，後續的渲染就不需要執行
  if [ ${#data_rows[@]} -eq 0 ] && [ -n "$all_dbs" ]; then
      # 這種情況很少見，但以防萬一
      echo -e "${YELLOW}  無法解析資料庫列表。${RESET}"
      return
  elif [ ${#data_rows[@]} -eq 0 ]; then
      # 這是沒有資料庫的正常情況，前面已經提示過，直接結束
      return
  fi


  # --- 階段二：計算各欄位的最大寬度 ---

  local headers=("資 料 庫 名 稱" "可 存 取 用 戶")
  local -a max_widths=()
  max_widths[0]=$(display_width "${headers[0]}")
  max_widths[1]=$(display_width "${headers[1]}")

  for row in "${data_rows[@]}"; do
    IFS='|' read -r db users <<< "$row"
    local db_width=$(display_width "$db")
    local users_width=$(display_width "$users")

    if [[ $db_width -gt ${max_widths[0]} ]]; then
      max_widths[0]=$db_width
    fi
    if [[ $users_width -gt ${max_widths[1]} ]]; then
      max_widths[1]=$users_width
    fi
  done

  # --- 階段三：根據計算好的寬度，格式化輸出 ---

  local total_width=$((max_widths[0] + max_widths[1] + 3)) # +3 for " | "
  local separator
  separator=$(printf '%.0s-' $(seq 1 $total_width))
  
  echo -e "\033[1;34m$separator\033[0m"
  
  # 輸出標頭
  local header_col1="${headers[0]}"
  local header_col1_padding=$((max_widths[0] - $(display_width "$header_col1")))
  header_col1+=$(printf "%*s" $header_col1_padding "")
  
  local header_col2="${headers[1]}"
  local header_col2_padding=$((max_widths[1] - $(display_width "$header_col2")))
  header_col2+=$(printf "%*s" $header_col2_padding "")
  
  echo -e "$header_col1 | $header_col2"
  echo -e "\033[1;34m$separator\033[0m"

  # 輸出資料
  for row in "${data_rows[@]}"; do
    IFS='|' read -r db users <<< "$row"
    
    local col1="$db"
    local col1_padding=$((max_widths[0] - $(display_width "$col1")))
    col1+=$(printf "%*s" $col1_padding "")
    
    local col2="$users"
    local col2_padding=$((max_widths[1] - $(display_width "$col2")))
    col2+=$(printf "%*s" $col2_padding "")
    
    echo -e "$col1 | $col2"
  done
  unset -f display_width
  
  # 所有用戶
  local all_users=$("${MYSQL_CMD[@]}" -N -e "
    SELECT DISTINCT user
    FROM mysql.user
    WHERE user NOT IN (
      'mysql.session',
      'mysql.sys',
      'debian-sys-maint',
      'mysql',
      'mariadb.sys',
      'root'
    )
    ORDER BY user;
  ")

  if [ -n "$all_users" ]; then
      local all_users_line
      all_users_line=$(echo "$all_users" | tr '\n' ' ' | sed 's/ $//')
      echo -e "${CYAN}所 有 用 戶 列 表：${RESET} ${all_users_line}"
  fi

  # --- 處理孤立用戶 (邏輯不變) ---
  local orphan_users=$("${MYSQL_CMD[@]}" -N -e "
    SELECT CONCAT(user, '@', host)
    FROM mysql.user AS u
    WHERE
      -- 排除空帳號與系統帳號
      user <> ''
      AND user NOT IN ('mysql.session','mysql.sys','debian-sys-maint','mysql','mariadb.sys')
    
      -- 沒有資料庫權限
      AND CONCAT(user, '@', host) NOT IN (
        SELECT DISTINCT CONCAT(user, '@', host) FROM mysql.db
      )

      -- 沒有全域權限（全部 = 'N'）
      AND NOT EXISTS (
        SELECT 1
        FROM mysql.user AS uu
        WHERE uu.user = u.user AND uu.host = u.host
        AND (
          uu.Select_priv = 'Y' OR uu.Insert_priv = 'Y' OR uu.Update_priv = 'Y' OR
          uu.Delete_priv = 'Y' OR uu.Create_priv = 'Y' OR uu.Drop_priv = 'Y' OR
          uu.Reload_priv = 'Y' OR uu.Shutdown_priv = 'Y' OR uu.Process_priv = 'Y' OR
          uu.File_priv = 'Y' OR uu.Grant_priv = 'Y' OR uu.References_priv = 'Y' OR
          uu.Index_priv = 'Y' OR uu.Alter_priv = 'Y' OR uu.Show_db_priv = 'Y' OR
          uu.Super_priv = 'Y' OR uu.Create_tmp_table_priv = 'Y' OR uu.Lock_tables_priv = 'Y' OR
          uu.Create_view_priv = 'Y' OR uu.Show_view_priv = 'Y' OR uu.Create_routine_priv = 'Y' OR
          uu.Alter_routine_priv = 'Y' OR uu.Execute_priv = 'Y' OR uu.Event_priv = 'Y' OR
          uu.Trigger_priv = 'Y'
        )
      )
    ORDER BY user, host;
  ")

  if [ -n "$orphan_users" ]; then
      local orphan_line
      orphan_line=$(echo "$orphan_users" | tr '\n' ' ' | sed 's/ $//')
      echo -e "\n${RED}警告：孤立用戶（沒有任何資料庫授權）：${RESET} ${orphan_line}"
  fi
}

update_script() {
  local download_url="https://gitlab.com/gebu8f/sh/-/raw/main/db/dba.sh"
  local temp_path="/tmp/dba.sh"
  local current_script="/usr/local/bin/dba"
  local current_path="$0"

  wget -q "$download_url" -O "$temp_path"
  if [ $? -ne 0 ]; then
    echo -e "${RED}無法下載最新版本，請檢查網路連線。${RESET}"
    return
  fi

  # 比較檔案差異
  if [ -f "$current_script" ]; then
    if diff "$current_script" "$temp_path" >/dev/null; then
      rm -f "$temp_path"
      return
    fi
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
      echo "11. 安裝及管理PostgreSQL"
      echo "12. 安裝管理工具phpmyadmin（須有docker和超級用戶）"
    elif [ $db_mode = pgsql ]; then
      echo "10. 解除安裝PostgreSQL"
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
      deploy_webui
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

if [[ $# -gt 0 ]]; then
  if [[ ($1 == "mysql" || $1 == "pgsql") && "$2" != "install" ]]; then
    check_cli_db $1
  fi
  cli_mode=true
fi
case "$1" in
  mysql|pgsql)
    case "$2" in
    install)
      install_database $1
      exit 0
      ;;
    add)
      dbname=$3
      dbuser=$4
      skip=$5
      [[ "$skip" == "--force" ]] && skip=y
      pass=${6:-$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')}
      create_database "$dbname" "$dbuser" "$pass" "$skip" 
      echo $pass
      exit 0
      ;;
    del)
      dbname=$3
      skip=$4
      [[ "$skip" == "--force" ]] && skip=y
      remove_database "$dbname" "$skip"
      exit 0
      ;;
    "export")
      dbname=$3
      path=$4
      export_database "$dbname" "$path"
      exit
      ;;
    "import")
      dbname=$3
      dbuser=$4
      dbpass=$5
      path=$6
      import_database "$dbname" "$dbuser" "$dbpass" "$path"
      exit
      ;;
    *)
      db_mode=$1
      show_menu
      ;;
    esac
    ;;
  install_script)
    exit 0
    ;;
esac
check_db
