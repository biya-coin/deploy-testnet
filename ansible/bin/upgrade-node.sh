#!/bin/bash

set -e

# ==========================================
# Biyachain 节点升级脚本（使用 Cosmovisor）
# ==========================================

# 配置区域
UPGRADE_NAME="${1}"
DOWNLOAD_URL="${2}"
CHECKSUM="${3:-}"

if [ -z "$UPGRADE_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "用法: $0 <upgrade_name> <download_url> [checksum]"
    echo "示例："
    echo "  $0 v1.17.2 https://github.com/InjectiveLabs/testnet/releases/download/v1.17.2-beta-1765406497/linux-amd64.zip"
    echo ""
    exit 1
fi

WASMVM_VERSION="v2.1.5"
BUILD_BASE_DIR="./build/upgrade"

# 进入 ansible 目录（脚本在 ansible/bin/ 下）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ANSIBLE_DIR"

# 设置变量
BUILD_OUTPUT_DIR="$BUILD_BASE_DIR/$UPGRADE_NAME"

# 检查文件
if [ ! -f "inventory.yml" ]; then
    echo "错误: inventory.yml 文件不存在"
    exit 1
fi

if [ ! -f "playbooks/upgrade-node.yml" ]; then
    echo "错误: playbooks/upgrade-node.yml 文件不存在"
    exit 1
fi

# 执行 Ansible
ansible-playbook -i inventory.yml playbooks/upgrade-node.yml \
    -e "upgrade_name=$UPGRADE_NAME" \
    -e "download_url=$DOWNLOAD_URL" \
    -e "checksum=$CHECKSUM" \
    -e "wasmvm_version=$WASMVM_VERSION" \
    -e "build_output_dir=$(pwd)/$BUILD_OUTPUT_DIR" \
    -e "upgrade_binary_dir=$(pwd)/$BUILD_OUTPUT_DIR"

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ 升级部署完成: $UPGRADE_NAME"
else
    echo ""
    echo "✗ 升级部署失败"
    exit 1
fi
