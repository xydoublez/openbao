#!/usr/bin/env bash
# ==============================================================================
# OpenBao AppRole + Transit 加解密一键配置脚本
#
# 功能:
#   - 为指定应用启用 Transit Secrets Engine 并创建加密密钥
#   - 创建最小权限策略 (encrypt / decrypt / 读密钥元信息)
#   - 启用 AppRole 认证并创建角色，绑定策略
#   - 输出 role-id / secret-id，给出应用端完整操作示例
#
# 用法:
#   ./setup-approle-transit.sh [选项]
#
# 示例:
#   # 基本用法 (root 命名空间)
#   ./setup-approle-transit.sh --app order-service
#
#   # 指定命名空间 (仅企业版/付费版支持)
#   ./setup-approle-transit.sh --app order-service --namespace team-a
#
#   # 指定密钥类型 & 允许密钥轮转
#   ./setup-approle-transit.sh --app order-service --key-type chacha20-poly1305 --allow-rotate
#
# 环境变量:
#   BAO_ADDR         OpenBao 服务地址 (默认 http://127.0.0.1:8200)
#   BAO_TOKEN        管理员 Token (若未设置则交互式登录)
#   BAO_NAMESPACE    命名空间 (可选，优先使用 --namespace 参数)
#
# 前提:
#   - OpenBao 服务已运行且已解封
#   - 已安装 bao CLI 并加入 PATH
#   - 拥有 root 或管理员权限
# ==============================================================================

set -euo pipefail

# ========================== 默认配置 ==========================================
APP_NAME=""
NAMESPACE=""
KEY_TYPE="aes256-gcm96"
ALLOW_ROTATE="false"
TOKEN_TTL="1h"
TOKEN_MAX_TTL="24h"
SECRET_ID_TTL="720h"
SECRET_ID_NUM_USES="0"
TRANSIT_MOUNT="transit"
FORCE="false"
SKIP_TRANSIT_ENABLE="false"
SKIP_APPROLE_ENABLE="false"
OUTPUT_DIR=""
BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"

# ========================== 颜色与日志 ========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

die() { log_error "$@"; exit 1; }

# 安全的 JSON 字段提取 (优先 jq，fallback grep)
_json_field() {
    local field="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".${field} // empty" 2>/dev/null
    else
        grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:.*"\([^"]*\)"$/\1/'
    fi
}

_json_bool() {
    local field="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".${field} // false" 2>/dev/null
    else
        grep -o "\"${field}\"[[:space:]]*:[[:space:]]*[a-z]*" | head -1 | sed 's/.*:[[:space:]]*//' 
    fi
}

# 参数值非空校验
_require_arg() {
    local opt="$1" val="${2:-}"
    if [[ -z "${val}" || "${val}" == --* ]]; then
        die "参数 ${opt} 缺少值 (使用 -h 查看帮助)"
    fi
}

# 检查 jq 可用性 (仅提示，不阻断)
_HAS_JQ="false"
if command -v jq >/dev/null 2>&1; then
    _HAS_JQ="true"
fi

# ========================== 帮助信息 ==========================================
usage() {
    echo -e "${BOLD}OpenBao AppRole + Transit 加解密一键配置脚本${NC}"
    echo ""
    echo -e "${CYAN}用法:${NC}"
    echo "  $0 --app <应用名> [选项]"
    echo ""
    echo -e "${CYAN}必需参数:${NC}"
    echo "  --app, -a <name>          应用名称 (如 order-service)"
    echo ""
    echo -e "${CYAN}可选参数:${NC}"
    echo "  --namespace, -n <ns>      命名空间 (OpenBao 开源版仅支持 root，可省略)"
    echo "  --key-type, -k <type>     加密密钥类型 (默认: aes256-gcm96)"
    echo "                            可选: aes128-gcm96, aes256-gcm96, chacha20-poly1305,"
    echo "                                  rsa-2048, rsa-3072, rsa-4096, ecdsa-p256, ecdsa-p384"
    echo "  --allow-rotate            允许应用轮转密钥 (默认: 不允许)"
    echo "  --token-ttl <duration>    AppRole Token 有效期 (默认: 1h)"
    echo "  --token-max-ttl <dur>     Token 续期最大上限 (默认: 24h)"
    echo "  --secret-id-ttl <dur>     secret_id 有效期 (默认: 720h，即30天)"
    echo "  --secret-id-num-uses <n>  secret_id 可用次数 (默认: 0=不限)"
    echo "  --transit-mount <path>    Transit 引擎挂载路径 (默认: transit)"
    echo "  --skip-transit-enable     跳过启用 Transit 引擎 (已启用时使用)"
    echo "  --skip-approle-enable     跳过启用 AppRole 认证 (已启用时使用)"
    echo "  --output-dir, -o <dir>    将凭据输出到指定目录"
    echo "  --force, -f               跳过确认提示，直接执行"
    echo "  -h, --help                显示帮助信息"
    echo ""
    echo -e "${CYAN}环境变量:${NC}"
    echo "  BAO_ADDR                  OpenBao 服务地址 (默认: http://127.0.0.1:8200)"
    echo "  BAO_TOKEN                 管理员 Token"
    echo "  BAO_NAMESPACE             命名空间"
    echo ""
    echo -e "${CYAN}示例:${NC}"
    echo "  # 为 order-service 配置 AppRole + Transit (root 命名空间)"
    echo "  $0 --app order-service"
    echo ""
    echo "  # 指定命名空间 team-a，允许密钥轮转"
    echo "  $0 --app order-service --namespace team-a --allow-rotate"
    echo ""
    echo "  # 使用 chacha20-poly1305 密钥，输出凭据到 /tmp/creds"
    echo "  $0 --app payment-service --key-type chacha20-poly1305 --output-dir /tmp/creds"
    echo ""
    echo "  # 全自动模式 (CI/CD)"
    echo "  BAO_TOKEN=root-token $0 --app order-service --force"
    exit 0
}

