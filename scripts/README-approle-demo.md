# OpenBao AppRole 授权配置 — 管理员操作指南

管理员如何为 Java 应用颁发 AppRole 凭据，并配置最小权限策略。

---

## 完整流程

```
管理员 (CLI)                          OpenBao                        Java 应用
     │                                  │                               │
     │ ① 创建策略 (Policy)              │                               │
     │─────────────────────────────────▶│                               │
     │                                  │                               │
     │ ② 启用 AppRole 认证              │                               │
     │─────────────────────────────────▶│                               │
     │                                  │                               │
     │ ③ 创建 AppRole (绑定策略)        │                               │
     │─────────────────────────────────▶│                               │
     │                                  │                               │
     │ ④ 读取 role_id                   │                               │
     │◀─────────────────────────────────│                               │
     │                                  │                               │
     │ ⑤ 生成 secret_id                 │                               │
     │◀─────────────────────────────────│                               │
     │                                  │                               │
     │ ⑥ 安全分发 role_id + secret_id   │                               │
     │──────────────────────────────────────────────────────────────────▶│
     │                                  │                               │
     │                                  │  ⑦ 应用用凭据登录             │
     │                                  │◀──────────────────────────────│
     │                                  │                               │
     │                                  │  ⑧ 返回 Token                 │
     │                                  │──────────────────────────────▶│
     │                                  │                               │
     │                                  │  ⑨ 应用用 Token 加密/解密     │
     │                                  │◀──────────────────────────────│
```

---

## 场景设定

为一个 **订单服务 (order-service)** 颁发 AppRole 凭据，该应用需要：

- ✅ 加密/解密订单敏感数据（通过 Transit 引擎）
- ✅ 读取自身配置密钥（通过 KV 引擎）
- ❌ 不能创建/删除密钥
- ❌ 不能访问其他应用的数据

---

## Step 1：管理员创建策略

```bash
export BAO_ADDR=http://127.0.0.1:8200
bao login
# 输入 Root Token
```

### 1.1 Transit 策略（加密解密权限）

```bash
bao policy write order-service-transit - <<'POLICY'
# 允许加密 (写入密文)
path "transit/encrypt/order-key" {
  capabilities = ["update"]
}

# 允许解密 (读取明文)
path "transit/decrypt/order-key" {
  capabilities = ["update"]
}

# 允许查看密钥元信息 (类型、版本, 不含密钥本身)
path "transit/keys/order-key" {
  capabilities = ["read"]
}
POLICY
```

### 1.2 KV 策略（读写应用配置）

```bash
bao policy write order-service-kv - <<'POLICY'
# 允许读取 order-service 命名空间下的所有密钥
path "secret/data/order-service/*" {
  capabilities = ["read", "list"]
}

# 允许写入 (应用可能需要缓存临时数据)
path "secret/data/order-service/cache/*" {
  capabilities = ["create", "update", "delete"]
}

# 禁止访问其他应用的数据 (显式拒绝)
path "secret/data/user-service/*" {
  capabilities = ["deny"]
}

path "secret/data/payment-service/*" {
  capabilities = ["deny"]
}
POLICY
```

### 1.3 Token 自管理策略（续期权限）

```bash
bao policy write order-service-token - <<'POLICY'
# 允许续期自身 Token
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# 允许查看自身 Token 信息
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# 允许撤销自身 Token
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
POLICY
```

---

## Step 2：准备 Transit 引擎和密钥

```bash
# 启用 Transit 引擎 (如未启用)
bao secrets enable transit

# 创建订单服务专用加密密钥
bao write -f transit/keys/order-key type=aes256-gcm96

# 启用自动轮转 (每 90 天)
bao write transit/keys/order-key/config auto_rotate_period=7776000

# 验证密钥已创建
bao read transit/keys/order-key
# Key                       Value
# ---                       -----
# type                      aes256-gcm96
# latest_version            1
# auto_rotate_period        7776000
```

---

## Step 3：创建 AppRole 并绑定策略

