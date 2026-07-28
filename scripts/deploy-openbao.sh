#!/usr/bin/env bash
# ==============================================================================
# OpenBao 一键部署脚本
# 支持架构: AMD64 / ARM64
# 部署模式: 单机 / HA (高可用, 基于 Raft 存储)
# 官方文档: https://openbao.org/docs/
# HA 指南:  https://openbao.org/docs/concepts/ha/
# ==============================================================================

set -euo pipefail

# ========================== 默认配置 ==========================================
OPENBAO_VERSION="${OPENBAO_VERSION:-2.6.1}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/openbao}"
DATA_DIR="${DATA_DIR:-/opt/openbao/data}"
TLS_DIR="${TLS_DIR:-/opt/openbao/tls}"
LOG_DIR="${LOG_DIR:-/var/log/openbao}"
BAO_USER="${BAO_USER:-openbao}"
BAO_GROUP="${BAO_GROUP:-openbao}"

DEPLOY_MODE="${DEPLOY_MODE:-standalone}"
NODE_ID="${NODE_ID:-node1}"
API_ADDR="${API_ADDR:-}"
CLUSTER_ADDR="${CLUSTER_ADDR:-}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:8200}"
CLUSTER_LISTEN_ADDR="${CLUSTER_LISTEN_ADDR:-0.0.0.0:8201}"
ENABLE_TLS="${ENABLE_TLS:-false}"
ENABLE_UI="${ENABLE_UI:-true}"
RAFT_PEERS="${RAFT_PEERS:-}"
FORCE="${FORCE:-false}"
LOCAL_BINARY="${LOCAL_BINARY:-}"

GITHUB_BASE_URL="https://github.com/openbao/openbao/releases/download"

# ========================== 工具函数 ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

die() {
    log_error "$@"
    exit 1
}

confirm() {
    local msg="${1:-继续?}"
    if [[ "${FORCE}" == "true" ]]; then
        return 0
    fi
    echo -en "${YELLOW}${msg} [y/N]: ${NC}"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# ========================== 依赖检查 ==========================================
check_dependencies() {
    log_step "检查系统依赖..."
    local missing=()
    local required_cmds=(tar getent)

    # 在线模式需要 curl 和 sha256sum
    if [[ -z "$LOCAL_BINARY" ]]; then
        required_cmds+=(curl sha256sum)
    fi

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "缺少必要依赖: ${missing[*]}。请先安装后重试。"
    fi
    log_info "所有依赖检查通过$([ -n "$LOCAL_BINARY" ] && echo ' (离线模式)')"
}

# ========================== 架构检测 ==========================================
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            die "不支持的架构: ${machine}。仅支持 amd64 和 arm64。"
            ;;
    esac
    log_info "检测到系统架构: ${ARCH}"
}

# ========================== 离线安装 ==========================================
install_local_openbao() {
    local src="${LOCAL_BINARY}"

    if [[ ! -e "$src" ]]; then
        die "本地文件不存在: ${src}"
    fi

    log_step "从本地文件安装 OpenBao (${src})..."

    install -d -m 0755 "$INSTALL_DIR"

    if [[ "$src" == *.tar.gz || "$src" == *.tgz ]]; then
        # 从 tar 包安装
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        log_info "解压本地 tar 包..."
        tar -xzf "$src" -C "$tmp_dir"

        if [[ -f "${tmp_dir}/bao" ]]; then
            install -m 0755 "${tmp_dir}/bao" "${INSTALL_DIR}/bao"
        elif [[ -f "${tmp_dir}/openbao" ]]; then
            install -m 0755 "${tmp_dir}/openbao" "${INSTALL_DIR}/bao"
        else
            rm -rf "$tmp_dir"
            die "tar 包中未找到 bao 或 openbao 二进制文件"
        fi
        rm -rf "$tmp_dir"
    elif [[ -x "$src" || -f "$src" ]]; then
        # 从单个二进制文件安装
        install -m 0755 "$src" "${INSTALL_DIR}/bao"
    else
        die "不支持的文件类型: ${src}。支持 .tar.gz / .tgz 或可执行的 bao 二进制文件"
    fi

    # 验证二进制可用
    if [[ -x "${INSTALL_DIR}/bao" ]]; then
        local ver
        ver="$("${INSTALL_DIR}/bao" version 2>/dev/null || echo 'unknown')"
        log_info "OpenBao 已从本地文件安装到 ${INSTALL_DIR}/bao (${ver})"
    else
        die "安装失败: ${INSTALL_DIR}/bao 不可执行"
    fi
}