# ========================== 参数解析 ==========================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|-a)          _require_arg "$1" "${2:-}"; APP_NAME="$2"; shift 2 ;;
        --namespace|-n)    _require_arg "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
        --key-type|-k)     _require_arg "$1" "${2:-}"; KEY_TYPE="$2"; shift 2 ;;
        --allow-rotate)    ALLOW_ROTATE="true"; shift ;;
        --token-ttl)       _require_arg "$1" "${2:-}"; TOKEN_TTL="$2"; shift 2 ;;
        --token-max-ttl)   _require_arg "$1" "${2:-}"; TOKEN_MAX_TTL="$2"; shift 2 ;;
        --secret-id-ttl)   _require_arg "$1" "${2:-}"; SECRET_ID_TTL="$2"; shift 2 ;;
        --secret-id-num-uses) _require_arg "$1" "${2:-}"; SECRET_ID_NUM_USES="$2"; shift 2 ;;
        --transit-mount)   _require_arg "$1" "${2:-}"; TRANSIT_MOUNT="$2"; shift 2 ;;
        --skip-transit-enable)  SKIP_TRANSIT_ENABLE="true"; shift ;;
        --skip-approle-enable)  SKIP_APPROLE_ENABLE="true"; shift ;;
        --output-dir|-o)   _require_arg "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
        --force|-f)        FORCE="true"; shift ;;
        -h|--help)         usage ;;
        *)                 die "未知参数: $1 (使用 -h 查看帮助)" ;;
    esac
done

# ========================== 参数验证 ==========================================
[[ -z "${APP_NAME}" ]] && die "缺少必需参数 --app (使用 -h 查看帮助)"

# 校验密钥类型合法性
_VALID_KEY_TYPES="aes128-gcm96 aes256-gcm96 chacha20-poly1305 rsa-2048 rsa-3072 rsa-4096 ecdsa-p256 ecdsa-p384 ecdsa-p521 ed25519"
_VALID="false"
for _VT in ${_VALID_KEY_TYPES}; do
    [[ "${KEY_TYPE}" == "${_VT}" ]] && { _VALID="true"; break; }
done
[[ "${_VALID}" == "true" ]] || die "不支持的密钥类型: ${KEY_TYPE}\n  可选: ${_VALID_KEY_TYPES}"

# 命名空间优先级：参数 > 环境变量
NAMESPACE="${NAMESPACE:-${BAO_NAMESPACE:-}}"

# ========================== 前置检查 ==========================================
log_step "前置检查"

# 检查 bao CLI
command -v bao >/dev/null 2>&1 || die "未找到 bao CLI，请确认已安装并加入 PATH"
log_ok "bao CLI 已安装: $(bao version 2>/dev/null | head -1 || echo 'version unknown')"

# 检查 BAO_ADDR
export BAO_ADDR
log_info "BAO_ADDR = ${BAO_ADDR}"

# 检查 Token (若未设置则提示登录)
if [[ -z "${BAO_TOKEN:-}" ]]; then
    log_warn "未设置 BAO_TOKEN，请先登录获取管理员 Token"
    echo ""
    echo -e "${CYAN}请在另一个终端执行:${NC}"
    echo "  export BAO_ADDR=${BAO_ADDR}"
    echo "  bao login"
    echo ""
    echo -en "${YELLOW}登录后请粘贴 Token: ${NC}"
    read -r BAO_TOKEN
    export BAO_TOKEN
fi

# 验证 Token 有效性 & 缓存状态信息
_BAO_STATUS=""
if _BAO_STATUS=$(bao status -format=json 2>/dev/null); then
    log_ok "OpenBao 连接正常"
else
    die "无法连接 OpenBao 或 Token 无效 (BAO_ADDR=${BAO_ADDR})"
fi

# 检查初始化状态
INIT_STATUS=$(echo "${_BAO_STATUS}" | _json_bool "initialized")
if [[ "${INIT_STATUS}" != "true" ]]; then
    die "OpenBao 尚未初始化，请先执行 bao operator init"
fi
log_ok "OpenBao 已初始化"

# 检查 Seal 状态
SEAL_STATUS=$(echo "${_BAO_STATUS}" | _json_bool "sealed")
if [[ "${SEAL_STATUS}" == "true" ]]; then
    die "OpenBao 已封存，请先执行 bao operator unseal"
fi
log_ok "OpenBao 已解封"

# ========================== 确认执行 ==========================================
echo ""
echo -e "${BOLD}========== 配置摘要 ==========${NC}"
echo -e "  应用名称:        ${CYAN}${APP_NAME}${NC}"
echo -e "  命名空间:        ${CYAN}${NAMESPACE:-root (默认)}${NC}"
echo -e "  密钥类型:        ${CYAN}${KEY_TYPE}${NC}"
echo -e "  允许密钥轮转:    ${CYAN}${ALLOW_ROTATE}${NC}"
echo -e "  Transit 挂载:    ${CYAN}${TRANSIT_MOUNT}${NC}"
echo -e "  Token TTL:       ${CYAN}${TOKEN_TTL}${NC}"
echo -e "  Token Max TTL:   ${CYAN}${TOKEN_MAX_TTL}${NC}"
echo -e "  Secret ID TTL:   ${CYAN}${SECRET_ID_TTL}${NC}"
echo -e "  Secret ID 次数:  ${CYAN}${SECRET_ID_NUM_USES}${NC}"
echo -e "${BOLD}==============================${NC}"
echo ""

if [[ "${FORCE}" != "true" ]]; then
    echo -en "${YELLOW}确认执行以上配置? [y/N]: ${NC}"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { log_warn "已取消"; exit 0; }
fi

# 设置命名空间环境变量 (先不设置，等创建完成后再切换作用域)
# BAO_NAMESPACE 在 Step 1 结束后才 export

# ========================== Step 1: 创建命名空间 ==============================
if [[ -n "${NAMESPACE}" ]]; then
    log_step "Step 1/7: 创建命名空间 ${NAMESPACE}"

    # 切换到 root 进行命名空间操作
    unset BAO_NAMESPACE 2>/dev/null || true

    # 逐级创建命名空间 (支持嵌套，如 team-a/sub-team)
    IFS='/' read -ra _NS_PARTS <<< "${NAMESPACE}"
    _NS_PATH=""
    for _PART in "${_NS_PARTS[@]}"; do
        if [[ -n "${_NS_PATH}" ]]; then
            _NS_PATH="${_NS_PATH}/${_PART}"
            # 嵌套命名空间需在父命名空间下创建
            export BAO_NAMESPACE="${_NS_PATH%/*}"
        else
            _NS_PATH="${_PART}"
            unset BAO_NAMESPACE 2>/dev/null || true
        fi

        # 检查命名空间是否已存在 (匹配 JSON key: "name/" 形式)
        if bao namespace list -format=json 2>/dev/null | grep -q "\"${_PART}/\"" ; then
            log_warn "命名空间 ${_NS_PATH} 已存在，跳过创建"
        else
            # 确保在正确的父命名空间下创建
            if [[ "${_NS_PATH}" == *"/"* ]]; then
                export BAO_NAMESPACE="${_NS_PATH%/*}"
            else
                unset BAO_NAMESPACE 2>/dev/null || true
            fi
            bao namespace create "${_PART}" || die "创建命名空间 ${_NS_PATH} 失败"
            log_ok "命名空间 ${_NS_PATH} 创建成功"
        fi
    done

    # 切换到目标命名空间
    export BAO_NAMESPACE="${NAMESPACE}"
    log_info "已切换到命名空间: ${NAMESPACE}"
