#!/bin/bash
# Biyachain 多节点配置生成脚本
# 
# 功能：
#   1. 从 inventory.yml 读取节点列表
#   2. 为每个节点生成独立的配置（包含独立的私钥）
#   3. 在主节点生成包含所有验证者的 genesis.json
#   4. 分发 genesis.json 到所有节点
#
# 注意：
#   - persistent_peers 由 Ansible 在部署时配置
#   - config.toml/app.toml 的其他参数由 Ansible 调优

set -e


# ======================
# 配置参数
# ======================
CHAINID="biyachain-888"
MONIKER="biyachain"
PASSPHRASE="12345678"

CHAIN_BINARY="injectived"

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ansible 目录
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
# 输出目录
BASE_DIR="$SCRIPT_DIR/chain-deploy-config"

# 验证者节点配置 - 从 inventory.yml 读取
declare -A VALIDATORS=()
declare -A SENTRY_NODES=()

# 从 inventory.yml 读取节点列表
load_inventory() {
    # 读取 inventory.yml 配置
    local inventory_file="$ANSIBLE_DIR/inventory.yml"
    if [ ! -f "$inventory_file" ]; then
        echo "未找到 inventory.yml: $inventory_file"
        exit 1
    fi
    
    # 使用 Python 解析 YAML
    local parse_result=$(python3 -c "
import yaml

with open('$inventory_file', 'r') as f:
    inv = yaml.safe_load(f)

hosts = inv.get('all', {}).get('hosts', {})

for name, config in sorted(hosts.items()):
    if name.startswith('validator-'):
        ip = config.get('ansible_host', '')
        if ip:
            print(f'VALIDATOR:{name}:{ip}')
    elif name.startswith('sentry-'):
        ip = config.get('ansible_host', '')
        if ip:
            print(f'SENTRY:{name}:{ip}')
")
    
    # 解析输出
    while IFS=: read -r node_type node_name node_ip; do
        if [ "$node_type" = "VALIDATOR" ]; then
            VALIDATORS["$node_name"]="$node_ip"
            echo "  ✓ $node_name: $node_ip"
        elif [ "$node_type" = "SENTRY" ]; then
            SENTRY_NODES["$node_name"]="$node_ip"
            echo "  ✓ $node_name: $node_ip"
        fi
    done <<< "$parse_result"
    
    if [ ${#VALIDATORS[@]} -eq 0 ]; then
        echo "未读取到任何 validator 节点"
        exit 1
    fi
    
    echo "✓ 读取到 ${#VALIDATORS[@]} 个验证者, ${#SENTRY_NODES[@]} 个 Sentry 节点"
}

# 清理旧数据
clean_old_data() {
    if [ -d "$BASE_DIR" ]; then
        rm -rf "$BASE_DIR"
    fi
    mkdir -p "$BASE_DIR"
}

# 初始化主节点（用于生成 genesis.json）
init_master_node() {
    MASTER_HOME="$BASE_DIR/master"
    CONFIG_FILE="$MASTER_HOME/config/config.toml"
    APP_FILE="$MASTER_HOME/config/app.toml"

    mkdir -p $MASTER_HOME
    mkdir -p $MASTER_HOME/keyring-file
    mkdir -p $MASTER_HOME/config/gentx

    # 生成genesis文件
    $CHAIN_BINARY init $MONIKER --chain-id $CHAINID --home $MASTER_HOME > /dev/null 2>&1

    # 使用 Python 脚本配置 genesis.json
    echo "配置 genesis.json..."
    python3 $SCRIPT_DIR/scripts/merge_genesis.py \
        $SCRIPT_DIR/genesis_config.yml \
        $MASTER_HOME/config/genesis.json
    
    if [ $? -ne 0 ]; then
        echo "✗ Genesis 配置失败"
        exit 1
    fi

    # zero address account
    yes $PASSPHRASE | $CHAIN_BINARY add-genesis-account --chain-id $CHAINID --home $MASTER_HOME inj1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqe2hm49 1inj

    
    for name in $(echo "${!VALIDATORS[@]}" | tr ' ' '\n' | sort); do
        # 复制共识节点validator钱包
        local node_home="$BASE_DIR/$name"
        cp -r $node_home/keyring-file/* $MASTER_HOME/keyring-file/
        # 验证者账户添加到genesis.json
        local addr=$(yes $PASSPHRASE | $CHAIN_BINARY keys show $name -a --home $MASTER_HOME 2>/dev/null)
        yes $PASSPHRASE | $CHAIN_BINARY add-genesis-account --chain-id $CHAINID --home $MASTER_HOME $addr 1000000000000000000000000inj > /dev/null 2>&1
        #生成 gentx
        local node_home="$BASE_DIR/$name"
        mv $node_home/config/gentx/gentx-*.json $MASTER_HOME/config/gentx/
    done
    
    # 收集所有 gentx
    echo "Collecting gentx..."
    yes $PASSPHRASE | $CHAIN_BINARY genesis collect-gentxs --home $MASTER_HOME > /dev/null 2>&1

    $CHAIN_BINARY genesis validate --home $MASTER_HOME
}

generate_validator_config(){
    local name=$1
    local node_home="$BASE_DIR/$name"
    
    # 生成配置文件
    $CHAIN_BINARY init $name --chain-id $CHAINID --home $node_home > /dev/null 2>&1
    # 生成验证者账户
    yes $PASSPHRASE | $CHAIN_BINARY keys add $name --home $node_home > /dev/null 2>&1
    # 添加验证者账户到genesis.json
    local addr=$(yes $PASSPHRASE | $CHAIN_BINARY keys show $name -a --home $node_home 2>/dev/null)
    yes $PASSPHRASE | $CHAIN_BINARY add-genesis-account --chain-id $CHAINID --home $node_home $addr 1000000000000000000000000inj > /dev/null 2>&1
    # 生成gentx
    yes $PASSPHRASE | $CHAIN_BINARY genesis gentx $name 1000000000000000000000inj \
            --chain-id $CHAINID \
            --home $node_home # > /dev/null 2>&1
}

generate_sentry_config(){
    local name=$1
    local node_home="$BASE_DIR/$name"
    
    # 生成配置文件
    $CHAIN_BINARY init $name --chain-id $CHAINID --home $node_home > /dev/null 2>&1
    # 删除rpc节点不需要的配置
    rm -rf $node_home/config/priv_validator_key.json
    rm -rf $node_home/data
}

copy_genesis(){
    for name in $(echo "${!VALIDATORS[@]}" | tr ' ' '\n' | sort); do
        cp $MASTER_HOME/config/genesis.json $BASE_DIR/$name/config/genesis.json
    done
    
    for name in $(echo "${!SENTRY_NODES[@]}" | tr ' ' '\n' | sort); do
        cp $MASTER_HOME/config/genesis.json $BASE_DIR/$name/config/genesis.json
    done
}

# 应用节点配置（并行执行 - 使用 Python 脚本）
apply_node_configs(){
    # 应用验证者节点配置（后台并行）
    for name in $(echo "${!VALIDATORS[@]}" | tr ' ' '\n' | sort); do
        python3 $SCRIPT_DIR/scripts/apply_node_config_fast.py \
            $SCRIPT_DIR/node_config.yml \
            $BASE_DIR/$name \
            $name \
            validator > /dev/null 2>&1 &
    done
    
    # 应用 Sentry 节点配置（后台并行）
    for name in $(echo "${!SENTRY_NODES[@]}" | tr ' ' '\n' | sort); do
        python3 $SCRIPT_DIR/scripts/apply_node_config_fast.py \
            $SCRIPT_DIR/node_config.yml \
            $BASE_DIR/$name \
            $name \
            sentry > /dev/null 2>&1 &
    done
    
    # 等待所有配置任务完成
    wait
    
    echo "✓ 节点配置应用完成"
}

# 主流程
main() {
    # 从 inventory.yml 读取节点列表
    load_inventory
    
    # 执行生成流程
    clean_old_data
    echo ""
    
    for name in $(echo "${!VALIDATORS[@]}" | tr ' ' '\n' | sort); do
        generate_validator_config "$name" &
    done
    
    for name in $(echo "${!SENTRY_NODES[@]}" | tr ' ' '\n' | sort); do
        generate_sentry_config "$name" &
    done
    
    wait  # 等待所有节点配置生成完成

    init_master_node
    echo ""

    copy_genesis
    apply_node_configs

}
# 记录开始时间（毫秒）
start_time=$(date +%s%3N)

# 运行主流程
main

# 记录结束时间并计算耗时
end_time=$(date +%s%3N)
elapsed_time=$((end_time - start_time))
elapsed_seconds=$(awk "BEGIN {printf \"%.2f\", $elapsed_time/1000}")
echo "总耗时: ${elapsed_time} ms (${elapsed_seconds}s)"