#!/usr/bin/env bash
# Server Service Manager
# 统一管理 Docker Compose 服务和少量独立应用（可移植，支持任意服务器）

set -euo pipefail

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success()  { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warning()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()    { echo -e "${RED}[ERR]${NC} $1"; }
print_header()   { echo -e "\n${CYAN}${BOLD}$1${NC}"; }

check_root() {
  [ "$(id -u)" -eq 0 ] || { print_error "请使用 root 权限运行。"; exit 1; }
}

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

COMPOSE_CMD=$(detect_compose_cmd)
[ -z "$COMPOSE_CMD" ] && print_warning "未检测到 Docker Compose；Docker 服务管理不可用。"

require_compose() {
  [ -n "$COMPOSE_CMD" ] || { print_error "未检测到 Docker Compose，无法执行该 Docker 服务操作。"; return 1; }
}

# ===== Service Definitions =====
# Format: name|dir|display_name|backup_items

CONF_FILE="/opt/server-manager.conf"

declare -a SERVICES=(
  "postgres|/opt/postgres|PostgreSQL|data,docker-compose.yml"
  "newapi|/opt/newapi|NewAPI|data,docker-compose.yml"
  "metapi|/root/metapi|MetaPI|data,docker-compose.yml,.env"
  "cliproxy|/opt/cliproxy|CLIProxyAPI|config.yaml,auths,logs,docker-compose.yml"
  "axonhub|/opt/axonhub|AxonHub|config.yml,docker-compose.yml"
  "9router|/opt/9router|9Router|data,usage,logs,docker-compose.yml,.env"
  "litellm|/opt/litellm|LiteLLM|config.yaml,docker-compose.yml,.env"
)

if [ -f "$CONF_FILE" ]; then
  SERVICES=()
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -n "$line" ] && SERVICES+=("$line")
  done < "$CONF_FILE"
  print_info "已从 $CONF_FILE 加载 ${#SERVICES[@]} 个服务定义。"
fi

BACKUP_BASE="/var/backups"

# ===== Shared PostgreSQL Settings =====
PG_CONTAINER="${PG_CONTAINER_NAME:-shared-postgres}"
PG_NETWORK="${PG_NETWORK:-postgres_default}"
PG_CONF_FILE="/etc/server-manager-pg.conf"
PG_USER="${PG_USER:-}"
PG_PASSWORD="${PG_PASSWORD:-}"

# 对密码中的特殊字符做 URL 编码（用于 PostgreSQL URI）
url_encode() {
  local str="$1" encoded="" c
  local i=0 len=${#str}
  while [ "$i" -lt "$len" ]; do
    c="${str:$i:1}"
    case "$c" in
      [a-zA-Z0-9_.~-]) encoded+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; encoded+="$hex" ;;
    esac
    i=$((i + 1))
  done
  echo "$encoded"
}

# 转义 YAML 双引号字符串中的特殊字符（\ 和 "）
yaml_dquote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  echo "$s"
}

# 转义 PostgreSQL key=value DSN 中的值，避免密码包含空格、引号或反斜杠时解析失败
pg_kv_dsn_value() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf "'%s'" "$s"
}

pg_kv_dsn_unescape() {
  local s="$1" out="" c
  local i=0 len=${#s}
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ "$c" = "\\" ] && [ $((i + 1)) -lt "$len" ]; then
      i=$((i + 1))
      out+="${s:$i:1}"
    else
      out+="$c"
    fi
    i=$((i + 1))
  done
  echo "$out"
}

pg_sql_literal() {
  local s="$1"
  s="${s//\'/''}"
  printf "'%s'" "$s"
}

pg_sql_identifier() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

_random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 || true
  fi
}

_prompt_secret_value() {
  local prompt="$1" default_value="$2" input_value=""
  if [ -t 0 ] || [ -t 1 ]; then
    { read -r -p "  $prompt [$default_value]: " input_value < /dev/tty; } 2>/dev/null || input_value=""
  else
    print_warning "无法读取交互终端，$prompt 将使用自动生成值。" >&2
  fi
  echo "${input_value:-$default_value}"
}

detect_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -fsS --max-time 3 https://ifconfig.me/ip 2>/dev/null || true)
  elif command -v wget >/dev/null 2>&1; then
    ip=$(wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)
  fi
  case "$ip" in
    *[!0-9.]*|"") echo "" ;;
    *) echo "$ip" ;;
  esac
}

print_access_info() {
  local port="$1" lan_ip="$2" public_ip="$3" service_name="${4:-}" network_name="${5:-}"
  [ -n "$lan_ip" ] && echo "  局域网访问: http://${lan_ip}:${port}"
  [ -n "$public_ip" ] && echo "  公网访问: http://${public_ip}:${port}" || echo "  公网访问: 未检测到公网 IP，请用服务器公网 IP + 端口访问"
  if [ -n "$service_name" ] && [ -n "$network_name" ]; then
    echo "  同 Docker 网络访问: http://${service_name}:${port}（调用方容器需连接 ${network_name}）"
  fi
}

# 检查任意 PostgreSQL 容器是否在运行（不限容器名，用作迁移兼容）
_any_pg_running() {
  docker ps --format '{{.Image}} {{.Names}}' 2>/dev/null | grep -qiE 'postgres'
}

# pg_installed: 检查 PostgreSQL 是否存在（独立 compose、共享容器或旧版内嵌容器）
pg_installed() {
  [ -f "/opt/postgres/docker-compose.yml" ] && return 0
  pg_available && return 0
  _any_pg_running && return 0
  return 1
}

pg_compose_installed() {
  [ -f "/opt/postgres/docker-compose.yml" ]
}

# 从持久化文件加载凭据（优先级低于环境变量）
_load_pg_conf() {
  if [ -f "$PG_CONF_FILE" ] && [ -z "${PG_USER:-}" ] && [ -z "${PG_PASSWORD:-}" ]; then
    . "$PG_CONF_FILE"
  fi
}

# 从任意运行中的 PG 容器探测用户名和密码
_probe_pg_from_running() {
  _any_pg_running || return 1

  # 找到一个运行中的 postgres 容器
  local pg_cid
  pg_cid=$(docker ps --filter "ancestor=postgres" --format '{{.ID}}' 2>/dev/null | head -1)
  [ -z "$pg_cid" ] && pg_cid=$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | grep -i postgres | head -1 | awk '{print $1}')
  [ -z "$pg_cid" ] && return 1

  # 读取容器内的环境变量
  local env_str
  env_str=$(docker exec "$pg_cid" env 2>/dev/null || true)
  if [ -z "$env_str" ]; then
    env_str=$(docker inspect "$pg_cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)
  fi

  local probed_user probed_pass
  probed_user=$(echo "$env_str" | grep '^POSTGRES_USER=' | head -1 | cut -d'=' -f2-)
  probed_pass=$(echo "$env_str" | grep '^POSTGRES_PASSWORD=' | head -1 | cut -d'=' -f2-)

  if [ -n "$probed_user" ] && [ -n "$probed_pass" ]; then
    PG_USER="$probed_user"
    PG_PASSWORD="$probed_pass"
    return 0
  fi
  return 1
}

# 交互式收集 PostgreSQL 凭据
_prompt_pg_credentials() {
  echo ""
  echo "=============================================="
  echo "     配置共享 PostgreSQL 数据库凭据"
  echo "=============================================="
  echo ""
  echo "  该凭据用于创建和管理所有服务所需的 PostgreSQL 数据库。"
  echo "  所有需要数据库的服务将共用这一个 PostgreSQL 实例。"
  echo ""

  # 尝试自动探测已有凭据
  if _probe_pg_from_running; then
    echo "  已从运行中的 PostgreSQL 容器自动探测到凭据。"
    echo "  用户名: $PG_USER"
    echo ""
    local use_probed=""
    read -r -p "  使用探测到的凭据？[Y/n]: " use_probed < /dev/tty
    if [[ "$use_probed" =~ ^[Nn]$ ]]; then
      PG_USER=""
      PG_PASSWORD=""
    else
      _save_pg_credentials
      return 0
    fi
  fi

  local input_user input_pass
  read -r -p "  数据库用户名: " input_user < /dev/tty
  while [ -z "$input_user" ]; do
    echo "  用户名不能为空。"
    read -r -p "  数据库用户名: " input_user < /dev/tty
  done

  read -r -s -p "  数据库密码: " input_pass < /dev/tty
  echo ""
  while [ -z "$input_pass" ]; do
    echo "  密码不能为空。"
    read -r -s -p "  数据库密码: " input_pass < /dev/tty
    echo ""
  done

  PG_USER="$input_user"
  PG_PASSWORD="$input_pass"
  _save_pg_credentials
}

_save_pg_credentials() {
  local save=""
  echo ""
  read -r -p "  是否保存到 $PG_CONF_FILE 以便下次自动加载？[Y/n]: " save < /dev/tty
  if [[ ! "$save" =~ ^[Nn]$ ]]; then
    printf '# Server Manager — PostgreSQL 凭据（自动生成，权限 600）\n' > "$PG_CONF_FILE"
    printf 'PG_USER=%q\n' "$PG_USER" >> "$PG_CONF_FILE"
    printf 'PG_PASSWORD=%q\n' "$PG_PASSWORD" >> "$PG_CONF_FILE"
    chmod 600 "$PG_CONF_FILE"
    print_success "凭据已保存到 $PG_CONF_FILE"
  fi
}

check_pg_credentials() {
  _load_pg_conf

  if [ -n "$PG_USER" ] && [ -n "$PG_PASSWORD" ]; then
    return 0
  fi

  _prompt_pg_credentials

  if [ -z "$PG_USER" ] || [ -z "$PG_PASSWORD" ]; then
    return 1
  fi
  return 0
}

# 检测 docker-compose.yml 是否为旧版（内嵌 postgres 服务，需要迁移）
_is_legacy_compose() {
  local compose_file="$1"
  [ -f "$compose_file" ] || return 1
  grep -qE '^[[:space:]]*postgres:' "$compose_file" 2>/dev/null
}

