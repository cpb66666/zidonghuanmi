#!/usr/bin/env bash
# ==============================================================================
# install.sh - 233boy/sing-box 每日自动换密与面板同步工具 一键安装/管理脚本
# 使用方式:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<你的仓库名>/main/install.sh)
# ==============================================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 如果你希望 install.sh 从你的 GitHub 仓库拉取独立的 sb-rotator.sh，可填写下方地址；
# 留空或拉取失败时，install.sh 会自动释放内置的完整版 sb-rotator.sh，单文件也可独立运行！
GITHUB_RAW_BASE_URL=""

INSTALL_BIN="/usr/local/bin/sb-rotator"
ALIAS_BIN="/usr/local/bin/sbr"
INSTALL_DIR="/etc/sb-rotator"

check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        echo -e "${RED}[错误] 请使用 root 用户运行此一键脚本 (sudo -i)${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl sed awk grep flock; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done

    if ! command -v crontab >/dev/null 2>&1 && [[ ! -d /etc/cron.d ]]; then
        missing+=("cron")
    fi

    if (( ${#missing[@]} > 0 )); then
        echo -e "${YELLOW}[提示] 正在安装必要系统组件: ${missing[*]} ...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl sed gawk grep util-linux cron openssl ca-certificates >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl sed gawk grep util-linux cronie openssl ca-certificates >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl sed gawk grep util-linux dcron openssl ca-certificates >/dev/null 2>&1
        fi
    fi

    # 确保 cron 服务处于运行状态
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
}

check_singbox_installed() {
    if ! command -v sing-box >/dev/null 2>&1 && ! command -v sb >/dev/null 2>&1 && [[ ! -d /etc/sing-box ]]; then
        echo -e "${YELLOW}=================================================================${NC}"
        echo -e "${YELLOW}[提示] 未检测到 233boy/sing-box 脚本环境 (/etc/sing-box)${NC}"
        echo -e "是否现在为您自动调用 233boy 官方脚本安装 sing-box？"
        read -rp "请输入 (y/n，默认 n 跳过): " auto_sb
        if [[ "${auto_sb:-n}" =~ ^[Yy]$ ]]; then
            bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh)
        else
            echo -e "${YELLOW}[提示] 将继续安装 sb-rotator，请稍后确保已安装 233boy/sing-box。${NC}"
        fi
    fi
}

deploy_core_script() {
    mkdir -p "${INSTALL_DIR}"
    if [[ -n "${GITHUB_RAW_BASE_URL}" ]]; then
        echo -e "${CYAN}[INFO] 正在从远程源下载 sb-rotator.sh ...${NC}"
        if curl -fsSL --connect-timeout 10 "${GITHUB_RAW_BASE_URL%/}/sb-rotator.sh" -o "${INSTALL_BIN}"; then
            chmod +x "${INSTALL_BIN}"
            ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
            return 0
        fi
        echo -e "${YELLOW}[WARN] 远程拉取失败，自动切换为内置完整脚本部署...${NC}"
    fi

    cat > "${INSTALL_BIN}" <<'__EOF_SB_ROTATOR_CORE__'
#!/usr/bin/env bash
# ==============================================================================
# sb-rotator.sh - 233boy/sing-box 每日自动密码/UUID轮换与面板API同步工具 (核心脚本)
# 适配脚本: https://github.com/233boy/sing-box
# ==============================================================================

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C

VERSION="1.2.0"
INSTALL_DIR="${INSTALL_DIR:-/etc/sb-rotator}"
CONFIG_FILE="${CONFIG_FILE:-${INSTALL_DIR}/config.env}"
BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
CACHE_DIR="${CACHE_DIR:-${INSTALL_DIR}/cache}"
LOG_FILE="${LOG_FILE:-/var/log/sb-rotator.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/sb-rotator.lock}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/sb-rotator}"
SB_CONF_DIR="${SB_CONF_DIR:-/etc/sing-box/conf}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================================================
# 基础工具与日志函数
# ==============================================================================

ensure_dirs() {
    mkdir -p "${INSTALL_DIR}" "${BACKUP_DIR}" "${CACHE_DIR}"
    touch "${LOG_FILE}" 2>/dev/null || true
    chmod 600 "${CONFIG_FILE}" 2>/dev/null || true
}

now_beijing() {
    TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'
}

now_iso8601() {
    TZ='Asia/Shanghai' date '+%Y-%m-%dT%H:%M:%S+08:00'
}

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(now_beijing)"
    echo "[${ts} CST] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

info()    { echo -e "${GREEN}[INFO]${NC} $*"; log_msg "INFO" "$*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; log_msg "WARN" "$*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; log_msg "ERROR" "$*"; }
step()    { echo -e "${CYAN}[STEP]${NC} $*"; log_msg "STEP" "$*"; }

# 去除 233boy 脚本输出的 ANSI 颜色控制字符与回车符
strip_ansi() {
    sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'
}

# JSON 字符串安全转义
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# 查找 233boy sing-box 管理命令路径
find_sb_bin() {
    if [[ -n "${SB_BIN:-}" && -x "${SB_BIN}" ]]; then
        echo "${SB_BIN}"
        return 0
    fi
    local candidate
    for candidate in /usr/local/bin/sing-box /usr/local/bin/sb /usr/bin/sing-box /bin/sing-box /etc/sing-box/sh/sing-box.sh; do
        if [[ -x "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    if command -v sing-box >/dev/null 2>&1; then
        command -v sing-box
        return 0
    fi
    if command -v sb >/dev/null 2>&1; then
        command -v sb
        return 0
    fi
    return 1
}

# 日志轮转（防止日志文件无限增长，超过 5MB 自动截断保留最近 2000 行）
rotate_log_if_needed() {
    if [[ -f "${LOG_FILE}" ]]; then
        local size
        size=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
        if (( size > 5242880 )); then
            tail -n 2000 "${LOG_FILE}" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "${LOG_FILE}"
            log_msg "INFO" "日志文件超过 5MB，已自动裁剪保留最新 2000 行"
        fi
    fi
}

# ==============================================================================
# 配置加载与保存
# ==============================================================================

load_config() {
    # 默认值
    PANEL_URL=""
    API_KEY=""
    NODE_IDS=""
    CRON_HOUR="4"
    CRON_MINUTE="0"
    SYNC_MODE="batch"
    MAX_RETRIES="3"
    RETRY_DELAY="5"
    RANDOM_JITTER_MAX="15"
    ROLLBACK_ON_FAIL="true"
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    CUSTOM_SERVER_NAME=""

    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
    fi
}

save_config() {
    ensure_dirs
    cat > "${CONFIG_FILE}" <<EOF
# sb-rotator 配置文件 (自动生成，请勿泄露 API_KEY)
# 订阅管理面板 API 地址 (支持填写基础域名或完整接口地址)
PANEL_URL="${PANEL_URL}"

# 面板通信密钥 (API Key / Communication Token)
API_KEY="${API_KEY}"

# 节点 ID 映射列表 (英文逗号分隔，按 sing-box info 序号 1,2,3... 依次对应；填 0 或 - 表示跳过该序号节点)
# 也支持显式绑定格式: 101:AnyTLS-36542.json,102:Hysteria2-15642.json
NODE_IDS="${NODE_IDS}"

# 每日自动更换密码时间 (以北京时间 Asia/Shanghai 为准，默认凌晨 04:00)
CRON_HOUR="${CRON_HOUR:-4}"
CRON_MINUTE="${CRON_MINUTE:-0}"

# API 同步模式: batch (单次请求批量推送全部节点) 或 single (逐个节点分别推送)
SYNC_MODE="${SYNC_MODE:-batch}"

# API 请求失败重试次数与间隔(秒)
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# 定时任务随机延迟上限(秒)，避免多台节点同一秒并发请求面板 (手动执行时不延迟)
RANDOM_JITTER_MAX="${RANDOM_JITTER_MAX:-15}"

# 当面板 API 同步最终失败时，是否自动回滚节点原密码/UUID配置 (true/false)
ROLLBACK_ON_FAIL="${ROLLBACK_ON_FAIL:-true}"

# 可选: 自定义服务器标识名称 (留空则使用 hostname)
CUSTOM_SERVER_NAME="${CUSTOM_SERVER_NAME:-}"

# 可选: Telegram 机器人告警通知配置
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

# 规范化面板接口地址
get_endpoint_url() {
    local url="${PANEL_URL%/}"
    if [[ -z "${url}" ]]; then
        echo ""
        return 1
    fi
    # 如果用户只填了域名（如 https://panel.example.com），自动补全标准路径 /api/v1/node/rotate
    if [[ "${url}" =~ ^https?://[^/]+$ ]]; then
        echo "${url}/api/v1/node/rotate"
    else
        echo "${url}"
    fi
}

# ==============================================================================
# 节点自动发现与解析 (严格遵循 233boy sing-box 命令逻辑)
# ==============================================================================

# 发现所有节点配置，输出格式: "序号|配置文件名(含.json)|配置短名(不含.json)"
discover_nodes() {
    local sb_bin
    sb_bin="$(find_sb_bin)" || {
        err "未检测到 233boy sing-box 脚本，请先安装 https://github.com/233boy/sing-box"
        return 1
    }

    local raw_info
    # 向 sing-box info 输入空行，当存在多个配置时会打印编号列表 "1) xxx.json" 后退出
    raw_info="$(printf '\n' | "${sb_bin}" info 2>&1 | strip_ansi)"

    local found_numbered=0
    local line idx fname shortname

    while IFS= read -r line; do
        if [[ "${line}" =~ ^[[:space:]]*([0-9]+)\)[[:space:]]+([^[:space:]]+\.json)[[:space:]]*$ ]]; then
            idx="${BASH_REMATCH[1]}"
            fname="${BASH_REMATCH[2]}"
            shortname="${fname%.json}"
            echo "${idx}|${fname}|${shortname}"
            found_numbered=1
        fi
    done <<< "${raw_info}"

    if (( found_numbered == 1 )); then
        return 0
    fi

    # 如果 sing-box info 没有出现 "1) xxx.json"，说明当前只有 1 个节点（233boy 脚本自动选中了该唯一节点）
    # 或者通过 /etc/sing-box/conf/*.json 进行兜底读取，保持与 233boy 相同的字典序
    if [[ -d "${SB_CONF_DIR}" ]]; then
        local i=1
        local f
        shopt -s nullglob
        for f in "${SB_CONF_DIR}"/*.json; do
            fname="$(basename "$f")"
            shortname="${fname%.json}"
            echo "${i}|${fname}|${shortname}"
            ((i++))
        done
        shopt -u nullglob
        if (( i > 1 )); then
            return 0
        fi
    fi

    return 1
}

# 解析某个节点的面板 Node ID
# 参数: $1=序号(1,2,3...) $2=配置文件名(如 AnyTLS-36542.json)
resolve_panel_node_id() {
    local target_idx="$1"
    local target_fname="$2"
    local target_short="${target_fname%.json}"

    local IFS=','
    read -ra items <<< "${NODE_IDS// /,}"

    # 1. 优先检查是否有显式绑定 (例如 101:AnyTLS-36542.json 或 101:AnyTLS-36542)
    local item k v
    for item in "${items[@]}"; do
        if [[ "${item}" == *:* ]]; then
            k="${item%%:*}"
            v="${item#*:}"
            if [[ "${v}" == "${target_fname}" || "${v}" == "${target_short}" ]]; then
                echo "${k}"
                return 0
            fi
        fi
    done

    # 2. 按顺序映射 (第 1 个 ID 对应节点 1，第 2 个 ID 对应节点 2...)
    local pos=$(( target_idx - 1 ))
    if (( pos >= 0 && pos < ${#items[@]} )); then
        local val="${items[$pos]}"
        # 去除可能的 :后缀
        val="${val%%:*}"
        if [[ -n "${val}" && "${val}" != "0" && "${val}" != "-" ]]; then
            echo "${val}"
            return 0
        fi
    fi

    echo ""
    return 1
}

# 调用 `sing-box info [name]` 查询节点详情并判断协议与凭据类型
# 返回格式: protocol|port|rotate_cmd_type|current_credential
inspect_node_info() {
    local shortname="$1"
    local fname="$2"
    local sb_bin
    sb_bin="$(find_sb_bin)" || return 1

    local info_out
    info_out="$(printf '\n' | "${sb_bin}" info "${shortname}" 2>&1 | strip_ansi)"

    # 1. 提取协议名称
    local proto=""
    proto="$(echo "${info_out}" | awk -F'[=:]' '/协议|\(protocol\)/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print tolower($2); exit}')"
    if [[ -z "${proto}" ]]; then
        # 从文件名推断 (例如 VLESS-REALITY-15624.json -> vless-reality)
        proto="$(echo "${shortname}" | sed -E 's/-[0-9]+$//' | tr '[:upper:]' '[:lower:]')"
    fi

    # 2. 提取端口
    local port=""
    port="$(echo "${info_out}" | awk -F'[=:]' '/端口|\(port\)/ {gsub(/[^0-9]/, "", $2); if ($2 != "") {print $2; exit}}')"
    if [[ -z "${port}" && "${shortname}" =~ -([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    fi
    [[ -z "${port}" ]] && port="0"

    # 3. 判定应该使用 `sing-box id [name] auto` 还是 `sing-box passwd [name] auto`
    local rotate_type=""
    if echo "${info_out}" | grep -Eqi '用户ID|\(id\)|uuid'; then
        rotate_type="id"
    elif echo "${info_out}" | grep -Eqi '密码|\(password\)|passwd'; then
        rotate_type="passwd"
    fi

    # 如果输出文本未明确匹配，根据协议名或配置文件内容精确判断
    if [[ -z "${rotate_type}" ]]; then
        case "${proto}" in
            *vless*|*vmess*|*tuic*)
                rotate_type="id"
                ;;
            *anytls*|*hysteria*|*hy2*|*trojan*|*shadowsocks*|*ss*|*socks*)
                rotate_type="passwd"
                ;;
            *)
                if [[ -f "${SB_CONF_DIR}/${fname}" ]] && grep -q '"uuid"' "${SB_CONF_DIR}/${fname}" 2>/dev/null; then
                    rotate_type="id"
                else
                    rotate_type="passwd"
                fi
                ;;
        esac
    fi

    # 4. 提取当前密码或 UUID
    local cred=""
    if [[ "${rotate_type}" == "id" ]]; then
        cred="$(echo "${info_out}" | awk -F'[=:]' '/用户ID|\(id\)|uuid/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
    else
        cred="$(echo "${info_out}" | awk -F'[=:]' '/密码|\(password\)|passwd/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
    fi
    if [[ -z "${cred}" && -f "${SB_CONF_DIR}/${fname}" ]]; then
        cred="$(grep -Eo '"(uuid|password)"[[:space:]]*:[[:space:]]*"[^"]+"' "${SB_CONF_DIR}/${fname}" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
    fi

    echo "${proto}|${port}|${rotate_type}|${cred}"
}

# 调用 `sing-box url [name]` 获取完整节点链接
get_node_url() {
    local shortname="$1"
    local proto="$2"
    local port="$3"
    local cred="$4"
    local sb_bin
    sb_bin="$(find_sb_bin)" || return 1

    local url_out
    url_out="$(printf '\n' | "${sb_bin}" url "${shortname}" 2>&1 | strip_ansi)"

    # 提取包含 scheme:// 的完整链接行
    local node_url=""
    node_url="$(echo "${url_out}" | grep -Eo '(vless|vmess|trojan|hysteria2|hy2|tuic|ss|shadowsocks|anytls|socks5?|http|https)://[^[:space:]]+' | tail -n1)"

    # 若 `sing-box url` 未打印标准带 scheme 的行，尝试从 `sing-box info` 中提取
    if [[ -z "${node_url}" ]]; then
        local info_out
        info_out="$(printf '\n' | "${sb_bin}" info "${shortname}" 2>&1 | strip_ansi)"
        node_url="$(echo "${info_out}" | grep -Eo '(vless|vmess|trojan|hysteria2|hy2|tuic|ss|shadowsocks|anytls|socks5?|http|https)://[^[:space:]]+' | tail -n1)"
    fi

    # 针对部分版本 AnyTLS 若无直接 URL 输出的兜底拼装
    if [[ -z "${node_url}" && "${proto}" == *anytls* && -n "${cred}" ]]; then
        local server_ip
        server_ip="$(get_server_ip)"
        node_url="anytls://${cred}@${server_ip}:${port}#${shortname}"
    fi

    echo "${node_url}"
}

# 获取本机公网 IP（优先使用 `sing-box ip`）
get_server_ip() {
    local sb_bin ip=""
    if sb_bin="$(find_sb_bin)"; then
        ip="$(printf '\n' | "${sb_bin}" ip 2>/dev/null | strip_ansi | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
    fi
    if [[ -z "${ip}" ]]; then
        ip="$(curl -fsSL4 --connect-timeout 4 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    [[ -z "${ip}" ]] && ip="127.0.0.1"
    echo "${ip}"
}

# ==============================================================================
# 备份与回滚机制
# ==============================================================================

backup_configs() {
    ensure_dirs
    if [[ -d "${SB_CONF_DIR}" ]]; then
        rm -rf "${BACKUP_DIR}/ prev" 2>/dev/null || true
        mkdir -p "${BACKUP_DIR}/latest"
        cp -af "${SB_CONF_DIR}"/*.json "${BACKUP_DIR}/latest/" 2>/dev/null || true
        date '+%Y-%m-%d %H:%M:%S' > "${BACKUP_DIR}/latest/backup_time.txt"
        info "已备份当前 sing-box 节点配置至 ${BACKUP_DIR}/latest"
    fi
}

rollback_configs() {
    local sb_bin
    sb_bin="$(find_sb_bin)" || return 1
    if [[ -d "${BACKUP_DIR}/latest" ]] && compgen -G "${BACKUP_DIR}/latest/*.json" >/dev/null; then
        warn "正在回滚 sing-box 节点配置至轮换前状态..."
        cp -af "${BACKUP_DIR}/latest"/*.json "${SB_CONF_DIR}/"
        "${sb_bin}" restart >/dev/null 2>&1 || true
        info "已成功恢复轮换前的节点配置并重启 sing-box 服务"
        return 0
    else
        err "未找到可用的备份配置，无法执行回滚"
        return 1
    fi
}

# ==============================================================================
# Telegram 通知推送 (可选)
# ==============================================================================

send_tg_notify() {
    local status_title="$1"
    local detail_msg="$2"
    if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        return 0
    fi
    local srv_name="${CUSTOM_SERVER_NAME:-$(hostname)}"
    local text="<b>[sb-rotator] ${status_title}</b>%0A主机: <code>${srv_name}</code>%0A时间: <code>$(now_beijing) CST</code>%0A详情: ${detail_msg}"
    curl -fsSL --connect-timeout 8 --max-time 15 \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=${text}" >/dev/null 2>&1 || warn "Telegram 通知发送失败"
}

# ==============================================================================
# API 签名与上报通信实现
# ==============================================================================

# 计算 HMAC-SHA256 签名: HMAC_SHA256("${timestamp}.${payload}", "${API_KEY}")
compute_signature() {
    local timestamp="$1"
    local payload="$2"
    if command -v openssl >/dev/null 2>&1; then
        printf '%s.%s' "${timestamp}" "${payload}" | openssl dgst -sha256 -hmac "${API_KEY}" | awk '{print $NF}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s.%s.%s' "${timestamp}" "${payload}" "${API_KEY}" | sha256sum | awk '{print $1}'
    else
        echo "unsigned"
    fi
}

# 发送 JSON 数据到管理面板（带指数退避重试）
post_to_panel() {
    local payload="$1"
    local endpoint
    endpoint="$(get_endpoint_url)" || {
        err "未配置有效的 PANEL_URL"
        return 1
    }

    local max_retries="${MAX_RETRIES:-3}"
    local retry_delay="${RETRY_DELAY:-5}"
    local attempt=1
    local ts sig http_code resp_file
    resp_file="$(mktemp /tmp/sb-rotator-resp.XXXXXX)"

    while (( attempt <= max_retries )); do
        ts="$(date +%s)"
        sig="$(compute_signature "${ts}" "${payload}")"

        http_code="$(curl -sS --connect-timeout 10 --max-time 25 \
            -o "${resp_file}" -w "%{http_code}" \
            -X POST "${endpoint}" \
            -H "Content-Type: application/json; charset=utf-8" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "X-API-Key: ${API_KEY}" \
            -H "X-Timestamp: ${ts}" \
            -H "X-Signature: ${sig}" \
            -H "User-Agent: sb-rotator/${VERSION}" \
            -d "${payload}" 2>>"${LOG_FILE}" || echo "000")"

        local resp_body=""
        [[ -f "${resp_file}" ]] && resp_body="$(head -c 500 "${resp_file}" | tr '\n' ' ')"

        if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
            rm -f "${resp_file}"
            info "面板 API 同步成功 (HTTP ${http_code})，响应: ${resp_body:-OK}"
            return 0
        fi

        warn "面板 API 请求失败 (第 ${attempt}/${max_retries} 次尝试, HTTP ${http_code})，响应: ${resp_body:-无响应}"
        if (( attempt < max_retries )); then
            sleep "${retry_delay}"
            retry_delay=$(( retry_delay * 2 ))
        fi
        ((attempt++))
    done

    rm -f "${resp_file}"
    # 保存失败载荷到本地缓存以便后续重试或排查
    printf '%s\n' "${payload}" > "${CACHE_DIR}/last_failed_payload.json"
    err "面板 API 同步在 ${max_retries} 次尝试后仍然失败，载荷已保存至 ${CACHE_DIR}/last_failed_payload.json"
    return 1
}

# ==============================================================================
# 核心流程：密码/UUID 轮换与同步
# 参数:
#   --cron       定时任务触发（启用随机抖动延迟）
#   --sync-only  仅获取当前链接并上传到面板，不修改密码/UUID
#   --dry-run    演练模式：仅展示将要执行的命令与生成的 JSON，不实际改密
# ==============================================================================

run_rotation() {
    local mode="rotate"
    local is_cron=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron)      is_cron=1 ;;
            --sync-only) mode="sync_only" ;;
            --dry-run)   mode="dry_run" ;;
        esac
        shift
    done

    ensure_dirs
    rotate_log_if_needed
    load_config

    if [[ -z "${PANEL_URL}" || -z "${API_KEY}" || -z "${NODE_IDS}" ]]; then
        err "配置不完整 (PANEL_URL / API_KEY / NODE_IDS 不能为空)，请先运行 sb-rotator 进行配置"
        return 1
    fi

    # 进程锁，防止并发执行
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        warn "检测到另一个 sb-rotator 实例正在运行，本次任务跳过"
        return 1
    fi

    # 若由 Cron 触发且设置了随机延迟，防止多台机器同一秒打爆面板
    if (( is_cron == 1 )) && [[ "${RANDOM_JITTER_MAX:-0}" =~ ^[0-9]+$ ]] && (( RANDOM_JITTER_MAX > 0 )); then
        local delay=$(( RANDOM % RANDOM_JITTER_MAX ))
        if (( delay > 0 )); then
            info "定时任务触发，随机等待 ${delay} 秒以分散面板并发压力..."
            sleep "${delay}"
        fi
    fi

    local sb_bin
    sb_bin="$(find_sb_bin)" || {
        err "未找到 sing-box 管理命令，请确认已安装 233boy/sing-box"
        return 1
    }

    step "开始扫描本机 sing-box 节点配置..."
    local nodes_raw
    nodes_raw="$(discover_nodes)" || {
        err "未发现任何 sing-box 节点配置文件"
        return 1
    }

    if [[ "${mode}" == "rotate" ]]; then
        backup_configs
    fi

    local srv_hostname="${CUSTOM_SERVER_NAME:-$(hostname)}"
    local srv_ip
    srv_ip="$(get_server_ip)"
    local rotated_at
    rotated_at="$(now_iso8601)"
    local ts
    ts="$(date +%s)"

    local nodes_json_array=""
    local single_payloads=()
    local rotated_count=0
    local skipped_count=0

    while IFS='|' read -r idx fname shortname; do
        [[ -z "${idx}" ]] && continue
        local panel_node_id
        panel_node_id="$(resolve_panel_node_id "${idx}" "${fname}")" || true

        if [[ -z "${panel_node_id}" ]]; then
            info "序号 #${idx} [${fname}] 未配置对应的面板节点 ID，跳过处理"
            ((skipped_count++))
            continue
        fi

        # 1. 查询当前配置及协议类型 (`sing-box info [name]`)
        local meta proto port rotate_type old_cred
        meta="$(inspect_node_info "${shortname}" "${fname}")"
        IFS='|' read -r proto port rotate_type old_cred <<< "${meta}"

        step "处理节点 #${idx}: ${fname} (协议: ${proto}, 端口: ${port}, 面板节点ID: ${panel_node_id})"

        # 2. 执行自动更换 UUID 或 密码 (`sing-box id [name] auto` 或 `sing-box passwd [name] auto`)
        if [[ "${mode}" == "rotate" ]]; then
            local cmd_out=""
            local cmd_rc=0
            if [[ "${rotate_type}" == "id" ]]; then
                info "执行命令: sing-box id ${shortname} auto"
                cmd_out="$(printf '\n' | "${sb_bin}" id "${shortname}" auto 2>&1 | strip_ansi)" || cmd_rc=$?
                # 若某种特殊协议 id 失败，尝试 passwd 兜底
                if (( cmd_rc != 0 )) || echo "${cmd_out}" | grep -Eqi '错误|error|不支持|invalid'; then
                    warn "sing-box id 返回异常，尝试使用 sing-box passwd ${shortname} auto 兜底..."
                    rotate_type="passwd"
                    cmd_out="$(printf '\n' | "${sb_bin}" passwd "${shortname}" auto 2>&1 | strip_ansi)" || true
                fi
            else
                info "执行命令: sing-box passwd ${shortname} auto"
                cmd_out="$(printf '\n' | "${sb_bin}" passwd "${shortname}" auto 2>&1 | strip_ansi)" || cmd_rc=$?
                # 若某种特殊协议 passwd 失败，尝试 id 兜底
                if (( cmd_rc != 0 )) || echo "${cmd_out}" | grep -Eqi '错误|error|不支持|invalid'; then
                    warn "sing-box passwd 返回异常，尝试使用 sing-box id ${shortname} auto 兜底..."
                    rotate_type="id"
                    cmd_out="$(printf '\n' | "${sb_bin}" id "${shortname}" auto 2>&1 | strip_ansi)" || true
                fi
            fi
        elif [[ "${mode}" == "dry_run" ]]; then
            info "[演练模式] 将执行命令: sing-box ${rotate_type} ${shortname} auto"
        else
            info "[仅同步模式] 不修改密码，直接读取节点 ${shortname} 当前链接"
        fi

        # 3. 重新读取最新配置与完整节点链接 (`sing-box info [name]` + `sing-box url [name]`)
        local new_meta new_proto new_port new_type new_cred node_url
        new_meta="$(inspect_node_info "${shortname}" "${fname}")"
        IFS='|' read -r new_proto new_port new_type new_cred <<< "${new_meta}"
        node_url="$(get_node_url "${shortname}" "${new_proto}" "${new_port}" "${new_cred}")"

        if [[ -z "${node_url}" ]]; then
            err "无法获取节点 ${fname} 的完整链接 (sing-box url ${shortname} 输出为空)"
            if [[ "${mode}" == "rotate" && "${ROLLBACK_ON_FAIL}" == "true" ]]; then
                rollback_configs
            fi
            send_tg_notify "节点链接提取失败" "节点 ${fname} 无法生成 URL，已中止同步"
            return 1
        fi

        info "节点 #${idx} [${fname}] -> 面板 ID [${panel_node_id}] 准备就绪"

        local item_json
        item_json=$(cat <<EOF
    {
      "index": ${idx},
      "node_id": "$(json_escape "${panel_node_id}")",
      "config_name": "$(json_escape "${fname}")",
      "protocol": "$(json_escape "${new_proto}")",
      "port": ${new_port:-0},
      "rotate_type": "$(json_escape "${rotate_type}")",
      "credential": "$(json_escape "${new_cred}")",
      "node_url": "$(json_escape "${node_url}")"
    }
EOF
)
        if [[ -n "${nodes_json_array}" ]]; then
            nodes_json_array="${nodes_json_array},"$'\n'"${item_json}"
        else
            nodes_json_array="${item_json}"
        fi

        local single_json
        single_json=$(cat <<EOF
{
  "action": "rotate_node",
  "server_hostname": "$(json_escape "${srv_hostname}")",
  "server_ip": "$(json_escape "${srv_ip}")",
  "rotated_at": "${rotated_at}",
  "timestamp": ${ts},
  "node_id": "$(json_escape "${panel_node_id}")",
  "config_name": "$(json_escape "${fname}")",
  "protocol": "$(json_escape "${new_proto}")",
  "port": ${new_port:-0},
  "rotate_type": "$(json_escape "${rotate_type}")",
  "credential": "$(json_escape "${new_cred}")",
  "node_url": "$(json_escape "${node_url}")"
}
EOF
)
        single_payloads+=("${single_json}")
        ((rotated_count++))
    done <<< "${nodes_raw}"

    if (( rotated_count == 0 )); then
        warn "没有任何节点匹配到有效的面板 Node ID，任务结束"
        return 1
    fi

    local batch_payload
    batch_payload=$(cat <<EOF
{
  "action": "rotate_nodes_batch",
  "server_hostname": "$(json_escape "${srv_hostname}")",
  "server_ip": "$(json_escape "${srv_ip}")",
  "rotated_at": "${rotated_at}",
  "timestamp": ${ts},
  "nodes": [
${nodes_json_array}
  ]
}
EOF
)

    if [[ "${mode}" == "dry_run" ]]; then
        echo -e "\n${BOLD}${CYAN}=== [演练模式] 即将发送至 $(get_endpoint_url) 的 JSON 载荷 ===${NC}"
        echo "${batch_payload}"
        echo -e "${BOLD}${CYAN}==============================================================${NC}"
        return 0
    fi

    step "正在将 ${rotated_count} 个节点的最新链接同步至订阅管理面板..."
    local sync_ok=0
    if [[ "${SYNC_MODE:-batch}" == "single" ]]; then
        local sp
        sync_ok=1
        for sp in "${single_payloads[@]}"; do
            if ! post_to_panel "${sp}"; then
                sync_ok=0
                break
            fi
        done
    else
        if post_to_panel "${batch_payload}"; then
            sync_ok=1
        fi
    fi

    if (( sync_ok == 1 )); then
        printf '%s\n' "${batch_payload}" > "${CACHE_DIR}/last_success_payload.json"
        info "全部 ${rotated_count} 个节点轮换并同步面板成功！"
        send_tg_notify "每日节点轮换成功" "已成功更新并同步 ${rotated_count} 个节点链接至面板"
        return 0
    else
        err "同步至订阅管理面板失败！"
        if [[ "${mode}" == "rotate" && "${ROLLBACK_ON_FAIL:-true}" == "true" ]]; then
            rollback_configs
            send_tg_notify "面板同步失败 (已自动回滚)" "API 请求失败，已自动恢复原节点密码以保障在线用户连接"
        else
            send_tg_notify "面板同步失败 (未回滚)" "API 请求失败，新节点载荷保存在 ${CACHE_DIR}/last_failed_payload.json"
        fi
        return 1
    fi
}

# ==============================================================================
# 定时任务部署与管理 (默认北京时间 Asia/Shanghai 凌晨 04:00)
# ==============================================================================

setup_cron() {
    load_config
    local hour="${CRON_HOUR:-4}"
    local minute="${CRON_MINUTE:-0}"

    # 计算当前系统时区与北京时间 (UTC+8) 的偏移，确保即使 cron 不支持 CRON_TZ 也能准时在 04:00 CST 触发
    local sys_offset_sec cst_offset_sec diff_hours local_hour
    sys_offset_sec="$(date +%z | awk '{
        sign = substr($0,1,1);
        h = substr($0,2,2) + 0;
        m = substr($0,4,2) + 0;
        sec = h * 3600 + m * 60;
        if (sign == "-") sec = -sec;
        print sec;
    }')"
    cst_offset_sec=$(( 8 * 3600 ))
    diff_hours=$(( (sys_offset_sec - cst_offset_sec) / 3600 ))
    local_hour=$(( (hour + diff_hours + 24) % 24 ))

    cat > "${CRON_FILE}" <<EOF
# sb-rotator 每日自动更换 sing-box 节点密码/UUID 并同步至面板
# 设定时间: 每日北京时间 (Asia/Shanghai) $(printf '%02d:%02d' "${hour}" "${minute}")
# 对应当前服务器本地时区时间: $(printf '%02d:%02d' "${local_hour}" "${minute}")
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${minute} ${local_hour} * * * root /usr/local/bin/sb-rotator --cron >> ${LOG_FILE} 2>&1
EOF
    chmod 644 "${CRON_FILE}"

    # 尝试重载 cron 服务
    systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || service cron reload 2>/dev/null || service crond reload 2>/dev/null || true
    info "已部署定时任务: 每日北京时间 $(printf '%02d:%02d' "${hour}" "${minute}") (服务器本地时间 $(printf '%02d:%02d' "${local_hour}" "${minute}")) 自动执行"
}

remove_cron() {
    if [[ -f "${CRON_FILE}" ]]; then
        rm -f "${CRON_FILE}"
        systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
        info "已移除定时任务 ${CRON_FILE}"
    fi
}

# ==============================================================================
# 状态展示、连通性测试与一键卸载
# ==============================================================================

show_mapping_table() {
    load_config
    echo -e "\n${BOLD}${CYAN}================ 当前本机 sing-box 节点与面板映射表 ================${NC}"
    printf "${BOLD}%-6s %-28s %-14s %-8s %-10s %-14s${NC}\n" "序号" "节点配置文件" "协议类型" "端口" "轮换方式" "对应面板ID"
    echo "--------------------------------------------------------------------------------"

    local nodes_raw
    if ! nodes_raw="$(discover_nodes 2>/dev/null)"; then
        echo -e "${YELLOW}未检测到任何 sing-box 节点配置，请先使用 sing-box add 添加节点。${NC}"
        echo "================================================================================"
        return 1
    fi

    while IFS='|' read -r idx fname shortname; do
        [[ -z "${idx}" ]] && continue
        local meta proto port rtype cred panel_id
        meta="$(inspect_node_info "${shortname}" "${fname}")"
        IFS='|' read -r proto port rtype cred <<< "${meta}"
        panel_id="$(resolve_panel_node_id "${idx}" "${fname}")" || panel_id="未绑定(跳过)"
        local rcmd="sing-box ${rtype}"
        printf "%-6s %-28s %-14s %-8s %-12s %-14s\n" "${idx})" "${fname}" "${proto}" "${port}" "${rcmd}" "${panel_id}"
    done <<< "${nodes_raw}"
    echo "================================================================================"
}

test_api_connection() {
    load_config
    local endpoint
    endpoint="$(get_endpoint_url)" || {
        err "请先配置面板地址 (PANEL_URL)"
        return 1
    }
    step "正在向面板接口发送连通性测试请求: ${endpoint}"
    local ts sig payload http_code resp_file
    ts="$(date +%s)"
    payload=$(cat <<EOF
{
  "action": "ping",
  "server_hostname": "$(json_escape "${CUSTOM_SERVER_NAME:-$(hostname)}")",
  "server_ip": "$(get_server_ip)",
  "timestamp": ${ts}
}
EOF
)
    sig="$(compute_signature "${ts}" "${payload}")"
    resp_file="$(mktemp /tmp/sb-rotator-ping.XXXXXX)"

    http_code="$(curl -sS --connect-timeout 8 --max-time 15 \
        -o "${resp_file}" -w "%{http_code}" \
        -X POST "${endpoint}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "X-API-Key: ${API_KEY}" \
        -H "X-Timestamp: ${ts}" \
        -H "X-Signature: ${sig}" \
        -d "${payload}" 2>&1 || echo "000")"

    local body=""
    [[ -f "${resp_file}" ]] && body="$(head -c 400 "${resp_file}")"
    rm -f "${resp_file}"

    echo -e "HTTP 状态码: ${BOLD}${http_code}${NC}"
    echo -e "面板响应内容: ${body:-<空>}"
    if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
        info "面板 API 通信测试通过！"
        return 0
    else
        warn "面板未返回 2xx 状态码，请检查面板接口地址、API Key 或防火墙设置。"
        return 1
    fi
}

# 交互式向导配置
interactive_configure() {
    load_config
    echo -e "\n${BOLD}${BLUE}>>> 配置 sb-rotator 节点自动轮换与面板对接参数 <<<${NC}"
    show_mapping_table || true

    echo ""
    read -rp "1. 请输入订阅管理面板地址 (例如 https://panel.example.com 或完整 API 地址) [${PANEL_URL}]: " input_url
    PANEL_URL="${input_url:-${PANEL_URL}}"

    read -rp "2. 请输入面板通信密码 / API Key [${API_KEY}]: " input_key
    API_KEY="${input_key:-${API_KEY}}"

    echo -e "\n${CYAN}提示: 多个节点 ID 请用英文逗号分隔，第 1 个对应配置中的 1)，第 2 个对应 2)，以此类推。"
    echo -e "      如果某个序号的节点不需要轮换，对应位置填 0 即可（例如: 101,0,103）。${NC}"
    read -rp "3. 请输入面板节点 ID 列表 [${NODE_IDS}]: " input_ids
    NODE_IDS="${input_ids:-${NODE_IDS}}"
    NODE_IDS="${NODE_IDS// /,}"

    echo ""
    read -rp "4. 请输入每日自动修改密码的北京时间小时 (0-23，默认凌晨 4 点) [${CRON_HOUR:-4}]: " input_hour
    CRON_HOUR="${input_hour:-${CRON_HOUR:-4}}"

    read -rp "5. 请输入每日自动修改密码的分钟 (0-59，默认 0 分) [${CRON_MINUTE:-0}]: " input_min
    CRON_MINUTE="${input_min:-${CRON_MINUTE:-0}}"

    read -rp "6. 面板同步失败时是否自动回滚原密码以防断连? (y/n，默认 y) [y]: " input_rb
    if [[ "${input_rb:-y}" =~ ^[Nn]$ ]]; then
        ROLLBACK_ON_FAIL="false"
    else
        ROLLBACK_ON_FAIL="true"
    fi

    read -rp "7. [可选] 是否配置 Telegram 机器人告警通知? (y/n，默认 n) [n]: " input_tg
    if [[ "${input_tg:-n}" =~ ^[Yy]$ ]]; then
        read -rp "   请输入 Telegram Bot Token [${TG_BOT_TOKEN}]: " input_tk
        TG_BOT_TOKEN="${input_tk:-${TG_BOT_TOKEN}}"
        read -rp "   请输入 Telegram Chat ID [${TG_CHAT_ID}]: " input_cid
        TG_CHAT_ID="${input_cid:-${TG_CHAT_ID}}"
    fi

    save_config
    setup_cron
    echo ""
    info "配置已保存至 ${CONFIG_FILE}"
    show_mapping_table || true
}

# 查看日志子菜单
view_logs_menu() {
    echo -e "\n${BOLD}${CYAN}================ 日志查看工具 ================${NC}"
    echo "  1) 查看最近 50 行日志"
    echo "  2) 实时追踪日志输出 (Ctrl+C 退出)"
    echo "  3) 查看最近一次失败的 API 载荷"
    echo "  4) 清空历史日志"
    echo "  0) 返回主菜单"
    read -rp "请选择操作 [0-4]: " log_opt
    case "${log_opt}" in
        1)
            echo -e "\n${BOLD}--- 最近 50 行日志 (${LOG_FILE}) ---${NC}"
            tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志记录"
            ;;
        2)
            echo -e "\n${YELLOW}正在实时追踪日志 (按 Ctrl+C 退出)...${NC}"
            tail -f "${LOG_FILE}"
            ;;
        3)
            if [[ -f "${CACHE_DIR}/last_failed_payload.json" ]]; then
                cat "${CACHE_DIR}/last_failed_payload.json"
            else
                echo "暂无失败载荷记录"
            fi
            ;;
        4)
            : > "${LOG_FILE}"
            info "已清空日志文件 ${LOG_FILE}"
            ;;
        *)
            return 0
            ;;
    esac
}

# 一键卸载
uninstall_all() {
    echo -e "\n${RED}${BOLD}⚠️  警告：即将卸载 sb-rotator 自动轮换程序及其定时任务（不会影响 233boy sing-box 本身）${NC}"
    read -rp "确认卸载吗？(输入 y 确认卸载，其他键取消): " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        info "已取消卸载"
        return 0
    fi

    remove_cron
    rm -rf "${INSTALL_DIR}"
    rm -f "${LOCK_FILE}"
    rm -f /usr/local/bin/sb-rotator /usr/local/bin/sbr
    echo -e "${GREEN}✅ sb-rotator 已彻底卸载完成！（历史日志保留在 ${LOG_FILE}，如需删除可执行 rm -f ${LOG_FILE}）${NC}"
    exit 0
}

# 交互式主管理面板
main_menu() {
    load_config
    while true; do
        local cron_status="${RED}未启用${NC}"
        if [[ -f "${CRON_FILE}" ]]; then
            cron_status="${GREEN}已启用 (每日北京时间 $(printf '%02d:%02d' "${CRON_HOUR:-4}" "${CRON_MINUTE:-0}"))${NC}"
        fi

        echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
        echo -e "${BOLD}     233boy/sing-box 节点每日自动换密与面板同步工具 v${VERSION}${NC}"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        echo -e "  面板接口地址 : ${YELLOW}${PANEL_URL:-未配置}${NC}"
        echo -e "  绑定节点 ID  : ${YELLOW}${NODE_IDS:-未配置}${NC}"
        echo -e "  定时任务状态 : ${cron_status}"
        echo -e "  失败自动回滚 : ${YELLOW}${ROLLBACK_ON_FAIL:-true}${NC}"
        echo -e "  快捷启动命令 : ${GREEN}sb-rotator${NC} 或 ${GREEN}sbr${NC}"
        echo -e "-----------------------------------------------------------------"
        echo -e "  ${GREEN}1.${NC} 立即执行一次密码/UUID轮换并上传面板"
        echo -e "  ${GREEN}2.${NC} 仅同步当前节点链接到面板 (不修改密码)"
        echo -e "  ${GREEN}3.${NC} 演练模式 (Dry-Run：预览将要执行的命令与上传 JSON)"
        echo -e "  ${GREEN}4.${NC} 查看本机节点与面板 Node ID 映射关系"
        echo -e "  ${GREEN}5.${NC} 修改配置 (面板地址 / API Key / 节点 ID / 定时时间)"
        echo -e "  ${GREEN}6.${NC} 测试面板 API 通信连通性"
        echo -e "  ${GREEN}7.${NC} 查看运行日志 (查看 / 实时追踪 / 清空)"
        echo -e "  ${GREEN}8.${NC} 开启 / 关闭定时轮换任务"
        echo -e "  ${GREEN}9.${NC} 紧急回滚到上一次备份的节点配置"
        echo -e "  ${RED}10.${NC} 一键卸载本程序 (Uninstall)"
        echo -e "  ${GREEN}0.${NC} 退出管理面板"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        read -rp "请输入选项编号 [0-10]: " choice

        case "${choice}" in
            1) run_rotation ;;
            2) run_rotation --sync-only ;;
            3) run_rotation --dry-run ;;
            4) show_mapping_table ;;
            5) interactive_configure ;;
            6) test_api_connection ;;
            7) view_logs_menu ;;
            8)
                if [[ -f "${CRON_FILE}" ]]; then
                    remove_cron
                else
                    setup_cron
                fi
                ;;
            9) rollback_configs ;;
            10) uninstall_all ;;
            0|"") exit 0 ;;
            *) warn "无效的选项 [${choice}]，请重新输入" ;;
        esac
    done
}

# ==============================================================================
# CLI 入口路由
# ==============================================================================

usage() {
    cat <<EOF
用法: sb-rotator [选项]

无参数               打开交互式管理菜单 (含查看日志、一键卸载、手动触发等按钮)
--run                立即执行一次节点密码/UUID轮换并同步至面板
--cron               定时任务模式执行（带随机抖动延迟）
--sync-only          仅获取当前节点完整链接并上传面板（不更换密码/UUID）
--dry-run            演练模式：打印节点发现结果与待发送 JSON，不实际修改配置
--status             显示本机节点列表与面板 Node ID 映射表
--test-api           发送 Ping 请求测试面板 API 连通性与签名校验
--config             进入交互式配置向导
--logs               查看最近 50 行运行日志
--rollback           将节点配置恢复到上一次轮换前的备份
--uninstall          一键卸载 sb-rotator 及定时任务
-h, --help           显示此帮助信息
EOF
}

case "${1:-}" in
    --run)       run_rotation ;;
    --cron)      run_rotation --cron ;;
    --sync-only) run_rotation --sync-only ;;
    --dry-run)   run_rotation --dry-run ;;
    --status)    show_mapping_table ;;
    --test-api)  test_api_connection ;;
    --config)    interactive_configure ;;
    --logs)      tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志" ;;
    --rollback)  rollback_configs ;;
    --uninstall) uninstall_all ;;
    -h|--help)   usage ;;
    "")          main_menu ;;
    *)           err "未知参数: $1"; usage; exit 1 ;;
esac

__EOF_SB_ROTATOR_CORE__

    chmod +x "${INSTALL_BIN}"
    ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
}

main() {
    check_root
    echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
    echo -e "${BOLD}   欢迎使用 233boy/sing-box 每日自动轮换密码 & 面板同步一键脚本${NC}"
    echo -e "${BOLD}${CYAN}=================================================================${NC}"

    # 如果已经安装过，询问是进入管理面板、重新配置还是一键卸载
    if [[ -x "${INSTALL_BIN}" && -f "${INSTALL_DIR}/config.env" && "${1:-}" == "" ]]; then
        echo -e "${GREEN}检测到本机已安装 sb-rotator，请选择操作：${NC}"
        echo -e "  ${GREEN}1)${NC} 打开管理面板 (含立即同步 / 查看日志 / 一键卸载按钮)"
        echo -e "  ${GREEN}2)${NC} 更新脚本并重新引导配置"
        echo -e "  ${GREEN}3)${NC} 查看运行日志"
        echo -e "  ${RED}4)${NC} 一键卸载"
        echo -e "  ${GREEN}0)${NC} 退出"
        read -rp "请选择 [0-4，默认 1]: " exist_opt
        case "${exist_opt:-1}" in
            1) deploy_core_script; exec "${INSTALL_BIN}" ;;
            2) ;;
            3) exec "${INSTALL_BIN}" --logs ;;
            4) exec "${INSTALL_BIN}" --uninstall ;;
            0) exit 0 ;;
        esac
    fi

    check_dependencies
    check_singbox_installed
    deploy_core_script

    echo -e "${GREEN}[成功] 核心程序已安装至 ${INSTALL_BIN} (快捷命令: sb-rotator 或 sbr)${NC}"

    # 启动交互式安装配置向导
    "${INSTALL_BIN}" --config

    echo ""
    read -rp "是否现在测试一次面板 API 连通性？(y/n，默认 y): " do_ping
    if [[ "${do_ping:-y}" =~ ^[Yy]$ ]]; then
        "${INSTALL_BIN}" --test-api || true
    fi

    echo ""
    read -rp "是否立即执行一次【仅同步当前节点链接到面板（不改密）】以完成初始对接？(y/n，默认 y): " do_sync
    if [[ "${do_sync:-y}" =~ ^[Yy]$ ]]; then
        "${INSTALL_BIN}" --sync-only || true
    fi

    echo -e "\n${BOLD}${GREEN}=================================================================${NC}"
    echo -e "${BOLD}${GREEN} 🎉 部署完成！后续随时输入 ${YELLOW}sbr${GREEN} 或 ${YELLOW}sb-rotator${GREEN} 即可打开管理面板${NC}"
    echo -e "${BOLD}${GREEN}    查看日志、手动触发换密、修改配置或一键卸载！${NC}"
    echo -e "${BOLD}${GREEN}=================================================================${NC}"
}

main "$@"
