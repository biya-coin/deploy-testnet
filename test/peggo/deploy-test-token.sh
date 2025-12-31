#!/bin/bash

# 部署测试 ERC20 代币到 Sepolia 测试网
# 用于 Peggy Bridge 跨链测试

set -e

# ==================== 配置区域 ====================
# 代币参数
TOKEN_NAME="Test Token"
TOKEN_SYMBOL="TEST"
TOKEN_DECIMALS="6"
TOKEN_TOTAL_SUPPLY="1000000"  # 1M tokens

# 部署者私钥（从 inventory.yml 读取）
DEPLOYER_PRIVATE_KEY="0x99f65f092924fd9c7cb8125255da54ca63733be861d5cdfdb570e41182100ba1"

# Sepolia RPC URL
RPC_URL="https://ethereum-sepolia.publicnode.com"

# Sepolia Chain ID
CHAIN_ID="11155111"
# ================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 进入脚本所在目录
cd "$(dirname "$0")"

echo "=========================================="
echo "部署测试 ERC20 代币到 Sepolia"
echo "=========================================="
echo ""

# 检查 cast 是否安装
if ! command -v cast &> /dev/null; then
    echo -e "${RED}错误: cast 未安装${NC}"
    echo "请安装 foundry: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi

if ! command -v forge &> /dev/null; then
    echo -e "${RED}错误: forge 未安装${NC}"
    echo "请安装 foundry: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi

# 显示部署者地址
DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
echo -e "${BLUE}部署者地址:${NC} $DEPLOYER_ADDRESS"
echo ""

# 查询部署者余额
echo "查询部署者余额..."
DEPLOYER_BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")
DEPLOYER_BALANCE_ETH=$(cast --to-unit "$DEPLOYER_BALANCE" ether)
echo -e "${GREEN}余额:${NC} $DEPLOYER_BALANCE_ETH ETH"
echo ""

if [ "$DEPLOYER_BALANCE" == "0" ]; then
    echo -e "${RED}错误: 部署者余额不足${NC}"
    echo "请从水龙头获取 Sepolia ETH:"
    echo "  - https://sepoliafaucet.com/"
    echo "  - https://www.alchemy.com/faucets/ethereum-sepolia"
    exit 1
fi

# 创建临时目录
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# 初始化 Foundry 项目
forge init --no-git --force . > /dev/null 2>&1

echo "=========================================="
echo "生成测试代币合约..."
echo "=========================================="
echo ""

# 创建测试代币合约
cat > src/TestToken.sol << EOF
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract TestToken {
    string public name = "${TOKEN_NAME}";
    string public symbol = "${TOKEN_SYMBOL}";
    uint8 public decimals = ${TOKEN_DECIMALS};
    uint256 public totalSupply = ${TOKEN_TOTAL_SUPPLY} * 10**${TOKEN_DECIMALS};
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }
    
    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
EOF

echo -e "${GREEN}✓ 合约代码已生成${NC}"
echo ""

echo "=========================================="
echo "部署合约到 Sepolia..."
echo "=========================================="
echo ""
echo -e "${YELLOW}代币信息:${NC}"
echo "  名称: $TOKEN_NAME"
echo "  符号: $TOKEN_SYMBOL"
echo "  精度: $TOKEN_DECIMALS"
echo "  总量: $TOKEN_TOTAL_SUPPLY"
echo ""

# 部署合约
echo "正在部署..."
echo ""

# 临时关闭 set -e，手动处理错误
set +e
DEPLOY_OUTPUT=$(forge create src/TestToken.sol:TestToken \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --chain "$CHAIN_ID" \
  --broadcast 2>&1)
DEPLOY_EXIT_CODE=$?
set -e

echo "$DEPLOY_OUTPUT"
echo ""

if [ $DEPLOY_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}✗ 部署失败（退出码: $DEPLOY_EXIT_CODE）${NC}"
    echo ""
    echo "可能的原因："
    echo "  1. RPC 连接失败"
    echo "  2. Gas 不足"
    echo "  3. 私钥格式错误"
    echo "  4. Foundry 版本问题"
    echo ""
    cd - > /dev/null
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 提取合约地址（支持多种输出格式）
TOKEN_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -i "deployed to:" | awk '{print $NF}' | tr -d '\n\r')

if [ -z "$TOKEN_ADDRESS" ]; then
    echo -e "${RED}错误: 无法提取合约地址${NC}"
    cd - > /dev/null
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "=========================================="
echo -e "${GREEN}✓ 部署成功！${NC}"
echo "=========================================="
echo ""
echo -e "${BLUE}合约地址:${NC} $TOKEN_ADDRESS"
echo ""

# 验证合约
echo "验证合约..."
TOKEN_NAME_ONCHAIN=$(cast call "$TOKEN_ADDRESS" "name()(string)" --rpc-url "$RPC_URL")
TOKEN_SYMBOL_ONCHAIN=$(cast call "$TOKEN_ADDRESS" "symbol()(string)" --rpc-url "$RPC_URL")
TOKEN_DECIMALS_ONCHAIN=$(cast call "$TOKEN_ADDRESS" "decimals()(uint8)" --rpc-url "$RPC_URL")
TOKEN_TOTAL_SUPPLY_ONCHAIN=$(cast call "$TOKEN_ADDRESS" "totalSupply()(uint256)" --rpc-url "$RPC_URL")

echo "链上信息:"
echo "  名称: $TOKEN_NAME_ONCHAIN"
echo "  符号: $TOKEN_SYMBOL_ONCHAIN"
echo "  精度: $TOKEN_DECIMALS_ONCHAIN"
echo "  总量: $TOKEN_TOTAL_SUPPLY_ONCHAIN"
echo ""

# 查询部署者代币余额
DEPLOYER_TOKEN_BALANCE=$(cast call "$TOKEN_ADDRESS" \
  "balanceOf(address)(uint256)" \
  "$DEPLOYER_ADDRESS" \
  --rpc-url "$RPC_URL" 2>/dev/null || echo "0")

if [ "$DEPLOYER_TOKEN_BALANCE" != "0" ]; then
    echo -e "${GREEN}部署者代币余额:${NC} $DEPLOYER_TOKEN_BALANCE (原始单位)"
else
    echo -e "${YELLOW}⚠️  无法查询代币余额（可能需要等待区块确认）${NC}"
fi
echo ""

# 保存合约信息
cd - > /dev/null
INFO_FILE="test-token-info.txt"

cat > "$INFO_FILE" << EOF
# 测试代币信息
# 生成时间: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# 网络: Sepolia 测试网
# 部署者: $DEPLOYER_ADDRESS

# 代币信息
token_address=$TOKEN_ADDRESS
token_name=$TOKEN_NAME
token_symbol=$TOKEN_SYMBOL
token_decimals=$TOKEN_DECIMALS
token_total_supply=$TOKEN_TOTAL_SUPPLY

# RPC 配置
rpc_url=$RPC_URL
chain_id=$CHAIN_ID
EOF

echo "=========================================="
echo "合约信息已保存到: $INFO_FILE"
echo "=========================================="
cat "$INFO_FILE"
echo ""

echo "=========================================="
echo "下一步"
echo "=========================================="
echo ""
echo "1. 更新 test-bridge.sh 中的 TOKEN_ADDRESS:"
echo "   TOKEN_ADDRESS=\"$TOKEN_ADDRESS\""
echo ""
echo "2. 运行跨链测试:"
echo "   ./test-bridge.sh"
echo ""

# 清理临时目录
rm -rf "$TEMP_DIR"

