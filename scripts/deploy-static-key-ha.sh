#!/usr/bin/env bash
# ==============================================================================
# OpenBao Static Key 自动解封 HA 集群一键部署脚本
#
# 功能:
#   - 自动生成 32 字节 AES-256-GCM 共享密钥
#   - 通过 SSH 将密钥分发到所有节点
#   - 在每个节点上安装 OpenBao + 配置 Static Key Seal + Raft 存储
#   - 自动初始化集群、加入 Raft、验证健康状态
#   - 支持 sudo 提权 (需输入密码)
#
# 用法:
#   ./deploy-static-key-ha.sh [选项]
#
# 示例:
#   # 三节点远程部署 (SSH root)
#   ./deploy-static-key-ha.sh \
#     --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user root
#
#   # 使用 sudo 提权 (非 root SSH 用户)
#   ./deploy-static-key-ha.sh \
#     --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user ubuntu --sudo
#
#   # 本地单机测试
#   sudo ./deploy-static-key-ha.sh --local --node-id node1
# ==============================================================================

set -euo pipefail

# ========================== 默认配置 ==========================================
OPENBAO_VERSION="${OPENBAO_VERSION:-2.6.1}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/openbao"
DATA_DIR="/msun/openbao/data"
RAFT_DIR="/msun/openbao/raft"
SEAL_DIR="/msun/openbao/secrets"
TLS_DIR="/msun/openbao/tls"
LOG_DIR="/msun/openbao/logs"
BAO_USER="openbao"
BAO_GROUP="openbao"

NODES=""
SSH_USER="root"
SSH_PORT="22"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
USE_SUDO="false"
SUDO_PASSWORD=""
NODE_PREFIX="node"
API_PORT="8200"
CLUSTER_PORT="8201"
ENABLE_TLS="false"
ENABLE_UI="true"
LOCAL_BINARY=""
FORCE="false"
LOCAL_MODE="false"
LOCAL_NODE_ID="node1"
KEY_SHARES=3
KEY_THRESHOLD=2
SKIP_INIT="false"
CLEANUP="false"

GITHUB_BASE_URL="https://github.com/openbao/openbao/releases/download"

# ========================== 颜色与日志 ========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_node()  { echo -e "${CYAN}[NODE $1]${NC} $*"; }
die()       { log_error "$@"; exit 1; }

