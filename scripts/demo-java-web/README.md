# OpenBao Java Web Demo — Transit 加密解密实战

基于 Spring Boot 3 的 Java Web 应用，通过 OpenBao Transit 引擎实现 **Encryption-as-a-Service（加密即服务）**。

---

## 一、架构总览

```
                    ┌─────────────────────────────────────────────┐
                    │            OpenBao Server                   │
                    │                                             │
                    │  ┌─────────────────────────────────────┐    │
  Java App ────────▶  │   Transit Secrets Engine            │    │
  (Spring Boot)       │                                     │    │
                      │   密钥管理: AES-256-GCM              │    │
                      │   密钥轮转: 自动 (OpenBao 侧配置)    │    │
                      │   API: /transit/encrypt/app-key      │    │
                      │        /transit/decrypt/app-key      │    │
                      └─────────────────────────────────────┘    │
                    │                                             │
                    │  认证: AppRole (role-id + secret-id)        │
                    │  策略: 最小权限 (只允许 encrypt/decrypt)     │
                    └─────────────────────────────────────────────┘

  Java App                    Database (H2/MySQL/PG)
  ────────                    ─────────────────────
  POST /api/store ──加密──▶   INSERT (只存密文 vault:v1:xxx)
  GET  /api/read  ──解密──▶   SELECT → OpenBao 解密 → 返回明文
```

**核心原则：应用不持有加密密钥，密钥完全由 OpenBao 管理。**

---

## 二、项目结构

```
demo-java-web/
├── pom.xml                                          # Maven 依赖 (Spring Boot 3.3 + Spring Vault)
├── README.md                                        # 本文档
└── src/main/
    ├── java/com/example/openbaodemo/
    │   ├── OpenBaoTransitDemoApplication.java       # Spring Boot 启动类
    │   ├── config/
    │   │   ├── OpenBaoProperties.java               # 配置属性映射
    │   │   └── OpenBaoConfig.java                   # VaultTemplate Bean (支持 Token/AppRole)
    │   ├── service/
    │   │   └── TransitService.java                  # 核心: 加密 / 解密 / 批量加密
    │   ├── controller/
    │   │   └── TransitController.java               # REST API (5 个端点)
    │   ├── entity/
    │   │   └── EncryptedData.java                   # JPA 实体 (数据库只存密文)
    │   ├── repository/
    │   │   └── EncryptedDataRepository.java         # JPA Repository
    │   └── dto/                                     # 请求/响应 DTO (Java Record)
    │       ├── EncryptRequest / EncryptResponse
    │       ├── DecryptRequest / DecryptResponse
    │       ├── StoreRequest / StoreResponse
    │       └── ReadResponse
    └── resources/
        └── application.yml                          # 配置文件 (支持环境变量覆盖)
```

---

## 三、完整操作流程

### 阶段 1：OpenBao 侧准备（管理员操作，仅首次）

```bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1.1: 登录 OpenBao
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
export BAO_ADDR=http://127.0.0.1:8200
bao login
# 输入 Root Token

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1.2: 启用 Transit 引擎
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
bao secrets enable transit
# Success! Enabled the transit secrets engine at: transit/

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1.3: 创建加密密钥 (AES-256-GCM, 默认)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
bao write -f transit/keys/app-key type=aes256-gcm96
# Success! Data written to: transit/keys/app-key

# 验证密钥已创建
bao read transit/keys/app-key
# Key                   Value
# ---                   -----
# type                  aes256-gcm96       ← 加密算法
# latest_version        1                  ← 当前密钥版本
# min_decryption_version 1                 ← 最低可解密版本

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1.4: 创建应用专用策略 (最小权限)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
bao policy write app-transit-policy - <<'POLICY'
# 允许加密
path "transit/encrypt/app-key" {
  capabilities = ["update"]
}

# 允许解密
path "transit/decrypt/app-key" {
  capabilities = ["update"]
}

# 允许读取密钥元信息 (不能读取密钥本身)
path "transit/keys/app-key" {
  capabilities = ["read"]
}
POLICY

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1.5: 创建 AppRole 认证 (应用凭据)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
bao auth enable approle

bao write auth/approle/role/java-app \
  token_policies="app-transit-policy" \
  token_ttl=1h \
  token_max_ttl=4h

# 获取 role_id (固定值, 写入应用配置)
bao read auth/approle/role/java-app/role-id
# Key        Value
# ---        -----
# role_id    a1b2c3d4-e5f6-7890-abcd-ef1234567890    ← 记下来

# 获取 secret_id (敏感, 类似密码)
bao write -f auth/approle/role/java-app/secret-id
# Key           Value
# ---           -----
# secret_id     x9y8z7w6-v5u4-3210-dcba-0987654321fe  ← 记下来
```