else
    log_step "Step 1/7: 命名空间 - 跳过 (使用 root)"
fi

# ========================== Step 2: 启用 Transit 引擎 =========================
log_step "Step 2/7: 启用 Transit Secrets Engine"

if [[ "${SKIP_TRANSIT_ENABLE}" == "true" ]]; then
    log_warn "已指定 --skip-transit-enable，跳过启用 Transit 引擎"
else
    if bao secrets list -format=json 2>/dev/null | grep -q "\"${TRANSIT_MOUNT}/\"[[:space:]]*:[[:space:]]*{" ; then
        log_warn "Transit 引擎已在 ${TRANSIT_MOUNT} 挂载，跳过启用"
    else
        bao secrets enable -path="${TRANSIT_MOUNT}" transit || die "启用 Transit 引擎失败"
        log_ok "Transit 引擎已启用 (mount: ${TRANSIT_MOUNT})"
    fi
fi

# ========================== Step 3: 创建加密密钥 ==============================
log_step "Step 3/7: 创建加密密钥 ${APP_NAME}"

KEY_PATH="${TRANSIT_MOUNT}/keys/${APP_NAME}"

if bao read "${KEY_PATH}" -format=json >/dev/null 2>&1; then
    log_warn "密钥 ${APP_NAME} 已存在，跳过创建"
    EXISTING_TYPE=$(bao read "${KEY_PATH}" -format=json 2>/dev/null | _json_field "data.type")
    if [[ -z "${EXISTING_TYPE}" ]]; then
        EXISTING_TYPE=$(bao read "${KEY_PATH}" -format=json 2>/dev/null | grep -o '"type"[[:space:]]*:[[:space:]]*"[a-zA-Z0-9_-]*"' | head -1 | sed 's/.*"\([a-zA-Z0-9_-]*\)"$/\1/')
    fi
    log_info "现有密钥类型: ${EXISTING_TYPE}"
else
    bao write -f "${KEY_PATH}" type="${KEY_TYPE}" || die "创建加密密钥失败"
    log_ok "加密密钥创建成功 (type: ${KEY_TYPE})"
fi

# 显示密钥信息
echo ""
echo -e "${CYAN}--- 密钥详情 ---${NC}"
bao read "${KEY_PATH}" || true
echo ""

# ========================== Step 4: 创建策略 ==================================
log_step "Step 4/7: 创建最小权限策略"

POLICY_NAME="${APP_NAME}-transit"

# 构建策略内容
POLICY_CONTENT="# AppRole Transit 策略 - 应用: ${APP_NAME}
# 生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

# 允许加密
path \"${TRANSIT_MOUNT}/encrypt/${APP_NAME}\" {
  capabilities = [\"update\"]
}

# 允许解密
path \"${TRANSIT_MOUNT}/decrypt/${APP_NAME}\" {
  capabilities = [\"update\"]
}

# 允许读取密钥元信息 (不能导出密钥本身)
path \"${TRANSIT_MOUNT}/keys/${APP_NAME}\" {
  capabilities = [\"read\"]
}"

if [[ "${ALLOW_ROTATE}" == "true" ]]; then
    POLICY_CONTENT="${POLICY_CONTENT}

# 允许密钥轮转
path \"${TRANSIT_MOUNT}/keys/${APP_NAME}/rotate\" {
  capabilities = [\"update\"]
}"
fi

echo "${POLICY_CONTENT}" | bao policy write "${POLICY_NAME}" - || die "创建策略失败"
log_ok "策略 ${POLICY_NAME} 创建成功"

echo ""
echo -e "${CYAN}--- 策略内容 ---${NC}"
bao policy read "${POLICY_NAME}" || true
echo ""

# ========================== Step 5: 启用 AppRole ==============================
log_step "Step 5/7: 启用 AppRole 认证"

if [[ "${SKIP_APPROLE_ENABLE}" == "true" ]]; then
    log_warn "已指定 --skip-approle-enable，跳过启用 AppRole"
else
    if bao auth list -format=json 2>/dev/null | grep -q '"type"[[:space:]]*:[[:space:]]*"approle"'; then
        log_warn "AppRole 认证已启用，跳过"
    else
        bao auth enable approle || die "启用 AppRole 失败"
        log_ok "AppRole 认证已启用"
    fi
fi

# ========================== Step 6: 创建 AppRole 角色 =========================
log_step "Step 6/7: 创建 AppRole 角色 ${APP_NAME}"

ROLE_PATH="auth/approle/role/${APP_NAME}"

bao write "${ROLE_PATH}" \
    token_policies="${POLICY_NAME}" \
    token_ttl="${TOKEN_TTL}" \
    token_max_ttl="${TOKEN_MAX_TTL}" \
    secret_id_ttl="${SECRET_ID_TTL}" \
    secret_id_num_uses="${SECRET_ID_NUM_USES}" \
    || die "创建 AppRole 角色失败"

log_ok "AppRole 角色 ${APP_NAME} 创建成功"

# ========================== Step 7: 获取凭据 ==================================
log_step "Step 7/7: 获取 AppRole 凭据"

