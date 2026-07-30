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
#   ./deploy-ansible.sh --reinit --nodes "10.0.1.11,10.0.1.12,10.0.1.13" --ssh-user sfxadmin
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
REINIT="false"
ENABLE_AUDIT="false"
SKIP_KEY_GEN="false"
SKIP_VALIDATE="false"
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

# ========================== 检查 SSH 密钥 ====================================
check_ssh_key() {
    # 如果指定了 SSH key, 验证文件存在
    if [[ -n "${SSH_KEY}" ]]; then
        if [[ ! -f "${SSH_KEY}" ]]; then
            die "SSH 私钥文件不存在: ${SSH_KEY}\n请先生成密钥: ssh-keygen -t ed25519"
        fi
        log_info "SSH 密钥: ${SSH_KEY}"
        return 0
    fi

    # 未指定 --ssh-key, 检查默认密钥或 ssh-agent
    if ssh-add -l &>/dev/null 2>&1; then
        log_info "检测到 ssh-agent 已加载密钥"
        return 0
    fi

    local default_keys=(~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_ecdsa)
    for key in "${default_keys[@]}"; do
        if [[ -f "${key}" ]]; then
            SSH_KEY="${key}"
            log_info "使用默认 SSH 密钥: ${SSH_KEY}"
            return 0
        fi
    done

    # 没有找到任何密钥, 自动生成
    log_warn "未找到 SSH 密钥, 自动生成..."
    local new_key="${HOME}/.ssh/id_ed25519"
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t ed25519 -f "${new_key}" -N "" -q
    SSH_KEY="${new_key}"
    log_info "已生成 SSH 密钥: ${SSH_KEY}"
    echo ""
    echo -e "${YELLOW}  密钥已生成, 但还需要将公钥分发到所有节点。${NC}"
    echo -e "${YELLOW}  请执行以下命令 (每个节点输入一次密码):${NC}"
    echo ""
    IFS=',' read -ra _nodes <<< "${NODES}"
    for node in "${_nodes[@]}"; do
        node="$(echo "${node}" | xargs)"
        echo "    ssh-copy-id -p ${SSH_PORT} ${SSH_USER}@${node}"
    done
    echo ""
    die "公钥分发完成后重新运行此脚本"
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

# ========================== 重新初始化 Playbook ================================
generate_reinit_playbook() {
    cat > "${ANSIBLE_DIR}/reinit.yml" <<'EOF'
---
# 重新初始化 OpenBao 集群 (清除 Raft 数据, 保留安装和配置)
- name: "重新初始化 — 停止服务并清除 Raft 数据"
  hosts: openbao_cluster
  become: true
  gather_facts: false
  any_errors_fatal: true

  tasks:
    - name: 停止 OpenBao 服务
      ansible.builtin.systemd:
        name: openbao
        state: stopped
      failed_when: false

    - name: 删除 Raft 数据目录
      ansible.builtin.file:
        path: "{{ openbao_raft_dir }}"
        state: absent

    - name: 重建 Raft 数据目录
      ansible.builtin.file:
        path: "{{ openbao_raft_dir }}"
        state: directory
        owner: "{{ openbao_user }}"
        group: "{{ openbao_group }}"
        mode: "0750"

    - name: 启动 OpenBao 服务
      ansible.builtin.systemd:
        name: openbao
        state: started

    - name: 等待 API 就绪
      ansible.builtin.uri:
        url: "{{ ('https' if openbao_enable_tls else 'http') }}://127.0.0.1:{{ openbao_api_port }}/v1/sys/health"
        validate_certs: false
        status_code: [200, 429, 472, 473, 501, 503]
      register: health
      retries: 15
      delay: 2
      until: health is succeeded

    - name: 确认节点处于未初始化状态
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }}: initialized={{ health.json.initialized }} (应为 false)"