### 阶段 2：启动 Java 应用

```bash
cd scripts/demo-java-web

# 方式 A: 使用 AppRole 认证 (推荐, 生产环境)
export OPENBAO_ADDR=http://127.0.0.1:8200
export OPENBAO_AUTH_METHOD=approle
export OPENBAO_ROLE_ID=a1b2c3d4-e5f6-7890-abcd-ef1234567890
export OPENBAO_SECRET_ID=x9y8z7w6-v5u4-3210-dcba-0987654321fe
export OPENBAO_TRANSIT_KEY=app-key

./mvnw spring-boot:run

# 方式 B: 使用 Token 认证 (仅开发环境)
export OPENBAO_AUTH_METHOD=token
export OPENBAO_TOKEN=hvs.CAESIxxxxxxxxx...
./mvnw spring-boot:run
```

启动成功后日志输出：
```
INFO  OpenBao 连接配置: uri=http://127.0.0.1:8200, auth=approle, transit-key=app-key
INFO  Tomcat started on port 8080
INFO  Started OpenBaoTransitDemoApplication
```

### 阶段 3：API 测试

#### 3.1 纯加密/解密

```bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 加密: 明文 → 密文
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
curl -s -X POST http://localhost:8080/api/encrypt \
  -H "Content-Type: application/json" \
  -d '{"plaintext": "Hello OpenBao!"}' | python3 -m json.tool

# 输出:
# {
#     "ciphertext": "vault:v1:abcdef1234567890..."
# }

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 解密: 密文 → 明文
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
curl -s -X POST http://localhost:8080/api/decrypt \
  -H "Content-Type: application/json" \
  -d '{"ciphertext": "vault:v1:abcdef1234567890..."}' | python3 -m json.tool

# 输出:
# {
#     "plaintext": "Hello OpenBao!"
# }
```

#### 3.2 加密存储 + 解密读取（核心场景）

```bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 存储: 明文 → OpenBao 加密 → 密文存入数据库
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 存储数据库密码
curl -s -X POST http://localhost:8080/api/store \
  -H "Content-Type: application/json" \
  -d '{"key": "db-password", "value": "SuperSecret123!"}' | python3 -m json.tool

# 输出:
# {
#     "key": "db-password",
#     "encryptedValue": "vault:v1:8SDd3WHDOjf7mq69Cy...",
#     "message": "数据已加密存储，数据库中仅保存密文"
# }

# 存储 API 密钥
curl -s -X POST http://localhost:8080/api/store \
  -H "Content-Type: application/json" \
  -d '{"key": "api-key", "value": "sk-abc123def456"}' | python3 -m json.tool

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 读取: 数据库密文 → OpenBao 解密 → 返回明文
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
curl -s http://localhost:8080/api/read/db-password | python3 -m json.tool

# 输出:
# {
#     "key": "db-password",
#     "value": "SuperSecret123!",           ← 解密后的明文
#     "encryptedValue": "vault:v1:8SDd3..." ← 数据库中的密文
# }
```

#### 3.3 验证数据库中确实只有密文

```bash
# 直接查询数据库 (H2 Console: http://localhost:8080/h2-console)
# JDBC URL: jdbc:h2:mem:testdb, User: sa, Password: (空)
# SQL:
SELECT * FROM encrypted_data;

# ID | DATA_KEY      | ENCRYPTED_VALUE                    | CREATED_AT
# ---+---------------+------------------------------------+-------------------
# 1  | db-password   | vault:v1:8SDd3WHDOjf7mq69Cy...    | 2026-07-27 14:30:00
# 2  | api-key       | vault:v1:Kfj8sLm2nPqRs4TuVw...    | 2026-07-27 14:30:05

# ✅ 数据库管理员看到的都是密文，无法得知明文
```

---

## 四、数据流详解

### 加密存储流程

```
客户端                     Java App                    OpenBao                 Database
  │                          │                           │                       │
  │  POST /api/store         │                           │                       │
  │  {"key":"db-pwd",        │                           │                       │
  │   "value":"Secret123"}   │                           │                       │
  │─────────────────────────▶│                           │                       │
  │                          │                           │                       │
  │                          │  POST /transit/encrypt    │                       │
  │                          │  {"plaintext":"U2Vj..."}  │ (Base64编码)          │
  │                          │──────────────────────────▶│                       │
  │                          │                           │                       │
  │                          │  {"ciphertext":"vault:v1:xxx"}                    │
  │                          │◀──────────────────────────│                       │
  │                          │                           │                       │
  │                          │  INSERT encrypted_data    │                       │
  │                          │  (data_key, "vault:v1:xxx")                       │
  │                          │──────────────────────────────────────────────────▶│
  │                          │                           │                       │
  │  {"key":"db-pwd",        │                           │                       │
  │   "encryptedValue":      │                           │                       │
  │    "vault:v1:xxx"}       │                           │                       │
  │◀─────────────────────────│                           │                       │
```