# ========================== 下载与安装 ========================================
download_openbao() {
    local filename="openbao_${OPENBAO_VERSION}_linux_${ARCH}.tar.gz"
    local url="${GITHUB_BASE_URL}/v${OPENBAO_VERSION}/${filename}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local archive="${tmp_dir}/${filename}"

    log_step "下载 OpenBao v${OPENBAO_VERSION} (${ARCH})..."
    log_info "下载地址: ${url}"

    local http_code
    http_code="$(curl -sL -o "$archive" -w '%{http_code}' "$url")" || true

    if [[ "$http_code" != "200" ]]; then
        rm -rf "$tmp_dir"
        die "下载失败 (HTTP ${http_code})。请检查版本号 ${OPENBAO_VERSION} 是否存在。"
    fi

    log_step "校验文件完整性..."
    local checksum_url="${GITHUB_BASE_URL}/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_checksums.txt"
    local checksum_file="${tmp_dir}/checksums.txt"
    if curl -sL -o "$checksum_file" "$checksum_url" && [[ -s "$checksum_file" ]]; then
        local expected_hash
        expected_hash="$(grep "${filename}" "$checksum_file" | awk '{print $1}')"
        if [[ -n "$expected_hash" ]]; then
            local actual_hash
            actual_hash="$(sha256sum "$archive" | awk '{print $1}')"
            if [[ "$expected_hash" != "$actual_hash" ]]; then
                rm -rf "$tmp_dir"
                die "SHA256 校验失败！文件可能损坏或被篡改。"
            fi
            log_info "SHA256 校验通过"
        else
            log_warn "未在 checksum 文件中找到对应条目，跳过校验"
        fi
    else
        log_warn "无法下载校验文件，跳过 SHA256 校验"
    fi

    log_step "解压安装..."
    tar -xzf "$archive" -C "$tmp_dir"

    install -d -m 0755 "$INSTALL_DIR"
    install -m 0755 "${tmp_dir}/bao" "${INSTALL_DIR}/bao"
    rm -rf "$tmp_dir"

    log_info "OpenBao v${OPENBAO_VERSION} 已安装到 ${INSTALL_DIR}/bao"
}

# ========================== 用户与目录 ========================================
setup_user_and_dirs() {
    log_step "创建系统用户与目录..."

    if ! getent group "$BAO_GROUP" &>/dev/null; then
        groupadd --system "$BAO_GROUP"
        log_info "创建系统组: ${BAO_GROUP}"
    fi

    if ! getent passwd "$BAO_USER" &>/dev/null; then
        useradd --system --gid "$BAO_GROUP" --no-create-home --shell /usr/sbin/nologin "$BAO_USER"
        log_info "创建系统用户: ${BAO_USER}"
    fi

    for dir in "$CONFIG_DIR" "$DATA_DIR" "$TLS_DIR" "$LOG_DIR" "/opt/openbao/raft"; do
        install -d -m 0750 -o "$BAO_USER" -g "$BAO_GROUP" "$dir"
    done

    log_info "目录结构创建完成"
}

# ========================== TLS 证书 ==========================================
generate_tls() {
    if [[ "$ENABLE_TLS" != "true" ]]; then
        log_warn "TLS 已禁用，不建议在生产环境使用"
        return
    fi

    if [[ -f "${TLS_DIR}/tls.crt" && -f "${TLS_DIR}/tls.key" ]]; then
        log_info "TLS 证书已存在，跳过生成"
        return
    fi

    log_step "生成自签名 TLS 证书..."

    if ! command -v openssl &>/dev/null; then
        log_warn "未安装 openssl，跳过 TLS 证书生成"
        log_warn "请手动放置证书到 ${TLS_DIR}/tls.crt 和 ${TLS_DIR}/tls.key"
        return
    fi

    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${TLS_DIR}/tls.key" \
        -out "${TLS_DIR}/tls.crt" \
        -days 3650 \
        -subj "/C=US/ST=State/L=City/O=OpenBao/CN=openbao.local" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    chown "${BAO_USER}:${BAO_GROUP}" "${TLS_DIR}/tls.crt" "${TLS_DIR}/tls.key"
    chmod 0640 "${TLS_DIR}/tls.key"

    log_info "TLS 证书已生成 (有效期 10 年)"
    log_warn "生产环境请替换为正式证书！"
}