ROLE_ID=$(bao read "auth/approle/role/${APP_NAME}/role-id" -format=json 2>/dev/null | _json_field "data.role_id")
if [[ -z "${ROLE_ID}" ]]; then
    ROLE_ID=$(bao read "auth/approle/role/${APP_NAME}/role-id" -format=json 2>/dev/null | grep -o '"role_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

SECRET_ID=$(bao write -f "auth/approle/role/${APP_NAME}/secret-id" -format=json 2>/dev/null | _json_field "data.secret_id")
if [[ -z "${SECRET_ID}" ]]; then
    SECRET_ID=$(bao write -f "auth/approle/role/${APP_NAME}/secret-id" -format=json 2>/dev/null | grep -o '"secret_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
fi

log_ok "凭据获取成功"

# ========================== 输出结果 ==========================================
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  AppRole + Transit 配置完成!${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""

echo -e "${BOLD}--- AppRole 凭据 ---${NC}"
echo -e "  ${CYAN}Role ID:${NC}    ${ROLE_ID}"
echo -e "  ${CYAN}Secret ID:${NC}  ${SECRET_ID}"
echo ""
log_warn "${YELLOW}Secret ID 已打印到终端，请注意命令行历史记录泄露风险。${NC}"
log_warn "${YELLOW}建议通过 --output-dir 参数将凭据写入文件 (权限 600)。${NC}"
echo ""

# 如果指定了输出目录，保存凭据
if [[ -n "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
    CRED_FILE="${OUTPUT_DIR}/${APP_NAME}-credentials.env"
    cat > "${CRED_FILE}" <<EOF
# OpenBao AppRole Credentials - ${APP_NAME}
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
OPENBAO_ADDR=${BAO_ADDR}
OPENBAO_NAMESPACE=${NAMESPACE:-}
OPENBAO_ROLE_ID=${ROLE_ID}
OPENBAO_SECRET_ID=${SECRET_ID}
OPENBAO_TRANSIT_KEY=${APP_NAME}
OPENBAO_TRANSIT_MOUNT=${TRANSIT_MOUNT}
OPENBAO_POLICY_NAME=${POLICY_NAME}
EOF
    chmod 600 "${CRED_FILE}"
    log_info "凭据已保存到: ${CRED_FILE}"

    # 保存策略文件
    POLICY_FILE="${OUTPUT_DIR}/${APP_NAME}-transit-policy.hcl"
    echo "${POLICY_CONTENT}" > "${POLICY_FILE}"
    log_info "策略已保存到: ${POLICY_FILE}"
fi

# ========================== 生成凭据交付文件 ==================================
DELIVERY_FILE="${OUTPUT_DIR:-.}/openbao-credential-delivery-${APP_NAME}-$(date '+%Y%m%d%H%M%S').txt"
_NS_HEADER_LINE=""
if [[ -n "${NAMESPACE}" ]]; then
  _NS_HEADER_LINE="  X-Vault-Namespace:  ${NAMESPACE}  (如使用命名空间必须携带)"
fi
_generate_delivery_file() {
cat <<DELIVERY_EOF
################################################################################
#
#  OpenBao KMS 凭据交付文件
#  应用名称:  ${APP_NAME}
#  交付时间:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
#  交付人:    $(whoami)@$(hostname)
#
################################################################################

目录
----
  1. 连接信息与凭据
  2. 环境变量配置
  3. KMS 接口文档 (核心)
     3.1 登录获取 Token
     3.2 加密
     3.3 解密
     3.4 Token 续期
     3.5 错误码说明
  4. 多语言调用示例
     4.1 curl
     4.2 Go
     4.3 Python
     4.4 Java (Spring Boot)
  5. 一键验证脚本
  6. 权限边界
  7. 安全须知


================================================================================
  1. 连接信息与凭据
================================================================================

  服务地址 (BAO_ADDR):     ${BAO_ADDR}
  API 基础路径:            ${BAO_ADDR}/v1
  命名空间:                ${NAMESPACE:-root (默认)}
  Transit 引擎挂载:        ${TRANSIT_MOUNT}
  加密密钥名:              ${APP_NAME}
  密钥类型:                ${KEY_TYPE}
  策略名称:                ${POLICY_NAME}

  Role ID:                 ${ROLE_ID}
  Secret ID:               ${SECRET_ID}

  Token 有效期:            ${TOKEN_TTL}
  Token 续期上限:          ${TOKEN_MAX_TTL}
  Secret ID 有效期:        ${SECRET_ID_TTL}


================================================================================
  2. 环境变量配置
================================================================================

  将以下内容写入 .env 文件或配置中心 (切勿提交到 Git):

  OPENBAO_ADDR="${BAO_ADDR}"
  OPENBAO_NAMESPACE="${NAMESPACE:-}"
  OPENBAO_ROLE_ID="${ROLE_ID}"
  OPENBAO_SECRET_ID="${SECRET_ID}"
  OPENBAO_TRANSIT_KEY="${APP_NAME}"
  OPENBAO_TRANSIT_MOUNT="${TRANSIT_MOUNT}"

  .gitignore 务必添加:
  .env
  *.env
  openbao-credential-delivery-*.txt


################################################################################
#                                                                              #
#                    3. KMS 接口文档 (核心)                                    #
#                                                                              #
#  所有接口说明:                                                                #
#  - Base URL:  ${BAO_ADDR}/v1                                                #
#  - 数据格式:  JSON                                                           #
#  - 认证方式:  请求头 X-Vault-Token 携带登录后获得的 Token                    #
#  - 命名空间:  如使用命名空间需携带 X-Vault-Namespace 请求头                   #
#                                                                              #
################################################################################


--------------------------------------------------------------------------------
  3.1  登录获取 Token
--------------------------------------------------------------------------------

  所有加解密操作前，必须先调用此接口获取 Token。
  Token 有效期 ${TOKEN_TTL}，续期上限 ${TOKEN_MAX_TTL}。

  HTTP 请求:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ POST ${BAO_ADDR}/v1/auth/approle/login                                    │
  │                                                                            │
  │ Headers:                                                                   │
  │   Content-Type:       application/json                                     │
  │                                                                            │
  │ Body (JSON):                                                               │
  │   {                                                                        │
  │     "role_id":   "${ROLE_ID}",                                        │
  │     "secret_id": "<your-secret-id>"                                        │
  │   }                                                                        │
  └────────────────────────────────────────────────────────────────────────────┘

  成功响应 (HTTP 200):
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ {                                                                          │
  │   "auth": {                                                                │
  │     "client_token":      "hvs.CAESI...",   <-- 后续请求携带此 Token       │
  │     "accessor":          "hmac-sha256:...",                                │
  │     "policies":          ["default", "${POLICY_NAME}"],              │
  │     "token_policies":    ["default", "${POLICY_NAME}"],              │
  │     "lease_duration":    3600,               <-- Token 有效期 (秒)         │
  │     "renewable":         true                                              │
  │   }                                                                        │
  │ }                                                                          │
  └────────────────────────────────────────────────────────────────────────────┘

  curl 示例:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ curl -s -X POST '${BAO_ADDR}/v1/auth/approle/login' \\               │
  │   -H 'Content-Type: application/json'\\                                   │
  │   -d '{"role_id":"${ROLE_ID}","secret_id":"<SECRET_ID>"}'       │
  │   | jq -r '.auth.client_token'                                             │
  └────────────────────────────────────────────────────────────────────────────┘


--------------------------------------------------------------------------------
  3.2  加密接口
--------------------------------------------------------------------------------

  将明文数据加密为密文。明文必须为 base64 编码。

  HTTP 请求:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ POST ${BAO_ADDR}/v1/${TRANSIT_MOUNT}/encrypt/${APP_NAME}            │
  │                                                                            │
  │ Headers:                                                                   │
  │   Content-Type:       application/json                                     │
  │   X-Vault-Token:      <登录后获取的 client_token>                          │
${_NS_HEADER_LINE:+  │ ${_NS_HEADER_LINE}
}
  │ Body (JSON):                                                               │
  │   {                                                                        │
  │     "plaintext":  "<base64 编码的明文数据>"                               │
  │   }                                                                        │
  │                                                                            │
  │ Body 字段说明:                                                             │
  │   plaintext  (string, 必填)  base64 编码的原始数据                         │
  │   context    (string, 可选)  加密上下文 (用于派生密钥, 需 base64)          │
  │   key_version(int,    可选)  指定密钥版本 (默认使用最新版本)               │
  └────────────────────────────────────────────────────────────────────────────┘

  成功响应 (HTTP 200):
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ {                                                                          │
  │   "data": {                                                                │
  │     "ciphertext":    "vault:v1:abcdef1234567890...",  <-- 密文            │
  │     "key_version":   1                                                     │
  │   }                                                                        │
  │ }                                                                          │
  └────────────────────────────────────────────────────────────────────────────┘

  注意事项:
  - 密文格式为 "vault:v<version>:<密文数据>"，请完整存储，解密时原样传入
  - 每次加密即使明文相同，密文也不同 (因 IV/nonce 随机)
  - plaintext 必须是合法的 base64 字符串，否则返回 400

  curl 示例:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ # 加密 "sensitive-data-12345"                                              │
  │ PLAIN_B64=\$(echo -n "sensitive-data-12345" | base64)                     │
  │                                                                            │
  │ curl -s -X POST \\                                                          │
  │   '${BAO_ADDR}/v1/${TRANSIT_MOUNT}/encrypt/${APP_NAME}' \\           │
  │   -H "Content-Type: application/json" \\                                    │
  │   -H "X-Vault-Token: \${TOKEN}" \\                                          │
  │   -d "{\"plaintext\":\"\${PLAIN_B64}\"}" \\                               │
  │   | jq -r '.data.ciphertext'                                               │
  │                                                                            │
  │ # 输出: vault:v1:xxxxxxxxxxxxxxxxxxxxxxxxx                                 │
  └────────────────────────────────────────────────────────────────────────────┘


--------------------------------------------------------------------------------
  3.3  解密接口
--------------------------------------------------------------------------------

  将密文解密回明文。

  HTTP 请求:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ POST ${BAO_ADDR}/v1/${TRANSIT_MOUNT}/decrypt/${APP_NAME}            │
  │                                                                            │
  │ Headers:                                                                   │
  │   Content-Type:       application/json                                     │
  │   X-Vault-Token:      <登录后获取的 client_token>                          │
${_NS_HEADER_LINE:+  │ ${_NS_HEADER_LINE}
}
  │ Body (JSON):                                                               │
  │   {                                                                        │
  │     "ciphertext":  "vault:v1:abcdef1234567890..."                         │
  │   }                                                                        │
  │                                                                            │
  │ Body 字段说明:                                                             │
  │   ciphertext (string, 必填)  加密接口返回的完整密文                        │
  │   context    (string, 可选)  加密时使用的上下文 (需与加密时一致)           │
  └────────────────────────────────────────────────────────────────────────────┘

  成功响应 (HTTP 200):
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ {                                                                          │
  │   "data": {                                                                │
  │     "plaintext":    "c2Vuc2l0aXZlLWRhdGEtMTIzNDU="   <-- base64 编码明文  │
  │   }                                                                        │
  │ }                                                                          │
  └────────────────────────────────────────────────────────────────────────────┘

  注意事项:
  - 返回的 plaintext 是 base64 编码，需解码后使用:  echo <plaintext> | base64 -d
  - ciphertext 必须使用加密接口返回的完整字符串 (含 "vault:v1:" 前缀)
  - 如果密钥版本已轮转且旧版本被禁止解密，将返回 400

  curl 示例:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ curl -s -X POST \\                                                          │
  │   '${BAO_ADDR}/v1/${TRANSIT_MOUNT}/decrypt/${APP_NAME}' \\           │
  │   -H "Content-Type: application/json" \\                                    │
  │   -H "X-Vault-Token: \${TOKEN}" \\                                          │
  │   -d '{"ciphertext":"vault:v1:xxxxxxxx"}' \\                              │
  │   | jq -r '.data.plaintext' | base64 -d                                    │
  │                                                                            │
  │ # 输出: sensitive-data-12345                                               │
  └────────────────────────────────────────────────────────────────────────────┘


--------------------------------------------------------------------------------
  3.4  Token 续期
--------------------------------------------------------------------------------

  在 Token 过期前调用此接口续期，避免重新登录。

  HTTP 请求:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ POST ${BAO_ADDR}/v1/auth/token/renew-self                                 │
  │                                                                            │
  │ Headers:                                                                   │
  │   Content-Type:       application/json                                     │
  │   X-Vault-Token:      <当前有效的 client_token>                            │
  │                                                                            │
  │ Body (JSON):                                                               │
  │   {                                                                        │
  │     "increment": "1h"              <-- 续期时长 (可选, 默认按原 TTL)       │
  │   }                                                                        │
  └────────────────────────────────────────────────────────────────────────────┘

  成功响应 (HTTP 200):  与登录响应格式相同，auth.lease_duration 为新的有效期。

  注意: Token 续期不能超过 max_ttl (${TOKEN_MAX_TTL})，超过后必须重新登录。


--------------------------------------------------------------------------------
  3.5  错误码说明
--------------------------------------------------------------------------------

  HTTP 状态码   含义                  常见原因
  ----------   --------------------   ------------------------------------------
  200          成功                   请求正常处理
  400          请求参数错误           plaintext 非 base64; ciphertext 格式错误
  403          权限不足               Token 无效/过期; 策略不允许该操作
  404          路径不存在             密钥名错误; Transit 引擎未挂载
  429          请求过于频繁           触发速率限制
  500          服务端内部错误         请联系管理员
  503          服务不可用             OpenBao 已封存(sealed)或未就绪

  错误响应格式:
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ {                                                                          │
  │   "errors": [                                                              │
  │     "具体错误描述信息"                                                     │
  │   ]                                                                        │
  │ }                                                                          │
  └────────────────────────────────────────────────────────────────────────────┘

  常见排查:
  - 403 "permission denied": 检查 Token 是否过期，重新登录即可
  - 400 "invalid base64":   plaintext 必须是标准 base64 编码
  - 404 "no handler":       检查密钥名和 Transit 挂载路径是否正确


################################################################################
#                                                                              #
#                    4. 多语言调用示例                                          #
#                                                                              #
################################################################################


--------------------------------------------------------------------------------
  4.1  curl 完整流程
--------------------------------------------------------------------------------

  #!/usr/bin/env bash
  set -euo pipefail

  BAO="${BAO_ADDR}"
  ROLE_ID="${ROLE_ID}"
  SECRET_ID="${SECRET_ID}"
  KEY="${APP_NAME}"
  MOUNT="${TRANSIT_MOUNT}"

  # [1] 登录
  TOKEN=\$(curl -sf -X POST "\${BAO}/v1/auth/approle/login" \\
    -H 'Content-Type: application/json' \\
    -d "{\"role_id\":\"\${ROLE_ID}\",\"secret_id\":\"\${SECRET_ID}\"}" \\
    | jq -r '.auth.client_token')

  # [2] 加密
  PLAIN_B64=\$(echo -n "hello-world" | base64)
  CIPHER=\$(curl -sf -X POST "\${BAO}/v1/\${MOUNT}/encrypt/\${KEY}" \\
    -H "X-Vault-Token: \${TOKEN}" \\
    -d "{\"plaintext\":\"\${PLAIN_B64}\"}" \\
    | jq -r '.data.ciphertext')
  echo "密文: \${CIPHER}"

  # [3] 解密
  RESULT=\$(curl -sf -X POST "\${BAO}/v1/\${MOUNT}/decrypt/\${KEY}" \\
    -H "X-Vault-Token: \${TOKEN}" \\
    -d "{\"ciphertext\":\"\${CIPHER}\"}" \\
    | jq -r '.data.plaintext' | base64 -d)
  echo "明文: \${RESULT}"


--------------------------------------------------------------------------------
  4.2  Go (使用 openbao/api SDK)
--------------------------------------------------------------------------------

  import (
      "context"
      "encoding/base64"
      "fmt"
      "os"

      "github.com/openbao/openbao/api"
      "github.com/openbao/openbao/api/auth/approle"
  )

  func main() {
      // 初始化客户端
      client, err := api.NewClient(&api.Config{
          Address: os.Getenv("OPENBAO_ADDR"),
      })
      if err != nil { panic(err) }

      // 登录
      secret, err := client.LogonWithContext(context.Background(),
          &approle.AppRoleLogin{
              RoleID:   os.Getenv("OPENBAO_ROLE_ID"),
              SecretID: os.Getenv("OPENBAO_SECRET_ID"),
          })
      if err != nil { panic(err) }
      client.SetToken(secret.Auth.ClientToken)

      // 加密
      plaintext := base64.StdEncoding.EncodeToString([]byte("sensitive-data"))
      encResp, err := client.Logical().Write("${TRANSIT_MOUNT}/encrypt/${APP_NAME}",
          map[string]interface{}{"plaintext": plaintext})
      if err != nil { panic(err) }
      ciphertext := encResp.Data["ciphertext"].(string)
      fmt.Println("密文:", ciphertext)

      // 解密
      decResp, err := client.Logical().Write("${TRANSIT_MOUNT}/decrypt/${APP_NAME}",
          map[string]interface{}{"ciphertext": ciphertext})
      if err != nil { panic(err) }
      raw := decResp.Data["plaintext"].(string)
      decoded, _ := base64.StdEncoding.DecodeString(raw)
      fmt.Println("明文:", string(decoded))
  }

  依赖:  go get github.com/openbao/openbao/api github.com/openbao/openbao/api/auth/approle


--------------------------------------------------------------------------------
  4.3  Python (使用 hvac 库)
--------------------------------------------------------------------------------

  import base64
  import hvac
  import os

  # 初始化客户端
  client = hvac.Client(url=os.environ["OPENBAO_ADDR"])

  # AppRole 登录
  client.auth.approle.login(
      role_id=os.environ["OPENBAO_ROLE_ID"],
      secret_id=os.environ["OPENBAO_SECRET_ID"],
  )

  # 加密
  plaintext_b64 = base64.b64encode(b"sensitive-data").decode()
  enc = client.secrets.transit.encrypt_data(
      name="${APP_NAME}",
      mount_point="${TRANSIT_MOUNT}",
      plaintext=plaintext_b64,
  )
  ciphertext = enc["data"]["ciphertext"]
  print(f"密文: {ciphertext}")

  # 解密
  dec = client.secrets.transit.decrypt_data(
      name="${APP_NAME}",
      mount_point="${TRANSIT_MOUNT}",
      ciphertext=ciphertext,
  )
  plaintext = base64.b64decode(dec["data"]["plaintext"]).decode()
  print(f"明文: {plaintext}")

  依赖:  pip install hvac


--------------------------------------------------------------------------------
  4.4  Java (Spring Boot + RestTemplate)
--------------------------------------------------------------------------------

  @Service
  public class OpenBaoKmsService {
      private static final String BAO_ADDR = "${BAO_ADDR}";
      private static final String KEY_NAME = "${APP_NAME}";
      private static final String MOUNT    = "${TRANSIT_MOUNT}";

      private final RestTemplate rest = new RestTemplate();
      private String token;

      // 登录获取 Token
      public void login(String roleId, String secretId) {
          String url = BAO_ADDR + "/v1/auth/approle/login";
          Map<String, String> body = Map.of(
              "role_id", roleId, "secret_id", secretId);
          var resp = rest.postForObject(url, body, Map.class);
          this.token = ((Map<String, Object>)
              ((Map<String, Object>) resp.get("auth")).get("client_token"))
              .toString();
      }

      // 加密
      public String encrypt(String plaintext) {
          String url = BAO_ADDR + "/v1/" + MOUNT + "/encrypt/" + KEY_NAME;
          String b64 = Base64.getEncoder().encodeToString(plaintext.getBytes());
          HttpHeaders headers = new HttpHeaders();
          headers.set("X-Vault-Token", token);
          var resp = rest.exchange(url, HttpMethod.POST,
              new HttpEntity<>(Map.of("plaintext", b64), headers),
              Map.class).getBody();
          return ((Map<String, String>) resp.get("data")).get("ciphertext");
      }

      // 解密
      public String decrypt(String ciphertext) {
          String url = BAO_ADDR + "/v1/" + MOUNT + "/decrypt/" + KEY_NAME;
          HttpHeaders headers = new HttpHeaders();
          headers.set("X-Vault-Token", token);
          var resp = rest.exchange(url, HttpMethod.POST,
              new HttpEntity<>(Map.of("ciphertext", ciphertext), headers),
              Map.class).getBody();
          String b64 = ((Map<String, String>) resp.get("data")).get("plaintext");
          return new String(Base64.getDecoder().decode(b64));
      }
  }


################################################################################
#                                                                              #
#                    5. 一键验证脚本                                            #
#                                                                              #
################################################################################

  复制以下整段脚本保存为 verify-kms.sh，执行 bash verify-kms.sh 即可验证。

  #!/usr/bin/env bash
  set -euo pipefail

  BAO="${BAO_ADDR}"
  ROLE_ID="${ROLE_ID}"
  SECRET_ID="${SECRET_ID}"

  echo "[1/4] 登录 OpenBao..."
  TOKEN=\$(curl -sf -X POST "\${BAO}/v1/auth/approle/login" \\
    -H 'Content-Type: application/json' \\
    -d "{\"role_id\":\"\${ROLE_ID}\",\"secret_id\":\"\${SECRET_ID}\"}" \\
    | jq -r '.auth.client_token')
  echo "  -> OK, Token: \${TOKEN:0:20}..."

  echo "[2/4] 加密测试..."
  TEST_DATA="kms-verify-\$(date +%s)"
  PLAIN_B64=\$(echo -n "\${TEST_DATA}" | base64)
  CIPHER=\$(curl -sf -X POST "\${BAO}/v1/${TRANSIT_MOUNT}/encrypt/${APP_NAME}" \\
    -H "X-Vault-Token: \${TOKEN}" \\
    -H 'Content-Type: application/json' \\
    -d "{\"plaintext\":\"\${PLAIN_B64}\"}" \\
    | jq -r '.data.ciphertext')
  echo "  -> OK, 密文: \${CIPHER}"

  echo "[3/4] 解密测试..."
  RESULT_B64=\$(curl -sf -X POST "\${BAO}/v1/${TRANSIT_MOUNT}/decrypt/${APP_NAME}" \\
    -H "X-Vault-Token: \${TOKEN}" \\
    -H 'Content-Type: application/json' \\
    -d "{\"ciphertext\":\"\${CIPHER}\"}" \\
    | jq -r '.data.plaintext')
  RESULT=\$(echo -n "\${RESULT_B64}" | base64 -d)
  echo "  -> OK, 明文: \${RESULT}"

  echo "[4/4] 一致性校验..."
  if [[ "\${RESULT}" == "\${TEST_DATA}" ]]; then
    echo "  -> [PASS] KMS 加解密验证通过!"
  else
    echo "  -> [FAIL] 验证失败! 期望: \${TEST_DATA}, 实际: \${RESULT}"
    exit 1
  fi


================================================================================
  6. 权限边界 (策略: ${POLICY_NAME})
================================================================================

  允许的操作:
    [OK]  POST  ${TRANSIT_MOUNT}/encrypt/${APP_NAME}     加密数据
    [OK]  POST  ${TRANSIT_MOUNT}/decrypt/${APP_NAME}     解密数据
    [OK]  GET   ${TRANSIT_MOUNT}/keys/${APP_NAME}        读取密钥元信息${ALLOW_ROTATE:+
    [OK]  POST  ${TRANSIT_MOUNT}/keys/${APP_NAME}/rotate   轮转密钥}

  禁止的操作 (示例):
    [NO]  DELETE  ${TRANSIT_MOUNT}/keys/${APP_NAME}           删除密钥
    [NO]  GET     ${TRANSIT_MOUNT}/keys/${APP_NAME}/export    导出密钥材料
    [NO]  POST    ${TRANSIT_MOUNT}/encrypt/<其他应用名>        加密其他应用数据
    [NO]  PUT     sys/policies/*                              修改策略

  核心原则: 应用永远不持有加密密钥本身，密钥完全由 OpenBao 管理。


================================================================================
  7. 安全须知
================================================================================

  [!] Role ID 和 Secret ID 属于敏感凭据，必须妥善保管:

  1. 禁止将凭据写入代码、提交到 Git 或打印到日志
  2. 使用 .env + .gitignore 或配置中心 (Consul KV / Nacos / K8s Secret) 存储
  3. Secret ID 如疑似泄露，立即联系管理员重新生成:
       bao write -f auth/approle/role/${APP_NAME}/secret-id
  4. Token 过期处理:
     - 有效期内调用 POST /v1/auth/token/renew-self 续期
     - 过期后使用 role-id + secret-id 重新调用登录接口
  5. 生产环境建议:
     - 启用 TLS (BAO_ADDR 使用 https://)
     - 设置 secret_id_num_uses > 0 限制使用次数
     - 定期轮转 Secret ID
     - 在应用端缓存 Token，避免每次加解密都重新登录


================================================================================
  管理员信息
================================================================================

  服务地址:    ${BAO_ADDR}
  交付时间:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')
  应用名称:    ${APP_NAME}
  策略名称:    ${POLICY_NAME}
  操作人:      $(whoami)@$(hostname)

################################################################################
#  本文件由 setup-approle-transit.sh 自动生成
#  重新生成: ./setup-approle-transit.sh --app ${APP_NAME} --output-dir <目录> --force
################################################################################
DELIVERY_EOF
}

_generate_delivery_file > "${DELIVERY_FILE}"
chmod 600 "${DELIVERY_FILE}"
echo ""
log_info "凭据交付文件已生成: ${DELIVERY_FILE}"
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  凭据交付文件 (可发送给应用调用方)${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
cat "${DELIVERY_FILE}"

# ========================== 应用端操作示例 =====================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  应用端操作示例${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""

echo -e "${BOLD}[1] 环境变量配置${NC}"
echo -e "${CYAN}────────────────────────────────────────────────${NC}"
cat <<EOF
export OPENBAO_ADDR="${BAO_ADDR}"
export OPENBAO_NAMESPACE="${NAMESPACE:-}"
export OPENBAO_ROLE_ID="${ROLE_ID}"
export OPENBAO_SECRET_ID="${SECRET_ID}"
export OPENBAO_TRANSIT_KEY="${APP_NAME}"
EOF
echo ""

echo -e "${BOLD}[2] 应用登录获取 Token${NC}"
echo -e "${CYAN}────────────────────────────────────────────────${NC}"
cat <<EOF
TOKEN=\$(bao write auth/approle/login \\
  role_id="\${OPENBAO_ROLE_ID}" \\
  secret_id="\${OPENBAO_SECRET_ID}" \\
  -field=token)

export BAO_TOKEN="\${TOKEN}"
echo "App Token: \${TOKEN}"
EOF
echo ""

echo -e "${BOLD}[3] 加密数据${NC}"
echo -e "${CYAN}────────────────────────────────────────────────${NC}"
cat <<EOF
# 加密明文 (需 base64 编码)
CIPHERTEXT=\$(echo -n "sensitive-data-12345" | base64 | \\
  bao write ${TRANSIT_MOUNT}/encrypt/${APP_NAME} plaintext=- \\
  -field=ciphertext)

echo "密文: \${CIPHERTEXT}"
EOF
echo ""

echo -e "${BOLD}[4] 解密数据${NC}"
echo -e "${CYAN}────────────────────────────────────────────────${NC}"
cat <<EOF
# 解密密文
PLAINTEXT=\$(bao write ${TRANSIT_MOUNT}/decrypt/${APP_NAME} \\
  ciphertext="\${CIPHERTEXT}" \\
  -field=plaintext | base64 -d)

echo "明文: \${PLAINTEXT}"
EOF
echo ""

echo -e "${BOLD}[5] 一键验证 (复制以下整段执行)${NC}"
echo -e "${CYAN}────────────────────────────────────────────────${NC}"
cat <<'VERIFY_EOF'
# ---- 快速验证开始 ----
ROLE_ID="__ROLE_ID__"
SECRET_ID="__SECRET_ID__"

# 登录
TOKEN=$(bao write auth/approle/login \
  role_id=$ROLE_ID secret_id=$SECRET_ID -field=token)
echo "[OK] 登录成功, Token: ${TOKEN:0:20}..."

export BAO_TOKEN=$TOKEN

# 加密
CIPHER=$(echo -n "hello-openbao" | base64 | \
  bao write __TRANSIT_MOUNT__/encrypt/__APP_NAME__ plaintext=- -field=ciphertext)
echo "[OK] 加密成功: ${CIPHER}"

# 解密
RESULT=$(bao write __TRANSIT_MOUNT__/decrypt/__APP_NAME__ \
  ciphertext="$CIPHER" -field=plaintext | base64 -d)
echo "[OK] 解密成功: ${RESULT}"

# 验证一致性
if [[ "${RESULT}" == "hello-openbao" ]]; then
  echo "[PASS] 加解密验证通过!"
else
  echo "[FAIL] 加解密验证失败! 期望: hello-openbao, 实际: ${RESULT}"
fi
# ---- 快速验证结束 ----
VERIFY_EOF

# 输出替换后的验证脚本
echo ""
echo -e "${BOLD}[5-实际] 替换变量后的验证脚本${NC}"
echo -e "${CYAN}────────────────────────────────────────────────${NC}"
cat <<EOF
# ---- 快速验证开始 ----
ROLE_ID="${ROLE_ID}"
SECRET_ID="${SECRET_ID}"

# 登录
TOKEN=\$(bao write auth/approle/login \\
  role_id=\$ROLE_ID secret_id=\$SECRET_ID -field=token)
echo "[OK] 登录成功, Token: \${TOKEN:0:20}..."

export BAO_TOKEN=\$TOKEN

# 加密
CIPHER=\$(echo -n "hello-openbao" | base64 | \\
  bao write ${TRANSIT_MOUNT}/encrypt/${APP_NAME} plaintext=- -field=ciphertext)
echo "[OK] 加密成功: \${CIPHER}"

# 解密
RESULT=\$(bao write ${TRANSIT_MOUNT}/decrypt/${APP_NAME} \\
  ciphertext="\$CIPHER" -field=plaintext | base64 -d)
echo "[OK] 解密成功: \${RESULT}"

# 验证一致性
if [[ "\${RESULT}" == "hello-openbao" ]]; then
  echo "[PASS] 加解密验证通过!"
else
  echo "[FAIL] 加解密验证失败! 期望: hello-openbao, 实际: \${RESULT}"
fi
# ---- 快速验证结束 ----
EOF

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  管理命令参考${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
cat <<EOF
# 查看密钥信息
bao read ${TRANSIT_MOUNT}/keys/${APP_NAME}

# 轮转密钥 (需 --allow-rotate)
bao write -f ${TRANSIT_MOUNT}/keys/${APP_NAME}/rotate

# 重新生成 Secret ID (撤销旧的)
bao write -f auth/approle/role/${APP_NAME}/secret-id

# 撤销指定 Secret ID
bao write auth/approle/role/${APP_NAME}/secret-id/destroy \\
  secret_id="<old-secret-id>"

# 查看 AppRole 角色配置
bao read auth/approle/role/${APP_NAME}

# 查看策略
bao policy read ${POLICY_NAME}

# 删除角色 (谨慎!)
bao delete auth/approle/role/${APP_NAME}

# 删除密钥 (需先开启 deletion_allowed)
bao write ${TRANSIT_MOUNT}/keys/${APP_NAME}/config deletion_allowed=true
bao delete ${TRANSIT_MOUNT}/keys/${APP_NAME}
EOF

echo ""
echo -e "${GREEN}${BOLD}配置完成! 请妥善保存 Role ID 和 Secret ID。${NC}"
echo ""
