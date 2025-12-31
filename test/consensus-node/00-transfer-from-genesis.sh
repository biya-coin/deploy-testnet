#!/bin/bash
# 从 genesis 账户转账到指定地址

set -e

if [ $# -lt 2 ]; then
    echo "用法: $0 <目标地址> <金额(INJ)>"
    echo "示例: $0 inj1xxx... 100"
    exit 1
fi

TO_ADDR="$1"
AMOUNT_INJ="$2"
AMOUNT="${AMOUNT_INJ}000000000000000000"  # 转换为基础单位

CHAIN_ID="biyachain-888"
NODE_RPC="http://127.0.0.1:26857"

# Genesis 账户地址和私钥
GENESIS_ADDR="inj1qqsc99jwvwvgh5frs2exa8n6upw4hrw44drdxl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNTS_FILE="$SCRIPT_DIR/../ansible/chain-stresser-deploy/instances/0/accounts.json"

echo "=========================================="
echo "  从 Genesis 账户转账"
echo "=========================================="
echo ""
echo "从: $GENESIS_ADDR"
echo "到: $TO_ADDR"
echo "金额: $AMOUNT_INJ INJ"
echo ""

# 读取私钥
PRIVATE_KEY_BASE64=$(cat "$ACCOUNTS_FILE" | jq -r '.[0]')
PRIVATE_KEY_HEX=$(echo "$PRIVATE_KEY_BASE64" | base64 -d | xxd -p -c 256 | tr -d '\n')

# 创建临时 keyring
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "导入私钥..."

# 创建一个包含私钥的 keyring 文件
# 使用 test backend 不需要密码
mkdir -p "$TEMP_DIR"

# 方法1: 尝试使用 keys add --recover (但这需要助记词)
# 方法2: 直接使用 --from 地址 + 手动签名
# 方法3: 使用 Python 或 Go 脚本

# 让我们使用更简单的方法: 直接用 biyachaind 的原始签名功能

# 生成未签名交易
echo "生成交易..."
UNSIGNED_TX_FILE="$TEMP_DIR/unsigned.json"

/usr/local/biyachain/bin/biyachaind tx bank send "$GENESIS_ADDR" "$TO_ADDR" "${AMOUNT}inj" \
    --chain-id=$CHAIN_ID \
    --node=$NODE_RPC \
    --gas=200000 \
    --gas-prices=500000000inj \
    --generate-only \
    > "$UNSIGNED_TX_FILE"

echo "✓ 交易已生成"
echo ""

# 现在需要签名这个交易
# 问题: biyachaind tx sign 需要 keyring 中有密钥

# 替代方案: 使用 Python + cosmpy 或 Go 脚本
echo "❌ CLI 工具需要将私钥导入 keyring"
echo ""
echo "建议使用以下方法之一:"
echo ""
echo "1. 使用 Python 脚本 (需要安装 cosmpy):"
echo "   pip install cosmpy"
echo "   # 然后运行 Python 转账脚本"
echo ""
echo "2. 使用 Go 程序 (推荐):"
echo "   # 我可以创建一个简单的 Go 程序"
echo ""
echo "3. 手动导入私钥到 keyring:"
echo "   # 但 unsafe-import-eth-key 命令有问题"
echo ""
echo "私钥 (hex): $PRIVATE_KEY_HEX"
echo "未签名交易: $UNSIGNED_TX_FILE"
echo ""

cat "$UNSIGNED_TX_FILE"

