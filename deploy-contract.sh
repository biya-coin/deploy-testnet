#!/bin/bash

# 合约部署脚本 - 部署 Peggy 合约并更新配置文件
# 用法: ./deploy-contract.sh

set -e

# 脚本目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Ansible 目录
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
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

# 检查配置文件目录（相对于项目根目录）
CONFIG_DIR="$SCRIPT_DIR/chain-deploy-config"
# 转换为绝对路径
CONFIG_DIR_ABS=$(cd "$CONFIG_DIR" 2>/dev/null && pwd || echo "")
if [ -z "$CONFIG_DIR_ABS" ] || [ ! -d "$CONFIG_DIR_ABS" ]; then
    echo "错误: 配置文件目录不存在: $CONFIG_DIR"
    echo "请先运行 ./generate_config.sh 生成配置文件"
    exit 1
fi

# 检查 ansible 是否安装
if ! command -v ansible-playbook &> /dev/null; then
    echo "错误: ansible-playbook 未安装"
    echo "请运行: pip3 install ansible"
    exit 1
fi

# 检查是否至少有一个 validator 节点的 orchestrator 密钥文件（从节点根目录）
FIRST_ORCH_KEY="$CONFIG_DIR_ABS/validator-0/peggo_evm_key.json"
if [ ! -f "$FIRST_ORCH_KEY" ]; then
    echo "错误: 未找到 Orchestrator 密钥文件: $FIRST_ORCH_KEY"
    echo "请先运行 ./generate_config.sh 生成配置文件"
    exit 1
fi

# 统计 orchestrator 密钥文件数量（用于显示）
ORCH_KEY_COUNT=$(ls -1 "$CONFIG_DIR_ABS"/validator-*/peggo_evm_key.json 2>/dev/null | wc -l)

echo "=========================================="
echo "步骤: 本地准备 - Peggy 合约部署"
echo "=========================================="
echo "配置目录: $CONFIG_DIR_ABS"
echo "Orchestrator 密钥: $ORCH_KEY_COUNT 个（在各节点根目录）"
echo "=========================================="
echo "在本地部署 Peggy 合约到以太坊 Sepolia（只执行一次）"
echo "合约部署需要工具: etherman, Go, solc"
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
    -e local_config_dir="$CONFIG_DIR_ABS"

LOCAL_DEPLOY_EXIT_CODE=$?
if [ $LOCAL_DEPLOY_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "错误: 本地 Peggy 合约部署失败（退出码: $LOCAL_DEPLOY_EXIT_CODE）"
    echo "部署已中断"
    exit 1
fi

echo "=========================================="
echo "合约部署流程完成！"
echo "=========================================="

# 读取并显示合约部署信息
CONTRACT_INFO_FILE="$SCRIPT_DIR/build/peggy-contract-info.txt"
echo "合约信息文件: $CONTRACT_INFO_FILE"
cat "$CONTRACT_INFO_FILE"
