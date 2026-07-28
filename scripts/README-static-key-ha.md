# Static Key 自动解封 + HA 高可用集群部署指南

基于 OpenBao Static Key Seal 实现自动解封，结合 Raft 存储构建 3 节点 HA 高可用集群。无需云 KMS，完全自建。

---

## 一、架构总览

```
                          ┌─────────────────────────────────────────────────┐
                          │              共享密钥文件 (NFS / 配置管理)       │
                          │                                                 │
                          │   /opt/openbao/secrets/unseal.key  (32 bytes)   │
                          │   AES-256-GCM 密钥，3 个节点共享同一份          │
                          └────────┬──────────┬──────────┬──────────────────┘
                                   │          │          │
                                   │          │          │
              ┌────────────────────▼──┐ ┌─────▼────────────────┐ ┌▼────────────────────┐
              │   Node 1 (Active)     │ │   Node 2 (Standby)   │ │   Node 3 (Standby)  │
              │                       │ │                      │ │                     │
              │ seal "static" {       │ │ seal "static" {      │ │ seal "static" {     │
              │   current_key =       │ │   current_key =      │ │   current_key =     │
              │   "file://...key"     │ │   "file://...key"    │ │   "file://...key"   │
              │ }                     │ │ }                    │ │ }                   │
              │                       │ │                      │ │                     │
              │ storage "raft" {      │ │ storage "raft" {     │ │ storage "raft" {    │
              │   node_id = "node1"   │ │   node_id = "node2"  │ │   node_id = "node3" │
              │   retry_join {...}    │ │   retry_join {...}   │ │   retry_join {...}  │
              │ }                     │ │ }                    │ │ }                   │
              │                       │ │                      │ │                     │
              │ :8200 (API)           │ │ :8200 (API)          │ │ :8200 (API)         │
              │ :8201 (Cluster)       │ │ :8201 (Cluster)      │ │ :8201 (Cluster)     │
              └───────────┬───────────┘ └──────────┬───────────┘ └──────────┬──────────┘
                          │                        │                        │
                          └────────────────────────┼────────────────────────┘
                                                   │
                                          Raft 协议 (加密复制)
                                          Autopilot 自动管理
                                                   │
                                          ┌────────▼────────┐
                                          │   ELB / Nginx   │
                                          │   (TLS 终止)    │
                                          │   健康检查       │
                                          └────────┬────────┘
                                                   │
                                          ┌────────▼────────┐
                                          │     客户端       │
                                          │  (bao CLI / App) │
                                          └─────────────────┘
```

### 数据流

```
启动流程 (每个节点):
  服务器开机 → systemd 启动 openbao → 读取 unseal.key → 自动解封 → 加入 Raft 集群 → 就绪

请求流程:
  客户端 → ELB → Active 节点 (写) / Standby 节点 (读, 转发写请求)
```

---

## 二、关键设计

| 组件 | 选型 | 说明 |
|------|------|------|
| **自动解封** | `seal "static"` | 32 字节 AES-256-GCM 密钥文件 |
| **存储后端** | Raft (Integrated Storage) | 内置 HA，数据强一致 |
| **集群通信** | :8201 (cluster_address) | Raft 复制 + 请求转发 |
| **负载均衡** | ELB / Nginx / HAProxy | TLS 终止 + 健康检查 `/v1/sys/health` |
| **密钥分发** | NFS / Ansible / K8s Secret | 3 节点共享同一密钥文件 |
| **密钥轮转** | `previous_key` 机制 | 无缝轮转，旧密文仍可解密 |

### 安全模型

```
┌──────────────────────────────────────────────────────┐
│  密钥文件 (unseal.key) 安全要求:                      │
│                                                      │
│  ● 文件权限: 400 (仅 openbao 用户可读)               │
│  ● 分发方式: Ansible Vault / NFS + 严格 ACL          │
│  ● 存储位置: tmpfs / 加密分区 (不落普通磁盘)          │
│  ● 传输安全: SSH / TLS 加密通道                      │
│  ● 备份策略: GPG 加密后离线存储                      │
└──────────────────────────────────────────────────────┘
```

