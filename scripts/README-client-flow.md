# OpenBao 客户端加解密完整流程

从身份认证到数据加解密，一个客户端应用与 OpenBao 交互的完整生命周期。

---

## 一、全局流程总览

```
┌──────────┐                    ┌──────────────────────────────────────────┐                    ┌──────────┐
│  客户端   │                    │              OpenBao Server              │                    │  数据库   │
│  (应用)   │                    │                                          │                    │  (存储)   │
└────┬─────┘                    └──────────────────┬───────────────────────┘                    └──────────┘
     │                                             │
     │  ┌─── 阶段1: 认证 (Authentication) ───┐     │
     │  │  我是谁? → 验证身份 → 发放 Token   │     │
     │  └─────────────────────────────────────┘     │
     │                                             │
     │  ┌─── 阶段2: 授权 (Authorization) ────┐     │
     │  │  Token → 查策略 → 能做什么?         │     │
     │  └─────────────────────────────────────┘     │
     │                                             │
     │  ┌─── 阶段3: 操作 (Operations) ───────┐     │
     │  │  加密 / 解密 / 读取密钥 / 写入Secret │     │
     │  └─────────────────────────────────────┘     │
     │                                             │
```

---

## 二、阶段详解

### 阶段 1：认证 — "我是谁？"

客户端必须先证明自己的身份，OpenBao 验证通过后发放一个**临时 Token**。

```
┌─────────────┐                    ┌──────────────────────┐                    ┌──────────────┐
│  Java App   │                    │    OpenBao           │                    │  身份源      │
│             │                    │                      │                    │ (LDAP/K8s/   │
│             │                    │   Auth Methods:      │                    │  OIDC/AWS)   │
│             │                    │   ┌──────────────┐   │                    │              │
│  ① 提交凭据 │───────────────────▶│   │ AppRole      │   │                    │              │
│  role-id    │  POST /v1/auth/    │   │ LDAP         │   │                    │              │
│  secret-id  │  approle/login     │   │ Kubernetes   │   │  ② 验证凭据        │              │
│             │                    │   │ JWT/OIDC     │   │──────────────────▶ │              │
│             │                    │   │ Userpass     │   │                    │              │
│             │                    │   │ AWS IAM      │   │  ③ 验证通过        │              │
│             │                    │   └──────────────┘   │◀────────────────── │              │
│             │                    │                      │                    │              │
│  ④ 获得Token│◀───────────────────│  返回:              │                    │              │
│  token      │                    │  {                  │                    │              │
│  (临时,     │                    │    "auth": {        │                    │              │
│   有过期)   │                    │      "client_token":│                    │              │
│             │                    │       "hvs.CAESI...",                    │              │
│             │                    │      "policies": [  │                    │              │
│             │                    │        "app-policy" │                    │              │
│             │                    │      ],             │                    │              │
│             │                    │      "ttl": 3600,   │                    │              │
│             │                    │      "renewable":   │                    │              │
│             │                    │       true          │                    │              │
│             │                    │    }                │                    │              │
│             │                    │  }                  │                    │              │
└─────────────┘                    └──────────────────────┘                    └──────────────┘
```

**关键概念：**
- Token 是临时的（默认 1 小时 TTL），可续期
- Token 绑定了**策略 (Policy)**，决定了能做什么
- 凭据泄露的风险窗口 = Token 的 TTL

### 阶段 2：授权 — "我能做什么？"

OpenBao 根据 Token 绑定的策略 (Policy) 判断每次请求是否允许。

