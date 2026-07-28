# OpenBao HA 集群 ELB 负载均衡配置指南

---

## 一、架构总览

```
                    客户端 (bao CLI / Java App / curl)
                              │
                              │ HTTPS :443
                              ▼
                ┌──────────────────────────┐
                │    ELB / 负载均衡器       │
                │                          │
                │  ● TLS 终止              │
                │  ● 健康检查              │
                │  ● 轮询/最少连接         │
                │  ● 故障自动剔除          │
                └────┬─────────┬────┬─────┘
                     │         │    │
              HTTP   │   HTTP  │    │  HTTP
              :8200  │   :8200 │    │  :8200
                     ▼         ▼    ▼
              ┌──────────┐┌──────────┐┌──────────┐
              │ Node 1   ││ Node 2   ││ Node 3   │
              │ (Active) ││ (Standby)││ (Standby)│
              │          ││          ││          │
              │ 读 ✅    ││ 读 ✅    ││ 读 ✅    │
              │ 写 ✅    ││ 写 ↗    ││ 写 ↗    │
              │ encrypt ✅│ encrypt ✅│ encrypt ✅│
              │ decrypt ✅│ decrypt ✅│ decrypt ✅│
              └──────────┘└──────────┘└──────────┘
```

**关键点：**
- TLS 在 ELB 终止，后端 HTTP 明文通信（内网安全）
- 3 个节点都接收加密解密流量（纯计算，不转发）
- Standby 节点的写请求自动转发到 Active 节点
- 健康检查必须加 `?standbyok=true`，否则 Standby 会被踢掉

---

## 二、阿里云 ALB/CLB 配置

### 2.1 创建后端服务器组

```bash
# 阿里云 CLI (aliyun)

# 创建服务器组
aliyun alb CreateServerGroup \
  --ServerGroupName "openbao-cluster" \
  --VpcId "vpc-xxx" \
  --Protocol "HTTP" \
  --Port 8200 \
  --HealthCheckConfig '{
    "HealthCheckEnabled": true,
    "HealthCheckProtocol": "HTTP",
    "HealthCheckPath": "/v1/sys/health?standbyok=true",
    "HealthCheckMethod": "GET",
    "HealthCheckInterval": 10,
    "HealthCheckTimeout": 5,
    "HealthyThreshold": 3,
    "UnhealthyThreshold": 3,
    "HealthCheckHttpCode": "http_2xx"
  }'
```

**健康检查关键参数：**

| 参数 | 值 | 说明 |
|------|-----|------|
| **Path** | `/v1/sys/health?standbyok=true` | **必须加 standbyok**，否则 Standby 返回 429 |
| **Method** | GET | |
| **Expected Code** | 200 | Active 和 Standby 都返回 200 |
| **Interval** | 10s | 每 10 秒检查一次 |
| **Timeout** | 5s | 超时时间 |
| **Healthy Threshold** | 3 | 连续 3 次成功标记健康 |
| **Unhealthy Threshold** | 3 | 连续 3 次失败标记不健康 |

### 2.2 添加后端服务器

```bash
# 将 3 个节点加入服务器组
for ip in 10.0.1.11 10.0.1.12 10.0.1.13; do
  aliyun alb AddServersToServerGroup \
    --ServerGroupId "sgp-xxx" \
    --Servers "[{\"ServerIp\":\"${ip}\",\"Port\":8200,\"Weight\":100}]"
done
```

### 2.3 创建监听器 (TLS 终止)

```bash
# 创建 HTTPS 监听 (443 → 8200)
aliyun alb CreateListener \
  --LoadBalancerId "alb-xxx" \
  --ListenerProtocol "HTTPS" \
  --ListenerPort 443 \
  --ServerGroupId "sgp-xxx" \
  --Certificates '[{"CertificateId":"cert-xxx"}]' \
  --ForwardingRules '[{
    "Type": "ForwardGroup",
    "ForwardGroupConfig": {
      "ServerGroupTuples": [{"ServerGroupId":"sgp-xxx"}]
    }
  }]'
```