---

## 三、Demo：3 节点 HA 集群完整部署

### 环境准备

| 节点 | 主机名 | IP | 角色 |
|------|--------|-----|------|
| Node 1 | openbao-node1 | 10.0.1.11 | Raft Leader (初始) |
| Node 2 | openbao-node2 | 10.0.1.12 | Raft Follower |
| Node 3 | openbao-node3 | 10.0.1.13 | Raft Follower |

### Step 1：生成共享密钥

```bash
# 在任意一台机器上生成 (只需一次)
mkdir -p /tmp/openbao-keys
openssl rand -out /tmp/openbao-keys/unseal.key 32

# 验证密钥大小 (必须 32 字节)
ls -l /tmp/openbao-keys/unseal.key
# -rw-r--r-- 1 root root 32 Jul 27 10:00 /tmp/openbao-keys/unseal.key

# 生成密钥 ID (用于标识版本, 轮转时用)
echo "key-$(date +%Y%m%d)-1"
# key-20260727-1
```

### Step 2：分发密钥到 3 个节点

```bash
# 通过 SSH 分发 (生产环境建议用 Ansible Vault)
for node in openbao-node1 openbao-node2 openbao-node3; do
  ssh root@${node} "mkdir -p /opt/openbao/secrets"
  scp /tmp/openbao-keys/unseal.key root@${node}:/opt/openbao/secrets/unseal.key
  ssh root@${node} "chmod 400 /opt/openbao/secrets/unseal.key"
done

# 清理本地临时密钥
rm -f /tmp/openbao-keys/unseal.key
```

### Step 3：在 3 个节点上部署 OpenBao

在每个节点上执行（使用部署脚本）：

```bash
# Node 1
sudo ./scripts/deploy-openbao.sh --mode ha \
  --node-id node1 \
  --api-addr http://10.0.1.11:8200 \
  --cluster-addr http://10.0.1.11:8201 \
  --force

# Node 2
sudo ./scripts/deploy-openbao.sh --mode ha \
  --node-id node2 \
  --api-addr http://10.0.1.12:8200 \
  --cluster-addr http://10.0.1.12:8201 \
  --raft-peers "http://10.0.1.11:8200" \
  --force

# Node 3
sudo ./scripts/deploy-openbao.sh --mode ha \
  --node-id node3 \
  --api-addr http://10.0.1.13:8200 \
  --cluster-addr http://10.0.1.13:8201 \
  --raft-peers "http://10.0.1.11:8200,http://10.0.1.12:8200" \
  --force
```

### Step 4：追加 Static Key Seal 配置

在 **3 个节点** 上追加 seal 配置：

```bash
# 在每个节点上执行
sudo tee -a /etc/openbao/openbao.hcl << 'HCL'

# Static Key 自动解封
seal "static" {
  current_key_id = "key-20260727-1"
  current_key    = "file:///opt/openbao/secrets/unseal.key"
}
HCL

# 重启服务
sudo systemctl restart openbao
```

### Step 5：验证自动解封 + HA 集群

```bash
# 检查各节点状态 (应该是 sealed: false = 自动解封成功)
for node in 10.0.1.11 10.0.1.12 10.0.1.13; do
  echo "=== Node ${node} ==="
  curl -s http://${node}:8200/v1/sys/health | python3 -m json.tool
done
# 每个节点都应返回 "sealed": false
```

### Step 6：初始化集群（仅在 Node 1 执行一次）

```bash
export BAO_ADDR=http://10.0.1.11:8200

# 初始化 (GPG 加密分发, 参见部署脚本 init 子命令)
bao operator init -key-shares=3 -key-threshold=2

# 或使用 GPG 加密
./scripts/deploy-openbao.sh init \
  --key-shares=3 --key-threshold=2 \
  --pgp-keys alice.asc,bob.asc,carol.asc \
  --root-token-pgp admin.asc

# 解封 Node 1 (首次手动, 之后重启自动解封)
bao operator unseal <key1>
bao operator unseal <key2>
```