```
┌─────────────┐                    ┌──────────────────────────────────────────────────────┐
│  Java App   │                    │                    OpenBao                            │
│             │                    │                                                      │
│  ⑤ 发起请求 │  POST /v1/transit/encrypt/app-key     │                                                      │
│  + Token    │──────────────────▶ │  ┌────────────────────────────────────────────────┐  │
│  X-Vault-   │  Headers:          │  │  授权检查流程:                                  │  │
│  Token: hvs │  X-Vault-Token     │  │                                                │  │
│  .CAESI...  │                    │  │  1. 解析 Token → 获取绑定的策略列表            │  │
│             │                    │  │     Token → ["app-transit-policy"]              │  │
│             │                    │  │                                                │  │
│             │                    │  │  2. 加载策略内容:                               │  │
│             │                    │  │     path "transit/encrypt/app-key" {            │  │
│             │                    │  │       capabilities = ["update"]                │  │
│             │                    │  │     }                                          │  │
│             │                    │  │                                                │  │
│             │                    │  │  3. 匹配: 请求路径 "transit/encrypt/app-key"   │  │
│             │                    │  │         请求方法 POST (= update)               │  │
│             │                    │  │         策略允许 ["update"]                    │  │
│             │                    │  │                                                │  │
│             │                    │  │  4. 结果: ✅ 授权通过                           │  │
│             │                    │  └────────────────────────────────────────────────┘  │
│             │                    │                                                      │
└─────────────┘                    └──────────────────────────────────────────────────────┘

策略匹配失败时:
  → 返回 403 Permission Denied
  → 记录审计日志 (如果启用了 Audit)
```

**策略 (Policy) 示例：**

```hcl
# app-transit-policy.hcl
# 允许加密
path "transit/encrypt/app-key" {
  capabilities = ["update"]
}

# 允许解密
path "transit/decrypt/app-key" {
  capabilities = ["update"]
}

# 允许读取密钥元信息 (版本、类型, 不含密钥本身)
path "transit/keys/app-key" {
  capabilities = ["read"]
}

# 允许读取 KV 密钥
path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}

# 禁止删除 (显式拒绝)
path "transit/keys/app-key" {
  capabilities = ["deny"]  # 不能修改/删除密钥
}
```

### 阶段 3：操作 — "加密/解密数据"

授权通过后，OpenBao 执行实际的加密/解密操作。

---

## 三、完整交互时序图

以 **Java Web 应用使用 Transit 引擎加密用户密码并存入数据库** 为例：

```
 用户浏览器       Java Web App            OpenBao                    MySQL数据库
     │               │                       │                          │
     │  注册请求      │                       │                          │
     │  POST /register                       │                          │
     │  {"username":  │                       │                          │
     │   "alice",     │                       │                          │
     │   "password":  │                       │                          │
     │   "P@ssw0rd!"} │                       │                          │
     │──────────────▶ │                       │                          │
     │               │                       │                          │
     │               │ ── 步骤A: 认证 ──────  │                          │
     │               │                       │                          │
     │               │  POST /v1/auth/       │                          │
     │               │  approle/login        │                          │
     │               │  {role_id, secret_id}  │                          │
     │               │──────────────────────▶│                          │
     │               │                       │                          │
     │               │  {"client_token":     │                          │
     │               │   "hvs.CAESI...",     │                          │
     │               │   "ttl": 3600}        │                          │
     │               │◀──────────────────────│                          │
     │               │                       │                          │
     │               │ ── 步骤B: 加密 ──────  │                          │
     │               │                       │                          │
     │               │  POST /v1/transit/    │                          │
     │               │  encrypt/app-key      │                          │
     │               │  Headers:             │                          │
     │               │    X-Vault-Token:     │                          │
     │               │      hvs.CAESI...     │                          │
     │               │  Body:                │                          │
     │               │  {"plaintext":        │                          │
     │               │   "UCkBhc3N3MHJkIQ=="} ← Base64("P@ssw0rd!")    │
     │               │──────────────────────▶│                          │
     │               │                       │                          │
     │               │                       │  ┌───────────────────┐   │
     │               │                       │  │ ① 验证Token      │   │
     │               │                       │  │ ② 检查Policy     │   │
     │               │                       │  │ ③ 加载 app-key   │   │
     │               │                       │  │    (AES-256-GCM) │   │
     │               │                       │  │ ④ AES加密明文    │   │
     │               │                       │  │ ⑤ 返回密文       │   │
     │               │                       │  └───────────────────┘   │
     │               │                       │                          │
     │               │  {"data": {           │                          │
     │               │    "ciphertext":      │                          │
     │               │    "vault:v1:8SDd3..." │                         │
     │               │  }}                   │                          │
     │               │◀──────────────────────│                          │
     │               │                       │                          │
     │               │ ── 步骤C: 存储 ──────  │                          │
     │               │                       │                          │
     │               │  INSERT INTO users    │                          │
     │               │  (username, password) │                          │
     │               │  VALUES               │                          │
     │               │  ('alice',            │                          │
     │               │   'vault:v1:8SDd3...')│                          │
     │               │─────────────────────────────────────────────────▶│
     │               │                       │                          │
     │               │  OK                   │                          │
     │               │◀─────────────────────────────────────────────────│
     │               │                       │                          │
     │  注册成功      │                       │                          │
     │  {"status":    │                       │                          │
     │   "ok"}        │                       │                          │
     │◀──────────────│                       │                          │
```

