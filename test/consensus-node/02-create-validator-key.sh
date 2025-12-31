#!/bin/bash
# 创建验证者密钥账户

set -e

NEW_NODE_HOME="/data/biyachain-local"
KEYRING_BACKEND="test"  # 使用 test backend 避免密码输入

echo "=========================================="
echo "  创建验证者密钥"
echo "=========================================="
echo ""

# 检查节点目录是否存在
if [ ! -d "$NEW_NODE_HOME" ]; then
    echo "❌ 错误: 节点目录不存在: $NEW_NODE_HOME"
    echo "请先运行 01-prepare-new-validator.sh"
    exit 1
fi

# 创建验证者密钥
echo "创建新的验证者账户..."
echo ""
echo "⚠️  请妥善保存助记词!"
echo ""

/usr/local/biyachain/bin/biyachaind keys add validator \
    --home "$NEW_NODE_HOME" \
    --keyring-backend "$KEYRING_BACKEND"

echo ""
echo "=========================================="
echo "  验证者密钥信息"
echo "=========================================="

VALIDATOR_ADDR=$(/usr/local/biyachain/bin/biyachaind keys show validator \
    --home "$NEW_NODE_HOME" \
    --keyring-backend "$KEYRING_BACKEND" \
    -a)

VALIDATOR_VALOPER=$(/usr/local/biyachain/bin/biyachaind keys show validator \
    --home "$NEW_NODE_HOME" \
    --keyring-backend "$KEYRING_BACKEND" \
    --bech val \
    -a)

echo "Address: $VALIDATOR_ADDR"
echo "Valoper: $VALIDATOR_VALOPER"
echo ""

# 保存到文件
cat > "$NEW_NODE_HOME/validator-info.txt" <<EOF
Validator Address: $VALIDATOR_ADDR
Validator Operator: $VALIDATOR_VALOPER
Created: $(date)
EOF

echo "✓ 验证者密钥已创建"
echo "✓ 信息已保存到: $NEW_NODE_HOME/validator-info.txt"
echo ""
echo "下一步:"
echo "  1. 从现有验证者账户转账一些 INJ 到新地址: $VALIDATOR_ADDR"
echo "  2. 运行 03-start-local-node.sh 启动节点"
echo ""