_newapi_image_needs_latest_patch() {
  local compose_file="$1"
  [ -f "$compose_file" ] || return 1
  grep -q 'calciumion/new-api:' "$compose_file" || return 1
  ! grep -qE '^[[:space:]]*image:[[:space:]]*"?calciumion/new-api:latest"?[[:space:]]*$' "$compose_file"
}

_patch_newapi_image_to_latest() {
  local dir="$1" compose_file="$dir/docker-compose.yml"
  [ -f "$compose_file" ] || return 1

  if ! _newapi_image_needs_latest_patch "$compose_file"; then
    return 0
  fi

  local bak="${compose_file}.bak.$(date +%Y%m%d-%H%M%S)"
  local tmp="${compose_file}.tmp.$$"
  cp "$compose_file" "$bak"

  awk '
    /^[[:space:]]*image:/ && /calciumion\/new-api:/ {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) "image: calciumion/new-api:latest"
      next
    }
    { print }
  ' "$bak" > "$tmp"
  mv "$tmp" "$compose_file"

  print_warning "检测到 NewAPI 使用非 latest 镜像，已按官方部署文档改为 calciumion/new-api:latest。"
  print_info "原配置已备份到 $bak"
}

# ===== Utility Functions =====

get_service_field() {
  local idx="$1" field="$2"
  echo "${SERVICES[$idx]}" | cut -d'|' -f"$field"
}

find_service_idx() {
  local key="$1"
  for i in "${!SERVICES[@]}"; do
    [ "$(get_service_field "$i" 1)" = "$key" ] && echo "$i" && return 0
  done
  return 1
}

compose_in() {
  local dir="$1"; shift
  require_compose || return 1
  (cd "$dir" && $COMPOSE_CMD "$@")
}

is_installed() {
  [ -f "$1/docker-compose.yml" ]
}

is_running() {
  [ -n "$COMPOSE_CMD" ] || return 1
  (cd "$1" && $COMPOSE_CMD ps --format "{{.Status}}" 2>/dev/null | grep -q "Up")
}

is_restarting() {
  [ -n "$COMPOSE_CMD" ] || return 1
  (cd "$1" && $COMPOSE_CMD ps --format "{{.Status}}" 2>/dev/null | grep -q "Restarting")
}

pg_available() {
  docker inspect "$PG_CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q "true"
}

start_and_verify() {
  local dir="$1" display="$2"

  compose_in "$dir" up -d
  reconnect_networks

  sleep 5

  if is_running "$dir"; then
    return 0
  fi

  if is_restarting "$dir"; then
    sleep 10
    if is_running "$dir"; then
      return 0
    fi
  fi

  local status_line
  status_line=$(cd "$dir" && $COMPOSE_CMD ps --format "{{.Status}}" 2>/dev/null | head -1)
  print_error "$display 启动后未能正常运行（状态: $status_line）"
  echo ""
  print_info "最近日志:"
  compose_in "$dir" logs --tail 30 2>/dev/null || true
  return 1
}

# ===== Network Auto-Detection & Reconnect =====

reconnect_networks() {
  print_info "检查跨服务网络连接..."

  for svc in "${SERVICES[@]}"; do
    local dir
    dir=$(echo "$svc" | cut -d'|' -f2)
    local compose_file="$dir/docker-compose.yml"
    [ -f "$compose_file" ] || continue

    local ext_networks_str
    ext_networks_str=$(awk '
      function ltrim(s){ sub(/^[[:space:]]+/, "", s); return s }
      function rtrim(s){ sub(/[[:space:]]+$/, "", s); return s }
      function indent_of(s,    i){ i = match(s, /[^ ]/); return (i ? i-1 : 0) }
      function flush_net() {
        if (cur_name != "" && cur_external == 1) {
          print (cur_real != "" ? cur_real : cur_name)
        }
        cur_name=""; cur_real=""; cur_external=0
      }
      BEGIN { in_net=0; base=-1 }
      {
        line=$0
        stripped=ltrim(line); sub(/#.*$/, "", stripped); stripped=rtrim(stripped)
        if (stripped == "") next

        ind = indent_of(line)

        if (ind == 0 && stripped ~ /^networks:[[:space:]]*$/) {
          flush_net(); in_net=1; base=-1; next
        }

        if (!in_net) next

        if (ind == 0 && stripped !~ /^-/) {
          flush_net(); in_net=0; next
        }

        if (base < 0 || ind == base) {
          if (stripped ~ /:[[:space:]]*({})?[[:space:]]*$/) {
            flush_net()
            base = ind
            n = stripped
            sub(/:.*$/, "", n)
            cur_name = n
            next
          }
        }

        if (ind > base) {
          if (stripped ~ /^external:[[:space:]]*true[[:space:]]*$/) {
            cur_external = 1
          } else if (stripped ~ /^name:[[:space:]]*/) {
            v = stripped
            sub(/^name:[[:space:]]*/, "", v)
            gsub(/^["\x27]|["\x27]$/, "", v)
            cur_real = v
          }
        }
      }
      END { flush_net() }
    ' "$compose_file")

    [ -z "$ext_networks_str" ] && continue

    local ext_networks=()
    while IFS= read -r n; do
      [ -n "$n" ] && ext_networks+=("$n")
    done <<< "$ext_networks_str"

    [ ${#ext_networks[@]} -eq 0 ] && continue

    local containers
    containers=$(cd "$dir" && $COMPOSE_CMD ps -q 2>/dev/null) || continue
    [ -z "$containers" ] && continue

    for cid in $containers; do
      local cname
      cname=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's/^\///')
      [ -z "$cname" ] && continue

      local current_nets
      current_nets=$(docker inspect "$cid" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)

      for net in "${ext_networks[@]}"; do
        if ! echo "$current_nets" | grep -qw "$net"; then
          if docker network inspect "$net" >/dev/null 2>&1; then
            docker network connect "$net" "$cname" 2>/dev/null && \
              print_info "  已连接 $cname -> $net" || true
          else
            print_warning "  网络 $net 不存在（依赖服务可能未启动），跳过 $cname"
          fi
        fi
      done
    done
  done
}

# ===== Legacy Migration =====
# 从旧版 docker-compose.yml（内嵌 postgres）迁移到共享 PostgreSQL 架构

_abs_path() {
  local path="$1"
  case "$path" in
    /*) echo "$path" ;;
    *) echo "$(pwd)/$path" ;;
  esac
}

_find_legacy_pg_data_mount() {
  local dir="$1" old_container="$2" data_mount=""

  if [ -n "$old_container" ] && docker inspect "$old_container" >/dev/null 2>&1; then
    data_mount=$(docker inspect "$old_container" \
      --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
  fi

  if [ -z "$data_mount" ] && [ -d "${dir}/postgres" ]; then
    data_mount=$(_abs_path "${dir}/postgres")
  fi

  if [ -z "$data_mount" ] && [ -d "/opt/postgres/data" ]; then
    data_mount="/opt/postgres/data"
  fi

  echo "$data_mount"
}

_write_postgres_compose_with_mount() {
  local data_mount="$1"
  mkdir -p /opt/postgres

  cat > "/opt/postgres/docker-compose.yml" <<AUTOGEN_EOF
# 共享 PostgreSQL 服务 (adopted by server-manager)
services:
  postgres:
    image: postgres:15-alpine
    container_name: ${PG_CONTAINER}
    restart: always
    environment:
      POSTGRES_USER: "$(yaml_dquote "$PG_USER")"
      POSTGRES_PASSWORD: "$(yaml_dquote "$PG_PASSWORD")"
    volumes:
      - "${data_mount}:/var/lib/postgresql/data"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \"$(yaml_dquote "$PG_USER")\" -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
    ports:
      - "5432:5432"
AUTOGEN_EOF
}

migrate_legacy_newapi() {
  local dir="$1"

  if ! _is_legacy_compose "$dir/docker-compose.yml"; then
    return 0
  fi

  print_header "检测到旧版 NewAPI 配置（内嵌 PostgreSQL）"

  echo "  当前配置将 PostgreSQL 和 NewAPI 放在同一个 docker-compose.yml 中。"
  echo "  新版本会改为独立共享 PostgreSQL，但不会删除或移动原数据库文件。"
  echo "  迁移前会备份旧 docker-compose.yml，并尽量复用旧 PostgreSQL 数据目录。"
  echo ""

  local do_migrate=""
  read -r -p "  是否迁移到新架构？[Y/n]: " do_migrate < /dev/tty
  if [[ "$do_migrate" =~ ^[Nn]$ ]]; then
    print_info "跳过迁移，继续使用旧配置。"
    print_warning "注意：旧镜像 calciumion/new-api:fixed-quota 可能已不可用。"
    return 0
  fi

  local bak="${dir}/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$dir/docker-compose.yml" "$bak"
  print_info "旧配置已备份到 $bak"

  local old_user old_pass old_container data_mount
  old_user=$(grep -E 'POSTGRES_USER' "$bak" | head -1 | sed -E 's/.*POSTGRES_USER[=:]\s*//' | tr -d '"' | xargs)
  old_pass=$(grep -E 'POSTGRES_PASSWORD' "$bak" | head -1 | sed -E 's/.*POSTGRES_PASSWORD[=:]\s*//' | tr -d '"' | xargs)
  old_container=$(grep -E 'container_name.*postgres' "$bak" | head -1 | sed -E 's/.*container_name:\s*//' | xargs)
  [ -z "$old_container" ] && old_container=$(cd "$dir" && $COMPOSE_CMD ps -q postgres 2>/dev/null | xargs -r docker inspect --format '{{.Name}}' 2>/dev/null | sed 's#^/##' | head -1 || true)

  if [ -n "$old_user" ] && [ -n "$old_pass" ]; then
    PG_USER="$old_user"
    PG_PASSWORD="$old_pass"
    printf '# Server Manager — PostgreSQL 凭据（迁移自旧版 NewAPI）\n' > "$PG_CONF_FILE"
    printf 'PG_USER=%q\n' "$PG_USER" >> "$PG_CONF_FILE"
    printf 'PG_PASSWORD=%q\n' "$PG_PASSWORD" >> "$PG_CONF_FILE"
    chmod 600 "$PG_CONF_FILE"
    print_info "已提取旧版 PostgreSQL 凭据并保存。"
  else
    print_warning "无法从旧配置提取 PostgreSQL 凭据，将使用交互式配置。"
    check_pg_credentials || return 1
  fi

  data_mount=$(_find_legacy_pg_data_mount "$dir" "$old_container")
  if [ -z "$data_mount" ]; then
    print_error "无法定位旧 PostgreSQL 数据目录，已中止迁移以避免创建空数据库。"
    print_info "旧配置备份: $bak"
    return 1
  fi
  print_info "将原地复用 PostgreSQL 数据目录: $data_mount"

  print_info "停止当前 NewAPI 旧版服务..."
  compose_in "$dir" down 2>/dev/null || true

  _write_postgres_compose_with_mount "$data_mount"

  print_info "生成新版 NewAPI docker-compose.yml ..."
  rm -f "$dir/docker-compose.yml"
  generate_default_configs "newapi" "$dir"

  print_info "启动共享 PostgreSQL..."
  if ! start_and_verify "/opt/postgres" "PostgreSQL"; then
    print_error "PostgreSQL 启动失败，已保留旧配置备份: $bak"
    return 1
  fi

  print_info "启动 NewAPI..."
  if start_and_verify "$dir" "NewAPI"; then
    print_success "迁移完成。原数据库文件未移动，旧配置备份: $bak"
  else
    print_error "NewAPI 启动失败。旧配置备份: $bak，可手动恢复。"
    return 1
  fi
}

# ===== Database Helpers =====

detect_db_type() {
  local compose_file="$1"
  [ -f "$compose_file" ] || { echo "none"; return; }

  local dir content dsn_values
  dir=$(dirname "$compose_file")
  content=$(_service_config_content "$dir")
  dsn_values=$(_extract_db_dsn_values "$dir")

  if echo "$content" | grep -qiE 'DB_DIALECT.*postgres'; then
    local pg_dsn
    pg_dsn=$(printf '%s\n' "$dsn_values" | grep -vi sqlite | head -1 || true)
    if [ -n "$pg_dsn" ]; then
      echo "postgres|$pg_dsn"
      return
    fi
  fi

  if echo "$content" | grep -qiE 'DB_DIALECT.*sqlite'; then
    local sqlite_dsn
    sqlite_dsn=$(printf '%s\n' "$dsn_values" | grep -E '^(file:|sqlite:)' | head -1 || true)
    if [ -n "$sqlite_dsn" ]; then
      echo "sqlite|$sqlite_dsn"
      return
    fi
  fi

  local sql_dsn
  sql_dsn=$(printf '%s\n' "$dsn_values" | head -1 || true)

  if [ -n "$sql_dsn" ]; then
    case "$sql_dsn" in
      postgres://*|postgresql://*)
        echo "postgres|$sql_dsn"; return ;;
      *host=*dbname=*)
        echo "postgres|$sql_dsn"; return ;;
      file:*|sqlite:*)
        echo "sqlite|$sql_dsn"; return ;;
    esac
  fi

  echo "none"
}

_service_config_content() {
  local dir="$1" file
  for file in "$dir/docker-compose.yml" "$dir/.env" "$dir/config.yml" "$dir/config.yaml"; do
    [ -f "$file" ] && cat "$file"
  done
  return 0
}

_strip_config_value() {
  local v="$1"
  v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s\n' "$v"
}

_extract_db_dsn_values() {
  local dir="$1" file line value
  for file in "$dir/docker-compose.yml" "$dir/.env" "$dir/config.yml" "$dir/config.yaml"; do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|[[:space:]]'#'*) continue ;;
      esac
      if [[ "$line" =~ ^[[:space:]]*([A-Z_]*DB_DSN|SQL_DSN|DATABASE_URL|dsn)[[:space:]]*[:=][[:space:]]*(.*)$ ]]; then
        value=$(_strip_config_value "${BASH_REMATCH[2]}")
        [ -n "$value" ] && printf '%s\n' "$value"
      fi
    done < "$file"
  done
  return 0
}

