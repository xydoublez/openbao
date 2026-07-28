#!/usr/bin/env bash
# ==============================================================================
# OpenBao Static Key HA 集群 — Ansible 一键部署包装脚本
#
# 功能:
#   1. 检查 Ansible 是否可用 (不可用则自动安装)
#   2. 生成 32 字节 AES-256-GCM 共享密钥
#   3. 从参数生成 Ansible Inventory
#   4. 调用 ansible-playbook 批量部署
#   5. sudo 密码只需输入一次 (-K 参数)
#
# 用法:
#   ./deploy-ansible.sh --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user sfxadmin
#   ./deploy-ansible.sh --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user sfxadmin \
#     --local-binary /tmp/openbao_2.6.1_linux_amd64.tar.gz
#   ./deploy-ansible.sh --cleanup --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user sfxadmin
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}"

# 默认参数
NODES=""
SSH_USER="root"
SSH_PORT="22"
SSH_KEY=""
LOCAL_BINARY=""
OPENBAO_VERSION="2.6.1"
FORCE="false"
CLEANUP="false"
SKIP_KEY_GEN="false"
EXTRA_VARS=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
die()       { log_error "$@"; exit 1; }

# ========================== 安装 Ansible ======================================
ensure_ansible() {
    if command -v ansible-playbook &>/dev/null; then
        local ver
        ver="$(ansible --version | head -1)"
        log_info "Ansible 已安装: ${ver}"
        return 0
    fi

    log_step "Ansible 未安装, 尝试自动安装..."

    if command -v pip3 &>/dev/null; then
        log_info "使用 pip3 安装 Ansible..."
        pip3 install --user ansible-core 2>/dev/null || pip3 install ansible-core
    elif command -v apt-get &>/dev/null; then
        log_info "使用 apt 安装 Ansible..."
        sudo apt-get update -qq && sudo apt-get install -y -qq ansible
    elif command -v yum &>/dev/null; then
        log_info "使用 yum 安装 Ansible..."
        sudo yum install -y ansible
    elif command -v dnf &>/dev/null; then
        log_info "使用 dnf 安装 Ansible..."
        sudo dnf install -y ansible
    else
        die "无法自动安装 Ansible, 请手动安装:\n  pip3 install ansible-core\n  或: apt install ansible"
    fi

    if ! command -v ansible-playbook &>/dev/null; then
        # pip 安装后可能不在 PATH 中
        export PATH="${HOME}/.local/bin:${PATH}"
        if ! command -v ansible-playbook &>/dev/null; then
            die "Ansible 安装失败, 请手动安装"
        fi
    fi

    log_info "Ansible 安装成功"
}

# ========================== 检查 sshpass ======================================
# Ansible 使用 -k (SSH 密码认证) 时需要 sshpass
ensure_sshpass() {
    # 如果指定了 SSH key, 不需要 sshpass
    if [[ -n "${SSH_KEY}" ]]; then
        return 0
    fi

    if command -v sshpass &>/dev/null; then
        log_info "sshpass 已安装 (SSH 密码认证所需)"
        return 0
    fi

    log_step "sshpass 未安装, 尝试自动安装 (SSH 密码认证所需)..."

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
    elif command -v yum &>/dev/null; then
        sudo yum install -y sshpass
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y sshpass
    elif command -v brew &>/dev/null; then
        brew install hudochenkov/sshpass/sshpass
    else
        die "无法自动安装 sshpass\n请手动安装:\n  Ubuntu/Debian: sudo apt install sshpass\n  CentOS/RHEL:   sudo yum install sshpass\n  或使用 SSH 密钥认证: --ssh-key ~/.ssh/id_rsa"
    fi

    if ! command -v sshpass &>/dev/null; then
        die "sshpass 安装失败\n请手动安装或使用 SSH 密钥认证 (--ssh-key)"
    fi

    log_info "sshpass 安装成功"
}

# ========================== 生成密钥 ==========================================
generate_seal_key() {
    if [[ "${SKIP_KEY_GEN}" == "true" ]]; then
        log_info "跳过密钥生成 (使用已有密钥)"
        return 0
    fi

    log_step "生成 Static Key 共享密钥 (32 字节 AES-256-GCM)..."

    SEAL_KEY_DIR="$(mktemp -d)"
    SEAL_KEY_FILE="${SEAL_KEY_DIR}/unseal.key"

    openssl rand -out "${SEAL_KEY_FILE}" 32

    local key_size
    key_size="$(wc -c < "${SEAL_KEY_FILE}")"
    [[ "${key_size}" -ne 32 ]] && die "密钥大小错误: ${key_size} (需要 32)"

    log_info "共享密钥已生成: ${SEAL_KEY_FILE} (${key_size} bytes)"
}

