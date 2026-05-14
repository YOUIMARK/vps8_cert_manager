#!/bin/bash
# ============================================================
# vps8 CertCenter 证书管理脚本
# https://vps8.zz.cd/certcenter
# ============================================================

# ---- 路径常量 ----
BASE_DIR="${HOME}/vps8_cert_manager"
CONFIG_FILE="${BASE_DIR}/config.conf"
LOG_FILE="${BASE_DIR}/logs/cert_manager.log"
CERT_BASE_DIR="/cert"
API_BASE="https://vps8.zz.cd/api/client/certcenter"

RENEW_DAYS_BEFORE=15
RENEW_WAIT_SECONDS=30
DOWNLOAD_TYPES=("fullchain" "cert" "privkey")

# ---- 颜色 ----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 依赖检查与自动安装 ----
detect_pkg_manager() {
  command -v apt-get >/dev/null 2>&1 && echo "apt" && return
  command -v apk     >/dev/null 2>&1 && echo "apk" && return
  command -v yum     >/dev/null 2>&1 && echo "yum" && return
  command -v dnf     >/dev/null 2>&1 && echo "dnf" && return
  command -v pacman  >/dev/null 2>&1 && echo "pacman" && return
  command -v zypper  >/dev/null 2>&1 && echo "zypper" && return
  echo ""
}

ensure_tool() {
  local binary="$1" pkg="$2"
  command -v "$binary" >/dev/null 2>&1 && return 0

  echo -e "  ${YELLOW}缺少依赖：${binary}，正在自动安装...${NC}"
  local pm
  pm=$(detect_pkg_manager)
  case "$pm" in
    apt) apt-get update -qq && apt-get install -y -qq "$pkg" ;;
    apk) apk add --no-cache "$pkg" ;;
    yum) yum install -y -q "$pkg" ;;
    dnf) dnf install -y -q "$pkg" ;;
    pacman) pacman -S --noconfirm "$pkg" ;;
    zypper) zypper install -y "$pkg" ;;
    "") echo -e "  ${RED}未检测到包管理器，请手动安装 ${binary} 后重试${NC}"; return 1 ;;
  esac
  if ! command -v "$binary" >/dev/null 2>&1; then
    echo -e "  ${RED}自动安装 ${binary} 失败，请手动安装后重试${NC}"
    return 1
  fi
  echo -e "  ${GREEN}✓ ${binary} 已安装${NC}"
}

check_deps() {
  local ok=0
  ensure_tool "bash" "bash" || ok=1
  ensure_tool "curl" "curl" || ok=1
  # crontab 的包名因发行版而异：Debian/Ubuntu → cron, Alpine → dcron, CentOS → cronie
  ensure_tool "crontab" "cron" 2>/dev/null || \
    ensure_tool "crontab" "cronie" 2>/dev/null || \
    ensure_tool "crontab" "dcron" || ok=1
  return "$ok"
}