```bash
# 启用 AppRole 认证 (如未启用)
bao auth enable approle

# 创建 order-service 的 AppRole
bao write auth/approle/role/order-service \
  token_policies="order-service-transit,order-service-kv,order-service-token" \
  token_ttl="1h" \
  token_max_ttl="720h" \
  token_num_uses=0 \
  secret_id_ttl="24h" \
  secret_id_num_uses=5 \
  bind_secret_id=true \
  token_bound_cidrs="" \
  secret_id_bound_cidrs=""

# 参数说明:
#   token_policies     = 绑定的策略列表 (多个用逗号分隔)
#   token_ttl          = Token 有效期 1 小时 (到期需续期)
#   token_max_ttl      = Token 最长生命周期 30 天 (超过必须重新登录)
#   token_num_uses     = 0 表示不限制使用次数
#   secret_id_ttl      = secret_id 有效期 24 小时 (过期需重新生成)
#   secret_id_num_uses = secret_id 最多使用 5 次 (防滥用)
#   bind_secret_id     = true 要求必须提供 secret_id
```

---

## Step 4：获取凭据并安全分发

```bash
# 获取 role_id (固定值, 写入应用配置)
ROLE_ID=$(bao read -field=role_id auth/approle/role/order-service/role-id)
echo "role_id: $ROLE_ID"
# role_id: a1b2c3d4-e5f6-7890-abcd-ef1234567890

# 生成 secret_id (敏感凭据, 类似密码)
SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/order-service/secret-id)
echo "secret_id: $SECRET_ID"
# secret_id: x9y8z7w6-v5u4-3210-dcba-0987654321fe

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 安全分发方式 (选择一种):
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 方式 1: 环境变量 (K8s / Docker)
#   kubectl set env deployment/order-service \
#     OPENBAO_ROLE_ID=$ROLE_ID \
#     OPENBAO_SECRET_ID=$SECRET_ID

# 方式 2: 配置文件 (权限严格限制)
cat > /etc/order-service/openbao-credentials.json <<EOF
{
  "role_id": "$ROLE_ID",
  "secret_id": "$SECRET_ID"
}
EOF
chmod 400 /etc/order-service/openbao-credentials.json
chown order-service:order-service /etc/order-service/openbao-credentials.json

# 方式 3: Ansible Vault (推荐, CI/CD 友好)
#   ansible-vault encrypt_string "$SECRET_ID" --name 'openbao_secret_id'

# ⚠️ 分发完成后, 清除本地变量
unset ROLE_ID SECRET_ID
```

---

## Step 5：Java 应用使用 AppRole 登录

### application.yml

```yaml
openbao:
  uri: ${OPENBAO_ADDR:http://127.0.0.1:8200}
  auth-method: approle
  transit-key: order-key
  approle:
    role-id: ${OPENBAO_ROLE_ID:}
    secret-id: ${OPENBAO_SECRET_ID:}
```

### AppRole 登录 + Token 续期 Java 代码

```java
package com.example.orderservice.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.vault.authentication.AppRoleAuthentication;
import org.springframework.vault.authentication.AppRoleAuthenticationOptions;
import org.springframework.vault.authentication.ClientAuthentication;
import org.springframework.vault.client.VaultEndpoint;
import org.springframework.vault.core.VaultTemplate;
import org.springframework.web.client.RestTemplate;

import java.net.URI;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

@Component
@EnableScheduling
public class OpenBaoAuthManager {

    private static final Logger log = LoggerFactory.getLogger(OpenBaoAuthManager.class);

    private final VaultTemplate vaultTemplate;
    private final AtomicReference<String> currentToken = new AtomicReference<>();

    public OpenBaoAuthManager(OpenBaoProperties properties) {
        // 1. 使用 AppRole 认证
        VaultEndpoint endpoint = VaultEndpoint.from(URI.create(properties.getUri()));
        ClientAuthentication auth = new AppRoleAuthentication(
                AppRoleAuthenticationOptions.builder()
                        .roleId(properties.getApprole().getRoleId())
                        .secretId(properties.getApprole().getSecretId())
                        .build(),
                new RestTemplate()
        );
        this.vaultTemplate = new VaultTemplate(endpoint, auth);
        log.info("✅ AppRole 认证成功, OpenBao 连接就绪");
    }

    /**
     * 每 30 分钟自动续期 Token
     */
    @Scheduled(fixedRate = 1800000) // 30 分钟
    public void renewToken() {
        try {
            Map<String, Object> response = vaultTemplate.write(
                    "auth/token/renew-self", Map.of("increment", "1h"), Map.class);
            log.debug("Token 续期成功");
        } catch (Exception e) {
            log.warn("Token 续期失败, 将在下次自动重试: {}", e.getMessage());
        }
    }

    public VaultTemplate getVaultTemplate() {
        return vaultTemplate;
    }
}
```