parse_pg_kv_dsn_field() {
  local dsn="$1" field="$2"
  local i=0 len=${#dsn} key value c quote

  while [ "$i" -lt "$len" ]; do
    while [ "$i" -lt "$len" ] && [[ "${dsn:$i:1}" =~ [[:space:]] ]]; do
      i=$((i + 1))
    done

    key=""
    while [ "$i" -lt "$len" ]; do
      c="${dsn:$i:1}"
      [ "$c" = "=" ] && break
      [[ "$c" =~ [[:space:]] ]] && break
      key+="$c"
      i=$((i + 1))
    done

    while [ "$i" -lt "$len" ] && [[ "${dsn:$i:1}" =~ [[:space:]] ]]; do
      i=$((i + 1))
    done
    if [ "$i" -ge "$len" ] || [ "${dsn:$i:1}" != "=" ]; then
      while [ "$i" -lt "$len" ] && ! [[ "${dsn:$i:1}" =~ [[:space:]] ]]; do
        i=$((i + 1))
      done
      continue
    fi
    i=$((i + 1))
    while [ "$i" -lt "$len" ] && [[ "${dsn:$i:1}" =~ [[:space:]] ]]; do
      i=$((i + 1))
    done

    value=""
    quote=""
    if [ "$i" -lt "$len" ] && { [ "${dsn:$i:1}" = "'" ] || [ "${dsn:$i:1}" = '"' ]; }; then
      quote="${dsn:$i:1}"
      i=$((i + 1))
      while [ "$i" -lt "$len" ]; do
        c="${dsn:$i:1}"
        if [ "$c" = "\\" ] && [ $((i + 1)) -lt "$len" ]; then
          value+="$c${dsn:$((i + 1)):1}"
          i=$((i + 2))
          continue
        fi
        [ "$c" = "$quote" ] && { i=$((i + 1)); break; }
        value+="$c"
        i=$((i + 1))
      done
      value=$(pg_kv_dsn_unescape "$value")
    else
      while [ "$i" -lt "$len" ] && ! [[ "${dsn:$i:1}" =~ [[:space:]] ]]; do
        value+="${dsn:$i:1}"
        i=$((i + 1))
      done
    fi

    if [ "$key" = "$field" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done

  return 1
}

parse_pg_dsn_field() {
  local dsn="$1" field="$2"
  local kv
  if kv=$(parse_pg_kv_dsn_field "$dsn" "$field"); then
    echo "$kv"
    return 0
  fi

  case "$dsn" in
    postgres://*|postgresql://*) ;;
    *) return 0 ;;
  esac

  local rest="${dsn#*://}"
  local before_query="${rest%%\?*}"
  local auth="" hostpart="$before_query"
  if [[ "$before_query" == *"@"* ]]; then
    auth="${before_query%@*}"
    hostpart="${before_query##*@}"
  fi
  local userpart="${auth%%:*}"
  local passpart=""
  if [[ "$auth" == *":"* ]]; then
    passpart="${auth#*:}"
  fi
  local hostport="${hostpart%%/*}"
  local dbpart=""
  if [[ "$hostpart" == */* ]]; then
    dbpart="${hostpart#*/}"
  fi
  local h="${hostport%%:*}"
  local p=""
  if [[ "$hostport" == *":"* ]]; then
    p="${hostport##*:}"
  fi

  url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
  }

  case "$field" in
    host)     echo "$h" ;;
    port)     echo "$p" ;;
    user)     url_decode "$userpart" ;;
    password) url_decode "$passpart" ;;
    dbname)   echo "$dbpart" ;;
    *)        echo "" ;;
  esac
}

find_pg_container() {
  local pg_host="$1"
  local cname aliases
  while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    aliases=$(docker inspect "$cname" \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{range $v.Aliases}}{{.}} {{end}}{{end}}' 2>/dev/null)
    if echo "$aliases $cname" | grep -qw "$pg_host"; then
      echo "$cname"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}')
  return 1
}

backup_postgres() {
  local name="$1" dir="$2" display="$3" items="$4" dsn="$5"

  local pg_host pg_port pg_user pg_pass pg_db
  pg_host=$(parse_pg_dsn_field "$dsn" "host")
  pg_port=$(parse_pg_dsn_field "$dsn" "port")
  pg_user=$(parse_pg_dsn_field "$dsn" "user")
  pg_db=$(parse_pg_dsn_field "$dsn" "dbname")
  pg_pass=$(parse_pg_dsn_field "$dsn" "password")
  pg_port="${pg_port:-5432}"

  if [ -z "$pg_host" ] || [ -z "$pg_user" ] || [ -z "$pg_db" ]; then
    print_error "无法从 DSN 解析 PostgreSQL 连接信息。"
    print_info "回退到文件备份..."
    backup_files "$name" "$dir" "$display" "$items"
    return
  fi

  local pg_container
  pg_container=$(find_pg_container "$pg_host")
  if [ -z "$pg_container" ]; then
    print_error "找不到 PostgreSQL 容器 (host=$pg_host)。"
    print_info "回退到文件备份..."
    backup_files "$name" "$dir" "$display" "$items"
    return
  fi

  local timestamp backup_dir sql_file tar_file
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_dir="${BACKUP_BASE}/${name}"
  sql_file="${backup_dir}/${name}-pgdump-${timestamp}.sql"
  tar_file="${backup_dir}/${name}-backup-${timestamp}.tar.gz"
  mkdir -p "$backup_dir"

  print_info "正在 pg_dump $pg_db (容器: $pg_container)..."
  if docker exec -e PGPASSWORD="$pg_pass" "$pg_container" \
      pg_dump -U "$pg_user" -d "$pg_db" --no-owner --no-privileges > "$sql_file" 2>/dev/null; then
    print_success "数据库导出完成: $sql_file ($(du -h "$sql_file" | cut -f1))"
  else
    rm -f "$sql_file"
    print_error "pg_dump 失败。"
    return
  fi

  local archive_args=()
  IFS=',' read -ra item_list <<< "$items"
  for item in "${item_list[@]}"; do
    [ -e "${dir}/${item}" ] && archive_args+=("${dir#/}/${item}")
  done
  archive_args+=("${sql_file#/}")

  print_info "正在打包配置 + 数据库 dump..."
  if tar --use-compress-program="gzip -1" -cpf "$tar_file" -C / "${archive_args[@]}"; then
    print_success "备份完成: $tar_file ($(du -h "$tar_file" | cut -f1))"
  else
    print_error "打包失败。"
  fi

  rm -f "$sql_file"
}