# ========================== 配置文件 ==========================================
generate_config() {
    log_step "生成 OpenBao 配置文件..."

    local protocol="http"
    [[ "$ENABLE_TLS" == "true" ]] && protocol="https"

    if [[ -z "$API_ADDR" ]]; then
        local host_ip
        host_ip="$(hostname -f 2>/dev/null || hostname -I | awk '{print $1}')"
        API_ADDR="${protocol}://${host_ip}:8200"
        log_info "自动推断 API_ADDR: ${API_ADDR}"
    fi
    if [[ -z "$CLUSTER_ADDR" ]]; then
        local host_ip
        host_ip="$(hostname -f 2>/dev/null || hostname -I | awk '{print $1}')"
        CLUSTER_ADDR="${protocol}://${host_ip}:8201"
    fi

    local config_file="${CONFIG_DIR}/openbao.hcl"

    if [[ "$DEPLOY_MODE" == "ha" ]]; then
        generate_ha_config "$config_file"
    else
        generate_standalone_config "$config_file"
    fi

    chown "${BAO_USER}:${BAO_GROUP}" "$config_file"
    chmod 0640 "$config_file"
    log_info "配置文件已写入: ${config_file}"
}

generate_standalone_config() {
    local config_file="$1"
    local tls_block=""
    if [[ "$ENABLE_TLS" == "true" ]]; then
        tls_block="  tls_cert_file = \"${TLS_DIR}/tls.crt\"
  tls_key_file  = \"${TLS_DIR}/tls.key\""
    else
        tls_block="  tls_disable   = 1"
    fi

    cat > "$config_file" <<EOF
# ============================================================================
# OpenBao 单机配置
# 文档: https://openbao.org/docs/configuration/
# ============================================================================

ui = ${ENABLE_UI}

storage "file" {
  path = "${DATA_DIR}"
}

listener "tcp" {
  address = "${LISTEN_ADDR}"
${tls_block}
}

api_addr     = "${API_ADDR}"
cluster_addr = "${CLUSTER_ADDR}"

telemetry {
  disable_hostname = true
  prometheus_retention_time = "30s"
}
EOF
}

generate_ha_config() {
    local config_file="$1"
    local raft_data="/opt/openbao/raft"

    local tls_block=""
    if [[ "$ENABLE_TLS" == "true" ]]; then
        tls_block="  tls_cert_file   = \"${TLS_DIR}/tls.crt\"
  tls_key_file    = \"${TLS_DIR}/tls.key\""
    else
        tls_block="  tls_disable     = 1"
    fi

    cat > "$config_file" <<EOF
# ============================================================================
# OpenBao 高可用 (HA) 配置 - 基于 Integrated Storage (Raft)
# 文档: https://openbao.org/docs/concepts/ha/
# 存储: https://openbao.org/docs/configuration/storage/raft/
# ============================================================================

ui = ${ENABLE_UI}

storage "raft" {
  path    = "${raft_data}"
  node_id = "${NODE_ID}"

  performance_multiplier = 1
  trailing_logs       = 10000
  snapshot_threshold  = 8192
  snapshot_interval   = "120s"
  max_entry_size = 1048576

EOF

    if [[ -n "$RAFT_PEERS" ]]; then
        IFS=',' read -ra PEERS <<< "$RAFT_PEERS"
        for peer in "${PEERS[@]}"; do
            peer="$(echo "$peer" | xargs)"
            [[ -z "$peer" ]] && continue
            cat >> "$config_file" <<EOF
  retry_join {
    leader_api_addr = "${peer}"
  }

EOF
        done
    fi

    cat >> "$config_file" <<EOF
  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "10s"
    max_trailing_logs         = 250
    min_quorum                = 2
    server_stabilization_time = "10s"
  }
}

listener "tcp" {
  address         = "${LISTEN_ADDR}"
  cluster_address = "${CLUSTER_LISTEN_ADDR}"
${tls_block}
}

api_addr     = "${API_ADDR}"
cluster_addr = "${CLUSTER_ADDR}"

telemetry {
  disable_hostname = true
  prometheus_retention_time = "30s"
}
EOF
}

# ========================== 环境变量文件 ======================================
generate_env_file() {
    local env_file="${CONFIG_DIR}/openbao.env"
    local protocol="http"
    [[ "$ENABLE_TLS" == "true" ]] && protocol="https"

    cat > "$env_file" <<EOF
# OpenBao 环境变量配置
BAO_ADDR="${protocol}://127.0.0.1:8200"
BAO_SKIP_VERIFY=true
EOF

    log_info "环境变量文件已写入 (含 BAO_SKIP_VERIFY=true，用于自签名证书)"

    chown "${BAO_USER}:${BAO_GROUP}" "$env_file"
    chmod 0640 "$env_file"
}

