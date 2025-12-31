#!/bin/bash
# 使用本地私钥对提案投票

set -e

CHAIN_ID="biyachain-888"
KEYRING_BACKEND="test"  # 使用 test backend,简单且持久化
BINARY="/usr/local/biyachain/bin/biyachaind"

# 本地配置目录
DEPLOY_DIR="../ansible/chain-stresser-deploy"

# 验证者节点配置
VALIDATORS=(
    "validator-0:0:10.8.21.50"
    "validator-1:1:10.8.45.209"
    "validator-2:2:10.8.61.62"
    "validator-3:3:10.8.161.142"
)

# 临时 keyring 目录
TEMP_KEYRING_DIR="/tmp/vote-keyring-$$"

# 清理函数
cleanup() {
    if [ -d "$TEMP_KEYRING_DIR" ]; then
        rm -rf "$TEMP_KEYRING_DIR"
    fi
}
trap cleanup EXIT

# 检查参数
if [ -z "$1" ]; then
    echo "用法: $0 <proposal-id>"
    echo ""
    echo "示例: $0 1"
    exit 1
fi

PROPOSAL_ID="$1"

echo "=========================================="
echo "  对提案 #$PROPOSAL_ID 投票"
echo "=========================================="
echo ""
echo "使用本地私钥文件直接发送投票交易"
echo ""

# 检查二进制文件
if [ ! -f "$BINARY" ]; then
    echo "❌ 错误: 找不到 biyachaind: $BINARY"
    exit 1
fi

# 检查 expect
if ! command -v expect >/dev/null 2>&1; then
    echo "❌ 错误: 需要安装 expect 工具"
    echo "  运行: sudo apt-get install -y expect"
    exit 1
fi

# 设置库路径
export LD_LIBRARY_PATH=/usr/local/biyachain/lib:$LD_LIBRARY_PATH

# 为每个验证者投票
for validator_info in "${VALIDATORS[@]}"; do
    IFS=':' read -r VALIDATOR_NAME VALIDATOR_INDEX VALIDATOR_IP <<< "$validator_info"
    
    echo "----------------------------------------"
    echo "验证者: $VALIDATOR_NAME (节点 $VALIDATOR_IP)"
    echo "----------------------------------------"
    
    # 本地配置文件路径
    PEGGO_KEY_FILE="$DEPLOY_DIR/validators/$VALIDATOR_INDEX/config/peggo_key.json"
    
    # 检查配置文件
    if [ ! -f "$PEGGO_KEY_FILE" ]; then
        echo "❌ 错误: 找不到配置文件: $PEGGO_KEY_FILE"
        echo ""
        continue
    fi
    
    # 从 peggo_key.json 读取信息
    PRIV_KEY=$(jq -r '.cosmos_private_key' "$PEGGO_KEY_FILE")
    COSMOS_ADDR=$(jq -r '.cosmos_address' "$PEGGO_KEY_FILE")
    
    if [ -z "$PRIV_KEY" ] || [ "$PRIV_KEY" = "null" ]; then
        echo "❌ 错误: 无法读取私钥"
        echo ""
        continue
    fi
    
    echo "地址: $COSMOS_ADDR"
    echo "私钥: ${PRIV_KEY:0:8}...${PRIV_KEY: -8}"
    
    # 创建临时 keyring 目录
    VALIDATOR_KEYRING_DIR="$TEMP_KEYRING_DIR/$VALIDATOR_NAME"
    mkdir -p "$VALIDATOR_KEYRING_DIR"
    
    # 导入私钥 (test backend 需要密码)
    echo ""
    echo "导入私钥到临时 keyring..."
    
    echo -e "12345678\n12345678" | $BINARY keys unsafe-import-eth-key "$VALIDATOR_NAME" "$PRIV_KEY" \
        --home "$VALIDATOR_KEYRING_DIR" \
        --keyring-backend "$KEYRING_BACKEND" >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo "❌ 导入私钥失败"
        echo ""
        continue
    fi
    
    echo "✓ 私钥导入成功"
    
    # 验证密钥
    IMPORTED_ADDR=$($BINARY keys show "$VALIDATOR_NAME" \
        --home "$VALIDATOR_KEYRING_DIR" \
        --keyring-backend "$KEYRING_BACKEND" \
        -a 2>/dev/null)
    
    if [ "$IMPORTED_ADDR" != "$COSMOS_ADDR" ]; then
        echo "⚠️  地址不匹配:"
        echo "  导入的: $IMPORTED_ADDR"
        echo "  预期的: $COSMOS_ADDR"
    else
        echo "✓ 地址验证通过"
    fi
    
    # 发送投票交易
    echo ""
    echo "发送投票交易 (YES)..."
    
    # 选择一个可用的 RPC 节点
    RPC_NODE="http://$VALIDATOR_IP:26757"
    
    # 直接发送交易 (test backend 不需要密码)
    VOTE_RESULT=$($BINARY tx gov vote "$PROPOSAL_ID" yes \
        --from="$VALIDATOR_NAME" \
        --chain-id="$CHAIN_ID" \
        --node="$RPC_NODE" \
        --home="$VALIDATOR_KEYRING_DIR" \
        --keyring-backend="$KEYRING_BACKEND" \
        --gas=auto \
        --gas-adjustment=1.5 \
        --gas-prices=500000000inj \
        --yes \
        -o json 2>&1)
    
    # 提取 JSON 响应
    VOTE_JSON=$(echo "$VOTE_RESULT" | grep -o '{.*}' | tail -1)
    
    # 检查响应是否为有效的 JSON
    if [ -n "$VOTE_JSON" ] && echo "$VOTE_JSON" | jq -e '.' >/dev/null 2>&1; then
        TX_CODE=$(echo "$VOTE_JSON" | jq -r '.code // empty')
        TX_HASH=$(echo "$VOTE_JSON" | jq -r '.txhash // empty')
        
        # code 为 0 或不存在都表示成功
        if [ -z "$TX_CODE" ] || [ "$TX_CODE" = "0" ]; then
            if [ -n "$TX_HASH" ]; then
                echo "✓ 投票成功!"
                echo "  交易哈希: $TX_HASH"
            else
                echo "✓ 投票已提交"
            fi
        else
            ERROR_MSG=$(echo "$VOTE_JSON" | jq -r '.raw_log // .log // "未知错误"')
            echo "❌ 投票失败 (错误码: $TX_CODE)"
            echo "  错误信息: $ERROR_MSG"
        fi
    else
        # 不是 JSON,检查常见错误
        if echo "$VOTE_RESULT" | grep -qi "inactive proposal"; then
            echo "❌ 投票失败: 提案已不活跃"
        elif echo "$VOTE_RESULT" | grep -qi "already voted"; then
            echo "⚠️  该验证者已经投过票"
        elif echo "$VOTE_RESULT" | grep -qi "proposal.*does not exist"; then
            echo "❌ 投票失败: 提案不存在"
        else
            echo "❌ 投票失败"
            echo "  响应: $VOTE_RESULT"
        fi
    fi
    
    echo ""
    sleep 2
done

echo "=========================================="
echo "  投票完成"
echo "=========================================="
echo ""
echo "查询提案状态:"
echo "  biyachaind query gov proposal $PROPOSAL_ID --node=http://10.8.21.50:26757"
echo ""
echo "查询投票情况:"
echo "  biyachaind query gov votes $PROPOSAL_ID --node=http://10.8.21.50:26757"
echo ""