backup_sqlite() {
  local name="$1" dir="$2" display="$3" items="$4" dsn="$5"

  local db_path
  db_path=$(echo "$dsn" | sed 's/^file://' | sed 's/?.*//')

  local host_db=""
  if [ -f "$db_path" ]; then
    host_db="$db_path"
  elif [ -f "${dir}${db_path}" ]; then
    host_db="${dir}${db_path}"
  elif [ -f "${dir}/data/$(basename "$db_path")" ]; then
    host_db="${dir}/data/$(basename "$db_path")"
  fi

  if [ -z "$host_db" ] || [ ! -f "$host_db" ]; then
    print_warning "找不到 SQLite 数据库文件 ($db_path)，回退到文件备份..."
    backup_files "$name" "$dir" "$display" "$items"
    return
  fi

  if ! command -v sqlite3 >/dev/null 2>&1; then
    print_warning "sqlite3 未安装，回退到文件备份..."
    backup_files "$name" "$dir" "$display" "$items"
    return
  fi

  local timestamp backup_dir db_backup tar_file
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_dir="${BACKUP_BASE}/${name}"
  db_backup="${backup_dir}/${name}-sqlite-${timestamp}.db"
  tar_file="${backup_dir}/${name}-backup-${timestamp}.tar.gz"
  mkdir -p "$backup_dir"

  print_info "正在热备 SQLite 数据库..."
  if sqlite3 "$host_db" ".backup '$db_backup'"; then
    print_success "数据库热备完成: $db_backup ($(du -h "$db_backup" | cut -f1))"
  else
    print_error "sqlite3 .backup 失败，回退到文件备份..."
    rm -f "$db_backup"
    backup_files "$name" "$dir" "$display" "$items"
    return
  fi

  local archive_args=()
  IFS=',' read -ra item_list <<< "$items"
  for item in "${item_list[@]}"; do
    [ "$item" = "data" ] && continue
    [ -e "${dir}/${item}" ] && archive_args+=("${dir#/}/${item}")
  done
  archive_args+=("${db_backup#/}")

  print_info "正在打包配置 + 数据库副本..."
  if tar --use-compress-program="gzip -1" -cpf "$tar_file" -C / "${archive_args[@]}"; then
    print_success "备份完成: $tar_file ($(du -h "$tar_file" | cut -f1))"
  else
    print_error "打包失败。"
  fi

  rm -f "$db_backup"
}

backup_files() {
  local name="$1" dir="$2" display="$3" items="$4"

  local timestamp backup_dir backup_file
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_dir="${BACKUP_BASE}/${name}"
  backup_file="${backup_dir}/${name}-backup-${timestamp}.tar.gz"
  mkdir -p "$backup_dir"

  local archive_args=()
  IFS=',' read -ra item_list <<< "$items"
  for item in "${item_list[@]}"; do
    [ -e "${dir}/${item}" ] && archive_args+=("${dir#/}/${item}")
  done

  if [ ${#archive_args[@]} -eq 0 ]; then
    print_error "未找到可备份的文件。"; return
  fi

  local had_stop="false"
  if is_installed "$dir" && is_running "$dir"; then
    print_info "短暂停止服务以确保数据一致性..."
    compose_in "$dir" stop
    had_stop="true"
  fi

  print_info "正在备份文件..."
  if tar --use-compress-program="gzip -1" -cpf "$backup_file" -C / "${archive_args[@]}"; then
    print_success "备份完成: $backup_file ($(du -h "$backup_file" | cut -f1))"
  else
    rm -f "$backup_file"
    print_error "备份失败。"
  fi

  if [ "$had_stop" = "true" ]; then
    if compose_in "$dir" start; then
      reconnect_networks
      print_info "服务已恢复。"
    else
      print_error "服务自动恢复失败，请手动执行: (cd $dir && $COMPOSE_CMD start)"
    fi
  fi
}

# ===== Service Actions =====

extract_pg_dsns() {
  local dir="$1"
  local compose_file="$dir/docker-compose.yml"
  [ -f "$compose_file" ] || return 0

  _extract_db_dsn_values "$dir" \
    | grep -E '(^|[[:space:]])host=' \
    | while IFS= read -r dsn; do
        local host port user pass db
        host=$(parse_pg_dsn_field "$dsn" "host")
        port=$(parse_pg_dsn_field "$dsn" "port")
        port="${port:-5432}"
        user=$(parse_pg_dsn_field "$dsn" "user")
        pass=$(parse_pg_dsn_field "$dsn" "password")
        db=$(parse_pg_dsn_field "$dsn" "dbname")
        [ -n "$host" ] && [ -n "$user" ] && [ -n "$db" ] && echo "$host|$port|$user|$pass|$db"
      done
}

extract_pg_uri_dsns() {
  local dir="$1"
  local compose_file="$dir/docker-compose.yml"
  [ -f "$compose_file" ] || return 0

  _service_config_content "$dir" \
    | grep -oE 'postgres(ql)?://[^"[:space:]]+' \
    | while IFS= read -r uri; do
        local host port user pass db
        host=$(parse_pg_dsn_field "$uri" "host")
        port=$(parse_pg_dsn_field "$uri" "port")
        port="${port:-5432}"
        user=$(parse_pg_dsn_field "$uri" "user")
        pass=$(parse_pg_dsn_field "$uri" "password")
        db=$(parse_pg_dsn_field "$uri" "dbname")
        [ -n "$host" ] && [ -n "$user" ] && [ -n "$db" ] && echo "$host|$port|$user|$pass|$db"
      done
}

ensure_pg_database() {
  local pg_host="$1" pg_port="$2" pg_user="$3" pg_pass="$4" pg_db="$5"

  local pg_container
  pg_container=$(find_pg_container "$pg_host")
  if [ -z "$pg_container" ]; then
    print_warning "  找不到 PostgreSQL 容器 (host=$pg_host)，跳过数据库 $pg_db 创建检查。"
    print_info "  请确保 PostgreSQL 服务已安装并运行。"
    return 1
  fi

  local exists
  local pg_db_literal pg_db_identifier
  pg_db_literal=$(pg_sql_literal "$pg_db")
  pg_db_identifier=$(pg_sql_identifier "$pg_db")

  exists=$(docker exec -e PGPASSWORD="$pg_pass" "$pg_container" \
    psql -U "$pg_user" -tAc "SELECT 1 FROM pg_database WHERE datname=${pg_db_literal}" 2>/dev/null)
  if [ "$exists" = "1" ]; then
    print_info "  数据库 $pg_db 已存在。"
    return 0
  fi

  print_info "  正在创建数据库 $pg_db ..."
  if docker exec -e PGPASSWORD="$pg_pass" "$pg_container" \
      psql -U "$pg_user" -c "CREATE DATABASE ${pg_db_identifier}" 2>/dev/null; then
    print_success "  数据库 $pg_db 已创建。"
    return 0
  else
    print_error "  创建数据库 $pg_db 失败。"
    return 1
  fi
}

ensure_all_pg_databases() {
  local dir="$1"
  local compose_file="$dir/docker-compose.yml"
  [ -f "$compose_file" ] || return 0

  print_info "检查并创建所需 PostgreSQL 数据库..."

  local db_host db_port db_user db_pass db_name
  while IFS='|' read -r db_host db_port db_user db_pass db_name; do
    [ -z "$db_host" ] && continue
    ensure_pg_database "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name" || true
  done < <(extract_pg_dsns "$dir")

  while IFS='|' read -r db_host db_port db_user db_pass db_name; do
    [ -z "$db_host" ] && continue
    ensure_pg_database "$db_host" "$db_port" "$db_user" "$db_pass" "$db_name" || true
  done < <(extract_pg_uri_dsns "$dir")
}

# 确保 PostgreSQL 在需要时自动安装
ensure_pg_installed() {
  if pg_compose_installed && pg_available; then
    return 0
  fi

  print_warning "共享 PostgreSQL 服务 ($PG_CONTAINER) 不可用。"

  # PG 可能运行在另一个 compose 中（旧版 NewAPI 内嵌），尝试迁移
  if _any_pg_running; then
    echo ""
    print_info "检测到运行中的 PostgreSQL 容器（可能来自旧版 NewAPI 内嵌）。"
    local do_migrate=""
    read -r -p "  是否迁移到独立共享 PostgreSQL 架构？[Y/n]: " do_migrate < /dev/tty
    if [[ ! "$do_migrate" =~ ^[Nn]$ ]]; then
      migrate_legacy_newapi "/opt/newapi"
      return $?
    fi
    return 0
  fi

  if pg_compose_installed && ! pg_available; then
    print_info "PostgreSQL 已安装但未运行，正在启动..."
    do_start "postgres" "/opt/postgres" "PostgreSQL"
    return $?
  fi

  # 完全没有 PG，自动安装
  echo ""
  local auto_install=""
  read -r -p "  是否自动安装共享 PostgreSQL？[Y/n]: " auto_install < /dev/tty
  if [[ "$auto_install" =~ ^[Nn]$ ]]; then
    print_warning "跳过 PostgreSQL 安装。依赖数据库的服务可能无法启动。"
    return 1
  fi

  do_install "postgres" "/opt/postgres" "PostgreSQL"
  return $?
}

# ===== Default Config Generators =====

generate_default_configs() {
  local name="$1" dir="$2"

  case "$name" in
    postgres|newapi|metapi|axonhub|litellm)
      check_pg_credentials || return 1
      ;;
  esac

  local pg_pass_url="" pg_user_url="" pg_pass_yaml="" pg_pass_dsn="" pg_user_dsn=""
  if [ -n "${PG_PASSWORD:-}" ]; then
    pg_pass_url=$(url_encode "$PG_PASSWORD")
    pg_pass_yaml=$(yaml_dquote "$PG_PASSWORD")
    pg_pass_dsn=$(pg_kv_dsn_value "$PG_PASSWORD")
  fi
  if [ -n "${PG_USER:-}" ]; then
    pg_user_url=$(url_encode "$PG_USER")
    pg_user_dsn=$(pg_kv_dsn_value "$PG_USER")
  fi

  case "$name" in
    postgres)
      if [ ! -f "$dir/docker-compose.yml" ]; then
        print_info "生成默认 docker-compose.yml ..."
        cat > "$dir/docker-compose.yml" <<AUTOGEN_EOF
# 共享 PostgreSQL 服务 (auto-generated by server-manager)
services:
  postgres:
    image: postgres:15-alpine
    container_name: ${PG_CONTAINER}
    restart: always
    environment:
      POSTGRES_USER: "$(yaml_dquote "$PG_USER")"
      POSTGRES_PASSWORD: "${pg_pass_yaml}"
    volumes:
      - ./data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \"$(yaml_dquote "$PG_USER")\" -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
    ports:
      - "5432:5432"
AUTOGEN_EOF
      fi
      ;;

    newapi)
      if [ ! -f "$dir/docker-compose.yml" ]; then
        print_info "生成默认 docker-compose.yml ..."
        cat > "$dir/docker-compose.yml" <<AUTOGEN_EOF
