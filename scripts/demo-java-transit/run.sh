#!/bin/bash
# ============================================================
# OpenBao Transit 加密/解密 Java 示例 — 构建 & 运行脚本
# ============================================================

set -e

# ---------- 检查环境变量 ----------
MISSING=0
for VAR in OPENBAO_ADDR OPENBAO_NAMESPACE OPENBAO_ROLE_ID OPENBAO_SECRET_ID OPENBAO_TRANSIT_KEY OPENBAO_TRANSIT_MOUNT; do
    if [ -z "${!VAR}" ]; then
        echo "错误: 环境变量 $VAR 未设置"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "请先设置所有环境变量:"
    echo '  export OPENBAO_ADDR="https://kms.msuncloud-internal.com"'
    echo '  export OPENBAO_NAMESPACE="devops"'
    echo '  export OPENBAO_ROLE_ID="a7e0a617-64f2-1944-bd9e-9ebe18bf54cb"'
    echo '  export OPENBAO_SECRET_ID="6f7cb405-cbf5-1419-21c4-9991622c1fd0"'
    echo '  export OPENBAO_TRANSIT_KEY="msun-devops-knowledge"'
    echo '  export OPENBAO_TRANSIT_MOUNT="transit"'
    exit 1
fi

# ---------- 构建 ----------
echo ">>> 构建项目..."
mvn -q clean package -DskipTests

# ---------- 运行 ----------
echo ">>> 运行示例..."
java -jar target/openbao-transit-example-1.0.0.jar