# ---- 初始化目录 ----
init_dirs() {
  mkdir -p "${BASE_DIR}/logs"
  touch "$LOG_FILE"
  if [ ! -f "$CONFIG_FILE" ]; then
    printf "API_KEY=\nDOMAINS=\n" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
  fi
  # 自动生成定时任务脚本（如不存在）
  local cron_script="${BASE_DIR}/cert_cron.sh"
  if [ ! -f "$cron_script" ]; then
    cat > "$cron_script" << 'CRON_EOF'
#!/bin/bash
# 由 cert_manager.sh 自动生成，供 crontab 调用
# 用法：cert_cron.sh <domain>

DOMAIN="$1"
BASE_DIR="${HOME}/vps8_cert_manager"
CONFIG_FILE="${BASE_DIR}/config.conf"
LOG_FILE="${BASE_DIR}/logs/cert_manager.log"
CERT_BASE_DIR="/cert"
API_BASE="https://vps8.zz.cd/api/client/certcenter"
RENEW_DAYS_BEFORE=15
RENEW_WAIT_SECONDS=30
DOWNLOAD_TYPES=("fullchain" "cert" "privkey")

[ -z "$DOMAIN" ] && echo "用法：$0 <domain>" >&2 && exit 1
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

if [ -z "$API_KEY" ]; then
  echo "$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S') [ERROR] API Key 未配置" >> "$LOG_FILE"
  exit 1
fi

log() { echo "$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}" >> "$LOG_FILE"; }

NETRC_FILE=$(mktemp)
chmod 600 "$NETRC_FILE"
echo "machine vps8.zz.cd login client password ${API_KEY}" > "$NETRC_FILE"
trap 'rm -f "$NETRC_FILE"' EXIT

api_post() { curl -sS --connect-timeout 10 --max-time 30 --netrc-file "$NETRC_FILE" -X POST "${API_BASE}/$1" -d "$2"; }

json_extract_content() {
  local raw="$1" out="$2"
  if command -v python3 >/dev/null 2>&1; then
    echo "$raw" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    content = data.get('content', '')
    if content:
        sys.stdout.write(content)
except Exception:
    pass
" > "$out" 2>/dev/null
    [ -s "$out" ] && return 0
  fi
  sed 's/.*"content"[[:space:]]*:[[:space:]]*"//; s/"}[[:space:]]*,[[:space:]]*"error".*//; s/"[[:space:]]*,[[:space:]]*"error".*//' <<< "$raw" \
    | sed 's/\\n/\
/g
s|\\/|/|g
s/"$//' > "$out"
  return 0
}

log INFO "[${DOMAIN}] 定时任务开始"

response=$(api_post "list" "domain=${DOMAIN}" 2>>"$LOG_FILE")
expire_str=""
if command -v python3 >/dev/null 2>&1; then
  expire_str=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for key in ('expire', 'expiry', 'not_after', 'valid_to'):
        if key in data and data[key] is not None:
            print(data[key])
            break
except Exception:
    pass
" 2>/dev/null)
fi
[ -z "$expire_str" ] && expire_str=$(echo "$response" | sed -n 's/.*"\(expire\|expiry\|not_after\|valid_to\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p' | head -1)
[ -z "$expire_str" ] && expire_str=$(echo "$response" | sed -n 's/.*"\(expire\|expiry\|not_after\|valid_to\)"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\2/p' | head -1)

if [ -z "$expire_str" ]; then
  log ERROR "[${DOMAIN}] 无法获取到期时间，原始响应：${response}"
  exit 1
fi

if [[ "$expire_str" =~ ^[0-9]+$ ]]; then
  expiry="$expire_str"
else
  expiry=$(TZ='Asia/Shanghai' date -d "$expire_str" +%s 2>/dev/null || \
           TZ='Asia/Shanghai' date -j -f "%Y-%m-%dT%H:%M:%S" "$expire_str" +%s 2>/dev/null)
fi

[ -z "$expiry" ] && log ERROR "[${DOMAIN}] 日期解析失败：${expire_str}" && exit 1

now=$(date +%s)
days_left=$(( (expiry - now) / 86400 ))
log INFO "[${DOMAIN}] 剩余 ${days_left} 天"

if [ "$days_left" -gt "$RENEW_DAYS_BEFORE" ]; then
  if [ -f "${CERT_BASE_DIR}/${DOMAIN}/${DOWNLOAD_TYPES[0]}.pem" ]; then
    log INFO "[${DOMAIN}] 证书有效，无需操作"
    exit 0
  fi
  log INFO "[${DOMAIN}] 本地证书不存在，补充下载"
else
  log INFO "[${DOMAIN}] 触发续签（剩余 ${days_left} 天 ≤ ${RENEW_DAYS_BEFORE} 天）"
  renew_resp=$(api_post "renew" "domain=${DOMAIN}" 2>>"$LOG_FILE")
  if echo "$renew_resp" | grep -qi '"status"\s*:\s*"already_issued"'; then
    log OK "[${DOMAIN}] 证书未到期，跳过续签"
    exit 0
  fi
  if ! echo "$renew_resp" | grep -qiE '"error"\s*:\s*null'; then
    log ERROR "[${DOMAIN}] 续签失败：${renew_resp}"
    exit 1
  fi
  log OK "[${DOMAIN}] 续签成功，等待 ${RENEW_WAIT_SECONDS}s"
  sleep "$RENEW_WAIT_SECONDS"
fi

fail=0
for type in "${DOWNLOAD_TYPES[@]}"; do
  dest_dir="${CERT_BASE_DIR}/${DOMAIN}"
  mkdir -p "$dest_dir"
  dest_file="${dest_dir}/${type}.pem"
  tmp_file="${dest_file}.tmp"
  http_code=$(curl -sS -w "%{http_code}" -o "$tmp_file" \
    --connect-timeout 10 --max-time 60 \
    --netrc-file "$NETRC_FILE" -X POST "${API_BASE}/download" \
    -d "domain=${DOMAIN}&type=${type}" 2>>"$LOG_FILE")
  if [ "$http_code" -eq 200 ] && [ -s "$tmp_file" ]; then
    local raw
    raw=$(cat "$tmp_file")
    if echo "$raw" | grep -q '"content"'; then
      json_extract_content "$raw" "${tmp_file}.pem"
      [ -s "${tmp_file}.pem" ] && mv "${tmp_file}.pem" "$tmp_file"
    fi
    [ "$type" = "privkey" ] && chmod 600 "$tmp_file" || chmod 644 "$tmp_file"
    mv "$tmp_file" "$dest_file"
    log OK "[${DOMAIN}] 下载 ${type} 成功"
  else
    rm -f "$tmp_file"
    log ERROR "[${DOMAIN}] 下载 ${type} 失败（HTTP ${http_code}）"
    fail=$(( fail + 1 ))
  fi
done

[ "$fail" -eq 0 ] && log OK "[${DOMAIN}] 定时任务完成" || log ERROR "[${DOMAIN}] ${fail} 个文件下载失败"
exit "$fail"
CRON_EOF
    chmod +x "$cron_script"
  fi
}