# NewAPI Docker Compose (auto-generated by server-manager)
# 仓库: https://github.com/QuantumNous/new-api
services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    networks:
      - default
      - postgres-net
    ports:
      - "3000:3000"
    environment:
      TZ: Asia/Shanghai
      SQL_DSN: "postgres://${pg_user_url}:${pg_pass_url}@${PG_CONTAINER}:5432/newapi?sslmode=disable"
    volumes:
      - ./data:/data

networks:
  postgres-net:
    external: true
    name: ${PG_NETWORK}
AUTOGEN_EOF
      fi
      ;;

    metapi)
      if [ ! -f "$dir/docker-compose.yml" ]; then
        print_info "生成默认 docker-compose.yml ..."
        cat > "$dir/docker-compose.yml" <<AUTOGEN_EOF
# MetaPI Docker Compose (auto-generated by server-manager)
services:
  metapi:
    image: your-metapi-image:latest
    container_name: metapi
    restart: unless-stopped
    networks:
      - default
      - postgres-net
    ports:
      - "8000:8000"
    environment:
      TZ: Asia/Shanghai
    env_file:
      - .env
    volumes:
      - ./data:/data

networks:
  postgres-net:
    external: true
    name: ${PG_NETWORK}
AUTOGEN_EOF
      fi
      if [ ! -f "$dir/.env" ]; then
        print_info "生成默认 .env ..."
        cat > "$dir/.env" <<AUTOGEN_EOF
# MetaPI Environment (auto-generated by server-manager)
DB_DIALECT=postgres
DB_DSN=host=${PG_CONTAINER} port=5432 user=${pg_user_dsn} password=${pg_pass_dsn} dbname=metapi sslmode=disable
AUTOGEN_EOF
      fi
      ;;

    cliproxy)
      if [ ! -f "$dir/docker-compose.yml" ]; then
        print_info "生成默认 docker-compose.yml ..."
        cat > "$dir/docker-compose.yml" <<'AUTOGEN_EOF'
# CLIProxy Docker Compose (auto-generated by server-manager)
services:
  cliproxy:
    image: eceasy/cli-proxy-api:latest
    container_name: cliproxy
    restart: unless-stopped
    networks:
      - default
      - postgres-net
      - axonhub-net
    ports:
      - "8977:8977"
    volumes:
      - ./config.yaml:/CLIProxyAPI/config.yaml
      - ./auths:/root/.cli-proxy-api
      - ./logs:/CLIProxyAPI/logs
    environment:
      TZ: Asia/Shanghai

networks:
  postgres-net:
    external: true
    name: postgres_default
  axonhub-net:
    external: true
    name: axonhub_default
AUTOGEN_EOF
      fi
      if [ ! -f "$dir/config.yaml" ]; then
        print_info "生成默认 config.yaml (最小配置) ..."
        cat > "$dir/config.yaml" <<'AUTOGEN_EOF'
# CLIProxy Configuration (auto-generated by server-manager)
host: ''
port: 8977
tls:
  enable: false
  cert: ''
  key: ''

remote-management:
  allow-remote: true
  secret-key: ""
  disable-control-panel: false

auth-dir: '~/.cli-proxy-api'

api-keys: []

debug: false
incognito-browser: true

request-retry: 3
max-retry-credentials: 0
max-retry-interval: 30

routing:
  strategy: 'round-robin'

ws-auth: false
enable-gemini-cli-endpoint: false

usage-statistics-enabled: true
force-model-prefix: false

quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true

logging-to-file: false
logs-max-total-size-mb: 0
error-logs-max-files: 10

channels: {}
AUTOGEN_EOF
      fi
      ;;

    axonhub)
      if [ ! -f "$dir/docker-compose.yml" ]; then
        print_info "生成默认 docker-compose.yml ..."
        cat > "$dir/docker-compose.yml" <<AUTOGEN_EOF
# AxonHub Docker Compose (auto-generated by server-manager)
services:
  axonhub:
    image: looplj/axonhub:latest
    container_name: axonhub
    restart: unless-stopped
    networks:
      - default
      - postgres-net
    environment:
      AXONHUB_DB_DIALECT: postgres
      AXONHUB_DB_DSN: "host=${PG_CONTAINER} port=5432 user=${pg_user_dsn} password=${pg_pass_dsn} dbname=axonhub sslmode=disable"
      TZ: Asia/Shanghai
    ports:
      - "8090:8090"
    volumes:
      - ./config.yml:/app/config.yml:ro
      - ./data:/data
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8090/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  postgres-net:
    external: true
    name: ${PG_NETWORK}
AUTOGEN_EOF
      fi
      if [ ! -f "$dir/config.yml" ]; then
        print_info "生成默认 config.yml ..."
        cat > "$dir/config.yml" <<AUTOGEN_EOF
# AxonHub Configuration (auto-generated by server-manager)
server:
  host: "0.0.0.0"
  port: 8090
  name: "AxonHub"
  llm_request_timeout: "600s"
  cors:
    enabled: true
    allowed_origins:
      - "*"

db:
  dialect: "postgres"
  dsn: "host=${PG_CONTAINER} port=5432 user=${pg_user_dsn} password=${pg_pass_dsn} dbname=axonhub sslmode=disable"

cache:
  mode: "memory"

log:
  level: "info"
  encoding: "json"
  output: "stdio"

gc:
  cron: "0 2 * * *"
  vacuum_enabled: true
AUTOGEN_EOF
      fi
      ;;

    9router)
      if [ ! -f "$dir/docker-compose.yml" ]; then
        print_info "生成默认 docker-compose.yml ..."
        cat > "$dir/docker-compose.yml" <<'AUTOGEN_EOF'
# 9Router Docker Compose (auto-generated by server-manager)
# 仓库: https://github.com/decolua/9router
services:
  9router:
    image: decolua/9router:latest
    container_name: 9router
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "20128:20128"
    volumes:
      - ./data:/app/data
      - ./usage:/root/.9router
      - ./logs:/app/logs
AUTOGEN_EOF
      fi
      if [ ! -f "$dir/.env" ]; then
        print_info "生成默认 .env ..."
        local initial_password jwt_secret api_key_secret machine_id_salt
        initial_password=$(_random_secret)
        jwt_secret=$(_random_secret)
        api_key_secret=$(_random_secret)
        machine_id_salt=$(_random_secret)
        cat > "$dir/.env" <<AUTOGEN_EOF
# 9Router Environment (auto-generated by server-manager)
PORT=20128
HOSTNAME=0.0.0.0
LOCAL_URL=http://127.0.0.1:20128
PUBLIC_BASE_URL=
APP_URL=
DATA_DIR=/app/data
NODE_ENV=production
INITIAL_PASSWORD=${initial_password}
JWT_SECRET=${jwt_secret}
API_KEY_SECRET=${api_key_secret}
MACHINE_ID_SALT=${machine_id_salt}
# 互联网暴露部署建议改为 true，并在客户端使用 Bearer API key 访问 /v1/*
REQUIRE_API_KEY=false
# HTTPS 反向代理后可改为 true
AUTH_COOKIE_SECURE=false
AUTOGEN_EOF
        chmod 600 "$dir/.env"
      fi
      ;;

    litellm)
      if [ ! -f "$dir/docker-compose.yml" ]; then
        print_info "生成默认 docker-compose.yml ..."
        cat > "$dir/docker-compose.yml" <<AUTOGEN_EOF
# LiteLLM Docker Compose (auto-generated by server-manager)
# 仓库: https://github.com/BerriAI/litellm
services:
  litellm:
    image: docker.litellm.ai/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    networks:
      - default
      - postgres-net
    env_file:
      - .env
    ports:
      - "4000:4000"
    volumes:
      - ./config.yaml:/app/config.yaml
    command:
      - "--config=/app/config.yaml"
      - "--port=4000"
      - "--host=0.0.0.0"
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')\""]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  postgres-net:
    external: true
    name: ${PG_NETWORK}
AUTOGEN_EOF
      fi
      if [ ! -f "$dir/.env" ]; then
        print_info "生成默认 .env ..."
        local master_key salt_key
        master_key="sk-$(_random_secret)"
        salt_key=$(_random_secret)
        cat > "$dir/.env" <<AUTOGEN_EOF
# LiteLLM Environment (auto-generated by server-manager)
LITELLM_MASTER_KEY=${master_key}
LITELLM_SALT_KEY=${salt_key}
DATABASE_URL=postgresql://${pg_user_url}:${pg_pass_url}@${PG_CONTAINER}:5432/litellm
LOCAL_URL=http://127.0.0.1:4000
PUBLIC_BASE_URL=
APP_URL=
STORE_MODEL_IN_DB=True
UI_USERNAME=admin
UI_PASSWORD=${master_key}
TZ=Asia/Shanghai
AUTOGEN_EOF
        chmod 600 "$dir/.env"
      fi
      if [ ! -f "$dir/config.yaml" ]; then
        print_info "生成默认 config.yaml ..."
        cat > "$dir/config.yaml" <<'AUTOGEN_EOF'
