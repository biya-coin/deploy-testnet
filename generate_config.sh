#!/bin/bash
# Biyachain 多节点配置生成脚本
# 
# 功能：
#   1. 从 inventory.yml 读取节点列表
#   2. 为每个节点生成独立的配置（包含独立的私钥）
#   3. 在主节点生成包含所有验证者的 genesis.json
#   4. 分发 genesis.json 到所有节点
#   5. 配置 persistent_peers（P2P 连接）
#   6. 应用节点配置（config.toml 和 app.toml）
#

set -e


# ======================
# 配置参数
# ======================
CHAINID="biyachain-888"
MONIKER="biyachain"
# 创世账号余额
ORCHESTRATOR_BALANCE="1000000000000000000000000inj"
VALIDATOR_BALANCE="1000000000000000000000000inj"

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
    
    # 使用 Python 脚本解析 YAML
    local parse_result=$(python3 $SCRIPT_DIR/scripts/parse_inventory.py "$inventory_file")
    
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
    mkdir -p $MASTER_HOME/keyring-test  # 所有钱包使用 test 模式
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
    $CHAIN_BINARY add-genesis-account --chain-id $CHAINID --home $MASTER_HOME inj1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqe2hm49 1inj

    for name in $(echo "${!VALIDATORS[@]}" | tr ' ' '\n' | sort); do
        local node_home="$BASE_DIR/$name"
        
        # 复制 validator 和 orchestrator 钱包到 master
        cp -r $node_home/keyring-test/* $MASTER_HOME/keyring-test/
        
        # 将 validator 账户添加到 genesis.json
        local validator_addr=$($CHAIN_BINARY keys show $name -a --home $MASTER_HOME --keyring-backend test 2>/dev/null)
        $CHAIN_BINARY add-genesis-account --chain-id $CHAINID --home $MASTER_HOME $validator_addr $VALIDATOR_BALANCE > /dev/null 2>&1
        
        # 将 orchestrator 账户添加到 genesis.json
        local orch_addr=$($CHAIN_BINARY keys show orchestrator-$name -a --home $MASTER_HOME --keyring-backend test 2>/dev/null)
        $CHAIN_BINARY add-genesis-account --chain-id $CHAINID --home $MASTER_HOME $orch_addr $ORCHESTRATOR_BALANCE > /dev/null 2>&1
        
        # 移动 gentx 到 master
        mv $node_home/config/gentx/gentx-*.json $MASTER_HOME/config/gentx/
    done
    
    # 收集所有 gentx
    echo "Collecting gentx..."
    $CHAIN_BINARY genesis collect-gentxs --home $MASTER_HOME > /dev/null 2>&1

    $CHAIN_BINARY genesis validate --home $MASTER_HOME
}

generate_validator_config(){
    local name=$1
    local node_home="$BASE_DIR/$name"
    
    # 生成配置文件
    $CHAIN_BINARY init $name --chain-id $CHAINID --home $node_home > /dev/null 2>&1
    
    # 生成验证者账户（使用 keyring-test，无需密码）
    $CHAIN_BINARY keys add $name --home $node_home --keyring-backend test > /dev/null 2>&1
    
    # 生成 orchestrator 账户（使用 keyring-test）
    $CHAIN_BINARY keys add orchestrator-$name --home $node_home --keyring-backend test > /dev/null 2>&1
    
    # 添加验证者账户到genesis.json
    local addr=$($CHAIN_BINARY keys show $name -a --home $node_home --keyring-backend test 2>/dev/null)
    $CHAIN_BINARY add-genesis-account --chain-id $CHAINID --home $node_home $addr $VALIDATOR_BALANCE > /dev/null 2>&1
    
    # 生成gentx
    $CHAIN_BINARY genesis gentx $name 1000000000000000000000inj \
            --chain-id $CHAINID \
            --home $node_home \
            --keyring-backend test > /dev/null 2>&1
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

# 生成 orchestrator 密钥文件（在节点根目录，部署时不上传）
generate_orchestrator_keys(){
    echo "生成 Orchestrator 密钥文件..."
    for name in $(echo "${!VALIDATORS[@]}" | tr ' ' '\n' | sort); do
        local node_home="$BASE_DIR/$name"
        # 从节点的 keyring-test 读取，输出到节点根目录（不在 config/ 下）
        python3 $SCRIPT_DIR/scripts/generate_orchestrator_keys.py \
            "$CHAIN_BINARY" \
            "$node_home" \
            "$node_home" \
            "test" \
            "[\"$name\"]" \
            "peggo_evm_key.json" > /dev/null 2>&1 &
    done
    wait
    echo "✓ Orchestrator 密钥文件生成完成"
}

# 配置 persistent_peers
configure_persistent_peers(){
    echo "配置 P2P 连接（persistent_peers）..."
    
    python3 $SCRIPT_DIR/scripts/configure_peers.py \
        $CHAIN_BINARY \
        $BASE_DIR \
        $SCRIPT_DIR/node_config.yml \
        $ANSIBLE_DIR/inventory.yml
    
    if [ $? -ne 0 ]; then
        echo "✗ P2P 连接配置失败"
        exit 1
    fi
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
    
    generate_orchestrator_keys  # 生成 orchestrator 密钥文件
    echo ""

    copy_genesis
    configure_persistent_peers
    apply_node_configs

}

main