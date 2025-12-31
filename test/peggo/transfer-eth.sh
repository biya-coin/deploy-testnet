#!/bin/bash

# 自动给以太坊账户转账脚本
# 从 peggo_evm_key.json 读取目标地址，批量转账 Sepolia ETH

set -e

# ==================== 配置区域 ====================
# 转账金额（单位：ether）
TRANSFER_AMOUNT="0.0001"

# 发送方私钥（合约部署者）
FROM_PRIVATE_KEY="0x99f65f092924fd9c7cb8125255da54ca63733be861d5cdfdb570e41182100ba1"

# Sepolia RPC URL
RPC_URL="https://ethereum-sepolia.publicnode.com"

# Sepolia Chain ID
CHAIN_ID="11155111"

# peggo_evm_key.json 文件目录
PEGGO_KEYS_DIR="../../ansible/chain-stresser-deploy/validators"
# ================================================

# 解析命令行参数
CHECK_ONLY=false
if [ "$1" == "--check-only" ] || [ "$1" == "-c" ]; then
    CHECK_ONLY=true
fi

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 进入脚本所在目录
cd "$(dirname "$0")"

# 显示使用说明
show_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --check-only, -c    仅查询余额，不执行转账"
    echo "  --help, -h          显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                  执行转账（转账 ${TRANSFER_AMOUNT} ETH 到每个地址）"
    echo "  $0 --check-only     仅查询所有地址的余额"
}

# 检查帮助参数
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    show_usage
    exit 0
fi

echo "=========================================="
if [ "$CHECK_ONLY" == true ]; then
    echo "以太坊账户余额查询 (Sepolia 测试网)"
else
    echo "以太坊账户转账脚本 (Sepolia 测试网)"
fi
echo "=========================================="
echo ""

# 检查必要的工具
if ! command -v cast &> /dev/null; then
    echo -e "${RED}错误: cast 未安装${NC}"
    echo "请安装 foundry: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: jq 未安装${NC}"
    echo "请安装 jq: sudo apt-get install jq"
    exit 1
fi

# 检查 peggo_keys 目录是否存在
if [ ! -d "$PEGGO_KEYS_DIR" ]; then
    echo -e "${RED}错误: peggo_keys 目录不存在: $PEGGO_KEYS_DIR${NC}"
    exit 1
fi

# 获取发送方地址
FROM_ADDRESS=$(cast wallet address --private-key "$FROM_PRIVATE_KEY")
echo -e "${BLUE}发送方地址:${NC} $FROM_ADDRESS"
echo ""

# 查询发送方余额
echo "查询发送方余额..."
FROM_BALANCE=$(cast balance "$FROM_ADDRESS" --rpc-url "$RPC_URL")
FROM_BALANCE_ETH=$(cast --to-unit "$FROM_BALANCE" ether)
echo -e "${GREEN}发送方余额:${NC} $FROM_BALANCE_ETH ETH"
echo ""

TARGET_ADDRESSES=()
VALIDATOR_INDICES=()