# ========================== 生成 Inventory ====================================
generate_inventory() {
    log_step "生成 Ansible Inventory..."

    INVENTORY_FILE="${ANSIBLE_DIR}/inventory-generated.ini"

    IFS=',' read -ra NODE_LIST <<< "${NODES}"

    cat > "${INVENTORY_FILE}" <<EOF
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 请勿手动编辑, 重新运行 deploy-ansible.sh 会覆盖此文件

[openbao_cluster]
EOF

    for i in "${!NODE_LIST[@]}"; do
        local node="${NODE_LIST[$i]}"
        node="$(echo "${node}" | xargs)"
        local n=$((i + 1))
        echo "node${n} ansible_host=${node}" >> "${INVENTORY_FILE}"
    done

    cat >> "${INVENTORY_FILE}" <<EOF

[openbao_cluster:vars]
ansible_user=${SSH_USER}
ansible_port=${SSH_PORT}
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ConnectTimeout=10'
EOF

    if [[ -n "${SSH_KEY}" ]]; then
        echo "ansible_ssh_private_key_file=${SSH_KEY}" >> "${INVENTORY_FILE}"
    fi

    log_info "Inventory 已生成: ${INVENTORY_FILE}"
    cat "${INVENTORY_FILE}"
    echo ""
}

# ========================== 清理 Playbook =====================================
generate_cleanup_playbook() {
    cat > "${ANSIBLE_DIR}/cleanup.yml" <<'EOF'
---
- name: "清理 OpenBao HA 集群"
  hosts: openbao_cluster
  become: true
  gather_facts: false

  tasks:
    - name: 停止 OpenBao 服务
      ansible.builtin.systemd:
        name: openbao
        state: stopped
        enabled: false
      failed_when: false

    - name: 删除 systemd 服务单元
      ansible.builtin.file:
        path: /etc/systemd/system/openbao.service
        state: absent

    - name: 重载 systemd
      ansible.builtin.systemd:
        daemon_reload: true

    - name: 删除 OpenBao 二进制
      ansible.builtin.file:
        path: /usr/local/bin/bao
        state: absent

    - name: 删除配置与数据目录
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - /etc/openbao
        - /msun/openbao/data
        - /msun/openbao/raft
        - /msun/openbao/secrets
        - /msun/openbao/tls
        - /msun/openbao/logs

    - name: 删除系统用户
      ansible.builtin.user:
        name: openbao
        state: absent
        remove: false
      failed_when: false

    - name: 删除系统组
      ansible.builtin.group:
        name: openbao
        state: absent
      failed_when: false

    - name: 清理完成
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} 清理完成"
EOF
}

# ========================== 使用帮助 ==========================================
usage() {
    cat <<'EOF'
OpenBao Static Key HA 集群 — Ansible 一键部署

用法:
  ./deploy-ansible.sh [选项]

选项:
  --nodes ADDRS          节点 IP, 逗号分隔 (必填)
  --ssh-user USER        SSH 用户 (默认: root)
  --ssh-port PORT        SSH 端口 (默认: 22)
  --ssh-key PATH         SSH 私钥路径 (密钥认证, 推荐)
  --local-binary PATH    离线安装 tar.gz 路径
  --version VERSION      OpenBao 版本 (默认: 2.6.1)
  --seal-key PATH        使用已有密钥文件 (跳过生成)
  --force                跳过确认
  --cleanup              清理集群
  -h, --help             显示帮助

关键优势 (对比 SSH 脚本):
  - sudo 密码只需输入一次 (Ansible -K 参数)
  - 所有节点并行部署, 效率提升 N 倍
  - 离线安装使用 Ansible copy 模块, 稳定可靠
  - 支持 SSH 密钥认证, 完全免密码

示例:
  # 三节点部署 (sudo 密码只输入一次!)
  ./deploy-ansible.sh \
    --nodes "10.255.2.49,10.255.2.195,10.255.2.94" \
    --ssh-user sfxadmin

  # 离线部署
  ./deploy-ansible.sh \
    --nodes "10.255.2.49,10.255.2.195,10.255.2.94" \
    --ssh-user sfxadmin \
    --local-binary /tmp/openbao_2.6.1_linux_amd64.tar.gz

  # SSH 密钥认证 (完全无密码)
  ./deploy-ansible.sh \
    --nodes "10.255.2.49,10.255.2.195,10.255.2.94" \
    --ssh-user sfxadmin \
    --ssh-key ~/.ssh/id_rsa

  # 清理集群
  ./deploy-ansible.sh --cleanup \
    --nodes "10.255.2.49,10.255.2.195,10.255.2.94" \
    --ssh-user sfxadmin
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
            --ssh-key)      SSH_KEY="$2"; shift 2 ;;
            --local-binary) LOCAL_BINARY="$2"; shift 2 ;;
            --version)      OPENBAO_VERSION="$2"; shift 2 ;;
            --seal-key)     SEAL_KEY_FILE="$2"; SKIP_KEY_GEN="true"; shift 2 ;;
            --force)        FORCE="true"; shift ;;
            --cleanup)      CLEANUP="true"; shift ;;
            -h|--help)      usage ;;
            *)              die "未知选项: $1\n使用 --help 查看帮助" ;;
        esac
    done
}