# ========================== Systemd 服务 ======================================
install_systemd_service() {
    log_step "安装 systemd 服务..."

    local service_file="/etc/systemd/system/openbao.service"

    cat > "$service_file" <<'EOF'
[Unit]
Description=OpenBao - Secret Management & Data Protection
Documentation=https://openbao.org/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/openbao/openbao.hcl
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
EnvironmentFile=/etc/openbao/openbao.env
User=openbao
Group=openbao
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/bao server -config=/etc/openbao/openbao.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
MemorySwapMax=0
LimitNOFILE=65536
LimitMEMLOCK=infinity
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable openbao.service
    log_info "systemd 服务已安装并设为开机启动"
}

# ========================== 启动前检查 ========================================
pre_start_checks() {
    # 端口占用检测
    local ports=("${LISTEN_ADDR##*:}" "${CLUSTER_LISTEN_ADDR##*:}")
    for port in "${ports[@]}"; do
        port="$(echo "$port" | xargs)"  # trim
        [[ -z "$port" || "$port" == "0" ]] && continue
        local occupier
        occupier="$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 || \
                   lsof -i ":${port}" -sTCP:LISTEN 2>/dev/null | tail -1 || true)"
        if [[ -n "$occupier" ]]; then
            die "端口 ${port} 已被占用！\n  ${occupier}\n  请释放端口或通过 --listen-addr / --cluster-addr 更换地址"
        fi
    done
    log_info "端口检测通过 (${LISTEN_ADDR}, ${CLUSTER_LISTEN_ADDR})"
}

# ========================== 启动与验证 ========================================
start_and_verify() {
    log_step "启动 OpenBao 服务..."

    if ! systemctl start openbao.service 2>/dev/null; then
        log_error "服务启动失败，最近日志:"
        journalctl -u openbao -n 20 --no-pager 2>/dev/null || true
        echo ""
        die "请检查配置或运行: journalctl -xeu openbao.service"
    fi

    local max_wait=30
    local waited=0
    local protocol="http"
    [[ "$ENABLE_TLS" == "true" ]] && protocol="https"

    while [[ $waited -lt $max_wait ]]; do
        if curl -sk "${protocol}://127.0.0.1:8200/v1/sys/health" &>/dev/null; then
            log_info "OpenBao 服务已启动"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [[ $waited -ge $max_wait ]]; then
        log_warn "等待超时 (${max_wait}s)，请检查日志: journalctl -u openbao"
        return 1
    fi

    log_step "验证安装..."
    local health
    health="$(curl -sk "${protocol}://127.0.0.1:8200/v1/sys/health" 2>/dev/null)" || true

    if echo "$health" | grep -q '"initialized"'; then
        log_info "健康检查通过"
    else
        log_warn "健康检查返回异常，请手动确认"
    fi

    if bao version &>/dev/null; then
        local ver
        ver="$(bao version 2>/dev/null)"
        log_info "CLI 版本: ${ver}"
    fi

    return 0
}

