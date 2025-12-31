#!/bin/bash

set -e

# ==========================================
# 本地编译 Biyachain 脚本
# ==========================================
# 功能：
#   1. 检查编译环境（Go、WASM 库）
#   2. 使用 Ansible 编译 biyachaind
# ==========================================

# 配置区域
INJECTIVE_VERSION="v1.17.0"
INJECTIVE_REPO_URL="https://github.com/biya-coin/injective-core.git"

# 脚本目录（当前目录）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 使用绝对路径 - build 放在当前目录下
SOURCE_DIR="$SCRIPT_DIR/build/biyachain"
BUILD_DIR="$SCRIPT_DIR/build"
GO_CACHE_DIR="$BUILD_DIR/go"
OUTPUT_BIN_DIR="$BUILD_DIR/bin"

# Ansible 目录
ANSIBLE_DIR="$SCRIPT_DIR/ansible"

# Go 版本要求
GO_REQUIRED_VERSION="1.23.8"
GO_MIN_VERSION="1.23.1"

# WASM 库配置
LIBWASMVM_VERSION="v2.1.5"
LIBWASMVM_DOWNLOAD_URL="https://github.com/CosmWasm/wasmvm/releases/download/${LIBWASMVM_VERSION}/libwasmvm.x86_64.so"

# Cosmovisor 配置
COSMOVISOR_VERSION="v1.5.0"

# 检查 Ansible 是否安装
if ! command -v ansible-playbook &> /dev/null; then
    echo "✗ Ansible 未安装"
    echo "  安装: pip3 install ansible"
    exit 1
fi

# 使用 Ansible 检查编译环境
echo "检查编译环境并自动安装缺失的工具..."
if ! ANSIBLE_CONFIG=$ANSIBLE_DIR/ansible.cfg ansible-playbook $ANSIBLE_DIR/playbooks/check-build-env.yml \
    -e "go_required_version=$GO_REQUIRED_VERSION" \
    -e "go_min_version=$GO_MIN_VERSION" > /dev/null 2>&1; then
    
    echo ""
    echo "环境检查失败，正在显示详细信息..."
    echo ""
    ANSIBLE_CONFIG=$ANSIBLE_DIR/ansible.cfg ansible-playbook $ANSIBLE_DIR/playbooks/check-build-env.yml \
        -e "go_required_version=$GO_REQUIRED_VERSION" \
        -e "go_min_version=$GO_MIN_VERSION"
    exit 1
fi

echo "✓ 环境检查通过"

# 检查 playbook
if [ ! -f "$ANSIBLE_DIR/playbooks/build-local.yml" ]; then
    echo "✗ $ANSIBLE_DIR/playbooks/build-local.yml 不存在"
    exit 1
fi

# 创建目录
mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$GO_CACHE_DIR" "$OUTPUT_BIN_DIR"

# 执行编译（包括 WASM 库下载和 Cosmovisor 编译）
ANSIBLE_CONFIG=$ANSIBLE_DIR/ansible.cfg ansible-playbook -i $ANSIBLE_DIR/inventory.yml $ANSIBLE_DIR/playbooks/build-local.yml \
    -e "injective_version=$INJECTIVE_VERSION" \
    -e "injective_repo_url=$INJECTIVE_REPO_URL" \
    -e "injective_build_dir=$SOURCE_DIR" \
    -e "injective_binary_output_dir=$OUTPUT_BIN_DIR" \
    -e "go_cache_dir=$GO_CACHE_DIR" \
    -e "libwasmvm_download_url=$LIBWASMVM_DOWNLOAD_URL" \
    -e "libwasmvm_version=$LIBWASMVM_VERSION" \
    -e "cosmovisor_version=$COSMOVISOR_VERSION" \
    --limit localhost --connection local

if [ $? -ne 0 ]; then
    echo ""
    echo "✗ 编译失败"
    exit 1
fi

# 检查编译产物
if [ ! -f "$OUTPUT_BIN_DIR/injectived" ] && [ ! -f "$OUTPUT_BIN_DIR/biyachaind" ]; then
    echo ""
    echo "✗ 未找到编译产物"
    exit 1
fi

# 重命名 injectived 为 biyachaind
if [ -f "$OUTPUT_BIN_DIR/injectived" ]; then
    if [ ! -f "$OUTPUT_BIN_DIR/biyachaind" ]; then
        mv "$OUTPUT_BIN_DIR/injectived" "$OUTPUT_BIN_DIR/biyachaind"
    else
        rm "$OUTPUT_BIN_DIR/injectived"
    fi
fi

echo ""
echo "✓ 编译完成: $OUTPUT_BIN_DIR"