# LiteLLM Configuration (auto-generated by server-manager)
model_list: []

general_settings:
  store_model_in_db: true
AUTOGEN_EOF
      fi
      ;;
  esac
}

print_install_info() {
  local name="$1" dir="$2" display="$3"
  local lan_ip="" public_ip=""
  lan_ip=$(detect_lan_ip)
  public_ip=$(detect_public_ip)

  print_header "$display 安装信息"
  echo "  安装目录: $dir"
  echo "  管理命令: cd $dir && $COMPOSE_CMD ps"

  case "$name" in
    postgres)
      echo "  容器名称: $PG_CONTAINER"
      [ -n "$lan_ip" ] && echo "  数据库局域网地址: $lan_ip:5432"
      [ -n "$public_ip" ] && echo "  数据库公网地址: $public_ip:5432"
      echo "  凭据文件: $PG_CONF_FILE"
      ;;
    newapi)
      print_access_info "3000" "$lan_ip" "$public_ip"
      echo "  数据目录: $dir/data"
      ;;
    metapi)
      print_access_info "8000" "$lan_ip" "$public_ip"
      echo "  环境文件: $dir/.env"
      ;;
    cliproxy)
      print_access_info "8977" "$lan_ip" "$public_ip"
      echo "  配置文件: $dir/config.yaml"
      echo "  授权目录: $dir/auths"
      ;;
    axonhub)
      print_access_info "8090" "$lan_ip" "$public_ip"
      echo "  配置文件: $dir/config.yml"
      ;;
    9router)
      print_access_info "20128" "$lan_ip" "$public_ip" "9router" "9router_default"
      echo "  环境文件: $dir/.env"
      if [ -f "$dir/.env" ]; then
        local initial_password
        initial_password=$(sed -n 's/^INITIAL_PASSWORD=//p' "$dir/.env" | head -1)
        [ -n "$initial_password" ] && echo "  首次登录密码: $initial_password"
      fi
      ;;
    litellm)
      print_access_info "4000" "$lan_ip" "$public_ip" "litellm" "litellm_default"
      echo "  配置文件: $dir/config.yaml"
      echo "  环境文件: $dir/.env"
      if [ -f "$dir/.env" ]; then
        local master_key
        master_key=$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$dir/.env" | head -1)
        [ -n "$master_key" ] && echo "  Master Key: $master_key"
      fi
      ;;
  esac
}

# ===== Install / Update / Start / Stop / Restart / Status / Logs / Backup / Uninstall =====