---

## 三、Nginx 配置 (自建负载均衡)

### 3.1 完整配置

```nginx
# /etc/nginx/conf.d/openbao.conf

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 后端集群 (3 个 OpenBao 节点)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
upstream openbao_cluster {
    # 最少连接算法 (推荐)
    least_conn;

    server 10.0.1.11:8200 max_fails=3 fail_timeout=10s;
    server 10.0.1.12:8200 max_fails=3 fail_timeout=10s;
    server 10.0.1.13:8200 max_fails=3 fail_timeout=10s;

    # 保持连接 (减少 TCP 握手开销)
    keepalive 32;
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# HTTPS 入口 (TLS 终止)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
server {
    listen 443 ssl http2;
    server_name openbao.company.com;

    # TLS 证书 (ELB 统一终止)
    ssl_certificate     /etc/nginx/ssl/openbao.company.com.crt;
    ssl_certificate_key /etc/nginx/ssl/openbao.company.com.key;

    # TLS 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # ── Transit 加密解密 (高吞吐路径) ──────────
    location ~ ^/v1/transit/(encrypt|decrypt)/ {
        proxy_pass http://openbao_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # 转发客户端信息
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 超时配置 (加密解密应该很快)
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
        proxy_send_timeout 10s;

        # 故障自动切换
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
    }

    # ── 健康检查端点 ───────────────────────────
    location /health {
        proxy_pass http://openbao_cluster/v1/sys/health?standbyok=true;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        access_log off;
    }

    # ── 其他所有请求 ──────────────────────────
    location / {
        proxy_pass http://openbao_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Standby 节点会 307 重定向到 Active
        # 关闭重定向改写，让客户端直接跟随
        proxy_redirect off;

        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
        proxy_send_timeout 30s;

        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# HTTP → HTTPS 强制跳转
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
server {
    listen 80;
    server_name openbao.company.com;
    return 301 https://$host$request_uri;
}
```

### 3.2 验证 Nginx 配置

```bash
# 检查语法
nginx -t

# 重载配置
nginx -s reload

# 验证健康检查
curl -sk https://openbao.company.com/health | python3 -m json.tool
# {"initialized": true, "sealed": false, ...}
```

---

## 四、HAProxy 配置 (高性能方案)

```haproxy
# /etc/haproxy/haproxy.cfg

global
    log stdout format raw local0
    maxconn 4096

defaults
    mode http
    log global
    option httplog
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    retries 3

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前端: HTTPS 入口 (TLS 终止)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
frontend openbao_https
    bind *:443 ssl crt /etc/haproxy/certs/openbao.company.com.pem
    default_backend openbao_nodes

    # 健康检查专用路径
    acl is_health path /health
    use_backend openbao_health if is_health

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 后端: OpenBao 集群
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
backend openbao_nodes
    balance leastconn
    option httpchk GET /v1/sys/health?standbyok=true
    http-check expect status 200

    # 后端 HTTP 明文
    server node1 10.0.1.11:8200 check inter 10s fall 3 rise 3
    server node2 10.0.1.12:8200 check inter 10s fall 3 rise 3
    server node3 10.0.1.13:8200 check inter 10s fall 3 rise 3

# 健康检查后端 (关闭日志)
backend openbao_health
    balance leastconn
    option httpchk GET /v1/sys/health?standbyok=true
    http-check expect status 200
    server node1 10.0.1.11:8200 check inter 10s fall 3 rise 3
    server node2 10.0.1.12:8200 check inter 10s fall 3 rise 3
    server node3 10.0.1.13:8200 check inter 10s fall 3 rise 3

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# HAProxy Stats 页面 (运维监控)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
frontend stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if LOCALHOST
```

---

## 五、健康检查详解

### OpenBao 健康端点返回值