### 解密读取流程

```
客户端                     Java App                    OpenBao                 Database
  │                          │                           │                       │
  │  GET /api/read/db-pwd    │                           │                       │
  │─────────────────────────▶│                           │                       │
  │                          │                           │                       │
  │                          │  SELECT encrypted_data    │                       │
  │                          │  WHERE data_key='db-pwd'  │                       │
  │                          │──────────────────────────────────────────────────▶│
  │                          │                           │                       │
  │                          │  {"encrypted_value":      │                       │
  │                          │   "vault:v1:xxx"}         │                       │
  │                          │◀──────────────────────────────────────────────────│
  │                          │                           │                       │
  │                          │  POST /transit/decrypt    │                       │
  │                          │  {"ciphertext":"vault:v1:xxx"}                    │
  │                          │──────────────────────────▶│                       │
  │                          │                           │                       │
  │                          │  {"plaintext":"U2Vj..."}  │ (Base64编码)          │
  │                          │◀──────────────────────────│                       │
  │                          │                           │                       │
  │  {"key":"db-pwd",        │                           │                       │
  │   "value":"Secret123",   │                           │                       │
  │   "encryptedValue":      │                           │                       │
  │    "vault:v1:xxx"}       │                           │                       │
  │◀─────────────────────────│                           │                       │
```

---

## 五、安全特性

| 特性 | 说明 |
|------|------|
| **密钥零暴露** | Java 应用永远不接触加密密钥，密钥完全由 OpenBao 管理 |
| **最小权限** | AppRole 策略只授予 encrypt/decrypt 权限，不能导出密钥 |
| **自动轮转** | OpenBao 侧配置密钥轮转策略，应用代码无需修改 |
| **密文版本化** | 密文格式 `vault:v1:xxx` 包含密钥版本号，支持多版本解密 |
| **数据库安全** | DBA 看到的都是密文，无法获取明文数据 |
| **认证隔离** | AppRole 有 TTL，Token 过期自动失效 |

---

## 六、生产环境注意事项

### 6.1 配置文件安全

```yaml
# application.yml (生产环境通过环境变量注入, 不写死)
openbao:
  uri: ${OPENBAO_ADDR}              # 从环境变量读取
  approle:
    role-id: ${OPENBAO_ROLE_ID}     # 从 K8s Secret / Vault Agent 注入
    secret-id: ${OPENBAO_SECRET_ID} # 从 K8s Secret / Vault Agent 注入
```

### 6.2 密钥轮转

```bash
# 在 OpenBao 侧轮转密钥 (应用无感知)
bao write -f transit/keys/app-key/rotate

# 查看轮转后的版本
bao read transit/keys/app-key
# latest_version: 2    ← 新数据使用 v2 加密
# min_decryption_version: 1   ← v1 的旧密文仍可解密

# 用新版本重新加密已有数据 (密文版本从 v1 升级为 v2)
# bao 支持 /transit/rewrap 端点批量升级
curl -X POST http://localhost:8080/api/rewrap \
  -H "Content-Type: application/json" \
  -d '{"key": "db-password"}'
```

### 6.3 Kubernetes 部署

在 K8s 中推荐使用 **Vault Agent Sidecar** 自动注入 AppRole 凭据，避免将 secret_id 写入 Secret：

```yaml
# Pod 注解 (Vault Agent Injector)
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "java-app"
  vault.hashicorp.com/agent-inject-secret-approle: "auth/approle/role/java-app/role-id"
```

---

## 七、故障排查

| 问题 | 原因 | 解决 |
|------|------|------|
| `403 permission denied` | AppRole 策略权限不足 | 检查 policy 是否绑定了 encrypt/decrypt 路径 |
| `encryption key not found` | Transit 密钥未创建 | `bao write -f transit/keys/app-key` |
| `invalid ciphertext` | 密文格式错误 | 确认以 `vault:v` 开头 |
| `connection refused` | OpenBao 服务未运行 | `systemctl status openbao` |
| `client token expired` | AppRole Token 过期 | 应用重启获取新 Token |

```bash
# 快速诊断
curl -s http://127.0.0.1:8200/v1/sys/health | python3 -m json.tool  # OpenBao 健康
curl -s http://localhost:8080/api/health | python3 -m json.tool       # Java 应用健康
```