_update_newapi_frontend() {
  print_header "构建 NewAPI 前端"

  local src_dir="/root/newapi-frontend-src"
  local nginx_dir="/var/www/newapi-dist"

  if [ ! -d "$nginx_dir" ]; then
    print_error "Nginx 静态文件目录 $nginx_dir 不存在，跳过前端部署。"
    return 1
  fi

  # 检查磁盘空间（bun install + 构建至少需要 1GB 临时空间）
  local avail_kb
  avail_kb=$(df / --output=avail 2>/dev/null | tail -1 | tr -d ' ' || echo "0")
  local avail_mb=$((avail_kb / 1024))
  if [ "$avail_mb" -lt 1024 ]; then
    print_warning "磁盘剩余空间仅 ${avail_mb}MB，前端构建至少需要 1GB 空闲空间。"
    local do_clean=""
    read -r -p "  是否执行 Docker 系统清理以释放空间？[Y/n]: " do_clean < /dev/tty
    if [[ ! "$do_clean" =~ ^[Nn]$ ]]; then
      print_info "清理 Docker 未使用的镜像、容器和构建缓存..."
      docker system prune -f || true
      avail_kb=$(df / --output=avail 2>/dev/null | tail -1 | tr -d ' ' || echo "0")
      avail_mb=$((avail_kb / 1024))
      if [ "$avail_mb" -lt 512 ]; then
        print_error "清理后磁盘空间仍不足 (${avail_mb}MB)，无法构建前端。"
        print_info "建议手动清理磁盘（如删除不需要的 Docker 镜像或旧日志）。"
        return 1
      fi
      print_info "清理后可用空间: ${avail_mb}MB"
    else
      if [ "$avail_mb" -lt 512 ]; then
        print_error "磁盘空间严重不足 (${avail_mb}MB)，构建可能失败。"
        local force=""
        read -r -p "  仍然继续？[y/N]: " force < /dev/tty
        if [[ ! "$force" =~ ^[Yy]$ ]]; then
          return 1
        fi
      fi
    fi
  fi

  # 确保 bun 可用
  if ! command -v bun >/dev/null 2>&1; then
    print_info "正在安装 bun..."
    if command -v npm >/dev/null 2>&1; then
      if ! npm install -g bun; then
        print_error "通过 npm 安装 bun 失败。"
        return 1
      fi
    else
      print_info "npm 不可用，使用官方安装脚本..."
      if ! curl -fsSL https://bun.sh/install | bash; then
        print_error "bun 安装失败。"
        return 1
      fi
      export PATH="$HOME/.bun/bin:$PATH"
      if ! command -v bun >/dev/null 2>&1; then
        print_error "bun 安装后仍不可用。"
        return 1
      fi
    fi
  fi

  # 清理 old node_modules 释放空间
  if [ -d "$src_dir/web/node_modules" ]; then
    print_info "清理旧依赖缓存..."
    rm -rf "$src_dir/web/node_modules" 2>/dev/null || true
  fi

  # 获取 NewAPI 源码
  if [ -d "$src_dir" ]; then
    print_info "拉取最新 NewAPI 源码..."
    (cd "$src_dir" && git pull --ff-only) || {
      print_warning "拉取失败，重新克隆..."
      rm -rf "$src_dir"
      if ! git clone --depth=1 https://github.com/QuantumNous/new-api.git "$src_dir"; then
        print_error "克隆 NewAPI 源码失败。"
        return 1
      fi
    }
  else
    print_info "克隆 NewAPI 源码..."
    if ! git clone --depth=1 https://github.com/QuantumNous/new-api.git "$src_dir"; then
      print_error "克隆 NewAPI 源码失败。"
      return 1
    fi
  fi

  if [ ! -d "$src_dir/web" ]; then
    print_error "源码中未找到 web 前端目录。"
    return 1
  fi

  cd "$src_dir/web"
  print_info "安装前端依赖（跳过缓存以节省空间）..."
  if ! bun install --no-cache; then
    print_error "bun install 失败。"
    rm -rf "node_modules" "default/node_modules" "classic/node_modules" 2>/dev/null || true
    return 1
  fi

  local classic_dir="$src_dir/web/classic"
  if [ ! -d "$classic_dir" ]; then
    print_error "源码中未找到 web/classic 构建目录。"
    rm -rf "node_modules" "default/node_modules" "classic/node_modules" 2>/dev/null || true
    return 1
  fi

  # 应用自定义补丁（Mirage 幻境主页 + AIPlanHub 路由 + 导航）
  print_info "应用自定义补丁..."

  # 1. 替换 Home 页面为 Design1（Mirage 幻境赛博风格）
  #    Design1.jsx 从本地项目嵌入脚本中读取，若不存在则使用默认
  if [ ! -f "$classic_dir/src/pages/Home/Design1.jsx" ]; then
    print_warning "未找到 Design1.jsx 自定义主页，使用默认主页。"
  fi

  # 2. 创建 AIPlanHub 页面
  mkdir -p "$classic_dir/src/pages/AIPlanHub"
  cat > "$classic_dir/src/pages/AIPlanHub/index.jsx" << 'AIPEOF'
import React, { useEffect, useMemo, useState } from 'react';
const AIPlanHub = () => {
  const [isDark, setIsDark] = useState(false);
  useEffect(() => {
    const syncTheme = () => setIsDark(document.documentElement.classList.contains('dark'));
    syncTheme();
    const observer = new MutationObserver(syncTheme);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
    return () => observer.disconnect();
  }, []);
  const iframeSrc = useMemo(() => '/aiplanhub/?theme=' + (isDark ? 'dark' : 'light') + '&embed=1', [isDark]);
  return (
    <div style={{width:'100%',height:'100%',display:'flex',flexDirection:'column',overflow:'hidden',paddingTop:8,paddingBottom:12,boxSizing:'border-box',background:'var(--semi-color-bg-0)'}}>
      <iframe key={iframeSrc} src={iframeSrc} title='AI 订阅方案对比' style={{flex:1,border:'none',width:'100%',height:'100%',borderRadius:12,background:isDark?'#0A0E1A':'#F8FAFC'}} allow='clipboard-write' />
    </div>
  );
};
export default AIPlanHub;
AIPEOF

  # 3. 修改 App.jsx 添加路由
  if ! grep -q "AIPlanHub" "$classic_dir/src/App.jsx"; then
    sed -i "s|import SetupCheck from './components/layout/SetupCheck';|import SetupCheck from './components/layout/SetupCheck';\nimport AIPlanHub from './pages/AIPlanHub';|" "$classic_dir/src/App.jsx"
    sed -i "s|<Route path='/about' element={<|<Route path='/aiplanhub' element={<AIPlanHub />} />\n        <Route path='/about' element={<|" "$classic_dir/src/App.jsx"
  fi

  # 4. 修改 useNavigation.js 添加导航
  if ! grep -q "aiplanhub" "$classic_dir/src/hooks/common/useNavigation.js"; then
    sed -i "s|text: t('模型广场'),|text: t('模型广场'),\n      },\n      {\n        text: '⚡ AI 订阅方案对比',\n        itemKey: 'aiplanhub',\n        to: '/aiplanhub',|" "$classic_dir/src/hooks/common/useNavigation.js"
    sed -i "s|if (link.itemKey === 'docs') {|if (link.itemKey === 'aiplanhub' || link.itemKey === 'recharge') {\n        return true;\n      }\n      if (link.itemKey === 'docs') {|" "$classic_dir/src/hooks/common/useNavigation.js"
  fi

  # 5. 修改 PageLayout.jsx 隐藏页脚
  if ! grep -q "aiplanhub" "$classic_dir/src/components/layout/PageLayout.jsx"; then
    sed -i "s|cardProPages.includes(location.pathname);|cardProPages.includes(location.pathname) || location.pathname === '/aiplanhub';|" "$classic_dir/src/components/layout/PageLayout.jsx"
  fi


  cd "$classic_dir"
  print_info "构建前端（classic 工作区）..."
  if ! DISABLE_ESLINT_PLUGIN=true bun run build; then
    print_error "前端构建失败。"
    rm -rf "$src_dir/web/node_modules" "$src_dir/web/classic/node_modules" 2>/dev/null || true
    return 1
  fi

  if [ ! -d "dist" ]; then
    print_error "构建产物 dist 目录不存在。"
    rm -rf "$src_dir/web/node_modules" "$src_dir/web/classic/node_modules" 2>/dev/null || true
    return 1
  fi

  print_info "部署前端到 $nginx_dir ..."
  rm -rf "$nginx_dir/assets" "$nginx_dir/static" "$nginx_dir/index.html" "$nginx_dir/vite.svg" 2>/dev/null || true
  if ! cp -r dist/* "$nginx_dir/"; then
    print_error "部署前端失败。"
    rm -rf "$src_dir/web/node_modules" "$src_dir/web/classic/node_modules" 2>/dev/null || true
    return 1
  fi

  # 构建完成后清理临时文件，释放磁盘空间
  print_info "清理构建临时文件..."
  rm -rf "$src_dir/web/node_modules" "$src_dir/web/classic/node_modules" "$src_dir" 2>/dev/null || true
  # 清理 bun 缓存（避免下次安装时因缓存占用额外空间）
  rm -rf ~/.bun/install/cache/ 2>/dev/null || true

  print_success "NewAPI 前端已构建并部署到 $nginx_dir"
  print_info "浏览器可能需要强制刷新 (Cmd+Shift+R) 才能看到最新版本。"
}

do_install() {
  local name="$1" dir="$2" display="$3"
  print_header "安装 $display ($name)"
  require_compose || return

  if is_installed "$dir"; then
    print_warning "$display 已安装。如需重新安装请先卸载。"
    return
  fi

  if [ ! -d "$dir" ]; then
    print_info "目录 $dir 不存在，正在创建..."
    mkdir -p "$dir"
  fi

  # 对于依赖 PG 的服务，先确保 PG 可用
  if [ "$name" != "postgres" ]; then
    case "$name" in
      newapi|metapi|axonhub|litellm)
        ensure_pg_installed || {
          print_warning "PostgreSQL 未就绪，$display 可能无法正常启动。"
        }
        ;;
    esac
  fi

  generate_default_configs "$name" "$dir" || {
    print_error "无法生成默认配置，安装中止。"
    return
  }

  if [ ! -f "$dir/docker-compose.yml" ]; then
    print_error "未找到 $dir/docker-compose.yml，请手动部署配置文件后再安装。"
    return
  fi

  # PG 可用时自动创建所需数据库
  local db_info db_type
  db_info=$(detect_db_type "$dir/docker-compose.yml" 2>/dev/null || echo "none")
  db_type=$(echo "$db_info" | cut -d'|' -f1)
  if [ "$db_type" = "postgres" ] && pg_available; then
    ensure_all_pg_databases "$dir"
  fi

  print_info "启动 $display..."
  if start_and_verify "$dir" "$display"; then
    print_success "$display 安装完成。"
    print_install_info "$name" "$dir" "$display"
  else
    print_error "$display 安装失败，请检查上面的日志排查问题。"
  fi
}

do_update() {
  local name="$1" dir="$2" display="$3"
  print_header "更新 $display ($name)"
  require_compose || return

  if ! is_installed "$dir"; then
    print_error "$display 未安装。"; return
  fi

  # 检测旧版配置（内嵌 postgres）并提示迁移
  if [ "$name" = "newapi" ] && _is_legacy_compose "$dir/docker-compose.yml"; then
    print_warning "检测到旧版 NewAPI 配置（内嵌 PostgreSQL + 旧镜像标签）。"
    print_info "旧镜像 calciumion/new-api:fixed-quota 可能已不可用。"
    echo ""
    local do_migrate=""
    read -r -p "  是否迁移到新版共享 PostgreSQL 架构？[Y/n]: " do_migrate < /dev/tty
    if [[ ! "$do_migrate" =~ ^[Nn]$ ]]; then
      migrate_legacy_newapi "$dir"
      return $?
    fi
    print_info "继续使用旧配置，仅修正 NewAPI 镜像标签后尝试更新..."
  fi

  if [ "$name" = "newapi" ]; then
    _patch_newapi_image_to_latest "$dir"
  fi

  # 备份当前镜像以便启动失败时回退
  local bk_dir="/tmp/.sm-rollback-${name}"
  rm -rf "$bk_dir"
  mkdir -p "$bk_dir"
  local compose_images
  compose_images=$(grep 'image:' "$dir/docker-compose.yml" | sed 's/.*image:\s*["'\'']\?//' | sed 's/["'\'']\?\s*$//' || true)
  local has_backup=false
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    local safe_name
    safe_name=$(echo "$img" | tr '/:' '__')
    if docker inspect "$img" --format '{{.Id}}' > "$bk_dir/$safe_name" 2>/dev/null; then
      docker tag "$img" "sm-rollback-${safe_name}" 2>/dev/null || true
      has_backup=true
    fi
  done <<< "$compose_images"

  print_info "拉取最新镜像..."
  if ! compose_in "$dir" pull 2>&1; then
    print_error "拉取镜像失败。"
    echo ""
    if [ "$name" = "newapi" ]; then
      print_info "如果旧配置文件使用的是 calciumion/new-api:fixed-quota，该标签已不存在。"
      print_info "建议：回到主菜单选择 NewAPI -> 卸载（保留数据），然后重新安装。"
    fi
    rm -rf "$bk_dir" 2>/dev/null || true
    return 1
  fi

  print_info "重建容器..."
  if start_and_verify "$dir" "$display"; then
    print_success "$display 已更新。"
    rm -rf "$bk_dir" 2>/dev/null || true

    # NewAPI 额外步骤：构建前端
    if [ "$name" = "newapi" ]; then
      echo ""
      local build_fe=""
      read -r -p "  是否同时构建并部署最新前端（到 /var/www/newapi-dist）？[y/N]: " build_fe < /dev/tty
      if [[ "$build_fe" =~ ^[Yy]$ ]]; then
        _update_newapi_frontend
      fi
    fi
  else
    print_error "$display 更新后启动失败，请检查上面的日志。"
    # 有备份 → 常规回退
    if [ "$has_backup" = true ]; then
      echo ""
      local do_rollback=""
      read -r -p "  是否回退到更新前的版本？[Y/n]: " do_rollback < /dev/tty
      if [[ ! "$do_rollback" =~ ^[Nn]$ ]]; then
        print_info "正在回退镜像..."
        while IFS= read -r img; do
          [ -z "$img" ] && continue
          local safe_name
          safe_name=$(echo "$img" | tr '/:' '__')
          if [ -f "$bk_dir/$safe_name" ]; then
            docker tag "sm-rollback-${safe_name}" "$img" 2>/dev/null || true
            docker rmi "sm-rollback-${safe_name}" 2>/dev/null || true
          fi
        done <<< "$compose_images"
        print_info "使用旧版本镜像重新启动..."
        compose_in "$dir" up -d --force-recreate
        sleep 5
        if is_running "$dir"; then
          print_success "已回退到旧版本。"
        else
          print_error "回退后启动仍然失败，可能需要手动排查。"
          compose_in "$dir" logs --tail 30 2>/dev/null || true
        fi
      fi
    # 无备份（此前直接更新后故障），尝试从 Docker 缓存恢复
    elif [ -n "$compose_images" ]; then
      echo ""
      local do_cache=""
      read -r -p "  是否尝试从 Docker 缓存恢复旧版本？[Y/n]: " do_cache < /dev/tty
      if [[ ! "$do_cache" =~ ^[Nn]$ ]]; then
        print_info "正在从 Docker 缓存查找旧版本..."
        local restored_any=false
        for img in $compose_images; do
          [ -z "$img" ] && continue
          local repo="${img%:*}"
          local current_id
          current_id=$(docker inspect "$img" --format '{{.Id}}' 2>/dev/null || true)
          local cached_ids
          cached_ids=$(docker images "$repo" --all --format '{{.ID}}' 2>/dev/null || true)
          while IFS= read -r cid; do
            [ -z "$cid" ] && continue
            [ "$cid" = "$current_id" ] && continue
            if docker tag "$cid" "$img" 2>/dev/null; then
              print_info "已从 Docker 缓存恢复 $img"
              restored_any=true
              break
            fi
          done <<< "$cached_ids"
        done
        if [ "$restored_any" = true ]; then
          print_info "使用缓存中的旧版本镜像重新启动..."
          compose_in "$dir" up -d --force-recreate
          sleep 5
          if is_running "$dir"; then
            print_success "已从缓存恢复旧版本。"
          else
            print_error "缓存恢复后启动仍然失败。"
            compose_in "$dir" logs --tail 30 2>/dev/null || true
          fi
        else
          print_warning "Docker 缓存中未找到可用的旧版本镜像。"
        fi
      fi
    fi
    rm -rf "$bk_dir" 2>/dev/null || true
  fi
}

do_start() {
  local name="$1" dir="$2" display="$3"
  print_header "启动 $display ($name)"
  require_compose || return

  if ! is_installed "$dir"; then
    print_error "$display 未安装。"; return
  fi

  if is_running "$dir"; then
    print_warning "$display 已在运行。"; return
  fi

  if start_and_verify "$dir" "$display"; then
    print_success "$display 已启动。"
  else
    print_error "$display 启动失败，请检查上面的日志排查问题。"
  fi
}

do_restart() {
  local name="$1" dir="$2" display="$3"
  print_header "重启 $display ($name)"
  require_compose || return

  if ! is_installed "$dir"; then
    print_error "$display 未安装。"; return
  fi

  compose_in "$dir" down 2>/dev/null || true
  sleep 1

  if start_and_verify "$dir" "$display"; then
    print_success "$display 已重启。"
  else
    print_error "$display 重启失败，请检查上面的日志排查问题。"
  fi
}

do_stop() {
  local name="$1" dir="$2" display="$3"
  print_header "停止 $display ($name)"
  require_compose || return

  if ! is_installed "$dir"; then
    print_error "$display 未安装。"; return
  fi

  compose_in "$dir" stop
  print_success "$display 已停止。"
}

do_status() {
  local name="$1" dir="$2" display="$3"
  print_header "$display ($name) 状态"
  require_compose || return
  echo ""

  if ! is_installed "$dir"; then
    print_error "未安装 (找不到 $dir/docker-compose.yml)"
    return
  fi

  compose_in "$dir" ps
}

do_logs() {
  local name="$1" dir="$2" display="$3"
  print_header "$display ($name) 日志 (最近 100 行)"
  require_compose || return

  if ! is_installed "$dir"; then
    print_error "$display 未安装。"; return
  fi

  compose_in "$dir" logs --tail 100
}

do_backup() {
  local name="$1" dir="$2" display="$3" items="$4"
  print_header "备份 $display ($name)"
  require_compose || return

  if [ ! -d "$dir" ]; then
    print_error "目录 $dir 不存在。"; return
  fi

  local compose_file="$dir/docker-compose.yml"
  local db_info db_type db_dsn
  db_info=$(detect_db_type "$compose_file")
  db_type=$(echo "$db_info" | cut -d'|' -f1)
  db_dsn=$(echo "$db_info" | cut -d'|' -f2-)

  case "$db_type" in
    postgres)
      print_info "检测到 PostgreSQL，使用 pg_dump 在线备份..."
      backup_postgres "$name" "$dir" "$display" "$items" "$db_dsn"
      ;;
    sqlite)
      print_info "检测到 SQLite，使用热备..."
      backup_sqlite "$name" "$dir" "$display" "$items" "$db_dsn"
      ;;
    *)
      backup_files "$name" "$dir" "$display" "$items"
      ;;
  esac
}

do_uninstall() {
  local name="$1" dir="$2" display="$3"
  print_header "卸载 $display ($name)"
  require_compose || return

  if ! is_installed "$dir"; then
    print_error "$display 未安装。"; return
  fi

  echo -e "${YELLOW}警告: 即将停止并删除 $display 的所有容器和网络。${NC}"
  local confirm=""
  read -r -p "确认卸载容器？(y/N，N=取消整个操作): " confirm < /dev/tty
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "已取消卸载。"
    return
  fi

  local ans=""
  read -r -p "是否同时删除数据目录 $dir？[y/N]: " ans < /dev/tty

  compose_in "$dir" down

  local images
  images=$(compose_in "$dir" images -q 2>/dev/null | sort -u || true)
  if [ -n "$images" ]; then
    print_info "清理镜像（被其他容器使用的会被跳过）..."
    echo "$images" | xargs -r -n1 docker rmi 2>/dev/null || true
  fi

  if [[ "$ans" =~ ^[Yy]$ ]]; then
    rm -rf "$dir"
    print_success "$display 已完全卸载（含数据）。"
  else
    print_success "$display 容器已卸载，数据保留在 $dir。"
  fi
}

# ===== Menus =====

show_action_menu() {
  local name="$1" dir="$2" display="$3" items="$4"
  while true; do
    local status_icon=""
    if is_installed "$dir"; then
      if is_running "$dir"; then
        status_icon="${GREEN}● 运行中${NC}"
      elif is_restarting "$dir"; then
        status_icon="${RED}● 反复崩溃${NC}"
      else
        status_icon="${YELLOW}● 已停止${NC}"
      fi
    else
      status_icon="${RED}○ 未安装${NC}"
    fi
    echo ""
    echo "=============================================="
    echo -e "    $display ($name)  $status_icon"
    echo "=============================================="
    echo "  1) 安装"
    echo "  2) 更新（拉取最新镜像并重建）"
    echo "  3) 启动"
    echo "  4) 重启"
    echo "  5) 停止"
    echo "  6) 查看状态"
    echo "  7) 查看日志"
    echo "  8) 备份"
    echo "  9) 卸载"
    echo "  0) 返回上级"
    echo ""
    local choice=""
    read -r -p "请选择操作: " choice < /dev/tty
    case "$choice" in
      1) do_install   "$name" "$dir" "$display" ;;
      2) do_update    "$name" "$dir" "$display" ;;
      3) do_start     "$name" "$dir" "$display" ;;
      4) do_restart   "$name" "$dir" "$display" ;;
      5) do_stop      "$name" "$dir" "$display" ;;
      6) do_status    "$name" "$dir" "$display" ;;
      7) do_logs      "$name" "$dir" "$display" ;;
      8) do_backup    "$name" "$dir" "$display" "$items" ;;
      9) do_uninstall "$name" "$dir" "$display" ;;
      0|q|Q) return ;;
      *)  print_error "无效选择: $choice" ;;
    esac
    echo ""; read -r -p "按 Enter 继续..." < /dev/tty
  done
}

# 获取服务在主菜单中的状态图标（PostgreSQL 用 pg_installed 判断）
_service_status() {
  local name="$1" dir="$2"
  # PostgreSQL 特殊处理：用 pg_installed 而非 is_installed
  if [ "$name" = "postgres" ]; then
    if pg_installed; then
      pg_available && echo "${GREEN}运行中${NC}" || echo "${YELLOW}已停止${NC}"
    else
      echo "${RED}未安装${NC}"
    fi
    return
  fi
  if is_installed "$dir"; then
    if is_running "$dir"; then
      echo "${GREEN}运行中${NC}"
    elif is_restarting "$dir"; then
      echo "${RED}反复崩溃${NC}"
    else
      echo "${YELLOW}已停止${NC}"
    fi
  else
    echo "${RED}未安装${NC}"
  fi
}

show_main_menu() {
  while true; do
    echo ""
    echo "=============================================="
    echo "              服务器服务管理器"
    echo "=============================================="
    echo ""

    local i=1
    for svc in "${SERVICES[@]}"; do
      local sname=$(echo "$svc" | cut -d'|' -f1)
      local sdir=$(echo "$svc" | cut -d'|' -f2)
      local sdisplay=$(echo "$svc" | cut -d'|' -f3)
      local sstatus; sstatus=$(_service_status "$sname" "$sdir")
      echo -e "  $i) $sdisplay  [$sstatus]"
      i=$((i + 1))
    done


    echo ""
    echo "  a) 全部启动"
    echo "  s) 全部停止"
    echo "  r) 全部重启"
    echo "  u) 全部更新"
    echo "  b) 全部备份"
    echo "  t) 查看全部状态"
    echo "  0) 退出"
    echo ""

    local choice=""
    read -r -p "请选择服务或操作: " choice < /dev/tty

    case "$choice" in
      0|q|Q|quit|exit) print_info "已退出。"; exit 0 ;;
      a)
        for svc in "${SERVICES[@]}"; do
          local n=$(echo "$svc" | cut -d'|' -f1)
          local d=$(echo "$svc" | cut -d'|' -f2)
          local dp=$(echo "$svc" | cut -d'|' -f3)
          is_installed "$d" && do_start "$n" "$d" "$dp"
        done
        reconnect_networks
        ;;
      s)
        for svc in "${SERVICES[@]}"; do
          local n=$(echo "$svc" | cut -d'|' -f1)
          local d=$(echo "$svc" | cut -d'|' -f2)
          local dp=$(echo "$svc" | cut -d'|' -f3)
          is_installed "$d" && do_stop "$n" "$d" "$dp"
        done
        ;;
      r)
        for svc in "${SERVICES[@]}"; do
          local n=$(echo "$svc" | cut -d'|' -f1)
          local d=$(echo "$svc" | cut -d'|' -f2)
          local dp=$(echo "$svc" | cut -d'|' -f3)
          is_installed "$d" && do_restart "$n" "$d" "$dp"
        done
        reconnect_networks
        ;;
      u)
        for svc in "${SERVICES[@]}"; do
          local n=$(echo "$svc" | cut -d'|' -f1)
          local d=$(echo "$svc" | cut -d'|' -f2)
          local dp=$(echo "$svc" | cut -d'|' -f3)
          is_installed "$d" && do_update "$n" "$d" "$dp"
        done
        ;;
      b)
        for svc in "${SERVICES[@]}"; do
          local n=$(echo "$svc" | cut -d'|' -f1)
          local d=$(echo "$svc" | cut -d'|' -f2)
          local dp=$(echo "$svc" | cut -d'|' -f3)
          local it=$(echo "$svc" | cut -d'|' -f4)
          is_installed "$d" && do_backup "$n" "$d" "$dp" "$it"
        done
        ;;
      t)
        print_header "全部服务状态"
        echo ""
        for svc in "${SERVICES[@]}"; do
          local d=$(echo "$svc" | cut -d'|' -f2)
          local dp=$(echo "$svc" | cut -d'|' -f3)
          echo -e "  --- $dp ---"
          if is_installed "$d"; then
            compose_in "$d" ps 2>/dev/null || echo "  (无法获取状态)"
          else
            echo "  未安装"
          fi
          echo ""
        done
        ;;
      [1-9]|[1-9][0-9])
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
          print_error "无效选择: $choice"; continue
        fi
        local idx=$((choice - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#SERVICES[@]}" ]; then
          local svc="${SERVICES[$idx]}"
          local n=$(echo "$svc" | cut -d'|' -f1)
          local d=$(echo "$svc" | cut -d'|' -f2)
          local dp=$(echo "$svc" | cut -d'|' -f3)
          local it=$(echo "$svc" | cut -d'|' -f4)
          show_action_menu "$n" "$d" "$dp" "$it"
        else
          print_error "无效选择: $choice"
        fi
        ;;
      *) print_error "无效选择: $choice" ;;
    esac
  done
}

# ===== Entry Point =====
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  check_root
  show_main_menu
fi
