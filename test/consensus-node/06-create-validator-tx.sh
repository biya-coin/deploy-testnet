#!/bin/bash
# 创建验证者交易 (在提案通过后执行)

set -e

NEW_NODE_HOME="/data/biyachain-local"
KEYRING_BACKEND="test"
CHAIN_ID="biyachain-888"
NODE_RPC="http://127.0.0.1:26857"

# 验证者参数
VALIDATOR_MONIKER="validator-local"
VALIDATOR_COMMISSION_RATE="0.10"
VALIDATOR_COMMISSION_MAX_RATE="0.20"
VALIDATOR_COMMISSION_MAX_CHANGE_RATE="0.01"
VALIDATOR_MIN_SELF_DELEGATION="1"
VALIDATOR_AMOUNT="10000000000000000000inj"  # 10 INJ

echo "=========================================="
echo "  创建验证者"
echo "=========================================="
echo ""

# 设置库路径
export LD_LIBRARY_PATH=/usr/local/biyachain/lib:$LD_LIBRARY_PATH

# 检查节点是否运行
if ! /usr/local/biyachain/bin/biyachaind status --node=$NODE_RPC 2>/dev/null | grep -q "height"; then
    echo "❌ 错误: 本地节点未运行"
    echo "   请先运行: ./03-start-local-node.sh"
    exit 1
fi

echo "✓ 本地节点正在运行"
echo ""

# 获取验证者信息
VALIDATOR_ADDR=$(/usr/local/biyachain/bin/biyachaind keys show validator \
    --home "$NEW_NODE_HOME" \
    --keyring-backend "$KEYRING_BACKEND" \
    -a)

VALIDATOR_PUBKEY=$(/usr/local/biyachain/bin/biyachaind tendermint show-validator \
    --home "$NEW_NODE_HOME")

echo "验证者地址: $VALIDATOR_ADDR"
echo "验证者公钥: $VALIDATOR_PUBKEY"
echo "质押金额: $VALIDATOR_AMOUNT"
echo ""

# 检查余额
BALANCE=$(/usr/local/biyachain/bin/biyachaind query bank balances $VALIDATOR_ADDR \
    --node=$NODE_RPC \
    -o json | jq -r '.balances[] | select(.denom=="inj") | .amount' || echo "0")

echo "当前余额: $BALANCE inj"

# 提取数值进行比较 (使用 bc 处理大数字)
BALANCE_NUM=$(echo "$BALANCE" | sed 's/inj//')
AMOUNT_NUM=$(echo "$VALIDATOR_AMOUNT" | sed 's/inj//')

if command -v bc >/dev/null 2>&1; then
    if [ $(echo "$BALANCE_NUM < $AMOUNT_NUM" | bc) -eq 1 ]; then
        echo "❌ 错误: 余额不足，无法质押"
        exit 1
    fi
else
    # 如果没有 bc，简单检查余额是否为 0
    if [ "$BALANCE_NUM" = "0" ]; then
        echo "❌ 错误: 余额不足，无法质押"
        exit 1
    fi
fi

echo "✓ 余额充足"
echo ""

# 创建验证者 JSON 配置文件
echo "创建验证者配置文件..."
VALIDATOR_JSON="/tmp/validator-$$.json"

cat > "$VALIDATOR_JSON" << EOF
{
    "pubkey": $VALIDATOR_PUBKEY,
    "amount": "$VALIDATOR_AMOUNT",
    "moniker": "$VALIDATOR_MONIKER",
    "identity": "",
    "website": "",
    "security": "",
    "details": "New validator node",
    "commission-rate": "$VALIDATOR_COMMISSION_RATE",
    "commission-max-rate": "$VALIDATOR_COMMISSION_MAX_RATE",
    "commission-max-change-rate": "$VALIDATOR_COMMISSION_MAX_CHANGE_RATE",
    "min-self-delegation": "$VALIDATOR_MIN_SELF_DELEGATION"
}
EOF

echo "✓ 配置文件已创建: $VALIDATOR_JSON"
echo ""
cat "$VALIDATOR_JSON" | jq '.'
echo ""

# 创建验证者交易
echo "提交创建验证者交易..."
echo ""

TX_RESULT=$(/usr/local/biyachain/bin/biyachaind tx staking create-validator "$VALIDATOR_JSON" \
    --from=validator \
    --chain-id=$CHAIN_ID \
    --node=$NODE_RPC \
    --keyring-backend=$KEYRING_BACKEND \
    --home="$NEW_NODE_HOME" \
    --gas=auto \
    --gas-adjustment=1.5 \
    --gas-prices=500000000inj \
    --yes \
    -o json 2>&1)

TX_EXIT_CODE=$?

# 清理临时文件
rm -f "$VALIDATOR_JSON"

# 检查是否为有效 JSON
if echo "$TX_RESULT" | jq -e '.' >/dev/null 2>&1; then
    echo "$TX_RESULT" | jq '.'
else
    echo "交易输出:"
    echo "$TX_RESULT"
    echo ""
    
    if [ $TX_EXIT_CODE -ne 0 ]; then
        echo "❌ 创建验证者失败"
        exit 1
    fi
fi

# 提取交易哈希
TX_HASH=$(echo "$TX_RESULT" | jq -r '.txhash')

echo ""
echo "=========================================="
echo "  验证者创建交易已提交"
echo "=========================================="
echo "交易哈希: $TX_HASH"
echo ""
echo "等待交易确认..."
sleep 5

# 查询交易结果
echo ""
echo "查询交易结果..."
/usr/local/biyachain/bin/biyachaind query tx $TX_HASH \
    --node=$NODE_RPC \
    -o json | jq '.'

echo ""
echo "验证验证者状态:"
echo "  biyachaind query staking validator \\"
echo "    \$(/usr/local/biyachain/bin/biyachaind keys show validator --bech val -a --home $NEW_NODE_HOME --keyring-backend $KEYRING_BACKEND) \\"
echo "    --node=$NODE_RPC"
echo ""
echo "查看所有验证者:"
echo "  biyachaind query staking validators --node=$NODE_RPC"
echo ""

