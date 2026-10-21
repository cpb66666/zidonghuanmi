#!/usr/bin/env bash
# ==============================================================================
# install.sh - 233boy/sing-box 多槽位阶梯换密与面板同步工具 一键安装脚本 (v2.0.1)
# 使用方式:
#   bash <(curl -fsSL https://raw.githubusercontent.com/cpb66666/zidonghuanmi/main/install.sh)
# ==============================================================================

set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GITHUB_RAW_BASE_URL=""

INSTALL_BIN="/usr/local/bin/sb-rotator"
ALIAS_BIN="/usr/local/bin/sbr"
INSTALL_DIR="/etc/sb-rotator"

prompt_read() {
    local prompt_str="$1" var_name="$2"
    if [[ -t 0 ]]; then read -rp "${prompt_str}" "${var_name}" || return 1
    elif [[ -e /dev/tty ]]; then read -rp "${prompt_str}" "${var_name}" < /dev/tty || return 1
    else read -rp "${prompt_str}" "${var_name}" || return 1; fi
}

check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        echo -e "${RED}[错误] 请使用 root 用户运行此脚本 (sudo -i)${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl sed awk grep flock timeout jq; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if ! command -v crontab >/dev/null 2>&1 && [[ ! -d /etc/cron.d ]]; then
        missing+=("cron")
    fi
    if (( ${#missing[@]} > 0 )); then
        echo -e "${YELLOW}[提示] 正在安装必要系统组件: ${missing[*]} ...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl sed gawk grep util-linux coreutils cron openssl ca-certificates jq tzdata >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl sed gawk grep util-linux coreutils cronie openssl ca-certificates jq tzdata >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl sed gawk grep util-linux coreutils dcron openssl ca-certificates jq tzdata >/dev/null 2>&1
        fi
    fi
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
}

deploy_core_script() {
    mkdir -p "${INSTALL_DIR}"
    if [[ -n "${GITHUB_RAW_BASE_URL}" ]]; then
        if curl -fsSL --connect-timeout 10 "${GITHUB_RAW_BASE_URL%/}/sb-rotator.sh" -o "${INSTALL_BIN}"; then
            chmod +x "${INSTALL_BIN}"
            ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
            return 0
        fi
    fi

    cat > "${INSTALL_BIN}" <<'__EOF_SB_ROTATOR_CORE__'
#!/usr/bin/env bash
# ==============================================================================
# sb-rotator.sh - 233boy/sing-box 多槽位阶梯换密与面板同步工具 (v2.0.1)
# 架构: 5组长效密码 (L:01~L:05, 15天到期, 每3天03:00轮换1组, 寿命阶梯 15/12/9/6/3天)
#       + 1组短期密码 (D:00 / P24h, 24小时到期, 每天04:00轮换)
# ==============================================================================

set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="2.0.1"
INSTALL_DIR="${INSTALL_DIR:-/etc/sb-rotator}"
CONFIG_FILE="${CONFIG_FILE:-${INSTALL_DIR}/config.env}"
STATE_FILE="${STATE_FILE:-${INSTALL_DIR}/slots_state.json}"
INIT_FLAG="${INIT_FLAG:-${INSTALL_DIR}/.initialized}"
BACKUP_DIR="${BACKUP_DIR:-${INSTALL_DIR}/backup}"
CACHE_DIR="${CACHE_DIR:-${INSTALL_DIR}/cache}"
LOG_FILE="${LOG_FILE:-/var/log/sb-rotator.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/sb-rotator.lock}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/sb-rotator}"
SB_CONF_DIR="${SB_CONF_DIR:-/etc/sing-box/conf}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================================================
# 基础工具与跨时区时间计算 (统一锚定北京时间 Asia/Shanghai -> Unix Epoch 秒)
# ==============================================================================

ensure_dirs() {
    mkdir -p "${INSTALL_DIR}" "${BACKUP_DIR}" "${CACHE_DIR}" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true
    [[ ! -f "${STATE_FILE}" ]] && echo "{}" > "${STATE_FILE}" 2>/dev/null || true
    chmod 600 "${CONFIG_FILE}" "${STATE_FILE}" 2>/dev/null || true
}

now_beijing() { TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S'; }
now_iso8601() { TZ='Asia/Shanghai' date '+%Y-%m-%dT%H:%M:%S+08:00'; }
get_beijing_doy() { TZ='Asia/Shanghai' date '+%-j'; }

# 计算从当前北京时间起 N 天后指定整点 (如 03:00:00 或 04:00:00) 的绝对 Unix 秒级时间戳
# 无论节点服务器或面板服务器处于任何时区，Unix 时间戳全球唯一且一致
calc_expire_ts() {
    local days_ahead="$1"
    local target_hour="$2"
    local target_date
    target_date="$(TZ='Asia/Shanghai' date -d "+${days_ahead} days" '+%Y-%m-%d')"
    TZ='Asia/Shanghai' date -d "${target_date} $(printf '%02d:00:00' "${target_hour}")" '+%s'
}

ts_to_iso8601_cst() {
    local ts="$1"
    TZ='Asia/Shanghai' date -d "@${ts}" '+%Y-%m-%dT%H:%M:%S+08:00'
}

# 根据自然年中的第几天 (DOY: 1~365) 计算今日应轮换的长效槽位编号 (1~5)
get_due_long_slot_num() {
    local doy
    doy="$(get_beijing_doy)"
    echo $(( (doy / 3) % 5 + 1 ))
}

# 判断今日是否为长效密码轮换日 (每隔 3 天轮换 1 组: DOY % 3 == 0)
is_long_rotation_day() {
    local doy
    doy="$(get_beijing_doy)"
    (( doy % 3 == 0 ))
}

log_msg() {
    local level="$1"; shift
    echo "[$(now_beijing) CST] [${level}] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

info() { echo -e "${GREEN}[INFO]${NC} $*"; log_msg "INFO" "$*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; log_msg "WARN" "$*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; log_msg "ERROR" "$*"; }
step() { echo -e "${CYAN}[STEP]${NC} $*"; log_msg "STEP" "$*"; }

prompt_read() {
    local prompt_str="$1" var_name="$2"
    if [[ -t 0 ]]; then read -rp "${prompt_str}" "${var_name}" || return 1
    elif [[ -e /dev/tty ]]; then read -rp "${prompt_str}" "${var_name}" < /dev/tty || return 1
    else read -rp "${prompt_str}" "${var_name}" || return 1; fi
}

strip_ansi() { sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'; }

find_sb_bin() {
    [[ -n "${SB_BIN:-}" && -x "${SB_BIN}" ]] && { echo "${SB_BIN}"; return 0; }
    local c
    for c in /usr/local/bin/sing-box /usr/local/bin/sb /etc/sing-box/sh/sing-box.sh /usr/bin/sing-box; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    command -v sing-box 2>/dev/null || command -v sb 2>/dev/null || return 1
}

run_sb_cmd_idx() {
    local default_idx="$1" timeout_sec="$2"; shift 2
    local sb_bin; sb_bin="$(find_sb_bin)" || return 1
    if command -v timeout >/dev/null 2>&1; then
        printf '%s\n' "${default_idx}" | COLUMNS=1 timeout "${timeout_sec}" "${sb_bin}" "$@" 2>&1 | strip_ansi
    else
        printf '%s\n' "${default_idx}" | COLUMNS=1 "${sb_bin}" "$@" 2>&1 | strip_ansi
    fi
}

run_sb_cmd() { local t="$1"; shift; run_sb_cmd_idx "1" "$t" "$@"; }

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

rotate_log_if_needed() {
    if [[ -f "${LOG_FILE}" ]] && (( $(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0) > 5242880 )); then
        tail -n 2000 "${LOG_FILE}" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "${LOG_FILE}"
    fi
}

# ==============================================================================
# 配置管理
# ==============================================================================

load_config() {
    PANEL_URL=""
    API_KEY=""
    NODE_IDS=""
    LONG_CRON_HOUR="3"
    DAILY_CRON_HOUR="4"
    CRON_MINUTE="0"
    MAX_RETRIES="3"
    RETRY_DELAY="5"
    RANDOM_JITTER_MAX="15"
    ROLLBACK_ON_FAIL="true"
    CUSTOM_SERVER_NAME=""
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    [[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"
}

save_config() {
    ensure_dirs
    cat > "${CONFIG_FILE}" <<EOF
# sb-rotator v2.0.1 配置文件
PANEL_URL="${PANEL_URL}"
API_KEY="${API_KEY}"
NODE_IDS="${NODE_IDS}"
LONG_CRON_HOUR="${LONG_CRON_HOUR:-3}"
DAILY_CRON_HOUR="${DAILY_CRON_HOUR:-4}"
CRON_MINUTE="${CRON_MINUTE:-0}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
RANDOM_JITTER_MAX="${RANDOM_JITTER_MAX:-15}"
ROLLBACK_ON_FAIL="${ROLLBACK_ON_FAIL:-true}"
CUSTOM_SERVER_NAME="${CUSTOM_SERVER_NAME:-}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

get_endpoint_url() {
    local url="${PANEL_URL%/}"
    [[ -z "${url}" ]] && return 1
    if [[ "${url}" =~ ^https?://[^/]+$ ]]; then
        echo "${url}/api/v1/node/rotate"
    else
        echo "${url}"
    fi
}

# ==============================================================================
# 节点发现与协议适配
# ==============================================================================

discover_nodes() {
    if [[ -d "${SB_CONF_DIR}" ]]; then
        local i=1 f fname
        shopt -s nullglob
        for f in "${SB_CONF_DIR}"/*.json; do
            fname="$(basename "$f")"
            echo "${i}|${fname}|${fname%.json}"
            ((i++))
        done
        shopt -u nullglob
        (( i > 1 )) && return 0
    fi
    return 1
}

resolve_panel_node_id() {
    local target_idx="$1" target_fname="$2"
    local target_short="${target_fname%.json}"
    local IFS=',' item k v
    read -ra items <<< "${NODE_IDS// /,}"
    for item in "${items[@]}"; do
        if [[ "${item}" == *:* ]]; then
            k="${item%%:*}"; v="${item#*:}"
            [[ "${v}" == "${target_fname}" || "${v}" == "${target_short}" ]] && { echo "${k}"; return 0; }
        fi
    done
    local pos=$(( target_idx - 1 ))
    if (( pos >= 0 && pos < ${#items[@]} )); then
        local val="${items[$pos]%%:*}"
        [[ -n "${val}" && "${val}" != "0" && "${val}" != "-" ]] && { echo "${val}"; return 0; }
    fi
    return 1
}

# 识别节点协议、端口、凭据字段名 (uuid 或 password)
inspect_node_meta() {
    local shortname="$1" fname="$2"
    local conf_path="${SB_CONF_DIR}/${fname}"
    local proto="" port="" cred_field=""

    if [[ -f "${conf_path}" ]]; then
        proto="$(jq -r '.inbounds[0].type // empty' "${conf_path}" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        port="$(jq -r '.inbounds[0].listen_port // empty' "${conf_path}" 2>/dev/null)"
        if jq -e '.inbounds[0].users[0].uuid != null' "${conf_path}" >/dev/null 2>&1 || grep -q '"uuid"' "${conf_path}" 2>/dev/null; then
            cred_field="uuid"
        else
            cred_field="password"
        fi
    fi

    [[ -z "${proto}" ]] && proto="$(echo "${shortname}" | sed -E 's/-[0-9]+$//' | tr '[:upper:]' '[:lower:]')"
    [[ -z "${port}" && "${shortname}" =~ -([0-9]+)$ ]] && port="${BASH_REMATCH[1]}"
    [[ -z "${port}" ]] && port="0"

    if [[ -z "${cred_field}" ]]; then
        case "${proto}" in
            *vless*|*vmess*|*tuic*) cred_field="uuid" ;;
            *) cred_field="password" ;;
        esac
    fi
    echo "${proto}|${port}|${cred_field}"
}

generate_new_credential() {
    local cred_field="$1" conf_path="$2"
    if [[ "${cred_field}" == "uuid" ]]; then
        if [[ -r /proc/sys/kernel/random/uuid ]]; then
            cat /proc/sys/kernel/random/uuid
        elif command -v uuidgen >/dev/null 2>&1; then
            uuidgen | tr '[:upper:]' '[:lower:]'
        else
            od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}'
        fi
    else
        if [[ -f "${conf_path}" ]] && grep -qi '2022-blake3' "${conf_path}" 2>/dev/null; then
            local ss_pass
            ss_pass="$(run_sb_cmd 3 ss2022 2>/dev/null | grep -Eo '[A-Za-z0-9+/=]{16,}' | tail -n1)"
            [[ -n "${ss_pass}" ]] && { echo "${ss_pass}"; return 0; }
        fi
        local pass
        pass="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)"
        [[ -z "${pass}" ]] && pass="$(date +%s%N | sha256sum | head -c 16)"
        echo "${pass}"
    fi
}

get_server_ip() {
    local ip=""
    ip="$(run_sb_cmd 5 ip 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
    [[ -z "${ip}" ]] && ip="$(curl -fsSL4 --connect-timeout 4 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -z "${ip}" ]] && ip="127.0.0.1"
    echo "${ip}"
}

extract_proxy_url_from_text() {
    echo "$1" \
        | grep -Eo '(vless|vmess|trojan|hysteria2|hy2|tuic|ss|shadowsocks|anytls|socks5?|hysteria)://[^[:space:]"'"'"']+' \
        | grep -Ev 'getjms\.com|233boy\.com|github\.com|t\.me' \
        | head -n1
}

# 获取节点的基准分享链接模板 (以 users[0] 为基准)，用于派发各槽位完整链接
get_base_node_url() {
    local idx="$1" shortname="$2" fname="$3" proto="$4" port="$5" first_cred="$6"
    local out="" base_url=""

    out="$(run_sb_cmd_idx "${idx}" 6 url "${shortname}" 2>/dev/null)"
    base_url="$(extract_proxy_url_from_text "${out}")"

    if [[ -z "${base_url}" && -n "${port}" && "${port}" != "0" ]]; then
        out="$(run_sb_cmd_idx "${idx}" 6 url "${port}" 2>/dev/null)"
        base_url="$(extract_proxy_url_from_text "${out}")"
    fi

    if [[ -z "${base_url}" ]]; then
        out="$(run_sb_cmd_idx "${idx}" 6 info "${shortname}" 2>/dev/null)"
        base_url="$(extract_proxy_url_from_text "${out}")"
    fi

    # 智能兜底构造完整节点链接
    if [[ -z "${base_url}" ]]; then
        local srv_ip sni="" pbk="" sid="" flow=""
        srv_ip="$(get_server_ip)"
        local conf_path="${SB_CONF_DIR}/${fname}"
        if [[ -f "${conf_path}" ]]; then
            sni="$(jq -r '.inbounds[0].tls.server_name // empty' "${conf_path}" 2>/dev/null)"
            flow="$(jq -r '.inbounds[0].users[0].flow // empty' "${conf_path}" 2>/dev/null)"
            sid="$(jq -r '.inbounds[0].tls.reality.short_id[0] // empty' "${conf_path}" 2>/dev/null)"
        fi
        case "${proto}" in
            *anytls*)
                base_url="anytls://${first_cred}@${srv_ip}:${port}?security=tls${sni:+&sni=${sni}}&insecure=1#${shortname}"
                ;;
            *hysteria2*|*hy2*)
                base_url="hysteria2://${first_cred}@${srv_ip}:${port}?insecure=1&sni=${sni:-www.bing.com}#${shortname}"
                ;;
            *vless*)
                base_url="vless://${first_cred}@${srv_ip}:${port}?encryption=none${flow:+&flow=${flow}}&security=tls${sni:+&sni=${sni}}#${shortname}"
                ;;
            *trojan*)
                base_url="trojan://${first_cred}@${srv_ip}:${port}?security=tls${sni:+&sni=${sni}}#${shortname}"
                ;;
            *)
                base_url="${proto}://${first_cred}@${srv_ip}:${port}#${shortname}"
                ;;
        esac
    fi
    echo "${base_url}"
}

# 将基准节点链接转换为指定槽位凭据与标识的完整节点链接
build_slot_node_url() {
    local base_url="$1" first_cred="$2" slot_cred="$3" slot_id="$4" proto="$5"
    local url="${base_url}"

    if [[ "${proto}" == *vmess* && "${url}" =~ ^vmess://(.+)$ ]]; then
        local b64="${BASH_REMATCH[1]}"
        local decoded
        decoded="$(echo "${b64}" | base64 -d 2>/dev/null || true)"
        if [[ -n "${decoded}" ]] && command -v jq >/dev/null 2>&1; then
            local modified
            modified="$(echo "${decoded}" | jq -c --arg id "${slot_cred}" --arg ps "${slot_id}" '.id = $id | .ps = $ps' 2>/dev/null || true)"
            if [[ -n "${modified}" ]]; then
                echo "vmess://$(printf '%s' "${modified}" | base64 -w 0 2>/dev/null || printf '%s' "${modified}" | base64 | tr -d '\n')"
                return 0
            fi
        fi
    fi

    # 替换协议头后的凭据部分
    if [[ -n "${first_cred}" && "${url}" == *"${first_cred}"* ]]; then
        url="${url//${first_cred}/${slot_cred}}"
    else
        url="$(echo "${url}" | sed -E "s|^([a-zA-Z0-9]+://)[^@]+@|\1${slot_cred}@|")"
    fi

    # 在链接末尾锚点 # 标注槽位标识 (如 #AnyTLS-36542|6:L:01)
    if [[ "${url}" == *#* ]]; then
        local prefix="${url%%#*}"
        url="${prefix}#${slot_id}"
    else
        url="${url}#${slot_id}"
    fi
    echo "${url}"
}

# ==============================================================================
# 多槽位配置维护 (5个长效 L:01~L:05 + 1个短期 D:00)
# ==============================================================================

# 读取或更新本地状态文件中的过期时间
get_slot_expire_from_state() {
    local slot_id="$1"
    jq -r --arg k "${slot_id}" '.[$k].expires_at // 0' "${STATE_FILE}" 2>/dev/null || echo 0
}

set_slot_state() {
    local slot_id="$1" cred="$2" exp_ts="$3" slot_tag="$4" slot_type="$5"
    local exp_iso
    exp_iso="$(ts_to_iso8601_cst "${exp_ts}")"
    local tmp="${STATE_FILE}.tmp.$$"
    jq --arg k "${slot_id}" \
       --arg c "${cred}" \
       --arg tag "${slot_tag}" \
       --arg st "${slot_type}" \
       --arg iso "${exp_iso}" \
       --argjson exp "${exp_ts}" \
       '.[$k] = {"credential": $c, "expires_at": $exp, "expires_at_iso": $iso, "slot_tag": $tag, "slot_type": $st}' \
       "${STATE_FILE}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${STATE_FILE}"
}

# 确保节点的 sing-box 配置文件中包含完整的 6 个槽位用户并带有 name 标注
# 参数: fname panel_node_id cred_field action_mode target_slot_key
# action_mode:
#   "init"       -> 重新初始化全部 6 个槽位 (L:01~L:05 阶梯寿命 {15,12,9,6,3}天 + D:00 24h)
#   "rotate_one" -> 仅更换指定的 target_slot_key (如 "L:01" 或 "D:00")，其余 5 个槽位保持不变
#   "ensure"     -> 若配置文件还不是 6 槽位结构则补齐，不重置已有槽位
update_node_slots_in_conf() {
    local fname="$1"
    local panel_id="$2"
    local cred_field="$3"
    local action_mode="$4"
    local target_slot_key="${5:-}"
    local conf_path="${SB_CONF_DIR}/${fname}"

    [[ ! -f "${conf_path}" ]] && return 1

    # 提取原模板用户中的附加属性 (例如 VLESS Reality 的 flow: xtls-rprx-vision)
    local extra_fields_json="{}"
    extra_fields_json="$(jq -c '(.inbounds[0].users[0] // {}) | del(.name, .uuid, .password)' "${conf_path}" 2>/dev/null || echo "{}")"

    local due_num
    due_num="$(get_due_long_slot_num)"
    local long_hour="${LONG_CRON_HOUR:-3}"
    local daily_hour="${DAILY_CRON_HOUR:-4}"

    local slot_keys=("L:01" "L:02" "L:03" "L:04" "L:05" "D:00")
    local users_json="[]"
    local sk s_num slot_id slot_tag slot_type cur_cred new_cred exp_ts days_left steps_ahead

    for sk in "${slot_keys[@]}"; do
        slot_id="${panel_id}:${sk}"
        if [[ "${sk}" == "D:00" ]]; then
            slot_tag="P24h"
            slot_type="daily"
        else
            s_num="${sk#L:0}"
            slot_tag="P_0${s_num}"
            slot_type="long"
        fi

        # 从当前 sing-box 配置文件按 name 查找该槽位的现有凭据
        cur_cred="$(jq -r --arg name "${slot_id}" --arg cf "${cred_field}" '
            .inbounds[0].users[]? | select(.name == $name) | .[$cf] // empty
        ' "${conf_path}" 2>/dev/null | head -n1)"

        exp_ts="$(get_slot_expire_from_state "${slot_id}")"

        local need_new=0
        if [[ "${action_mode}" == "init" ]]; then
            need_new=1
        elif [[ "${action_mode}" == "rotate_one" && "${sk}" == "${target_slot_key}" ]]; then
            need_new=1
        elif [[ -z "${cur_cred}" || "${exp_ts}" == "0" ]]; then
            need_new=1
        fi

        if (( need_new == 1 )); then
            new_cred="$(generate_new_credential "${cred_field}" "${conf_path}")"
            if [[ "${sk}" == "D:00" ]]; then
                # 短期密码：次日凌晨 04:00 到期 (24小时)
                exp_ts="$(calc_expire_ts 1 "${daily_hour}")"
            else
                if [[ "${action_mode}" == "init" || "${exp_ts}" == "0" ]]; then
                    # 初始构建 5 组长效密码的阶梯剩余寿命 {15, 12, 9, 6, 3} 天，严格对齐 DOY 轮换周期
                    steps_ahead=$(( (s_num - due_num + 5) % 5 ))
                    if (( steps_ahead == 0 )); then
                        days_left=15
                    else
                        days_left=$(( steps_ahead * 3 ))
                    fi
                    exp_ts="$(calc_expire_ts "${days_left}" "${long_hour}")"
                else
                    # 常规轮换：从当前轮换日起 15 天后的凌晨 03:00 到期
                    exp_ts="$(calc_expire_ts 15 "${long_hour}")"
                fi
            fi
            cur_cred="${new_cred}"
            set_slot_state "${slot_id}" "${cur_cred}" "${exp_ts}" "${slot_tag}" "${slot_type}"
        fi

        # 组装 sing-box user 对象（保留 flow 等协议专属字段，写入 name 标注与对应凭据）
        users_json="$(jq -c \
            --argjson arr "${users_json}" \
            --argjson extra "${extra_fields_json}" \
            --arg name "${slot_id}" \
            --arg cf "${cred_field}" \
            --arg val "${cur_cred}" \
            '$arr + [($extra + {"name": $name, ($cf): $val})]' <<< "{}")"
    done

    local tmp_conf="${conf_path}.tmp.$$"
    if jq --argjson u "${users_json}" '.inbounds[0].users = $u' "${conf_path}" > "${tmp_conf}" 2>/dev/null && [[ -s "${tmp_conf}" ]]; then
        mv -f "${tmp_conf}" "${conf_path}"
        return 0
    fi
    rm -f "${tmp_conf}" 2>/dev/null || true
    return 1
}

reload_singbox_service() {
    # 注意: 严禁调用 sing-box fix-config.json！
    # 因为 233boy 的 fix-config.json 会重建 /etc/sing-box/config.json 并清空用户已设置的 DNS (如 1.1.1.1)，导致节点无法解析域名。
    # 同时直接调用 systemctl / rc-service 同步重启，避免 timeout 终止 233boy 脚本的后台重启子进程。
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart sing-box >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box restart >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service sing-box restart >/dev/null 2>&1 || true
    else
        run_sb_cmd 10 restart >/dev/null 2>&1 || true
    fi
    sleep 1
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        if ! systemctl is-active --quiet sing-box; then
            err "sing-box 服务重启后未处于运行状态，请检查配置！"
            return 1
        fi
    fi
    info "sing-box 服务已重启生效 (已完整保留 /etc/sing-box/config.json 中的 DNS 配置)"
    return 0
}

# ==============================================================================
# 备份与回滚
# ==============================================================================

backup_configs() {
    ensure_dirs
    if [[ -d "${SB_CONF_DIR}" ]]; then
        mkdir -p "${BACKUP_DIR}/latest"
        cp -af "${SB_CONF_DIR}"/*.json "${BACKUP_DIR}/latest/" 2>/dev/null || true
        [[ -f "${STATE_FILE}" ]] && cp -af "${STATE_FILE}" "${BACKUP_DIR}/latest/slots_state.json" 2>/dev/null || true
        date '+%Y-%m-%d %H:%M:%S' > "${BACKUP_DIR}/latest/backup_time.txt"
        info "已备份当前 sing-box 节点配置与槽位状态至 ${BACKUP_DIR}/latest"
    fi
}

rollback_configs() {
    if [[ -d "${BACKUP_DIR}/latest" ]] && compgen -G "${BACKUP_DIR}/latest/*.json" >/dev/null; then
        warn "正在回滚 sing-box 节点配置至轮换前状态..."
        cp -af "${BACKUP_DIR}/latest"/*.json "${SB_CONF_DIR}/"
        [[ -f "${BACKUP_DIR}/latest/slots_state.json" ]] && cp -af "${BACKUP_DIR}/latest/slots_state.json" "${STATE_FILE}"
        reload_singbox_service
        info "已成功恢复轮换前的节点配置并重启 sing-box 服务"
        return 0
    else
        err "未找到可用的备份配置，无法执行回滚"
        return 1
    fi
}

# ==============================================================================
# 面板通信与签名上报
# ==============================================================================

send_tg_notify() {
    local status_title="$1" detail_msg="$2"
    [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]] && return 0
    local srv_name="${CUSTOM_SERVER_NAME:-$(hostname)}"
    local text="<b>[sb-rotator v${VERSION}] ${status_title}</b>%0A主机: <code>${srv_name}</code>%0A时间: <code>$(now_beijing) CST</code>%0A详情: ${detail_msg}"
    curl -fsSL --connect-timeout 8 --max-time 15 \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=HTML" -d "text=${text}" >/dev/null 2>&1 || true
}

compute_signature() {
    local timestamp="$1" payload="$2"
    if command -v openssl >/dev/null 2>&1; then
        printf '%s.%s' "${timestamp}" "${payload}" | openssl dgst -sha256 -hmac "${API_KEY}" | awk '{print $NF}'
    else
        printf '%s.%s.%s' "${timestamp}" "${payload}" "${API_KEY}" | sha256sum | awk '{print $1}'
    fi
}

post_to_panel() {
    local payload="$1"
    local endpoint; endpoint="$(get_endpoint_url)" || { err "未配置有效的 PANEL_URL"; return 1; }
    local max_retries="${MAX_RETRIES:-3}" retry_delay="${RETRY_DELAY:-5}" attempt=1
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
        warn "面板 API 请求失败 (第 ${attempt}/${max_retries} 次, HTTP ${http_code})，响应: ${resp_body:-无响应}"
        (( attempt < max_retries )) && { sleep "${retry_delay}"; retry_delay=$(( retry_delay * 2 )); }
        ((attempt++))
    done

    rm -f "${resp_file}"
    printf '%s\n' "${payload}" > "${CACHE_DIR}/last_failed_payload.json"
    err "面板 API 同步失败，载荷已保存至 ${CACHE_DIR}/last_failed_payload.json"
    return 1
}

# ==============================================================================
# 核心执行流：支持全量初始化 (all) / 仅长效轮换 (long) / 仅短期轮换 (daily) / 仅同步 (sync_only)
# ==============================================================================

execute_workflow() {
    local task_type="$1"      # init | cron_long | force_long | cron_daily | sync_only | dry_run
    local custom_slot="${2:-}"
    local is_cron="${3:-0}"

    ensure_dirs
    rotate_log_if_needed
    load_config

    if [[ -z "${PANEL_URL}" || -z "${API_KEY}" || -z "${NODE_IDS}" ]]; then
        err "配置不完整 (PANEL_URL / API_KEY / NODE_IDS 不能为空)，请先运行 sb-rotator 配置"
        return 1
    fi

    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        warn "检测到另一个 sb-rotator 实例正在运行，跳过本次执行"
        return 1
    fi

    # 若尚未完成首次全量初始化，任何定时任务触发时自动升级为首次全量初始化并上传全部 6 组密码
    if [[ ! -f "${INIT_FLAG}" && "${task_type}" != "dry_run" && "${task_type}" != "init" ]]; then
        info "检测到首次运行，自动切换为【首次全量生成并上传全部 6 组槽位密码】模式..."
        task_type="init"
    fi

    # 决定本次要轮换及上传的槽位列表
    local upload_slots=()
    local sync_scope="incremental"
    local conf_action="rotate_one"
    local target_slot_key=""

    case "${task_type}" in
        init)
            sync_scope="full"
            conf_action="init"
            upload_slots=("L:01" "L:02" "L:03" "L:04" "L:05" "D:00")
            ;;
        sync_only)
            sync_scope="full"
            conf_action="ensure"
            upload_slots=("L:01" "L:02" "L:03" "L:04" "L:05" "D:00")
            ;;
        cron_long)
            if ! is_long_rotation_day; then
                info "今日为自然年第 $(get_beijing_doy) 天，非 3 天长效轮换日，无需更换长效槽位"
                return 0
            fi
            local due_num; due_num="$(get_due_long_slot_num)"
            target_slot_key="L:0${due_num}"
            upload_slots=("${target_slot_key}")
            ;;
        force_long)
            local due_num="${custom_slot:-$(get_due_long_slot_num)}"
            due_num="${due_num#0}"
            target_slot_key="L:0${due_num}"
            upload_slots=("${target_slot_key}")
            ;;
        cron_daily)
            target_slot_key="D:00"
            upload_slots=("D:00")
            ;;
        dry_run)
            sync_scope="full"
            conf_action="ensure"
            upload_slots=("L:01" "L:02" "L:03" "L:04" "L:05" "D:00")
            ;;
    esac

    if (( is_cron == 1 )) && [[ "${RANDOM_JITTER_MAX:-0}" =~ ^[0-9]+$ ]] && (( RANDOM_JITTER_MAX > 0 )); then
        local delay=$(( RANDOM % RANDOM_JITTER_MAX ))
        (( delay > 0 )) && { info "定时任务随机延迟 ${delay} 秒..."; sleep "${delay}"; }
    fi

    local nodes_raw
    nodes_raw="$(discover_nodes)" || { err "未发现任何 sing-box 节点配置文件"; return 1; }

    if [[ "${task_type}" != "sync_only" && "${task_type}" != "dry_run" ]]; then
        backup_configs
    fi

    local srv_hostname="${CUSTOM_SERVER_NAME:-$(hostname)}"
    local srv_ip; srv_ip="$(get_server_ip)"
    local rotated_at; rotated_at="$(now_iso8601)"
    local now_ts; now_ts="$(date +%s)"
    local doy; doy="$(get_beijing_doy)"

    local nodes_json_items=""
    local processed_nodes=0

    while IFS='|' read -r idx fname shortname; do
        [[ -z "${idx}" ]] && continue
        local panel_id
        panel_id="$(resolve_panel_node_id "${idx}" "${fname}")" || continue

        local meta proto port cred_field
        meta="$(inspect_node_meta "${shortname}" "${fname}")"
        IFS='|' read -r proto port cred_field <<< "${meta}"

        step "处理节点 #${idx} [${fname}] (面板NodeID: ${panel_id}, 协议: ${proto}, 凭据字段: ${cred_field})"

        if ! update_node_slots_in_conf "${fname}" "${panel_id}" "${cred_field}" "${conf_action}" "${target_slot_key}"; then
            err "更新节点 [${fname}] 多槽位配置失败"
            [[ "${ROLLBACK_ON_FAIL}" == "true" && "${task_type}" != "dry_run" ]] && rollback_configs
            return 1
        fi

        ((processed_nodes++))
    done <<< "${nodes_raw}"

    if (( processed_nodes == 0 )); then
        warn "没有匹配到任何已绑定面板 ID 的节点"
        return 1
    fi

    # 使最新槽位配置在 sing-box 中生效，以便提取链接与接受客户端连接
    if [[ "${task_type}" != "sync_only" && "${task_type}" != "dry_run" ]]; then
        if ! reload_singbox_service; then
            [[ "${ROLLBACK_ON_FAIL}" == "true" ]] && rollback_configs
            return 1
        fi
    fi

    # 构建要上传的 JSON 数据 (首次上传全部 6 个槽位，后续仅上传本次变更的槽位)
    local total_uploaded_slots=0
    while IFS='|' read -r idx fname shortname; do
        [[ -z "${idx}" ]] && continue
        local panel_id
        panel_id="$(resolve_panel_node_id "${idx}" "${fname}")" || continue

        local meta proto port cred_field
        meta="$(inspect_node_meta "${shortname}" "${fname}")"
        IFS='|' read -r proto port cred_field <<< "${meta}"

        local conf_path="${SB_CONF_DIR}/${fname}"
        local first_cred
        first_cred="$(jq -r --arg cf "${cred_field}" '.inbounds[0].users[0][$cf] // empty' "${conf_path}" 2>/dev/null)"
        local base_url
        base_url="$(get_base_node_url "${idx}" "${shortname}" "${fname}" "${proto}" "${port}" "${first_cred}")"

        local slots_json_arr=""
        local sk slot_id slot_tag slot_type slot_cred exp_ts exp_iso slot_url
        for sk in "${upload_slots[@]}"; do
            slot_id="${panel_id}:${sk}"
            if [[ "${sk}" == "D:00" ]]; then
                slot_tag="P24h"
                slot_type="daily"
            else
                slot_tag="P_0${sk#L:0}"
                slot_type="long"
            fi

            slot_cred="$(jq -r --arg name "${slot_id}" --arg cf "${cred_field}" '
                .inbounds[0].users[]? | select(.name == $name) | .[$cf] // empty
            ' "${conf_path}" 2>/dev/null | head -n1)"

            exp_ts="$(get_slot_expire_from_state "${slot_id}")"
            exp_iso="$(ts_to_iso8601_cst "${exp_ts}")"
            slot_url="$(build_slot_node_url "${base_url}" "${first_cred}" "${slot_cred}" "${slot_id}" "${proto}")"

            info "  -> 槽位 [${slot_id}] (${slot_tag}) 凭据: ${slot_cred} | 到期: ${exp_iso} (${exp_ts})"

            local slot_obj
            slot_obj=$(cat <<EOF
        {
          "slot_id": "$(json_escape "${slot_id}")",
          "slot_tag": "$(json_escape "${slot_tag}")",
          "slot_type": "$(json_escape "${slot_type}")",
          "credential": "$(json_escape "${slot_cred}")",
          "node_url": "$(json_escape "${slot_url}")",
          "expires_at": ${exp_ts},
          "expires_at_iso": "${exp_iso}"
        }
EOF
)
            if [[ -n "${slots_json_arr}" ]]; then
                slots_json_arr="${slots_json_arr},"$'\n'"${slot_obj}"
            else
                slots_json_arr="${slot_obj}"
            fi
            ((total_uploaded_slots++))
        done

        # 为向后兼容旧版字段，同时在节点级保留主槽位或当前变更槽位的摘要信息
        local primary_slot_id="${panel_id}:${upload_slots[0]}"
        local primary_cred primary_url primary_exp
        primary_cred="$(jq -r --arg name "${primary_slot_id}" --arg cf "${cred_field}" '.inbounds[0].users[]? | select(.name == $name) | .[$cf] // empty' "${conf_path}" 2>/dev/null | head -n1)"
        primary_exp="$(get_slot_expire_from_state "${primary_slot_id}")"
        primary_url="$(build_slot_node_url "${base_url}" "${first_cred}" "${primary_cred}" "${primary_slot_id}" "${proto}")"

        local node_obj
        node_obj=$(cat <<EOF
    {
      "index": ${idx},
      "node_id": "$(json_escape "${panel_id}")",
      "config_name": "$(json_escape "${fname}")",
      "protocol": "$(json_escape "${proto}")",
      "port": ${port:-0},
      "credential_type": "$(json_escape "${cred_field}")",
      "slot_id": "$(json_escape "${primary_slot_id}")",
      "credential": "$(json_escape "${primary_cred}")",
      "node_url": "$(json_escape "${primary_url}")",
      "expires_at": ${primary_exp},
      "slots": [
${slots_json_arr}
      ]
    }
EOF
)
        if [[ -n "${nodes_json_items}" ]]; then
            nodes_json_items="${nodes_json_items},"$'\n'"${node_obj}"
        else
            nodes_json_items="${node_obj}"
        fi
    done <<< "${nodes_raw}"

    local payload
    payload=$(cat <<EOF
{
  "action": "rotate_nodes_batch",
  "version": "${VERSION}",
  "sync_scope": "${sync_scope}",
  "day_of_year": ${doy},
  "timezone": "Asia/Shanghai",
  "server_hostname": "$(json_escape "${srv_hostname}")",
  "server_ip": "$(json_escape "${srv_ip}")",
  "rotated_at": "${rotated_at}",
  "timestamp": ${now_ts},
  "nodes": [
${nodes_json_items}
  ]
}
EOF
)

    if [[ "${task_type}" == "dry_run" ]]; then
        echo -e "\n${BOLD}${CYAN}=== [演练模式] 即将发送至 $(get_endpoint_url) 的 JSON 载荷 ===${NC}"
        echo "${payload}"
        echo -e "${BOLD}${CYAN}==============================================================${NC}"
        return 0
    fi

    step "正在向面板推送 ${processed_nodes} 个节点共 ${total_uploaded_slots} 个槽位的完整链接与到期时间戳 (模式: ${sync_scope})..."
    if post_to_panel "${payload}"; then
        printf '%s\n' "${payload}" > "${CACHE_DIR}/last_success_payload.json"
        touch "${INIT_FLAG}"
        info "同步完成！本次共上传 ${total_uploaded_slots} 个槽位链接。"
        send_tg_notify "槽位轮换同步成功 (${sync_scope})" "已同步 ${processed_nodes} 个节点 (${total_uploaded_slots} 个槽位)"
        return 0
    else
        err "同步至管理面板失败！"
        if [[ "${task_type}" != "sync_only" && "${ROLLBACK_ON_FAIL:-true}" == "true" ]]; then
            rollback_configs
            send_tg_notify "面板同步失败 (已自动回滚)" "API 请求失败，已恢复原槽位配置"
        fi
        return 1
    fi
}

# ==============================================================================
# 定时任务管理 (北京时间 03:00 轮换长效槽位，04:00 轮换每日短期槽位)
# ==============================================================================

calc_local_hour_from_beijing() {
    local bj_hour="$1"
    local sys_offset_sec cst_offset_sec diff_hours
    sys_offset_sec="$(date +%z | awk '{
        sign = substr($0,1,1); h = substr($0,2,2) + 0; m = substr($0,4,2) + 0;
        sec = h * 3600 + m * 60; if (sign == "-") sec = -sec; print sec;
    }')"
    cst_offset_sec=$(( 8 * 3600 ))
    diff_hours=$(( (sys_offset_sec - cst_offset_sec) / 3600 ))
    echo $(( (bj_hour + diff_hours + 24) % 24 ))
}

setup_cron() {
    load_config
    local long_bj_h="${LONG_CRON_HOUR:-3}"
    local daily_bj_h="${DAILY_CRON_HOUR:-4}"
    local min="${CRON_MINUTE:-0}"

    local long_local_h daily_local_h
    long_local_h="$(calc_local_hour_from_beijing "${long_bj_h}")"
    daily_local_h="$(calc_local_hour_from_beijing "${daily_bj_h}")"

    cat > "${CRON_FILE}" <<EOF
# sb-rotator v2.0.1 定时任务
# 1) 每日北京时间 $(printf '%02d:%02d' "${long_bj_h}" "${min}") 检查并轮换到期长效密码槽位 (每隔3天轮换1组，15天有效期)
# 2) 每日北京时间 $(printf '%02d:%02d' "${daily_bj_h}" "${min}") 轮换短期24h密码槽位 (D:00 / P24h)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${min} ${long_local_h} * * * root /usr/local/bin/sb-rotator --cron-long >> ${LOG_FILE} 2>&1
${min} ${daily_local_h} * * * root /usr/local/bin/sb-rotator --cron-daily >> ${LOG_FILE} 2>&1
EOF
    chmod 644 "${CRON_FILE}"
    systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || service cron reload 2>/dev/null || true
    info "已部署双定时任务: 长效槽位每日北京时间 $(printf '%02d:%02d' "${long_bj_h}" "${min}") (本地 $(printf '%02d:%02d' "${long_local_h}" "${min}"))，短期槽位每日北京时间 $(printf '%02d:%02d' "${daily_bj_h}" "${min}") (本地 $(printf '%02d:%02d' "${daily_local_h}" "${min}"))"
}

remove_cron() {
    if [[ -f "${CRON_FILE}" ]]; then
        rm -f "${CRON_FILE}"
        systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
        info "已移除定时任务 ${CRON_FILE}"
    fi
}

# ==============================================================================
# 状态展示与交互面板
# ==============================================================================

show_mapping_table() {
    load_config
    ensure_dirs
    local doy due_num
    doy="$(get_beijing_doy)"
    due_num="$(get_due_long_slot_num)"
    echo -e "\n${BOLD}${CYAN}================ 当前本机 sing-box 节点与 6 槽位状态表 ================${NC}"
    echo -e "当前北京时间: $(now_beijing) | 自然年第 ${BOLD}${doy}${NC} 天 | 当前周期轮值长效槽: ${BOLD}L:0${due_num}${NC}"
    echo "--------------------------------------------------------------------------------"

    local nodes_raw
    if ! nodes_raw="$(discover_nodes 2>/dev/null)"; then
        echo -e "${YELLOW}未检测到任何 sing-box 节点配置，请先使用 sing-box add 添加节点。${NC}"
        echo "================================================================================"
        return 1
    fi

    while IFS='|' read -r idx fname shortname; do
        [[ -z "${idx}" ]] && continue
        local meta proto port cred_field panel_id
        meta="$(inspect_node_meta "${shortname}" "${fname}")"
        IFS='|' read -r proto port cred_field <<< "${meta}"
        panel_id="$(resolve_panel_node_id "${idx}" "${fname}")" || panel_id="未绑定(跳过)"
        echo -e "${BOLD}节点 #${idx}) ${fname}${NC} | 协议: ${GREEN}${proto}${NC} | 端口: ${port} | 凭据字段: ${cred_field} | 面板NodeID: ${YELLOW}${panel_id}${NC}"

        if [[ "${panel_id}" != "未绑定(跳过)" && -f "${SB_CONF_DIR}/${fname}" ]]; then
            local sk slot_id u_cred exp_ts exp_str
            for sk in "L:01" "L:02" "L:03" "L:04" "L:05" "D:00"; do
                slot_id="${panel_id}:${sk}"
                u_cred="$(jq -r --arg name "${slot_id}" --arg cf "${cred_field}" '.inbounds[0].users[]? | select(.name == $name) | .[$cf] // empty' "${SB_CONF_DIR}/${fname}" 2>/dev/null | head -n1)"
                exp_ts="$(get_slot_expire_from_state "${slot_id}")"
                if [[ -n "${u_cred}" && "${exp_ts}" != "0" ]]; then
                    exp_str="$(ts_to_iso8601_cst "${exp_ts}")"
                    printf "   ├─ 槽位 %-8s : %-36s (到期: %s | TS: %s)\n" "${slot_id}" "${u_cred}" "${exp_str}" "${exp_ts}"
                else
                    printf "   ├─ 槽位 %-8s : 未初始化 (执行首次全量同步后自动生成)\n" "${slot_id}"
                fi
            done
        fi
    done <<< "${nodes_raw}"
    echo "================================================================================"
}

test_api_connection() {
    load_config
    local endpoint; endpoint="$(get_endpoint_url)" || { err "请先配置面板地址 (PANEL_URL)"; return 1; }
    step "正在向面板接口发送连通性测试请求: ${endpoint}"
    local ts sig payload http_code resp_file
    ts="$(date +%s)"
    payload=$(cat <<EOF
{
  "action": "ping",
  "version": "${VERSION}",
  "server_hostname": "$(json_escape "${CUSTOM_SERVER_NAME:-$(hostname)}")",
  "server_ip": "$(get_server_ip)",
  "timestamp": ${ts}
}
EOF
)
    sig="$(compute_signature "${ts}" "${payload}")"
    resp_file="$(mktemp /tmp/sb-rotator-ping.XXXXXX)"
    http_code="$(curl -sS --connect-timeout 8 --max-time 15 -o "${resp_file}" -w "%{http_code}" -X POST "${endpoint}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "X-API-Key: ${API_KEY}" \
        -H "X-Timestamp: ${ts}" \
        -H "X-Signature: ${sig}" \
        -d "${payload}" 2>&1 || echo "000")"
    local body=""; [[ -f "${resp_file}" ]] && body="$(head -c 400 "${resp_file}")"
    rm -f "${resp_file}"
    echo -e "HTTP 状态码: ${BOLD}${http_code}${NC}\n面板响应内容: ${body:-<空>}"
    [[ "${http_code}" =~ ^2[0-9][0-9]$ ]] && { info "面板 API 通信测试通过！"; return 0; }
    warn "面板未返回 2xx 状态码，请检查配置。"
    return 1
}

interactive_configure() {
    load_config
    echo -e "\n${BOLD}${BLUE}>>> 配置 sb-rotator v${VERSION} 多槽位阶梯轮换与面板对接参数 <<<${NC}"
    show_mapping_table || true

    local input_url input_key input_ids input_rb input_tg input_tk input_cid
    prompt_read "1. 请输入订阅管理面板地址 [${PANEL_URL}]: " input_url || return 1
    PANEL_URL="${input_url:-${PANEL_URL}}"

    prompt_read "2. 请输入面板通信密码 / API Key [${API_KEY}]: " input_key || return 1
    API_KEY="${input_key:-${API_KEY}}"

    echo -e "\n${CYAN}提示: 多个节点 ID 用英文逗号分隔，第 1 个对应配置中的 1)，第 2 个对应 2)，不需要轮换填 0。${NC}"
    prompt_read "3. 请输入面板节点 ID 列表 [${NODE_IDS}]: " input_ids || return 1
    NODE_IDS="${input_ids:-${NODE_IDS}}"
    NODE_IDS="${NODE_IDS// /,}"

    prompt_read "4. 面板同步失败时是否自动回滚配置? (y/n，默认 y) [y]: " input_rb || return 1
    [[ "${input_rb:-y}" =~ ^[Nn]$ ]] && ROLLBACK_ON_FAIL="false" || ROLLBACK_ON_FAIL="true"

    prompt_read "5. [可选] 是否配置 Telegram 告警通知? (y/n，默认 n) [n]: " input_tg || return 1
    if [[ "${input_tg:-n}" =~ ^[Yy]$ ]]; then
        prompt_read "   请输入 Telegram Bot Token [${TG_BOT_TOKEN}]: " input_tk || return 1
        TG_BOT_TOKEN="${input_tk:-${TG_BOT_TOKEN}}"
        prompt_read "   请输入 Telegram Chat ID [${TG_CHAT_ID}]: " input_cid || return 1
        TG_CHAT_ID="${input_cid:-${TG_CHAT_ID}}"
    fi

    save_config
    setup_cron
    info "配置已保存至 ${CONFIG_FILE}"
}

view_logs_menu() {
    echo -e "\n${BOLD}${CYAN}================ 日志与载荷查看工具 ================${NC}"
    echo "  1) 查看最近 50 行日志"
    echo "  2) 实时追踪日志输出 (Ctrl+C 退出)"
    echo "  3) 查看最近一次成功上传的 JSON 载荷"
    echo "  4) 查看最近一次失败的 JSON 载荷"
    echo "  5) 清空历史日志"
    echo "  0) 返回主菜单"
    local log_opt=""
    prompt_read "请选择操作 [0-5]: " log_opt || return 0
    case "${log_opt}" in
        1) tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志" ;;
        2) tail -f "${LOG_FILE}" ;;
        3) [[ -f "${CACHE_DIR}/last_success_payload.json" ]] && cat "${CACHE_DIR}/last_success_payload.json" || echo "暂无记录" ;;
        4) [[ -f "${CACHE_DIR}/last_failed_payload.json" ]] && cat "${CACHE_DIR}/last_failed_payload.json" || echo "暂无记录" ;;
        5) : > "${LOG_FILE}"; info "已清空日志" ;;
    esac
}

uninstall_all() {
    echo -e "\n${RED}${BOLD}⚠️  确认卸载 sb-rotator 及其定时任务吗？（不影响 sing-box 本身）${NC}"
    local confirm=""
    prompt_read "输入 y 确认卸载，其他键取消: " confirm || return 0
    [[ ! "${confirm}" =~ ^[Yy]$ ]] && { info "已取消卸载"; return 0; }
    remove_cron
    rm -rf "${INSTALL_DIR}" "${LOCK_FILE}" /usr/local/bin/sb-rotator /usr/local/bin/sbr
    echo -e "${GREEN}✅ sb-rotator 已卸载完成！${NC}"
    exit 0
}

main_menu() {
    load_config
    while true; do
        local cron_status="${RED}未启用${NC}"
        [[ -f "${CRON_FILE}" ]] && cron_status="${GREEN}已启用 (北京时间 03:00 长效轮换 / 04:00 短期P24h轮换)${NC}"
        local init_status="${YELLOW}未初始化 (首次运行将上传全部6组密码)${NC}"
        [[ -f "${INIT_FLAG}" ]] && init_status="${GREEN}已完成首次全量同步 (后续仅增量上传变更密码)${NC}"

        echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
        echo -e "${BOLD}   233boy/sing-box 多槽位阶梯换密与面板同步工具 v${VERSION}${NC}"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        echo -e "  面板接口地址 : ${YELLOW}${PANEL_URL:-未配置}${NC}"
        echo -e "  绑定节点 ID  : ${YELLOW}${NODE_IDS:-未配置}${NC}"
        echo -e "  初始化状态   : ${init_status}"
        echo -e "  定时任务状态 : ${cron_status}"
        echo -e "-----------------------------------------------------------------"
        echo -e "  ${GREEN}1.${NC} 首次全量初始化 / 重置全部 6 组密码并全量上传面板 (--init)"
        echo -e "  ${GREEN}2.${NC} 立即轮换今日长效槽位 (L:0$(get_due_long_slot_num)) 并增量上传 (--force-long)"
        echo -e "  ${GREEN}3.${NC} 立即轮换短期 24h 槽位 (D:00 / P24h) 并增量上传 (--rotate-daily)"
        echo -e "  ${GREEN}4.${NC} 仅全量同步当前 6 组槽位链接到面板 (不改密) (--sync-only)"
        echo -e "  ${GREEN}5.${NC} 演练模式 (Dry-Run：预览 JSON 载荷，不实际修改) (--dry-run)"
        echo -e "  ${GREEN}6.${NC} 查看本机节点与 6 槽位凭据/到期时间状态表 (--status)"
        echo -e "  ${GREEN}7.${NC} 修改对接配置 (面板地址 / API Key / 节点 ID)"
        echo -e "  ${GREEN}8.${NC} 测试面板 API 连通性 (--test-api)"
        echo -e "  ${GREEN}9.${NC} 查看运行日志与最近上传的 JSON 载荷"
        echo -e "  ${GREEN}10.${NC} 紧急回滚到上一次备份的配置 (--rollback)"
        echo -e "  ${RED}11.${NC} 一键卸载本程序 (--uninstall)"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo -e "${BOLD}${CYAN}=================================================================${NC}"
        local choice=""
        prompt_read "请输入选项编号 [0-11]: " choice || exit 0
        case "${choice}" in
            1) execute_workflow "init" ;;
            2) execute_workflow "force_long" ;;
            3) execute_workflow "cron_daily" ;;
            4) execute_workflow "sync_only" ;;
            5) execute_workflow "dry_run" ;;
            6) show_mapping_table ;;
            7) interactive_configure ;;
            8) test_api_connection ;;
            9) view_logs_menu ;;
            10) rollback_configs ;;
            11) uninstall_all ;;
            0|"") exit 0 ;;
            *) warn "无效选项 [${choice}]" ;;
        esac
    done
}

usage() {
    cat <<EOF
用法: sb-rotator [选项]

无参数                  打开交互式管理菜单
--init                  生成/重置全部 6 个槽位 (5长效 L:01~05 + 1短期 D:00) 并全量上传面板
--cron-long             [定时任务 03:00] 按自然年 DOY 每 3 天轮换 1 组长效密码并增量上传
--force-long [1-5]      手动立即轮换指定(或今日对应)的长效槽位并增量上传
--cron-daily            [定时任务 04:00] 每日轮换短期 24h 密码 (D:00 / P24h) 并增量上传
--rotate-daily          手动立即轮换短期 24h 密码 (D:00 / P24h) 并增量上传
--sync-only             不修改密码，全量上传当前 6 个槽位链接与到期时间
--dry-run               演练模式：预览多槽位 JSON 载荷
--status                查看所有节点的 6 槽位凭据与到期时间戳
--test-api              测试面板 API 连通性
--config                进入交互式配置向导
--logs                  查看最近 50 行运行日志
--rollback              回滚到上一次轮换前的节点配置
--uninstall             一键卸载本程序
EOF
}

case "${1:-}" in
    --init|--run)    execute_workflow "init" ;;
    --cron-long)     execute_workflow "cron_long" "" 1 ;;
    --force-long)    execute_workflow "force_long" "${2:-}" 0 ;;
    --cron-daily)    execute_workflow "cron_daily" "" 1 ;;
    --rotate-daily)  execute_workflow "cron_daily" "" 0 ;;
    --sync-only)     execute_workflow "sync_only" ;;
    --dry-run)       execute_workflow "dry_run" ;;
    --status)        show_mapping_table ;;
    --test-api)      test_api_connection ;;
    --config)        interactive_configure ;;
    --logs)          tail -n 50 "${LOG_FILE}" 2>/dev/null || echo "暂无日志" ;;
    --rollback)      rollback_configs ;;
    --uninstall)     uninstall_all ;;
    -h|--help)       usage ;;
    "")              main_menu ;;
    *)               err "未知参数: $1"; usage; exit 1 ;;
esac

__EOF_SB_ROTATOR_CORE__

    chmod +x "${INSTALL_BIN}"
    ln -sf "${INSTALL_BIN}" "${ALIAS_BIN}"
}

main() {
    check_root
    echo -e "\n${BOLD}${CYAN}=================================================================${NC}"
    echo -e "${BOLD}   233boy/sing-box 多槽位阶梯自动换密 & 面板同步一键脚本 v2.0.1${NC}"
    echo -e "${BOLD}${CYAN}=================================================================${NC}"

    if [[ -x "${INSTALL_BIN}" && -f "${INSTALL_DIR}/config.env" && "${1:-}" == "" ]]; then
        echo -e "${GREEN}检测到本机已安装 sb-rotator，请选择操作：${NC}"
        echo -e "  ${GREEN}1)${NC} 升级核心脚本至 v2.0.1 并立即执行首次 6 槽位全量初始化与上传"
        echo -e "  ${GREEN}2)${NC} 升级核心脚本至 v2.0.1 并打开管理菜单"
        echo -e "  ${GREEN}3)${NC} 重新引导配置"
        echo -e "  ${RED}4)${NC} 一键卸载"
        echo -e "  ${GREEN}0)${NC} 退出"
        local exist_opt=""
        prompt_read "请选择 [0-4，默认 1]: " exist_opt || exit 0
        case "${exist_opt:-1}" in
            1)
                check_dependencies
                deploy_core_script
                "${INSTALL_BIN}" --init || true
                exec "${INSTALL_BIN}"
                ;;
            2)
                check_dependencies
                deploy_core_script
                exec "${INSTALL_BIN}"
                ;;
            3) ;;
            4) deploy_core_script; exec "${INSTALL_BIN}" --uninstall ;;
            0) exit 0 ;;
        esac
    fi

    check_dependencies
    deploy_core_script
    echo -e "${GREEN}[成功] 核心程序 v2.0.1 已安装至 ${INSTALL_BIN} (快捷命令: sbr)${NC}"

    "${INSTALL_BIN}" --config

    echo ""
    local do_init=""
    prompt_read "是否立即生成全部 6 组槽位密码 (5组长效+1组24h短期) 并全量上传至面板？(y/n，默认 y): " do_init || true
    if [[ "${do_init:-y}" =~ ^[Yy]$ ]]; then
        "${INSTALL_BIN}" --init || true
    fi

    echo -e "\n${BOLD}${GREEN}=================================================================${NC}"
    echo -e "${BOLD}${GREEN} 🎉 v2.0.1 部署完成！随时输入 ${YELLOW}sbr${GREEN} 即可管理 6 槽位状态与日志${NC}"
    echo -e "${BOLD}${GREEN}=================================================================${NC}"
}

main "$@"
