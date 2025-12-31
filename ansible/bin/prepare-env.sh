#!/bin/bash
# 准备本地环境 - 安装依赖工具

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ANSIBLE_DIR"

echo "准备本地环境..."
echo ""

# 运行 Ansible playbook
ansible-playbook playbooks/prepare-local-env.yml

echo ""
echo "环境准备完成！"

