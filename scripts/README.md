# OpenBao 一键部署脚本

[OpenBao](https://openbao.org/) 是开源的密钥管理与数据保护平台，本脚本提供一键自动化部署能力，支持单机与高可用 (HA) 两种模式。

---

## 部署架构

### 单机模式 (Standalone)

```
┌─────────────────────────────────────────────────┐
│                   Client                         │
│          (bao CLI / API / Web UI)                │
└──────────────────────┬──────────────────────────┘
                       │ HTTPS :8200
                       ▼
┌─────────────────────────────────────────────────┐
│              OpenBao Server                      │
│                                                  │
│  ┌────────────┐   ┌────────────────────────┐    │
│  │  Listener   │   │     Storage (File)     │    │
│  │  TCP :8200  │   │  /opt/openbao/data     │    │
│  └────────────┘   └────────────────────────┘    │
│                                                  │
│  TLS: 自签名证书 (可替换)                          │
│  Config: /etc/openbao/openbao.hcl               │
└─────────────────────────────────────────────────┘
```

适用场景：开发、测试、非关键生产环境。

---

### 高可用模式 (HA — Raft 集群)

```
                    ┌──────────────┐
                    │ Load Balancer│  (可选, 推荐 Nginx/HAProxy)
                    │   :443/:8200 │
                    └──────┬───────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
            ▼              ▼              ▼
    ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
    │  Node 1       │ │  Node 2       │ │  Node 3       │
    │  (Active)     │ │  (Standby)    │ │  (Standby)    │
    │               │ │               │ │               │
    │ ┌───────────┐ │ │ ┌───────────┐ │ │ ┌───────────┐ │
    │ │ Listener   │ │ │ │ Listener   │ │ │ │ Listener   │ │
    │ │ :8200 API │ │ │ │ :8200 API │ │ │ │ :8200 API │ │
    │ │ :8201 Clst│ │ │ │ :8201 Clst│ │ │ │ :8201 Clst│ │
    │ └─────┬─────┘ │ │ └─────┬─────┘ │ │ └─────┬─────┘ │
    │       │       │ │       │       │ │       │       │
    │ ┌─────▼─────┐ │ │ ┌─────▼─────┐ │ │ ┌─────▼─────┐ │
    │ │ Raft Data │ │ │ │ Raft Data │ │ │ │ Raft Data │ │
    │ │  (Leader) │ │◄┤ │ (Follower)│ ├►│ │ (Follower)│ │
    │ └───────────┘ │ │ └───────────┘ │ │ └───────────┘ │
    │ node_id=node1 │ │ node_id=node2 │ │ node_id=node3 │
    └───────────────┘ └───────────────┘ └───────────────┘
            ▲                ▲                ▲
            └────────────────┴────────────────┘
                   Raft 协议 (加密通信)
                   retry_join 自动发现
                   Autopilot 自动管理
```

**关键特性：**

| 特性 | 说明 |
|------|------|
| **存储后端** | Integrated Storage (Raft) — 官方推荐 |
| **故障转移** | Leader 失效时 Standby 自动竞选 |
| **请求转发** | Standby 节点自动转发写请求至 Active 节点 |
| **数据复制** | Raft 共识协议保证强一致性 |
| **自动发现** | `retry_join` 配置实现节点自动加入 |
| **集群自愈** | Autopilot 自动清理 Dead Server |
| **最低节点数** | 3 节点 (满足 quorum 要求) |

---

### ELB + OpenBao 生产架构 (默认推荐)

```
         客户端
           │
           │ HTTPS :443
           ▼
    ┌─────────────────┐
    │   ELB / ALB      │  TLS 终止在这里
    │  (TLS 终止)      │  健康检查: /v1/sys/health
    └────────┬────────┘
             │
             │ HTTP :8200  (内网明文)
      ┌──────┼──────┐
      │      │      │
      ▼      ▼      ▼
   ┌──────┐┌──────┐┌──────┐
   │Node1 ││Node2 ││Node3 │  OpenBao 集群 (非 TLS)
   │ :8200││ :8200││ :8200│
   └──────┘└──────┘└──────┘
```

> 本脚本默认以非 TLS 模式部署，TLS 由前端 ELB/ALB/Nginx 终止。  
> 若需直连客户端场景（无 ELB），使用 `--tls` 参数启用 TLS。

---

## 快速开始

### 前置要求

- **操作系统**: Linux (amd64 / arm64)
- **权限**: root (sudo)
- **依赖**: `curl`, `tar`, `sha256sum` (脚本会自动检查，离线安装时 `curl` 不强制要求)

### 单机部署

```bash
# 下载脚本
chmod +x scripts/deploy-openbao.sh

# 一键部署 (默认 v2.6.1, 单机, 非 TLS，配合前端 ELB 使用)
sudo ./scripts/deploy-openbao.sh

# 启用 TLS (直连客户端场景，生成自签名证书)
sudo ./scripts/deploy-openbao.sh --tls --force
```

### HA 集群部署 (3 节点)

**节点 1 (初始 Leader):**

```bash
sudo ./scripts/deploy-openbao.sh --mode ha \
  --node-id node1 \
  --api-addr https://node1.example.com:8200 \
  --cluster-addr https://node1.example.com:8201 \
  --force
```

**节点 2 (加入集群):**

```bash
sudo ./scripts/deploy-openbao.sh --mode ha \
  --node-id node2 \
  --api-addr https://node2.example.com:8200 \
  --cluster-addr https://node2.example.com:8201 \
  --raft-peers "https://node1.example.com:8200" \
  --force
```

**节点 3 (加入集群):**

```bash
sudo ./scripts/deploy-openbao.sh --mode ha \
  --node-id node3 \
  --api-addr https://node3.example.com:8200 \
  --cluster-addr https://node3.example.com:8201 \
  --raft-peers "https://node1.example.com:8200,https://node2.example.com:8200" \
  --force
```

---

## 离线安装 (无外网服务器)

适用于无法访问互联网的服务器，需要提前在有网络的机器上下载好安装包。

### 步骤 1: 在有网络的机器上下载安装包

```bash
# 确定目标服务器架构
# amd64 (x86_64) 或 arm64 (aarch64)

# 下载对应架构的 tar 包
# AMD64
curl -LO https://github.com/openbao/openbao/releases/download/v2.6.1/openbao_2.6.1_linux_amd64.tar.gz

# ARM64
curl -LO https://github.com/openbao/openbao/releases/download/v2.6.1/openbao_2.6.1_linux_arm64.tar.gz

# (可选) 下载校验文件
curl -LO https://github.com/openbao/openbao/releases/download/v2.6.1/openbao_2.6.1_checksums.txt
```

### 步骤 2: 传输安装包到目标服务器

```bash
# 通过 scp/rsync/U盘等方式传输
scp openbao_2.6.1_linux_amd64.tar.gz user@target-server:/tmp/
```

### 步骤 3: 在目标服务器上使用 `--local-binary` 安装

```bash
# 单机离线安装
sudo ./scripts/deploy-openbao.sh --local-binary /tmp/openbao_2.6.1_linux_amd64.tar.gz

# 离线 + HA 模式
sudo ./scripts/deploy-openbao.sh --mode ha \
  --local-binary /tmp/openbao_2.6.1_linux_amd64.tar.gz \
  --node-id node1 \
  --api-addr https://node1.example.com:8200 \
  --cluster-addr https://node1.example.com:8201

# 也支持直接传入单个 bao 二进制文件
sudo ./scripts/deploy-openbao.sh --local-binary /tmp/bao
```

**`--local-binary` 支持的文件格式：**

| 文件格式 | 说明 |
|----------|------|
| `*.tar.gz` / `*.tgz` | 官方发布包，脚本自动解压提取 `bao` 二进制 |
| 单个可执行文件 | 直接作为 `bao` 二进制安装 |

> **提示**: 离线安装时其他所有功能（TLS 证书生成、配置文件、systemd 服务）均正常工作，仅跳过下载步骤。

---

## 初始化与解封

### 单机模式

```bash
export BAO_ADDR=https://127.0.0.1:8200

# 初始化 (保存输出的 Keys 和 Token!)
bao operator init -key-shares=5 -key-threshold=3

# 解封 (执行 3 次, 每次使用不同的 key)
bao operator unseal <unseal_key_1>
bao operator unseal <unseal_key_2>
bao operator unseal <unseal_key_3>

# 登录
bao login
```

### HA 模式

```bash
# 在 Node 1 上初始化
export BAO_ADDR=https://node1.example.com:8200
bao operator init -key-shares=5 -key-threshold=3

# 在 Node 1 上解封
bao operator unseal <key1>
bao operator unseal <key2>
bao operator unseal <key3>

# 在 Node 2/3 上加入集群并解封
export BAO_ADDR=https://node2.example.com:8200
bao operator raft join https://node1.example.com:8200
bao operator unseal <key1>
bao operator unseal <key2>
bao operator unseal <key3>

# 验证集群
bao operator raft list-peers
```

---

## 完整参数说明

```
用法: ./deploy-openbao.sh [选项]

选项:
  --mode standalone|ha     部署模式 (默认: standalone)
  --version VERSION        OpenBao 版本 (默认: 2.6.1)
  --node-id ID             HA 节点 ID (默认: node1)
  --api-addr URL           API 外部地址 (自动推断)
  --cluster-addr URL       集群通信地址 (自动推断)
  --listen-addr ADDR       监听地址 (默认: 0.0.0.0:8200)
  --raft-peers ADDRS       Raft 对等节点, 逗号分隔
  --no-tls                 禁用 TLS
  --no-ui                  禁用 Web UI
  --force                  跳过交互确认
  --uninstall              卸载 OpenBao
  -h, --help               显示帮助
```

---

## 部署后文件结构

```
/usr/local/bin/bao              # 二进制文件
/etc/openbao/
├── openbao.hcl                 # 主配置文件
└── openbao.env                 # 环境变量 (systemd 加载)
/opt/openbao/
├── data/                       # File 存储数据 (单机模式)
├── raft/                       # Raft 存储数据 (HA 模式)
└── tls/
    ├── tls.crt                 # TLS 证书
    └── tls.key                 # TLS 私钥
/var/log/openbao/               # 日志目录
/etc/systemd/system/
└── openbao.service             # systemd 服务单元
```

---

## 运维命令速查

```bash
# 查看服务状态
systemctl status openbao

# 查看实时日志
journalctl -u openbao -f

# 重启服务
systemctl restart openbao

# 重新加载配置 (不中断服务)
systemctl reload openbao

# 健康检查
curl -sk https://127.0.0.1:8200/v1/sys/health | jq

# HA: 查看集群节点
bao operator raft list-peers

# HA: 查看 Leader
bao status
```

---

## 架构选型指南

| 场景 | 推荐模式 | 节点数 | 说明 |
|------|----------|--------|------|
| 开发/测试 | Standalone | 1 | 快速部署，无需 HA |
| 小型生产 | Standalone + 备份 | 1 | 定期备份 `/opt/openbao/data` |
| 生产 HA | HA (Raft) | 3 | 自动故障转移，推荐最少节点 |
| 大规模生产 | HA (Raft) | 5 | 容忍 2 节点故障 |

> **注意**: Raft 集群节点数应为奇数 (3, 5, 7...)，以满足 quorum 要求。

---

## 常见问题

**Q: 服务启动失败？**

```bash
journalctl -u openbao -n 50 --no-pager
```

常见原因：配置文件语法错误、TLS 证书不存在、端口被占用。

**Q: HA 节点无法加入集群？**

- 确认 `--raft-peers` 地址可达
- 确认各节点防火墙开放 8200 和 8201 端口
- 确认 `api_addr` 和 `cluster_addr` 配置正确

**Q: 如何从 HA 降级到单机？**

修改 `/etc/openbao/openbao.hcl`，将 `storage "raft"` 改为 `storage "file"`，重启服务。注意：此操作会丢失 Raft 数据。

---

## 参考文档

- [OpenBao 官方文档](https://openbao.org/docs/)
- [高可用 (HA) 概念](https://openbao.org/docs/concepts/ha/)
- [Raft 存储配置](https://openbao.org/docs/configuration/storage/raft/)
- [配置参考](https://openbao.org/docs/configuration/)
- [GitHub Releases](https://github.com/openbao/openbao/releases)

---

## 国密算法支持情况

**OpenBao 目前不支持国密算法（SM2/SM3/SM4）。**

OpenBao 加密层使用的是 **AES-256-GCM** 国际标准（见源码 `internal/vault/core.go` 中的 `NewAESGCMBarrier`）。

### 国密合规替代方案

如需满足国密合规要求，可通过以下途径：

| 方案 | 说明 |
|------|------|
| **PKCS#11 HSM** | 通过 `seal "pkcs11"` 接入支持国密的国产 HSM（三未信安、江南天安等），由 HSM 底层完成 SM2/SM4 运算 |
| **KMIP 协议** | 通过 `seal "kmip"` 对接支持国密的密钥管理系统 |
| **插件开发** | v2.6.0+ 已开放插件系统，可自定义国密实现 |

---

## 自动解封 (Auto Unseal)

OpenBao **支持自动解封**。通过 `seal` 配置块，用外部 KMS/HSM 替代手动 Shamir 解封，服务启动时自动完成解封，无需人工输入 Unseal Key。

### 自动解封工作原理

```
服务启动 → 向外部 KMS/HSM 请求解密 Root Key → 自动完成解封 → 服务就绪
```

配置 `seal` 后，初始化时返回的是 **Recovery Key**（恢复密钥），而非 Unseal Key，用于灾难恢复场景。

### 支持的 Seal 类型

| 类型 | 说明 | 部署方式 |
|------|------|----------|
| `pkcs11` | PKCS#11 HSM 标准接口（可接入国产国密 HSM） | 内置 |
| `transit` | 用另一个 OpenBao/Transit 引擎解封 | 内置 |
| `static` | 静态密钥（仅开发用，**不安全**） | 内置 |
| `kmip` | KMIP 密钥管理协议 | 内置 |
| `awskms` | AWS KMS | 插件 |
| `gcpckms` | Google Cloud KMS | 插件 |
| `azurekeyvault` | Azure Key Vault | 插件 |
| `alicloudkms` | **阿里云 KMS** | 插件 |
| `tcloudpublic` | **腾讯云 KMS** | 插件 |
| `ocikms` | Oracle Cloud KMS | 插件 |
| `ovhcloud` | OVHcloud KMS | 插件 |

> **注意**: 从 v2.6.0 起，新的 Auto Unseal 机制通过插件系统安装。v2.7.0 起，许多原本内置的云厂商 Seal 将仅以插件形式提供。

### 配置示例

**阿里云 KMS 自动解封：**

```hcl
seal "alicloudkms" {
  region     = "cn-hangzhou"
  access_key = "your-access-key"
  secret_key = "your-secret-key"
  kms_key_id = "your-kms-key-id"
}
```

**AWS KMS 自动解封：**

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/openbao-unseal"
}
```

**PKCS#11 HSM 自动解封（可接入国产国密 HSM）：**

```hcl
seal "pkcs11" {
  lib            = "/usr/lib/hsm/libhsm.so"
  slot           = "0"
  pin            = "your-pin"
  key_label      = "openbao-unseal"
  hmac_key_label = "openbao-hmac"
}
```

**Transit 引擎自动解封（跨集群解封）：**

```hcl
seal "transit" {
  address    = "https://primary-openbao.example.com:8200"
  token      = "s.xxxxxxxxxxxx"
  mount_path = "transit/"
  key_name   = "openbao-autounseal"
}
```

### 在部署脚本中启用自动解封

部署脚本生成的配置文件位于 `/etc/openbao/openbao.hcl`，部署后可手动追加 `seal` 配置块：

```bash
# 部署完成后，编辑配置文件追加 seal 块
sudo tee -a /etc/openbao/openbao.hcl << 'EOF'

# 阿里云 KMS 自动解封
seal "alicloudkms" {
  region     = "cn-hangzhou"
  access_key = "your-access-key"
  secret_key = "your-secret-key"
  kms_key_id = "your-kms-key-id"
}
EOF

# 重启服务生效
sudo systemctl restart openbao
```

---

## 推荐生产架构：Auto-Unseal + GPG 密钥分发

这是 OpenBao 在生产环境中最安全的部署方案，结合了 **KMS 自动解封** 和 **GPG 加密分发**，兼顾自动化与安全性。

### 架构概览

```
┌───────────────────────────────────────────────────────────────────┐
│                        正常启动流程                               │
│                                                                   │
│  ┌──────────┐     ┌──────────┐     ┌──────────────┐              │
│  │ OpenBao  │────▶│ 阿里云    │────▶│   自动解封    │              │
│  │ 服务启动  │     │   KMS    │     │   无需人工    │              │
│  └──────────┘     └──────────┘     └──────────────┘              │
│                                                                   │
│  KMS 解密 Root Key → OpenBao 自动解封 → 服务就绪                 │
└───────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────┐
│                     灾难恢复流程 (KMS 不可用)                      │
│                                                                   │
│  ┌──────────┐     ┌──────────────┐     ┌──────────────┐          │
│  │ OpenBao  │     │ Recovery Key │     │  手动解封     │          │
│  │ 启动失败  │────▶│ GPG 解密    │────▶│  输入分片    │          │
│  │(KMS挂了) │     │   持有人     │     │  达到阀值    │          │
│  └──────────┘     └──────────────┘     └──────────────┘          │
│                                                                   │
│  3 位持有人各自 GPG 解密 → 得到 Recovery Key 分片               │
│  → 输入 3/5 个分片 → OpenBao 强制解封                           │
└───────────────────────────────────────────────────────────────────┘
```

### 安全模型

| 组件 | 保护方式 | 说明 |
|------|----------|------|
| **Root Key** | KMS 加密存储 | 日常解封由 KMS 自动处理 |
| **Recovery Key 分片** | GPG 公钥加密 | 仅 KMS 不可用时使用，分发给不同持有人 |
| **Root Token** | GPG 公钥加密 | 管理员凭据，仅指定管理员可解密 |
| **数据** | AES-256-GCM | 由 Root Key 派生的密钥加密 |

### 完整操作流程

#### 第 1 步：准备 GPG 密钥

每个 Recovery Key 持有人和 Root Token 管理员都需要一个 GPG 密钥对。

```bash
# 每个持有人在自己的机器上生成 GPG 密钥
gpg --gen-key
# 按提示输入姓名和邮箱，选择 RSA 4096

# 导出公钥发给管理员
gpg --export '张三' | base64 > zhang.asc
gpg --export '李四' | base64 > li.asc
gpg --export '王五' | base64 > wang.asc
gpg --export '赵六' | base64 > zhao.asc
gpg --export '钱七' | base64 > qian.asc

# Root Token 管理员
gpg --export 'Admin' | base64 > admin.asc

# 将所有公钥文件集中到初始化机器上
```

#### 第 2 步：部署 OpenBao 并配置阿里云 KMS

```bash
# 部署 OpenBao
sudo ./scripts/deploy-openbao.sh --force

# 追加 seal 配置 (阿里云 KMS 自动解封)
sudo tee -a /etc/openbao/openbao.hcl << 'EOF'

seal "alicloudkms" {
  region     = "cn-hangzhou"
  access_key = "your-access-key"
  secret_key = "your-secret-key"
  kms_key_id = "your-kms-key-id"
}
EOF

# 重启服务
sudo systemctl restart openbao
```

#### 第 3 步：GPG 加密初始化

```bash
# 设置环境变量
export BAO_ADDR=http://127.0.0.1:8200

# 使用 GPG 密钥分发初始化
# 5 个 Recovery Key 分片，需 3 个解封
# 每个分片用对应持有人的 GPG 公钥加密
bao operator init \
  -recovery-shares=5 \
  -recovery-threshold=3 \
  -recovery-pgp-keys="zhang.asc,li.asc,wang.asc,zhao.asc,qian.asc" \
  -root-token-pgp-key="admin.asc"
```

输出示例：

```
Recovery Key 1: wcBMA37rwGt6FS1VAQgAk1q8XQh6yc...  (张三持有)
Recovery Key 2: wcBMA0wwnMXgRzYYAQgAavqbTCxZGD...  (李四持有)
Recovery Key 3: wcFMA2DjqDb4YhTAARAAeTFyYxPmUd...  (王五持有)
Recovery Key 4: wcBMA77rwGt6FS1VAQgAk2q9YQh7yd...  (赵六持有)
Recovery Key 5: wcFMA8DjqDb5YhTBARAAeUFzZxQnVe...  (钱七持有)

Initial Root Token: wcBMA0wwnMXgRzYYAQgAav...          (Admin 持有)
```

> 此时所有 Key 和 Token 都是 **GPG 加密后的密文**，初始化者无法看到明文。

#### 第 4 步：分发加密密钥

将每个加密分片通过安全渠道发送给对应持有人：

```
张三 ← Recovery Key 1 密文
李四 ← Recovery Key 2 密文
王五 ← Recovery Key 3 密文
赵六 ← Recovery Key 4 密文
钱七 ← Recovery Key 5 密文
Admin ← Initial Root Token 密文
```

#### 第 5 步：持有人解密（灾备时）

每位持有人收到密文后，用自己的 GPG 私钥解密：

```bash
# 张三解密自己的 Recovery Key
echo "wcBMA37rwGt6FS1VAQgAk1q8XQh6yc..." | base64 --decode | gpg -dq
# 输入 GPG 密码
# 输出: 6ecb46277133e04b29bd0b1b05e60722dab7cdc684a0d3ee2de50ce4c38a3571

# Admin 解密 Root Token
echo "wcBMA0wwnMXgRzYYAQgAav..." | base64 --decode | gpg -dq
```

#### 第 6 步：灾难恢复（KMS 不可用时）

当 KMS 服务不可用时，需要至少 3 位持有人提供解密后的 Recovery Key：

```bash
# 进入恢复模式
bao operator rekey -init \
  -recovery-shares=5 \
  -recovery-threshold=3

# 依次输入 3 个 Recovery Key
bao operator rekey   # 输入张三的明文 key
bao operator rekey   # 输入李四的明文 key
bao operator rekey   # 输入王五的明文 key
```

### 职责分离矩阵

| 角色 | 持有 | 能解密 | 职责 |
|------|------|--------|------|
| **张三** | Recovery Key 1 | 仅自己的分片 | 灾备时提供分片 |
| **李四** | Recovery Key 2 | 仅自己的分片 | 灾备时提供分片 |
| **王五** | Recovery Key 3 | 仅自己的分片 | 灾备时提供分片 |
| **赵六** | Recovery Key 4 | 仅自己的分片 | 灾备时提供分片 (冗余) |
| **钱七** | Recovery Key 5 | 仅自己的分片 | 灾备时提供分片 (冗余) |
| **Admin** | Root Token | 仅 Root Token | 日常管理 OpenBao |
| **运维** | 服务器权限 | 无法解密任何密钥 | 维护基础设施 |

> **核心安全特性**: 初始化者、运维人员、任何单一持有人均无法获取完整的 Unseal/Recovery 密钥或 Root Token。

### 与脚本集成

可使用脚本的 `init` 子命令简化 GPG 初始化流程：

```bash
# 自动生成 GPG 密钥并初始化
./scripts/deploy-openbao.sh init \
  --key-shares=5 \
  --key-threshold=3 \
  --gpg-output-dir /secure/openbao-keys

# 或使用已有的公钥文件
./scripts/deploy-openbao.sh init \
  --key-shares=5 \
  --key-threshold=3 \
  --pgp-keys zhang.asc,li.asc,wang.asc,zhao.asc,qian.asc \
  --root-token-pgp admin.asc
```

---

## Demo：完整安全配置实战案例

以下以一个 **3 人运维团队 + 阿里云 KMS** 的场景，演示从密钥准备到生产部署的完整流程。

### 场景设定

| 角色 | 姓名 | 职责 |
|------|------|------|
| 运维负责人 | **张三** | 服务器部署、配置管理 |
| 安全管理员 | **李四** | 密钥管理、审计 |
| DBA | **王五** | 数据库与备份 |
| CTO | **赵总** | 持有 Root Token，审批权限 |

分片策略：`recovery-shares=3`，`recovery-threshold=2`（任意 2 人可灾备恢复）

---

### Step 1：各持有人生成 GPG 密钥

**张三、李四、王五、赵总分别在自己的机器上执行：**

```bash
# 张三
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: zhangsan
Name-Email: zhangsan@company.com
Expire-Date: 0
%commit
EOF

# 李四
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: lisi
Name-Email: lisi@company.com
Expire-Date: 0
%commit
EOF

# 王五
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: wangwu
Name-Email: wangwu@company.com
Expire-Date: 0
%commit
EOF

# 赵总 (Root Token 管理员)
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: zhaozong
Name-Email: zhao@company.com
Expire-Date: 0
%commit
EOF
```

### Step 2：导出公钥并集中到部署机器

```bash
# 各自导出公钥
gpg --export zhangsan  | base64 > zhangsan.asc
gpg --export lisi      | base64 > lisi.asc
gpg --export wangwu    | base64 > wangwu.asc
gpg --export zhaozong  | base64 > zhaozong.asc

# 通过安全渠道发送到张三的部署机器
scp lisi.asc     zhangsan@openbao-server:/home/zhangsan/gpg-keys/
scp wangwu.asc   zhangsan@openbao-server:/home/zhangsan/gpg-keys/
scp zhaozong.asc zhangsan@openbao-server:/home/zhangsan/gpg-keys/
```

### Step 3：部署 OpenBao

```bash
# 在服务器上 (张三操作)
mkdir -p /home/zhangsan/gpg-keys
# 将收到的公钥放入该目录

# 一键部署 (非 TLS, 配合 ELB)
sudo ./scripts/deploy-openbao.sh --force

# 追加阿里云 KMS 自动解封配置
sudo tee -a /etc/openbao/openbao.hcl << 'HCL'

seal "alicloudkms" {
  region     = "cn-hangzhou"
  access_key = "LTAI5tExampleKeyId"
  secret_key = "ExampleSecretKeyDoNotCommit"
  kms_key_id = "key-hz1234567890abcdef"
}
HCL

# 重启服务使配置生效
sudo systemctl restart openbao

# 确认服务运行正常
curl -s http://127.0.0.1:8200/v1/sys/health | python3 -m json.tool
# {"initialized": false, "sealed": true, "version": "2.6.1"}
```

### Step 4：GPG 加密初始化

```bash
export BAO_ADDR=http://127.0.0.1:8200

# 使用 init 子命令执行 GPG 加密初始化
./scripts/deploy-openbao.sh init \
  --key-shares=3 \
  --key-threshold=2 \
  --pgp-keys /home/zhangsan/gpg-keys/zhangsan.asc,/home/zhangsan/gpg-keys/lisi.asc,/home/zhangsan/gpg-keys/wangwu.asc \
  --root-token-pgp /home/zhangsan/gpg-keys/zhaozong.asc \
  --force
```

输出示例：

```
Recovery Key 1: wcBMA37rwGt6FS1VAQgAk1q8XQh6yc8kPnTqL4mN...  ← 张三的密文
Recovery Key 2: wcBMA0wwnMXgRzYYAQgAavqbTCxZGD6jPrFs2Wn...  ← 李四的密文
Recovery Key 3: wcFMA2DjqDb4YhTAARAAeTFyYxPmUdHjLkRs3Nq...  ← 王五的密文

Initial Root Token: wcBMA0wwnMXgRzYYAQgAavqbTCxZGD6jPr...  ← 赵总的密文

[INFO]  初始化输出已保存: /tmp/openbao-init/init-output.txt
```

> 此时所有 Key 和 Token 都是 **GPG 加密后的密文**，初始化者无法看到明文。

### Step 5：分发加密密文

张三从 `init-output.txt` 中复制各持有人的密文，通过安全渠道发送：

```bash
# 张三的 Recovery Key 密文 (张三自己保留)
echo "wcBMA37rwGt6FS1VAQgAk1q8XQh6yc8kPnTqL4mN..." > /secure/my-recovery-key.txt

# 发送给李四 (通过企业微信/加密邮件等)
echo "wcBMA0wwnMXgRzYYAQgAavqbTCxZGD6jPrFs2Wn..." | ssh lisi@workstation 'cat > ~/my-recovery-key.txt'

# 发送给王五
echo "wcFMA2DjqDb4YhTAARAAeTFyYxPmUdHjLkRs3Nq..." | ssh wangwu@workstation 'cat > ~/my-recovery-key.txt'

# 发送给赵总 (Root Token)
echo "wcBMA0wwnMXgRzYYAQgAavqbTCxZGD6jPr..." | ssh zhao@workstation 'cat > ~/my-root-token.txt'

# 删除本地密文副本 (安全清理)
rm -f /tmp/openbao-init/init-output.txt
```

### Step 6：各持有人验证解密（可选但推荐）

```bash
# 李四在自己的机器上验证解密
cat ~/my-recovery-key.txt | base64 --decode | gpg -dq
# 输入 GPG 密码后输出: a3f7c8d9e1f2...  (这就是李四的明文 Recovery Key)
# 确认后删除明文
```

### Step 7：验证自动解封生效

```bash
# 重启服务，观察是否自动解封
sudo systemctl restart openbao
sleep 2

# 检查状态 (KMS 正常时应显示 sealed: false)
curl -s http://127.0.0.1:8200/v1/sys/health | python3 -m json.tool
# {
#     "initialized": true,
#     "sealed": false,        ← 自动解封成功！
#     "version": "2.6.1"
# }
```

### Step 8：日常运维

```bash
# 赵总解密 Root Token 后登录
echo "wcBMA0wwnMXg..." | base64 --decode | gpg -dq
# 得到: hvs.CAESIxxxxxxxxx...

export BAO_ADDR=http://openbao-elb.company.com:8200  # ELB 地址
bao login
# Token (will be hidden): 输入解密后的 Root Token

# 查看状态
bao status
# Key                Value
# ---                -----
# Seal Type          alicloudkms     ← KMS 自动解封
# Initialized        true
# Sealed             false
# Recovery Seal Type shamir          ← Recovery Key 用于灾备
# Version            2.6.1

# 写入一个密钥测试
bao kv put secret/myapp/database \
  username=admin \
  password=SuperSecret123

# 读取
bao kv get secret/myapp/database
```

---

### Demo 配置文件完整示例

以下是一个可直接使用的完整配置文件（非 TLS + 阿里云 KMS + HA Raft）：

```hcl
# /etc/openbao/openbao.hcl
# ============================================================================
# OpenBao 生产配置 — ELB + 阿里云 KMS Auto-Unseal + Raft HA
# ============================================================================

ui = true

# Raft 存储 (HA 集群)
storage "raft" {
  path    = "/opt/openbao/raft"
  node_id = "node1"

  performance_multiplier = 1
  trailing_logs          = 10000
  snapshot_threshold     = 8192
  snapshot_interval      = "120s"

  retry_join {
    leader_api_addr = "http://node2:8200"
  }
  retry_join {
    leader_api_addr = "http://node3:8200"
  }

  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "10s"
    max_trailing_logs         = 250
    min_quorum                = 2
    server_stabilization_time = "10s"
  }
}

# 非 TLS (ELB 终止 TLS)
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

# 阿里云 KMS 自动解封
seal "alicloudkms" {
  region     = "cn-hangzhou"
  access_key = "LTAI5tExampleKeyId"
  secret_key = "ExampleSecretKeyDoNotCommit"
  kms_key_id = "key-hz1234567890abcdef"
}

# 地址配置 (ELB 地址)
api_addr     = "http://openbao-elb.company.com:8200"
cluster_addr = "http://node1:8201"

# 遥测
telemetry {
  disable_hostname          = true
  prometheus_retention_time = "30s"
}
```

---

### 灾备恢复 Demo

当阿里云 KMS 服务不可用时：

```bash
# 服务启动失败，状态显示 sealed: true
curl -s http://127.0.0.1:8200/v1/sys/health
# {"initialized": true, "sealed": true, ...}

# 张三和李四各自解密自己的 Recovery Key
# 张三:
echo "wcBMA37rwGt6FS1V..." | base64 --decode | gpg -dq
# 输出: zhang_key_plaintext_here

# 李四:
echo "wcBMA0wwnMXgRzYY..." | base64 --decode | gpg -dq
# 输出: li_key_plaintext_here

# 在服务器上输入 Recovery Key (任意 2 个)
bao operator unseal zhang_key_plaintext_here
# Key Shares: 2/3 (还需要 1 个)

bao operator unseal li_key_plaintext_here
# Key Shares: 3/3 → 解封成功！

# 验证
curl -s http://127.0.0.1:8200/v1/sys/health
# {"initialized": true, "sealed": false, ...}
```

---

## 参考文档（补充）

- [Seal 配置概览](https://openbao.org/docs/configuration/seal/)
- [阿里云 KMS Seal](https://openbao.org/docs/configuration/seal/alicloudkms/)
- [腾讯云 KMS Seal](https://openbao.org/docs/configuration/seal/tcloudpublic/)
- [AWS KMS Seal](https://openbao.org/docs/configuration/seal/awskms/)
- [PKCS#11 Seal](https://openbao.org/docs/configuration/seal/pkcs11/)
- [Transit Seal](https://openbao.org/docs/configuration/seal/transit/)
- [PKCS#11 HSM 接入指南](https://openbao.org/docs/guides/unseal/pkcs11/)
- [Seal 迁移指南](https://openbao.org/docs/guides/migration/)