# ========================== 主流程 ============================================
main() {
    parse_args "$@"

    echo ""
    echo "============================================================"
    echo "    OpenBao HA 集群 — Ansible 批量部署"
    echo "============================================================"
    echo ""

    # 1. 检查 Ansible
    ensure_ansible

    # 2. 检查 sshpass (SSH 密码认证时需要)
    ensure_sshpass

    # 3. 检查节点列表
    [[ -z "${NODES}" ]] && die "请通过 --nodes 指定节点列表\n使用 --help 查看帮助"

    IFS=',' read -ra NODE_LIST <<< "${NODES}"
    local node_count="${#NODE_LIST[@]}"

    echo "  节点数:    ${node_count}"
    echo "  节点:      ${NODES}"
    echo "  SSH:       ${SSH_USER}@*:${SSH_PORT}"
    echo "  版本:      v${OPENBAO_VERSION}"
    echo "  安装模式:  $([ -n "${LOCAL_BINARY}" ] && echo "离线 (${LOCAL_BINARY})" || echo "在线")"
    echo "  SSH Key:   $([ -n "${SSH_KEY}" ] && echo "${SSH_KEY}" || echo "(未指定, 将使用密码)")"
    echo ""

    # 清理模式
    if [[ "${CLEANUP}" == "true" ]]; then
        log_step "清理模式"
        generate_inventory
        generate_cleanup_playbook

        echo -e "${YELLOW}即将清理 ${node_count} 个节点上的 OpenBao${NC}"
        if [[ "${FORCE}" != "true" ]]; then
            echo -en "${YELLOW}确认清理? [y/N]: ${NC}"
            read -r reply
            [[ "${reply}" =~ ^[Yy]$ ]] || { log_info "取消"; exit 0; }
        fi

        log_step "执行清理..."
        ansible-playbook \
            -i "${INVENTORY_FILE}" \
            "${ANSIBLE_DIR}/cleanup.yml" \
            -K 2>&1

        log_info "清理完成"
        exit 0
    fi

    # 4. 生成密钥
    generate_seal_key

    # 5. 生成 Inventory
    generate_inventory

    # 6. 构造 extra vars (每个变量单独 -e, 避免空格解析问题)
    EXTRA_VARS=(-e "openbao_version=${OPENBAO_VERSION}")
    if [[ -n "${LOCAL_BINARY}" ]]; then
        # 获取绝对路径
        LOCAL_BINARY="$(cd "$(dirname "${LOCAL_BINARY}")" && pwd)/$(basename "${LOCAL_BINARY}")"
        EXTRA_VARS+=(-e "openbao_install_mode=offline" -e "openbao_local_binary=${LOCAL_BINARY}")
    fi

    # 密钥路径: --seal-key 指定或自动生成的
    local seal_key_path="${SEAL_KEY_FILE:-${SEAL_KEY_DIR}/unseal.key}"
    EXTRA_VARS+=(-e "openbao_seal_key_local_path=${seal_key_path}")

    # 7. 确认
    if [[ "${FORCE}" != "true" ]]; then
        echo -e "${YELLOW}即将在 ${node_count} 个节点上部署 OpenBao v${OPENBAO_VERSION} HA 集群${NC}"
        echo -en "${YELLOW}确认部署? [y/N]: ${NC}"
        read -r reply
        [[ "${reply}" =~ ^[Yy]$ ]] || { log_info "取消"; exit 0; }
    fi

    # 8. 执行 Playbook
    log_step "执行 Ansible Playbook..."
    echo ""
    echo "  sudo 密码只需在下方提示时输入一次!"
    echo "  如果 SSH 也需要密码, 请加 -k 参数"
    echo ""

    local playbook_args=(
        -i "${INVENTORY_FILE}"
        "${ANSIBLE_DIR}/deploy.yml"
        "${EXTRA_VARS[@]}"
    )

    # 如果未指定 SSH key, 可能需要 SSH 密码 (-k) 和 sudo 密码 (-K)
    if [[ -z "${SSH_KEY}" ]]; then
        playbook_args+=(-k -K)
    else
        playbook_args+=(-K)
    fi

    if [[ "${FORCE}" == "true" ]]; then
        playbook_args+=(--extra-vars "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'")
    fi

    ansible-playbook "${playbook_args[@]}"
    local rc=$?

    # 9. 清理临时文件
    if [[ -n "${SEAL_KEY_DIR:-}" && -d "${SEAL_KEY_DIR}" ]]; then
        rm -rf "${SEAL_KEY_DIR}"
        log_info "临时密钥文件已清理"
    fi

    if [[ $rc -eq 0 ]]; then
        echo ""
        echo "============================================================"
        echo -e "${GREEN}  部署完成!${NC}"
        echo "============================================================"
        echo ""
        echo "  初始化结果保存在: /tmp/openbao-init-*/"
        echo "  查看: cat /tmp/openbao-init-*/root-token.txt"
        echo ""
    else
        echo ""
        log_error "Playbook 执行失败 (exit code: ${rc})"
        log_error "请检查上方错误信息"
        exit $rc
    fi
}

main "$@"
