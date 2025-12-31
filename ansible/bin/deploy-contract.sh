#!/bin/bash

# 合约部署脚本 - 部署 Peggy 合约并更新配置文件
# 用法: ./deploy-contract.sh

set -e

# 进入 ansible 目录（脚本在 ansible/bin/ 下）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ANSIBLE_DIR"

# 检查 inventory.yml 是否存在
if [ ! -f "inventory.yml" ]; then
    echo "错误: inventory.yml 文件不存在"
    exit 1
fi

# 检查 deploy-full.yml 是否存在
if [ ! -f "playbooks/deploy-full.yml" ]; then
    echo "错误: playbooks/deploy-full.yml 文件不存在"
    exit 1
fi

# 检查配置文件目录（用户指定的目录）
CONFIG_DIR="./chain-deploy-config"
# 转换为绝对路径
CONFIG_DIR_ABS=$(cd "$CONFIG_DIR" 2>/dev/null && pwd || echo "$(pwd)/$CONFIG_DIR")
if [ ! -d "$CONFIG_DIR_ABS" ]; then
    echo "错误: 配置文件目录不存在: $CONFIG_DIR_ABS"
    echo "请先运行 chain-stresser generate 生成配置文件"
    exit 1
fi

# 检查 ansible 是否安装
if ! command -v ansible-playbook &> /dev/null; then
    echo "错误: ansible-playbook 未安装"
    echo "请运行: pip3 install ansible"
    exit 1
fi

# build 目录会在 ansible playbook 中自动创建，这里不需要检查
# 合约部署信息文件路径（用于后续读取）- 使用绝对路径
CONTRACT_INFO_FILE="$ANSIBLE_DIR/build/peggy-contract-info.txt"

echo "=========================================="
echo "步骤: 本地准备 - Peggy 合约部署"
echo "=========================================="
echo "在本地部署 Peggy 合约到以太坊 Sepolia（只执行一次）"
echo "=========================================="
echo ""

# 执行 Play 1（本地准备），使用 tags 而不是 limit
# 传递绝对路径给 playbook
# 明确跳过远程部署和 Peggo 部署
# 注意：合约部署后会自动更新所有节点的 genesis.json
ansible-playbook -i inventory.yml playbooks/deploy-full.yml \
    --tags local_prepare \
    --skip-tags remote_deploy,deploy_peggo \
    -e deploy_peggy_contract=true \
    -e local_config_dir="$CONFIG_DIR_ABS" \
    -e local_binary_dir="$BINARY_DIR_ABS"

LOCAL_DEPLOY_EXIT_CODE=$?
if [ $LOCAL_DEPLOY_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "错误: 本地 Peggy 合约部署失败（退出码: $LOCAL_DEPLOY_EXIT_CODE）"
    echo "部署已中断"
    exit 1
fi

echo ""
echo "✓ Peggy 合约部署完成"
echo ""

# 读取并显示合约部署信息
if [ -f "$CONTRACT_INFO_FILE" ]; then
    echo "=========================================="
    echo "合约部署信息:"
    echo "=========================================="
    cat "$CONTRACT_INFO_FILE"
    echo "=========================================="
    echo ""
    
    # 验证配置文件是否已更新
    echo "验证配置文件更新..."
    FIRST_GENESIS="$CONFIG_DIR_ABS/validator-0/config/genesis.json"
    if [ -f "$FIRST_GENESIS" ]; then
        if command -v jq &> /dev/null; then
            CONTRACT_ADDR=$(jq -r '.app_state.peggy.params.bridge_ethereum_address // "未设置"' "$FIRST_GENESIS" 2>/dev/null || echo "未设置")
            DEPLOY_HEIGHT=$(jq -r '.app_state.peggy.params.bridge_contract_start_height // "未设置"' "$FIRST_GENESIS" 2>/dev/null || echo "未设置")
            echo "配置文件中的合约参数:"
            echo "  - 合约地址: $CONTRACT_ADDR"
            echo "  - 部署高度: $DEPLOY_HEIGHT"
            echo ""
            if [ "$CONTRACT_ADDR" != "未设置" ] && [ "$CONTRACT_ADDR" != "null" ] && [ "$CONTRACT_ADDR" != "" ]; then
                echo "✓ 配置文件已成功更新"
            else
                echo "⚠️  警告: 配置文件中的合约地址未正确设置"
            fi
        else
            echo "⚠️  警告: jq 未安装，无法验证配置文件更新"
        fi
    else
        echo "⚠️  警告: 未找到配置文件: $FIRST_GENESIS"
    fi
else
    echo "⚠️  警告: $CONTRACT_INFO_FILE 文件不存在，无法读取合约信息"
fi

echo "=========================================="
echo "合约部署流程完成！"
echo "=========================================="
echo ""