### 读取并解密流程

```
 用户浏览器       Java Web App            OpenBao                    MySQL数据库
     │               │                       │                          │
     │  查看个人信息   │                       │                          │
     │  GET /profile  │                       │                          │
     │──────────────▶ │                       │                          │
     │               │                       │                          │
     │               │  SELECT password      │                          │
     │               │  FROM users           │                          │
     │               │  WHERE username='alice'                          │
     │               │─────────────────────────────────────────────────▶│
     │               │                       │                          │
     │               │  "vault:v1:8SDd3..."  │                          │
     │               │◀─────────────────────────────────────────────────│
     │               │                       │                          │
     │               │  POST /v1/transit/    │                          │
     │               │  decrypt/app-key      │                          │
     │               │  {ciphertext:         │                          │
     │               │   "vault:v1:8SDd3..."}│                          │
     │               │──────────────────────▶│                          │
     │               │                       │                          │
     │               │                       │  ┌───────────────────┐   │
     │               │                       │  │ ① 解析版本号 v1  │   │
     │               │                       │  │ ② 加载 v1 密钥   │   │
     │               │                       │  │ ③ AES解密        │   │
     │               │                       │  │ ④ 返回明文       │   │
     │               │                       │  └───────────────────┘   │
     │               │                       │                          │
     │               │  {"data": {           │                          │
     │               │    "plaintext":       │                          │
     │               │    "UCkBhc3N3MHJkIQ=="}                          │
     │               │◀──────────────────────│                          │
     │               │                       │                          │
     │               │  Base64解码 → "P@ssw0rd!"                        │
     │               │                       │                          │
     │  返回信息      │                       │                          │
     │◀──────────────│                       │                          │
```

---

## 四、认证方式对比

不同客户端场景适用不同的认证方式：

```
┌────────────────┬────────────┬──────────────────────────────────────────┐
│ 客户端类型      │ 推荐认证    │ 说明                                     │
├────────────────┼────────────┼──────────────────────────────────────────┤
│ 服务器应用      │ AppRole    │ role-id + secret-id, 最常用             │
│ (Java/Go/Node) │            │ secret-id 可设使用次数限制 (一次性)      │
├────────────────┼────────────┼──────────────────────────────────────────┤
│ Kubernetes Pod │ K8s Auth   │ 用 Pod 的 ServiceAccount JWT 认证       │
│                │            │ 无需管理 secret-id, 最安全               │
├────────────────┼────────────┼──────────────────────────────────────────┤
│ 运维人员        │ LDAP/OIDC  │ 用企业账号登录, Token 绑定用户身份      │
│                │            │ 支持 MFA                                 │
├────────────────┼────────────┼──────────────────────────────────────────┤
│ CI/CD Pipeline │ JWT/GitHub │ 用 GitHub Actions / GitLab CI 的 Token  │
│                │            │ 自动获取 OpenBao Token                   │
├────────────────┼────────────┼──────────────────────────────────────────┤
│ 临时脚本/调试   │ Token      │ 手动创建的 Token, 短期使用              │
│                │            │ 不推荐生产环境                           │
└────────────────┴────────────┴──────────────────────────────────────────┘
```