### Step 7：加入 Raft 集群

```bash
# Node 2 加入集群
export BAO_ADDR=http://10.0.1.12:8200
bao operator raft join http://10.0.1.11:8200
bao operator unseal <key1>
bao operator unseal <key2>

# Node 3 加入集群
export BAO_ADDR=http://10.0.1.13:8200
bao operator raft join http://10.0.1.11:8200
bao operator unseal <key1>
bao operator unseal <key2>
```

### Step 8：验证集群状态

```bash
export BAO_ADDR=http://10.0.1.11:8200
bao login   # 输入 Root Token

bao operator raft list-peers
# Node    Address          State     Voter
# ----    -------          -----     -----
# node1   10.0.1.11:8201   leader    true      ← Active (Leader)
# node2   10.0.1.12:8201   follower  true      ← Standby
# node3   10.0.1.13:8201   follower  true      ← Standby

bao status
# Key                Value
# ---                -----
# Seal Type          static          ← Static Key 自动解封
# HA Enabled         true
# Leader             node1
```

### Step 9：测试故障转移

```bash
# 模拟 Node 1 宕机
ssh root@openbao-node1 "systemctl stop openbao"
sleep 10

# 查看 Node 2 是否自动成为 Leader
curl -s http://10.0.1.12:8200/v1/sys/health | python3 -m json.tool
# "is_self": true, ...  (可能变为 active)

export BAO_ADDR=http://10.0.1.12:8200
bao operator raft list-peers
# node2 变为 leader ← 自动故障转移成功！

# 恢复 Node 1
ssh root@openbao-node1 "systemctl start openbao"
sleep 5
# Node 1 自动重新加入集群 (Standby), 自动解封 ✅
```

---

## 四、完整配置文件示例

### Node 1 配置

```hcl
# /etc/openbao/openbao.hcl — Node 1 (Leader)
# ============================================================================
# OpenBao HA 集群 — Static Key Auto-Unseal + Raft
# ============================================================================

ui = true

# ── Static Key 自动解封 ──────────────────────────────────────────────
seal "static" {
  current_key_id = "key-20260727-1"
  current_key    = "file:///opt/openbao/secrets/unseal.key"
}

# ── Raft 存储 (HA) ──────────────────────────────────────────────────
storage "raft" {
  path    = "/opt/openbao/raft"
  node_id = "node1"

  performance_multiplier = 1

  retry_join {
    leader_api_addr = "http://10.0.1.12:8200"
  }
  retry_join {
    leader_api_addr = "http://10.0.1.13:8200"
  }

  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "10s"
    max_trailing_logs         = 250
    min_quorum                = 2
    server_stabilization_time = "10s"
  }
}

# ── 监听器 (非 TLS, ELB 终止) ───────────────────────────────────────
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

api_addr     = "http://10.0.1.11:8200"
cluster_addr = "http://10.0.1.11:8201"

telemetry {
  disable_hostname          = true
  prometheus_retention_time = "30s"
}
```

### Node 2 配置

```hcl
# /etc/openbao/openbao.hcl — Node 2 (Follower)

ui = true

seal "static" {
  current_key_id = "key-20260727-1"
  current_key    = "file:///opt/openbao/secrets/unseal.key"
}

storage "raft" {
  path    = "/opt/openbao/raft"
  node_id = "node2"

  performance_multiplier = 1

  retry_join {
    leader_api_addr = "http://10.0.1.11:8200"
  }
  retry_join {
    leader_api_addr = "http://10.0.1.13:8200"
  }

  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "10s"
    max_trailing_logs         = 250
    min_quorum                = 2
    server_stabilization_time = "10s"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

api_addr     = "http://10.0.1.12:8200"
cluster_addr = "http://10.0.1.12:8201"

telemetry {
  disable_hostname          = true
  prometheus_retention_time = "30s"
}
```

### Node 3 配置