### 使用 Token 加密/解密

```java
package com.example.orderservice.service;

import org.springframework.stereotype.Service;
import org.springframework.vault.core.VaultTemplate;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;

@Service
public class OrderEncryptionService {

    private final VaultTemplate vaultTemplate;
    private final String keyName = "order-key";

    public OrderEncryptionService(OpenBaoAuthManager authManager) {
        this.vaultTemplate = authManager.getVaultTemplate();
    }

    /**
     * 加密订单敏感字段 (手机号、地址等)
     */
    public String encrypt(String plaintext) {
        String encoded = Base64.getEncoder()
                .encodeToString(plaintext.getBytes(StandardCharsets.UTF_8));

        Map<String, Object> response = vaultTemplate.write(
                "transit/encrypt/" + keyName,
                Map.of("plaintext", encoded),
                Map.class
        );

        @SuppressWarnings("unchecked")
        Map<String, String> data = (Map<String, String>) response.get("data");
        return data.get("ciphertext");
        // 返回: "vault:v1:8SDd3WHDOjf7mq69..."
    }

    /**
     * 解密订单敏感字段
     */
    public String decrypt(String ciphertext) {
        Map<String, Object> response = vaultTemplate.write(
                "transit/decrypt/" + keyName,
                Map.of("ciphertext", ciphertext),
                Map.class
        );

        @SuppressWarnings("unchecked")
        Map<String, String> data = (Map<String, String>) response.get("data");
        String encoded = data.get("plaintext");

        return new String(
                Base64.getDecoder().decode(encoded),
                StandardCharsets.UTF_8
        );
    }
}
```

### 订单服务使用示例

```java
package com.example.orderservice.controller;

import com.example.orderservice.service.OrderEncryptionService;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderEncryptionService encryptionService;
    private final OrderRepository orderRepository;

    public OrderController(OrderEncryptionService encryptionService,
                           OrderRepository orderRepository) {
        this.encryptionService = encryptionService;
        this.orderRepository = orderRepository;
    }

    /**
     * 创建订单 — 敏感字段加密后存储
     */
    @PostMapping
    public Order createOrder(@RequestBody CreateOrderRequest request) {
        Order order = new Order();
        order.setOrderNo(request.getOrderNo());

        // 手机号、地址等敏感字段通过 OpenBao 加密
        order.setPhone(encryptionService.encrypt(request.getPhone()));
        order.setAddress(encryptionService.encrypt(request.getAddress()));

        // 非敏感字段直接存储
        order.setAmount(request.getAmount());
        order.setStatus("CREATED");

        // 存入数据库 (敏感字段为密文)
        orderRepository.save(order);

        // 返回时解密
        order.setPhone(request.getPhone());
        order.setAddress(request.getAddress());
        return order;
    }

    /**
     * 查询订单 — 读取时自动解密
     */
    @GetMapping("/{id}")
    public Order getOrder(@PathVariable Long id) {
        Order order = orderRepository.findById(id)
                .orElseThrow(() -> new RuntimeException("订单不存在"));

        // 解密敏感字段
        order.setPhone(encryptionService.decrypt(order.getPhone()));
        order.setAddress(encryptionService.decrypt(order.getAddress()));

        return order;
    }
}
```