- name: "重新初始化 — 清除控制节点旧数据 + 取回 Seal Key"
  hosts: openbao_cluster[0]
  become: true
  gather_facts: false

  tasks:
    - name: 取回 Seal Key 到控制节点
      ansible.builtin.fetch:
        src: "{{ openbao_seal_dir }}/unseal.key"
        dest: /tmp/openbao-reinit-key/unseal.key
        flat: true

    - name: 删除旧的初始化结果
      ansible.builtin.file:
        path: /tmp/openbao-init
        state: absent
      delegate_to: localhost
      become: false

    - name: 提示
      ansible.builtin.debug:
        msg: "旧数据已清除, Seal Key 已取回, 接下来将重新执行 deploy.yml 进行初始化"
EOF
}

# ========================== 审计 Playbook =====================================
generate_audit_playbook() {
    cat > "${ANSIBLE_DIR}/enable-audit.yml" <<'EOF'
---
# 为现有 OpenBao HA 集群启用文件审计设备 (声明式配置)
# 通过更新 HCL 配置文件添加 audit 块, 重启服务生效
- name: "启用审计日志 — 更新配置并重启"
  hosts: openbao_cluster
  become: true
  gather_facts: true

  pre_tasks:
    - name: 计算节点序号和 node_id
      ansible.builtin.set_fact:
        openbao_node_index: "{{ groups['openbao_cluster'].index(inventory_hostname) + 1 }}"
        openbao_node_id: "node{{ groups['openbao_cluster'].index(inventory_hostname) + 1 }}"
        openbao_protocol: "{{ 'https' if openbao_enable_tls else 'http' }}"

  tasks:
    - name: 确保日志目录存在且权限正确
      ansible.builtin.file:
        path: "{{ openbao_log_dir }}"
        state: directory
        owner: "{{ openbao_user }}"
        group: "{{ openbao_group }}"
        mode: "0750"

    - name: 部署 openbao.hcl 配置 (含审计块)
      ansible.builtin.template:
        src: openbao.hcl.j2
        dest: "{{ openbao_config_dir }}/openbao.hcl"
        owner: "{{ openbao_user }}"
        group: "{{ openbao_group }}"
        mode: "0640"
      notify: restart openbao

    - name: 验证 HCL 配置合法性
      when: openbao_skip_validate | default(false) | bool == false
      ansible.builtin.command: >
        {{ openbao_install_dir }}/bao server
        -config={{ openbao_config_dir }}/openbao.hcl
        -test-server-config
      register: config_validate
      changed_when: false

    - name: 刷新 handlers (重启服务)
      ansible.builtin.meta: flush_handlers

    - name: 确保服务运行
      ansible.builtin.systemd:
        name: openbao
        state: started

    - name: 等待 API 就绪
      ansible.builtin.uri:
        url: "{{ openbao_protocol }}://127.0.0.1:{{ openbao_api_port }}/v1/sys/health"
        validate_certs: false
        status_code: [200, 429, 472, 473, 501, 503]
      register: health_check
      retries: 15
      delay: 2
      until: health_check is succeeded

    - name: 显示审计配置状态
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }}: 审计日志已启用 (配置驱动), 路径: {{ openbao_audit_file_path }}"

  handlers:
    - name: restart openbao
      ansible.builtin.systemd:
        name: openbao
        state: restarted
      failed_when: false
EOF
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
        path: "{{ openbao_install_dir }}/bao"
        state: absent

    - name: 删除配置与数据目录
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - "{{ openbao_config_dir }}"
        - "{{ openbao_data_dir }}"
        - "{{ openbao_raft_dir }}"
        - "{{ openbao_seal_dir }}"
        - "{{ openbao_tls_dir }}"
        - "{{ openbao_log_dir }}"

    - name: 删除系统用户
      ansible.builtin.user:
        name: "{{ openbao_user }}"
        state: absent
        remove: false
      failed_when: false

    - name: 删除系统组
      ansible.builtin.group:
        name: "{{ openbao_group }}"
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
  --reinit               重新初始化集群 (清除Raft数据, 保留安装)
  --enable-audit         为现有集群启用审计日志
  --skip-validate        跳过 HCL 配置验证 (修复错误配置时使用)
  --cleanup              清理集群 (完全卸载)
  -h, --help             显示帮助