confirm() {
    local msg="${1:-继续?}"
    [[ "${FORCE}" == "true" ]] && return 0
    echo -en "${YELLOW}${msg} [y/N]: ${NC}"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# ========================== Sudo 支持 =========================================
setup_sudo() {
    [[ "${USE_SUDO}" != "true" ]] && return 0
    if [[ "${SSH_USER}" == "root" ]]; then
        USE_SUDO="false"
        log_info "SSH 用户为 root，无需 sudo 提权"
        return 0
    fi

    log_step "配置 sudo 提权..."
    echo -e "${YELLOW}  SSH 用户 '${SSH_USER}' 非 root，需要 sudo 密码${NC}"
    echo -en "  请输入 ${SSH_USER}@远程节点 的 sudo 密码: "
    read -rs SUDO_PASSWORD
    echo ""
    [[ -z "${SUDO_PASSWORD}" ]] && die "sudo 密码不能为空"

    # 验证 sudo 密码
    local first_node
    first_node="$(echo "${NODES}" | cut -d',' -f1)"
    log_info "验证 sudo 密码 (节点: ${first_node})..."
    local test_cmd
    test_cmd="echo 'SUDO_OK' 2>/dev/null"
    local result
    result="$(run_remote "${first_node}" "${test_cmd}" | tail -1)" || true
    if [[ "${result}" != *"SUDO_OK"* ]]; then
        die "sudo 密码验证失败"
    fi
    log_info "sudo 密码验证通过"
}

# ========================== 远程命令执行 (Base64 编码) ========================
# 核心: 所有远程命令通过 base64 编码传输，彻底避免引号嵌套问题
run_remote() {
    local node="$1"
    local script="$2"
    local cmd_b64
    cmd_b64="$(printf '%s' "${script}" | base64 -w0)"

    if [[ "${USE_SUDO}" == "true" ]]; then
        # 双重 base64: 密码和命令都编码，避免任何特殊字符问题
        local pass_b64
        pass_b64="$(printf '%s' "${SUDO_PASSWORD}" | base64 -w0)"
        local sudo_script
        sudo_script="echo \"${pass_b64}\" | base64 -d | sudo -S bash -c \"\$(echo '${cmd_b64}' | base64 -d)\" 2>/dev/null"
        local sudo_encoded
        sudo_encoded="$(printf '%s' "${sudo_script}" | base64 -w0)"
        ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${node}" \
            "echo '${sudo_encoded}' | base64 -d | bash" 2>/dev/null
    else
        ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${node}" \
            "echo '${cmd_b64}' | base64 -d | bash" 2>/dev/null
    fi
}

# 将本地文件内容写入远程文件 (通过 base64 传输)
put_remote_file() {
    local node="$1"
    local remote_path="$2"
    local local_content="$3"
    local encoded
    encoded="$(printf '%s' "${local_content}" | base64 -w0)"

    run_remote "${node}" "echo '${encoded}' | base64 -d > '${remote_path}'"
}

# ========================== 本地执行 ==========================================
run_local() {
    if [[ $EUID -ne 0 ]]; then
        if [[ -n "${SUDO_PASSWORD}" ]]; then
            echo "${SUDO_PASSWORD}" | sudo -S bash -c "$1" 2>/dev/null
        else
            sudo bash -c "$1"
        fi
    else
        bash -c "$1"
    fi
}

# ========================== 依赖检查 ==========================================
check_local_deps() {
    log_step "检查本地依赖..."
    local missing=()
    if [[ "${LOCAL_MODE}" == "false" ]]; then
        command -v ssh &>/dev/null || missing+=(ssh)
        command -v scp &>/dev/null || missing+=(scp)
    fi
    command -v openssl &>/dev/null || missing+=(openssl)
    command -v base64  &>/dev/null || missing+=(base64)
    [[ ${#missing[@]} -gt 0 ]] && die "缺少本地依赖: ${missing[*]}"
    log_info "本地依赖检查通过"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
    log_info "检测到架构: ${ARCH}"
}

# ========================== 生成共享密钥 ======================================
generate_seal_key() {
    log_step "生成 Static Key 共享密钥 (32 字节 AES-256-GCM)..."
    SEAL_KEY_DIR="$(mktemp -d)"
    SEAL_KEY_FILE="${SEAL_KEY_DIR}/unseal.key"
    SEAL_KEY_ID="key-$(date +%Y%m%d)-1"
    openssl rand -out "${SEAL_KEY_FILE}" 32
    local key_size
    key_size="$(wc -c < "${SEAL_KEY_FILE}")"
    [[ "${key_size}" -ne 32 ]] && die "密钥大小错误: ${key_size} (需要 32)"
    log_info "共享密钥已生成 (${key_size} bytes), ID: ${SEAL_KEY_ID}"
}

# ========================== 分发密钥 ==========================================
distribute_key_remote() {
    log_step "分发共享密钥到所有节点..."
    IFS=',' read -ra NODE_LIST <<< "${NODES}"
    for i in "${!NODE_LIST[@]}"; do
        local node="${NODE_LIST[$i]}"
        local n=$((i + 1))
        log_node "${n}" "分发密钥到 ${node}..."

        run_remote "${node}" "mkdir -p ${SEAL_DIR}"

        # SCP 传输密钥文件
        scp ${SSH_OPTS} -P "${SSH_PORT}" "${SEAL_KEY_FILE}" \
            "${SSH_USER}@${node}:/tmp/unseal.key" 2>/dev/null

        run_remote "${node}" "
            mv /tmp/unseal.key ${SEAL_DIR}/unseal.key
            chown ${BAO_USER}:${BAO_GROUP} ${SEAL_DIR}/unseal.key 2>/dev/null || true
            chmod 400 ${SEAL_DIR}/unseal.key
        "
        log_node "${n}" "密钥已分发 (权限 400)"
    done
}

distribute_key_local() {
    log_step "本地部署密钥..."
    run_local "
        mkdir -p ${SEAL_DIR}
        cp '${SEAL_KEY_FILE}' ${SEAL_DIR}/unseal.key
        chown ${BAO_USER}:${BAO_GROUP} ${SEAL_DIR}/unseal.key 2>/dev/null || true
        chmod 400 ${SEAL_DIR}/unseal.key
    "
    log_info "密钥已部署到 ${SEAL_DIR}/unseal.key"
}

# ========================== 安装 OpenBao =====================================
install_openbao_remote() {
    local node="$1"
    local n="$2"

    if [[ -n "${LOCAL_BINARY}" ]]; then
        log_node "${n}" "上传本地二进制文件..."
        scp ${SSH_OPTS} -P "${SSH_PORT}" "${LOCAL_BINARY}" \
            "${SSH_USER}@${node}:/tmp/openbao-install" 2>/dev/null
        run_remote "${node}" "
            cd /tmp
            if file /tmp/openbao-install | grep -q gzip; then
                tar -xzf /tmp/openbao-install
            fi
            if [ -f /tmp/bao ]; then
                install -m 0755 /tmp/bao ${INSTALL_DIR}/bao
            elif [ -f /tmp/openbao ]; then
                install -m 0755 /tmp/openbao ${INSTALL_DIR}/bao
            fi
            rm -f /tmp/openbao-install /tmp/bao /tmp/openbao
            ${INSTALL_DIR}/bao version
        "
    else
        log_node "${n}" "下载 OpenBao v${OPENBAO_VERSION}..."
        local filename="openbao_${OPENBAO_VERSION}_linux_${ARCH}.tar.gz"
        local url="${GITHUB_BASE_URL}/v${OPENBAO_VERSION}/${filename}"
        run_remote "${node}" "
            cd /tmp
            curl -sL -o ${filename} '${url}'
            tar -xzf ${filename}
            install -m 0755 bao ${INSTALL_DIR}/bao
            rm -f /tmp/${filename} /tmp/bao
            ${INSTALL_DIR}/bao version
        "
    fi
    log_node "${n}" "OpenBao 已安装"
}

install_openbao_local() {
    log_step "安装 OpenBao..."
    if [[ -n "${LOCAL_BINARY}" ]]; then
        run_local "
            cd /tmp
            if file '${LOCAL_BINARY}' | grep -q gzip; then
                tar -xzf '${LOCAL_BINARY}'
            fi
            if [ -f /tmp/bao ]; then
                install -m 0755 /tmp/bao ${INSTALL_DIR}/bao
            else
                install -m 0755 '${LOCAL_BINARY}' ${INSTALL_DIR}/bao
            fi
        "
    else
        local filename="openbao_${OPENBAO_VERSION}_linux_${ARCH}.tar.gz"
        local url="${GITHUB_BASE_URL}/v${OPENBAO_VERSION}/${filename}"
        run_local "
            cd /tmp
            curl -sL -o ${filename} '${url}'
            tar -xzf ${filename}
            install -m 0755 bao ${INSTALL_DIR}/bao
            rm -f /tmp/${filename} /tmp/bao
        "
    fi
    log_info "OpenBao 已安装到 ${INSTALL_DIR}/bao"
}

# ========================== 创建用户与目录 ====================================
setup_system_remote() {
    local node="$1"
    local n="$2"
    log_node "${n}" "创建系统用户与目录..."
    run_remote "${node}" "
        getent group ${BAO_GROUP} >/dev/null 2>&1 || groupadd --system ${BAO_GROUP}
        getent passwd ${BAO_USER} >/dev/null 2>&1 || useradd --system --gid ${BAO_GROUP} --no-create-home --shell /usr/sbin/nologin ${BAO_USER}
        for dir in ${CONFIG_DIR} ${DATA_DIR} ${RAFT_DIR} ${SEAL_DIR} ${TLS_DIR} ${LOG_DIR}; do
            install -d -m 0750 -o ${BAO_USER} -g ${BAO_GROUP} \"\${dir}\"
        done
    "
    log_node "${n}" "用户与目录就绪"
}

setup_system_local() {
    log_step "创建系统用户与目录..."
    run_local "
        getent group ${BAO_GROUP} >/dev/null 2>&1 || groupadd --system ${BAO_GROUP}
        getent passwd ${BAO_USER} >/dev/null 2>&1 || useradd --system --gid ${BAO_GROUP} --no-create-home --shell /usr/sbin/nologin ${BAO_USER}
        for dir in ${CONFIG_DIR} ${DATA_DIR} ${RAFT_DIR} ${SEAL_DIR} ${TLS_DIR} ${LOG_DIR}; do
            install -d -m 0750 -o ${BAO_USER} -g ${BAO_GROUP} \"\${dir}\"
        done
    "
}

# ========================== 生成配置文件 ======================================
build_config() {
    local node_ip="$1"
    local node_id="$2"
    local all_nodes_csv="$3"
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"

    # retry_join: 排除自己
    local retry_join=""
    IFS=',' read -ra ALL <<< "${all_nodes_csv}"
    for peer in "${ALL[@]}"; do
        peer="$(echo "${peer}" | xargs)"
        [[ "${peer}" == "${node_ip}" ]] && continue
        retry_join+="
  retry_join {
    leader_api_addr = \"${protocol}://${peer}:${API_PORT}\"
  }"
    done

    local tls_block
    if [[ "${ENABLE_TLS}" == "true" ]]; then
        tls_block="  tls_cert_file   = \"${TLS_DIR}/tls.crt\"
  tls_key_file    = \"${TLS_DIR}/tls.key\""
    else
        tls_block="  tls_disable     = 1"
    fi

    cat <<HCL
# ============================================================================
# OpenBao HA — Static Key Auto-Unseal + Raft
# Node: ${node_id} (${node_ip})
# ============================================================================

ui = ${ENABLE_UI}

# -- Static Key 自动解封 --
seal "static" {
  current_key_id = "${SEAL_KEY_ID}"
  current_key    = "file://${SEAL_DIR}/unseal.key"
}

# -- Raft 存储 (HA) --
storage "raft" {
  path    = "${RAFT_DIR}"
  node_id = "${node_id}"

  performance_multiplier = 1
  trailing_logs          = 10000
  snapshot_threshold     = 8192
  snapshot_interval      = "120s"
  max_entry_size         = 1048576
${retry_join}

  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "10s"
    max_trailing_logs         = 250
    min_quorum                = 2
    server_stabilization_time = "10s"
  }
}

# -- 监听器 --
listener "tcp" {
  address         = "0.0.0.0:${API_PORT}"
  cluster_address = "0.0.0.0:${CLUSTER_PORT}"
${tls_block}
}

api_addr     = "${protocol}://${node_ip}:${API_PORT}"
cluster_addr = "${protocol}://${node_ip}:${CLUSTER_PORT}"

telemetry {
  disable_hostname          = true
  prometheus_retention_time = "30s"
}
HCL
}

# ========================== Systemd 服务单元 =================================
build_systemd_unit() {
    cat <<'UNIT_EOF'
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
UNIT_EOF
}

# ========================== 部署配置 + 服务 ===================================
deploy_config_and_service_remote() {
    local node="$1"
    local node_id="$2"
    local n="$3"

    log_node "${n}" "部署配置文件 + systemd 服务..."

    # 生成配置内容
    local config_content
    config_content="$(build_config "${node}" "${node_id}" "${NODES}")"

    local env_content
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"
    env_content="BAO_ADDR=\"${protocol}://127.0.0.1:${API_PORT}\"
BAO_SKIP_VERIFY=true"

    local unit_content
    unit_content="$(build_systemd_unit)"

    # 通过 base64 写入远程文件
    put_remote_file "${node}" "${CONFIG_DIR}/openbao.hcl" "${config_content}"
    put_remote_file "${node}" "${CONFIG_DIR}/openbao.env" "${env_content}"
    put_remote_file "${node}" "/etc/systemd/system/openbao.service" "${unit_content}"

    # 设置权限 + 启用服务
    run_remote "${node}" "
        chown ${BAO_USER}:${BAO_GROUP} ${CONFIG_DIR}/openbao.hcl
        chmod 0640 ${CONFIG_DIR}/openbao.hcl
        chown ${BAO_USER}:${BAO_GROUP} ${CONFIG_DIR}/openbao.env
        chmod 0640 ${CONFIG_DIR}/openbao.env
        systemctl daemon-reload
        systemctl enable openbao.service
    "

    log_node "${n}" "配置 + 服务已部署"
}

deploy_config_and_service_local() {
    log_step "本地: 部署配置 + systemd 服务..."

    local node_ip
    node_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')"

    local config_content
    config_content="$(build_config "${node_ip}" "${LOCAL_NODE_ID}" "${node_ip}")"

    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"
    local env_content="BAO_ADDR=\"${protocol}://127.0.0.1:${API_PORT}\"
BAO_SKIP_VERIFY=true"

    local unit_content
    unit_content="$(build_systemd_unit)"

    run_local "
        cat > ${CONFIG_DIR}/openbao.hcl << 'XEOF'
${config_content}
XEOF
        cat > ${CONFIG_DIR}/openbao.env << 'XEOF'
${env_content}
XEOF
        cat > /etc/systemd/system/openbao.service << 'XEOF'
${unit_content}
XEOF
        chown ${BAO_USER}:${BAO_GROUP} ${CONFIG_DIR}/openbao.hcl
        chmod 0640 ${CONFIG_DIR}/openbao.hcl
        chown ${BAO_USER}:${BAO_GROUP} ${CONFIG_DIR}/openbao.env
        chmod 0640 ${CONFIG_DIR}/openbao.env
        systemctl daemon-reload
        systemctl enable openbao.service
    "
    log_info "本地配置 + 服务已部署"
}

# ========================== 启动服务 ==========================================
start_service() {
    local node="$1"
    local n="$2"
    local is_local="${3:-false}"
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"

    if [[ "${is_local}" == "true" ]]; then
        log_step "本地: 启动服务..."
        run_local "systemctl restart openbao.service"
    else
        log_node "${n}" "启动服务..."
        run_remote "${node}" "systemctl restart openbao.service" || {
            log_warn "Node ${n}: systemctl restart 返回非零，服务可能未启动，继续等待检查..."
        }
    fi

    local max_wait=30 waited=0
    while [[ $waited -lt $max_wait ]]; do
        local health=""
        if [[ "${is_local}" == "true" ]]; then
            health="$(curl -sk "${protocol}://127.0.0.1:${API_PORT}/v1/sys/health" 2>/dev/null || echo "")"
        else
            health="$(ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${node}" \
                "curl -sk '${protocol}://127.0.0.1:${API_PORT}/v1/sys/health' 2>/dev/null" 2>/dev/null || echo "")"
        fi
        if [[ "${health}" == *"initialized"* || "${health}" == *"sealed"* ]]; then
            if [[ "${is_local}" == "true" ]]; then
                log_info "本地服务已启动"
            else
                log_node "${n}" "服务已启动"
            fi
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_warn "等待超时 (${max_wait}s)"
    return 1
}

# ========================== 健康检查 ==========================================
check_health() {
    local node="$1"
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"
    ssh ${SSH_OPTS} -p "${SSH_PORT}" "${SSH_USER}@${node}" \
        "curl -sk '${protocol}://127.0.0.1:${API_PORT}/v1/sys/health' 2>/dev/null" 2>/dev/null || echo '{}'
}

# ========================== 初始化集群 ========================================
init_cluster() {
    local leader="$1"
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"

    log_step "初始化集群 (Leader: ${leader})..."

    # 检查是否已初始化
    local health
    health="$(check_health "${leader}")"
    if echo "${health}" | grep -q '"initialized":\s*true'; then
        log_info "集群已初始化，跳过"
        return 0
    fi

    local init_result
    init_result="$(run_remote "${leader}" "
        export BAO_ADDR='${protocol}://127.0.0.1:${API_PORT}'
        export BAO_SKIP_VERIFY=true
        ${INSTALL_DIR}/bao operator init -key-shares=${KEY_SHARES} -key-threshold=${KEY_THRESHOLD} -format=json
    ")"

    [[ -z "${init_result}" ]] && die "集群初始化失败"

    # 保存结果
    local output_dir="/tmp/openbao-init-$(date +%Y%m%d%H%M%S)"
    mkdir -p "${output_dir}"
    echo "${init_result}" > "${output_dir}/init-result.json"
    chmod 700 "${output_dir}"

    # 解析
    if command -v python3 &>/dev/null; then
        echo "${init_result}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = d.get('keys', d.get('recovery_keys', []))
for k in keys: print(k)
" > "${output_dir}/recovery-keys.txt" 2>/dev/null || true
        echo "${init_result}" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('root_token', ''))
" > "${output_dir}/root-token.txt" 2>/dev/null || true
    elif command -v jq &>/dev/null; then
        echo "${init_result}" | jq -r '.keys[]?, .recovery_keys[]?' > "${output_dir}/recovery-keys.txt" 2>/dev/null || true
        echo "${init_result}" | jq -r '.root_token // ""' > "${output_dir}/root-token.txt" 2>/dev/null || true
    else
        log_warn "未安装 python3/jq，请手动查看 ${output_dir}/init-result.json"
    fi

    chmod 600 "${output_dir}"/*.txt 2>/dev/null || true

    log_info "初始化完成！"
    echo ""
    echo -e "${RED}  重要: 请妥善保存以下文件:${NC}"
    echo "    ${output_dir}/init-result.json"
    echo "    ${output_dir}/recovery-keys.txt"
    echo "    ${output_dir}/root-token.txt"
    echo ""
}

# ========================== 加入 Raft =========================================
join_raft() {
    local leader="$1"
    local follower="$2"
    local n="$3"
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"

    log_node "${n}" "加入 Raft 集群..."

    local result
    result="$(run_remote "${follower}" "
        export BAO_ADDR='${protocol}://127.0.0.1:${API_PORT}'
        export BAO_SKIP_VERIFY=true
        ${INSTALL_DIR}/bao operator raft join '${protocol}://${leader}:${API_PORT}' 2>&1 || true
    ")"

    if echo "${result}" | grep -qi "joined.*true\|success"; then
        log_node "${n}" "已加入 Raft 集群"
    else
        log_node "${n}" "加入结果: ${result}"
    fi
}

# ========================== 验证集群 ==========================================
verify_cluster() {
    local leader="$1"
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"

    log_step "验证集群状态..."
    echo ""
    echo "============================================================"
    echo "  集群节点健康状态"
    echo "============================================================"

    IFS=',' read -ra NODE_LIST <<< "${NODES}"
    for i in "${!NODE_LIST[@]}"; do
        local node="${NODE_LIST[$i]}"
        local n=$((i + 1))
        local health
        health="$(check_health "${node}")"

        echo -e "  ${CYAN}Node ${n} (${node}):${NC}"
        if command -v python3 &>/dev/null; then
            echo "${health}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f'    Initialized={d.get(\"initialized\",\"?\")}, Sealed={d.get(\"sealed\",\"?\")}, HA={d.get(\"ha_enabled\",\"?\")}, Version={d.get(\"version\",\"?\")}')
except: print('    无法解析')
" 2>/dev/null || echo "    ${health}"
        else
            echo "    ${health}"
        fi
        echo ""
    done

    echo "============================================================"

    log_step "Raft 成员列表..."
    local peers
    peers="$(run_remote "${leader}" "
        export BAO_ADDR='${protocol}://127.0.0.1:${API_PORT}'
        export BAO_SKIP_VERIFY=true
        ${INSTALL_DIR}/bao operator raft list-peers 2>&1 || echo '(需要先登录)'
    ")"
    echo "${peers}"
    echo ""
}

# ========================== 清理模式 ==========================================
do_cleanup() {
    log_step "清理所有节点..."
    confirm "确认清理？将停止服务并删除数据" || { log_info "取消"; exit 0; }

    IFS=',' read -ra NODE_LIST <<< "${NODES}"
    for i in "${!NODE_LIST[@]}"; do
        local node="${NODE_LIST[$i]}"
        local n=$((i + 1))
        log_node "${n}" "清理 ${node}..."
        run_remote "${node}" "
            systemctl stop openbao.service 2>/dev/null || true
            systemctl disable openbao.service 2>/dev/null || true
            rm -f /etc/systemd/system/openbao.service
            systemctl daemon-reload
            rm -f ${INSTALL_DIR}/bao
            rm -rf ${CONFIG_DIR} ${DATA_DIR} ${RAFT_DIR} ${SEAL_DIR} ${TLS_DIR} ${LOG_DIR}
            userdel ${BAO_USER} 2>/dev/null || true
            groupdel ${BAO_GROUP} 2>/dev/null || true
        "
        log_node "${n}" "清理完成"
    done
    log_info "所有节点已清理"
    exit 0
}

# ========================== 使用帮助 ==========================================
usage() {
    cat <<'EOF'
OpenBao Static Key 自动解封 HA 集群一键部署脚本

用法:
  ./deploy-static-key-ha.sh [选项]

集群选项:
  --nodes ADDRS          节点 IP/主机名, 逗号分隔 (例: 10.0.1.11,10.0.1.12,10.0.1.13)
  --ssh-user USER        SSH 用户 (默认: root)
  --ssh-port PORT        SSH 端口 (默认: 22)
  --sudo                 使用 sudo 提权 (SSH 用户非 root 时需要, 会提示输入密码)
  --version VERSION      OpenBao 版本 (默认: 2.6.1)
  --node-prefix PREFIX   节点 ID 前缀 (默认: node → node1, node2, ...)
  --api-port PORT        API 端口 (默认: 8200)
  --cluster-port PORT    Cluster 端口 (默认: 8201)
  --key-shares N         Recovery Key 分片数 (默认: 3)
  --key-threshold N      Recovery Key 阈值 (默认: 2)
  --tls                  启用 TLS
  --no-ui                禁用 Web UI
  --local-binary PATH    本地二进制/tar 包 (离线安装)
  --skip-init            跳过初始化
  --force                跳过确认
  --cleanup              清理集群

本地模式:
  --local                本地单机部署
  --node-id ID           节点 ID (默认: node1)

  -h, --help             显示帮助

示例:
  # 三节点 (root SSH)
  ./deploy-static-key-ha.sh --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user root

  # 三节点 (普通用户 + sudo 密码)
  ./deploy-static-key-ha.sh --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user ubuntu --sudo

  # 离线 + sudo
  ./deploy-static-key-ha.sh --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user ops --sudo \
    --local-binary ./openbao_2.6.1_linux_amd64.tar.gz

  # 本地单机
  sudo ./deploy-static-key-ha.sh --local

  # 清理
  ./deploy-static-key-ha.sh --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user root --cleanup
EOF
    exit 0
}

# ========================== 参数解析 ==========================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nodes)        NODES="$2"; shift 2 ;;
            --ssh-user)     SSH_USER="$2"; shift 2 ;;
            --ssh-port)     SSH_PORT="$2"; shift 2 ;;
            --sudo)         USE_SUDO="true"; shift ;;
            --version)      OPENBAO_VERSION="$2"; shift 2 ;;
            --node-prefix)  NODE_PREFIX="$2"; shift 2 ;;
            --api-port)     API_PORT="$2"; shift 2 ;;
            --cluster-port) CLUSTER_PORT="$2"; shift 2 ;;
            --key-shares)   KEY_SHARES="$2"; shift 2 ;;
            --key-threshold) KEY_THRESHOLD="$2"; shift 2 ;;
            --tls)          ENABLE_TLS="true"; shift ;;
            --no-ui)        ENABLE_UI="false"; shift ;;
            --local-binary) LOCAL_BINARY="$2"; shift 2 ;;
            --skip-init)    SKIP_INIT="true"; shift ;;
            --force)        FORCE="true"; shift ;;
            --local)        LOCAL_MODE="true"; shift ;;
            --node-id)      LOCAL_NODE_ID="$2"; shift 2 ;;
            --cleanup)      CLEANUP="true"; shift ;;
            -h|--help)      usage ;;
            *)              die "未知选项: $1\n使用 --help 查看帮助" ;;
        esac
    done
}

# ========================== 远程部署主流程 ====================================
deploy_remote() {
    IFS=',' read -ra NODE_LIST <<< "${NODES}"
    local node_count="${#NODE_LIST[@]}"

    echo ""
    echo "============================================================"
    echo "    OpenBao Static Key HA 集群一键部署"
    echo "============================================================"
    echo "  版本:       v${OPENBAO_VERSION}"
    echo "  节点数:     ${node_count}"
    echo "  节点:       ${NODES}"
    echo "  SSH:        ${SSH_USER}@*:$(echo ${SSH_PORT})"
    echo "  Sudo:       ${USE_SUDO}"
    echo "  TLS:        ${ENABLE_TLS}"
    echo "  UI:         ${ENABLE_UI}"
    echo "  安装来源:   $([ -n "${LOCAL_BINARY}" ] && echo "离线" || echo "在线")"
    echo "  Key:        ${KEY_SHARES} shares / ${KEY_THRESHOLD} threshold"
    echo "============================================================"
    echo ""

    [[ ${node_count} -lt 1 ]] && die "至少需要 1 个节点"
    [[ ${node_count} -eq 2 ]] && log_warn "2 节点无法容忍故障, 建议 3 或 5 节点"

    confirm "确认部署 ${node_count} 节点 HA 集群?" || { log_info "取消"; exit 0; }
    [[ "${CLEANUP}" == "true" ]] && do_cleanup

    # 1. Sudo
    setup_sudo

    # 2. 架构
    detect_arch

    # 3. 共享密钥
    generate_seal_key

    # 4. 逐节点部署
    for i in "${!NODE_LIST[@]}"; do
        local node="${NODE_LIST[$i]}"
        local n=$((i + 1))
        local node_id="${NODE_PREFIX}${n}"

        echo ""
        log_step "========== Node ${n}: ${node} (${node_id}) =========="
        setup_system_remote "${node}" "${n}"
        install_openbao_remote "${node}" "${n}"
        deploy_config_and_service_remote "${node}" "${node_id}" "${n}"
    done

    # 5. 分发密钥
    distribute_key_remote

    # 6. 启动
    echo ""
    log_step "========== 启动所有节点 =========="
    for i in "${!NODE_LIST[@]}"; do
        start_service "${NODE_LIST[$i]}" "$((i + 1))" "false"
    done

    log_info "等待 Raft 选举 (10s)..."
    sleep 10

    # 7. 初始化
    local leader="${NODE_LIST[0]}"
    [[ "${SKIP_INIT}" != "true" ]] && init_cluster "${leader}"

    # 8. Join
    if [[ ${node_count} -gt 1 ]]; then
        log_step "========== Follower 加入 Raft =========="
        for i in "${!NODE_LIST[@]}"; do
            [[ $i -eq 0 ]] && continue
            join_raft "${leader}" "${NODE_LIST[$i]}" "$((i + 1))"
            sleep 3
        done
    fi

    # 9. 验证
    echo ""
    verify_cluster "${leader}"

    # 10. 清理临时
    rm -rf "${SEAL_KEY_DIR}"

    # 最终输出
    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}  OpenBao v${OPENBAO_VERSION} Static Key HA 集群部署完成！${NC}"
    echo "============================================================"
    echo ""
    echo "  集群节点:"
    for i in "${!NODE_LIST[@]}"; do
        local node="${NODE_LIST[$i]}"
        local n=$((i + 1))
        local role="$([ $i -eq 0 ] && echo '(Leader)' || echo '(Follower)')"
        echo "    ${NODE_PREFIX}${n}: ${protocol}://${node}:${API_PORT}  ${role}"
    done
    echo ""
    echo "  配置:    ${CONFIG_DIR}/openbao.hcl"
    echo "  Seal:    ${SEAL_DIR}/unseal.key (自动解封)"
    echo "  数据:    ${RAFT_DIR}"
    echo ""
    echo -e "${YELLOW}  使用:${NC}"
    echo "    export BAO_ADDR=${protocol}://${NODE_LIST[0]}:${API_PORT}"
    echo "    export BAO_SKIP_VERIFY=true"
    echo "    bao login          # 用 Root Token 登录"
    echo "    bao operator raft list-peers"
    echo "    bao status"
    echo ""
    echo -e "${RED}  安全提示:${NC}"
    echo "    Static Key = 密钥文件 + 数据 = 可解密全部数据"
    echo "    确保 ${SEAL_DIR}/unseal.key 权限 400, 生产环境建议 KMS/HSM"
    echo ""
    echo "============================================================"
}

# ========================== 本地部署流程 ======================================
deploy_local() {
    echo ""
    echo "============================================================"
    echo "    OpenBao Static Key 本地单机部署"
    echo "============================================================"
    echo "  版本:    v${OPENBAO_VERSION}"
    echo "  Node:    ${LOCAL_NODE_ID}"
    echo "  TLS:     ${ENABLE_TLS}"
    echo "  UI:      ${ENABLE_UI}"
    echo "============================================================"
    echo ""

    detect_arch

    # 非 root 需要 sudo
    if [[ $EUID -ne 0 ]]; then
        log_warn "非 root 用户，将使用 sudo"
        echo -en "${YELLOW}请输入 sudo 密码: ${NC}"
        read -rs SUDO_PASSWORD
        echo ""
        echo "${SUDO_PASSWORD}" | sudo -S -v 2>/dev/null || die "sudo 验证失败"
    fi

    generate_seal_key
    setup_system_local
    install_openbao_local
    distribute_key_local
    deploy_config_and_service_local
    start_service "localhost" "1" "true"

    rm -rf "${SEAL_KEY_DIR}"

    local protocol="http"
    [[ "${ENABLE_TLS}" == "true" ]] && protocol="https"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}  OpenBao v${OPENBAO_VERSION} 本地部署完成！${NC}"
    echo "============================================================"
    echo ""
    echo "  API:    ${protocol}://127.0.0.1:${API_PORT}"
    echo "  UI:     ${protocol}://127.0.0.1:${API_PORT}/ui"
    echo "  配置:   ${CONFIG_DIR}/openbao.hcl"
    echo "  Seal:   ${SEAL_DIR}/unseal.key"
    echo ""
    echo "    export BAO_ADDR=${protocol}://127.0.0.1:${API_PORT}"
    echo "    bao operator init"
    echo "    bao login"
    echo ""
    echo "============================================================"
}

# ========================== 主入口 ============================================
main() {
    parse_args "$@"
    check_local_deps

    if [[ "${LOCAL_MODE}" == "true" ]]; then
        deploy_local
    else
        [[ -z "${NODES}" ]] && die "请通过 --nodes 指定节点\n使用 --help 查看帮助"
        deploy_remote
    fi
}

main "$@"