---

## 五、Token 生命周期管理

```
  App 启动
     │
     │  ① 用 AppRole 登录
     │  POST /v1/auth/approle/login
     │  → 获得 Token (TTL=1h, renewable=true)
     │
     ▼
  Token 有效 ──────────────────────────────── 1h ──────────────────▶ Token 过期
     │                                                              │
     │  正常使用中...                                                │
     │                                                              │
     │  ② 定期续期 (每 30 分钟)                                     │
     │  POST /v1/auth/token/renew-self                             │
     │  → Token TTL 重置为 1h                                      │
     │  ←─── 30min ──→ 续期 ─── 30min ──→ 续期 ─── 30min ──→      │
     │                                                              │
     │  ③ 达到 max_ttl (4h)                                         │
     │  → 续期被拒绝                                                │
     │  → 必须重新用 AppRole 登录获取新 Token                       │
     │                                                              │
     │  ④ App 关闭                                                  │
     │  POST /v1/auth/token/revoke-self                            │
     │  → Token 立即失效                                            │
     ▼
```

**Java 应用中的 Token 管理：**

```java
// Spring Vault 自动处理 Token 续期
// 配置 periodic token (无 max_ttl, 可无限续期)
bao token create \
  -policy="app-policy" \
  -period="720h" \
  -renewable=true

// 或者 AppRole 配置长 TTL
bao write auth/approle/role/my-app \
  token_policies="app-policy" \
  token_ttl=1h \
  token_max_ttl=720h    // 最长 30 天
```

---

## 六、加密模式对比

OpenBao 提供两种加密使用模式：

### 模式 A：Transit 引擎 (Encryption-as-a-Service)

```
应用 ──▶ 发送明文 ──▶ OpenBao Transit 加密 ──▶ 返回密文 ──▶ 应用存储密文
应用 ──▶ 发送密文 ──▶ OpenBao Transit 解密 ──▶ 返回明文 ──▶ 应用使用明文

特点:
  ● 密钥在 OpenBao 中, 应用永远不接触密钥
  ● 密文格式: vault:v1:xxxxx (包含密钥版本号)
  ● 支持密钥自动轮转 (OpenBao 侧配置)
  ● 适合: 加密数据库字段、配置文件、API 密钥
```

### 模式 B：Datakey 模式 (信封加密, Envelope Encryption)

```
应用 ──▶ 请求 Datakey ──▶ OpenBao 生成随机密钥 ──▶ 返回:
                            ├─ plaintext_key (明文数据密钥)
                            └─ ciphertext_key (加密后的数据密钥)

应用用 plaintext_key 本地加密数据 (快!)
应用把 ciphertext_key + 密文 一起存储
应用丢弃 plaintext_key (不存储!)

读取时:
应用 ──▶ 发送 ciphertext_key ──▶ OpenBao 解密 ──▶ 返回 plaintext_key
应用用 plaintext_key 本地解密数据
应用丢弃 plaintext_key

特点:
  ● 加密/解密在应用本地完成 (不经过网络, 更快)
  ● 适合: 大文件加密、批量加密、离线加密
  ● OpenBao 只负责保护数据密钥, 不处理实际数据
```

```
Transit vs Datakey 选择:

数据量小 (< 1MB, 如密码/Token)?
  └── 用 Transit 直接加密

数据量大 (> 1MB, 如文件/日志)?
  └── 用 Datakey 信封加密 (避免大文件传输到 OpenBao)

高吞吐 (> 1000 QPS)?
  └── 用 Datakey (减少 OpenBao 网络调用)

需要集中管控密钥?
  └── 用 Transit (所有加密操作经过 OpenBao, 可审计)
```

---

## 七、审计日志

OpenBao 可以记录**每一次** API 调用（包括加解密），用于安全审计和合规。