关键优势 (对比 SSH 脚本):
  - SSH 使用密钥认证, 完全免密码, 无需 sshpass
  - sudo 密码只需输入一次 (Ansible -K 参数)
  - 所有节点并行部署, 效率提升 N 倍
  - 离线安装使用 Ansible copy 模块, 稳定可靠

前置条件:
  1. 已配置 SSH 密钥免密登录:
     ssh-keygen -t ed25519
     ssh-copy-id sfxadmin@10.255.2.49
     ssh-copy-id sfxadmin@10.255.2.195
     ssh-copy-id sfxadmin@10.255.2.94
  2. 或使用 --ssh-key 指定私钥路径

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

  # 重新初始化集群 (root token 丢失时使用)
  ./deploy-ansible.sh --reinit \
    --nodes "10.255.2.49,10.255.2.195,10.255.2.94" \
    --ssh-user sfxadmin

  # 为现有集群启用审计日志
  ./deploy-ansible.sh --enable-audit \
    --nodes "10.255.2.49,10.255.2.195,10.255.2.94" \
    --ssh-user sfxadmin

  # 清理集群 (完全卸载)
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
            --reinit)       REINIT="true"; shift ;;
            --enable-audit) ENABLE_AUDIT="true"; shift ;;
            --skip-validate) SKIP_VALIDATE="true"; shift ;;
            --cleanup)      CLEANUP="true"; shift ;;
            -h|--help)      usage ;;
            *)              die "未知选项: $1\n使用 --help 查看帮助" ;;
        esac
    done
}