# ---- 日志 ----
log() {
  local level="$1"; shift
  local ts
  ts=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
  echo "${ts} [${level}] $*" >> "$LOG_FILE"
}

# ---- 配置读写 ----
load_config() {
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

save_api_key() {
  local escaped
  escaped="${1//\\/\\\\}"; escaped="${escaped//&/\\&}"; escaped="${escaped//|/\\|}"
  sed -i "s|^API_KEY=.*|API_KEY=${escaped}|" "$CONFIG_FILE"
}

load_domains() {
  DOMAIN_LIST=()
  local raw
  raw=$(grep '^DOMAINS=' "$CONFIG_FILE" | cut -d= -f2-)
  IFS=',' read -ra DOMAIN_LIST <<< "$raw"
  local cleaned=()
  for d in "${DOMAIN_LIST[@]}"; do
    [ -n "$d" ] && cleaned+=("$d")
  done
  DOMAIN_LIST=("${cleaned[@]}")
}

save_domains() {
  local joined
  joined=$(IFS=','; echo "${DOMAIN_LIST[*]}")
  sed -i "s|^DOMAINS=.*|DOMAINS=${joined}|" "$CONFIG_FILE"
}

domain_exists() {
  local target="$1"
  for d in "${DOMAIN_LIST[@]}"; do
    [ "$d" = "$target" ] && return 0
  done
  return 1
}

# ---- netrc 临时凭证 ----
setup_netrc() {
  NETRC_FILE=$(mktemp)
  chmod 600 "$NETRC_FILE"
  echo "machine vps8.zz.cd login client password ${API_KEY}" > "$NETRC_FILE"
  trap 'rm -f "$NETRC_FILE"' EXIT
}

# ---- API 调用 ----
api_post() {
  curl -sS --connect-timeout 10 --max-time 30 \
    --netrc-file "$NETRC_FILE" \
    -X POST "${API_BASE}/$1" \
    -d "$2"
}

# ---- 验证 API Key ----
verify_api_key() {
  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 30 \
    --netrc-file "$NETRC_FILE" \
    -X POST "${API_BASE}/list" \
    -d "domain=verify.test" 2>/dev/null)
  [ "$http_code" -eq 200 ] && return 0 || return 1
}