```bash
# 启用文件审计
bao audit enable file file_path=/var/log/openbao/audit.log

# 每次 API 调用都会记录:
{
  "time": "2026-07-27T14:30:00Z",
  "type": "request",
  "auth": {
    "client_token": "hmac-sha256:abc123...",  // Token 被 HMAC 脱敏
    "token_type": "service",
    "policies": ["app-transit-policy"],
    "entity_id": "user-alice"                  // 关联到用户身份
  },
  "request": {
    "operation": "update",
    "path": "transit/encrypt/app-key",         // 谁在操作什么
    "data": {
      "plaintext": "hmac-sha256:xyz789..."    // 明文也被 HMAC 脱敏!
    }
  }
}
```

**审计日志保证：**
- 知道谁在什么时候加密/解密了什么
- 敏感数据（明文、Token）被 HMAC 脱敏，审计人员也看不到
- 满足等保、SOX、PCI-DSS 等合规要求

---

## 八、完整 Demo 命令参考

```bash
# ===== 管理员准备阶段 (一次性) =====

# 1. 启用 Transit 引擎
bao secrets enable transit

# 2. 创建加密密钥
bao write -f transit/keys/app-key type=aes256-gcm96

# 3. 创建策略
bao policy write app-policy - <<'POLICY'
path "transit/encrypt/app-key" { capabilities = ["update"] }
path "transit/decrypt/app-key" { capabilities = ["update"] }
path "transit/keys/app-key"    { capabilities = ["read"] }
path "secret/data/myapp/*"     { capabilities = ["read", "list"] }
POLICY

# 4. 创建 AppRole
bao auth enable approle
bao write auth/approle/role/java-app \
  token_policies="app-policy" \
  token_ttl=1h \
  token_max_ttl=720h

ROLE_ID=$(bao read -field=role_id auth/approle/role/java-app/role-id)
SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/java-app/secret-id)


# ===== 应用运行时 (自动化) =====

# 5. 认证: 获取 Token
TOKEN=$(curl -s http://127.0.0.1:8200/v1/auth/approle/login \
  -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" \
  | jq -r '.auth.client_token')

# 6. 加密
CIPHER=$(curl -s http://127.0.0.1:8200/v1/transit/encrypt/app-key \
  -H "X-Vault-Token: $TOKEN" \
  -d "{\"plaintext\":\"$(echo -n 'MySecretPassword' | base64)\"}" \
  | jq -r '.data.ciphertext')
echo "密文: $CIPHER"
# vault:v1:8SDd3WHDOjf7mq69CyCqYjBXAiQQAVZRkFM13ok481zoCmHnSeDX9vyf7w==

# 7. 解密
PLAIN=$(curl -s http://127.0.0.1:8200/v1/transit/decrypt/app-key \
  -H "X-Vault-Token: $TOKEN" \
  -d "{\"ciphertext\":\"$CIPHER\"}" \
  | jq -r '.data.plaintext' | base64 -d)
echo "明文: $PLAIN"
# MySecretPassword

# 8. 续期 Token
curl -s http://127.0.0.1:8200/v1/auth/token/renew-self \
  -H "X-Vault-Token: $TOKEN"

# 9. 退出时撤销 Token
curl -s http://127.0.0.1:8200/v1/auth/token/revoke-self \
  -H "X-Vault-Token: $TOKEN"
```

---

## 九、安全最佳实践清单

| 实践 | 说明 |
|------|------|
| **Token 短 TTL** | 设置 `token_ttl=1h`，定期续期，泄露影响窗口小 |
| **AppRole secret-id 一次性** | 设置 `secret_id_num_uses=1`，用后即焚 |
| **最小权限策略** | Policy 只授予必要的路径和操作 |
| **启用审计日志** | 记录所有 API 调用，满足合规 |
| **Token 不硬编码** | 从环境变量或 Vault Agent 注入，不写入代码/配置 |
| **密钥定期轮转** | Transit 密钥配置 `auto_rotate_period`，应用无感知 |
| **网络加密** | 应用与 OpenBao 之间使用 TLS (即使内网) |
| **IP 白名单** | 通过 Sentinel 策略限制 Token 只能从指定 IP 使用 |
