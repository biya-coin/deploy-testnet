#!/bin/bash
# 提交添加新验证者的治理提案

set -e

NEW_NODE_HOME="/data/biyachain-local"
KEYRING_BACKEND="test"
CHAIN_ID="biyachain-888"

# 使用现有验证者节点的 RPC (更可靠)
EXISTING_NODE_RPC="http://10.8.61.62:26757"  # validator-2
LOCAL_NODE_RPC="http://127.0.0.1:26857"      # 本地新节点

# 提案参数
PROPOSAL_TITLE="Add New Validator Node"
PROPOSAL_DESCRIPTION="Proposal to add a new validator node to the network"
INITIAL_DEPOSIT="10000000000000000000inj"  # 10 INJ

echo "=========================================="
echo "  提交添加验证者治理提案"
echo "=========================================="
echo ""

# 检查本地节点是否运行
echo "检查本地节点状态..."
if /usr/local/biyachain/bin/biyachaind status --node=$LOCAL_NODE_RPC 2>/dev/null | grep -q "height"; then
    echo "✓ 本地节点正在运行"
    LOCAL_NODE_RUNNING=true
else
    echo "⚠️  本地节点未运行或未同步完成"
    echo "   将使用现有验证者节点 RPC: $EXISTING_NODE_RPC"
    LOCAL_NODE_RUNNING=false
fi

# 选择使用哪个 RPC
if [ "$LOCAL_NODE_RUNNING" = true ]; then
    NODE_RPC=$LOCAL_NODE_RPC
    echo "使用本地节点 RPC"
else
    NODE_RPC=$EXISTING_NODE_RPC
    echo "使用现有验证者节点 RPC"
fi

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
echo ""

# 检查账户余额
echo "检查账户余额..."
BALANCE=$(/usr/local/biyachain/bin/biyachaind query bank balances $VALIDATOR_ADDR \
    --node=$NODE_RPC \
    -o json | jq -r '.balances[] | select(.denom=="inj") | .amount' || echo "0")

echo "当前余额: $BALANCE inj"

if [ "$BALANCE" = "0" ] || [ -z "$BALANCE" ]; then
    echo ""
    echo "❌ 错误: 账户余额不足"
    echo "正在自动从 genesis 账户转账 100 INJ..."
    echo ""
    
    # 从 accounts.json 读取第一个账户的私钥
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ACCOUNTS_FILE="$SCRIPT_DIR/../ansible/chain-stresser-deploy/instances/0/accounts.json"
    
    if [ ! -f "$ACCOUNTS_FILE" ]; then
        echo "❌ 错误: 未找到账户文件: $ACCOUNTS_FILE"
        exit 1
    fi
    
    # 读取私钥并转换为十六进制
    PRIVATE_KEY_BASE64=$(cat "$ACCOUNTS_FILE" | jq -r '.[0]')
    PRIVATE_KEY_HEX=$(echo "$PRIVATE_KEY_BASE64" | base64 -d | xxd -p -c 256 | tr -d '\n')
    
    # 创建临时 keyring
    TEMP_KEYRING_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_KEYRING_DIR" EXIT
    
    echo "  导入 genesis 账户私钥..."
    
    # 使用 unsafe-import-eth-key 导入私钥 (需要提供密码)
    printf "12345678\n12345678\n" | /usr/local/biyachain/bin/biyachaind keys unsafe-import-eth-key genesis-funder "$PRIVATE_KEY_HEX" \
        --keyring-backend=test \
        --home="$TEMP_KEYRING_DIR" >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo "❌ 错误: 导入私钥失败"
        exit 1
    fi
    
    # 获取资助者地址
    FUNDER_ADDR=$(/usr/local/biyachain/bin/biyachaind keys show genesis-funder \
        --keyring-backend=test \
        --home="$TEMP_KEYRING_DIR" \
        -a 2>/dev/null)
    
    echo "  资助者地址: $FUNDER_ADDR"
    echo "  目标地址: $VALIDATOR_ADDR"
    echo ""
    
    # 执行转账
    echo "  发送转账交易..."
    TX_RESULT=$(/usr/local/biyachain/bin/biyachaind tx bank send genesis-funder "$VALIDATOR_ADDR" 100000000000000000000inj \
        --chain-id=$CHAIN_ID \
        --node=$NODE_RPC \
        --keyring-backend=test \
        --home="$TEMP_KEYRING_DIR" \
        --gas=200000 \
        --gas-prices=500000000inj \
        --yes \
        -o json 2>&1)
    
    if echo "$TX_RESULT" | grep -q '"code":0'; then
        echo "  ✓ 转账交易已提交"
        
        # 提取 txhash
        TXHASH=$(echo "$TX_RESULT" | jq -r '.txhash' 2>/dev/null)
        if [ -n "$TXHASH" ] && [ "$TXHASH" != "null" ]; then
            echo "  交易哈希: $TXHASH"
        fi
        
        echo "  等待 5 秒让交易确认..."
        sleep 5
        
        # 重新查询余额
        BALANCE=$(/usr/local/biyachain/bin/biyachaind query bank balances $VALIDATOR_ADDR \
            --node=$NODE_RPC \
            -o json | jq -r '.balances[] | select(.denom=="inj") | .amount' || echo "0")
        echo "  新余额: $BALANCE inj"
        echo ""
        
        if [ "$BALANCE" = "0" ] || [ -z "$BALANCE" ]; then
            echo "⚠️  余额仍为 0,请等待交易确认后重试"
            exit 1
        fi
    else
        echo "❌ 转账失败"
        echo "$TX_RESULT" | jq '.' 2>/dev/null || echo "$TX_RESULT"
        exit 1
    fi