# ========================== 安装后提示 ========================================
post_install_instructions() {
    local protocol="http"
    [[ "$ENABLE_TLS" == "true" ]] && protocol="https"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}  OpenBao v${OPENBAO_VERSION} 部署完成！${NC}"
    echo "============================================================"
    echo ""
    echo "  部署模式:  $([ "$DEPLOY_MODE" == "ha" ] && echo '高可用 (HA) - Raft 存储' || echo '单机 (Standalone)')"
    echo "  架构:      ${ARCH}"
    echo "  监听地址:  ${LISTEN_ADDR}"
    echo "  API 地址:  ${API_ADDR}"
    echo "  配置文件:  ${CONFIG_DIR}/openbao.hcl"
    echo "  数据目录:  ${DATA_DIR}"
    echo "  日志查看:  journalctl -u openbao -f"
    echo ""

    if [[ "$DEPLOY_MODE" == "ha" ]]; then
        echo -e "${YELLOW}  === HA 集群初始化步骤 ===${NC}"
        echo ""
        echo "  1. 设置环境变量 (自签名证书需要跳过验证):"
        echo "     export BAO_ADDR=${protocol}://127.0.0.1:8200"
        echo "     export BAO_SKIP_VERIFY=true"
        echo ""
        echo "  2. 在第一个节点上初始化:"
        echo "     bao operator init -key-shares=5 -key-threshold=3"
        echo ""
        echo "  3. 保存返回的 Unseal Keys 和 Root Token!"
        echo ""
        echo "  4. 在第一个节点上解封 (重复 3 次, 使用不同的 key):"
        echo "     bao operator unseal <unseal_key_1>"
        echo "     bao operator unseal <unseal_key_2>"
        echo "     bao operator unseal <unseal_key_3>"
        echo ""
        echo "  5. 在其他节点上加入 Raft 集群并解封:"
        echo "     bao operator raft join ${protocol}://<leader_addr>:8200"
        echo "     bao operator unseal <unseal_key_1>"
        echo "     bao operator unseal <unseal_key_2>"
        echo "     bao operator unseal <unseal_key_3>"
        echo ""
        echo "  6. 验证集群状态:"
        echo "     bao operator raft list-peers"
        echo ""
    else
        echo -e "${YELLOW}  === 初始化步骤 ===${NC}"
        echo ""
        echo "  1. 设置环境变量 (自签名证书需要跳过验证):"
        echo "     export BAO_ADDR=${protocol}://127.0.0.1:8200"
        echo "     export BAO_SKIP_VERIFY=true"
        echo ""
        echo "  2. 初始化 OpenBao:"
        echo "     bao operator init"
        echo ""
        echo "  3. 保存返回的 Unseal Keys 和 Root Token!"
        echo ""
        echo "  4. 解封 OpenBao (重复 3 次):"
        echo "     bao operator unseal <unseal_key>"
        echo ""
        echo "  5. 登录并使用:"
        echo "     bao login"
        echo ""
        echo -e "  ${BLUE}如需 HA 模式, 重新运行脚本并设置:${NC}"
        echo "     DEPLOY_MODE=ha NODE_ID=node1 RAFT_PEERS=... ./deploy-openbao.sh"
        echo ""
    fi

    echo "============================================================"
}

# ========================== 卸载功能 ==========================================
reconfigure() {
    local config_file="${CONFIG_DIR}/openbao.hcl"

    if [[ ! -f "$config_file" ]]; then
        die "配置文件不存在: ${config_file}。请先运行安装。"
    fi

    log_step "重新配置 OpenBao (TLS: ${ENABLE_TLS})..."

    local protocol="http"
    [[ "$ENABLE_TLS" == "true" ]] && protocol="https"

    # 根据当前模式重新生成配置
    if [[ "$DEPLOY_MODE" == "ha" ]]; then
        generate_ha_config "$config_file"
    else
        generate_standalone_config "$config_file"
    fi

    chown "${BAO_USER}:${BAO_GROUP}" "$config_file"
    chmod 0640 "$config_file"

    # 更新环境变量文件
    generate_env_file

    log_info "配置已更新: ${config_file}"
    echo ""
    echo "  变更内容:"
    echo "    TLS:    $([ "$ENABLE_TLS" == "true" ] && echo '已启用' || echo '已禁用')"
    echo "    协议:   ${protocol}"
    echo "    UI:     ${ENABLE_UI}"
    echo ""

    if confirm "立即重启 OpenBao 服务?"; then
        systemctl restart openbao.service
        if systemctl is-active --quiet openbao.service; then
            log_info "服务已重启并运行正常"
        else
            log_error "服务重启失败，请检查: journalctl -u openbao -n 20 --no-pager"
        fi
    else
        log_warn "配置已保存，请稍后手动执行: systemctl restart openbao"
    fi
    exit 0
}