```hcl
# /etc/openbao/openbao.hcl — Node 3 (Follower)

ui = true

seal "static" {
  current_key_id = "key-20260727-1"
  current_key    = "file:///opt/openbao/secrets/unseal.key"
}

storage "raft" {
  path    = "/opt/openbao/raft"
  node_id = "node3"

  performance_multiplier = 1

  retry_join {
    leader_api_addr = "http://10.0.1.11:8200"
  }
  retry_join {
    leader_api_addr = "http://10.0.1.12:8200"
  }

  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "10s"
    max_trailing_logs         = 250
    min_quorum                = 2
    server_stabilization_time = "10s"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

api_addr     = "http://10.0.1.13:8200"
cluster_addr = "http://10.0.1.13:8201"

telemetry {
  disable_hostname          = true
  prometheus_retention_time = "30s"
}
```

---

## 五、Nginx 负载均衡配置

```nginx
# /etc/nginx/conf.d/openbao.conf

upstream openbao_cluster {
    # 健康检查 (OpenBao 健康端点)
    server 10.0.1.11:8200 max_fails=3 fail_timeout=10s;
    server 10.0.1.12:8200 max_fails=3 fail_timeout=10s;
    server 10.0.1.13:8200 max_fails=3 fail_timeout=10s;
}

server {
    listen 443 ssl;
    server_name openbao.company.com;

    ssl_certificate     /etc/nginx/ssl/openbao.crt;
    ssl_certificate_key /etc/nginx/ssl/openbao.key;

    # TLS 终止在 Nginx, 后端 HTTP 明文
    location / {
        proxy_pass http://openbao_cluster;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Standby 节点会 307 重定向到 Active, 让 Nginx 处理
        proxy_redirect off;
    }

    # 健康检查 (供监控系统使用)
    location /health {
        proxy_pass http://openbao_cluster/v1/sys/health?standbyok=true;
        access_log off;
    }
}
```

---

## 六、密钥轮转操作

### 轮转流程（不停机）

```bash
# Step 1: 生成新密钥
openssl rand -out /tmp/unseal-v2.key 32

# Step 2: 分发新密钥到所有节点
for node in openbao-node1 openbao-node2 openbao-node3; do
  scp /tmp/unseal-v2.key root@${node}:/opt/openbao/secrets/unseal-v2.key
  ssh root@${node} "chmod 400 /opt/openbao/secrets/unseal-v2.key; chown openbao:openbao /opt/openbao/secrets/unseal-v2.key"
done

# Step 3: 逐节点更新配置 (滚动更新, 不停服)
for node in openbao-node1 openbao-node2 openbao-node3; do
  ssh root@${node} 'cat >> /etc/openbao/openbao.hcl << "HCL"

# 密钥轮转: 新密钥 current, 旧密钥 previous
seal "static" {
  current_key_id  = "key-20260801-1"
  current_key     = "file:///opt/openbao/secrets/unseal-v2.key"
  previous_key_id = "key-20260727-1"
  previous_key    = "file:///opt/openbao/secrets/unseal.key"
}
HCL'

  # 注释掉旧的 seal 块 (或提前手动编辑)
  # 重启该节点
  ssh root@${node} "systemctl restart openbao"
  sleep 5

  # 验证该节点正常
  curl -s http://${node}:8200/v1/sys/health | python3 -m json.tool
done

# Step 4: 全部节点轮转完成后, 可删除 previous_key 配置
# (建议保留至少一个轮转周期后再清理)
```

---

## 七、Ansible 自动化部署示例