# ---- 解析到期时间戳 ----
get_expiry_timestamp() {
  local response
  response=$(api_post "list" "domain=$1" 2>>"$LOG_FILE")

  local expire_str
  # 优先用 python3 做 JSON 解析
  if command -v python3 >/dev/null 2>&1; then
    expire_str=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for key in ('expire', 'expiry', 'not_after', 'valid_to'):
        if key in data and data[key] is not None:
            print(data[key])
            break
except Exception:
    pass
" 2>/dev/null)
  fi
  # 降级：sed 提取
  [ -z "$expire_str" ] && expire_str=$(echo "$response" | sed -n 's/.*"\(expire\|expiry\|not_after\|valid_to\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p' | head -1)

  if [ -z "$expire_str" ]; then
    expire_str=$(echo "$response" | sed -n 's/.*"\(expire\|expiry\|not_after\|valid_to\)"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\2/p' | head -1)
    if [ -n "$expire_str" ]; then
      echo "$expire_str"; return 0
    fi
    echo "__RAW__${response}"; return 1
  fi

  # 如果 python3 返回的是数字时间戳，直接返回
  if [[ "$expire_str" =~ ^[0-9]+$ ]]; then
    echo "$expire_str"; return 0
  fi

  local ts
  ts=$(TZ='Asia/Shanghai' date -d "$expire_str" +%s 2>/dev/null || \
       TZ='Asia/Shanghai' date -j -f "%Y-%m-%dT%H:%M:%S" "$expire_str" +%s 2>/dev/null)
  [ -z "$ts" ] && return 1
  echo "$ts"
}

# ---- 从 JSON 响应中提取 content 字段（优先 python3，降级 sed） ----
json_extract_content() {
  local raw="$1" out="$2"
  if command -v python3 >/dev/null 2>&1; then
    echo "$raw" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    content = data.get('content', '')
    if content:
        sys.stdout.write(content)
except Exception:
    pass
" > "$out" 2>/dev/null
    [ -s "$out" ] && return 0
  fi
  # 降级：sed 最佳尝试（POSIX 字面换行，兼容 GNU/BusyBox/BSD）
  sed 's/.*"content"[[:space:]]*:[[:space:]]*"//; s/"}[[:space:]]*,[[:space:]]*"error".*//; s/"[[:space:]]*,[[:space:]]*"error".*//' <<< "$raw" \
    | sed 's/\\n/\
/g
s|\\/|/|g
s/"$//' > "$out"
  return 0
}

# ---- 下载证书 ----
do_download() {
  local domain="$1"
  local fail=0
  for type in "${DOWNLOAD_TYPES[@]}"; do
    local dest_dir="${CERT_BASE_DIR}/${domain}"
    mkdir -p "$dest_dir"
    local dest_file="${dest_dir}/${type}.pem"
    local tmp_file="${dest_file}.tmp"

    local http_code
    http_code=$(curl -sS -w "%{http_code}" -o "$tmp_file" \
      --connect-timeout 10 --max-time 60 \
      --netrc-file "$NETRC_FILE" \
      -X POST "${API_BASE}/download" \
      -d "domain=${domain}&type=${type}" 2>>"$LOG_FILE")

    if [ "$http_code" -eq 200 ] && [ -s "$tmp_file" ]; then
      # API 返回 JSON，证书内容在 content 字段中
      local raw
      raw=$(cat "$tmp_file")
      if echo "$raw" | grep -q '"content"'; then
        json_extract_content "$raw" "${tmp_file}.pem"
        [ -s "${tmp_file}.pem" ] && mv "${tmp_file}.pem" "$tmp_file"
      fi
      [ "$type" = "privkey" ] && chmod 600 "$tmp_file" || chmod 644 "$tmp_file"
      mv "$tmp_file" "$dest_file"
      echo -e "  ${GREEN}✓${NC} ${type} -> ${dest_file}"
      log OK "[${domain}] 下载 ${type} 成功"
    else
      rm -f "$tmp_file"
      echo -e "  ${RED}✗${NC} ${type} 下载失败（HTTP ${http_code}）"
      log ERROR "[${domain}] 下载 ${type} 失败（HTTP ${http_code}）"
      fail=$(( fail + 1 ))
    fi
  done
  return "$fail"
}

