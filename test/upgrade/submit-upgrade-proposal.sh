#!/bin/bash
set -e

# ==========================================
# 配置区域
# ==========================================
UPGRADE_NAME="v1.17.2"
UPGRADE_HEIGHT="500"

# 下载 URL（Cosmovisor 根据系统架构自动选择）
BINARY_DOWNLOAD_URLS='{
  "linux/amd64": "https://github.com/InjectiveLabs/testnet/releases/download/v1.17.2-beta-1765406497/linux-amd64.zip"
}'

# SHA256 Checksum（可选，生产环境建议提供）
BINARY_CHECKSUMS='{
  "linux/amd64": "5044ee3558a0682752bd1855ff1441b8fc72e3d8f3c66602aef09d01b04a4aa7"
}'

# ==========================================
# 链配置
# ==========================================
CHAIN_ID="biyachain-888"
RPC_NODE="http://10.8.160.37:26757"
DEPOSIT="10000000000000000000inj"
GAS_PRICES="500000000inj"
GAS_ADJUSTMENT="1.5"
KEYRING_BACKEND="test"
BINARY="/usr/local/biyachain/bin/biyachaind"
DEPLOY_DIR="../../ansible/chain-stresser-deploy"

VALIDATORS=(
    "validator-0:0:10.8.21.50"
    "validator-1:1:10.8.45.209"
    "validator-2:2:10.8.61.62"
    "validator-3:3:10.8.161.142"
)

cd "$(dirname "$0")"
export LD_LIBRARY_PATH=/usr/local/biyachain/lib:$LD_LIBRARY_PATH

# ==========================================
# 提交升级提案
# ==========================================
echo "升级: $UPGRADE_NAME -> 高度: $UPGRADE_HEIGHT"

# 查询当前高度
CURRENT_HEIGHT=$($BINARY status --node "$RPC_NODE" 2>/dev/null | jq -r '.sync_info.latest_block_height' 2>/dev/null || echo "0")
if [ "$CURRENT_HEIGHT" != "0" ] && [ "$CURRENT_HEIGHT" != "null" ]; then
    BLOCKS_UNTIL=$((UPGRADE_HEIGHT - CURRENT_HEIGHT))
    [ $BLOCKS_UNTIL -le 0 ] && echo "✗ 升级高度必须大于当前高度 $CURRENT_HEIGHT" && exit 1
    echo "当前高度: $CURRENT_HEIGHT, 距离升级: $BLOCKS_UNTIL 区块"
fi

# 构建提案（info 必须是 JSON 字符串，不是对象）
INFO_JSON=$(cat <<EOF
{
  "binaries": $BINARY_DOWNLOAD_URLS,
  "checksums": $BINARY_CHECKSUMS
}
EOF
)
INFO_STRING=$(echo "$INFO_JSON" | jq -c '.' | jq -Rs '.')

# 使用验证者本地 keyring
FIRST_VALIDATOR_INFO="${VALIDATORS[0]}"
IFS=':' read -r VALIDATOR_NAME VALIDATOR_INDEX VALIDATOR_IP <<< "$FIRST_VALIDATOR_INFO"
PROPOSER_KEYRING_DIR="$DEPLOY_DIR/validators/$VALIDATOR_INDEX"
[ ! -d "$PROPOSER_KEYRING_DIR/keyring-test" ] && echo "✗ Keyring 目录不存在" && exit 1

# 创建提案
PROPOSAL_JSON_FILE="/tmp/upgrade-proposal-$$.json"
trap "rm -f $PROPOSAL_JSON_FILE" EXIT

cat > "$PROPOSAL_JSON_FILE" << EOF
{
  "messages": [{
    "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
    "authority": "inj10d07y265gmmuvt4z0w9aw880jnsr700jstypyt",
    "plan": {"name": "$UPGRADE_NAME", "height": "$UPGRADE_HEIGHT", "info": $INFO_STRING}
  }],
  "metadata": "ipfs://CID",
  "deposit": "$DEPOSIT",
  "title": "Upgrade to $UPGRADE_NAME",
  "summary": "Upgrade to $UPGRADE_NAME at height $UPGRADE_HEIGHT. Cosmovisor auto-download enabled."
}
EOF

# 提交提案
set +e
PROPOSAL_RESULT=$($BINARY tx gov submit-proposal "$PROPOSAL_JSON_FILE" \
    --from="validator" --chain-id="$CHAIN_ID" --node="$RPC_NODE" \
    --home="$PROPOSER_KEYRING_DIR" --keyring-backend="$KEYRING_BACKEND" \
    --gas=auto --gas-adjustment="$GAS_ADJUSTMENT" --gas-prices="$GAS_PRICES" \
    --yes -o json 2>&1)
[ $? -ne 0 ] && echo "✗ 提案提交失败: $PROPOSAL_RESULT" && exit 1
set -e

PROPOSAL_JSON=$(echo "$PROPOSAL_RESULT" | grep -o '{.*}' | tail -1)
TX_CODE=$(echo "$PROPOSAL_JSON" | jq -r '.code // empty' 2>/dev/null)
[ -n "$TX_CODE" ] && [ "$TX_CODE" != "0" ] && echo "✗ 提案失败: $(echo "$PROPOSAL_JSON" | jq -r '.raw_log')" && exit 1

sleep 5
PROPOSAL_ID=$($BINARY query gov proposals --node "$RPC_NODE" -o json 2>/dev/null | jq -r '.proposals[-1].id' || echo "")
[ -z "$PROPOSAL_ID" ] || [ "$PROPOSAL_ID" == "null" ] && echo "✗ 无法获取提案 ID" && exit 1

echo "✓ 提案已提交 (ID: $PROPOSAL_ID)"

# ==========================================
# 自动投票
# ==========================================
for validator_info in "${VALIDATORS[@]}"; do
    IFS=':' read -r VALIDATOR_NAME VALIDATOR_INDEX VALIDATOR_IP <<< "$validator_info"
    
    VALIDATOR_KEYRING_DIR="$DEPLOY_DIR/validators/$VALIDATOR_INDEX"
    [ ! -d "$VALIDATOR_KEYRING_DIR/keyring-test" ] && echo "  ✗ $VALIDATOR_NAME: Keyring 不存在" && continue
    
    VOTE_RESULT=$($BINARY tx gov vote "$PROPOSAL_ID" yes \
        --from="validator" --chain-id="$CHAIN_ID" --node="http://$VALIDATOR_IP:26757" \
        --home="$VALIDATOR_KEYRING_DIR" --keyring-backend="$KEYRING_BACKEND" \
        --gas=auto --gas-adjustment="$GAS_ADJUSTMENT" --gas-prices="$GAS_PRICES" \
        --yes -o json 2>&1)
    
    echo "$VOTE_RESULT" | grep -q '"code":0\|already voted' && echo "  ✓ $VALIDATOR_NAME" || echo "  ✗ $VALIDATOR_NAME"
    sleep 1
done

echo ""
echo "✓ 完成 - 提案 ID: $PROPOSAL_ID"
echo "监控: sudo journalctl -u biyachaind -f"