```bash
# Active 节点
curl http://10.0.1.11:8200/v1/sys/health
# HTTP 200
# {"initialized":true,"sealed":false,"standby":false,"is_self":true,...}

# Standby 节点 (不加 standbyok)
curl http://10.0.1.12:8200/v1/sys/health
# HTTP 429 ← ELB 会认为不健康，踢掉!
# {"initialized":true,"sealed":false,"standby":true,...}

# Standby 节点 (加 standbyok=true)
curl http://10.0.1.12:8200/v1/sys/health?standbyok=true
# HTTP 200 ← ELB 认为健康，保留 ✅
# {"initialized":true,"sealed":false,"standby":true,...}
```

### 健康检查参数说明

```bash
# 完整参数
/v1/sys/health?standbyok=true&perfstandbyok=true&activecode=200&standbycode=200&sealedcode=503&uninitcode=501

参数说明:
  standbyok=true    → Standby 也返回 200 (必须!)
  perfstandbyok=true → Performance Standby 也返回 200
  activecode=200    → Active 节点返回码 (默认 200)
  standbycode=200   → Standby 节点返回码 (默认 429, 设为 200)
  sealedcode=503    → Sealed 节点返回码 (默认 503)
  uninitcode=501    → 未初始化返回码 (默认 501)
```

---

## 六、客户端配置

### Java 应用指向 ELB

```yaml
# application.yml
openbao:
  uri: https://openbao.company.com    # ELB 地址, 不是节点 IP
  auth-method: approle
  transit-key: app-key
```

### bao CLI 指向 ELB

```bash
# 环境变量
export BAO_ADDR=https://openbao.company.com    # ELB 地址
export BAO_SKIP_VERIFY=false                    # ELB 有正式证书, 不需要跳过

# 测试
bao status
bao operator raft list-peers
```

### DNS 配置

```
# /etc/hosts 或 DNS
openbao.company.com  →  ELB 的 IP/VIP

# 阿里云内网 DNS
openbao.company.com  →  ALB 的内网地址 (alb-xxx.cn-hangzhou.alb.aliyuncs.com)
```

---

## 七、方案对比

| | **阿里云 ALB** | **Nginx** | **HAProxy** |
|---|:---:|:---:|:---:|
| **部署复杂度** | 低 (控制台配置) | 中 | 中 |
| **运维成本** | 低 (托管服务) | 需自行维护 | 需自行维护 |
| **性能** | 高 (弹性伸缩) | 高 | 极高 |
| **TLS 终止** | 内置 | 内置 | 内置 |
| **健康检查** | 内置 | 被动检查 | 主动+被动 |
| **费用** | 按流量收费 | 免费 (自建) | 免费 (自建) |
| **适用场景** | 云环境 | 通用 | 高并发/精细控制 |
| **推荐度** | 云环境首选 | 通用推荐 | 性能极致场景 |

---

## 八、故障转移验证

```bash
# 1. 确认当前 Leader
bao operator raft list-peers
# Node    Address          State
# ----    -------          -----
# node1   10.0.1.11:8201   leader     ← 当前 Leader
# node2   10.0.1.12:8201   follower
# node3   10.0.1.13:8201   follower

# 2. 模拟 Node 1 宕机
ssh root@10.0.1.11 "systemctl stop openbao"

# 3. 等待 10~30 秒，观察 ELB 健康检查
# Nginx: 10 秒内标记 node1 不健康，流量切到 node2/node3
# ALB:   30 秒内剔除 node1

# 4. 验证新 Leader
bao operator raft list-peers
# node2   10.0.1.12:8201   leader     ← 自动选举新 Leader
# node3   10.0.1.13:8201   follower

# 5. 验证加密解密仍正常
curl -s https://openbao.company.com/v1/transit/encrypt/app-key \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"plaintext":"dGVzdA=="}' | jq
# 正常返回密文 ✅

# 6. 恢复 Node 1
ssh root@10.0.1.11 "systemctl start openbao"
# Node 1 自动重新加入集群 (Standby), 自动解封
# ELB 健康检查恢复，流量重新均衡到 3 个节点
```