# ---- 续签 ----
do_renew() {
  local domain="$1"
  local response
  response=$(api_post "renew" "domain=${domain}" 2>>"$LOG_FILE")

  if echo "$response" | grep -qi '"status"\s*:\s*"already_issued"'; then
    local msg
    msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    echo -e "  ${YELLOW}${msg:-证书未到期，暂不需要续签}${NC}"
    log OK "[${domain}] 续签跳过（证书未到期）"
    return 2
  fi
  if echo "$response" | grep -qiE '"error"\s*:\s*null'; then
    log OK "[${domain}] 续签请求成功"
    return 0
  fi
  log ERROR "[${domain}] 续签失败：${response}"
  return 1
}

# ---- crontab 管理 ----
add_cron() {
  local domain="$1"
  local script_path="${BASE_DIR}/cert_cron.sh"

  if crontab -l 2>/dev/null | grep -q "cert_cron.sh.*${domain}"; then
    echo -e "${YELLOW}该域名的定时任务已存在，跳过${NC}"
    return
  fi

  local tmp_cron
  tmp_cron=$(mktemp)
  crontab -l 2>/dev/null > "$tmp_cron"
  echo "0 1 * * * TZ=Asia/Shanghai ${script_path} ${domain} >> ${LOG_FILE} 2>&1" >> "$tmp_cron"
  crontab "$tmp_cron"
  rm -f "$tmp_cron"
  echo -e "${GREEN}✓ 已添加定时任务（每天北京时间 01:00 自动续签）${NC}"
  log INFO "[${domain}] 添加 crontab 自动续签"
}

remove_cron() {
  local domain="$1"
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -v "cert_cron.sh.*${domain}" > "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  log INFO "[${domain}] 移除 crontab 自动续签"
}

# ---- 分隔线 ----
hr() { echo -e "${CYAN}──────────────────────────────────────${NC}"; }

# ============================================================
# 菜单功能
# ============================================================

menu_query() {
  hr
  echo -e "${BOLD}查询证书${NC}"
  hr
  load_domains

  local domain=""
  if [ "${#DOMAIN_LIST[@]}" -gt 0 ]; then
    echo "已保存的域名："
    for i in "${!DOMAIN_LIST[@]}"; do
      echo "  $((i+1)). ${DOMAIN_LIST[$i]}"
    done
    echo "  0. 输入其他域名"
    echo ""
    read -rp "请选择: " choice
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
      read -rp "请输入域名: " domain
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DOMAIN_LIST[@]}" ]; then
      domain="${DOMAIN_LIST[$((choice-1))]}"
    else
      echo "无效选择"; return
    fi
  else
    read -rp "请输入域名: " domain
  fi

  [ -z "$domain" ] && echo "域名不能为空" && return

  echo -e "\n正在查询 ${CYAN}${domain}${NC} ..."
  local result
  result=$(get_expiry_timestamp "$domain")

  if [[ "$result" == __RAW__* ]]; then
    echo -e "${RED}查询失败，原始响应：${NC}"
    echo "${result#__RAW__}"
    return
  fi

  if [ -z "$result" ]; then
    echo -e "${RED}查询失败，无法解析到期时间${NC}"
    return
  fi

  local now days_left expire_date
  now=$(date +%s)
  days_left=$(( (result - now) / 86400 ))
  expire_date=$(date -d "@${result}" '+%Y-%m-%d' 2>/dev/null || date -r "$result" '+%Y-%m-%d' 2>/dev/null)

  echo -e "\n  域名：${CYAN}${domain}${NC}"
  echo -e "  到期：${expire_date}"
  if [ "$days_left" -le "$RENEW_DAYS_BEFORE" ]; then
    echo -e "  剩余：${RED}${days_left} 天${NC}（建议续签）"
  else
    echo -e "  剩余：${GREEN}${days_left} 天${NC}"
  fi
  echo ""

  load_domains
  if ! domain_exists "$domain"; then
    read -rp "是否保存该域名？(y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      DOMAIN_LIST+=("$domain")
      save_domains
      echo -e "${GREEN}✓ 已保存${NC}"
    fi
  fi
}