for validator_dir in "$PEGGO_KEYS_DIR"/*/; do
    if [ -d "$validator_dir" ]; then
        peggo_key_file="${validator_dir}config/peggo_evm_key.json"
        
        if [ -f "$peggo_key_file" ]; then
            # 提取 validator 索引
            validator_index=$(basename "$validator_dir")
            
            # 读取 EVM 地址
            evm_addr=$(jq -r '.evm_address' "$peggo_key_file" 2>/dev/null || echo "")
            
            if [ -n "$evm_addr" ] && [ "$evm_addr" != "null" ]; then
                # 添加 0x 前缀
                evm_addr_full="0x${evm_addr}"
                TARGET_ADDRESSES+=("$evm_addr_full")
                VALIDATOR_INDICES+=("$validator_index")
            fi
        fi
    fi
done

if [ ${#TARGET_ADDRESSES[@]} -eq 0 ]; then
    echo -e "${RED}错误: 未找到任何目标地址${NC}"
    exit 1
fi

# 查询所有目标地址的当前余额
echo "=========================================="
echo "查询目标地址当前余额..."
echo "=========================================="

# 用于存储需要转账的地址（余额为 0 的地址）
NEED_TRANSFER_ADDRESSES=()
NEED_TRANSFER_INDICES=()

for i in "${!TARGET_ADDRESSES[@]}"; do
    addr="${TARGET_ADDRESSES[$i]}"
    idx="${VALIDATOR_INDICES[$i]}"
    
    balance=$(cast balance "$addr" --rpc-url "$RPC_URL")
    balance_eth=$(cast --to-unit "$balance" ether)
    
    echo -e "Validator ${idx} (${addr}): ${YELLOW}${balance_eth} ETH${NC}"
    
    # 如果余额为 0，添加到需要转账的列表
    if [ "$balance" == "0" ]; then
        NEED_TRANSFER_ADDRESSES+=("$addr")
        NEED_TRANSFER_INDICES+=("$idx")
    fi
done

echo ""

# 如果所有地址都有余额，提示并退出
if [ ${#NEED_TRANSFER_ADDRESSES[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ 所有地址都已有余额，无需转账${NC}"
    echo ""
    exit 0
fi

echo -e "${BLUE}需要转账的地址: ${#NEED_TRANSFER_ADDRESSES[@]} 个${NC}"
echo ""

# 如果仅查询余额，则退出
if [ "$CHECK_ONLY" == true ]; then
    echo "=========================================="
    echo -e "${GREEN}✓ 余额查询完成${NC}"
    echo "=========================================="
    echo ""
    echo "如需执行转账，请运行："
    echo "  ./transfer-eth.sh"
    echo ""
    exit 0
fi

# 执行转账
echo "=========================================="
echo "开始转账..."
echo "=========================================="
echo -e "${YELLOW}转账金额: ${TRANSFER_AMOUNT} ETH${NC}"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

# 只转账给需要转账的地址（余额为 0 的地址）
for i in "${!NEED_TRANSFER_ADDRESSES[@]}"; do
    addr="${NEED_TRANSFER_ADDRESSES[$i]}"
    idx="${NEED_TRANSFER_INDICES[$i]}"
    
    echo "----------------------------------------"
    echo -e "正在转账到 Validator ${idx} (${addr})..."
    echo ""
    
    # 执行转账（使用 || true 确保不会因为错误退出）
    TX_OUTPUT=$(cast send "$addr" \
        --value "${TRANSFER_AMOUNT}ether" \
        --rpc-url "$RPC_URL" \
        --private-key "$FROM_PRIVATE_KEY" \
        --chain "$CHAIN_ID" 2>&1) || TX_EXIT_CODE=$?
    
    # 如果 TX_EXIT_CODE 未设置，说明命令成功
    if [ -z "${TX_EXIT_CODE:-}" ]; then
        TX_EXIT_CODE=0
    fi
    
    if [ $TX_EXIT_CODE -eq 0 ]; then
        echo "$TX_OUTPUT"
        echo ""
        echo -e "${GREEN}✓ 转账成功${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        
        # 等待交易确认
        sleep 3
    else
        echo "$TX_OUTPUT"
        echo ""
        echo -e "${RED}✗ 转账失败 (退出码: $TX_EXIT_CODE)${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        
        # 转账失败后等待一段时间再继续
        sleep 5
    fi
    
    # 重置退出码变量以便下次循环
    unset TX_EXIT_CODE
    
    echo ""
done

echo "=========================================="
echo "转账完成"
echo "=========================================="
echo -e "成功: ${GREEN}${SUCCESS_COUNT}${NC}"
echo -e "失败: ${RED}${FAIL_COUNT}${NC}"
echo ""

# 等待区块确认
echo "等待区块确认（5秒）..."
sleep 5
echo ""

# 查询转账后的余额
echo "=========================================="
echo "查询转账后余额..."
echo "=========================================="

for i in "${!TARGET_ADDRESSES[@]}"; do
    addr="${TARGET_ADDRESSES[$i]}"
    idx="${VALIDATOR_INDICES[$i]}"
    
    balance=$(cast balance "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
    balance_eth=$(cast --to-unit "$balance" ether 2>/dev/null || echo "0")
    
    echo -e "Validator ${idx} (${addr}): ${GREEN}${balance_eth} ETH${NC}"
done

echo ""
echo "=========================================="
echo "✓ 脚本执行完成"
echo "=========================================="