# ========================== GPG 密钥分发初始化 ==============================
gpg_init() {
    local key_shares="${KEY_SHARES:-5}"
    local key_threshold="${KEY_THRESHOLD:-3}"
    local pgp_keys="${PGP_KEYS:-}"
    local root_token_pgp="${ROOT_TOKEN_PGP:-}"
    local output_dir="${GPG_OUTPUT_DIR:-/tmp/openbao-init}"

    log_step "GPG 密钥分发初始化"
    echo ""
    echo "  Key Shares:    ${key_shares}"
    echo "  Key Threshold: ${key_threshold}"
    echo ""

    # 检查 bao 命令可用
    if ! command -v bao &>/dev/null; then
        die "bao 命令未找到，请确认已安装并设置 PATH"
    fi

    # 检查 gpg 命令可用
    if ! command -v gpg &>/dev/null; then
        die "gpg 命令未找到，请先安装 GnuPG: apt install gnupg"
    fi

    # 如果未提供 PGP keys，引导用户生成
    if [[ -z "$pgp_keys" ]]; then
        echo -e "${YELLOW}未指定 --pgp-keys，将进入交互式 GPG 密钥生成模式${NC}"
        echo ""
        echo "需要为 ${key_shares} 个持有人分别生成 GPG 密钥对"
        echo ""

        if confirm "立即为 ${key_shares} 个用户生成 GPG 密钥?"; then
            mkdir -p "$output_dir"
            local key_files=()

            for i in $(seq 1 "$key_shares"); do
                local key_name
                echo -en "  第 ${i}/${key_shares} 个持有人姓名: "
                read -r key_name
                [[ -z "$key_name" ]] && key_name="holder${i}"

                local key_file="${output_dir}/${key_name}.asc"
                log_info "为 ${key_name} 生成 GPG 密钥..."

                # 生成密钥 (batch 模式，无需交互)
                gpg --batch --gen-key <<GPGEOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${key_name}
Name-Email: ${key_name}@openbao.local
Expire-Date: 0
%commit
GPGEOF

                # 导出公钥
                gpg --export "${key_name}" | base64 > "$key_file"
                key_files+=("$key_file")
                log_info "公钥已导出: ${key_file}"
            done

            pgp_keys="$(IFS=','; echo "${key_files[*]}")"
            log_info "所有 GPG 公钥已生成"
        else
            echo ""
            echo "请手动准备 GPG 公钥文件，然后重新运行:"
            echo "  ./deploy-openbao.sh init --pgp-keys user1.asc,user2.asc,user3.asc"
            echo ""
            echo "生成公钥的方法:"
            echo "  gpg --gen-key                              # 生成密钥对"
            echo "  gpg --export '用户名' | base64 > user.asc  # 导出公钥"
            exit 0
        fi
    fi

    # 构造 init 命令
    local init_cmd="bao operator init"
    init_cmd+=" -key-shares=${key_shares}"
    init_cmd+=" -key-threshold=${key_threshold}"
    init_cmd+=" -pgp-keys=\"${pgp_keys}\""

    if [[ -n "$root_token_pgp" ]]; then
        init_cmd+=" -root-token-pgp-key=\"${root_token_pgp}\""
    fi

    echo ""
    log_step "执行初始化命令:"
    echo "  ${init_cmd}"
    echo ""

    if ! confirm "确认执行?"; then
        log_info "取消"
        exit 0
    fi

    # 执行初始化并保存输出
    local init_output
    mkdir -p "$output_dir"
    init_output="$(eval $init_cmd 2>&1)" || {
        log_error "初始化失败:"
        echo "$init_output"
        exit 1
    }

    # 保存完整输出到文件
    echo "$init_output" > "${output_dir}/init-output.txt"
    log_info "初始化输出已保存: ${output_dir}/init-output.txt"
    echo ""
    echo "$init_output"
    echo ""

    echo "============================================================"
    echo -e "${GREEN}  初始化完成！${NC}"
    echo "============================================================"
    echo ""
    echo -e "${YELLOW}  密钥分发说明:${NC}"
    echo ""
    echo "  每个持有人收到自己的加密 Unseal Key 后，执行以下命令解密:"
    echo ""
    echo "    echo \"<加密的key>\" | base64 --decode | gpg -dq"
    echo ""
    echo "  解密后得到明文 Unseal Key，用于解封:"
    echo ""
    echo "    bao operator unseal <解密后的明文key>"
    echo ""
    if [[ -n "$root_token_pgp" ]]; then
        echo "  Root Token 解密:"
        echo "    echo \"<加密的root_token>\" | base64 --decode | gpg -dq"
        echo ""
    fi
    echo "  需要 ${key_threshold}/${key_shares} 个持有人同时解封才能解锁 OpenBao"
    echo ""
    echo -e "${RED}  重要: 请妥善保存 ${output_dir}/init-output.txt，包含所有加密密钥！${NC}"
    echo ""
    echo "============================================================"
}

uninstall() {
    log_step "卸载 OpenBao..."
    if confirm "确认卸载 OpenBao？将删除二进制、服务配置和数据目录"; then
        systemctl stop openbao.service 2>/dev/null || true
        systemctl disable openbao.service 2>/dev/null || true
        rm -f /etc/systemd/system/openbao.service
        systemctl daemon-reload
        rm -f "${INSTALL_DIR}/bao"
        rm -rf "$CONFIG_DIR" "$DATA_DIR" "$TLS_DIR" "$LOG_DIR" "/opt/openbao"
        userdel "$BAO_USER" 2>/dev/null || true
        groupdel "$BAO_GROUP" 2>/dev/null || true
        log_info "OpenBao 已卸载"
    else
        log_info "取消卸载"
    fi
    exit 0
}