menu_download() {
  hr
  echo -e "${BOLD}下载证书${NC}"
  hr
  load_domains

  local domain=""
  if [ "${#DOMAIN_LIST[@]}" -gt 0 ]; then
    echo "已保存的域名："
    for i in "${!DOMAIN_LIST[@]}"; do
      echo "  $((i+1)). ${DOMAIN_LIST[$i]}"
    done
    echo "  0. 输入其他域名"
    echo ""
    read -rp "请选择: " choice
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
      read -rp "请输入域名: " domain
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DOMAIN_LIST[@]}" ]; then
      domain="${DOMAIN_LIST[$((choice-1))]}"
    else
      echo "无效选择"; return
    fi
  else
    read -rp "请输入域名: " domain
  fi

  [ -z "$domain" ] && echo "域名不能为空" && return

  echo -e "\n正在下载 ${CYAN}${domain}${NC} 的证书..."
  do_download "$domain"

  if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}下载完成${NC}"
    log INFO "[${domain}] 下载完成"
    echo ""
    read -rp "是否设置每天自动续签？(y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      add_cron "$domain"
      load_domains
      if ! domain_exists "$domain"; then
        DOMAIN_LIST+=("$domain")
        save_domains
      fi
    fi
  else
    echo -e "\n${RED}部分文件下载失败，请查看日志：${LOG_FILE}${NC}"
  fi
}

menu_renew() {
  hr
  echo -e "${BOLD}手动续签${NC}"
  hr
  load_domains

  local domain=""
  if [ "${#DOMAIN_LIST[@]}" -gt 0 ]; then
    echo "已保存的域名："
    for i in "${!DOMAIN_LIST[@]}"; do
      echo "  $((i+1)). ${DOMAIN_LIST[$i]}"
    done
    echo "  0. 输入其他域名"
    echo ""
    read -rp "请选择: " choice
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
      read -rp "请输入域名: " domain
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DOMAIN_LIST[@]}" ]; then
      domain="${DOMAIN_LIST[$((choice-1))]}"
    else
      echo "无效选择"; return
    fi
  else
    read -rp "请输入域名: " domain
  fi

  [ -z "$domain" ] && echo "域名不能为空" && return

  echo -e "\n正在对 ${CYAN}${domain}${NC} 发起续签..."
  do_renew "$domain"
  local renew_rc=$?
  if [ "$renew_rc" -eq 0 ]; then
    echo -e "${GREEN}续签请求已提交，等待 ${RENEW_WAIT_SECONDS}s 后下载...${NC}"
    sleep "$RENEW_WAIT_SECONDS"
    echo -e "\n正在下载最新证书..."
    do_download "$domain"
    echo -e "\n${GREEN}完成${NC}"
  elif [ "$renew_rc" -eq 2 ]; then
    : # already_issued，已在 do_renew 中打印提示
  else
    echo -e "${RED}续签失败，请查看日志：${LOG_FILE}${NC}"
  fi
}

menu_manage() {
  hr
  echo -e "${BOLD}管理已保存域名${NC}"
  hr
  load_domains

  if [ "${#DOMAIN_LIST[@]}" -eq 0 ]; then
    echo "暂无已保存的域名"
    echo -e "${YELLOW}提示：在「查询证书」或「下载证书」时选择保存，域名会自动添加${NC}"
    return
  fi

  echo "已保存的域名（均已设置自动续签）："
  echo ""
  for i in "${!DOMAIN_LIST[@]}"; do
    local cron_status=""
    crontab -l 2>/dev/null | grep -q "cert_cron.sh.*${DOMAIN_LIST[$i]}" \
      && cron_status=" ${GREEN}[定时任务已启用]${NC}"
    echo -e "  $((i+1)). ${DOMAIN_LIST[$i]}${cron_status}"
  done
  echo ""
  read -rp "输入序号删除（直接回车返回）: " choice
  [ -z "$choice" ] && return

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DOMAIN_LIST[@]}" ]; then
    local target="${DOMAIN_LIST[$((choice-1))]}"
    read -rp "确认删除 ${target} 的自动续签？(y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      remove_cron "$target"
      DOMAIN_LIST=("${DOMAIN_LIST[@]:0:$((choice-1))}" "${DOMAIN_LIST[@]:$choice}")
      save_domains
      echo -e "${GREEN}已删除 ${target} 的自动续签${NC}"
    fi
  else
    echo "无效序号"
  fi
}