```yaml
# playbooks/openbao-ha-static.yml
---
- name: Deploy OpenBao HA Cluster with Static Key Auto-Unseal
  hosts: openbao_cluster
  become: true
  vars:
    openbao_version: "2.6.1"
    seal_key_id: "key-20260727-1"

  tasks:
    - name: 创建密钥目录
      file:
        path: /opt/openbao/secrets
        state: directory
        owner: openbao
        group: openbao
        mode: '0750'

    - name: 分发 Seal 密钥 (从 Ansible Vault 解密)
      copy:
        content: "{{ openbao_seal_key }}"  # Ansible Vault 加密变量
        dest: /opt/openbao/secrets/unseal.key
        owner: openbao
        group: openbao
        mode: '0400'

    - name: 部署 OpenBao
      script: >
        scripts/deploy-openbao.sh
        --mode ha
        --node-id {{ inventory_hostname_short }}
        --api-addr http://{{ ansible_default_ipv4.address }}:8200
        --cluster-addr http://{{ ansible_default_ipv4.address }}:8201
        --raft-peers "{{ raft_peers }}"
        --local-binary /tmp/openbao_{{ openbao_version }}_linux_amd64.tar.gz
        --force

    - name: 追加 Static Key Seal 配置
      blockinfile:
        path: /etc/openbao/openbao.hcl
        marker: "# {mark} STATIC KEY SEAL"
        block: |
          seal "static" {
            current_key_id = "{{ seal_key_id }}"
            current_key    = "file:///opt/openbao/secrets/unseal.key"
          }
      notify: restart openbao

  handlers:
    - name: restart openbao
      systemd:
        name: openbao
        state: restarted
```

```ini
# inventory/production.ini
[openbao_cluster]
openbao-node1 ansible_host=10.0.1.11 raft_peers=http://10.0.1.12:8200,http://10.0.1.13:8200
openbao-node2 ansible_host=10.0.1.12 raft_peers=http://10.0.1.11:8200,http://10.0.1.13:8200
openbao-node3 ansible_host=10.0.1.13 raft_peers=http://10.0.1.11:8200,http://10.0.1.12:8200
```

```bash
# 执行部署
ansible-playbook -i inventory/production.ini \
  playbooks/openbao-ha-static.yml \
  --vault-password-file ~/.vault_pass
```

---

## 八、监控与告警

### Prometheus 指标

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'openbao'
    metrics_path: '/v1/sys/metrics'
    params:
      format: ['prometheus']
    static_configs:
      - targets:
        - '10.0.1.11:8200'
        - '10.0.1.12:8200'
        - '10.0.1.13:8200'
```

### 关键告警规则

```yaml
# alerts.yml
groups:
  - name: openbao
    rules:
      - alert: OpenBaoSealed
        expr: vault_core_unsealed == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "OpenBao 节点 {{ $labels.instance }} 处于密封状态"

      - alert: OpenBaoNoLeader
        expr: vault_raft_leader == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "Raft 集群无 Leader, 可能存在脑裂"

      - alert: OpenBaoNodeDown
        expr: up{job="openbao"} == 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "OpenBao 节点 {{ $labels.instance }} 不可达"
```

---

## 九、故障排查

| 问题 | 检查命令 | 解决 |
|------|---------|------|
| 启动后 sealed=true | `journalctl -u openbao -n 20` | 检查密钥文件路径和权限 |
| 节点无法加入集群 | `bao operator raft list-peers` | 检查 8201 端口防火墙 |
| 密钥文件权限错误 | `ls -la /opt/openbao/secrets/` | `chmod 400 && chown openbao:openbao` |
| Leader 选举失败 | `bao status` | 确认至少 2/3 节点在线 |
| 密钥大小错误 | `wc -c /opt/openbao/secrets/unseal.key` | 必须恰好 32 字节 |

```bash
# 快速诊断脚本
for node in 10.0.1.11 10.0.1.12 10.0.1.13; do
  echo "=== ${node} ==="
  echo "Health:  $(curl -s http://${node}:8200/v1/sys/health | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"init={d[\"initialized\"]}, sealed={d[\"sealed\"]}, ha={d.get(\"ha_enabled\",\"n/a\")}")' 2>/dev/null || echo 'UNREACHABLE')"
  echo "Key:     $(ssh root@${node} 'wc -c /opt/openbao/secrets/unseal.key 2>/dev/null || echo MISSING')"
  echo "Service: $(ssh root@${node} 'systemctl is-active openbao 2>/dev/null || echo UNKNOWN')"
  echo ""
done
```