# ========================== 使用帮助 ==========================================
usage() {
    cat <<'EOF'
OpenBao 一键部署脚本

用法:
  ./deploy-openbao.sh [选项]             # 部署
  ./deploy-openbao.sh init [选项]        # GPG 密钥分发初始化
  ./deploy-openbao.sh --reconfigure      # 重新配置
  ./deploy-openbao.sh --uninstall        # 卸载

部署选项:
  --mode standalone|ha     部署模式: standalone (默认) 或 ha (高可用)
  --version VERSION        指定 OpenBao 版本 (默认: 2.6.1)
  --node-id ID             HA 模式下的节点 ID (默认: node1)
  --api-addr URL           API 外部访问地址 (自动推断)
  --cluster-addr URL       集群内部通信地址 (自动推断)
  --listen-addr ADDR       监听地址 (默认: 0.0.0.0:8200)
  --raft-peers ADDRS       Raft 对等节点, 逗号分隔 (HA 模式)
  --local-binary PATH      使用本地二进制文件或 tar 包安装 (离线安装)
  --no-tls                 禁用 TLS (默认，配合前端 ELB/反代使用)
  --tls                    启用 TLS (生成自签名证书，生产环境请替换为正式证书)
  --no-ui                  禁用 Web UI
  --force                  跳过交互确认
  --uninstall              卸载 OpenBao
  --reconfigure            重新生成配置并重启服务 (不重新安装)
  -h, --help               显示此帮助

GPG 初始化选项 (与 init 子命令配合使用):
  --key-shares N           Unseal Key 分片数 (默认: 5)
  --key-threshold N        解封所需最小分片数 (默认: 3)
  --pgp-keys FILES         GPG 公钥文件路径, 逗号分隔 (例: a.asc,b.asc,c.asc)
  --root-token-pgp FILE    用 GPG 公钥加密 Root Token
  --gpg-output-dir DIR     GPG 密钥和输出保存目录 (默认: /tmp/openbao-init)

环境变量:
  OPENBAO_VERSION    版本号       (默认: 2.6.1)
  INSTALL_DIR        安装目录     (默认: /usr/local/bin)
  CONFIG_DIR         配置目录     (默认: /etc/openbao)
  DATA_DIR           数据目录     (默认: /opt/openbao/data)
  DEPLOY_MODE        部署模式     (standalone|ha)
  NODE_ID            节点 ID
  API_ADDR           API 地址
  CLUSTER_ADDR       集群地址
  RAFT_PEERS         Raft 对等节点 (逗号分隔)
  ENABLE_TLS         启用 TLS     (true|false)
  ENABLE_UI          启用 UI      (true|false)

示例:
  # 单机部署 (默认)
  sudo ./deploy-openbao.sh

  # 指定版本, 禁用 TLS (开发环境)
  sudo ./deploy-openbao.sh --version 2.6.1 --no-tls

  # HA 集群部署 - 节点 1 (Leader)
  sudo ./deploy-openbao.sh --mode ha \
    --node-id node1 \
    --api-addr https://node1.example.com:8200 \
    --cluster-addr https://node1.example.com:8201

  # HA 集群部署 - 节点 2 (Follower)
  sudo ./deploy-openbao.sh --mode ha \
    --node-id node2 \
    --api-addr https://node2.example.com:8200 \
    --cluster-addr https://node2.example.com:8201 \
    --raft-peers "https://node1.example.com:8200"

  # HA 集群部署 - 节点 3
  sudo ./deploy-openbao.sh --mode ha \
    --node-id node3 \
    --api-addr https://node3.example.com:8200 \
    --cluster-addr https://node3.example.com:8201 \
    --raft-peers "https://node1.example.com:8200,https://node2.example.com:8200"

  # 离线安装 (使用本地 tar 包, 无需外网)
  sudo ./deploy-openbao.sh --local-binary ./openbao_2.6.1_linux_amd64.tar.gz

  # 离线安装 (使用本地二进制文件)
  sudo ./deploy-openbao.sh --local-binary ./bao

  # 离线 + HA 模式
  sudo ./deploy-openbao.sh --mode ha --local-binary ./openbao_2.6.1_linux_amd64.tar.gz \
    --node-id node1 --api-addr https://node1.example.com:8200

  # 卸载
  sudo ./deploy-openbao.sh --uninstall

  # 重新配置: 切换为非 TLS 模式 (无需重装)
  sudo ./deploy-openbao.sh --reconfigure --no-tls

  # 重新配置: 切换回 TLS 模式
  sudo ./deploy-openbao.sh --reconfigure

  # GPG 密钥分发初始化 (指定公钥文件)
  ./deploy-openbao.sh init --key-shares=3 --key-threshold=2 \
    --pgp-keys /path/to/alice.asc,/path/to/bob.asc,/path/to/carol.asc \
    --root-token-pgp /path/to/admin.asc

  # GPG 交互式生成密钥并初始化
  ./deploy-openbao.sh init --key-shares=5 --key-threshold=3

  # 持有人解密自己的 Unseal Key
  echo "<加密的key>" | base64 --decode | gpg -dq
EOF
    exit 0
}

