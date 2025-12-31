#!/bin/bash
# 生成 Peggo .env 配置文件脚本
#
# 功能：
#   1. 读取 peggo_evm_key.json（由 generate_config.sh 生成）
#   2. 读取 inventory.yml 的 Peggo 配置参数
#   3. 为每个 validator 节点生成 .env 文件
#
# 依赖：
#   - chain-deploy-config/validator-X/peggo_evm_key.json（必须已存在）
#   - ansible/inventory.yml（Peggo 配置参数）
#
# 用法：
#   ./generate-peggo-env.sh

set -e

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
BASE_DIR="$SCRIPT_DIR/chain-deploy-config"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Peggo .env 配置文件生成脚本"
echo "=========================================="
echo ""

# 检查 inventory.yml 是否存在
if [ ! -f "$ANSIBLE_DIR/inventory.yml" ]; then
    echo -e "${RED}错误: 未找到 inventory.yml: $ANSIBLE_DIR/inventory.yml${NC}"
    exit 1
fi

# 检查配置目录是否存在
if [ ! -d "$BASE_DIR" ]; then
    echo -e "${RED}错误: 配置目录不存在: $BASE_DIR${NC}"
    echo "请先运行 ./generate_config.sh 生成配置文件"
    exit 1
fi

# 从 inventory.yml 读取 Peggo 配置参数
echo "读取 Peggo 配置参数..."
read_inventory_config() {
    python3 - <<EOF
import yaml
import sys

try:
    with open('$ANSIBLE_DIR/inventory.yml', 'r') as f:
        config = yaml.safe_load(f)
    
    # 获取全局配置
    all_vars = config.get('all', {}).get('vars', {})
    
    # 输出配置（格式：KEY=VALUE）
    print(f"PEGGO_COSMOS_CHAIN_ID={all_vars.get('peggo_cosmos_chain_id', 'biyachain-888')}")
    print(f"PEGGO_COSMOS_GRPC={all_vars.get('peggo_cosmos_grpc', 'tcp://127.0.0.1:10000')}")
    print(f"PEGGO_TENDERMINT_RPC={all_vars.get('peggo_tendermint_rpc', 'http://127.0.0.1:26757')}")
    print(f"PEGGO_COSMOS_FEE_DENOM={all_vars.get('peggo_cosmos_fee_denom', 'inj')}")
    print(f"PEGGO_COSMOS_GAS_PRICES={all_vars.get('peggo_cosmos_gas_prices', '1600000000inj')}")
    print(f"PEGGO_ETH_GAS_PRICE_ADJUSTMENT={all_vars.get('peggo_eth_gas_price_adjustment', '1.3')}")
    print(f"PEGGO_ETH_MAX_GAS_PRICE={all_vars.get('peggo_eth_max_gas_price', '500gwei')}")
    print(f"PEGGO_ETH_CHAIN_ID={all_vars.get('peggo_eth_chain_id', '11155111')}")
    print(f"PEGGO_ETH_RPC={all_vars.get('peggo_eth_rpc', 'https://ethereum-sepolia.publicnode.com')}")
    print(f"PEGGO_ETH_ALCHEMY_WS={all_vars.get('peggo_eth_alchemy_ws', '')}")
    print(f"PEGGO_RELAY_VALSETS={all_vars.get('peggo_relay_valsets', 'true')}")
    print(f"PEGGO_RELAY_VALSET_OFFSET_DUR={all_vars.get('peggo_relay_valset_offset_dur', '3m')}")
    print(f"PEGGO_RELAY_BATCHES={all_vars.get('peggo_relay_batches', 'true')}")
    print(f"PEGGO_RELAY_BATCH_OFFSET_DUR={all_vars.get('peggo_relay_batch_offset_dur', '3m')}")
    print(f"PEGGO_RELAY_PENDING_TX_WAIT_DURATION={all_vars.get('peggo_relay_pending_tx_wait_duration', '20m')}")
    print(f"PEGGO_MIN_BATCH_FEE_USD={all_vars.get('peggo_min_batch_fee_usd', '0')}")
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

# 读取配置并导出为环境变量
CONFIG_OUTPUT=$(read_inventory_config)
if [ $? -ne 0 ]; then
    echo -e "${RED}错误: 读取 inventory.yml 配置失败${NC}"
    echo "$CONFIG_OUTPUT"
    exit 1
fi

# 导出配置为环境变量
eval "$CONFIG_OUTPUT"

echo "✓ Peggo 配置参数已读取"
echo "  Chain ID: $PEGGO_COSMOS_CHAIN_ID"
echo "  ETH Chain ID: $PEGGO_ETH_CHAIN_ID"
echo "  ETH RPC: $PEGGO_ETH_RPC"
echo ""

# 查找所有 validator 节点
echo "查找 validator 节点..."
VALIDATOR_DIRS=$(find "$BASE_DIR" -maxdepth 1 -type d -name "validator-*" | sort)

if [ -z "$VALIDATOR_DIRS" ]; then
    echo -e "${RED}错误: 未找到任何 validator 节点目录${NC}"
    exit 1
fi

VALIDATOR_COUNT=$(echo "$VALIDATOR_DIRS" | wc -l)
echo "✓ 找到 $VALIDATOR_COUNT 个 validator 节点"
echo ""

# 生成每个节点的 .env 文件
echo "生成 .env 文件..."
SUCCESS_COUNT=0
FAILED_NODES=()

for validator_dir in $VALIDATOR_DIRS; do
    validator_name=$(basename "$validator_dir")
    peggo_key_file="$validator_dir/peggo_evm_key.json"
    env_file="$validator_dir/.env"
    
    # 检查 peggo_evm_key.json 是否存在
    if [ ! -f "$peggo_key_file" ]; then
        echo -e "${YELLOW}⚠ $validator_name: peggo_evm_key.json 不存在，跳过${NC}"
        FAILED_NODES+=("$validator_name")
        continue
    fi
    
    # 读取私钥
    COSMOS_PK=$(jq -r '.cosmos_private_key // .evm_private_key' "$peggo_key_file")
    ETH_PK=$(jq -r '.evm_private_key' "$peggo_key_file")
    
    if [ -z "$COSMOS_PK" ] || [ "$COSMOS_PK" = "null" ]; then
        echo -e "${RED}✗ $validator_name: 无法读取私钥${NC}"
        FAILED_NODES+=("$validator_name")
        continue
    fi
    
    # 生成 .env 文件
    cat > "$env_file" <<EOF
PEGGO_ENV="local"
PEGGO_LOG_LEVEL="info"

PEGGO_COSMOS_CHAIN_ID="$PEGGO_COSMOS_CHAIN_ID"
PEGGO_COSMOS_GRPC="$PEGGO_COSMOS_GRPC"
PEGGO_TENDERMINT_RPC="$PEGGO_TENDERMINT_RPC"

PEGGO_COSMOS_FEE_DENOM="$PEGGO_COSMOS_FEE_DENOM"
PEGGO_COSMOS_GAS_PRICES="$PEGGO_COSMOS_GAS_PRICES"

# 不使用 keyring，直接使用私钥
PEGGO_COSMOS_KEYRING=""
PEGGO_COSMOS_KEYRING_DIR=""
PEGGO_COSMOS_KEYRING_APP=""
PEGGO_COSMOS_FROM=""
PEGGO_COSMOS_FROM_PASSPHRASE=""
PEGGO_COSMOS_PK="$COSMOS_PK"

PEGGO_COSMOS_USE_LEDGER="false"

# 不使用 keystore，直接使用私钥
PEGGO_ETH_KEYSTORE_DIR=""
PEGGO_ETH_FROM=""
PEGGO_ETH_PASSPHRASE=""
PEGGO_ETH_PK="$ETH_PK"

PEGGO_ETH_GAS_PRICE_ADJUSTMENT="$PEGGO_ETH_GAS_PRICE_ADJUSTMENT"
PEGGO_ETH_MAX_GAS_PRICE="$PEGGO_ETH_MAX_GAS_PRICE"
PEGGO_ETH_CHAIN_ID="$PEGGO_ETH_CHAIN_ID"
PEGGO_ETH_RPC="$PEGGO_ETH_RPC"
PEGGO_ETH_ALCHEMY_WS="$PEGGO_ETH_ALCHEMY_WS"
PEGGO_ETH_USE_LEDGER="false"
PEGGO_COINGECKO_API="https://api.coingecko.com/api/v3"

PEGGO_RELAY_VALSETS="$PEGGO_RELAY_VALSETS"
PEGGO_RELAY_VALSET_OFFSET_DUR="$PEGGO_RELAY_VALSET_OFFSET_DUR"
PEGGO_RELAY_BATCHES="$PEGGO_RELAY_BATCHES"
PEGGO_RELAY_BATCH_OFFSET_DUR="$PEGGO_RELAY_BATCH_OFFSET_DUR"
PEGGO_RELAY_PENDING_TX_WAIT_DURATION="$PEGGO_RELAY_PENDING_TX_WAIT_DURATION"

PEGGO_MIN_BATCH_FEE_USD="$PEGGO_MIN_BATCH_FEE_USD"

PEGGO_STATSD_PREFIX="peggo."
PEGGO_STATSD_ADDR="localhost:8125"
PEGGO_STATSD_STUCK_DUR="5m"
PEGGO_STATSD_MOCKING="false"
PEGGO_STATSD_DISABLED="true"

PEGGO_ETH_PERSONAL_SIGN="false"
PEGGO_ETH_SIGN_MODE="raw"
EOF
    
    # 设置文件权限
    chmod 600 "$env_file"
    
    echo -e "${GREEN}✓ $validator_name${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
done

echo ""
echo "=========================================="
echo "生成完成！"
echo "=========================================="
echo -e "${GREEN}成功: $SUCCESS_COUNT 个节点${NC}"

if [ ${#FAILED_NODES[@]} -gt 0 ]; then
    echo -e "${RED}失败: ${#FAILED_NODES[@]} 个节点${NC}"
    for node in "${FAILED_NODES[@]}"; do
        echo "  - $node"
    done
    exit 1
fi

echo ""
echo "📁 生成的文件位置:"
for validator_dir in $VALIDATOR_DIRS; do
    validator_name=$(basename "$validator_dir")
    echo "  - $validator_dir/.env"
done

echo ""
echo -e "${YELLOW}⚠️  注意事项：${NC}"
echo "  1. .env 文件包含明文私钥，请妥善保管"
echo "  2. 文件权限已设置为 600（仅所有者可读写）"
echo "  3. 部署时会上传到远程服务器 /home/ubuntu/.peggo/.env"
echo "  4. 如需修改配置，请编辑 ansible/inventory.yml 后重新生成"