menu_uninstall() {
  hr
  echo -e "${BOLD}${RED}卸载脚本${NC}"
  hr
  echo "将要执行以下操作："
  echo -e "  ${RED}✗${NC} 删除目录：${BASE_DIR}"
  echo -e "  ${RED}✗${NC} 移除所有相关 crontab 条目"
  echo ""
  echo -e "  ${YELLOW}！保留${NC}：/cert 目录及其中的证书文件"
  echo -e "  如需删除证书，请卸载完成后手动执行："
  echo -e "  ${BOLD}rm -rf /cert${NC}"
  echo ""
  read -rp "确认卸载？输入 yes 继续: " confirm
  [ "$confirm" != "yes" ] && echo "已取消" && return

  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -vF "${BASE_DIR}/cert_cron.sh" | grep -vF "${BASE_DIR}/cert_manager.sh" > "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  echo -e "${GREEN}✓ 已清除 crontab${NC}"

  rm -rf "$BASE_DIR"
  echo -e "${GREEN}✓ 已删除 ${BASE_DIR}${NC}"
  echo ""
  echo "卸载完成。"
  exit 0
}

# ============================================================
# 首次运行 / API Key 检查
# ============================================================
first_run_or_check_key() {
  load_config

  if [ -z "$API_KEY" ]; then
    echo ""
    echo -e "${BOLD}欢迎使用 vps8 CertCenter 证书管理脚本${NC}"
    hr
    echo -e "首次使用，请输入您的 API Key。"
    echo -e "API Key 可在 ${CYAN}https://vps8.zz.cd/client/profile${NC} 获取。"
    echo ""
    while true; do
      read -rsp "API Key: " input_key
      echo ""
      [ -z "$input_key" ] && echo "API Key 不能为空" && continue

      API_KEY="$input_key"
      setup_netrc

      echo -n "正在验证..."
      if verify_api_key; then
        save_api_key "$API_KEY"
        echo -e " ${GREEN}验证成功${NC}"
        break
      else
        echo -e " ${RED}验证失败，请检查 API Key${NC}"
        rm -f "$NETRC_FILE"
        API_KEY=""
      fi
    done
  else
    setup_netrc
  fi
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
  while true; do
    echo ""
    hr
    echo -e "  ${BOLD}vps8 CertCenter 证书管理${NC}"
    hr
    echo "  1. 查询证书"
    echo "  2. 下载证书"
    echo "  3. 手动续签"
    echo "  4. 管理已保存域名"
    echo "  5. 卸载脚本"
    echo "  0. 退出"
    hr
    read -rp "请选择: " opt
    case "$opt" in
      1) menu_query ;;
      2) menu_download ;;
      3) menu_renew ;;
      4) menu_manage ;;
      5) menu_uninstall ;;
      0) echo "再见"; exit 0 ;;
      *) echo -e "${YELLOW}无效选项${NC}" ;;
    esac
  done
}

# ============================================================
# 入口
# ============================================================
echo -e "${BOLD}vps8 CertCenter 证书管理脚本${NC}"
check_deps || exit 1
init_dirs

# 脚本自身不在 BASE_DIR 时，复制过去并提示用户，然后删除原文件
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TARGET="${BASE_DIR}/cert_manager.sh"
if [ "$SELF" != "$TARGET" ]; then
  cp "$SELF" "$TARGET"
  chmod +x "$TARGET"
  echo -e "${GREEN}✓ 脚本已安装到 ${TARGET}${NC}"
  echo -e "${YELLOW}  原文件将被删除，以后请运行：bash ${TARGET}${NC}"
  echo ""
  rm -f "$SELF"
fi

first_run_or_check_key
main_menu