---

## Step 6：验证权限边界

```bash
# ===== 用 order-service 的 Token 测试 =====

# 获取 Token (模拟应用登录)
TOKEN=$(curl -s http://127.0.0.1:8200/v1/auth/approle/login \
  -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" \
  | jq -r '.auth.client_token')

# ✅ 应该成功: 加密订单数据
curl -s http://127.0.0.1:8200/v1/transit/encrypt/order-key \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"plaintext":"'$(echo -n '13800138000' | base64)'"}' \
  | jq '.data.ciphertext'
# "vault:v1:Kfj8sLm2nPq..."

# ✅ 应该成功: 解密订单数据
curl -s http://127.0.0.1:8200/v1/transit/decrypt/order-key \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"ciphertext":"vault:v1:Kfj8sLm2nPq..."}' \
  | jq '.data.plaintext' | base64 -d
# 13800138000

# ✅ 应该成功: 读取自身配置
curl -s http://127.0.0.1:8200/v1/secret/data/order-service/config \
  -H "X-Vault-Token: $TOKEN" | jq

# ❌ 应该失败: 不能创建新密钥 (无 create 权限)
curl -s http://127.0.0.1:8200/v1/transit/keys/new-key \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"type":"aes256-gcm96"}'
# {"errors":["1 error occurred:\n\t* permission denied"]}

# ❌ 应该失败: 不能访问其他应用数据
curl -s http://127.0.0.1:8200/v1/secret/data/payment-service/config \
  -H "X-Vault-Token: $TOKEN"
# {"errors":["1 error occurred:\n\t* permission denied"]}

# ❌ 应该失败: 不能删除密钥
curl -s -X DELETE http://127.0.0.1:8200/v1/transit/keys/order-key \
  -H "X-Vault-Token: $TOKEN"
# {"errors":["1 error occurred:\n\t* permission denied"]}
```

---

## 多应用权限隔离示意

```
┌────────────────────────────────────────────────────────────────────┐
│                        OpenBao Server                              │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │  Transit Engine                                          │      │
│  │  ├── order-key      ← order-service 可加密/解密          │      │
│  │  ├── user-key       ← user-service 可加密/解密           │      │
│  │  └── payment-key    ← payment-service 可加密/解密        │      │
│  └──────────────────────────────────────────────────────────┘      │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │  KV Engine (secret/)                                     │      │
│  │  ├── order-service/*    ← order-service 可读             │      │
│  │  ├── user-service/*     ← user-service 可读              │      │
│  │  └── payment-service/*  ← payment-service 可读           │      │
│  └──────────────────────────────────────────────────────────┘      │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │  AppRole 认证                                            │      │
│  │  ├── order-service     → [transit, kv, token] 策略      │      │
│  │  ├── user-service      → [transit, kv, token] 策略      │      │
│  │  └── payment-service   → [transit, kv, token] 策略      │      │
│  └──────────────────────────────────────────────────────────┘      │
│                                                                    │
│  每个应用只能操作自己的密钥和数据, 互相隔离                        │
└────────────────────────────────────────────────────────────────────┘
```

---

## 管理员日常操作速查

```bash
# 查看 AppRole 列表
bao list auth/approle/role

# 查看某个 AppRole 详情
bao read auth/approle/role/order-service

# 重新生成 secret_id (原 secret_id 立即失效)
bao write -f auth/approle/role/order-service/secret-id

# 查看 AppRole 绑定的策略
bao read -field=token_policies auth/approle/role/order-service

# 吊销某个 Token (发现异常时)
bao write auth/token/revoke token="hvs.CAESI..."

# 查看所有活跃 Token
bao list auth/token/accessors

# 禁用某个 AppRole (紧急下线)
bao delete auth/approle/role/order-service

# 查看审计日志中的加密调用
grep "transit/encrypt" /var/log/openbao/audit.log | tail -5
```