# ========================== SSH 连通性预检 ====================================
check_connectivity() {
    log_step "检查所有节点 SSH 连通性 + 认证..."

    local failed_nodes=()
    local ok_nodes=()
    local ssh_key_opt=""
    [[ -n "${SSH_KEY}" ]] && ssh_key_opt="-i ${SSH_KEY}"

    for node in "${NODE_LIST[@]}"; do
        node="$(echo "${node}" | xargs)"

        # Step 1: 检测端口是否可达
        local port_ok="false"
        if command -v nc &>/dev/null; then
            nc -z -w5 "${node}" "${SSH_PORT}" 2>/dev/null && port_ok="true"
        else
            (echo >/dev/tcp/"${node}"/"${SSH_PORT}") 2>/dev/null && port_ok="true"
        fi

        if [[ "${port_ok}" != "true" ]]; then
            failed_nodes+=("${node}:端口不可达")
            echo -e "    ${RED}✗${NC} ${node}:${SSH_PORT} — 端口不可达"
            continue
        fi

        # Step 2: 检测 SSH 认证 (密钥登录)
        local ssh_result
        ssh_result="$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -o BatchMode=yes -p "${SSH_PORT}" ${ssh_key_opt} \
            "${SSH_USER}@${node}" "echo SSH_OK" 2>&1)" || true

        if [[ "${ssh_result}" == *"SSH_OK"* ]]; then
            ok_nodes+=("${node}")
            echo -e "    ${GREEN}✓${NC} ${node}:${SSH_PORT} — 端口可达 + 认证成功"
        else
            failed_nodes+=("${node}:认证失败")
            # 提取错误关键信息
            local err_msg="${ssh_result}"
            if [[ "${err_msg}" == *"Permission denied"* ]]; then
                echo -e "    ${RED}✗${NC} ${node}:${SSH_PORT} — 端口可达, 但认证失败 (Permission denied)"
            elif [[ "${err_msg}" == *"Connection refused"* ]]; then
                echo -e "    ${RED}✗${NC} ${node}:${SSH_PORT} — SSH 服务拒绝连接"
            else
                echo -e "    ${RED}✗${NC} ${node}:${SSH_PORT} — 认证失败: ${err_msg:0:80}"
            fi
        fi
    done

    echo ""

    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        log_error "以下节点 SSH 不可用: ${failed_nodes[*]}"
        echo ""
        echo "  端口不可达: 检查 IP/防火墙/SSH服务"
        echo "  认证失败:   公钥未分发到目标节点"
        echo ""
        echo -e "${YELLOW}  修复认证失败 — 分发公钥到所有节点:${NC}"
        for fn in "${failed_nodes[@]}"; do
            local fn_ip="${fn%%:*}"
            echo "    ssh-copy-id -p ${SSH_PORT} ${SSH_USER}@${fn_ip}"
        done
        echo ""
        die "请先解决问题后重试"
    fi

    log_info "全部 ${#ok_nodes[@]} 个节点 SSH 连通性 + 认证检查通过"
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

    # 2. 检查节点列表 (必须在 check_ssh_key 之前, 因其内部使用 NODES)
    [[ -z "${NODES}" ]] && die "请通过 --nodes 指定节点列表\n使用 --help 查看帮助"

    # 3. 检查 SSH 密钥 (免密登录)
    check_ssh_key

    IFS=',' read -ra NODE_LIST <<< "${NODES}"
    local node_count="${#NODE_LIST[@]}"

    echo "  节点数:    ${node_count}"
    echo "  节点:      ${NODES}"
    echo "  SSH:       ${SSH_USER}@*:${SSH_PORT}"
    echo "  版本:      v${OPENBAO_VERSION}"
    echo "  安装模式:  $([ -n "${LOCAL_BINARY}" ] && echo "离线 (${LOCAL_BINARY})" || echo "在线")"
    echo "  SSH Key:   $([ -n "${SSH_KEY}" ] && echo "${SSH_KEY}" || echo "(自动检测)")"
    echo ""

    # 5. SSH 连通性预检
    check_connectivity

    # 重新初始化模式
    if [[ "${REINIT}" == "true" ]]; then
        log_step "重新初始化模式"
        generate_inventory
        generate_reinit_playbook

        echo -e "${YELLOW}即将重新初始化 ${node_count} 个节点的 OpenBao 集群${NC}"
        echo -e "${YELLOW}  - 清除所有 Raft 数据 (集群数据将丢失!)${NC}"
        echo -e "${YELLOW}  - 保留已安装的二进制、配置和 systemd 服务${NC}"
        echo -e "${YELLOW}  - 重新执行初始化, 生成新的 Root Token${NC}"
        if [[ "${FORCE}" != "true" ]]; then
            echo -en "${YELLOW}确认重新初始化? [y/N]: ${NC}"
            read -r reply
            [[ "${reply}" =~ ^[Yy]$ ]] || { log_info "取消"; exit 0; }
        fi

        log_step "Step 1/2: 停止服务 + 清除 Raft 数据..."
        echo -e "${BLUE}  (需要输入 sudo 密码, 共两次)${NC}"
        ansible-playbook \
            -i "${INVENTORY_FILE}" \
            "${ANSIBLE_DIR}/reinit.yml" \
            -K 2>&1

        log_step "Step 2/2: 重新部署 (初始化 + Join)..."
        # 构造 extra vars
        EXTRA_VARS=(-e "openbao_version=${OPENBAO_VERSION}")
        if [[ -n "${LOCAL_BINARY}" ]]; then
            LOCAL_BINARY="$(cd "$(dirname "${LOCAL_BINARY}")" && pwd)/$(basename "${LOCAL_BINARY}")"
            EXTRA_VARS+=(-e "openbao_install_mode=offline" -e "openbao_local_binary=${LOCAL_BINARY}")
        fi

        # Seal key: 优先用 --seal-key 指定的, 否则用 reinit.yml fetch 回来的
        local seal_key_path="${SEAL_KEY_FILE:-}"
        if [[ -z "${seal_key_path}" || ! -f "${seal_key_path}" ]]; then
            seal_key_path="/tmp/openbao-reinit-key/unseal.key"
            if [[ ! -f "${seal_key_path}" ]]; then
                die "无法找到 seal key (reinit.yml fetch 失败), 请使用 --seal-key 指定密钥文件"
            fi
            log_info "使用从节点取回的 seal key: ${seal_key_path}"
        fi
        EXTRA_VARS+=(-e "openbao_seal_key_local_path=${seal_key_path}")
        EXTRA_VARS+=(-e "openbao_skip_validate=${SKIP_VALIDATE}")

        local reinit_args=(
            -i "${INVENTORY_FILE}"
            "${ANSIBLE_DIR}/deploy.yml"
            "${EXTRA_VARS[@]}"
            -K
        )
        [[ -n "${SSH_KEY}" ]] && reinit_args+=(--private-key "${SSH_KEY}")

        ansible-playbook "${reinit_args[@]}"

        # 清理临时 seal key 文件
        [[ -d /tmp/openbao-reinit-key ]] && rm -rf /tmp/openbao-reinit-key

        echo ""
        echo "============================================================"
        echo -e "${GREEN}  重新初始化完成!${NC}"
        echo "============================================================"
        echo ""
        echo "  管理员交付文件:"
        echo "    /tmp/openbao-init/cluster-info.txt  — 完整交付信息"
        echo "    /tmp/openbao-init/root-token.txt    — 新的 Root Token"
        echo "    /tmp/openbao-init/recovery-keys.txt — 新的 Recovery Keys"
        echo ""
        exit 0
    fi

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

    # 启用审计模式
    if [[ "${ENABLE_AUDIT}" == "true" ]]; then
        log_step "启用审计日志模式"
        generate_inventory
        generate_audit_playbook

        echo -e "${YELLOW}即将为 ${node_count} 个节点的集群启用审计日志${NC}"
        echo -e "  配置方式: 更新 openbao.hcl 添加 audit 块 + 重启服务"
        echo -e "  审计日志路径: /msun/openbao/logs/audit.log (可通过 group_vars 自定义)"
        if [[ "${FORCE}" != "true" ]]; then
            echo -en "${YELLOW}确认启用? [y/N]: ${NC}"
            read -r reply
            [[ "${reply}" =~ ^[Yy]$ ]] || { log_info "取消"; exit 0; }
        fi

        log_step "执行启用审计日志..."
        local audit_args=(
            -i "${INVENTORY_FILE}"
            "${ANSIBLE_DIR}/enable-audit.yml"
            -e "openbao_audit_enabled=true"
            -e "openbao_skip_validate=${SKIP_VALIDATE}"
            -K
        )
        [[ -n "${SSH_KEY}" ]] && audit_args+=(--private-key "${SSH_KEY}")

        ansible-playbook "${audit_args[@]}"

        echo ""
        echo "============================================================"
        echo -e "${GREEN}  审计日志已启用!${NC}"
        echo "============================================================"
        echo ""
        echo "  配置方式: 声明式 (openbao.hcl audit 块)"
        echo "  日志文件: /msun/openbao/logs/audit.log (各节点)"
        echo "  查看日志: tail -f /msun/openbao/logs/audit.log"
        echo ""
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
    EXTRA_VARS+=(-e "openbao_skip_validate=${SKIP_VALIDATE}")

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
    echo "  SSH 使用密钥认证 (免密), 无需 sshpass"
    echo ""

    local playbook_args=(
        -i "${INVENTORY_FILE}"
        "${ANSIBLE_DIR}/deploy.yml"
        "${EXTRA_VARS[@]}"
        -K
    )

    # 如果指定了 SSH key, 传给 Ansible
    if [[ -n "${SSH_KEY}" ]]; then
        playbook_args+=(--private-key "${SSH_KEY}")
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
        echo "  管理员交付文件:"
        echo "    /tmp/openbao-init/cluster-info.txt  — 完整交付信息 (含所有凭据)"
        echo "    /tmp/openbao-init/root-token.txt    — Root Token"
        echo "    /tmp/openbao-init/recovery-keys.txt — Recovery Keys"
        echo ""
        echo -e "  ${YELLOW}请立即将以上文件保存到安全位置!${NC}"
        echo ""
    else
        echo ""
        log_error "Playbook 执行失败 (exit code: ${rc})"
        log_error "请检查上方错误信息"
        exit $rc
    fi
}

main "$@"