fi

echo "✓ 账户余额充足"
echo ""

# 创建提案 JSON 文件 (新格式)
PROPOSAL_FILE="$NEW_NODE_HOME/add-validator-proposal.json"

cat > "$PROPOSAL_FILE" <<EOF
{
  "messages": [],
  "metadata": "ipfs://CID",
  "deposit": "$INITIAL_DEPOSIT",
  "title": "$PROPOSAL_TITLE",
  "summary": "$PROPOSAL_DESCRIPTION",
  "expedited": false
}
EOF

echo "提案文件已创建: $PROPOSAL_FILE"
echo ""

# 提交提案
echo "提交治理提案..."
echo ""

TX_RESULT=$(/usr/local/biyachain/bin/biyachaind tx gov submit-proposal "$PROPOSAL_FILE" \
    --from=validator \
    --chain-id=$CHAIN_ID \
    --node=$NODE_RPC \
    --keyring-backend=$KEYRING_BACKEND \
    --home="$NEW_NODE_HOME" \
    --gas=auto \
    --gas-adjustment=1.5 \
    --gas-prices=500000000inj \
    --yes \
    -o json)

echo "$TX_RESULT" | jq '.'

# 提取提案 ID
PROPOSAL_ID=$(echo "$TX_RESULT" | jq -r '.logs[0].events[] | select(.type=="submit_proposal") | .attributes[] | select(.key=="proposal_id") | .value' || echo "")

if [ -z "$PROPOSAL_ID" ]; then
    echo ""
    echo "⚠️  无法从交易结果中提取提案 ID"
    echo "请等待几秒后手动查询最新提案:"
    echo "  biyachaind query gov proposals --node=$NODE_RPC"
    echo ""
    
    # 等待交易确认
    sleep 5
    
    # 查询最新提案
    echo "查询最新提案..."
    PROPOSAL_ID=$(/usr/local/biyachain/bin/biyachaind query gov proposals \
        --node=$NODE_RPC \
        -o json | jq -r '.proposals[-1].id' || echo "")
fi

if [ -n "$PROPOSAL_ID" ] && [ "$PROPOSAL_ID" != "null" ]; then
    echo ""
    echo "=========================================="
    echo "  提案已提交"
    echo "=========================================="
    echo "提案 ID: $PROPOSAL_ID"
    echo ""
    echo "下一步:"
    echo "  1. 运行 05-vote-proposal.sh $PROPOSAL_ID 进行投票"
    echo "  2. 等待提案通过"
    echo "  3. 运行 06-create-validator-tx.sh 创建验证者"
    echo ""
    
    # 保存提案 ID
    echo "$PROPOSAL_ID" > "$NEW_NODE_HOME/proposal-id.txt"
else
    echo ""
    echo "⚠️  提案可能已提交，但无法确认提案 ID"
    echo "请手动查询: biyachaind query gov proposals --node=$NODE_RPC"
fi