# ========================== 参数解析 ==========================================
parse_args() {
    # 处理子命令
    if [[ "${1:-}" == "init" ]]; then
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --key-shares)      KEY_SHARES="$2"; shift 2 ;;
                --key-threshold)   KEY_THRESHOLD="$2"; shift 2 ;;
                --pgp-keys)        PGP_KEYS="$2"; shift 2 ;;
                --root-token-pgp)  ROOT_TOKEN_PGP="$2"; shift 2 ;;
                --gpg-output-dir)  GPG_OUTPUT_DIR="$2"; shift 2 ;;
                --force)           FORCE="true"; shift ;;
                -h|--help)         usage ;;
                *)                 die "init 未知选项: $1\n使用 --help 查看帮助" ;;
            esac
        done
        gpg_init
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                DEPLOY_MODE="$2"
                [[ "$DEPLOY_MODE" == "standalone" || "$DEPLOY_MODE" == "ha" ]] \
                    || die "--mode 必须为 standalone 或 ha"
                shift 2 ;;
            --version)
                OPENBAO_VERSION="$2"; shift 2 ;;
            --node-id)
                NODE_ID="$2"; shift 2 ;;
            --api-addr)
                API_ADDR="$2"; shift 2 ;;
            --cluster-addr)
                CLUSTER_ADDR="$2"; shift 2 ;;
            --listen-addr)
                LISTEN_ADDR="$2"; shift 2 ;;
            --raft-peers)
                RAFT_PEERS="$2"; shift 2 ;;
            --local-binary)
                LOCAL_BINARY="$2"; shift 2 ;;
            --no-tls)
                ENABLE_TLS="false"; shift ;;
            --tls)
                ENABLE_TLS="true"; shift ;;
            --no-ui)
                ENABLE_UI="false"; shift ;;
            --force)
                FORCE="true"; shift ;;
            --uninstall)
                check_dependencies
                uninstall ;;
            --reconfigure)
                [[ $EUID -eq 0 ]] || die "此操作需要 root 权限，请使用 sudo"
                reconfigure ;;
            -h|--help)
                usage ;;
            *)
                die "未知选项: $1\n使用 --help 查看帮助" ;;
        esac
    done
}

# ========================== 主流程 ============================================
main() {
    parse_args "$@"

    echo ""
    echo "============================================================"
    echo "        OpenBao 一键部署脚本 v${OPENBAO_VERSION}"
    echo "============================================================"
    echo "  部署模式:  $([ "$DEPLOY_MODE" == "ha" ] && echo '高可用 (HA)' || echo '单机 (Standalone)')"
    echo "  安装来源:  $([ -n "$LOCAL_BINARY" ] && echo "离线 (${LOCAL_BINARY})" || echo '在线 (GitHub Releases)')"
    echo "  TLS:       ${ENABLE_TLS}"
    echo "  Web UI:    ${ENABLE_UI}"
    echo ""

    if [[ $EUID -ne 0 ]]; then
        die "此脚本需要 root 权限运行，请使用 sudo"
    fi

    check_dependencies
    detect_arch

    if ! confirm "确认安装 OpenBao v${OPENBAO_VERSION} (${DEPLOY_MODE} 模式)?"; then
        log_info "取消安装"
        exit 0
    fi

    if [[ -n "$LOCAL_BINARY" ]]; then
        install_local_openbao
    else
        download_openbao
    fi
    setup_user_and_dirs
    generate_tls
    generate_config
    generate_env_file
    install_systemd_service
    pre_start_checks

    if start_and_verify; then
        post_install_instructions
    else
        log_warn "服务启动可能存在问题，请查看日志排查"
        post_install_instructions
    fi
}

main "$@"
